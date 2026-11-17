import Foundation

fileprivate final class RemoteEventWakeup: Sendable {
    let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    init() {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream; continuation = pair.continuation
    }
    func signal() { continuation.yield(()) }
    func finish() { continuation.finish() }
}

/// A coalesced side channel, deliberately separate from shared history sequence.
fileprivate final class RemoteReceiptQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String> = []
    private var failed = false
    func push(_ id: String) {
        lock.withLock {
            if ids.count >= 128 && !ids.contains(id) {failed = true; return}
            ids.insert(id)
        }
    }
    func fail() {lock.withLock {failed = true}}
    func take() throws -> [String] {
        try lock.withLock {
            guard !failed else {throw RemoteOperationError.limitExceeded}
            let result = Array(ids); ids.removeAll(); return result
        }
    }
}

/// Unified session projection API. Registration is local and explicit; a client
/// cannot make an arbitrary journal row visible by guessing its session ID.
actor RemoteSessionService {
    private struct Source {
        let id: UUID
        let ref: RemoteSessionRef
        let journal: RemoteSessionJournal
        let possibleActions: Set<RemoteAction>
        let available: @Sendable () async -> Bool
        var commands: RemoteOperationService?
        var historyReader: RemoteJournalHistoryReader?
        var historyReaderLease: UUID?
    }
    struct Feed: Sendable {
        let ref: RemoteSessionRef
        let cursor: String
        let initial: RemoteJournalReplay
        let wakeups: AsyncStream<Void>
        fileprivate let sourceId: UUID
        fileprivate let journal: RemoteSessionJournal
        fileprivate let observerId: UUID
        fileprivate let timer: Task<Void, Never>
        fileprivate let wakeup: RemoteEventWakeup
        fileprivate let commands: RemoteOperationService?
        fileprivate let operationObserver: UUID?
        fileprivate let receipts: RemoteReceiptQueue?
        fileprivate let operationTask: Task<Void, Never>?
    }
    let serverId: String
    private var sources: [String: Source] = [:]
    private struct ToolCursor {
        let owner: RemoteAccessStore.PagingOwner
        let generation: UInt64
        let sourceId: UUID
        let ref: RemoteSessionRef
        let activityId: String
        let version: String
        let offset: Int
        let expires: Date
    }
    private var toolCursors: [String: ToolCursor] = [:]
    init(serverId: String) { self.serverId = serverId }

    @discardableResult
    func register(ref: RemoteSessionRef, journal: RemoteSessionJournal, possibleActions: Set<RemoteAction> = [.readHistory],
                  available: @escaping @Sendable () async -> Bool = { true }) async throws -> UUID {
        guard ref.serverId == serverId, sources.count < 128, sources[ref.sessionId] == nil,
              possibleActions.contains(.readHistory) else { throw RemoteReadError.invalidRequest }
        _ = try await journal.snapshot(ref: ref)
        guard sources.count < 128, sources[ref.sessionId] == nil else { throw RemoteReadError.duplicateRuntime }
        let lease = UUID()
        sources[ref.sessionId] = .init(id: lease, ref: ref, journal: journal, possibleActions: possibleActions, available: available)
        return lease
    }
    func unregister(sessionId: String) { sources.removeValue(forKey: sessionId) }
    func unregister(sessionId: String, lease: UUID) {
        if sources[sessionId]?.id == lease { sources.removeValue(forKey: sessionId) }
    }
    func installHistoryReader(_ reader: RemoteJournalHistoryReader, lease: UUID) throws {
        guard let source = sources[reader.ref.sessionId], source.ref == reader.ref,
              source.journal.storageIdentity == reader.journal.storageIdentity else {
            throw RemoteReadError.unavailable
        }
        sources[reader.ref.sessionId]?.historyReader = reader
        sources[reader.ref.sessionId]?.historyReaderLease = lease
    }
    func removeHistoryReader(_ reader: RemoteJournalHistoryReader, lease: UUID) {
        if sources[reader.ref.sessionId]?.historyReader === reader, sources[reader.ref.sessionId]?.historyReaderLease == lease {
            sources[reader.ref.sessionId]?.historyReader = nil; sources[reader.ref.sessionId]?.historyReaderLease = nil
        }
    }
    /// Called locally only after installing the HTTP operation service. A stale
    /// source lease cannot enable a replacement session with the same public ID.
    func publishCommands(sessionId: String, lease: UUID, service: RemoteOperationService) throws {
        guard service.serverId == serverId, sources[sessionId]?.id == lease else {throw RemoteReadError.notFound}
        sources[sessionId]?.commands = service
    }

    /// Only explicitly registered, currently available executors supply list state.
    /// Host-wide history rows are not evidence that a session is idle.
    func directoryControls(agentId: String, runtimeId: String, sessionIds: Set<String>,
                           principal: RemoteAccessStore.Principal) async -> [String: RemoteSessionControl] {
        let candidates = sources.values.filter { source in
            source.ref.agentId == agentId && source.ref.runtimeId == runtimeId && sessionIds.contains(source.ref.sessionId)
                && principal.permits(agentId: agentId, runtimeId: runtimeId, sessionId: source.ref.sessionId, action: .readHistory)
        }
        var result: [String: RemoteSessionControl] = [:]
        for source in candidates {
            guard await source.available(), let snapshot = try? await source.journal.snapshot(ref: source.ref),
                  sources[source.ref.sessionId]?.id == source.id else { continue }
            let control = await filter(snapshot.projection.control, source, principal)
            guard sources[source.ref.sessionId]?.id == source.id, await source.available() else { continue }
            result[source.ref.sessionId] = control
        }
        let leases = Dictionary(uniqueKeysWithValues: candidates.map { ($0.ref.sessionId, $0.id) })
        return result.filter { sources[$0.key]?.id == leases[$0.key] }
    }

    func sync(sessionId: String, query: [String: String], principal: RemoteAccessStore.Principal) async throws -> Data {
        let source = try resolve(sessionId, query, principal)
        guard await source.available() else { throw RemoteReadError.unavailable }
        let snapshot = try await source.journal.snapshot(ref: source.ref, includeHistorySnapshot: source.historyReader != nil)
        guard sources[sessionId]?.id == source.id, await source.available() else { throw RemoteReadError.unavailable }
        let control = await filter(snapshot.projection.control, source, principal)
        var requests: [RemotePendingRequest] = []
        for request in snapshot.projection.pendingRequests {
            if request.validContent, let expiry = ISO8601DateFormatter().date(from: request.expiresAt), expiry > Date(),
               await requestVisible(request.type, epoch: request.executionEpoch, source: source, principal: principal) {
                requests.append(request)
            }
        }
        guard sources[sessionId]?.id == source.id, await source.available() else {throw RemoteReadError.unavailable}
        let history = try await source.historyReader?.page(principal: principal, captured: snapshot,
            retainingTurn: snapshot.projection.control.currentTurnId)
        guard sources[sessionId]?.id == source.id, await source.available() else {throw RemoteReadError.unavailable}
        var projection = RemoteSessionProjection(control: control,
            messages: snapshot.projection.messages, pendingRequests: requests,
            olderHistoryCursor: snapshot.projection.olderHistoryCursor, hasOlder: snapshot.projection.hasOlder,
            activities: snapshot.projection.activities)
        if let history {
            projection.messages = history.messages; projection.olderHistoryCursor = history.olderHistoryCursor
            projection.hasOlder = history.hasOlder
        }
        return try JSONEncoder().encode(RemoteJournalSync(ref: source.ref, projection: projection,
            streamEpoch: snapshot.streamEpoch, sequence: snapshot.sequence, eventCursor: snapshot.eventCursor))
    }

    func toolResult(sessionId: String, activityId: String, query: [String: String], principal: RemoteAccessStore.Principal) async throws -> Data {
        guard principal.expiresAt > Date() else { throw RemoteAccessError.forbidden }
        var scope = query
        let token = scope.removeValue(forKey: "result_cursor")
        let source = try resolve(sessionId, scope, principal)
        guard await source.available() else { throw RemoteReadError.unavailable }
        toolCursors = toolCursors.filter { $0.value.expires > Date() }
        let cursor: ToolCursor?
        if let token {
            guard token.utf8.count <= 256, let saved = toolCursors[token], saved.owner == principal.pagingOwner, saved.generation == principal.generation,
                  saved.sourceId == source.id, saved.ref == source.ref, saved.activityId == activityId else {
                throw RemoteReadError.cursorExpired
            }
            cursor = saved
        } else { cursor = nil }
        var page = try await source.journal.toolResultPage(ref: source.ref, activityId: activityId,
            version: cursor?.version, offset: cursor?.offset ?? 0)
        let remainsAvailable = await source.available()
        guard remainsAvailable, sources[sessionId]?.id == source.id else { throw RemoteReadError.unavailable }
        guard principal.expiresAt > Date() else { throw RemoteAccessError.forbidden }
        try authorize(source, principal)
        let nextOffset = page.utf8Offset + page.text.utf8.count
        if nextOffset < page.totalUTF8Bytes {
            // Bound metadata without preventing continued reading of a maximum
            // size result. Old cursors expire explicitly instead of mixing pages.
            if toolCursors.count >= 2048, let oldest = toolCursors.min(by: { $0.value.expires < $1.value.expires })?.key {
                toolCursors.removeValue(forKey: oldest)
            }
            let next = UUID().uuidString
            toolCursors[next] = .init(owner: principal.pagingOwner, generation: principal.generation, sourceId: source.id, ref: source.ref, activityId: activityId,
                version: page.resultVersion, offset: nextOffset, expires: Date().addingTimeInterval(300))
            page.nextCursor = next
        }
        return try JSONEncoder().encode(page)
    }

    func open(sessionId: String, query: [String: String], cursor: String, principal: RemoteAccessStore.Principal) async throws -> Feed {
        let source = try resolve(sessionId, query, principal)
        guard await source.available() else { throw RemoteReadError.unavailable }
        let wakeup = RemoteEventWakeup()
        let (observer, initial) = try await source.journal.observe(ref: source.ref, after: cursor, signal: { wakeup.signal() })
        guard sources[sessionId]?.id == source.id else {
            await source.journal.removeObserver(observer); throw RemoteReadError.notFound
        }
        var operationObserver: UUID?
        var receipts: RemoteReceiptQueue?
        var operationTask: Task<Void, Never>?
        do {
            if let commands = source.commands {
                let snapshot = try await source.journal.snapshot(ref: source.ref)
                let actions = await commands.publishedActions(ref: source.ref, executionEpoch: snapshot.projection.control.executionEpoch)
                if actions.contains(where: {principal.permits(agentId: source.ref.agentId, runtimeId: source.ref.runtimeId,
                    sessionId: source.ref.sessionId, action: $0)}) {
                    let observation = try await commands.observe(ref: source.ref, principal: principal)
                    let queue = RemoteReceiptQueue()
                    operationObserver = observation.id; receipts = queue
                    operationTask = Task {
                        do {
                            for try await id in observation.changes {
                                guard !Task.isCancelled else {break}
                                queue.push(id); wakeup.signal()
                            }
                            if !Task.isCancelled {queue.fail(); wakeup.signal()}
                        } catch {
                            if !Task.isCancelled {queue.fail(); wakeup.signal()}
                        }
                    }
                }
            }
            guard sources[sessionId]?.id == source.id, await source.available() else {throw RemoteReadError.unavailable}
        } catch {
            operationTask?.cancel()
            if let operationObserver {await source.commands?.closeObservation(operationObserver)}
            await source.journal.removeObserver(observer); wakeup.finish()
            throw error
        }
        // Authorization and source checks run even on an idle stream. This is a
        // coalesced wake-up, not history polling; private data stays in the journal.
        let timer = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
                wakeup.signal()
            }
        }
        wakeup.signal()
        return .init(ref: source.ref, cursor: cursor,
                     initial: .init(streamEpoch: initial.streamEpoch, afterSequence: initial.afterSequence, records: []),
                     wakeups: wakeup.stream, sourceId: source.id,
                     journal: source.journal, observerId: observer, timer: timer, wakeup: wakeup,
                     commands: source.commands, operationObserver: operationObserver, receipts: receipts, operationTask: operationTask)
    }
    func close(_ feed: Feed) async {
        feed.timer.cancel(); feed.wakeup.finish()
        feed.operationTask?.cancel()
        if let id = feed.operationObserver {await feed.commands?.closeObservation(id)}
        await feed.operationTask?.value
        await feed.journal.removeObserver(feed.observerId)
    }
    /// No SSE id or history sequence. The client uses its original operation
    /// key/id for recovery; these receipts never become a shared replay cursor.
    func operationIDs(_ feed: Feed, principal: RemoteAccessStore.Principal) throws -> [String] {
        guard let source = sources[feed.ref.sessionId], source.id == feed.sourceId else {throw RemoteReadError.notFound}
        try authorize(source, principal)
        return try feed.receipts?.take() ?? []
    }
    func operationFrame(id: String, feed: Feed, principal: RemoteAccessStore.Principal) async throws -> Data {
        guard let source = sources[feed.ref.sessionId], source.id == feed.sourceId, await source.available(),
              let commands = feed.commands else {throw RemoteReadError.unavailable}
        try authorize(source, principal)
        let data = try await commands.operation(id: id,
            query: ["agent_id": feed.ref.agentId, "runtime_id": feed.ref.runtimeId], principal: principal)
        guard sources[feed.ref.sessionId]?.id == feed.sourceId, await source.available() else {throw RemoteReadError.unavailable}
        let operation = try JSONDecoder().decode(AgentJSON.self, from: data)
        let event: AgentJSON = .object(["schemaVersion": .integer(1), "type": .string("operation.updated"),
            "serverId": .string(feed.ref.serverId), "agentId": .string(feed.ref.agentId),
            "runtimeId": .string(feed.ref.runtimeId), "sessionId": .string(feed.ref.sessionId), "operation": operation])
        let json = try JSONEncoder().encode(event)
        return Data("id:\nevent: operation.updated\ndata: \(String(decoding: json, as: UTF8.self))\n\n".utf8)
    }
    func nudge(_ feed: Feed) { feed.wakeup.signal() }
    func replay(_ feed: Feed, after cursor: String, principal: RemoteAccessStore.Principal) async throws -> RemoteJournalReplay {
        guard let source = sources[feed.ref.sessionId], source.id == feed.sourceId, await source.available() else { throw RemoteReadError.unavailable }
        try authorize(source, principal)
        let result = try await feed.journal.replayWindow(ref: feed.ref, after: cursor)
        guard sources[feed.ref.sessionId]?.id == feed.sourceId else { throw RemoteReadError.notFound }
        return result
    }
    struct Frame: Sendable { let data: Data; let terminal: Bool }
    func frame(_ record: RemoteJournalRecord, feed: Feed, principal: RemoteAccessStore.Principal) async throws -> Data {
        try await frameResult(record, feed: feed, principal: principal).data
    }
    func frameResult(_ record: RemoteJournalRecord, feed: Feed, principal: RemoteAccessStore.Principal) async throws -> Frame {
        guard let source = sources[feed.ref.sessionId], source.id == feed.sourceId, await source.available() else { throw RemoteReadError.notFound }
        try authorize(source, principal)
        let snapshot = try await source.journal.snapshot(ref: source.ref)
        guard snapshot.streamEpoch == record.event.streamEpoch, record.event.sessionId == source.ref.sessionId,
              record.event.schemaVersion == 1 else { throw RemoteJournalError.revisionConflict }
        var event = record.event
        if event.type == "session.updated" {
            let control = try JSONDecoder().decode(RemoteSessionControl.self, from: JSONEncoder().encode(event.payload))
            let filtered = await filter(control, source, principal)
            guard sources[feed.ref.sessionId]?.id == feed.sourceId else {throw RemoteReadError.notFound}
            let payload = try JSONDecoder().decode(AgentJSON.self, from: JSONEncoder().encode(filtered))
            event = .init(schemaVersion: event.schemaVersion, sessionId: event.sessionId, streamEpoch: event.streamEpoch,
                sequence: event.sequence, occurredAt: event.occurredAt, type: event.type, payload: payload)
        } else if event.type.hasPrefix("approval.") || event.type.hasPrefix("question.") {
            let type = event.type.hasPrefix("approval.") ? "approval" : "question"
            let action: RemoteAction = type == "approval" ? .approve : .answer
            let published = await source.commands?.publishedActions(ref: source.ref,
                executionEpoch: snapshot.projection.control.executionEpoch) ?? []
            var replacement: (String, AgentJSON)?
            if !published.contains(action) {
                replacement = ("sync.required", .object(["reason": .string("request_adapter_unavailable")]))
            } else if !principal.permits(agentId: source.ref.agentId, runtimeId: source.ref.runtimeId,
                                         sessionId: source.ref.sessionId, action: action) {
                // Preserve sequence without leaking the command, questions or
                // request identity to a history-only caller.
                replacement = ("request.hidden", .object([:]))
            } else if event.type == type + ".requested" {
                let request = try JSONDecoder().decode(RemotePendingRequest.self, from: JSONEncoder().encode(event.payload))
                guard request.type == type, request.validContent else { throw RemoteJournalError.invalidProjection }
                if request.executionEpoch != snapshot.projection.control.executionEpoch
                    || ISO8601DateFormatter().date(from: request.expiresAt).map({ $0 <= Date() }) != false {
                    replacement = ("request.hidden", .object([:]))
                }
            } else if event.type == type + ".resolved" {
                guard case .object(let fields) = event.payload, Set(fields.keys) == ["requestId", "requestRevision"],
                      case .string(let id) = fields["requestId"], !id.isEmpty, id.utf8.count <= 256,
                      case .integer(let revision) = fields["requestRevision"], (1...9_007_199_254_740_991).contains(revision) else {
                    throw RemoteJournalError.invalidProjection
                }
            } else { replacement = ("sync.required", .object(["reason": .string("unsupported_request_event")])) }
            if let (type, payload) = replacement {
                event = .init(schemaVersion: event.schemaVersion, sessionId: event.sessionId, streamEpoch: event.streamEpoch,
                    sequence: event.sequence, occurredAt: event.occurredAt, type: type, payload: payload)
            }
        }
        guard sources[feed.ref.sessionId]?.id == feed.sourceId, await source.available() else { throw RemoteReadError.unavailable }
        try authorize(source, principal)
        let json = try JSONEncoder().encode(event)
        return .init(data: Data("id: \(record.cursor)\nevent: \(event.type)\ndata: \(String(decoding: json, as: UTF8.self))\n\n".utf8),
                     terminal: event.type == "sync.required")
    }
    /// Confirms replay has caught up without creating a new history sequence or
    /// cursor. Existing clients already ignore heartbeat events.
    static func readyFrame(ref: RemoteSessionRef, epoch: String, sequence: Int, cursor: String) throws -> Data {
        let event = RemoteJournalEvent(schemaVersion: 1, sessionId: ref.sessionId, streamEpoch: epoch, sequence: sequence,
            occurredAt: ISO8601DateFormatter().string(from: Date()), type: "heartbeat", payload: .object([:]))
        let json = try JSONEncoder().encode(event)
        return Data("id: \(cursor)\nevent: heartbeat\ndata: \(String(decoding: json, as: UTF8.self))\n\n".utf8)
    }
    static func signalFrame(type: String, ref: RemoteSessionRef, epoch: String, sequence: Int, reason: String) throws -> Data {
        let event = RemoteJournalEvent(schemaVersion: 1, sessionId: ref.sessionId, streamEpoch: epoch, sequence: sequence,
            occurredAt: ISO8601DateFormatter().string(from: Date()), type: type, payload: .object(["reason": .string(reason)]))
        let json = try JSONEncoder().encode(event)
        return Data("id: \(UUID().uuidString)\nevent: \(type)\ndata: \(String(decoding: json, as: UTF8.self))\n\n".utf8)
    }
    private func resolve(_ session: String, _ query: [String: String], _ principal: RemoteAccessStore.Principal) throws -> Source {
        guard Set(query.keys).isSubset(of: ["agent_id", "runtime_id"]),
              (query["agent_id"] == nil) == (query["runtime_id"] == nil) else { throw RemoteReadError.invalidRequest }
        guard let source = sources[session] else { throw RemoteReadError.notFound }
        if let agent = query["agent_id"], let runtime = query["runtime_id"] {
            guard agent == source.ref.agentId, runtime == source.ref.runtimeId else { throw RemoteAccessError.forbidden }
        }
        try authorize(source, principal)
        return source
    }
    private func authorize(_ source: Source, _ principal: RemoteAccessStore.Principal) throws {
        guard source.possibleActions.contains(.readHistory), principal.permits(agentId: source.ref.agentId, runtimeId: source.ref.runtimeId,
            sessionId: source.ref.sessionId, action: .readHistory) else { throw RemoteAccessError.forbidden }
    }
    private func requestVisible(_ type: String, epoch: String, source: Source, principal: RemoteAccessStore.Principal) async -> Bool {
        guard type == "approval" || type == "question" else { return false }
        let action: RemoteAction = type == "approval" ? .approve : .answer
        guard principal.permits(agentId: source.ref.agentId, runtimeId: source.ref.runtimeId,
                                sessionId: source.ref.sessionId, action: action) else { return false }
        return await source.commands?.publishedActions(ref: source.ref, executionEpoch: epoch).contains(action) ?? false
    }
    private func filter(_ control: RemoteSessionControl, _ source: Source, _ principal: RemoteAccessStore.Principal) async -> RemoteSessionControl {
        let commands = await source.commands?.publishedActions(ref: source.ref, executionEpoch: control.executionEpoch) ?? []
        let allowed = control.allowedActions.filter { raw in
            guard let action = RemoteAction(rawValue: raw), principal.permits(agentId: source.ref.agentId,
                runtimeId: source.ref.runtimeId, sessionId: source.ref.sessionId, action: action) else {return false}
            return action == .readHistory ? source.possibleActions.contains(action) : control.controlMode == "live" && commands.contains(action)
        }
        let live = allowed.contains { $0 != RemoteAction.readHistory.rawValue }
        return .init(executionEpoch: control.executionEpoch, controlRevision: control.controlRevision, state: control.state,
            controlMode: control.controlMode == "unavailable" ? "unavailable" : live ? "live" : "readOnly", currentTurnId: control.currentTurnId, allowedActions: allowed)
    }
}
