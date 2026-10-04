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
    /// Called locally only after installing the HTTP operation service. A stale
    /// source lease cannot enable a replacement session with the same public ID.
    func publishCommands(sessionId: String, lease: UUID, service: RemoteOperationService) throws {
        guard service.serverId == serverId, sources[sessionId]?.id == lease else {throw RemoteReadError.notFound}
        sources[sessionId]?.commands = service
    }

    func sync(sessionId: String, query: [String: String], principal: RemoteAccessStore.Principal) async throws -> Data {
        let source = try resolve(sessionId, query, principal)
        guard await source.available() else { throw RemoteReadError.unavailable }
        let snapshot = try await source.journal.snapshot(ref: source.ref)
        guard sources[sessionId]?.id == source.id, await source.available() else { throw RemoteReadError.unavailable }
        let control = await filter(snapshot.projection.control, source, principal)
        guard sources[sessionId]?.id == source.id, await source.available() else {throw RemoteReadError.unavailable}
        let projection = RemoteSessionProjection(control: control,
            messages: snapshot.projection.messages, pendingRequests: [], // Approval adapter not yet published.
            olderHistoryCursor: snapshot.projection.olderHistoryCursor, hasOlder: snapshot.projection.hasOlder,
            activities: snapshot.projection.activities)
        return try JSONEncoder().encode(RemoteJournalSync(ref: source.ref, projection: projection,
            streamEpoch: snapshot.streamEpoch, sequence: snapshot.sequence, eventCursor: snapshot.eventCursor))
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
    func frame(_ record: RemoteJournalRecord, feed: Feed, principal: RemoteAccessStore.Principal) async throws -> Data {
        guard let source = sources[feed.ref.sessionId], source.id == feed.sourceId else { throw RemoteReadError.notFound }
        try authorize(source, principal)
        var event = record.event
        if event.type == "session.updated" {
            let control = try JSONDecoder().decode(RemoteSessionControl.self, from: JSONEncoder().encode(event.payload))
            let filtered = await filter(control, source, principal)
            guard sources[feed.ref.sessionId]?.id == feed.sourceId else {throw RemoteReadError.notFound}
            let payload = try JSONDecoder().decode(AgentJSON.self, from: JSONEncoder().encode(filtered))
            event = .init(schemaVersion: event.schemaVersion, sessionId: event.sessionId, streamEpoch: event.streamEpoch,
                sequence: event.sequence, occurredAt: event.occurredAt, type: event.type, payload: payload)
        } else if event.type.hasPrefix("approval.") || event.type.hasPrefix("question.") {
            // Keep the sequence contiguous but don't publish actionable requests
            // before their typed upstream adapter and command journal exist.
            event = .init(schemaVersion: 1, sessionId: event.sessionId, streamEpoch: event.streamEpoch, sequence: event.sequence,
                occurredAt: event.occurredAt, type: "sync.required", payload: .object(["reason": .string("request_adapter_unavailable")]))
        }
        let json = try JSONEncoder().encode(event)
        return Data("id: \(record.cursor)\nevent: \(event.type)\ndata: \(String(decoding: json, as: UTF8.self))\n\n".utf8)
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
