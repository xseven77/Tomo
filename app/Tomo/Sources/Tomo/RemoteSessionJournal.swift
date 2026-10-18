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

struct RemoteQuestionOption: Codable, Equatable, Sendable {
    let optionId: String
    let label: String
    let description: String
}

struct RemoteRequestQuestion: Codable, Equatable, Sendable {
    let questionId: String
    let header: String
    let prompt: String
    let options: [RemoteQuestionOption]
    let allowsFreeText: Bool
    let isSecret: Bool
}

/// Reviewable, single-command scope. File and permission scopes use separate
/// complete models rather than being reduced to command approval.
struct RemoteCommandApproval: Codable, Equatable, Sendable {
    let command: String
    let cwd: String
    let reason: String?
}

struct RemoteFileChange: Codable, Equatable, Sendable {
    let path: String
    let kind: String
    let movePath: String?
    let diff: String
}

/// Complete proposed changes, never a truncated preview. grantRoot requests
/// write access for the remainder of the session and must be shown as such.
struct RemoteFileApproval: Codable, Equatable, Sendable {
    let changes: [RemoteFileChange]
    let reason: String?
    let grantRoot: String?
    var valid: Bool {
        func text(_ s: String, empty: Bool = false, limit: Int = 4096) -> Bool {
            (empty || !s.isEmpty) && !s.contains("\0") && s.utf8.count <= limit
        }
        return (1...128).contains(changes.count) && Set(changes.map(\.path)).count == changes.count
            && changes.allSatisfy { change in
                text(change.path) && ["add", "delete", "update"].contains(change.kind)
                    && (change.movePath.map { change.kind == "update" && text($0) } ?? true)
                    && text(change.diff, empty: true, limit: 512 * 1024)
            } && (reason.map { text($0, empty: true, limit: 16_384) } ?? true)
            && (grantRoot.map { text($0) } ?? true)
            && ((try? JSONEncoder().encode(self).count) ?? Int.max) <= 512 * 1024
    }
}

/// Finite UI data, never a vendor RPC envelope. The journal persists questions,
/// not submitted answers. Raw request/question IDs remain in the runtime adapter.
struct RemotePendingRequest: Codable, Equatable, Sendable {
    let requestId: String
    let requestRevision: Int
    let type: String
    let executionEpoch: String
    let turnId: String
    let summary: String
    let allowedDecisions: [String]
    let expiresAt: String
    let questions: [RemoteRequestQuestion]
    let commandApproval: RemoteCommandApproval?
    let fileApproval: RemoteFileApproval?
    let permissionApproval: RemotePermissionApproval?
    let isBlocking: Bool

    init(requestId: String, requestRevision: Int, type: String, executionEpoch: String,
         turnId: String, summary: String, allowedDecisions: [String] = [], expiresAt: String,
         questions: [RemoteRequestQuestion] = [], commandApproval: RemoteCommandApproval? = nil, fileApproval: RemoteFileApproval? = nil,
         permissionApproval: RemotePermissionApproval? = nil,
         isBlocking: Bool = true) {
        self.requestId = requestId; self.requestRevision = requestRevision; self.type = type
        self.executionEpoch = executionEpoch; self.turnId = turnId; self.summary = summary
        self.allowedDecisions = allowedDecisions; self.expiresAt = expiresAt
        self.questions = questions; self.commandApproval = commandApproval; self.fileApproval = fileApproval; self.isBlocking = isBlocking
        self.permissionApproval = permissionApproval
    }

    private enum CodingKeys: String, CodingKey {
        case requestId, requestRevision, type, executionEpoch, turnId, summary, allowedDecisions, expiresAt
        case questions, commandApproval, fileApproval, permissionApproval, isBlocking
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(requestId: try c.decode(String.self, forKey: .requestId),
            requestRevision: try c.decode(Int.self, forKey: .requestRevision), type: try c.decode(String.self, forKey: .type),
            executionEpoch: try c.decode(String.self, forKey: .executionEpoch), turnId: try c.decode(String.self, forKey: .turnId),
            summary: try c.decode(String.self, forKey: .summary), allowedDecisions: try c.decode([String].self, forKey: .allowedDecisions),
            expiresAt: try c.decode(String.self, forKey: .expiresAt),
            questions: try c.decodeIfPresent([RemoteRequestQuestion].self, forKey: .questions) ?? [],
            commandApproval: try c.decodeIfPresent(RemoteCommandApproval.self, forKey: .commandApproval),
            fileApproval: try c.decodeIfPresent(RemoteFileApproval.self, forKey: .fileApproval),
            permissionApproval: try c.decodeIfPresent(RemotePermissionApproval.self, forKey: .permissionApproval),
            isBlocking: try c.decodeIfPresent(Bool.self, forKey: .isBlocking) ?? true)
    }

    var validContent: Bool {
        func text(_ value: String, limit: Int, empty: Bool = false) -> Bool {
            (empty || !value.isEmpty) && value.utf8.count <= limit && !value.contains("\0")
        }
        guard text(requestId, limit: 256), text(summary, limit: 16_384),
              Set(allowedDecisions).count == allowedDecisions.count else { return false }
        switch type {
        case "approval":
            guard questions.isEmpty, isBlocking, !allowedDecisions.isEmpty,
                  allowedDecisions.allSatisfy({ ["accept", "acceptForSession", "decline", "cancel"].contains($0) }),
                  [commandApproval != nil, fileApproval != nil, permissionApproval != nil].filter({ $0 }).count <= 1 else { return false }
            if let permissionApproval {
                return permissionApproval.valid && !allowedDecisions.contains("cancel")
                    && (!permissionApproval.permissions.hasUnknownRange || allowedDecisions.allSatisfy({ $0 == "decline" }))
            }
            if let fileApproval { return fileApproval.valid }
            guard !allowedDecisions.contains("acceptForSession") else { return false }
            if let commandApproval {
                return text(commandApproval.command, limit: 32_768) && text(commandApproval.cwd, limit: 4096)
                    && (commandApproval.reason.map { text($0, limit: 16_384, empty: true) } ?? true)
            }
            return true // Older local journal records have summary-only approvals.
        case "question":
            guard commandApproval == nil, fileApproval == nil, permissionApproval == nil, allowedDecisions.isEmpty, (1...16).contains(questions.count),
                  Set(questions.map(\.questionId)).count == questions.count else { return false }
            return questions.allSatisfy { q in
                text(q.questionId, limit: 256) && text(q.header, limit: 1024, empty: true)
                    && text(q.prompt, limit: 16_384) && q.options.count <= 32
                    && (!q.options.isEmpty || q.allowsFreeText)
                    && Set(q.options.map(\.optionId)).count == q.options.count
                    && q.options.allSatisfy { text($0.optionId, limit: 256) && text($0.label, limit: 4096)
                        && text($0.description, limit: 8192, empty: true) }
            }
        default: return false
        }
    }
}

typealias RemoteApprovalRequest = RemotePendingRequest

/// An opaque activity identity plus an optional bounded user-visible text view.
/// Private vendor arguments, routing IDs and hidden reasoning remain absent.
struct RemoteToolActivity: Codable, Equatable, Sendable {
    let activityId: String
    let turnId: String
    let activityRevision: Int
    let kind: String
    let status: String
    let createdAt: String
    let presentation: RemoteToolPresentation?

    init(activityId: String, turnId: String, activityRevision: Int, kind: String, status: String, createdAt: String,
         presentation: RemoteToolPresentation? = nil) {
        self.activityId = activityId; self.turnId = turnId; self.activityRevision = activityRevision
        self.kind = kind; self.status = status; self.createdAt = createdAt; self.presentation = presentation
    }
}

struct RemoteSessionProjection: Codable, Equatable, Sendable {
    var control: RemoteSessionControl
    var messages: [RemoteHistoryMessage]
    var pendingRequests: [RemotePendingRequest]
    var olderHistoryCursor: String?
    var hasOlder: Bool
    var activities: [RemoteToolActivity]
    // Trusted baseline import only; never encoded into projection or sync/SSE.
    var toolResults: [String: RemoteToolResultText] = [:]

    init(control: RemoteSessionControl, messages: [RemoteHistoryMessage], pendingRequests: [RemotePendingRequest],
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
        pendingRequests = try values.decode([RemotePendingRequest].self, forKey: .pendingRequests)
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
    // Trusted paging metadata captured in the same transaction as control and
    // the replay head. Never encoded into sync/SSE or accepted from a client.
    var historySnapshot: RemoteMessageArchive.Snapshot? = nil
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
    case toolResult(activityId: String, result: RemoteToolResultText)
    case control(RemoteSessionControl)
    case approval(RemoteApprovalRequest)
    case resolveApproval(requestId: String, expectedRevision: Int)
    case question(RemotePendingRequest)
    case resolveQuestion(requestId: String, expectedRevision: Int)
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
        var toolResultBytes = 128 * 1024 * 1024
        var toolResultCount = 8192
    }
    private struct Stored: Codable {
        var projection: RemoteSessionProjection
        let epoch: String
        var sequence: Int
        var cursor: String
    }
    private let databaseURL: URL
    nonisolated var storageIdentity: URL {databaseURL.resolvingSymlinksInPath().standardizedFileURL}
    private let limits: Limits
    private var observers: [UUID: (ref: RemoteSessionRef, signal: @Sendable () -> Void)] = [:]

    init(databaseURL: URL, limits: Limits = .init()) throws {
        guard databaseURL.isFileURL, limits.replayCount > 0, limits.replayCount <= 10000,
              limits.replayBytes >= limits.eventBytes, limits.replayBytes <= 256 * 1024 * 1024,
              (1...16 * 1024 * 1024).contains(limits.eventBytes), (1...16 * 1024 * 1024).contains(limits.projectionBytes),
              (RemoteToolResultText.byteLimit...512 * 1024 * 1024).contains(limits.toolResultBytes),
              (1...20000).contains(limits.toolResultCount),
              limits.replayAge.isFinite, limits.replayAge > 0 else { throw RemoteJournalError.limitExceeded }
        self.databaseURL = databaseURL; self.limits = limits
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try Self.database(databaseURL) { db in
            let version = try Self.rows(db, "PRAGMA user_version").first?.integer ?? -1
            guard (0...2).contains(version) else { throw RemoteJournalError.incompatibleSchema }
            try Self.execute(db, "CREATE TABLE IF NOT EXISTS remote_session_streams (ref TEXT PRIMARY KEY, state BLOB NOT NULL)")
            try Self.execute(db, "CREATE TABLE IF NOT EXISTS remote_session_events (ref TEXT NOT NULL REFERENCES remote_session_streams(ref) ON DELETE CASCADE, sequence INTEGER NOT NULL, cursor TEXT NOT NULL UNIQUE, occurred REAL NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(ref, sequence))")
            try Self.execute(db, "CREATE TABLE IF NOT EXISTS remote_tool_results (ref TEXT NOT NULL REFERENCES remote_session_streams(ref) ON DELETE CASCADE, activity TEXT NOT NULL, version TEXT NOT NULL, content BLOB NOT NULL, truncated INTEGER NOT NULL, PRIMARY KEY(ref,activity))")
            try RemoteMessageArchive.create(db)
            if version < 2 {
                // Migrate the original complete projection atomically. A failed
                // decode/import leaves both the old data and version intact.
                for row in try Self.rows(db, "SELECT ref,state FROM remote_session_streams") {
                    guard let key = row.text, let data = row.blob else { throw RemoteJournalError.invalidProjection }
                    let parts = try JSONDecoder().decode([String].self, from: Data(key.utf8))
                    guard parts.count == 4 else { throw RemoteJournalError.invalidProjection }
                    let ref = RemoteSessionRef(serverId: parts[0], agentId: parts[1], runtimeId: parts[2], sessionId: parts[3])
                    var state = try JSONDecoder().decode(Stored.self, from: data)
                    try validate(ref, state.projection)
                    try RemoteMessageArchive.reset(db, ref: key, messages: state.projection.messages)
                    Self.compactMessages(&state.projection)
                    try Self.execute(db, "UPDATE remote_session_streams SET state=? WHERE ref=?", [.blob(try JSONEncoder().encode(state)), .text(key)])
                }
                try Self.execute(db, "PRAGMA user_version=2")
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
    }

    /// A trusted adapter calls replace only for initial indexing or explicit
    /// recovery; replacing a baseline rotates the log epoch and expires old cursors.
    func replace(ref: RemoteSessionRef, projection: RemoteSessionProjection, now: Date = Date()) throws -> RemoteJournalSync {
        try validate(ref, projection, maximumMessages: 10000)
        var projection = projection
        let toolResults = projection.toolResults
        projection.toolResults = [:]
        projection.activities = RemoteToolPresentation.compact(projection.activities)
        guard now.timeIntervalSince1970.isFinite else { throw RemoteJournalError.invalidProjection }
        guard try encode(projection).count <= limits.projectionBytes else { throw RemoteJournalError.limitExceeded }
        let messages = projection.messages
        Self.compactMessages(&projection)
        try validate(ref, projection)
        let state = Stored(projection: projection, epoch: UUID().uuidString, sequence: 0, cursor: UUID().uuidString)
        let encoded = try encode(state)
        guard encoded.count <= limits.projectionBytes else { throw RemoteJournalError.limitExceeded }
        let result = try Self.database(databaseURL) { db in
            try Self.execute(db, "INSERT INTO remote_session_streams(ref,state) VALUES(?,?) ON CONFLICT(ref) DO UPDATE SET state=excluded.state", [.text(ref.key), .blob(encoded)])
            try RemoteMessageArchive.reset(db, ref: ref.key, messages: messages)
            try Self.execute(db, "DELETE FROM remote_tool_results WHERE ref=?", [.text(ref.key)])
            for (id, result) in toolResults {
                try storeToolResult(db, ref: ref, activityId: id, result: result, projection: projection)
            }
            try pruneToolResults(db)
            try Self.execute(db, "DELETE FROM remote_session_events WHERE ref=?", [.text(ref.key)])
            try Self.execute(db, "INSERT INTO remote_session_events VALUES(?,?,?,?,?)", [.text(ref.key), .int(0), .text(state.cursor), .real(now.timeIntervalSince1970), .blob(Data())])
            var result = sync(ref, state)
            result.historySnapshot = try RemoteMessageArchive.capture(db, ref: ref.key, epoch: state.epoch, sequence: state.sequence, now: now)
            return result
        }
        notify(ref)
        return result
    }

    func snapshot(ref: RemoteSessionRef, includeHistorySnapshot: Bool = false, now: Date = Date()) throws -> RemoteJournalSync {
        guard ref.valid, now.timeIntervalSince1970.isFinite else { throw RemoteJournalError.invalidProjection }
        return try Self.database(databaseURL) { db in
            let state = try load(db, ref)
            var result = sync(ref, state)
            if includeHistorySnapshot {
                result.historySnapshot = try RemoteMessageArchive.capture(db, ref: ref.key, epoch: state.epoch, sequence: state.sequence, now: now)
            }
            return result
        }
    }

    func historySnapshot(ref: RemoteSessionRef, epoch: String? = nil, sequence: Int? = nil, now: Date = Date()) throws -> RemoteMessageArchive.Snapshot {
        guard ref.valid, now.timeIntervalSince1970.isFinite else { throw RemoteJournalError.invalidProjection }
        return try Self.database(databaseURL) { db in
            let state = try load(db, ref)
            guard epoch.map({$0 == state.epoch}) ?? true, sequence.map({$0 == state.sequence}) ?? true else { throw RolloutHistoryError.snapshotChanged }
            return try RemoteMessageArchive.capture(db, ref: ref.key, epoch: state.epoch, sequence: state.sequence, now: now)
        }
    }
    func historyWindow(ref: RemoteSessionRef, snapshot: RemoteMessageArchive.Snapshot, before: UInt64?, limit: Int,
                       retainingTurn: String? = nil, maximumBytes: Int, now: Date = Date()) throws -> RolloutHistoryWindow {
        guard ref.valid, now.timeIntervalSince1970.isFinite else { throw RemoteJournalError.invalidProjection }
        return try Self.database(databaseURL) { db in
            // Replacement removes the old snapshots in its own transaction.
            // Check the epoch too, including when separate actors share a DB.
            let state = try load(db, ref)
            guard state.epoch == snapshot.epoch else { throw RolloutHistoryError.snapshotChanged }
            return try RemoteMessageArchive.window(db, ref: ref.key, snapshot: snapshot, before: before, limit: limit,
                retainingTurn: retainingTurn, maximumBytes: maximumBytes, now: now)
        }
    }

    /// Authorized routing lives in RemoteSessionService. Offset/version are
    /// internal; public clients receive an owner/source-bound opaque cursor.
    func toolResultPage(ref: RemoteSessionRef, activityId: String, version: String? = nil, offset: Int = 0) throws -> RemoteToolResultPage {
        guard ref.valid, !activityId.isEmpty, activityId.utf8.count <= 160, !activityId.contains("\0"),
              (0..<RemoteToolResultText.byteLimit).contains(offset) else {
            throw RemoteJournalError.invalidProjection
        }
        return try Self.database(databaseURL) { db in
            // Only terminal activities can enter this table; baseline replacement
            // clears it atomically. Read a bounded SQLite BLOB slice, not the full
            // result and transcript on every page (quadratic for long output).
            guard let row = try Self.rows(db, "SELECT truncated,substr(content,?,8192),version,length(content) FROM remote_tool_results WHERE ref=? AND activity=?",
                    [.int(offset + 1), .text(ref.key), .text(activityId)]).first,
                  let data = row.blob, let storedVersion = row.text else { throw RemoteJournalError.notFound }
            guard (1...RemoteToolResultText.byteLimit).contains(row.fourthInteger),
                  storedVersion.count == 64, storedVersion.allSatisfy({ $0.isHexDigit }), [0, 1].contains(row.integer) else {
                throw RemoteJournalError.invalidProjection
            }
            guard version == nil || version == storedVersion else { throw RemoteJournalError.cursorExpired }
            guard offset < row.fourthInteger else { throw RemoteJournalError.cursorExpired }
            var chunk = data
            for _ in 0..<3 where String(data: chunk, encoding: .utf8) == nil { chunk.removeLast() }
            guard let text = String(data: chunk, encoding: .utf8), !text.isEmpty, !text.contains("\0") else { throw RemoteJournalError.cursorExpired }
            return .init(activityId: activityId, resultVersion: storedVersion, text: String(decoding: chunk, as: UTF8.self),
                utf8Offset: offset, totalUTF8Bytes: row.fourthInteger, truncated: row.integer != 0, nextCursor: nil)
        }
    }

    private func storeToolResult(_ db: OpaquePointer, ref: RemoteSessionRef, activityId: String,
                                 result: RemoteToolResultText, projection: RemoteSessionProjection) throws {
        guard result.valid, projection.activities.contains(where: {
            $0.activityId == activityId && ["completed", "failed"].contains($0.status)
        }) else { throw RemoteJournalError.invalidProjection }
        try Self.execute(db, "INSERT INTO remote_tool_results(ref,activity,version,content,truncated) VALUES(?,?,?,?,?) ON CONFLICT(ref,activity) DO UPDATE SET version=excluded.version,content=excluded.content,truncated=excluded.truncated",
            [.text(ref.key), .text(activityId), .text(result.version), .blob(Data(result.text.utf8)), .int(result.truncated ? 1 : 0)])
    }

    private func pruneToolResults(_ db: OpaquePointer) throws {
        let rows = try Self.rows(db, "SELECT rowid,0,length(content) FROM remote_tool_results ORDER BY rowid DESC")
        var bytes = 0
        for (index, row) in rows.enumerated() {
            bytes += row.thirdInteger
            if bytes > limits.toolResultBytes || index >= limits.toolResultCount {
                try Self.execute(db, "DELETE FROM remote_tool_results WHERE rowid<=?", [.int(row.integer)])
                break
            }
        }
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
        // A tool now has a public activity plus a private text-archive write.
        // Preserve the existing 256 public-mutation ceiling instead of halving
        // the number of tools accepted in a complete turn event.
        let publicCount = mutations.reduce(0) { count, mutation in
            if case .toolResult = mutation { return count }; return count + 1
        }
        guard mutations.count <= 512, publicCount <= 256 else { throw RemoteJournalError.limitExceeded }
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
            var archived = false
            for mutation in mutations {
                if case .toolResult(let id, let result) = mutation {
                    try storeToolResult(db, ref: ref, activityId: id, result: result, projection: state.projection)
                    archived = true
                    continue
                }
                // A late full revision may refer to an archived message. Load
                // only that row to enforce the same immutable identity/revision
                // rules rather than treating it as a new append.
                let messageId: String?
                switch mutation {
                case .message(let message): messageId = message.messageId
                case .delta(let id, _, _, _): messageId = id
                default: messageId = nil
                }
                if let messageId, !state.projection.messages.contains(where: {$0.messageId == messageId}),
                   let previous = try RemoteMessageArchive.message(db, ref: ref.key, id: messageId) {
                    state.projection.messages.insert(previous, at: 0)
                }
                guard let (type, payload) = try apply(mutation, to: &state.projection) else { continue }
                guard state.sequence < 9_007_199_254_740_991 else { throw RemoteJournalError.limitExceeded }
                state.sequence += 1; state.cursor = UUID().uuidString
                let event = RemoteJournalEvent(schemaVersion: 1, sessionId: ref.sessionId, streamEpoch: state.epoch,
                    sequence: state.sequence, occurredAt: ISO8601DateFormatter().string(from: now), type: type, payload: payload)
                let eventData = try encode(event)
                guard eventData.count <= limits.eventBytes else { throw RemoteJournalError.limitExceeded }
                if let messageId, let message = state.projection.messages.first(where: {$0.messageId == messageId}) {
                    // Validate before persistence. The whole transaction rolls
                    // back on a later mutation failure, including snapshot COW.
                    try validateMessage(message)
                    try RemoteMessageArchive.put(db, ref: ref.key, message: message, now: now)
                }
                try Self.execute(db, "INSERT INTO remote_session_events VALUES(?,?,?,?,?)", [.text(ref.key), .int(state.sequence), .text(state.cursor), .real(now.timeIntervalSince1970), .blob(eventData)])
                records.append(.init(cursor: state.cursor, event: event))
            }
            Self.compactMessages(&state.projection)
            try validate(ref, state.projection)
            let stateData = try encode(state)
            guard stateData.count <= limits.projectionBytes else { throw RemoteJournalError.limitExceeded }
            try Self.execute(db, "UPDATE remote_session_streams SET state=? WHERE ref=?", [.blob(stateData), .text(ref.key)])
            try prune(db, ref: ref, now: now)
            if archived { try pruneToolResults(db) }
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
        case .toolResult: throw RemoteJournalError.invalidProjection // handled atomically in commit
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
                      (activity.status == previous.status || ["running", "unknown"].contains(previous.status) && activity.status != "running") else { throw RemoteJournalError.revisionConflict }
                projection.activities[index] = activity
                projection.activities = RemoteToolPresentation.compact(projection.activities)
                return ("activity.updated", try json(activity))
            }
            projection.activities.append(activity)
            projection.activities = RemoteToolPresentation.compact(projection.activities)
            return ("activity.created", try json(activity))
        case .control(let control):
            if control == projection.control { return nil }
            guard control.executionEpoch != projection.control.executionEpoch || control.controlRevision > projection.control.controlRevision else { throw RemoteJournalError.revisionConflict }
            if control.executionEpoch != projection.control.executionEpoch { projection.pendingRequests.removeAll() }
            else { projection.pendingRequests.removeAll { $0.turnId != control.currentTurnId } }
            projection.control = control
            return ("session.updated", try json(control))
        case .approval(let request), .question(let request):
            if case .approval = mutation { guard request.type == "approval" else { throw RemoteJournalError.invalidProjection } }
            if case .question = mutation { guard request.type == "question" else { throw RemoteJournalError.invalidProjection } }
            guard request.executionEpoch == projection.control.executionEpoch, request.turnId == projection.control.currentTurnId else { throw RemoteJournalError.revisionConflict }
            if let index = projection.pendingRequests.firstIndex(where: { $0.requestId == request.requestId }) {
                if projection.pendingRequests[index] == request { return nil }
                guard request.requestRevision > projection.pendingRequests[index].requestRevision,
                      request.type == projection.pendingRequests[index].type else { throw RemoteJournalError.revisionConflict }
                projection.pendingRequests[index] = request
            } else { projection.pendingRequests.append(request) }
            return (request.type + ".requested", try json(request))
        case .resolveApproval(let id, let revision), .resolveQuestion(let id, let revision):
            guard let index = projection.pendingRequests.firstIndex(where: { $0.requestId == id }),
                  projection.pendingRequests[index].requestRevision == revision else { throw RemoteJournalError.revisionConflict }
            let type = projection.pendingRequests[index].type
            if case .resolveApproval = mutation { guard type == "approval" else { throw RemoteJournalError.revisionConflict } }
            if case .resolveQuestion = mutation { guard type == "question" else { throw RemoteJournalError.revisionConflict } }
            projection.pendingRequests.remove(at: index)
            return (type + ".resolved", .object(["requestId": .string(id), "requestRevision": .integer(Int64(revision + 1))]))
        case .requireSync(let reason):
            guard !reason.isEmpty, reason.utf8.count <= 128, !reason.contains("\0") else { throw RemoteJournalError.invalidProjection }
            return ("sync.required", .object(["reason": .string(reason)]))
        }
    }

    private static func compactMessages(_ projection: inout RemoteSessionProjection) {
        let start = max(0, projection.messages.count - 200)
        projection.messages = projection.messages.enumerated().compactMap {index, message in
            if index >= start { return message }
            if let turn = projection.control.currentTurnId, message.turnId == turn { return message }
            return nil
        }
    }

    private nonisolated func validate(_ ref: RemoteSessionRef, _ projection: RemoteSessionProjection, maximumMessages: Int = 1000) throws {
        let c = projection.control
        guard ref.valid, !c.executionEpoch.isEmpty, (0..<9_007_199_254_740_991).contains(c.controlRevision),
              ["idle", "running", "waitingForUser", "completed", "interrupted", "failed", "unknown"].contains(c.state),
              ["readOnly", "live", "resumable", "unavailable"].contains(c.controlMode),
              c.allowedActions.allSatisfy({ RemoteAction(rawValue: $0) != nil }),
              (c.controlMode != "readOnly" || c.allowedActions.allSatisfy({ $0 == "history.read" })),
              projection.messages.count <= maximumMessages, projection.pendingRequests.count <= 128, projection.activities.count <= 1000,
              Set(projection.messages.map(\.messageId)).count == projection.messages.count,
              Set(projection.pendingRequests.map(\.requestId)).count == projection.pendingRequests.count,
              Set(projection.activities.map(\.activityId)).count == projection.activities.count,
              projection.hasOlder == (projection.olderHistoryCursor != nil) else { throw RemoteJournalError.invalidProjection }
        for message in projection.messages { try validateMessage(message) }
        for activity in projection.activities {
            guard !activity.activityId.isEmpty, activity.activityId.utf8.count <= 160,
                  !activity.turnId.isEmpty, activity.turnId.utf8.count <= 160,
                  (1..<9_007_199_254_740_991).contains(activity.activityRevision),
                  ["command", "fileChange", "mcpTool", "dynamicTool", "collabTool", "webSearch", "imageView", "imageGeneration"].contains(activity.kind),
                  ["running", "completed", "failed", "unknown"].contains(activity.status),
                  validDate(activity.createdAt), activity.presentation?.valid ?? true else { throw RemoteJournalError.invalidProjection }
        }
        for request in projection.pendingRequests {
            guard request.validContent, (0..<9_007_199_254_740_991).contains(request.requestRevision),
                  request.executionEpoch == c.executionEpoch, request.turnId == c.currentTurnId,
                  validDate(request.expiresAt) else { throw RemoteJournalError.invalidProjection }
        }
    }
    private nonisolated func validateMessage(_ message: RemoteHistoryMessage) throws {
        guard !message.messageId.isEmpty, message.messageId.utf8.count <= 256, !message.messageId.contains("\0"),
              message.turnId.map({!$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0")}) ?? true,
              (0..<9_007_199_254_740_991).contains(message.messageRevision),
              ["user", "assistant"].contains(message.role), ["streaming", "completed", "failed", "interrupted"].contains(message.status),
              validDate(message.createdAt), message.content.count <= 128, Set(message.content.map(\.partId)).count == message.content.count,
              message.content.allSatisfy({ !$0.partId.isEmpty && ["text", "unsupported"].contains($0.type) }) else { throw RemoteJournalError.invalidProjection }
    }
    private nonisolated func validDate(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) != nil
    }

    private enum Binding { case text(String), blob(Data), int(Int), real(Double) }
    private struct Row { var integer = 0; var real = 0.0; var thirdInteger = 0; var fourthInteger = 0; var blob: Data?; var text: String? }
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
                    if column == 3 { row.fourthInteger = Int(sqlite3_column_int64(stmt, column)) }
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
