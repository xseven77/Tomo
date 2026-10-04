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

    init(serverId: String, runtimeId: String, channel: AgentRPCChannel, journal: RemoteSessionJournal) {
        self.serverId = serverId; self.runtimeId = runtimeId
        self.channel = channel; self.journal = journal
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
                 freshEphemeral: Bool = false) async throws {
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
                : reader.read(threadId: vendorThreadId))
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

    private func checkpoint() async throws {
        guard phase == .running else {throw ChatGPTEventPumpError.stopped}
        let id = UUID(), pair = AsyncThrowingStream<Void, Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        checkpoints[id] = pair.continuation
        let timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            await self?.failCheckpoint(id, error: AgentRPCError.timedOut)
        }
        defer { timeout.cancel(); checkpoints.removeValue(forKey: id)?.finish() }
        try await channel.checkpoint(id)
        var iterator = pair.stream.makeAsyncIterator()
        guard try await iterator.next() != nil else { throw CancellationError() }
    }
    private func failCheckpoint(_ id: UUID, error: Error) { checkpoints.removeValue(forKey: id)?.finish(throwing: error) }
    private func failCheckpoints() {
        for waiter in checkpoints.values { waiter.finish(throwing: AgentRPCError.disconnected) }
        checkpoints.removeAll()
    }

    /// Only the coordinator of a confirmed locally resumed execution may call
    /// this. Fresh starts are reserved for a thread created as ephemeral by
    /// this same private process; the coordinator checks that provenance.
    func enableOwnedInterrupt(vendorThreadId: String, allowSteer: Bool = false,
                              allowFreshStart: Bool = false) async throws {
        try await checkpoint()
        guard var binding = bindings[vendorThreadId], current(vendorThreadId, lease: binding.lease), let epoch = binding.epoch else {
            throw ChatGPTEventPumpError.invalidBinding
        }
        guard !binding.enablingControl else {throw ChatGPTEventPumpError.invalidBinding}
        if binding.projector.allowsOwnedInterrupt && (!allowSteer || binding.projector.allowsOwnedSteer)
            && (!allowFreshStart || binding.projector.allowsOwnedFreshStart) {return}
        let previousInterrupt = binding.projector.allowsOwnedInterrupt
        let previousSteer = binding.projector.allowsOwnedSteer
        let previousFreshStart = binding.projector.allowsOwnedFreshStart
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
        let control = RemoteSessionControl(executionEpoch: previous.executionEpoch, controlRevision: previous.controlRevision + 1,
            state: previous.state, controlMode: "live", currentTurnId: previous.currentTurnId,
            allowedActions: binding.projector.ownedActions(state: previous.state, currentTurnId: previous.currentTurnId,
                hasPendingRequests: !snapshot.projection.pendingRequests.isEmpty))
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
            if isRequest || ["turn/started", "turn/completed", "item/started", "item/completed", "item/agentMessage/delta"].contains(method) {
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
                return
            }
            switch binding.projector.project(event, onto: snapshot.projection) {
            case .ignored: return
            case .requiresSync:
                await degrade(threadId, lease: binding.lease, reason: "upstream_sync_required")
            case .mutations(let mutations):
                guard !mutations.isEmpty else { return }
                _ = try await journal.append(ref: binding.projector.ref, mutations: mutations,
                    expectedStreamEpoch: epoch, expectedSequence: snapshot.sequence)
                if current(threadId, lease: binding.lease), ["turn/started", "turn/completed"].contains(method),
                   case .object(let turn) = fields["turn"], case .string(let id) = turn["id"],
                   case .string(let status) = turn["status"] {
                    bindings[threadId]?.vendorCurrentTurnId = status == "inProgress" ? id : nil
                }
            }
        } catch {
            if current(threadId, lease: binding.lease) { await degrade(threadId, lease: binding.lease, reason: "projection_failed") }
        }
    }

    private func current(_ thread: String, lease: UUID) -> Bool {
        bindings[thread]?.lease == lease && bindings[thread]?.status == .active && phase == .running
    }
    private func degrade(_ thread: String, lease: UUID, reason: String) async {
        guard let binding = bindings[thread], binding.lease == lease, let epoch = binding.epoch else { return }
        bindings[thread]?.status = .requiresSync(reason)
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
