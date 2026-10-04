import Foundation
import CryptoKit

/// A private process and a single explicitly owned thread. The host-wide index
/// remains a separate read-only runtime; vendor identifiers never leave native code.
struct ChatGPTOwnedReadAdapter: RemoteReadAdapter {
    let base: ChatGPTReadAdapter
    let sessionId: String
    let allowSteer: Bool
    var descriptor: RemoteAgentDescriptor { base.descriptor }
    var runtimeId: String { base.runtimeId }
    var runtimeLabel: String { base.runtimeLabel }
    var runtimeControlMode: String { "live" }
    var runtimeActions: Set<RemoteAction> { allowSteer ? [.listSessions, .readHistory, .interrupt, .sendMessage] : [.listSessions, .readHistory, .interrupt] }
    func sessions(serverId: String) async throws -> RemoteDirectoryResult {
        let result = try await base.sessions(serverId: serverId)
        return .init(items: result.items.filter { $0.sessionId == sessionId }, indexState: result.indexState)
    }
    func history(sessionId: String, limit: Int, snapshotBytes: UInt64?, beforeOffset: UInt64?) async throws -> RolloutHistoryWindow {
        guard sessionId == self.sessionId else { throw RemoteReadError.notFound }
        return try await base.history(sessionId: sessionId, limit: limit, snapshotBytes: snapshotBytes, beforeOffset: beforeOffset)
    }
}

/// A new ephemeral thread has no vendor rollout or directory row. The private
/// journal is its only readable history; a changed snapshot expires old pages.
struct ChatGPTEphemeralReadAdapter: RemoteReadAdapter {
    let base: ChatGPTReadAdapter
    let journal: RemoteSessionJournal
    let ref: RemoteSessionRef
    let title: String
    var descriptor: RemoteAgentDescriptor { base.descriptor }
    var runtimeId: String { ref.runtimeId }
    var runtimeLabel: String { title }
    var runtimeControlMode: String { "live" }
    var runtimeActions: Set<RemoteAction> { [.listSessions, .readHistory, .interrupt, .sendMessage] }
    func sessions(serverId: String) async throws -> RemoteDirectoryResult {
        guard serverId == ref.serverId else { throw RemoteReadError.invalidRequest }
        let snapshot = try await journal.snapshot(ref: ref)
        return .init(items: [.init(serverId: serverId, agentId: ref.agentId, runtimeId: ref.runtimeId,
            sessionId: ref.sessionId, title: title, updatedAt: Date(), archived: false,
            controlMode: snapshot.projection.control.controlMode,
            allowedActions: snapshot.projection.control.allowedActions)], indexState: "ready")
    }
    func history(sessionId: String, limit: Int, snapshotBytes: UInt64?, beforeOffset: UInt64?) async throws -> RolloutHistoryWindow {
        guard sessionId == ref.sessionId, (1...100).contains(limit) else { throw RemoteReadError.invalidRequest }
        let snapshot = try await journal.snapshot(ref: ref)
        let messages = snapshot.projection.messages
        let size = UInt64(messages.count)
        guard snapshotBytes == nil || snapshotBytes == size else { throw RolloutHistoryError.snapshotChanged }
        let boundary = beforeOffset ?? size
        guard boundary <= size else { throw RolloutHistoryError.invalidWindow }
        let digest = SHA256.hash(data: try JSONEncoder().encode(messages)).map { String(format: "%02x", $0) }.joined()
        let start = Int(boundary) - min(limit, Int(boundary))
        return .init(messages: Array(messages[start..<Int(boundary)]), snapshotBytes: size,
            olderBeforeOffset: start > 0 ? UInt64(start) : nil,
            unsupportedContentCount: 0, snapshotDigest: digest)
    }
}

actor RemoteOwnedChatGPTService {
    typealias Launcher = @Sendable (ChatGPTLocalRuntimeConfiguration, RemoteSessionService) async throws -> ChatGPTRuntimeCoordinator
    struct Choice: Sendable, Identifiable {
        let sourceRuntimeId: String, sessionId: String, title: String
        var id: String { sourceRuntimeId + ":" + sessionId }
    }
    struct Account: Sendable, Identifiable {
        let id: String, label: String
    }
    struct Owned: Sendable, Identifiable {
        let id: String, sessionId: String, title: String
    }
    private struct Entry: Sendable { let summary: Owned; let runtime: ChatGPTRuntimeCoordinator; let selectionKey: String; let workspaceId: String? }
    private let sources: [ChatGPTReadAdapter]
    private let directory: URL
    private let reads: RemoteReadService
    private let sessions: RemoteSessionService
    private let operations: RemoteOperationService
    private let launch: Launcher
    private var entries: [String: Entry] = [:]
    private var pending = Set<String>()
    private var selectedThreads = Set<String>()
    private var launches: [String: Task<ChatGPTRuntimeCoordinator, Error>] = [:]
    private var stopped = false
    init(sources: [ChatGPTReadAdapter], directory: URL, reads: RemoteReadService, sessions: RemoteSessionService,
         operations: RemoteOperationService, launch: @escaping Launcher = { try await ChatGPTLocalRuntime.launch(configuration: $0, service: $1) }) {
        self.sources = sources; self.directory = directory; self.reads = reads; self.sessions = sessions
        self.operations = operations; self.launch = launch
    }
    deinit {
        for task in launches.values { task.cancel() }
        for entry in entries.values { Task { await entry.runtime.stop() } }
    }
    func choices() throws -> [Choice] {
        guard !stopped else { throw RemoteAccessError.unavailable }
        return try sources.flatMap { source in
            try source.directory.snapshot().entries.filter { !$0.archived }.map {
                Choice(sourceRuntimeId: source.runtimeId, sessionId: $0.sessionId, title: $0.title)
            }
        }
    }
    func accounts() throws -> [Account] {
        guard !stopped else { throw RemoteAccessError.unavailable }
        return sources.map { Account(id: $0.runtimeId, label: $0.runtimeLabel) }
    }
    func owned() async -> [Owned] {
        for (id, entry) in entries {
            if await entry.runtime.currentState() != .ready { await detach(id: id) }
        }
        return entries.values.map(\.summary).sorted { $0.id < $1.id }
    }
    /// Explicit native owner action. Neither paths nor vendor IDs are accepted
    /// from a network caller; selected session is resolved again locally.
    func attach(sourceRuntimeId: String, sessionId: String, executable: URL, allowSteer: Bool) async throws -> Owned {
        guard !stopped, entries.count + pending.count < 16,
              let source = sources.first(where: { $0.runtimeId == sourceRuntimeId }),
              let selected = try source.directory.snapshot().entries.first(where: { $0.sessionId == sessionId && !$0.archived }) else {
            throw RemoteAccessError.invalidConfiguration
        }
        let id = "rt_owned_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let home = source.directory.storageRoot
        let selectionKey = home.resolvingSymlinksInPath().standardizedFileURL.path + "\u{0}" + selected.vendorSessionId
        guard !selectedThreads.contains(selectionKey), !entries.values.contains(where: { $0.selectionKey == selectionKey }) else { throw ChatGPTRuntimeError.duplicateSession }
        pending.insert(id); selectedThreads.insert(selectionKey)
        defer { pending.remove(id); selectedThreads.remove(selectionKey); launches.removeValue(forKey: id) }
        let digest = SHA256.hash(data: Data("\(id)\u{0}\(selected.vendorSessionId)".utf8)).map { String(format: "%02x", $0) }.joined()
        let ownedId = "ss_" + String(digest.prefix(32))
        let summary = Owned(id: id, sessionId: ownedId, title: selected.title)
        let config = ChatGPTLocalRuntimeConfiguration(executable: executable, home: home,
            journalURL: directory.appendingPathComponent(id + ".sqlite"), runtimeId: id)
        let launch = launch, sessions = sessions
        let task = Task { try await launch(config, sessions) }; launches[id] = task
        let runtime = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        var registered = false
        do {
            try active(id)
            try await runtime.resumeOwnedSession(sessionId: ownedId, vendorThreadId: selected.vendorSessionId)
            try active(id)
            try await runtime.attach(sessionId: ownedId)
            try active(id)
            _ = try await runtime.publishOwnedControl(sessionId: ownedId, operations: operations, allowSteer: allowSteer)
            try active(id)
            let adapter = ChatGPTOwnedReadAdapter(base: .init(directory: .init(databaseURL: source.directory.databaseURL,
                storageRoot: home, runtimeId: id), runtimeLabel: source.runtimeLabel + " · 受控会话"), sessionId: ownedId, allowSteer: allowSteer)
            try await reads.register(adapter); registered = true
            try active(id)
            entries[id] = .init(summary: summary, runtime: runtime, selectionKey: selectionKey, workspaceId: nil)
            return summary
        } catch {
            if registered { await reads.unregister(agentId: "agent.chatgpt", runtimeId: id) }
            await runtime.stop(); throw error
        }
    }
    /// The desktop owner chooses both an already registered account and a
    /// local workspace. Neither value is supplied by the remote HTTP API.
    func create(sourceRuntimeId: String, workspace: URL, executable: URL) async throws -> Owned {
        guard !stopped, entries.count + pending.count < 16,
              let source = sources.first(where: { $0.runtimeId == sourceRuntimeId }) else {
            throw RemoteAccessError.invalidConfiguration
        }
        let cwd = workspace.resolvingSymlinksInPath().standardizedFileURL
        guard cwd.isFileURL, cwd.path != "/", (try? cwd.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw RemoteAccessError.invalidConfiguration
        }
        let id = "rt_owned_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let sessionId = "ss_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let workspaceId = "ws_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let summary = Owned(id: id, sessionId: sessionId, title: "新会话 · " + cwd.lastPathComponent)
        pending.insert(id)
        defer { pending.remove(id); launches.removeValue(forKey: id) }
        let config = ChatGPTLocalRuntimeConfiguration(executable: executable, home: source.directory.storageRoot,
            journalURL: directory.appendingPathComponent(id + ".sqlite"), runtimeId: id)
        let launch = launch, sessions = sessions
        let task = Task { try await launch(config, sessions) }; launches[id] = task
        let runtime = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        var registered = false, workspaceRegistered = false
        do {
            try active(id)
            try await runtime.createOwnedEphemeralSession(sessionId: sessionId, workspace: cwd)
            try active(id)
            try await runtime.attach(sessionId: sessionId)
            try active(id)
            let ref = try await runtime.publishOwnedControl(sessionId: sessionId, operations: operations, allowSteer: false)
            try active(id)
            let scope = try await reads.authorizationRegistry.registerWorkspace(id: workspaceId, root: cwd)
            workspaceRegistered = true
            let journal = try RemoteSessionJournal(databaseURL: config.journalURL)
            try await reads.register(ChatGPTEphemeralReadAdapter(base: source, journal: journal, ref: ref, title: summary.title), workspace: scope)
            registered = true
            try active(id)
            entries[id] = .init(summary: summary, runtime: runtime, selectionKey: id, workspaceId: workspaceId)
            return summary
        } catch {
            if registered { await reads.unregister(agentId: "agent.chatgpt", runtimeId: id) }
            if workspaceRegistered { await reads.authorizationRegistry.unregisterWorkspace(id: workspaceId) }
            await runtime.stop(); throw error
        }
    }
    private func active(_ id: String) throws {
        try Task.checkCancellation()
        guard !stopped, pending.contains(id) else { throw RemoteAccessError.unavailable }
    }
    func detach(id: String) async {
        guard let entry = entries.removeValue(forKey: id) else { return }
        await reads.unregister(agentId: "agent.chatgpt", runtimeId: id)
        if let workspaceId = entry.workspaceId { await reads.authorizationRegistry.unregisterWorkspace(id: workspaceId) }
        await entry.runtime.stop()
    }
    func stop() async {
        stopped = true; pending.removeAll(); selectedThreads.removeAll()
        for task in launches.values { task.cancel() }; launches.removeAll()
        for id in Array(entries.keys) { await detach(id: id) }
    }
}
