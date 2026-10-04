import Foundation
import SQLite3

struct RemoteSessionRef: Codable, Hashable, Sendable {
    let serverId: String
    let agentId: String
    let runtimeId: String
    let sessionId: String
    fileprivate var key: String {
        String(data: try! JSONEncoder().encode([serverId, agentId, runtimeId, sessionId]), encoding: .utf8)!
    }
    fileprivate var valid: Bool {
        [serverId, agentId, runtimeId, sessionId].allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }
    }
}

struct RemoteSessionControl: Codable, Equatable, Sendable {
    let executionEpoch: String
    let controlRevision: Int
    let state: String
    let controlMode: String
    let currentTurnId: String?
    let allowedActions: [String]
    enum CodingKeys: String, CodingKey { case executionEpoch, controlRevision, state, controlMode, currentTurnId, allowedActions }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(executionEpoch, forKey: .executionEpoch); try c.encode(controlRevision, forKey: .controlRevision)
        try c.encode(state, forKey: .state); try c.encode(controlMode, forKey: .controlMode)
        try c.encode(currentTurnId, forKey: .currentTurnId); try c.encode(allowedActions, forKey: .allowedActions)
    }
}

/// This is a mapped UI request, not raw vendor RPC arguments. Questions will have
/// their own typed model; until supported they must disable control and resync.
struct RemoteApprovalRequest: Codable, Equatable, Sendable {
    let requestId: String
    let requestRevision: Int
    let type: String
    let executionEpoch: String
    let turnId: String
    let summary: String
    let allowedDecisions: [String]
    let expiresAt: String
}

/// Safe presentation metadata only. Vendor arguments, paths, output and
/// reasoning are deliberately absent from the mobile session projection.
struct RemoteToolActivity: Codable, Equatable, Sendable {
    let activityId: String
    let turnId: String
    let activityRevision: Int
    let kind: String
    let status: String
    let createdAt: String
}

struct RemoteSessionProjection: Codable, Equatable, Sendable {
    var control: RemoteSessionControl
    var messages: [RemoteHistoryMessage]
    var pendingRequests: [RemoteApprovalRequest]
    var olderHistoryCursor: String?
    var hasOlder: Bool
    var activities: [RemoteToolActivity]

    init(control: RemoteSessionControl, messages: [RemoteHistoryMessage], pendingRequests: [RemoteApprovalRequest],
         olderHistoryCursor: String?, hasOlder: Bool, activities: [RemoteToolActivity] = []) {
        self.control = control; self.messages = messages; self.pendingRequests = pendingRequests
        self.olderHistoryCursor = olderHistoryCursor; self.hasOlder = hasOlder; self.activities = activities
    }

    private enum CodingKeys: String, CodingKey {
        case control, messages, pendingRequests, olderHistoryCursor, hasOlder, activities
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        control = try values.decode(RemoteSessionControl.self, forKey: .control)
        messages = try values.decode([RemoteHistoryMessage].self, forKey: .messages)
        pendingRequests = try values.decode([RemoteApprovalRequest].self, forKey: .pendingRequests)
        olderHistoryCursor = try values.decodeIfPresent(String.self, forKey: .olderHistoryCursor)
        hasOlder = try values.decode(Bool.self, forKey: .hasOlder)
        activities = try values.decodeIfPresent([RemoteToolActivity].self, forKey: .activities) ?? []
    }
}

struct RemoteJournalEvent: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let sessionId: String
    let streamEpoch: String
    let sequence: Int
    let occurredAt: String
    let type: String
    let payload: AgentJSON
}
struct RemoteJournalRecord: Codable, Sendable, Equatable {
    let cursor: String
    let event: RemoteJournalEvent
}
struct RemoteJournalReplay: Sendable {
    let streamEpoch: String
    let afterSequence: Int
    let records: [RemoteJournalRecord]
}
struct RemoteJournalSync: Encodable, Sendable {
    let ref: RemoteSessionRef
    let projection: RemoteSessionProjection
    let streamEpoch: String
    let sequence: Int
    let eventCursor: String
    enum CodingKeys: String, CodingKey {
        case sessionId, executionEpoch, controlRevision, state, controlMode, currentTurnId, allowedActions
        case messages, pendingRequests, activities, olderHistoryCursor, hasOlder, streamEpoch, sequence, eventCursor
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let control = projection.control
        try c.encode(ref.sessionId, forKey: .sessionId)
        try c.encode(control.executionEpoch, forKey: .executionEpoch); try c.encode(control.controlRevision, forKey: .controlRevision)
        try c.encode(control.state, forKey: .state); try c.encode(control.controlMode, forKey: .controlMode)
        try c.encode(control.currentTurnId, forKey: .currentTurnId); try c.encode(control.allowedActions, forKey: .allowedActions)
        try c.encode(projection.messages, forKey: .messages); try c.encode(projection.pendingRequests, forKey: .pendingRequests)
        try c.encode(projection.activities, forKey: .activities)
        try c.encode(projection.olderHistoryCursor, forKey: .olderHistoryCursor); try c.encode(projection.hasOlder, forKey: .hasOlder)
        try c.encode(streamEpoch, forKey: .streamEpoch); try c.encode(sequence, forKey: .sequence); try c.encode(eventCursor, forKey: .eventCursor)
    }
}

enum RemoteJournalMutation: Sendable {
    case message(RemoteHistoryMessage)
    case delta(messageId: String, partId: String, revision: Int, text: String)
    case activity(RemoteToolActivity)
    case control(RemoteSessionControl)
    case approval(RemoteApprovalRequest)
    case resolveApproval(requestId: String, expectedRevision: Int)
    case requireSync(reason: String)
}
enum RemoteJournalError: Error, Equatable {
    case unavailable, incompatibleSchema, invalidProjection, revisionConflict, notFound, cursorExpired, limitExceeded
}

/// Internal trusted-producer storage. The Remote router must separately enforce
/// resource ACL and revalidate the principal before serving sync/replay/each SSE
/// batch. No credentials or vendor file locators are stored here.
/// Projection and replay position are committed in one SQLite transaction.
actor RemoteSessionJournal {
    struct Limits: Sendable {
        var replayCount = 1024
        var replayBytes = 8 * 1024 * 1024
        var replayAge: TimeInterval = 300
        var eventBytes = 1024 * 1024
        var projectionBytes = 8 * 1024 * 1024
    }
    private struct Stored: Codable {
        var projection: RemoteSessionProjection
        let epoch: String
        var sequence: Int
        var cursor: String
    }
    private let databaseURL: URL
    private let limits: Limits
    private var observers: [UUID: (ref: RemoteSessionRef, signal: @Sendable () -> Void)] = [:]

    init(databaseURL: URL, limits: Limits = .init()) throws {
        guard databaseURL.isFileURL, limits.replayCount > 0, limits.replayCount <= 10000,
              limits.replayBytes >= limits.eventBytes, limits.replayBytes <= 256 * 1024 * 1024,
              (1...16 * 1024 * 1024).contains(limits.eventBytes), (1...16 * 1024 * 1024).contains(limits.projectionBytes),
              limits.replayAge.isFinite, limits.replayAge > 0 else { throw RemoteJournalError.limitExceeded }
        self.databaseURL = databaseURL; self.limits = limits
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try Self.database(databaseURL) { db in
            let version = try Self.rows(db, "PRAGMA user_version").first?.integer ?? -1
            guard version == 0 || version == 1 else { throw RemoteJournalError.incompatibleSchema }
            try Self.execute(db, "CREATE TABLE IF NOT EXISTS remote_session_streams (ref TEXT PRIMARY KEY, state BLOB NOT NULL)")
            try Self.execute(db, "CREATE TABLE IF NOT EXISTS remote_session_events (ref TEXT NOT NULL REFERENCES remote_session_streams(ref) ON DELETE CASCADE, sequence INTEGER NOT NULL, cursor TEXT NOT NULL UNIQUE, occurred REAL NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(ref, sequence))")
            try Self.execute(db, "PRAGMA user_version=1")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
    }

    /// A trusted adapter calls replace only for initial indexing or explicit
    /// recovery; replacing a baseline rotates the log epoch and expires old cursors.
    func replace(ref: RemoteSessionRef, projection: RemoteSessionProjection, now: Date = Date()) throws -> RemoteJournalSync {
        try validate(ref, projection)
        guard now.timeIntervalSince1970.isFinite else { throw RemoteJournalError.invalidProjection }
        let state = Stored(projection: projection, epoch: UUID().uuidString, sequence: 0, cursor: UUID().uuidString)
        let encoded = try encode(state)
        guard encoded.count <= limits.projectionBytes else { throw RemoteJournalError.limitExceeded }
        let result = try Self.database(databaseURL) { db in
            try Self.execute(db, "INSERT INTO remote_session_streams(ref,state) VALUES(?,?) ON CONFLICT(ref) DO UPDATE SET state=excluded.state", [.text(ref.key), .blob(encoded)])
            try Self.execute(db, "DELETE FROM remote_session_events WHERE ref=?", [.text(ref.key)])
            try Self.execute(db, "INSERT INTO remote_session_events VALUES(?,?,?,?,?)", [.text(ref.key), .int(0), .text(state.cursor), .real(now.timeIntervalSince1970), .blob(Data())])
            return sync(ref, state)
        }
        notify(ref)
        return result
    }

    func snapshot(ref: RemoteSessionRef) throws -> RemoteJournalSync {
        guard ref.valid else { throw RemoteJournalError.invalidProjection }
        return try Self.database(databaseURL) { db in sync(ref, try load(db, ref)) }
    }

    /// Nil means an exact duplicate/revision was already committed, without
    /// advancing the sequence. Conflicting same-revision values fail explicitly.
    func append(ref: RemoteSessionRef, mutation: RemoteJournalMutation, now: Date = Date()) throws -> RemoteJournalRecord? {
        try append(ref: ref, mutations: [mutation], now: now).first
    }

    /// All projections of one upstream event are committed together. A sync can
    /// see the state before or after the batch, never a partial turn completion.
    func append(ref: RemoteSessionRef, mutations: [RemoteJournalMutation], expectedStreamEpoch: String? = nil,
                expectedSequence: Int? = nil, now: Date = Date()) throws -> [RemoteJournalRecord] {
        guard ref.valid, now.timeIntervalSince1970.isFinite else { throw RemoteJournalError.invalidProjection }
        guard mutations.count <= 256 else { throw RemoteJournalError.limitExceeded }
        let result = try Self.database(databaseURL) { db in
            var state = try load(db, ref)
            guard expectedStreamEpoch.map({ $0 == state.epoch }) ?? true,
                  expectedSequence.map({ $0 == state.sequence }) ?? true else { throw RemoteJournalError.revisionConflict }
            return try commit(db, ref: ref, state: &state, mutations: mutations, now: now)
        }
        if !result.isEmpty { notify(ref) }
        return result
    }

    /// Fault handling reads the latest projection inside the same transaction;
    /// a stale reader cannot re-enable live status or overwrite newer text.
    func requireSync(ref: RemoteSessionRef, expectedStreamEpoch: String, reason: String, now: Date = Date()) throws -> [RemoteJournalRecord] {
        guard ref.valid, now.timeIntervalSince1970.isFinite else { throw RemoteJournalError.invalidProjection }
        let result = try Self.database(databaseURL) { db in
            var state = try load(db, ref)
            guard state.epoch == expectedStreamEpoch else { throw RemoteJournalError.revisionConflict }
            let previous = state.projection.control
            let unavailable = RemoteSessionControl(executionEpoch: previous.executionEpoch, controlRevision: previous.controlRevision + 1,
                state: "unknown", controlMode: "unavailable", currentTurnId: nil, allowedActions: [])
            return try commit(db, ref: ref, state: &state, mutations: [.control(unavailable), .requireSync(reason: reason)], now: now)
        }
        notify(ref)
        return result
    }

    private func commit(_ db: OpaquePointer, ref: RemoteSessionRef, state: inout Stored,
                        mutations: [RemoteJournalMutation], now: Date) throws -> [RemoteJournalRecord] {
            var records: [RemoteJournalRecord] = []
            for mutation in mutations {
                guard let (type, payload) = try apply(mutation, to: &state.projection) else { continue }
                guard state.sequence < 9_007_199_254_740_991 else { throw RemoteJournalError.limitExceeded }
                state.sequence += 1; state.cursor = UUID().uuidString
                let event = RemoteJournalEvent(schemaVersion: 1, sessionId: ref.sessionId, streamEpoch: state.epoch,
                    sequence: state.sequence, occurredAt: ISO8601DateFormatter().string(from: now), type: type, payload: payload)
                let eventData = try encode(event)
                guard eventData.count <= limits.eventBytes else { throw RemoteJournalError.limitExceeded }
                try Self.execute(db, "INSERT INTO remote_session_events VALUES(?,?,?,?,?)", [.text(ref.key), .int(state.sequence), .text(state.cursor), .real(now.timeIntervalSince1970), .blob(eventData)])
                records.append(.init(cursor: state.cursor, event: event))
            }
            try validate(ref, state.projection)
            let stateData = try encode(state)
            guard stateData.count <= limits.projectionBytes else { throw RemoteJournalError.limitExceeded }
            try Self.execute(db, "UPDATE remote_session_streams SET state=? WHERE ref=?", [.blob(stateData), .text(ref.key)])
            try prune(db, ref: ref, now: now)
            return records
    }

    func replay(ref: RemoteSessionRef, after cursor: String, limit: Int = 128, now: Date = Date()) throws -> [RemoteJournalRecord] {
        try replayWindow(ref: ref, after: cursor, limit: limit, now: now).records
    }
    func replayWindow(ref: RemoteSessionRef, after cursor: String, limit: Int = 128, now: Date = Date()) throws -> RemoteJournalReplay {
        guard ref.valid, !cursor.isEmpty, cursor.utf8.count <= 256, (1...256).contains(limit),
              now.timeIntervalSince1970.isFinite else { throw RemoteJournalError.invalidProjection }
        return try Self.database(databaseURL) { db in
            let state = try load(db, ref)
            // A fresh sync at the current head remains valid even on an idle log.
            if cursor == state.cursor { return .init(streamEpoch: state.epoch, afterSequence: state.sequence, records: []) }
            guard let position = try Self.rows(db, "SELECT sequence,occurred FROM remote_session_events WHERE ref=? AND cursor=?", [.text(ref.key), .text(cursor)]).first,
                  position.integer >= 0, position.integer < state.sequence,
                  position.real >= now.timeIntervalSince1970 - limits.replayAge else { throw RemoteJournalError.cursorExpired }
            let rows = try Self.rows(db, "SELECT sequence,payload,cursor FROM remote_session_events WHERE ref=? AND sequence>? ORDER BY sequence LIMIT ?", [.text(ref.key), .int(position.integer), .int(limit)])
            var expected = position.integer + 1
            var records: [RemoteJournalRecord] = []
            for row in rows {
                guard row.integer == expected, let data = row.blob, let token = row.text else { throw RemoteJournalError.cursorExpired }
                let event = try JSONDecoder().decode(RemoteJournalEvent.self, from: data)
                guard event.sequence == expected, event.streamEpoch == state.epoch, event.sessionId == ref.sessionId else { throw RemoteJournalError.cursorExpired }
                records.append(.init(cursor: token, event: event)); expected += 1
            }
            guard !records.isEmpty || position.integer == state.sequence else { throw RemoteJournalError.cursorExpired }
            return .init(streamEpoch: state.epoch, afterSequence: position.integer, records: records)
        }
    }
    /// Install a coalescing wake-up hint atomically with validating the start
    /// position. Consumers read durable replay; hints never carry private content.
    func observe(ref: RemoteSessionRef, after cursor: String, signal: @escaping @Sendable () -> Void) throws -> (UUID, RemoteJournalReplay) {
        guard observers.count < 64 else { throw RemoteJournalError.limitExceeded }
        let initial = try replayWindow(ref: ref, after: cursor)
        let id = UUID()
        observers[id] = (ref, signal)
        return (id, initial)
    }
    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func notify(_ ref: RemoteSessionRef) {
        for observer in observers.values where observer.ref == ref { observer.signal() }
    }

    private func sync(_ ref: RemoteSessionRef, _ state: Stored) -> RemoteJournalSync {
        .init(ref: ref, projection: state.projection, streamEpoch: state.epoch, sequence: state.sequence, eventCursor: state.cursor)
    }
    private func load(_ db: OpaquePointer, _ ref: RemoteSessionRef) throws -> Stored {
        guard let data = try Self.rows(db, "SELECT state FROM remote_session_streams WHERE ref=?", [.text(ref.key)]).first?.blob else { throw RemoteJournalError.notFound }
        let state = try JSONDecoder().decode(Stored.self, from: data)
        try validate(ref, state.projection)
        guard !state.epoch.isEmpty, !state.cursor.isEmpty, state.sequence >= 0 else { throw RemoteJournalError.invalidProjection }
        return state
    }
    private func prune(_ db: OpaquePointer, ref: RemoteSessionRef, now: Date) throws {
        let rows = try Self.rows(db, "SELECT sequence,occurred,length(payload) FROM remote_session_events WHERE ref=? ORDER BY sequence DESC", [.text(ref.key)])
        var bytes = 0, count = 0
        for row in rows {
            count += 1; bytes += row.thirdInteger
            if count > limits.replayCount || bytes > limits.replayBytes || row.real < now.timeIntervalSince1970 - limits.replayAge {
                try Self.execute(db, "DELETE FROM remote_session_events WHERE ref=? AND sequence<=?", [.text(ref.key), .int(row.integer)])
                break
            }
        }
    }
    private func json<T: Encodable>(_ value: T) throws -> AgentJSON { try JSONDecoder().decode(AgentJSON.self, from: encode(value)) }
    private func encode<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }

    private func apply(_ mutation: RemoteJournalMutation, to projection: inout RemoteSessionProjection) throws -> (String, AgentJSON)? {
        switch mutation {
        case .message(let message):
            if let index = projection.messages.firstIndex(where: { $0.messageId == message.messageId }) {
                let previous = projection.messages[index]
                if message == previous { return nil }
                guard message.messageRevision > previous.messageRevision, message.turnId == previous.turnId,
                      message.role == previous.role, message.createdAt == previous.createdAt else { throw RemoteJournalError.revisionConflict }
                projection.messages[index] = message
            } else { projection.messages.append(message) }
            return (message.status == "completed" ? "message.completed" : "message.created", try json(message))
        case .delta(let id, let partId, let revision, let text):
            guard let index = projection.messages.firstIndex(where: { $0.messageId == id }),
                  let partIndex = projection.messages[index].content.firstIndex(where: { $0.partId == partId && $0.type == "text" }) else { throw RemoteJournalError.revisionConflict }
            let previous = projection.messages[index]
            guard previous.status == "streaming", revision == previous.messageRevision + 1 else { throw RemoteJournalError.revisionConflict }
            var parts = previous.content
            parts[partIndex] = .init(partId: partId, type: "text", text: parts[partIndex].text + text)
            projection.messages[index] = .init(messageId: id, turnId: previous.turnId, messageRevision: revision, role: previous.role,
                createdAt: previous.createdAt, status: previous.status, content: parts)
            return ("message.delta", .object(["messageId": .string(id), "partId": .string(partId), "messageRevision": .integer(Int64(revision)), "delta": .string(text)]))
        case .activity(let activity):
            if let index = projection.activities.firstIndex(where: { $0.activityId == activity.activityId }) {
                let previous = projection.activities[index]
                if activity == previous { return nil }
                guard activity.activityRevision == previous.activityRevision + 1, activity.turnId == previous.turnId,
                      activity.kind == previous.kind, activity.createdAt == previous.createdAt,
                      ["running", "unknown"].contains(previous.status),
                      activity.status != previous.status, activity.status != "running" else { throw RemoteJournalError.revisionConflict }
                projection.activities[index] = activity
                return ("activity.updated", try json(activity))
            }
            projection.activities.append(activity)
            return ("activity.created", try json(activity))
        case .control(let control):
            if control == projection.control { return nil }
            guard control.executionEpoch != projection.control.executionEpoch || control.controlRevision > projection.control.controlRevision else { throw RemoteJournalError.revisionConflict }
            if control.executionEpoch != projection.control.executionEpoch { projection.pendingRequests.removeAll() }
            else { projection.pendingRequests.removeAll { $0.turnId != control.currentTurnId } }
            projection.control = control
            return ("session.updated", try json(control))
        case .approval(let request):
            guard request.executionEpoch == projection.control.executionEpoch, request.turnId == projection.control.currentTurnId else { throw RemoteJournalError.revisionConflict }
            if let index = projection.pendingRequests.firstIndex(where: { $0.requestId == request.requestId }) {
                if projection.pendingRequests[index] == request { return nil }
                guard request.requestRevision > projection.pendingRequests[index].requestRevision else { throw RemoteJournalError.revisionConflict }
                projection.pendingRequests[index] = request
            } else { projection.pendingRequests.append(request) }
            return ("approval.requested", try json(request))
        case .resolveApproval(let id, let revision):
            guard let index = projection.pendingRequests.firstIndex(where: { $0.requestId == id }),
                  projection.pendingRequests[index].requestRevision == revision else { throw RemoteJournalError.revisionConflict }
            projection.pendingRequests.remove(at: index)
            return ("approval.resolved", .object(["requestId": .string(id), "requestRevision": .integer(Int64(revision + 1))]))
        case .requireSync(let reason):
            guard !reason.isEmpty, reason.utf8.count <= 128, !reason.contains("\0") else { throw RemoteJournalError.invalidProjection }
            return ("sync.required", .object(["reason": .string(reason)]))
        }
    }

    private func validate(_ ref: RemoteSessionRef, _ projection: RemoteSessionProjection) throws {
        let c = projection.control
        guard ref.valid, !c.executionEpoch.isEmpty, (0..<9_007_199_254_740_991).contains(c.controlRevision),
              ["idle", "running", "waitingForUser", "completed", "interrupted", "failed", "unknown"].contains(c.state),
              ["readOnly", "live", "resumable", "unavailable"].contains(c.controlMode),
              c.allowedActions.allSatisfy({ RemoteAction(rawValue: $0) != nil }),
              (c.controlMode != "readOnly" || c.allowedActions.allSatisfy({ $0 == "history.read" })),
              projection.messages.count <= 1000, projection.pendingRequests.count <= 128, projection.activities.count <= 1000,
              Set(projection.messages.map(\.messageId)).count == projection.messages.count,
              Set(projection.pendingRequests.map(\.requestId)).count == projection.pendingRequests.count,
              Set(projection.activities.map(\.activityId)).count == projection.activities.count,
              projection.hasOlder == (projection.olderHistoryCursor != nil) else { throw RemoteJournalError.invalidProjection }
        for message in projection.messages {
            guard !message.messageId.isEmpty, (0..<9_007_199_254_740_991).contains(message.messageRevision),
                  ["user", "assistant"].contains(message.role), ["streaming", "completed", "failed", "interrupted"].contains(message.status),
                  validDate(message.createdAt),
                  message.content.count <= 128, Set(message.content.map(\.partId)).count == message.content.count,
                  message.content.allSatisfy({ !$0.partId.isEmpty && ["text", "unsupported"].contains($0.type) }) else { throw RemoteJournalError.invalidProjection }
        }
        for activity in projection.activities {
            guard !activity.activityId.isEmpty, activity.activityId.utf8.count <= 160,
                  !activity.turnId.isEmpty, activity.turnId.utf8.count <= 160,
                  (1..<9_007_199_254_740_991).contains(activity.activityRevision),
                  ["command", "fileChange", "mcpTool", "dynamicTool", "collabTool", "webSearch", "imageView", "imageGeneration"].contains(activity.kind),
                  ["running", "completed", "failed", "unknown"].contains(activity.status),
                  validDate(activity.createdAt) else { throw RemoteJournalError.invalidProjection }
        }
        for request in projection.pendingRequests {
            guard !request.requestId.isEmpty, (0..<9_007_199_254_740_991).contains(request.requestRevision), request.type == "approval",
                  request.executionEpoch == c.executionEpoch, request.turnId == c.currentTurnId, !request.summary.isEmpty,
                  !request.allowedDecisions.isEmpty, request.allowedDecisions.allSatisfy({ ["accept", "decline", "cancel"].contains($0) }),
                  validDate(request.expiresAt) else { throw RemoteJournalError.invalidProjection }
        }
    }
    private func validDate(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) != nil
    }

    private enum Binding { case text(String), blob(Data), int(Int), real(Double) }
    private struct Row { var integer = 0; var real = 0.0; var thirdInteger = 0; var blob: Data?; var text: String? }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static func database<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db = pointer else {
            if let pointer { sqlite3_close(pointer) }; throw RemoteJournalError.unavailable
        }
        defer { sqlite3_close(db) }
        // Set the main file mode before enabling WAL so newly created sidecars
        // inherit private permissions; also repair modes of existing sidecars.
        for path in [url.path, url.path + "-wal", url.path + "-shm"] where FileManager.default.fileExists(atPath: path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
        sqlite3_busy_timeout(db, 1000)
        try execute(db, "PRAGMA foreign_keys=ON"); try execute(db, "PRAGMA journal_mode=WAL"); try execute(db, "PRAGMA synchronous=FULL")
        try execute(db, "BEGIN IMMEDIATE")
        do { let result = try body(db); try execute(db, "COMMIT"); return result }
        catch { try? execute(db, "ROLLBACK"); throw error }
    }
    private static func statement(_ db: OpaquePointer, _ sql: String, _ bindings: [Binding]) throws -> OpaquePointer {
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &pointer, nil) == SQLITE_OK, let pointer else { throw RemoteJournalError.unavailable }
        for (index, value) in bindings.enumerated() {
            let slot = Int32(index + 1)
            let result: Int32
            switch value {
            case .text(let text): result = sqlite3_bind_text(pointer, slot, text, -1, transient)
            case .blob(let data):
                result = data.isEmpty ? sqlite3_bind_zeroblob(pointer, slot, 0) : data.withUnsafeBytes { sqlite3_bind_blob(pointer, slot, $0.baseAddress, Int32(data.count), transient) }
            case .int(let integer): result = sqlite3_bind_int64(pointer, slot, Int64(integer))
            case .real(let real): result = sqlite3_bind_double(pointer, slot, real)
            }
            guard result == SQLITE_OK else { sqlite3_finalize(pointer); throw RemoteJournalError.unavailable }
        }
        return pointer
    }
    private static func execute(_ db: OpaquePointer, _ sql: String, _ bindings: [Binding] = []) throws {
        let stmt = try statement(db, sql, bindings); defer { sqlite3_finalize(stmt) }
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW { result = sqlite3_step(stmt) }
        guard result == SQLITE_DONE else { throw RemoteJournalError.unavailable }
    }
    private static func rows(_ db: OpaquePointer, _ sql: String, _ bindings: [Binding] = []) throws -> [Row] {
        let stmt = try statement(db, sql, bindings); defer { sqlite3_finalize(stmt) }
        var rows: [Row] = []
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW {
            var row = Row()
            for column in 0..<sqlite3_column_count(stmt) {
                switch sqlite3_column_type(stmt, column) {
                case SQLITE_INTEGER:
                    if column == 0 { row.integer = Int(sqlite3_column_int64(stmt, column)) }
                    if column == 2 { row.thirdInteger = Int(sqlite3_column_int64(stmt, column)) }
                case SQLITE_FLOAT: row.real = sqlite3_column_double(stmt, column)
                case SQLITE_TEXT: if let value = sqlite3_column_text(stmt, column) { row.text = String(cString: value) }
                case SQLITE_BLOB:
                    if let bytes = sqlite3_column_blob(stmt, column) { row.blob = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, column))) }
                    else { row.blob = Data() }
                default: break
                }
            }
            rows.append(row); result = sqlite3_step(stmt)
        }
        guard result == SQLITE_DONE else { throw RemoteJournalError.unavailable }
        return rows
    }
}
