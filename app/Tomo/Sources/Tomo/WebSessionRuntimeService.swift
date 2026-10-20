import Foundation

/// A desktop-approved web window may explicitly resume a locally indexed thread.
/// Listing/history GETs never launch a process or change ownership. Public IDs
/// stay unchanged so the same detail page can move from history to live events.
actor WebSessionRuntimeService {
    private weak var server: MobileSyncServer?
    private let directory: URL
    private let executable: @Sendable () throws -> URL
    private let launch: RemoteOwnedChatGPTService.Launcher
    private var sources: [ChatGPTReadAdapter] = []
    private var operations: RemoteOperationService?
    private var runtimes: [String: ChatGPTRuntimeCoordinator] = [:]
    private var pending: [String: Task<ChatGPTRuntimeCoordinator, Error>] = [:]
    private var generation = 0
    private var stopping = false

    init(server: MobileSyncServer, directory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tomo-web-" + UUID().uuidString),
         executable: @escaping @Sendable () throws -> URL = { try PhoneConversationExecutable.locate() },
         launch: @escaping RemoteOwnedChatGPTService.Launcher = { try await ChatGPTLocalRuntime.launch(configuration: $0, service: $1) }) {
        self.server = server; self.directory = directory; self.executable = executable; self.launch = launch
    }

    func prepare(sources: [ChatGPTReadAdapter]) throws {
        guard !stopping, operations == nil, let server, !sources.isEmpty else { throw RemoteAccessError.unavailable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let store = try RemoteOperationStore(databaseURL: directory.appendingPathComponent("operations.sqlite"))
        let operations = RemoteOperationService(serverId: server.remoteSessionService.serverId,
            access: server.remoteAccess, store: store) { [weak server] principal in
                guard let server else { throw RemoteAccessError.unavailable }
                return try await server.webOperationOwner(principal)
            }
        try server.installRemoteOperationService(operations)
        server.installWebSessionRuntime(self)
        self.sources = sources; self.operations = operations
    }

    func resume(sessionId: String, query: [String: String], principal: RemoteAccessStore.Principal) async throws {
        guard let server, let operations, Set(query.keys) == ["agent_id", "runtime_id"],
              query["agent_id"] == "agent.chatgpt", let runtimeId = query["runtime_id"] else {
            throw RemoteReadError.invalidRequest
        }
        _ = try await server.webOperationOwner(principal)
        guard principal.permits(agentId: "agent.chatgpt", runtimeId: runtimeId, sessionId: sessionId, action: .resume),
              principal.permits(agentId: "agent.chatgpt", runtimeId: runtimeId, sessionId: sessionId, action: .sendMessage) else {
            throw RemoteAccessError.forbidden
        }
        guard let source = sources.first(where: { $0.runtimeId == runtimeId }),
              let selected = try source.directory.snapshot().entries.first(where: { $0.sessionId == sessionId && !$0.archived }) else {
            throw RemoteReadError.notFound
        }
        let lease = generation
        if let running = runtimes[sessionId] {
            if await running.currentState() == .ready {
                guard generation == lease else { throw RemoteReadError.unavailable }
                return
            }
            runtimes.removeValue(forKey: sessionId)
            await running.stop()
            guard generation == lease else { throw RemoteReadError.unavailable }
        }
        if let task = pending[sessionId] {
            _ = try await task.value
            _ = try await server.webOperationOwner(principal)
            guard generation == lease else { throw RemoteReadError.unavailable }
            return
        }
        guard runtimes.count + pending.count < 16 else { throw RemoteOperationError.limitExceeded }
        let config = ChatGPTLocalRuntimeConfiguration(executable: try executable(), home: source.directory.storageRoot,
            journalURL: directory.appendingPathComponent(UUID().uuidString + ".sqlite"), runtimeId: runtimeId)
        let launch = launch
        let task = Task {
            let runtime = try await launch(config, server.remoteSessionService)
            do {
                try Task.checkCancellation()
                _ = try await server.webOperationOwner(principal)
                try await runtime.resumeOwnedSession(sessionId: sessionId, vendorThreadId: selected.vendorSessionId, allowNewTurns: true)
                try await runtime.attach(sessionId: sessionId)
                try Task.checkCancellation()
                _ = try await server.webOperationOwner(principal)
                _ = try await runtime.publishOwnedControl(sessionId: sessionId, operations: operations, allowSteer: true)
                return runtime
            } catch { await runtime.stop(); throw error }
        }
        pending[sessionId] = task
        defer { if generation == lease { pending.removeValue(forKey: sessionId) } }
        let runtime = try await task.value
        guard generation == lease, self.operations === operations else {
            await runtime.stop(); throw RemoteReadError.unavailable
        }
        runtimes[sessionId] = runtime
        _ = try await server.webOperationOwner(principal)
    }

    func stop() async {
        guard !stopping else { return }
        stopping = true
        defer { stopping = false }
        generation += 1
        let jobs = Array(pending.values), active = Array(runtimes.values), commands = operations
        pending = [:]; runtimes = [:]; operations = nil; sources = []
        server?.removeWebSessionRuntime(self)
        if let commands { server?.removeRemoteOperationService(commands) }
        jobs.forEach { $0.cancel() }
        for job in jobs { if let runtime = try? await job.value { await runtime.stop() } }
        for runtime in active { await runtime.stop() }
        await commands?.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }
}
