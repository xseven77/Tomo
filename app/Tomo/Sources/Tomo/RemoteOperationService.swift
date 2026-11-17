import Foundation


/// Unified commands for all registered vendors. Identity must come from a
/// trusted verifier; neither HTTP body nor a pairing token can supply it.
actor RemoteOperationService {
    private final class Lifecycle: @unchecked Sendable {
        private let lock = NSLock()
        private var open = true
        func close() {lock.withLock {open = false}}
        var isOpen: Bool {lock.withLock {open}}
    }
    private nonisolated let lifecycle = Lifecycle()
    nonisolated func stopAccepting() {lifecycle.close()}
    typealias Identity = @Sendable (RemoteAccessStore.Principal) async throws -> RemoteOperationOwner
    private struct Source {
        let lease: UUID
        let ref: RemoteSessionRef
        let executionEpoch: String
        let actions: Set<RemoteAction>
        let adapter: any RemoteCommandAdapter
    }
    nonisolated let serverId: String
    private let access: any RemotePrincipalValidator
    private let store: RemoteOperationStore
    private let identity: Identity
    private var sources: [String: Source] = [:]
    private var jobs: [String: Task<Void, Never>] = [:]
    private struct Job: Sendable {
        let dispatcher: RemoteOperationDispatcher
        let owner: RemoteOperationOwner
        let ref: RemoteSessionRef
        let epoch: String
    }
    private var pending: [(String, Job)] = []
    private var submitting = 0
    private var observations: Set<UUID> = []

    init(serverId: String, access: any RemotePrincipalValidator, store: RemoteOperationStore,
         identity: @escaping Identity) {
        self.serverId = serverId; self.access = access; self.store = store
        self.identity = identity
    }
    @discardableResult
    func register(ref: RemoteSessionRef, executionEpoch: String, actions: Set<RemoteAction>, adapter: any RemoteCommandAdapter) throws -> UUID {
        guard lifecycle.isOpen else {throw RemoteReadError.unavailable}
        guard ref.serverId == serverId, [ref.agentId, ref.runtimeId, ref.sessionId, executionEpoch].allSatisfy(Self.validId),
              !actions.isEmpty, actions.isSubset(of: [.sendMessage, .interrupt, .approve, .answer]), sources.count < 128 else {
            throw RemoteReadError.invalidRequest
        }
        guard sources[ref.sessionId] == nil else {throw RemoteReadError.duplicateRuntime}
        let lease = UUID()
        sources[ref.sessionId] = .init(lease: lease, ref: ref, executionEpoch: executionEpoch, actions: actions, adapter: adapter)
        return lease
    }
    func unregister(sessionId: String, lease: UUID) async throws {
        guard let source = sources[sessionId], source.lease == lease else {return}
        sources.removeValue(forKey: sessionId)
        // Only use this when local lifecycle confirms this execution stopped.
        // Merely revoking a remote caller must not declare the Agent stopped.
        try await store.executionStopped(ref: source.ref, executionEpoch: source.executionEpoch)
    }
    /// Capability discovery is bound to the same source and execution as dispatch.
    /// Closing the service immediately withdraws its published actions.
    func publishedActions(ref: RemoteSessionRef, executionEpoch: String) -> Set<RemoteAction> {
        guard lifecycle.isOpen else {return []}
        if let source = sources[ref.sessionId], source.ref == ref,
           source.executionEpoch == executionEpoch {
            return source.actions
        }
        return []
    }
    func shutdown() async {
        stopAccepting()
        let observed = observations; observations.removeAll()
        for id in observed {await store.removeObserver(id)}
        sources.removeAll()
        let waiting = pending; pending.removeAll()
        let active = Array(jobs.values)
        active.forEach {$0.cancel()}
        for (id, job) in waiting {
            _ = try? await store.rejectAccepted(id: id, owner: job.owner, ref: job.ref, errorCode: "dispatch_cancelled")
        }
        for task in active {await task.value}
    }

    /// Internal feed admission. Notifications contain only opaque IDs; callers
    /// must use operation(...) for a fresh identity/action check on every frame.
    func observe(ref: RemoteSessionRef, principal: RemoteAccessStore.Principal) async throws -> RemoteOperationStore.Observation {
        let owner = try await verified(principal)
        guard observations.count < 64 else {throw RemoteOperationError.limitExceeded}
        let current = try source(ref.sessionId, ["agent_id": ref.agentId, "runtime_id": ref.runtimeId])
        guard current.ref == ref else {throw RemoteAccessError.forbidden}
        try permit(principal, ref, .readHistory)
        let actions = current.actions.filter {principal.permits(agentId: ref.agentId, runtimeId: ref.runtimeId,
            sessionId: ref.sessionId, action: $0)}
        guard !actions.isEmpty else {throw RemoteAccessError.forbidden}
        let observation = try await store.observe(owner: owner, ref: ref, actions: actions)
        do {
            guard try await verified(principal) == owner, sources[ref.sessionId]?.lease == current.lease else {
                throw RemoteAccessError.forbidden
            }
            guard observations.count < 64 else {throw RemoteOperationError.limitExceeded}
            observations.insert(observation.id)
            return observation
        } catch {await store.removeObserver(observation.id); throw error}
    }
    func closeObservation(_ id: UUID) async {
        observations.remove(id); await store.removeObserver(id)
    }

    func submit(sessionId: String, query: [String: String], action: RemoteAction, key: String, body: Data,
                principal: RemoteAccessStore.Principal) async throws -> RemoteOperation {
        let owner = try await verified(principal)
        let source = try source(sessionId, query)
        try permit(principal, source.ref, action)
        guard source.actions.contains(action) else {throw RemoteCommandError.unsupportedAction}
        guard body.count <= 64 * 1024,
              case .object(var fields) = try JSONDecoder().decode(AgentJSON.self, from: body),
              case .string(let epoch) = fields.removeValue(forKey: "executionEpoch"), Self.validId(epoch) else {
            throw RemoteReadError.invalidRequest
        }
        let request = RemoteOperationRequest(ref: source.ref, executionEpoch: epoch, action: action, body: .object(fields))
        let dispatcher = RemoteOperationDispatcher(store: store, adapter: source.adapter) { [weak self] owner, request in
            guard let self else {throw RemoteReadError.unavailable}
            try await self.authorize(principal, owner: owner, request: request, lease: source.lease)
        }
        // Dedupe precedes capacity/current execution validation. Queryability
        // does not depend on whether this instance still has a running job.
        if let prior = try await store.existing(owner: owner, key: key, request: request) {
            try await authorize(principal, owner: owner, request: request, lease: source.lease)
            if prior.state == .accepted {try enqueue(prior.operationId, dispatcher, owner, source)}
            return prior
        }
        guard submitting < 32, jobs.count + pending.count + submitting < 128 else {throw RemoteOperationError.limitExceeded}
        submitting += 1; defer {submitting -= 1}
        guard request.executionEpoch == source.executionEpoch else {throw RemoteCommandError.executionChanged}
        let operation = try await dispatcher.submit(owner: owner, key: key, request: request)
        do {try await authorize(principal, owner: owner, request: request, lease: source.lease)}
        catch {
            _ = try await store.rejectAccepted(id: operation.operationId, owner: owner, ref: source.ref, errorCode: "authorization_revoked")
            throw error
        }
        if operation.state == .accepted {try enqueue(operation.operationId, dispatcher, owner, source)}
        return operation
    }

    func operation(id: String, query: [String: String], principal: RemoteAccessStore.Principal) async throws -> Data {
        let owner = try await verified(principal)
        let request = try await store.request(id: id, owner: owner)
        try checkQuery(query, ref: request.ref)
        try permit(principal, request.ref, request.action)
        let result = try await store.operation(id: id, owner: owner, ref: request.ref)
        guard try await verified(principal) == owner else {throw RemoteAccessError.forbidden}
        return try result.responseData()
    }
    func byKey(sessionId: String, key: String, query: [String: String], principal: RemoteAccessStore.Principal) async throws -> Data {
        let owner = try await verified(principal), source = try source(sessionId, query)
        let result = try await store.byKey(owner: owner, ref: source.ref, key: key)
        let request = try await store.request(id: result.operationId, owner: owner, ref: source.ref)
        try permit(principal, source.ref, request.action)
        guard try await verified(principal) == owner else {throw RemoteAccessError.forbidden}
        return try result.responseData()
    }
    private func enqueue(_ id: String, _ dispatcher: RemoteOperationDispatcher, _ owner: RemoteOperationOwner, _ source: Source) throws {
        guard jobs[id] == nil, !pending.contains(where: {$0.0 == id}) else {return}
        // Existing durable acceptances may be recovered by retry after restart.
        // Queue only small handles; message bodies remain in SQLite.
        guard pending.count < 10000 else {throw RemoteOperationError.limitExceeded}
        pending.append((id, .init(dispatcher: dispatcher, owner: owner, ref: source.ref, epoch: source.executionEpoch)))
        drain()
    }
    private func drain() {
        while jobs.count < 32, !pending.isEmpty {
            let (id, job) = pending.removeFirst()
            jobs[id] = Task { [weak self] in
                _ = try? await job.dispatcher.execute(id: id, owner: job.owner, ref: job.ref, executionEpoch: job.epoch)
                await self?.finished(id)
            }
        }
    }
    private func finished(_ id: String) {jobs.removeValue(forKey: id); drain()}
    private func verified(_ principal: RemoteAccessStore.Principal) async throws -> RemoteOperationOwner {
        guard lifecycle.isOpen else {throw RemoteReadError.unavailable}
        try await access.validate(principal)
        let owner = try await identity(principal)
        guard [owner.userId, owner.deviceId].allSatisfy(Self.validId) else {throw RemoteAccessError.forbidden}
        try await access.validate(principal)
        guard lifecycle.isOpen else {throw RemoteReadError.unavailable}
        return owner
    }
    private func authorize(_ principal: RemoteAccessStore.Principal, owner: RemoteOperationOwner,
                           request: RemoteOperationRequest, lease: UUID) async throws {
        guard try await verified(principal) == owner else {throw RemoteAccessError.forbidden}
        try permit(principal, request.ref, request.action)
        let current = try source(request.ref.sessionId, ["agent_id": request.ref.agentId, "runtime_id": request.ref.runtimeId])
        guard current.lease == lease, current.ref == request.ref, current.actions.contains(request.action) else {throw RemoteReadError.unavailable}
    }
    private func permit(_ principal: RemoteAccessStore.Principal, _ ref: RemoteSessionRef, _ action: RemoteAction) throws {
        guard ref.serverId == serverId, principal.permits(agentId: ref.agentId, runtimeId: ref.runtimeId, sessionId: ref.sessionId, action: action) else {
            throw RemoteAccessError.forbidden
        }
    }
    private func source(_ session: String, _ query: [String: String]) throws -> Source {
        if let source = sources[session] {
            try checkQuery(query, ref: source.ref)
            return source
        }
        throw RemoteReadError.notFound
    }
    private func checkQuery(_ query: [String: String], ref: RemoteSessionRef) throws {
        guard Set(query.keys).isSubset(of: ["agent_id", "runtime_id", "session_id"]) else {
            throw RemoteReadError.invalidRequest
        }
        if let agent = query["agent_id"], agent != ref.agentId {
            throw RemoteAccessError.forbidden
        }
        if let runtime = query["runtime_id"], runtime != ref.runtimeId {
            throw RemoteAccessError.forbidden
        }
        if let session = query["session_id"], session != ref.sessionId {
            throw RemoteAccessError.forbidden
        }
    }
    private static func validId(_ value: String) -> Bool {!value.isEmpty && value.utf8.count <= 256 && !value.contains("\0")}
}
