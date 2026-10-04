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
}
struct RemoteDirectoryResult: Sendable {
    let items: [RemoteSessionSummary]
    let indexState: String
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
}
extension RemoteReadAdapter {
    var runtimeActions: Set<RemoteAction> { Set(descriptor.possibleActions.compactMap(RemoteAction.init(rawValue:))) }
    var runtimeControlMode: String { "readOnly" }
}

struct ChatGPTReadAdapter: RemoteReadAdapter {
    let directory: ChatGPTSessionDirectory
    let runtimeLabel: String
    var runtimeId: String { directory.runtimeId }
    var runtimeActions: Set<RemoteAction> { [.listSessions, .readHistory] }
    var descriptor: RemoteAgentDescriptor {
        .init(agentId: "agent.chatgpt", displayName: "ChatGPT", adapterId: "tomo.adapter.chatgpt-rollout",
              adapterVersion: "1.0.0", descriptorSchemaVersion: 1, supportedApiMajors: [1],
              supportedEventMajors: [1], supportedContentMajors: [1],
              surfaces: [.init(id: "surface.chatgpt-cli", kind: "cli", label: "CLI")],
              brand: .init(iconAssetId: nil, fallbackGlyph: "chat"),
              possibleActions: ["sessions.list", "history.read", "message.send", "turn.interrupt"], inputTypes: ["text"], outputTypes: ["text", "error"],
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
}

actor RemoteReadService {
    struct Runtime: Codable, Sendable {
        let agentId: String
        let runtimeId: String
        let label: String
        let controlMode: String
        let allowedActions: [String]
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
        enum CodingKeys: String, CodingKey { case items, nextCursor, hasMore, indexState }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(items, forKey: .items)
            try values.encode(nextCursor, forKey: .nextCursor)
            try values.encode(hasMore, forKey: .hasMore)
            try values.encode(indexState, forKey: .indexState)
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
        let owner: UUID
        let agent: String
        let runtime: String
        let expires: Date
        let remaining: [RemoteSessionSummary]
        let indexState: String
    }
    private struct History: Sendable {
        let owner: UUID
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
    let authorizationRegistry: RemoteRuntimeScopeRegistry
    private var adapters: [String: any RemoteReadAdapter] = [:]
    private var authorizationLeases: [String: UUID] = [:]
    private var registeredAgents: [String: RemoteAgentDescriptor] = [:]
    private var listings: [String: Listing] = [:]
    private var histories: [String: History] = [:]

    init(serverId: String, authorizationRegistry: RemoteRuntimeScopeRegistry = RemoteRuntimeScopeRegistry()) {
        self.serverId = serverId; self.authorizationRegistry = authorizationRegistry
    }
    func response(path: String, query: [String: String], principal: RemoteAccessStore.Principal) async throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
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
            guard Set(query.keys).isSubset(of: ["agent_id", "runtime_id", "cursor", "limit"]) else { throw RemoteReadError.invalidRequest }
            return try encoder.encode(await sessions(principal: principal, agentId: agent, runtimeId: runtime, cursor: query["cursor"], limit: limit ?? 30))
        }
        let segments = path.split(separator: "/")
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
    }
    func unregister(agentId: String, runtimeId: String) async {
        let id = key(agentId, runtimeId)
        adapters.removeValue(forKey: id)
        listings = listings.filter { $0.value.agent != agentId || $0.value.runtime != runtimeId }
        histories = histories.filter { $0.value.agent != agentId || $0.value.runtime != runtimeId }
        if let lease = authorizationLeases.removeValue(forKey: id) {
            await authorizationRegistry.unregister(agentId: agentId, runtimeId: runtimeId, lease: lease)
        }
    }
    func catalog(principal: RemoteAccessStore.Principal, client: RemoteClientCapabilities) async -> Catalog {
        let visible = adapters.values.filter { adapter in
            principal.scopes.contains { $0.agentId == adapter.descriptor.agentId && $0.runtimeId == adapter.runtimeId }
        }
        let agents = await registry.catalog(client: client, authorizedAgentIDs: Set(visible.map { $0.descriptor.agentId }))
        let compatible = Set(agents.items.filter { $0.status == "registered" }.map(\.agentId))
        let runtimes = visible.filter { compatible.contains($0.descriptor.agentId) }.map { adapter in
            Runtime(agentId: adapter.descriptor.agentId, runtimeId: adapter.runtimeId, label: adapter.runtimeLabel,
                    controlMode: adapter.runtimeControlMode, allowedActions: adapter.runtimeActions.map(\.rawValue).sorted().filter { action in
                        principal.scopes.contains { $0.agentId == adapter.descriptor.agentId && $0.runtimeId == adapter.runtimeId && $0.actions.contains(where: { $0.rawValue == action }) }
                    }.sorted())
        }.sorted { ($0.agentId, $0.runtimeId) < ($1.agentId, $1.runtimeId) }
        return .init(serverId: serverId, agents: agents, runtimes: runtimes)
    }
    func sessions(principal: RemoteAccessStore.Principal, agentId: String, runtimeId: String,
                  cursor: String? = nil, limit: Int = 30, now: Date = Date()) async throws -> SessionPage {
        guard (1...100).contains(limit) else { throw RemoteReadError.invalidRequest }
        guard principal.permits(agentId: agentId, runtimeId: runtimeId, sessionId: nil, action: .listSessions) else { throw RemoteAccessError.forbidden }
        let sourceId = key(agentId, runtimeId)
        guard let sourceLease = authorizationLeases[sourceId] else { throw RemoteReadError.notFound }
        purge(now)
        let result: RemoteDirectoryResult
        if let cursor {
            guard let snapshot = listings[cursor], snapshot.owner == principal.id,
                  snapshot.agent == agentId, snapshot.runtime == runtimeId else { throw RemoteReadError.cursorExpired }
            result = .init(items: snapshot.remaining, indexState: snapshot.indexState)
        } else {
            guard let adapter = adapters[key(agentId, runtimeId)] else { throw RemoteReadError.notFound }
            let source = try await adapter.sessions(serverId: serverId)
            guard authorizationLeases[sourceId] == sourceLease else { throw RemoteReadError.unavailable }
            guard source.items.count <= 10000, ["ready", "building", "partial"].contains(source.indexState),
                  source.items.allSatisfy({ $0.serverId == serverId && $0.agentId == agentId && $0.runtimeId == runtimeId }),
                  Set(source.items.map(\.sessionId)).count == source.items.count else { throw RemoteReadError.unavailable }
            result = .init(items: source.items.filter { principal.permits(agentId: agentId, runtimeId: runtimeId, sessionId: $0.sessionId, action: .readHistory) }.map { item in
                .init(serverId: item.serverId, agentId: item.agentId, runtimeId: item.runtimeId, sessionId: item.sessionId,
                      title: item.title, updatedAt: item.updatedAt, archived: item.archived, controlMode: "readOnly",
                      allowedActions: item.allowedActions.filter { action in
                          adapter.descriptor.possibleActions.contains(action) && action == RemoteAction.readHistory.rawValue
                      })
            }, indexState: source.indexState)
        }
        let rest = Array(result.items.dropFirst(limit))
        let next = rest.isEmpty ? nil : UUID().uuidString
        if let next {
            guard listings.count < 128 else { throw RemoteReadError.unavailable }
            listings[next] = .init(owner: principal.id, agent: agentId, runtime: runtimeId,
                expires: min(principal.expiresAt, now.addingTimeInterval(300)), remaining: rest, indexState: result.indexState)
        }
        return .init(items: Array(result.items.prefix(limit)), nextCursor: next, hasMore: next != nil, indexState: result.indexState)
    }
    func history(principal: RemoteAccessStore.Principal, agentId: String, runtimeId: String, sessionId: String,
                 cursor: String? = nil, limit: Int = 50, now: Date = Date()) async throws -> HistoryPage {
        guard (1...100).contains(limit) else { throw RemoteReadError.invalidRequest }
        guard principal.permits(agentId: agentId, runtimeId: runtimeId, sessionId: sessionId, action: .readHistory) else { throw RemoteAccessError.forbidden }
        purge(now)
        var snapshot: History?
        if let cursor {
            guard let saved = histories[cursor], saved.owner == principal.id, saved.agent == agentId,
                  saved.runtime == runtimeId, saved.session == sessionId else { throw RemoteReadError.cursorExpired }
            snapshot = saved
        }
        guard let adapter = adapters[key(agentId, runtimeId)] else { throw RemoteReadError.notFound }
        guard let sourceLease = authorizationLeases[key(agentId, runtimeId)] else { throw RemoteReadError.notFound }
        let window = try await adapter.history(sessionId: sessionId, limit: limit, snapshotBytes: snapshot?.bytes, beforeOffset: snapshot?.before)
        guard authorizationLeases[key(agentId, runtimeId)] == sourceLease else { throw RemoteReadError.unavailable }
        if let snapshot, snapshot.digest != window.snapshotDigest { throw RolloutHistoryError.snapshotChanged }
        let next = window.olderBeforeOffset.map { _ in UUID().uuidString }
        if let next, let before = window.olderBeforeOffset {
            guard histories.count < 128 else { throw RemoteReadError.unavailable }
            histories[next] = .init(owner: principal.id, agent: agentId, runtime: runtimeId, session: sessionId,
                expires: min(principal.expiresAt, now.addingTimeInterval(300)), bytes: window.snapshotBytes, before: before, digest: window.snapshotDigest)
        }
        return .init(sessionId: sessionId, messages: window.messages, olderHistoryCursor: next,
                     hasOlder: next != nil, unsupportedContentCount: window.unsupportedContentCount)
    }
    private func purge(_ now: Date) {
        listings = listings.filter { $0.value.expires > now }
        histories = histories.filter { $0.value.expires > now }
    }
}
