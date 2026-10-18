import Foundation
import CryptoKit

enum PhoneConversationError: Error {case invalidManifest, accountUnavailable, workspaceChanged, rolloutOutsideAccount, historyMissing}

/// Pairing-code rotation selects a new authorization ledger, while the owner's
/// durable conversation keeps its original directory (and vendor working path).
/// Store only a validated relative namespace; never accept an absolute path here.
enum PhoneConversationLocation {
    static func directory(root: URL, serverId: String, namespace: String) throws -> URL {
        func valid(_ value: String) -> Bool {value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil}
        guard root.isFileURL, UUID(uuidString: serverId)?.uuidString.lowercased() == serverId, valid(namespace) else {
            throw PhoneConversationError.invalidManifest
        }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        guard base.path != "/" else {throw PhoneConversationError.invalidManifest}
        let holder = base.appendingPathComponent("phone").appendingPathComponent(serverId)
        guard holder.resolvingSymlinksInPath().standardizedFileURL == holder else {throw PhoneConversationError.invalidManifest}
        let files = FileManager.default, record = holder.appendingPathComponent("conversation-namespace")
        let attributes: [FileAttributeKey: Any]?
        do {attributes = try files.attributesOfItem(atPath: record.path)}
        catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {attributes = nil}
        let selected: String
        if let attributes {
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.intValue == 64 else {throw PhoneConversationError.invalidManifest}
            let data = try Data(contentsOf: record)
            guard data.count == 64, let saved = String(data: data, encoding: .utf8), valid(saved) else {throw PhoneConversationError.invalidManifest}
            selected = saved
        } else {
            try files.createDirectory(at: holder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(namespace.utf8).write(to: record, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.path)
            selected = namespace
        }
        let result = base.appendingPathComponent("phone").appendingPathComponent(selected)
            .appendingPathComponent(serverId).appendingPathComponent("owned-journals")
        guard result.resolvingSymlinksInPath().standardizedFileURL == result else {throw PhoneConversationError.invalidManifest}
        return result
    }
}

/// A private process and a single explicitly owned thread. The host-wide index
/// remains a separate read-only runtime; vendor identifiers never leave native code.
struct ChatGPTOwnedReadAdapter: RemoteReadAdapter {
    let base: ChatGPTReadAdapter
    let sessionId: String
    let allowSteer: Bool
    var allowRequests: Bool = false
    var descriptor: RemoteAgentDescriptor { base.descriptor }
    var runtimeId: String { base.runtimeId }
    var runtimeLabel: String { base.runtimeLabel }
    var runtimeControlMode: String { "live" }
    var runtimeActions: Set<RemoteAction> {
        var actions: Set<RemoteAction> = [.listSessions, .readHistory, .interrupt]
        if allowSteer { actions.insert(.sendMessage) }
        if allowRequests { actions.formUnion([.approve, .answer]) }
        return actions
    }
    func sessions(serverId: String) async throws -> RemoteDirectoryResult {
        let result = try await base.sessions(serverId: serverId)
        return .init(items: result.items.filter { $0.sessionId == sessionId }, indexState: result.indexState)
    }
    func history(sessionId: String, limit: Int, snapshotBytes: UInt64?, beforeOffset: UInt64?) async throws -> RolloutHistoryWindow {
        guard sessionId == self.sessionId else { throw RemoteReadError.notFound }
        return try await base.history(sessionId: sessionId, limit: limit, snapshotBytes: snapshotBytes, beforeOffset: beforeOffset)
    }
    func containsSession(sessionId: String) async -> Bool {
        sessionId == self.sessionId
    }
}

/// Owned conversations read from their live private journal, including newly
/// created threads which do not yet have an indexed directory row.
struct ChatGPTJournalReadAdapter: RemoteReadAdapter {
    let base: ChatGPTReadAdapter
    let journal: RemoteSessionJournal
    let ref: RemoteSessionRef
    let title: String
    var allowRequests: Bool = false
    let allowsCommands: Bool
    let historyReader: RemoteJournalHistoryReader
    init(base: ChatGPTReadAdapter, journal: RemoteSessionJournal, ref: RemoteSessionRef, title: String, allowRequests: Bool = false,
         allowsCommands: Bool = true) {
        self.base = base; self.journal = journal; self.ref = ref; self.title = title; self.allowRequests = allowRequests
        self.allowsCommands = allowsCommands
        historyReader = .init(journal: journal, ref: ref)
    }
    var descriptor: RemoteAgentDescriptor { base.descriptor }
    var runtimeId: String { ref.runtimeId }
    var runtimeLabel: String { title }
    var runtimeControlMode: String { allowsCommands ? "live" : "readOnly" }
    var runtimeActions: Set<RemoteAction> {
        if !allowsCommands { return [.listSessions, .readHistory] }
        var actions: Set<RemoteAction> = [.listSessions, .readHistory, .interrupt, .sendMessage]
        if allowRequests { actions.formUnion([.approve, .answer]) }
        return actions
    }
    func sessions(serverId: String) async throws -> RemoteDirectoryResult {
        guard serverId == ref.serverId else { throw RemoteReadError.invalidRequest }
        let snapshot = try await journal.snapshot(ref: ref)
        return .init(items: [.init(serverId: serverId, agentId: ref.agentId, runtimeId: ref.runtimeId,
            sessionId: ref.sessionId, title: title, updatedAt: Date(), archived: false,
            controlMode: snapshot.projection.control.controlMode,
            allowedActions: snapshot.projection.control.allowedActions)], indexState: "ready")
    }
    func containsSession(sessionId: String) async -> Bool {
        sessionId == ref.sessionId
    }
    func history(sessionId: String, limit: Int, snapshotBytes: UInt64?, beforeOffset: UInt64?) async throws -> RolloutHistoryWindow {
        guard sessionId == ref.sessionId, (1...100).contains(limit) else { throw RemoteReadError.invalidRequest }
        return try await historyReader.window(limit: limit, snapshotBytes: snapshotBytes, beforeOffset: beforeOffset)
    }
}

actor RemoteOwnedChatGPTService {
    typealias Launcher = @Sendable (ChatGPTLocalRuntimeConfiguration, RemoteSessionService) async throws -> ChatGPTRuntimeCoordinator
    typealias PhoneDirectory = @Sendable () throws -> URL
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
    private let phoneDirectory: PhoneDirectory?
    private var entries: [String: Entry] = [:]
    private var pending = Set<String>()
    private var selectedThreads = Set<String>()
    private var launches: [String: Task<ChatGPTRuntimeCoordinator, Error>] = [:]
    private var stopped = false
    private var preparingPhone = false
    private var phoneDetachedByOwner = false
    private var phoneWorkspaceID: String?
    private struct PhoneConversationRecord: Codable {
        let version: Int
        let sourceRuntimeId: String
        let runtimeId: String
        let sessionId: String
        let workspaceId: String
        let vendorThreadId: String
        let rolloutPath: String
        static func resolvedPath(_ url: URL) -> URL {
            // resolvingSymlinksInPath can leave /var aliases unresolved when
            // the rollout does not exist yet. Resolve its existing ancestor.
            var ancestor = url.standardizedFileURL, suffix: [String] = []
            while ancestor.path != "/", !FileManager.default.fileExists(atPath: ancestor.path) {
                suffix.insert(ancestor.lastPathComponent, at: 0); ancestor.deleteLastPathComponent()
            }
            return suffix.reduce(ancestor.resolvingSymlinksInPath().standardizedFileURL) {$0.appendingPathComponent($1)}
        }
        func validate() throws {
            guard version == 1, !sourceRuntimeId.isEmpty, sourceRuntimeId.utf8.count <= 160,
                  runtimeId.range(of: "^rt_phone_[a-f0-9]{32}$", options: .regularExpression) != nil,
                  sessionId.range(of: "^ss_[a-f0-9]{32}$", options: .regularExpression) != nil,
                  workspaceId.range(of: "^ws_[a-f0-9]{32}$", options: .regularExpression) != nil,
                  !vendorThreadId.isEmpty, vendorThreadId.utf8.count <= 256, !vendorThreadId.contains("\0"),
                  rolloutPath.hasPrefix("/"), rolloutPath.utf8.count <= 4096, !rolloutPath.contains("\0") else {
                throw PhoneConversationError.invalidManifest
            }
        }
    }
    init(sources: [ChatGPTReadAdapter], directory: URL, reads: RemoteReadService, sessions: RemoteSessionService,
         operations: RemoteOperationService, phoneDirectory: PhoneDirectory? = nil,
         launch: @escaping Launcher = { try await ChatGPTLocalRuntime.launch(configuration: $0, service: $1) }) {
        self.sources = sources; self.directory = directory; self.reads = reads; self.sessions = sessions
        self.operations = operations; self.launch = launch
        self.phoneDirectory = phoneDirectory
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
            if await entry.runtime.currentState() != .ready {
                await discard(id: id, matching: entry.runtime, preservingWorkspace: id.hasPrefix("rt_phone_"))
            }
        }
        return entries.values.map(\.summary).sorted { $0.id < $1.id }
    }

    /// The phone switch is the local owner's explicit creation/resume action.
    /// Keep one durable default conversation, with a private local manifest;
    /// never resume an arbitrary history item or accept an executable/path over HTTP.
    func preparePhoneConversation(executable: URL) async throws -> Owned? {
        guard !stopped else {throw RemoteAccessError.unavailable}
        guard !phoneDetachedByOwner else {return nil}
        guard !preparingPhone else {throw RemoteAccessError.unavailable}
        preparingPhone = true
        defer {preparingPhone = false}
        guard !sources.isEmpty else {throw PhoneConversationError.accountUnavailable}
        // Resolve only for default preparation. Invalid local recovery metadata
        // must not prevent the host's independent read-only history from starting.
        let directory = try phoneDirectory?() ?? self.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = directory.appendingPathComponent("phone-conversation.json")
        let saved: PhoneConversationRecord?
        if FileManager.default.fileExists(atPath: manifest.path) {
            let data = try Data(contentsOf: manifest)
            guard data.count <= 8192 else {throw PhoneConversationError.invalidManifest}
            saved = try JSONDecoder().decode(PhoneConversationRecord.self, from: data)
            try saved?.validate()
        } else {saved = nil}
        guard let source = sources.first(where: {saved == nil || $0.runtimeId == saved?.sourceRuntimeId}) else {
            throw PhoneConversationError.accountUnavailable
        }
        func suffix() -> String {UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()}
        let id = saved?.runtimeId ?? "rt_phone_" + suffix(), sessionId = saved?.sessionId ?? "ss_" + suffix()
        let workspaceId = saved?.workspaceId ?? "ws_" + suffix()
        if let existing = entries[id] {
            let state = await existing.runtime.currentState()
            try Task.checkCancellation()
            guard !stopped, !phoneDetachedByOwner else {throw RemoteAccessError.unavailable}
            if state == .ready {
                guard entries[id]?.runtime === existing.runtime else {throw RemoteAccessError.unavailable}
                return existing.summary
            }
            await discard(id: id, matching: existing.runtime, preservingWorkspace: true)
        }
        guard entries.count + pending.count < 16, !pending.contains(id) else {throw RemoteAccessError.unavailable}
        let workspace = directory.appendingPathComponent("手机会话", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let cwd = workspace.resolvingSymlinksInPath().standardizedFileURL
        guard cwd == workspace.standardizedFileURL else {throw PhoneConversationError.workspaceChanged}
        pending.insert(id)
        defer {pending.remove(id); launches.removeValue(forKey: id)}
        let config = ChatGPTLocalRuntimeConfiguration(executable: executable, home: source.directory.storageRoot,
            journalURL: directory.appendingPathComponent(id + ".sqlite"), runtimeId: id)
        let journal = try RemoteSessionJournal(databaseURL: config.journalURL)
        let sessionsRoot = source.directory.storageRoot.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent("sessions").path + "/"
        if let saved {
            let rollout = PhoneConversationRecord.resolvedPath(URL(fileURLWithPath: saved.rolloutPath))
            guard rollout.path.hasPrefix(sessionsRoot) else {throw PhoneConversationError.rolloutOutsideAccount}
        }
        let materialized = saved.map {FileManager.default.fileExists(atPath: $0.rolloutPath)} ?? false
        if saved != nil && !materialized {
            let ref = RemoteSessionRef(serverId: await sessions.serverId, agentId: "agent.chatgpt", runtimeId: id, sessionId: sessionId)
            if let prior = try? await journal.snapshot(ref: ref) {
                guard prior.projection.messages.isEmpty, prior.projection.pendingRequests.isEmpty,
                      prior.projection.control.currentTurnId == nil else {throw PhoneConversationError.historyMissing}
            }
        }
        let launch = launch, sessions = sessions
        let task = Task {try await launch(config, sessions)}; launches[id] = task
        let runtime = try await withTaskCancellationHandler {try await task.value} onCancel: {task.cancel()}
        var registered = false, workspaceRegistered = false
        do {
            try active(id)
            try await runtime.requirePhoneAuthentication()
            try active(id)
            let vendorId: String
            if let saved, materialized {
                vendorId = saved.vendorThreadId
                try await runtime.resumeOwnedSession(sessionId: sessionId, vendorThreadId: vendorId, allowNewTurns: true)
            } else {
                let created = try await runtime.createOwnedPersistentSession(sessionId: sessionId, workspace: cwd)
                vendorId = created.id
                try active(id)
                guard PhoneConversationRecord.resolvedPath(created.rollout).path.hasPrefix(sessionsRoot) else {throw PhoneConversationError.rolloutOutsideAccount}
                let record = PhoneConversationRecord(version: 1, sourceRuntimeId: source.runtimeId,
                    runtimeId: id, sessionId: sessionId, workspaceId: workspaceId, vendorThreadId: vendorId, rolloutPath: created.rollout.path)
                try record.validate()
                try JSONEncoder().encode(record).write(to: manifest, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
            }
            try active(id); try await runtime.attach(sessionId: sessionId); try active(id)
            let ref = try await runtime.publishOwnedControl(sessionId: sessionId, operations: operations, allowSteer: true, allowRequests: true)
            try active(id)
            let scope = try await reads.authorizationRegistry.registerWorkspace(id: workspaceId, root: cwd)
            workspaceRegistered = true; phoneWorkspaceID = workspaceId
            try active(id)
            let summary = Owned(id: id, sessionId: sessionId, title: "手机会话")
            try await reads.register(ChatGPTJournalReadAdapter(base: source, journal: journal, ref: ref, title: summary.title,
                allowRequests: true), workspace: scope)
            registered = true; try active(id)
            entries[id] = .init(summary: summary, runtime: runtime,
                selectionKey: source.directory.storageRoot.standardizedFileURL.path + "\u{0}" + vendorId, workspaceId: workspaceId)
            return summary
        } catch {
            if registered {await reads.unregister(agentId: "agent.chatgpt", runtimeId: id)}
            if workspaceRegistered, stopped || phoneDetachedByOwner {
                await reads.authorizationRegistry.unregisterWorkspace(id: workspaceId)
            }
            await runtime.stop(); throw error
        }
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
            // This publishes supported request capabilities, not a device grant.
            // The owner must separately authorize session.approve for this runtime.
            _ = try await runtime.publishOwnedControl(sessionId: ownedId, operations: operations, allowSteer: allowSteer, allowRequests: true)
            try active(id)
            let adapter = ChatGPTOwnedReadAdapter(base: .init(directory: .init(databaseURL: source.directory.databaseURL,
                storageRoot: home, runtimeId: id), runtimeLabel: source.runtimeLabel + " · 受控会话"), sessionId: ownedId,
                allowSteer: allowSteer, allowRequests: true)
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
            let ref = try await runtime.publishOwnedControl(sessionId: sessionId, operations: operations, allowSteer: false, allowRequests: true)
            try active(id)
            let scope = try await reads.authorizationRegistry.registerWorkspace(id: workspaceId, root: cwd)
            workspaceRegistered = true
            let journal = try RemoteSessionJournal(databaseURL: config.journalURL)
            try await reads.register(ChatGPTJournalReadAdapter(base: source, journal: journal, ref: ref, title: summary.title,
                allowRequests: true), workspace: scope)
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
        guard !stopped, pending.contains(id), !id.hasPrefix("rt_phone_") || !phoneDetachedByOwner else { throw RemoteAccessError.unavailable }
    }
    func detach(id: String) async {
        // An explicit owner detach is not a transport failure. Automatic phone
        // maintenance stays suppressed until the switch starts a new service.
        if id.hasPrefix("rt_phone_"), entries[id] != nil || pending.contains(id) {
            phoneDetachedByOwner = true
            launches[id]?.cancel()
            if let phoneWorkspaceID {await reads.authorizationRegistry.unregisterWorkspace(id: phoneWorkspaceID)}
        }
        await discard(id: id)
    }
    private func discard(id: String, matching runtime: ChatGPTRuntimeCoordinator? = nil, preservingWorkspace: Bool = false) async {
        guard let entry = entries[id], runtime == nil || entry.runtime === runtime else { return }
        entries.removeValue(forKey: id)
        // Prevent another prepare from publishing this identity while its old
        // read/workspace registrations are still being removed asynchronously.
        let reserved = pending.insert(id).inserted
        defer {if reserved {pending.remove(id)}}
        await reads.unregister(agentId: "agent.chatgpt", runtimeId: id)
        if let workspaceId = entry.workspaceId, !preservingWorkspace {
            await reads.authorizationRegistry.unregisterWorkspace(id: workspaceId)
        }
        await entry.runtime.stop()
    }
    func stop() async {
        stopped = true; pending.removeAll(); selectedThreads.removeAll()
        for task in launches.values { task.cancel() }; launches.removeAll()
        for id in Array(entries.keys) { await discard(id: id) }
    }
}
