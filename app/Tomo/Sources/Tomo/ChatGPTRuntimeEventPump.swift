import Foundation

enum ChatGPTEventPumpError: Error, Equatable {
    case invalidBinding, duplicateBinding, alreadyStarted, stopped, baselineChanged, incompatibleBaseline
}

/// Owns the only consumer of one app-server channel. An owner runtime manager
/// must supply reconciled baselines before binding and stop its transport after
/// stopping this pump. No CLI launch, discovery or HTTP input can bind a session.
actor ChatGPTRuntimeEventPump {
    nonisolated let termination: AsyncStream<Void>
    private let terminated: AsyncStream<Void>.Continuation
    enum Status: Sendable, Equatable {
        case indexing, active, invalidating, requiresSync(String), storageFailed, removed
    }
    private struct Binding {
        let lease: UUID
        var projector: ChatGPTEventProjector
        var epoch: String?
        var status: Status
        var vendorCurrentTurnId: String?
        var requests: [AgentRPCID: ChatGPTMappedServerRequest] = [:]
        // Only the current turn's complete proposals. No filesystem reads or
        // path-based lookups: a callback is correlated by its exact item ID.
        var fileChanges: [String: [RemoteFileChange]] = [:]
        var enablingControl = false
    }
    private enum Phase { case idle, running, stopped }
    private let serverId: String
    private let runtimeId: String
    private let channel: AgentRPCChannel
    private let journal: RemoteSessionJournal
    private var bindings: [String: Binding] = [:]
    private var phase = Phase.idle
    private var worker: Task<Void, Never>?
    private var checkpoints: [UUID: AsyncThrowingStream<Void, Error>.Continuation] = [:]
    private let now: @Sendable () -> Date
    private let responseTimeout: Duration
    private let requestReviewLifetime: TimeInterval
    private var expiryTasks: [String: Task<Void, Never>] = [:]
    private var responsesInFlight: Set<String> = []
    private var responsesClaimed: Set<String> = []
    private struct ResponseAttempt {
        let token: UUID
        let thread: String
        let lease: UUID
        let continuation: AsyncStream<RemoteCommandOutcome>.Continuation
        var written = false
        var resolved = false
    }
    private var responseAttempts: [String: ResponseAttempt] = [:]
    private struct ResponseContext {
        let thread: String
        let lease: UUID
        let epoch: String
        let revision: UInt64
        let mapped: ChatGPTMappedServerRequest
    }

    init(serverId: String, runtimeId: String, channel: AgentRPCChannel, journal: RemoteSessionJournal,
         now: @escaping @Sendable () -> Date = { Date() }, responseTimeout: Duration = .seconds(15),
         requestReviewLifetime: TimeInterval = 15 * 60) {
        self.serverId = serverId; self.runtimeId = runtimeId
        self.channel = channel; self.journal = journal
        self.now = now; self.responseTimeout = responseTimeout
        self.requestReviewLifetime = requestReviewLifetime
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.termination = pair.stream; self.terminated = pair.continuation
    }

    func bind(ref: RemoteSessionRef, vendorThreadId: String, baseline: RemoteSessionProjection) async throws {
        guard phase != .stopped else { throw ChatGPTEventPumpError.stopped }
        guard ref.serverId == serverId, ref.runtimeId == runtimeId, ref.agentId == "agent.chatgpt",
              !vendorThreadId.isEmpty, vendorThreadId.utf8.count <= 256, !vendorThreadId.contains("\0"), bindings.count < 128,
              baseline.control.controlMode == "readOnly" else { throw ChatGPTEventPumpError.invalidBinding }
        guard bindings[vendorThreadId] == nil, !bindings.values.contains(where: { $0.projector.ref == ref }) else { throw ChatGPTEventPumpError.duplicateBinding }
        let lease = UUID()
        bindings[vendorThreadId] = .init(lease: lease, projector: .init(ref: ref, vendorThreadId: vendorThreadId), epoch: nil, status: .indexing)
        do {
            let snapshot = try await journal.replace(ref: ref, projection: baseline)
            guard var binding = bindings[vendorThreadId], binding.lease == lease else { throw ChatGPTEventPumpError.stopped }
            let wasInvalidated = binding.status != .indexing
            let wasUnbound = binding.status == .invalidating && phase != .stopped
            binding.epoch = snapshot.streamEpoch
            binding.status = phase == .stopped || wasInvalidated ? .invalidating : .active
            bindings[vendorThreadId] = binding
            if phase == .stopped || wasInvalidated {
                await degrade(vendorThreadId, lease: lease, reason: "baseline_invalidated")
                if wasUnbound, bindings[vendorThreadId]?.lease == lease { bindings.removeValue(forKey: vendorThreadId) }
                throw ChatGPTEventPumpError.stopped
            }
        } catch {
            if bindings[vendorThreadId]?.lease == lease, bindings[vendorThreadId]?.epoch == nil { bindings.removeValue(forKey: vendorThreadId) }
            throw error
        }
    }

    func start() throws {
        guard phase == .idle else { throw phase == .stopped ? ChatGPTEventPumpError.stopped : ChatGPTEventPumpError.alreadyStarted }
        guard !bindings.values.contains(where: { $0.status == .indexing }) else { throw ChatGPTEventPumpError.invalidBinding }
        phase = .running
        let events = channel.events
        worker = Task { [weak self] in
            do {
                for try await event in events {
                    guard !Task.isCancelled, let self else { break }
                    await self.receive(event)
                }
            } catch { /* All terminal errors downgrade bindings below. */ }
            await self?.ended()
        }
    }

    func status(vendorThreadId: String) -> Status { bindings[vendorThreadId]?.status ?? .removed }

    /// Read-only hydration. A quiet snapshot is required: events observed during
    /// read/commit invalidate the attempt rather than replaying potentially
    /// already-included deltas. The caller may retry; continuous active threads
    /// need a vendor revision-aware reconciliation adapter before attachment.
    func hydrate(ref: RemoteSessionRef, vendorThreadId: String, executionEpoch: String,
                 freshEphemeral: Bool = false, freshPersistent: Bool = false) async throws {
        guard phase == .running else { throw ChatGPTEventPumpError.stopped }
        guard ref.serverId == serverId, ref.runtimeId == runtimeId, ref.agentId == "agent.chatgpt",
              !vendorThreadId.isEmpty, vendorThreadId.utf8.count <= 256, !vendorThreadId.contains("\0"), bindings.count < 128 else {
            throw ChatGPTEventPumpError.invalidBinding
        }
        guard bindings[vendorThreadId] == nil, !bindings.values.contains(where: { $0.projector.ref == ref }) else { throw ChatGPTEventPumpError.duplicateBinding }
        let lease = UUID(), projector = ChatGPTEventProjector(ref: ref, vendorThreadId: vendorThreadId)
        bindings[vendorThreadId] = .init(lease: lease, projector: projector, epoch: nil, status: .indexing)
        do {
            let reader = ChatGPTBaselineReader(channel: channel)
            let response = try await (freshEphemeral
                ? reader.readFreshEphemeral(threadId: vendorThreadId)
                : freshPersistent ? reader.readFreshPersistent(threadId: vendorThreadId) : reader.read(threadId: vendorThreadId))
            try Task.checkCancellation()
            let baseline = try projector.baseline(response: response, executionEpoch: executionEpoch)
            guard baseline.control.controlMode == "readOnly" else { throw ChatGPTEventPumpError.incompatibleBaseline }
            try await checkpoint()
            try Task.checkCancellation()
            guard phase == .running, bindings[vendorThreadId]?.lease == lease,
                  bindings[vendorThreadId]?.status == .indexing else { throw ChatGPTEventPumpError.baselineChanged }
            let snapshot = try await journal.replace(ref: ref, projection: baseline)
            guard var binding = bindings[vendorThreadId], binding.lease == lease else { throw ChatGPTEventPumpError.stopped }
            binding.epoch = snapshot.streamEpoch
            if baseline.control.currentTurnId != nil,
               case .object(let result) = response, case .object(let thread) = result["thread"],
               case .array(let turns) = thread["turns"], case .object(let turn) = turns.last,
               case .string(let id) = turn["id"], projector.identifier("turn", id) == baseline.control.currentTurnId {
                binding.vendorCurrentTurnId = id
                binding.fileChanges = Self.fileChanges(in: turn)
            }
            let ready = phase == .running && binding.status == .indexing && !Task.isCancelled
            binding.status = ready ? .active : .invalidating
            bindings[vendorThreadId] = binding
            if !ready {
                await degrade(vendorThreadId, lease: lease, reason: "baseline_invalidated")
                throw ChatGPTEventPumpError.baselineChanged
            }
        } catch {
            if bindings[vendorThreadId]?.lease == lease, bindings[vendorThreadId]?.status != .active { bindings.removeValue(forKey: vendorThreadId) }
            throw error
        }
    }

    @discardableResult
    private func checkpoint() async throws -> UInt64 {
        guard phase == .running else {throw ChatGPTEventPumpError.stopped}
        let id = UUID(), pair = AsyncThrowingStream<Void, Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        checkpoints[id] = pair.continuation
        let timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            await self?.failCheckpoint(id, error: AgentRPCError.timedOut)
        }
        defer { timeout.cancel(); checkpoints.removeValue(forKey: id)?.finish() }
        let revision = try await channel.checkpoint(id)
        var iterator = pair.stream.makeAsyncIterator()
        guard try await iterator.next() != nil else { throw CancellationError() }
        return revision
    }
    private func failCheckpoint(_ id: UUID, error: Error) { checkpoints.removeValue(forKey: id)?.finish(throwing: error) }
    private func failCheckpoints() {
        for waiter in checkpoints.values { waiter.finish(throwing: AgentRPCError.disconnected) }
        checkpoints.removeAll()
    }

    /// Only the coordinator of a confirmed locally resumed execution may call
    /// this. Fresh starts require a thread created by this private process or
    /// restored from its local phone-conversation manifest.
    func enableOwnedInterrupt(vendorThreadId: String, allowSteer: Bool = false,
                              allowFreshStart: Bool = false, allowRequests: Bool = false) async throws {
        try await checkpoint()
        guard var binding = bindings[vendorThreadId], current(vendorThreadId, lease: binding.lease), let epoch = binding.epoch else {
            throw ChatGPTEventPumpError.invalidBinding
        }
        guard !binding.enablingControl else {throw ChatGPTEventPumpError.invalidBinding}
        if binding.projector.allowsOwnedInterrupt && (!allowSteer || binding.projector.allowsOwnedSteer)
            && (!allowFreshStart || binding.projector.allowsOwnedFreshStart)
            && (!allowRequests || binding.projector.allowsOwnedRequests) {return}
        let previousInterrupt = binding.projector.allowsOwnedInterrupt
        let previousSteer = binding.projector.allowsOwnedSteer
        let previousFreshStart = binding.projector.allowsOwnedFreshStart
        let previousRequests = binding.projector.allowsOwnedRequests
        let snapshot = try await journal.snapshot(ref: binding.projector.ref)
        guard current(vendorThreadId, lease: binding.lease), snapshot.streamEpoch == epoch,
              ["readOnly", "live"].contains(snapshot.projection.control.controlMode) else {throw ChatGPTEventPumpError.baselineChanged}
        let previous = snapshot.projection.control
        if let turn = previous.currentTurnId {
            guard let vendor = binding.vendorCurrentTurnId, binding.projector.identifier("turn", vendor) == turn else {
                throw ChatGPTEventPumpError.incompatibleBaseline
            }
        }
        binding.projector.allowsOwnedInterrupt = true
        binding.projector.allowsOwnedSteer = previousSteer || allowSteer
        binding.projector.allowsOwnedFreshStart = previousFreshStart || allowFreshStart
        binding.projector.allowsOwnedRequests = previousRequests || allowRequests
        let control = RemoteSessionControl(executionEpoch: previous.executionEpoch, controlRevision: previous.controlRevision + 1,
            state: previous.state, controlMode: "live", currentTurnId: previous.currentTurnId,
            allowedActions: binding.projector.ownedActions(state: previous.state, currentTurnId: previous.currentTurnId,
                hasPendingRequests: !snapshot.projection.pendingRequests.isEmpty, pendingRequests: snapshot.projection.pendingRequests))
        bindings[vendorThreadId]?.projector = binding.projector
        bindings[vendorThreadId]?.enablingControl = true
        do {
            _ = try await journal.append(ref: binding.projector.ref, mutations: [.control(control)],
                expectedStreamEpoch: epoch, expectedSequence: snapshot.sequence)
            guard current(vendorThreadId, lease: binding.lease) else {throw ChatGPTEventPumpError.stopped}
            bindings[vendorThreadId]?.enablingControl = false
        } catch {
            if bindings[vendorThreadId]?.lease == binding.lease {
                bindings[vendorThreadId]?.projector.allowsOwnedInterrupt = previousInterrupt
                bindings[vendorThreadId]?.projector.allowsOwnedSteer = previousSteer
                bindings[vendorThreadId]?.projector.allowsOwnedFreshStart = previousFreshStart
                bindings[vendorThreadId]?.projector.allowsOwnedRequests = previousRequests
                bindings[vendorThreadId]?.enablingControl = false
                await degrade(vendorThreadId, lease: binding.lease, reason: "control_activation_failed")
            }
            throw error
        }
    }

    func commandContext(ref: RemoteSessionRef) async throws -> ChatGPTCommandContext {
        try await checkpoint()
        guard let (thread, binding) = bindings.first(where: {$0.value.projector.ref == ref}),
              current(thread, lease: binding.lease), binding.projector.allowsOwnedInterrupt, !binding.enablingControl, let epoch = binding.epoch else {
            throw ChatGPTEventPumpError.invalidBinding
        }
        let snapshot = try await journal.snapshot(ref: ref)
        guard current(thread, lease: binding.lease), bindings[thread]?.enablingControl == false, snapshot.streamEpoch == epoch else {throw ChatGPTEventPumpError.baselineChanged}
        return .init(ref: ref, vendorThreadId: thread, vendorCurrentTurnId: bindings[thread]?.vendorCurrentTurnId,
            control: snapshot.projection.control, hasPendingRequests: !snapshot.projection.pendingRequests.isEmpty,
            permitsFreshStart: binding.projector.allowsOwnedFreshStart)
    }

    func validateResponse(_ operation: RemoteOperationRequest) async throws {
        let input = try ChatGPTRequestResponse(operation)
        guard !responsesInFlight.contains(input.requestId), !responsesClaimed.contains(input.requestId) else {
            throw RemoteCommandError.sessionBusy
        }
        let context = try await responseContext(operation, input: input)
        _ = try input.encode(for: context.mapped)
    }

    /// No arbitrary reply endpoint. The dispatcher supplies a fresh scoped
    /// authorization/dispatch-lease check at this private commit boundary.
    func respond(_ operation: RemoteOperationRequest,
                 authorizeBeforeCommit: @escaping @Sendable () async throws -> Void) async -> RemoteCommandOutcome {
        let input: ChatGPTRequestResponse
        do { input = try .init(operation) } catch { return .rejected }
        guard !responsesInFlight.contains(input.requestId), !responsesClaimed.contains(input.requestId) else { return .rejected }
        responsesInFlight.insert(input.requestId)
        defer { responsesInFlight.remove(input.requestId) }
        let context: ResponseContext, result: AgentJSON
        do {
            context = try await responseContext(operation, input: input)
            result = try input.encode(for: context.mapped)
            try await authorizeBeforeCommit()
            try Task.checkCancellation()
            guard responseIsCurrent(context), !responsesClaimed.contains(input.requestId),
                  let expiry = ISO8601DateFormatter().date(from: context.mapped.request.expiresAt), expiry > now() else {
                return .rejected
            }
        } catch { return .rejected }
        let pair = AsyncStream<RemoteCommandOutcome>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let token = UUID(), id = input.requestId
        responseAttempts[id] = .init(token: token, thread: context.thread, lease: context.lease, continuation: pair.continuation)
        responsesClaimed.insert(id)
        let duration = responseTimeout
        let timeout = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            await self?.responseTimedOut(id, token: token)
        }
        defer { timeout.cancel(); finishResponse(id, token: token, outcome: .uncertain) }
        do {
            try await channel.reply(id: context.mapped.rpcId, result: result, expectedEventRevision: context.revision)
            responseAttempts[id]?.written = true
            completeResponseIfReady(id)
        } catch AgentRPCError.staleRequest {
            responsesClaimed.remove(id); finishResponse(id, token: token, outcome: .rejected)
        } catch AgentRPCError.unknownRequest {
            responsesClaimed.remove(id); finishResponse(id, token: token, outcome: .rejected)
        } catch {
            finishResponse(id, token: token, outcome: .uncertain)
            if current(context.thread, lease: context.lease) { await degrade(context.thread, lease: context.lease, reason: "request_response_uncertain") }
        }
        var iterator = pair.stream.makeAsyncIterator()
        if let outcome = await iterator.next() { return outcome }
        if current(context.thread, lease: context.lease) { await degrade(context.thread, lease: context.lease, reason: "request_response_uncertain") }
        return .uncertain
    }

    private func responseContext(_ operation: RemoteOperationRequest, input: ChatGPTRequestResponse) async throws -> ResponseContext {
        let revision = try await checkpoint()
        guard let (thread, binding) = bindings.first(where: { $0.value.projector.ref == operation.ref }),
              current(thread, lease: binding.lease), binding.projector.allowsOwnedRequests, binding.projector.allowsOwnedInterrupt,
              !binding.enablingControl, let epoch = binding.epoch,
              let mapped = binding.requests.values.first(where: { $0.request.requestId == input.requestId }),
              mapped.request.requestRevision == input.requestRevision, mapped.request.turnId == input.turnId,
              mapped.request.executionEpoch == operation.executionEpoch,
              mapped.vendorTurnId == binding.vendorCurrentTurnId,
              let expiry = ISO8601DateFormatter().date(from: mapped.request.expiresAt), expiry > now() else {
            throw RemoteCommandError.controlChanged
        }
        let snapshot = try await journal.snapshot(ref: operation.ref)
        let context = ResponseContext(thread: thread, lease: binding.lease, epoch: epoch, revision: revision, mapped: mapped)
        guard responseIsCurrent(context), snapshot.streamEpoch == epoch,
              snapshot.projection.control.executionEpoch == operation.executionEpoch,
              snapshot.projection.control.currentTurnId == input.turnId, snapshot.projection.control.controlMode == "live",
              snapshot.projection.control.allowedActions.contains(operation.action.rawValue),
              snapshot.projection.pendingRequests.contains(mapped.request) else { throw RemoteCommandError.controlChanged }
        return context
    }
    private func responseIsCurrent(_ context: ResponseContext) -> Bool {
        guard let binding = bindings[context.thread] else { return false }
        return current(context.thread, lease: context.lease) && binding.epoch == context.epoch && !binding.enablingControl
            && binding.projector.allowsOwnedRequests && binding.vendorCurrentTurnId == context.mapped.vendorTurnId
            && binding.requests[context.mapped.rpcId]?.request == context.mapped.request
    }
    private func completeResponseIfReady(_ id: String) {
        guard let attempt = responseAttempts[id], attempt.written, attempt.resolved else { return }
        // Applied describes delivery and correlated resolution of the response,
        // not successful execution of the reviewed command or subsequent turn.
        finishResponse(id, token: attempt.token, outcome: .applied(turnId: nil))
    }
    private func finishResponse(_ id: String, token: UUID, outcome: RemoteCommandOutcome) {
        guard let attempt = responseAttempts[id], attempt.token == token else { return }
        responseAttempts.removeValue(forKey: id)
        attempt.continuation.yield(outcome); attempt.continuation.finish()
    }
    private func responseTimedOut(_ id: String, token: UUID) async {
        guard let attempt = responseAttempts[id], attempt.token == token else { return }
        finishResponse(id, token: token, outcome: .uncertain)
        if current(attempt.thread, lease: attempt.lease) { await degrade(attempt.thread, lease: attempt.lease, reason: "request_response_uncertain") }
    }

    private func scheduleExpiry(_ mapped: ChatGPTMappedServerRequest, thread: String, lease: UUID) {
        guard let deadline = ISO8601DateFormatter().date(from: mapped.request.expiresAt) else { return }
        let id = mapped.request.requestId, delay = max(0, deadline.timeIntervalSince(now()))
        expiryTasks.removeValue(forKey: id)?.cancel()
        expiryTasks[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.expireRequest(mapped, thread: thread, lease: lease)
        }
    }
    private func expireRequest(_ mapped: ChatGPTMappedServerRequest, thread: String, lease: UUID) async {
        guard current(thread, lease: lease), bindings[thread]?.requests[mapped.rpcId]?.request == mapped.request else { return }
        if let deadline = ISO8601DateFormatter().date(from: mapped.request.expiresAt), deadline > now() {
            scheduleExpiry(mapped, thread: thread, lease: lease); return
        }
        // Only withdraw remote control. Expiration never rejects, cancels or
        // answers the upstream request on behalf of the user.
        await degrade(thread, lease: lease, reason: "request_expired")
    }
    private func withdrawRoutes(_ thread: String, keeping turn: String? = nil) {
        guard let binding = bindings[thread] else { return }
        for mapped in binding.requests.values where mapped.vendorTurnId != turn {
            let id = mapped.request.requestId
            expiryTasks.removeValue(forKey: id)?.cancel(); responsesClaimed.remove(id)
            if let attempt = responseAttempts[id] { finishResponse(id, token: attempt.token, outcome: .uncertain) }
        }
        bindings[thread]?.requests = binding.requests.filter { $0.value.vendorTurnId == turn }
    }

    func unbind(vendorThreadId: String) async {
        guard let binding = bindings[vendorThreadId] else { return }
        // Keep the reservation until durable invalidation completes. Rebinding
        // cannot replace a baseline while an old unregister is still writing.
        bindings[vendorThreadId]?.status = .invalidating
        if binding.epoch == nil { return }
        await degrade(vendorThreadId, lease: binding.lease, reason: "session_unbound")
        if bindings[vendorThreadId]?.lease == binding.lease { bindings.removeValue(forKey: vendorThreadId) }
    }

    func stop() async {
        phase = .stopped
        failCheckpoints()
        await invalidateAll(reason: "runtime_stopped")
        await channel.close()
        worker?.cancel()
        terminated.yield(()); terminated.finish()
        await worker?.value
        worker = nil
    }

    private func receive(_ event: AgentRPCEvent) async {
        guard phase == .running else { return }
        let params: AgentJSON
        let isRequest: Bool
        let method: String
        switch event {
        case .checkpoint(let id):
            if let waiter = checkpoints.removeValue(forKey: id) { waiter.yield(()); waiter.finish() }
            return
        case .notification(let name, let value): params = value; isRequest = false; method = name
        case .request(_, let name, let value): params = value; isRequest = true; method = name
        }
        guard case .object(let fields) = params, case .string(let threadId) = fields["threadId"] else {
            // Global auth-refresh requests affect every bound session. They must
            // be handled by a dedicated auth adapter before this channel is live.
            if isRequest || ["turn/started", "turn/completed", "item/started", "item/completed", "item/agentMessage/delta", "item/fileChange/patchUpdated"].contains(method) {
                phase = .stopped
                await invalidateAll(reason: "invalid_runtime_event")
                await channel.close(.invalidFrame)
            }
            return
        }
        if bindings[threadId]?.status == .indexing {
            bindings[threadId]?.status = .requiresSync("events_during_index")
            return
        }
        guard let binding = bindings[threadId], binding.status == .active, let epoch = binding.epoch else { return }
        do {
            let snapshot = try await journal.snapshot(ref: binding.projector.ref)
            guard current(threadId, lease: binding.lease) else { return }
            guard snapshot.streamEpoch == epoch else {
                bindings[threadId]?.status = .requiresSync("projection_replaced")
                withdrawRoutes(threadId)
                return
            }
            if case .request(let id, _, _) = event, binding.projector.allowsOwnedRequests {
                guard binding.projector.allowsOwnedInterrupt, !binding.enablingControl, binding.requests[id] == nil,
                      binding.vendorCurrentTurnId != nil else { throw ChatGPTEventPumpError.invalidBinding }
                let mapped = try ChatGPTServerRequestMapper.map(id: id, method: method, params: params,
                    projector: binding.projector, control: snapshot.projection.control, now: now(), reviewLifetime: requestReviewLifetime,
                    fileChanges: { if case .string(let item) = fields["itemId"] { return binding.fileChanges[item] }; return nil }())
                let pending = snapshot.projection.pendingRequests + [mapped.request]
                let mutation: RemoteJournalMutation = mapped.request.type == "question" ? .question(mapped.request) : .approval(mapped.request)
                _ = try await journal.append(ref: binding.projector.ref, mutations: [mutation, .control(requestControl(binding.projector,
                    previous: snapshot.projection.control, pending: pending))], expectedStreamEpoch: epoch, expectedSequence: snapshot.sequence)
                if current(threadId, lease: binding.lease) {
                    bindings[threadId]?.requests[id] = mapped
                    scheduleExpiry(mapped, thread: threadId, lease: binding.lease)
                }
                return
            }
            if method == "serverRequest/resolved", !isRequest {
                guard let rawId = fields["requestId"] else { throw AgentRPCError.invalidFrame }
                let id = try AgentRPCID(rawId)
                // A terminal turn may already have withdrawn this callback.
                guard let mapped = binding.requests[id] else { return }
                guard snapshot.projection.pendingRequests.contains(mapped.request) else { throw ChatGPTEventPumpError.baselineChanged }
                bindings[threadId]?.requests.removeValue(forKey: id)
                expiryTasks.removeValue(forKey: mapped.request.requestId)?.cancel()
                responsesClaimed.remove(mapped.request.requestId)
                let pending = snapshot.projection.pendingRequests.filter { $0.requestId != mapped.request.requestId }
                let resolution: RemoteJournalMutation = mapped.request.type == "question"
                    ? .resolveQuestion(requestId: mapped.request.requestId, expectedRevision: mapped.request.requestRevision)
                    : .resolveApproval(requestId: mapped.request.requestId, expectedRevision: mapped.request.requestRevision)
                _ = try await journal.append(ref: binding.projector.ref, mutations: [resolution, .control(requestControl(binding.projector,
                    previous: snapshot.projection.control, pending: pending))], expectedStreamEpoch: epoch, expectedSequence: snapshot.sequence)
                if current(threadId, lease: binding.lease), bindings[threadId]?.vendorCurrentTurnId == mapped.vendorTurnId,
                   responseAttempts[mapped.request.requestId]?.lease == binding.lease {
                    responseAttempts[mapped.request.requestId]?.resolved = true
                    completeResponseIfReady(mapped.request.requestId)
                }
                return
            }
            var mutations: [RemoteJournalMutation]
            switch binding.projector.project(event, onto: snapshot.projection) {
            case .ignored: mutations = []
            case .requiresSync:
                await degrade(threadId, lease: binding.lease, reason: "upstream_sync_required")
                return
            case .mutations(let values): mutations = values
            }
            var cache = binding.fileChanges
            var changed: [ChatGPTMappedServerRequest] = []
            if let proposal = try Self.fileChangeEvent(method: method, fields: fields) {
                guard binding.vendorCurrentTurnId == proposal.turn else { throw ChatGPTEventPumpError.baselineChanged }
                let pending = binding.requests.values.filter { $0.vendorTurnId == proposal.turn && $0.vendorItemId == proposal.item && $0.request.fileApproval != nil }
                if proposal.completed {
                    guard pending.isEmpty else { throw ChatGPTEventPumpError.baselineChanged }
                    cache.removeValue(forKey: proposal.item)
                } else {
                    cache[proposal.item] = proposal.changes
                    guard cache.count <= 128, try JSONEncoder().encode(cache).count <= 2 * 1024 * 1024 else {
                        throw ChatGPTServerRequestError.unsupported
                    }
                    for mapped in pending where mapped.request.fileApproval?.changes != proposal.changes {
                        guard !responsesClaimed.contains(mapped.request.requestId) else { throw ChatGPTEventPumpError.baselineChanged }
                        let update = try mapped.replacingFileChanges(proposal.changes)
                        changed.append(update); mutations.append(.approval(update.request))
                    }
                }
            }
            if !mutations.isEmpty {
                _ = try await journal.append(ref: binding.projector.ref, mutations: mutations,
                    expectedStreamEpoch: epoch, expectedSequence: snapshot.sequence)
            }
            guard current(threadId, lease: binding.lease) else { return }
            bindings[threadId]?.fileChanges = cache
            for update in changed {
                bindings[threadId]?.requests[update.rpcId] = update
                scheduleExpiry(update, thread: threadId, lease: binding.lease)
            }
            if ["turn/started", "turn/completed"].contains(method),
               case .object(let turn) = fields["turn"], case .string(let id) = turn["id"], case .string(let status) = turn["status"] {
                bindings[threadId]?.vendorCurrentTurnId = status == "inProgress" ? id : nil
                bindings[threadId]?.fileChanges = status == "inProgress" ? Self.fileChanges(in: turn) : [:]
                withdrawRoutes(threadId, keeping: status == "inProgress" ? id : nil)
            }
        } catch {
            if current(threadId, lease: binding.lease) { await degrade(threadId, lease: binding.lease, reason: "projection_failed") }
        }
    }

    private struct FileChangeEvent {
        let turn: String, item: String
        let changes: [RemoteFileChange]
        let completed: Bool
    }
    private static func fileChangeEvent(method: String, fields: [String: AgentJSON]) throws -> FileChangeEvent? {
        let raw: AgentJSON, itemId: AgentJSON?, completed: Bool
        if method == "item/fileChange/patchUpdated" {
            guard Set(fields.keys) == ["threadId", "turnId", "itemId", "changes"], let changes = fields["changes"] else {
                throw ChatGPTServerRequestError.invalidRequest
            }
            raw = changes; itemId = fields["itemId"]; completed = false
        } else if ["item/started", "item/completed"].contains(method),
                  case .object(let item) = fields["item"], item["type"] == .string("fileChange") {
            guard Set(item.keys) == ["id", "type", "status", "changes"], let changes = item["changes"],
                  case .string(let status) = item["status"], ["inProgress", "completed", "failed", "declined"].contains(status) else {
                throw ChatGPTServerRequestError.invalidRequest
            }
            raw = changes; itemId = item["id"]; completed = method == "item/completed" || status != "inProgress"
        } else { return nil }
        guard case .string(let turn) = fields["turnId"], case .string(let item) = itemId,
              !turn.isEmpty, !item.isEmpty, turn.utf8.count <= 256, item.utf8.count <= 256,
              !turn.contains("\0"), !item.contains("\0") else { throw ChatGPTServerRequestError.invalidRequest }
        return .init(turn: turn, item: item, changes: try ChatGPTServerRequestMapper.fileChanges(raw), completed: completed)
    }
    private static func fileChanges(in turn: [String: AgentJSON]) -> [String: [RemoteFileChange]] {
        guard case .array(let items) = turn["items"] else { return [:] }
        var result: [String: [RemoteFileChange]] = [:]
        for value in items {
            guard case .object(let item) = value, item["type"] == .string("fileChange"), item["status"] == .string("inProgress"),
                  case .string(let id) = item["id"], !id.isEmpty, id.utf8.count <= 256, !id.contains("\0"),
                  Set(item.keys) == ["id", "type", "status", "changes"], let raw = item["changes"],
                  let changes = try? ChatGPTServerRequestMapper.fileChanges(raw) else { continue }
            result[id] = changes
        }
        // Omit an oversized baseline cache, never publish a partial proposal.
        guard result.count <= 128, ((try? JSONEncoder().encode(result).count) ?? Int.max) <= 2 * 1024 * 1024 else { return [:] }
        return result
    }

    private func current(_ thread: String, lease: UUID) -> Bool {
        bindings[thread]?.lease == lease && bindings[thread]?.status == .active && phase == .running
    }
    private func requestControl(_ projector: ChatGPTEventProjector, previous: RemoteSessionControl,
                                pending: [RemotePendingRequest]) -> RemoteSessionControl {
        let state = pending.contains(where: \.isBlocking) ? "waitingForUser" : "running"
        return .init(executionEpoch: previous.executionEpoch, controlRevision: previous.controlRevision + 1,
            state: state, controlMode: previous.controlMode, currentTurnId: previous.currentTurnId,
            allowedActions: projector.ownedActions(state: state, currentTurnId: previous.currentTurnId,
                hasPendingRequests: !pending.isEmpty, pendingRequests: pending))
    }
    private func degrade(_ thread: String, lease: UUID, reason: String) async {
        guard let binding = bindings[thread], binding.lease == lease, let epoch = binding.epoch else { return }
        bindings[thread]?.status = .requiresSync(reason)
        withdrawRoutes(thread)
        // A resolved callback may already be removed from routes while its
        // writer is returning. Runtime invalidation must also finish that wait.
        for (id, attempt) in responseAttempts where attempt.thread == thread && attempt.lease == lease {
            finishResponse(id, token: attempt.token, outcome: .uncertain)
        }
        do { _ = try await journal.requireSync(ref: binding.projector.ref, expectedStreamEpoch: epoch, reason: reason) }
        catch RemoteJournalError.revisionConflict {
            if bindings[thread]?.lease == lease { bindings[thread]?.status = .requiresSync("projection_replaced") }
        } catch {
            if bindings[thread]?.lease == lease { bindings[thread]?.status = .storageFailed }
        }
    }
    private func invalidateAll(reason: String) async {
        let active = bindings.filter { $0.value.status == .active || $0.value.status == .indexing }
        // Mark every binding before the first await so none accepts late events.
        for (thread, _) in active { bindings[thread]?.status = .invalidating }
        for (thread, binding) in active { await degrade(thread, lease: binding.lease, reason: reason) }
    }
    private func ended() async {
        defer { terminated.yield(()); terminated.finish() }
        failCheckpoints()
        guard phase != .stopped else { return }
        phase = .stopped
        await invalidateAll(reason: "runtime_disconnected")
    }
}
