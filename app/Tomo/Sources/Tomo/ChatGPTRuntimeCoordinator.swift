import Foundation

enum ChatGPTRuntimeError: Error, Equatable {
    case invalidConfiguration, invalidHandshake, invalidResume, invalidState, notSubscribed, duplicateSession, interrupted
    case authenticationRequired, invalidAccountState
}

/// Local adapter-owned lifecycle, never constructed from HTTP parameters.
/// A fresh channel is initialized once. The owner must establish a vendor
/// subscription before registering its session here; thread/read is not one.
actor ChatGPTRuntimeCoordinator {
    enum State: Sendable, Equatable { case idle, starting, ready, stopping, stopped, failed }
    private struct Entry {
        let ref: RemoteSessionRef
        let thread: String
        let reservation: UUID
        var sourceLease: UUID?
        var commands: (service: RemoteOperationService, lease: UUID)?
        var invalidating = false
    }
    private let serverId: String
    private let runtimeId: String
    private let channel: AgentRPCChannel
    private let pump: ChatGPTRuntimeEventPump
    private let journal: RemoteSessionJournal
    private let service: RemoteSessionService
    private let stopTransport: @Sendable () async -> Void
    private let executionEpoch = UUID().uuidString
    private var state = State.idle
    private var generation = 0
    private var subscriptions: [String: String] = [:] // opaque session -> private vendor thread
    private var ownedSessions = Set<String>()
    private var freshStartSessions = Set<String>()
    private var ephemeralSessions = Set<String>()
    private var newPersistentSessions = Set<String>()
    private var commandAdapter: ChatGPTCommandAdapter?
    private var interactiveAdapter: ChatGPTInteractiveCommandAdapter?
    private var resuming: [String: (thread: String, reservation: UUID)] = [:]
    private var entries: [String: Entry] = [:]
    private var shutdownTask: Task<Void, Never>?
    private var shutdownResult = State.stopped
    private var monitor: Task<Void, Never>?

    init(serverId: String, runtimeId: String, channel: AgentRPCChannel, journal: RemoteSessionJournal,
         service: RemoteSessionService, stopTransport: @escaping @Sendable () async -> Void) throws {
        guard [serverId, runtimeId].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }) else {
            throw ChatGPTRuntimeError.invalidConfiguration
        }
        self.serverId = serverId; self.runtimeId = runtimeId; self.channel = channel
        self.journal = journal; self.service = service; self.stopTransport = stopTransport
        self.pump = ChatGPTRuntimeEventPump(serverId: serverId, runtimeId: runtimeId, channel: channel, journal: journal)
    }
    func currentState() -> State { state }

    /// Check the selected local provider before advertising the default phone
    /// conversation as writable. Never retain or export the account response.
    func requirePhoneAuthentication() async throws {
        guard state == .ready else {throw ChatGPTRuntimeError.invalidState}
        let lease = generation
        let response = try await channel.request(method: "account/read", params: .object(["refreshToken": .bool(false)]))
        try Task.checkCancellation()
        guard state == .ready, generation == lease else {throw ChatGPTRuntimeError.interrupted}
        guard case .object(let fields) = response, case .bool(let required) = fields["requiresOpenaiAuth"],
              let account = fields["account"] else {throw ChatGPTRuntimeError.invalidAccountState}
        switch account {
        case .null:
            if required {throw ChatGPTRuntimeError.authenticationRequired}
        case .object(let account):
            guard case .string(let type) = account["type"], !type.isEmpty, type.utf8.count <= 128 else {
                throw ChatGPTRuntimeError.invalidAccountState
            }
        default: throw ChatGPTRuntimeError.invalidAccountState
        }
    }

    func start() async throws {
        guard state == .idle else { throw ChatGPTRuntimeError.invalidState }
        state = .starting; generation += 1
        let lease = generation
        do {
            guard service.serverId == serverId else { throw ChatGPTRuntimeError.invalidConfiguration }
            let response = try await channel.request(method: "initialize", params: .object([
                "clientInfo": .object(["name": .string("TomoRemoteSessions"), "version": .string("1.0")]),
                "capabilities": .object(["experimentalApi": .bool(false)])]))
            guard case .object(let fields) = response, case .string(let userAgent) = fields["userAgent"],
                  !userAgent.isEmpty, userAgent.utf8.count <= 4096 else { throw ChatGPTRuntimeError.invalidHandshake }
            try Task.checkCancellation()
            guard state == .starting, generation == lease else { throw ChatGPTRuntimeError.interrupted }
            try await channel.notify(method: "initialized")
            guard state == .starting, generation == lease else { throw ChatGPTRuntimeError.interrupted }
            try await pump.start()
            guard state == .starting, generation == lease else { throw ChatGPTRuntimeError.interrupted }
            state = .ready
            let termination = pump.termination
            monitor = Task { [weak self] in
                for await _ in termination {
                    guard !Task.isCancelled else { return }
                    await self?.disconnected()
                    return
                }
            }
        } catch {
            if state == .starting, generation == lease {
                await shutdown(result: .failed)
            }
            throw error
        }
    }

    /// Trusted adapter call after its own subscription acknowledgment/barrier.
    /// No remote request or mere history read may assert this provenance.
    func registerSubscription(sessionId: String, vendorThreadId: String) throws {
        guard state == .ready else { throw ChatGPTRuntimeError.invalidState }
        guard [sessionId, vendorThreadId].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }), subscriptions.count + resuming.count < 128 else {
            throw ChatGPTRuntimeError.invalidConfiguration
        }
        guard subscriptions[sessionId] == nil, resuming[sessionId] == nil,
              !subscriptions.values.contains(vendorThreadId), !resuming.values.contains(where: { $0.thread == vendorThreadId }) else {
            throw ChatGPTRuntimeError.duplicateSession
        }
        subscriptions[sessionId] = vendorThreadId
    }

    /// Explicit local ownership operation. Unlike history reads, resume may
    /// load a thread and resume vendor goal work. Never call from a remote GET,
    /// discovery or a readonly authorization flow. An explicitly authorized
    /// web resume POST is also an ownership operation; history GETs are not.
    func resumeOwnedSession(sessionId: String, vendorThreadId: String, allowNewTurns: Bool = false) async throws {
        guard state == .ready else { throw ChatGPTRuntimeError.invalidState }
        guard [sessionId, vendorThreadId].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }),
              subscriptions.count + resuming.count < 128 else { throw ChatGPTRuntimeError.invalidConfiguration }
        guard subscriptions[sessionId] == nil, resuming[sessionId] == nil,
              !subscriptions.values.contains(vendorThreadId), !resuming.values.contains(where: { $0.thread == vendorThreadId }) else {
            throw ChatGPTRuntimeError.duplicateSession
        }
        let reservation = UUID(), lease = generation
        resuming[sessionId] = (vendorThreadId, reservation)
        do {
            // No workspace, model, permission or instruction overrides. Private
            // vendor IDs come from the locally selected account's directory
            // or the local manifest of a Tomo-created phone conversation.
            let response = try await channel.request(method: "thread/resume", params: .object([
                "threadId": .string(vendorThreadId), "excludeTurns": .bool(true)]))
            try Task.checkCancellation()
            guard state == .ready, generation == lease, resuming[sessionId]?.reservation == reservation else {
                throw ChatGPTRuntimeError.interrupted
            }
            guard case .object(let result) = response, case .object(let thread) = result["thread"],
                  thread["id"] == .string(vendorThreadId) else { throw ChatGPTRuntimeError.invalidResume }
            resuming.removeValue(forKey: sessionId)
            subscriptions[sessionId] = vendorThreadId
            ownedSessions.insert(sessionId)
            // Only a local owner action or an explicitly granted web resume
            // sets this. Merely reading a desktop history record does not.
            if allowNewTurns {freshStartSessions.insert(sessionId)}
            // attach remains separate: a quiet-baseline failure can retry the
            // read without repeating the state-changing resume operation.
        } catch {
            // After sending resume, cancellation/timeout may leave an owned
            // vendor thread even without an acknowledgment. Stop this private
            // runtime instead of retrying the mutation or asserting provenance.
            if generation == lease, state == .ready { await shutdown(result: .failed) }
            throw error
        }
    }

    /// Local owner operation on a dedicated private process. An ephemeral
    /// thread is not indexed or resumable by another process, so this process
    /// is the sole possible writer. A timeout or ambiguous ack kills it.
    func createOwnedEphemeralSession(sessionId: String, workspace: URL) async throws {
        guard state == .ready else { throw ChatGPTRuntimeError.invalidState }
        let cwd = workspace.resolvingSymlinksInPath().standardizedFileURL
        guard !sessionId.isEmpty, sessionId.utf8.count <= 256, !sessionId.contains("\0"),
              cwd.isFileURL, cwd.path.hasPrefix("/"),
              (try? cwd.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              subscriptions.count + resuming.count < 128 else { throw ChatGPTRuntimeError.invalidConfiguration }
        guard subscriptions[sessionId] == nil, resuming[sessionId] == nil else { throw ChatGPTRuntimeError.duplicateSession }
        let reservation = UUID(), lease = generation
        resuming[sessionId] = ("", reservation)
        do {
            let response = try await channel.request(method: "thread/start", params: .object([
                "ephemeral": .bool(true), "cwd": .string(cwd.path)]))
            try Task.checkCancellation()
            guard state == .ready, generation == lease, resuming[sessionId]?.reservation == reservation else {
                throw ChatGPTRuntimeError.interrupted
            }
            guard case .object(let result) = response, case .object(let thread) = result["thread"],
                  case .string(let vendorId) = thread["id"], !vendorId.isEmpty,
                  vendorId.utf8.count <= 256, !vendorId.contains("\0"),
                  thread["ephemeral"] == .bool(true), thread["path"] == .null,
                  thread["cwd"] == .string(cwd.path),
                  !subscriptions.values.contains(vendorId) else { throw ChatGPTRuntimeError.invalidResume }
            resuming.removeValue(forKey: sessionId)
            subscriptions[sessionId] = vendorId
            ownedSessions.insert(sessionId)
            freshStartSessions.insert(sessionId)
            ephemeralSessions.insert(sessionId)
        } catch {
            if generation == lease, state == .ready { await shutdown(result: .failed) }
            throw error
        }
    }

    /// A durable conversation created by this private process. Its vendor ID
    /// stays in the desktop's local manifest and is never supplied by a phone.
    struct CreatedPersistentThread: Sendable {let id: String; let rollout: URL}
    func createOwnedPersistentSession(sessionId: String, workspace: URL) async throws -> CreatedPersistentThread {
        guard state == .ready else {throw ChatGPTRuntimeError.invalidState}
        let cwd = workspace.resolvingSymlinksInPath().standardizedFileURL
        guard !sessionId.isEmpty, sessionId.utf8.count <= 256, !sessionId.contains("\0"), cwd.isFileURL,
              (try? cwd.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              subscriptions.count + resuming.count < 128 else {throw ChatGPTRuntimeError.invalidConfiguration}
        guard subscriptions[sessionId] == nil, resuming[sessionId] == nil else {throw ChatGPTRuntimeError.duplicateSession}
        let reservation = UUID(), lease = generation
        resuming[sessionId] = ("", reservation)
        do {
            let response = try await channel.request(method: "thread/start", params: .object([
                "ephemeral": .bool(false), "cwd": .string(cwd.path)]))
            try Task.checkCancellation()
            guard state == .ready, generation == lease, resuming[sessionId]?.reservation == reservation else {throw ChatGPTRuntimeError.interrupted}
            guard case .object(let result) = response, case .object(let thread) = result["thread"],
                  case .string(let vendorId) = thread["id"], !vendorId.isEmpty, vendorId.utf8.count <= 256, !vendorId.contains("\0"),
                  case .string(let path) = thread["path"], path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096,
                  thread["ephemeral"] == .bool(false), thread["cwd"] == .string(cwd.path),
                  !subscriptions.values.contains(vendorId) else {throw ChatGPTRuntimeError.invalidResume}
            resuming.removeValue(forKey: sessionId); subscriptions[sessionId] = vendorId
            ownedSessions.insert(sessionId); freshStartSessions.insert(sessionId)
            newPersistentSessions.insert(sessionId)
            return .init(id: vendorId, rollout: URL(fileURLWithPath: path))
        } catch {
            if generation == lease, state == .ready {await shutdown(result: .failed)}
            throw error
        }
    }

    func attach(sessionId: String) async throws {
        guard state == .ready else { throw ChatGPTRuntimeError.invalidState }
        guard let thread = subscriptions[sessionId] else { throw ChatGPTRuntimeError.notSubscribed }
        guard entries[sessionId] == nil else { throw ChatGPTRuntimeError.duplicateSession }
        let reservation = UUID(), lease = generation
        let ref = RemoteSessionRef(serverId: serverId, agentId: "agent.chatgpt", runtimeId: runtimeId, sessionId: sessionId)
        entries[sessionId] = .init(ref: ref, thread: thread, reservation: reservation, sourceLease: nil)
        do {
            try await pump.hydrate(ref: ref, vendorThreadId: thread, executionEpoch: executionEpoch,
                                   freshEphemeral: ephemeralSessions.contains(sessionId), freshPersistent: newPersistentSessions.contains(sessionId))
            guard owns(sessionId, reservation: reservation, generation: lease), !Task.isCancelled else { throw ChatGPTRuntimeError.interrupted }
            let pump = self.pump
            let sourceLease = try await service.register(ref: ref, journal: journal, available: {
                switch await pump.status(vendorThreadId: thread) {
                case .active, .requiresSync: return true // durable unavailable snapshot is still readable
                default: return false
                }
            })
            guard owns(sessionId, reservation: reservation, generation: lease), !Task.isCancelled else {
                await service.unregister(sessionId: sessionId, lease: sourceLease)
                throw ChatGPTRuntimeError.interrupted
            }
            entries[sessionId]?.sourceLease = sourceLease
        } catch {
            if entries[sessionId]?.reservation == reservation {
                if let sourceLease = entries[sessionId]?.sourceLease { await service.unregister(sessionId: sessionId, lease: sourceLease) }
                await pump.unbind(vendorThreadId: thread)
                if entries[sessionId]?.reservation == reservation { entries.removeValue(forKey: sessionId) }
            }
            throw error
        }
    }
    private func owns(_ session: String, reservation: UUID, generation lease: Int) -> Bool {
        state == .ready && generation == lease && entries[session]?.reservation == reservation && entries[session]?.invalidating == false
    }

    /// Explicit local owner control for an acknowledged resume. A synthetic or
    /// externally observed registerSubscription cannot grant execution control.
    func enableOwnedInterrupt(sessionId: String, allowSteer: Bool = false, allowRequests: Bool = false) async throws {
        guard state == .ready, ownedSessions.contains(sessionId), let entry = entries[sessionId],
              entry.sourceLease != nil, !entry.invalidating else {throw ChatGPTRuntimeError.notSubscribed}
        let lease = generation
        try await pump.enableOwnedInterrupt(vendorThreadId: entry.thread, allowSteer: allowSteer,
                                            allowFreshStart: freshStartSessions.contains(sessionId), allowRequests: allowRequests)
        guard owns(sessionId, reservation: entry.reservation, generation: lease), ownedSessions.contains(sessionId) else {
            throw ChatGPTRuntimeError.interrupted
        }
    }

    func ownedCommandAdapter() throws -> ChatGPTCommandAdapter {
        guard state == .ready else {throw ChatGPTRuntimeError.invalidState}
        if let commandAdapter {return commandAdapter}
        let adapter = ChatGPTCommandAdapter(channel: channel) { [weak self] ref in
            guard let self else {throw ChatGPTRuntimeError.interrupted}
            return try await self.commandContext(ref: ref)
        }
        commandAdapter = adapter
        return adapter
    }
    /// Explicit local owner publication after the HTTP service is installed.
    /// The adapter/source IDs and epoch come exclusively from this owned runtime.
    func publishOwnedInterrupt(sessionId: String, operations: RemoteOperationService) async throws -> RemoteSessionRef {
        try await publishOwnedControl(sessionId: sessionId, operations: operations, allowSteer: false)
    }

    func publishOwnedControl(sessionId: String, operations: RemoteOperationService, allowSteer: Bool,
                             allowRequests: Bool = false) async throws -> RemoteSessionRef {
        guard operations.serverId == serverId, let entry = entries[sessionId], entry.commands == nil,
              let sourceLease = entry.sourceLease else {throw ChatGPTRuntimeError.notSubscribed}
        let generation = self.generation
        try await enableOwnedInterrupt(sessionId: sessionId, allowSteer: allowSteer, allowRequests: allowRequests)
        let messages = try ownedCommandAdapter()
        let adapter: any RemoteCommandAdapter
        if allowRequests {
            if interactiveAdapter == nil { interactiveAdapter = .init(messages: messages, pump: pump) }
            adapter = interactiveAdapter!
        } else { adapter = messages }
        let context = try await commandContext(ref: entry.ref)
        var actions: Set<RemoteAction> = allowSteer || freshStartSessions.contains(sessionId) ? [.interrupt, .sendMessage] : [.interrupt]
        if allowRequests { actions.formUnion([.approve, .answer]) }
        let lease = try await operations.register(ref: entry.ref, executionEpoch: context.control.executionEpoch,
            actions: actions, adapter: adapter)
        guard owns(sessionId, reservation: entry.reservation, generation: generation), !Task.isCancelled else {
            await stop()
            try await operations.unregister(sessionId: sessionId, lease: lease)
            throw ChatGPTRuntimeError.interrupted
        }
        entries[sessionId]?.commands = (operations, lease)
        do {
            try await service.publishCommands(sessionId: sessionId, lease: sourceLease, service: operations)
            guard owns(sessionId, reservation: entry.reservation, generation: generation), !Task.isCancelled else {
                throw ChatGPTRuntimeError.interrupted
            }
            return entry.ref
        } catch {
            await stop()
            throw error
        }
    }
    private func commandContext(ref: RemoteSessionRef) async throws -> ChatGPTCommandContext {
        guard state == .ready, let entry = entries[ref.sessionId], entry.ref == ref,
              entry.sourceLease != nil, !entry.invalidating, ownedSessions.contains(ref.sessionId) else {
            throw ChatGPTRuntimeError.notSubscribed
        }
        let lease = generation
        let result = try await pump.commandContext(ref: ref)
        guard owns(ref.sessionId, reservation: entry.reservation, generation: lease), ownedSessions.contains(ref.sessionId) else {
            throw ChatGPTRuntimeError.interrupted
        }
        return result
    }

    func detach(sessionId: String) async {
        ownedSessions.remove(sessionId)
        freshStartSessions.remove(sessionId)
        ephemeralSessions.remove(sessionId)
        newPersistentSessions.remove(sessionId)
        if resuming[sessionId] != nil {
            await shutdown(result: .failed)
            return
        }
        // Keep the reservation while async cleanup runs, rejecting a competing attach.
        guard let entry = entries[sessionId] else { subscriptions.removeValue(forKey: sessionId); return }
        if entry.commands != nil {await shutdown(result: .stopped); return}
        entries[sessionId]?.invalidating = true
        if let lease = entry.sourceLease { await service.unregister(sessionId: sessionId, lease: lease) }
        await pump.unbind(vendorThreadId: entry.thread)
        if entries[sessionId]?.reservation == entry.reservation { entries.removeValue(forKey: sessionId) }
        subscriptions.removeValue(forKey: sessionId)
    }

    func stop() async {
        guard state != .stopped, state != .failed else { return }
        await shutdown(result: .stopped)
    }
    private func shutdown(result: State) async {
        if shutdownTask == nil {
            monitor?.cancel(); monitor = nil
            state = .stopping; generation += 1; shutdownResult = result
            let registered = Array(entries.values), service = self.service, pump = self.pump, stopTransport = self.stopTransport
            shutdownTask = Task {
                for entry in registered {
                    if let lease = entry.sourceLease { await service.unregister(sessionId: entry.ref.sessionId, lease: lease) }
                }
                await pump.stop(); await stopTransport()
                for entry in registered {
                    if let commands = entry.commands {
                        try? await commands.service.unregister(sessionId: entry.ref.sessionId, lease: commands.lease)
                    }
                }
            }
        }
        await shutdownTask?.value
        entries.removeAll(); subscriptions.removeAll(); ownedSessions.removeAll(); freshStartSessions.removeAll(); ephemeralSessions.removeAll(); newPersistentSessions.removeAll(); commandAdapter = nil; interactiveAdapter = nil; resuming.removeAll(); state = shutdownResult
    }
    private func disconnected() async {
        guard state == .ready else { return }
        await shutdown(result: .failed)
    }
}
