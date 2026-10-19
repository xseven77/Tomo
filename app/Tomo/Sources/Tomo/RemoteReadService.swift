import Foundation

struct RemoteSessionSummary: Codable, Equatable, Sendable {
    let serverId: String
    let agentId: String
    let runtimeId: String
    let sessionId: String
    let title: String
    let updatedAt: Date
    let archived: Bool
    let controlMode: String
    let allowedActions: [String]
    var executionState: String = "unknown"
}
struct RemoteDirectoryResult: Sendable {
    let items: [RemoteSessionSummary]
    let indexState: String
}
struct RemoteSessionMetadata: Codable, Sendable {
    let serverId: String
    let agentId: String
    let runtimeId: String
    let sessionId: String
    let title: String
    let updatedAt: Date
    let archived: Bool
    var workspaceName: String? = nil
    var model: String? = nil
    var gitBranch: String? = nil
}
/// New vendors implement this boundary; no brand switch in the service/router.
protocol RemoteReadAdapter: Sendable {
    var descriptor: RemoteAgentDescriptor { get }
    var runtimeId: String { get }
    var runtimeLabel: String { get }
    var runtimeActions: Set<RemoteAction> { get }
    var runtimeControlMode: String { get }
    func sessions(serverId: String) async throws -> RemoteDirectoryResult
    func history(sessionId: String, limit: Int, snapshotBytes: UInt64?, beforeOffset: UInt64?) async throws -> RolloutHistoryWindow
    func containsSession(sessionId: String) async -> Bool
    func metadata(serverId: String, sessionId: String) async throws -> RemoteSessionMetadata
}
extension RemoteReadAdapter {
    func metadata(serverId: String, sessionId: String) async throws -> RemoteSessionMetadata {
        guard let item = try await sessions(serverId: serverId).items.first(where: { $0.sessionId == sessionId }) else { throw RemoteReadError.notFound }
        return .init(serverId: serverId, agentId: descriptor.agentId, runtimeId: runtimeId,
            sessionId: item.sessionId, title: item.title, updatedAt: item.updatedAt, archived: item.archived)
    }
    var runtimeActions: Set<RemoteAction> { Set(descriptor.possibleActions.compactMap(RemoteAction.init(rawValue:))) }
    var runtimeControlMode: String { "live" }
    func containsSession(sessionId: String) async -> Bool {
        if let result = try? await sessions(serverId: "") {
            return result.items.contains(where: { $0.sessionId == sessionId })
        }
        return false
    }
}

struct ChatGPTReadAdapter: RemoteReadAdapter {
    let directory: ChatGPTSessionDirectory
    let runtimeLabel: String
    var runtimeId: String { directory.runtimeId }
    var runtimeActions: Set<RemoteAction> { [.listSessions, .readHistory] }
    var runtimeControlMode: String { "readOnly" }
    var descriptor: RemoteAgentDescriptor {
        .init(agentId: "agent.chatgpt", displayName: "ChatGPT", adapterId: "tomo.adapter.chatgpt-rollout",
              adapterVersion: "1.0.0", descriptorSchemaVersion: 1, supportedApiMajors: [1],
              supportedEventMajors: [1], supportedContentMajors: [1],
              surfaces: [.init(id: "surface.chatgpt-cli", kind: "cli", label: "CLI")],
              brand: .init(iconAssetId: nil, fallbackGlyph: "chat"),
              // One agent descriptor is shared by its history and explicitly
              // owned runtimes. This ceiling is not a runtime grant: the history
              // adapter above always registers only list/read actions.
              possibleActions: ["sessions.list", "history.read", "message.send", "turn.interrupt", "approval.respond", "question.answer"],
              inputTypes: ["text"], outputTypes: ["text", "approval", "question", "error"],
              requiredClientFeatures: [], discoveryMode: "registered-paths", minRemoteApiVersion: 1)
    }
    func sessions(serverId: String) async throws -> RemoteDirectoryResult {
        let snapshot = try directory.snapshot()
        return .init(items: snapshot.entries.map {
            .init(serverId: serverId, agentId: descriptor.agentId, runtimeId: runtimeId, sessionId: $0.sessionId,
                  title: $0.title, updatedAt: $0.updatedAt, archived: $0.archived, controlMode: "readOnly",
                  allowedActions: ["history.read"])
        }, indexState: snapshot.indexState)
    }
    func containsSession(sessionId: String) async -> Bool {
        guard let snapshot = try? directory.snapshot() else { return false }
        return snapshot.entries.contains(where: { $0.sessionId == sessionId })
    }
    func metadata(serverId: String, sessionId: String) async throws -> RemoteSessionMetadata {
        guard let entry = try directory.snapshot().entries.first(where: { $0.sessionId == sessionId }) else { throw RemoteReadError.notFound }
        return .init(serverId: serverId, agentId: descriptor.agentId, runtimeId: runtimeId, sessionId: entry.sessionId,
            title: entry.title, updatedAt: entry.updatedAt, archived: entry.archived,
            workspaceName: entry.workspaceName, model: entry.model, gitBranch: entry.gitBranch)
    }
    func vendorSessionId(for sessionId: String) -> String? {
        guard let snapshot = try? directory.snapshot() else { return nil }
        return snapshot.entries.first(where: { $0.sessionId == sessionId })?.vendorSessionId
    }
    /// An image the session's own history refers to, read-only. The path must appear in this session's rollout as a whole
    /// token, so a client can never ask for a file the conversation did not mention; content is verified as an image.
    static let attachmentLimit = 8 * 1024 * 1024
    func attachment(sessionId: String, path: String) throws -> (data: Data, mime: String) {
        let snapshot = try directory.snapshot()
        guard let entry = snapshot.entries.first(where: { $0.sessionId == sessionId }) else { throw RemoteReadError.notFound }
        guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.contains("\0"), !path.contains("/../"), !path.hasSuffix("/..") else {
            throw RemoteReadError.invalidRequest
        }
        let rollout = try Data(contentsOf: directory.historyURL(for: entry), options: .mappedIfSafe)
        guard Self.mentions(path, in: rollout) else { throw RemoteReadError.notFound }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
              let size = values.fileSize else { throw RemoteReadError.attachmentGone }
        guard size <= Self.attachmentLimit else { throw RemoteReadError.attachmentTooLarge }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw RemoteReadError.attachmentGone }
        guard let mime = Self.imageMime(data) else { throw RemoteReadError.attachmentUnsupported }
        return (data, mime)
    }
    private static func mentions(_ path: String, in rollout: Data) -> Bool {
        let needle = Data(path.utf8)
        func pathByte(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || [95, 46, 47, 45, 126, 37, 43, 64].contains(byte)
        }
        var from = rollout.startIndex
        while from < rollout.endIndex, let range = rollout.range(of: needle, in: from..<rollout.endIndex) {
            let before = range.lowerBound > rollout.startIndex ? rollout[rollout.index(before: range.lowerBound)] : 0
            let after = range.upperBound < rollout.endIndex ? rollout[range.upperBound] : 0
            if !pathByte(before) && !pathByte(after) { return true }
            from = rollout.index(after: range.lowerBound)
        }
        return false
    }
    private static func imageMime(_ data: Data) -> String? {
        let head = [UInt8](data.prefix(12))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if head.starts(with: Array("GIF8".utf8)) { return "image/gif" }
        if head.count == 12, head.starts(with: Array("RIFF".utf8)), Array(head[8..<12]) == Array("WEBP".utf8) { return "image/webp" }
        return nil
    }
    func history(sessionId: String, limit: Int, snapshotBytes: UInt64?, beforeOffset: UInt64?) async throws -> RolloutHistoryWindow {
        let snapshot = try directory.snapshot()
        guard let entry = snapshot.entries.first(where: { $0.sessionId == sessionId }) else {
            throw RemoteReadError.notFound
        }
        return try directory.readHistory(for: entry, limit: limit, snapshotBytes: snapshotBytes, beforeOffset: beforeOffset)
    }
}

enum RemoteReadError: Error, Equatable {
    case invalidRequest
    case duplicateRuntime
    case notFound
    case cursorExpired
    case unavailable
    case notImplemented
    case attachmentGone
    case attachmentTooLarge
    case attachmentUnsupported
}

actor RemoteReadService {
    struct Runtime: Codable, Sendable {
        let agentId: String
        let runtimeId: String
        let label: String
        let controlMode: String
        let allowedActions: [String]
        let workspaceId: String?
        let workspaceLabel: String?
    }
    struct Catalog: Codable, Sendable {
        let serverId: String
        let agents: RemoteAgentRegistry.Catalog
        let runtimes: [Runtime]
    }
    struct SessionPage: Codable, Sendable {
        let items: [RemoteSessionSummary]
        let nextCursor: String?
        let hasMore: Bool
        let indexState: String
        let stateFilter: String
        let unknownStateCount: Int
        enum CodingKeys: String, CodingKey { case items, nextCursor, hasMore, indexState, stateFilter, unknownStateCount }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(items, forKey: .items)
            try values.encode(nextCursor, forKey: .nextCursor)
            try values.encode(hasMore, forKey: .hasMore)
            try values.encode(indexState, forKey: .indexState)
            try values.encode(stateFilter, forKey: .stateFilter)
            try values.encode(unknownStateCount, forKey: .unknownStateCount)
        }
    }
    struct HistoryPage: Codable, Sendable {
        let sessionId: String
        let messages: [RemoteHistoryMessage]
        let olderHistoryCursor: String?
        let hasOlder: Bool
        let unsupportedContentCount: Int
        enum CodingKeys: String, CodingKey { case sessionId, messages, olderHistoryCursor, hasOlder, unsupportedContentCount }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(sessionId, forKey: .sessionId)
            try values.encode(messages, forKey: .messages)
            try values.encode(olderHistoryCursor, forKey: .olderHistoryCursor)
            try values.encode(hasOlder, forKey: .hasOlder)
            try values.encode(unsupportedContentCount, forKey: .unsupportedContentCount)
        }
    }
    private struct Listing: Sendable {
        let owner: RemoteAccessStore.PagingOwner
        let sourceLease: UUID
        let agent: String
        let runtime: String
        let query: String
        let stateFilter: String
        let unknownStateCount: Int
        let expires: Date
        let remaining: [RemoteSessionSummary]
        let indexState: String
    }
    private struct History: Sendable {
        let owner: RemoteAccessStore.PagingOwner
        let sourceLease: UUID
        let agent: String
        let runtime: String
        let session: String
        let expires: Date
        let bytes: UInt64
        let before: UInt64
        let digest: String
    }
    let serverId: String
    private let registry = RemoteAgentRegistry()
    private let sessionService: RemoteSessionService?
    let authorizationRegistry: RemoteRuntimeScopeRegistry
    private var adapters: [String: any RemoteReadAdapter] = [:]
    private var runtimeWorkspaces: [String: (id: String, label: String)] = [:]
    private var authorizationLeases: [String: UUID] = [:]
    private var registeredAgents: [String: RemoteAgentDescriptor] = [:]
    private var listings: [String: Listing] = [:]
    private var histories: [String: History] = [:]
    private var sessionAppendedMessages: [String: [RemoteHistoryMessage]] = [:]
    private var activeTurns: [String: String] = [:]

    func setSessionRunning(sessionId: String, turnId: String) {
        activeTurns[sessionId] = turnId
    }

    func setSessionIdle(sessionId: String) {
        activeTurns.removeValue(forKey: sessionId)
    }

    func isSessionRunning(sessionId: String) -> Bool {
        activeTurns[sessionId] != nil
    }

    func appendSessionMessage(sessionId: String, message: RemoteHistoryMessage) {
        var list = sessionAppendedMessages[sessionId] ?? []
        list.append(message)
        sessionAppendedMessages[sessionId] = list
    }

    func locateVendorSessionId(sessionId: String) -> String? {
        for adapter in adapters.values {
            if let chatGPT = adapter as? ChatGPTReadAdapter {
                if let vid = chatGPT.vendorSessionId(for: sessionId) {
                    return vid
                }
            }
        }
        return nil
    }

    init(serverId: String, authorizationRegistry: RemoteRuntimeScopeRegistry = RemoteRuntimeScopeRegistry(), sessionService: RemoteSessionService? = nil) {
        self.serverId = serverId; self.authorizationRegistry = authorizationRegistry; self.sessionService = sessionService
    }
    func response(path: String, query: [String: String], principal: RemoteAccessStore.Principal) async throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if path == "/api/v1/remote/access" {
            guard query.isEmpty else { throw RemoteReadError.invalidRequest }
            guard principal.scopes.count <= 1024 else { throw RemoteReadError.unavailable }
            struct Access: Encodable {
                struct Scope: Encodable {
                    let agentId: String, runtimeId: String
                    let sessionId: String?
                    let actions: [String]
                }
                let serverId: String
                let expiresAt: Date
                let scopes: [Scope]
            }
            let value = Access(serverId: serverId, expiresAt: principal.expiresAt, scopes: principal.scopes.map {
                Access.Scope(agentId: $0.agentId, runtimeId: $0.runtimeId, sessionId: $0.sessionId,
                             actions: $0.actions.map(\.rawValue).sorted())
            })
            let data = try encoder.encode(value)
            guard data.count <= 512 * 1024 else { throw RemoteReadError.unavailable }
            return data
        }
        if path == "/api/v1/remote/catalog" {
            guard query.isEmpty else { throw RemoteReadError.invalidRequest }
            return try encoder.encode(await catalog(principal: principal, client: principal.clientCapabilities ?? .v1))
        }
        guard let agent = query["agent_id"], let runtime = query["runtime_id"], !agent.isEmpty, !runtime.isEmpty else {
            throw RemoteReadError.invalidRequest
        }
        let limit: Int?
        if let raw = query["limit"] {
            guard let parsed = Int(raw), (1...100).contains(parsed) else { throw RemoteReadError.invalidRequest }
            limit = parsed
        } else { limit = nil }
        if path == "/api/v1/remote/sessions" {
            guard Set(query.keys).isSubset(of: ["agent_id", "runtime_id", "cursor", "limit", "q", "state"]) else { throw RemoteReadError.invalidRequest }
            return try encoder.encode(await sessions(principal: principal, agentId: agent, runtimeId: runtime, cursor: query["cursor"], limit: limit ?? 30, query: query["q"] ?? "", state: query["state"] ?? "all"))
        }
        let segments = path.split(separator: "/")
        if segments.count == 6, segments[3] == "sessions", segments[5] == "metadata" {
            guard Set(query.keys) == ["agent_id", "runtime_id"] else { throw RemoteReadError.invalidRequest }
            return try encoder.encode(await metadata(principal: principal, agentId: agent, runtimeId: runtime, sessionId: String(segments[4])))
        }
        if segments.count == 6, segments[3] == "sessions", segments[5] == "messages" {
            guard Set(query.keys).isSubset(of: ["agent_id", "runtime_id", "history_cursor", "limit"]) else { throw RemoteReadError.invalidRequest }
            return try encoder.encode(await history(principal: principal, agentId: agent, runtimeId: runtime,
                sessionId: String(segments[4]), cursor: query["history_cursor"], limit: limit ?? 50))
        }
        throw RemoteReadError.notImplemented
    }
    private func key(_ agent: String, _ runtime: String) -> String { agent + "\u{0}" + runtime }
    /// Workspace association is a trusted local adapter decision, never a query parameter.
    /// ChatGPT's host-wide storage index must use the default nil workspace.
    func register(_ adapter: any RemoteReadAdapter, workspace: RemoteRuntimeScopeRegistry.Workspace? = nil) async throws {
        try adapter.descriptor.validate()
        let id = key(adapter.descriptor.agentId, adapter.runtimeId)
        guard !adapter.runtimeId.isEmpty, adapters[id] == nil else { throw RemoteReadError.duplicateRuntime }
        if let previous = registeredAgents[adapter.descriptor.agentId] {
            guard previous == adapter.descriptor else { throw RemoteRegistryError.invalidDescriptor(adapter.descriptor.agentId) }
        } else {
            try await registry.register(adapter.descriptor)
            registeredAgents[adapter.descriptor.agentId] = adapter.descriptor
        }
        // Registry await is reentrant. Recheck before installing this runtime.
        guard adapters[id] == nil else { throw RemoteReadError.duplicateRuntime }
        let lease = try await authorizationRegistry.register(descriptor: adapter.descriptor, runtimeId: adapter.runtimeId, workspace: workspace, actions: adapter.runtimeActions)
        guard adapters[id] == nil else {
            await authorizationRegistry.unregister(agentId: adapter.descriptor.agentId, runtimeId: adapter.runtimeId, lease: lease)
            throw RemoteReadError.duplicateRuntime
        }
        authorizationLeases[id] = lease
        adapters[id] = adapter
        if let owned = adapter as? ChatGPTJournalReadAdapter, let sessionService {
            do {
                try await sessionService.installHistoryReader(owned.historyReader, lease: lease)
                guard authorizationLeases[id] == lease else {
                    await sessionService.removeHistoryReader(owned.historyReader, lease: lease)
                    throw RemoteReadError.unavailable
                }
            } catch {
                if authorizationLeases[id] == lease {await unregister(agentId: adapter.descriptor.agentId, runtimeId: adapter.runtimeId)}
                throw error
            }
        }
        if let workspace {
            // The trusted registry has already validated the isolated root.
            // The catalog exposes only its display name, never its local path.
            runtimeWorkspaces[id] = (workspace.id, workspace.root.lastPathComponent)
        }
    }
    func unregister(agentId: String, runtimeId: String) async {
        let id = key(agentId, runtimeId)
        let removed = adapters.removeValue(forKey: id)
        runtimeWorkspaces.removeValue(forKey: id)
        listings = listings.filter { $0.value.agent != agentId || $0.value.runtime != runtimeId }
        histories = histories.filter { $0.value.agent != agentId || $0.value.runtime != runtimeId }
        let removedLease = authorizationLeases.removeValue(forKey: id)
        if let lease = removedLease {
            await authorizationRegistry.unregister(agentId: agentId, runtimeId: runtimeId, lease: lease)
        }
        if let owned = removed as? ChatGPTJournalReadAdapter, let removedLease {
            await sessionService?.removeHistoryReader(owned.historyReader, lease: removedLease)
        }
    }
    func hasSession(agentId: String, runtimeId: String, sessionId: String) async -> Bool {
        guard let adapter = adapters[key(agentId, runtimeId)] else { return false }
        return await adapter.containsSession(sessionId: sessionId)
    }
    func locateSession(sessionId: String, principal: RemoteAccessStore.Principal) async -> (agentId: String, runtimeId: String)? {
        for adapter in adapters.values {
            guard principal.permits(agentId: adapter.descriptor.agentId, runtimeId: adapter.runtimeId, sessionId: sessionId, action: .readHistory) else {
                continue
            }
            if await adapter.containsSession(sessionId: sessionId) {
                return (adapter.descriptor.agentId, adapter.runtimeId)
            }
        }
        return nil
    }
    func catalog(principal: RemoteAccessStore.Principal, client: RemoteClientCapabilities) async -> Catalog {
        let visible = adapters.values.filter { adapter in
            principal.scopes.contains { scope in
                (scope.agentId == "*" || scope.agentId == adapter.descriptor.agentId)
                && (scope.runtimeId == "*" || scope.runtimeId == adapter.runtimeId)
            }
        }
        let agents = await registry.catalog(client: client, authorizedAgentIDs: Set(visible.map { $0.descriptor.agentId }))
        let compatible = Set(agents.items.filter { $0.status == "registered" }.map(\.agentId))
        let runtimes = visible.filter { compatible.contains($0.descriptor.agentId) }.map { adapter in
            Runtime(agentId: adapter.descriptor.agentId, runtimeId: adapter.runtimeId, label: adapter.runtimeLabel,
                    controlMode: adapter.runtimeControlMode, allowedActions: adapter.runtimeActions.map(\.rawValue).sorted().filter { action in
                        principal.scopes.contains { scope in
                            (scope.agentId == "*" || scope.agentId == adapter.descriptor.agentId)
                            && (scope.runtimeId == "*" || scope.runtimeId == adapter.runtimeId)
                            && scope.actions.contains(where: { $0.rawValue == action })
                        }
                    }.sorted(), workspaceId: runtimeWorkspaces[key(adapter.descriptor.agentId, adapter.runtimeId)]?.id,
                    workspaceLabel: runtimeWorkspaces[key(adapter.descriptor.agentId, adapter.runtimeId)]?.label)
        }.sorted { ($0.agentId, $0.runtimeId) < ($1.agentId, $1.runtimeId) }
        return .init(serverId: serverId, agents: agents, runtimes: runtimes)
    }
    func sessions(principal: RemoteAccessStore.Principal, agentId: String, runtimeId: String,
                  cursor: String? = nil, limit: Int = 30, now: Date = Date(), query: String = "", state: String = "all") async throws -> SessionPage {
        guard ["all", "active", "history"].contains(state), (1...100).contains(limit) else { throw RemoteReadError.invalidRequest }
        guard query.utf8.count <= 256, !query.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) else {
            throw RemoteReadError.invalidRequest
        }
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        guard principal.permits(agentId: agentId, runtimeId: runtimeId, sessionId: nil, action: .listSessions) else { throw RemoteAccessError.forbidden }
        let sourceId = key(agentId, runtimeId)
        guard let sourceLease = authorizationLeases[sourceId] else { throw RemoteReadError.notFound }
        purge(now)
        let result: RemoteDirectoryResult
        let unknownCount: Int
        if let cursor {
            guard let snapshot = listings[cursor], snapshot.owner == principal.pagingOwner, snapshot.sourceLease == sourceLease,
                  snapshot.agent == agentId, snapshot.runtime == runtimeId, snapshot.query == search, snapshot.stateFilter == state else { throw RemoteReadError.cursorExpired }
            result = .init(items: snapshot.remaining, indexState: snapshot.indexState)
            unknownCount = snapshot.unknownStateCount
        } else {
            guard let adapter = adapters[key(agentId, runtimeId)] else { throw RemoteReadError.notFound }
            let source = try await adapter.sessions(serverId: serverId)
            guard authorizationLeases[sourceId] == sourceLease else { throw RemoteReadError.unavailable }
            guard source.items.count <= 10000, ["ready", "building", "partial"].contains(source.indexState),
                  source.items.allSatisfy({ $0.serverId == serverId && $0.agentId == agentId && $0.runtimeId == runtimeId }),
                  Set(source.items.map(\.sessionId)).count == source.items.count else { throw RemoteReadError.unavailable }
            let authorized = source.items.filter {
                principal.permits(agentId: agentId, runtimeId: runtimeId, sessionId: $0.sessionId, action: .readHistory)
                && (search.isEmpty || $0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).contains(search))
            }
            let controls = await sessionService?.directoryControls(agentId: agentId, runtimeId: runtimeId,
                sessionIds: Set(authorized.map(\.sessionId)), principal: principal) ?? [:]
            guard authorizationLeases[sourceId] == sourceLease else { throw RemoteReadError.unavailable }
            let enriched = authorized.map { item -> RemoteSessionSummary in
                let control = controls[item.sessionId]
                let knownStates = ["idle", "running", "waitingForUser", "completed", "interrupted", "failed"]
                let execution = control.map { $0.controlMode != "unavailable" && knownStates.contains($0.state) ? $0.state : "unknown" } ?? "unknown"
                return .init(serverId: item.serverId, agentId: item.agentId, runtimeId: item.runtimeId, sessionId: item.sessionId,
                    title: item.title, updatedAt: item.updatedAt, archived: item.archived,
                    controlMode: control?.controlMode ?? item.controlMode,
                    allowedActions: (control?.allowedActions ?? item.allowedActions).filter { action in
                        guard let value = RemoteAction(rawValue: action) else { return false }
                        return adapter.descriptor.possibleActions.contains(action)
                            && principal.permits(agentId: agentId, runtimeId: runtimeId, sessionId: item.sessionId, action: value)
                    }, executionState: execution)
            }
            unknownCount = enriched.filter { $0.executionState == "unknown" && !$0.archived }.count
            result = .init(items: enriched.filter { item in
                let active = ["running", "waitingForUser"].contains(item.executionState)
                return state == "all" || (state == "active" ? active
                    : !active && (item.archived || ["idle", "completed", "interrupted", "failed"].contains(item.executionState)))
            }, indexState: source.indexState)
        }
        let rest = Array(result.items.dropFirst(limit))
        let next = rest.isEmpty ? nil : UUID().uuidString
        if let next {
            guard listings.count < 128 else { throw RemoteReadError.unavailable }
            listings[next] = .init(owner: principal.pagingOwner, sourceLease: sourceLease, agent: agentId, runtime: runtimeId, query: search, stateFilter: state, unknownStateCount: unknownCount,
                expires: now.addingTimeInterval(300), remaining: rest, indexState: result.indexState)
        }
        return .init(items: Array(result.items.prefix(limit)), nextCursor: next, hasMore: next != nil, indexState: result.indexState, stateFilter: state, unknownStateCount: unknownCount)
    }
    func metadata(principal: RemoteAccessStore.Principal, agentId: String, runtimeId: String, sessionId: String) async throws -> RemoteSessionMetadata {
        guard principal.permits(agentId: agentId, runtimeId: runtimeId, sessionId: sessionId, action: .readHistory) else { throw RemoteAccessError.forbidden }
        let key = key(agentId, runtimeId)
        guard let adapter = adapters[key], let lease = authorizationLeases[key] else { throw RemoteReadError.notFound }
        var value = try await adapter.metadata(serverId: serverId, sessionId: sessionId)
        guard authorizationLeases[key] == lease else { throw RemoteReadError.unavailable }
        func valid(_ text: String, maximum: Int) -> Bool {
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= maximum &&
            !text.unicodeScalars.contains { $0.value < 32 || (127...159).contains($0.value) }
        }
        guard value.serverId == serverId, value.agentId == agentId, value.runtimeId == runtimeId, value.sessionId == sessionId,
              valid(value.title, maximum: 4096), value.updatedAt.timeIntervalSince1970.isFinite else { throw RemoteReadError.unavailable }
        value.workspaceName = value.workspaceName ?? runtimeWorkspaces[key]?.label
        for text in [value.workspaceName, value.model, value.gitBranch].compactMap({ $0 }) {
            guard valid(text, maximum: 512) else { throw RemoteReadError.unavailable }
        }
        guard value.workspaceName?.contains("/") != true, value.workspaceName?.contains("\\") != true else { throw RemoteReadError.unavailable }
        return value
    }
    func attachment(principal: RemoteAccessStore.Principal, agentId: String, runtimeId: String, sessionId: String,
                    path: String, now: Date = Date()) async throws -> (data: Data, mime: String) {
        guard principal.expiresAt > now, principal.permits(agentId: agentId, runtimeId: runtimeId, sessionId: sessionId, action: .readHistory) else {
            throw RemoteAccessError.forbidden
        }
        let key = key(agentId, runtimeId)
        guard let adapter = adapters[key] as? ChatGPTReadAdapter, let lease = authorizationLeases[key] else { throw RemoteReadError.notFound }
        let result = try await Task.detached { try adapter.attachment(sessionId: sessionId, path: path) }.value
        guard authorizationLeases[key] == lease else { throw RemoteReadError.unavailable }
        return result
    }
    func history(principal: RemoteAccessStore.Principal, agentId: String, runtimeId: String, sessionId: String,
                 cursor: String? = nil, limit: Int = 50, now: Date = Date()) async throws -> HistoryPage {
        guard (1...100).contains(limit), now.timeIntervalSince1970.isFinite else { throw RemoteReadError.invalidRequest }
        guard principal.expiresAt > now, principal.permits(agentId: agentId, runtimeId: runtimeId, sessionId: sessionId, action: .readHistory) else { throw RemoteAccessError.forbidden }
        purge(now)
        guard let adapter = adapters[key(agentId, runtimeId)] else { throw RemoteReadError.notFound }
        guard let sourceLease = authorizationLeases[key(agentId, runtimeId)] else { throw RemoteReadError.notFound }
        if let owned = adapter as? ChatGPTJournalReadAdapter {
            guard owned.ref.sessionId == sessionId else {throw RemoteReadError.notFound}
            let page = try await owned.historyReader.page(principal: principal, cursor: cursor, limit: limit, now: now)
            guard authorizationLeases[key(agentId, runtimeId)] == sourceLease else {throw RemoteReadError.unavailable}
            return page
        }
        var snapshot: History?
        if let cursor {
            guard let saved = histories[cursor], saved.owner == principal.pagingOwner, saved.sourceLease == sourceLease, saved.agent == agentId,
                  saved.runtime == runtimeId, saved.session == sessionId else { throw RemoteReadError.cursorExpired }
            snapshot = saved
        }
        let window = try await adapter.history(sessionId: sessionId, limit: limit, snapshotBytes: snapshot?.bytes, beforeOffset: snapshot?.before)
        guard authorizationLeases[key(agentId, runtimeId)] == sourceLease else { throw RemoteReadError.unavailable }
        guard principal.expiresAt > Date() else {throw RemoteAccessError.forbidden}
        if let snapshot, snapshot.digest != window.snapshotDigest { throw RolloutHistoryError.snapshotChanged }
        let next = window.olderBeforeOffset.map { _ in UUID().uuidString }
        if let next, let before = window.olderBeforeOffset {
            if histories.count >= 128, let oldest = histories.min(by: {$0.value.expires < $1.value.expires})?.key {
                histories.removeValue(forKey: oldest)
            }
            histories[next] = .init(owner: principal.pagingOwner, sourceLease: sourceLease, agent: agentId, runtime: runtimeId, session: sessionId,
                expires: now.addingTimeInterval(300), bytes: window.snapshotBytes, before: before, digest: window.snapshotDigest)
        }
        let extra = snapshot?.before == nil ? (sessionAppendedMessages[sessionId] ?? []) : []
        return .init(sessionId: sessionId, messages: window.messages + extra, olderHistoryCursor: next,
                     hasOlder: next != nil, unsupportedContentCount: window.unsupportedContentCount)
    }
    private func purge(_ now: Date) {
        listings = listings.filter { $0.value.expires > now }
        // File adapters retain only a bounded, owner/lease-bound position.
        // Reading still verifies the original byte-prefix digest after awaits.
        histories = histories.filter { $0.value.expires.addingTimeInterval(86400) > now }
    }
}
