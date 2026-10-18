import Foundation
import SQLite3
import Testing
@testable import Tomo

struct RemoteReadServiceTests {
    actor Gate {
        nonisolated let entered: AsyncStream<Void>
        private let signal: AsyncStream<Void>.Continuation
        private var resume: CheckedContinuation<Void, Never>?
        init() {
            let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            entered = pair.stream; signal = pair.continuation
        }
        func wait() async {
            await withCheckedContinuation { continuation in
                resume = continuation; signal.yield(()); signal.finish()
            }
        }
        func release() { resume?.resume(); resume = nil }
    }
    struct SuspendedAdapter: RemoteReadAdapter {
        let gate: Gate
        var runtimeId: String { "runtime_test" }
        var runtimeLabel: String { "Test" }
        var descriptor: RemoteAgentDescriptor { Adapter().descriptor }
        func sessions(serverId: String) async throws -> RemoteDirectoryResult {
            await gate.wait()
            return try await Adapter().sessions(serverId: serverId)
        }
        func history(sessionId: String, limit: Int, snapshotBytes: UInt64?, beforeOffset: UInt64?) async throws -> RolloutHistoryWindow {
            await gate.wait()
            return try await Adapter().history(sessionId: sessionId, limit: limit, snapshotBytes: snapshotBytes, beforeOffset: beforeOffset)
        }
    }
    @Test func withdrawnSourceCannotReturnInflightPagesEvenAfterReplacement() async throws {
        for history in [false, true] {
            let gate = Gate(), service = RemoteReadService(serverId: "srv_test"), access = RemoteAccessStore()
            await access.setDevelopmentEnabled(true)
            let principal = try await owner(access)
            try await service.register(SuspendedAdapter(gate: gate))
            let request = Task {
                if history {
                    _ = try await service.history(principal: principal, agentId: "agent.chatgpt", runtimeId: "runtime_test", sessionId: "ss_3")
                } else {
                    _ = try await service.sessions(principal: principal, agentId: "agent.chatgpt", runtimeId: "runtime_test")
                }
            }
            for await _ in gate.entered { break }
            await service.unregister(agentId: "agent.chatgpt", runtimeId: "runtime_test")
            try await service.register(Adapter())
            await gate.release()
            await #expect(throws: RemoteReadError.unavailable) { try await request.value }
        }
    }
    @Test func realChatGPTAdapterDetectsRewrittenHistorySnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout.jsonl")
        let database = root.appendingPathComponent("state.sqlite")
        var pointer: OpaquePointer?
        #expect(sqlite3_open(database.path, &pointer) == SQLITE_OK)
        let db = try #require(pointer)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "CREATE TABLE threads (id TEXT, rollout_path TEXT, title TEXT, updated_at INTEGER)", nil, nil, nil) == SQLITE_OK)
        let path = file.path.replacingOccurrences(of: "'", with: "''")
        #expect(sqlite3_exec(db, "INSERT INTO threads VALUES ('vendor-one', '\(path)', 'Visible title', 1)", nil, nil, nil) == SQLITE_OK)
        let meta = #"{"type":"session_meta","payload":{"id":"vendor-one"}}"#
        func text(_ value: String) -> String { #"{"type":"response_item","timestamp":"2026-10-03T00:00:00Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":""# + value + #""}]}}"# }
        let original = meta + "\n" + text("older") + "\n" + text("newer") + "\n"
        try Data(original.utf8).write(to: file)
        let service = RemoteReadService(serverId: "srv_test")
        try await service.register(ChatGPTReadAdapter(directory: .init(databaseURL: database, storageRoot: root, runtimeId: "runtime_test"), runtimeLabel: "Personal"))
        let access = RemoteAccessStore()
        await access.setDevelopmentEnabled(true)
        let principal = try await owner(access)
        let sessions = try await service.sessions(principal: principal, agentId: "agent.chatgpt", runtimeId: "runtime_test")
        let id = try #require(sessions.items.first?.sessionId)
        let latest = try await service.history(principal: principal, agentId: "agent.chatgpt", runtimeId: "runtime_test", sessionId: id, limit: 1)
        #expect(latest.messages.first?.content.first?.text == "newer")
        // Appending leaves the cursor snapshot unchanged.
        try Data((original + text("extra") + "\n").utf8).write(to: file)
        let older = try await service.history(principal: principal, agentId: "agent.chatgpt", runtimeId: "runtime_test", sessionId: id, cursor: latest.olderHistoryCursor, limit: 1)
        #expect(older.messages.first?.content.first?.text == "older")
        // Same-sized valid rewrite must not silently return a different page.
        try Data(original.replacingOccurrences(of: "older", with: "other").utf8).write(to: file)
        await #expect(throws: RolloutHistoryError.snapshotChanged) {
            try await service.history(principal: principal, agentId: "agent.chatgpt", runtimeId: "runtime_test", sessionId: id, cursor: latest.olderHistoryCursor, limit: 1)
        }
        let data = try await service.response(path: "/api/v1/remote/sessions", query: ["agent_id": "agent.chatgpt", "runtime_id": "runtime_test"], principal: principal)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains(root.path))
        #expect(!json.contains("vendor-one"))
        #expect(json.contains("readOnly"))
        let listWire = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(listWire["nextCursor"] is NSNull)
        let historyData = try await service.response(path: "/api/v1/remote/sessions/\(id)/messages",
            query: ["agent_id": "agent.chatgpt", "runtime_id": "runtime_test"], principal: principal)
        let historyWire = try #require(JSONSerialization.jsonObject(with: historyData) as? [String: Any])
        #expect(historyWire["olderHistoryCursor"] is NSNull)
        let messages = try #require(historyWire["messages"] as? [[String: Any]])
        #expect(messages[0]["turnId"] is NSNull)
    }
    struct Adapter: RemoteReadAdapter {
        let runtimeId = "runtime_test"
        let runtimeLabel = "Test"
        let descriptor = ChatGPTReadAdapter(directory: .init(databaseURL: URL(fileURLWithPath: "/unused"), storageRoot: URL(fileURLWithPath: "/unused"), runtimeId: "unused"), runtimeLabel: "unused").descriptor
        func sessions(serverId: String) async throws -> RemoteDirectoryResult {
            .init(items: (1...3).reversed().map { index in
                .init(serverId: serverId, agentId: descriptor.agentId, runtimeId: runtimeId, sessionId: "ss_\(index)", title: "Title \(index)", updatedAt: Date(timeIntervalSince1970: Double(index)), archived: false, controlMode: "readOnly", allowedActions: ["history.read"])
            }, indexState: "ready")
        }
        func history(sessionId: String, limit: Int, snapshotBytes: UInt64?, beforeOffset: UInt64?) async throws -> RolloutHistoryWindow {
            let index = beforeOffset ?? 3
            return .init(messages: [.init(messageId: "msg_\(index)", turnId: nil, messageRevision: 1, role: "user", createdAt: "2026-10-03T00:00:00Z", status: "completed", content: [.init(partId: "p", type: "text", text: "Message \(index)")])], snapshotBytes: snapshotBytes ?? 100, olderBeforeOffset: index > 1 ? index - 1 : nil, unsupportedContentCount: 0, snapshotDigest: "fixture")
        }
    }
    private func owner(_ store: RemoteAccessStore, runtime: String = "runtime_test") async throws -> RemoteAccessStore.Principal {
        try await store.issueDevelopment(scopes: [.init(agentId: "agent.chatgpt", runtimeId: runtime, sessionId: nil, actions: [.listSessions, .readHistory])], origin: nil).principal
    }
    struct SearchAdapter: RemoteReadAdapter {
        let base = Adapter()
        var runtimeId: String { base.runtimeId }
        var runtimeLabel: String { base.runtimeLabel }
        var descriptor: RemoteAgentDescriptor { base.descriptor }
        func sessions(serverId: String) async throws -> RemoteDirectoryResult {
            .init(items: (1...70).reversed().map { index in
                .init(serverId: serverId, agentId: descriptor.agentId, runtimeId: runtimeId, sessionId: "ss_\(index)",
                      title: index <= 3 ? "Café 搜索 🐙 \(index)" : "Title \(index)", updatedAt: Date(timeIntervalSince1970: Double(index)),
                      archived: false, controlMode: "readOnly", allowedActions: ["history.read"])
            }, indexState: "partial")
        }
        func history(sessionId: String, limit: Int, snapshotBytes: UInt64?, beforeOffset: UInt64?) async throws -> RolloutHistoryWindow {
            try await base.history(sessionId: sessionId, limit: limit, snapshotBytes: snapshotBytes, beforeOffset: beforeOffset)
        }
    }
    struct ArchivedAdapter: RemoteReadAdapter {
        let base = Adapter()
        var runtimeId: String { base.runtimeId }
        var runtimeLabel: String { base.runtimeLabel }
        var descriptor: RemoteAgentDescriptor { base.descriptor }
        func sessions(serverId: String) async throws -> RemoteDirectoryResult {
            let source = try await base.sessions(serverId: serverId)
            return .init(items: source.items.map { item in
                .init(serverId: item.serverId, agentId: item.agentId, runtimeId: item.runtimeId, sessionId: item.sessionId,
                      title: item.title, updatedAt: item.updatedAt, archived: item.sessionId == "ss_1",
                      controlMode: item.controlMode, allowedActions: item.allowedActions)
            }, indexState: source.indexState)
        }
        func history(sessionId: String, limit: Int, snapshotBytes: UInt64?, beforeOffset: UInt64?) async throws -> RolloutHistoryWindow {
            try await base.history(sessionId: sessionId, limit: limit, snapshotBytes: snapshotBytes, beforeOffset: beforeOffset)
        }
    }
    @Test func archivedRowsAreHistoryButUnavailableExecutorsDoNotBecomeActiveOrFinished() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try RemoteSessionJournal(databaseURL: root.appendingPathComponent("states.sqlite"))
        let sessions = RemoteSessionService(serverId: "srv_test")
        let service = RemoteReadService(serverId: "srv_test", sessionService: sessions), access = RemoteAccessStore()
        await access.setDevelopmentEnabled(true)
        let principal = try await owner(access)
        try await service.register(ArchivedAdapter())
        let ref = RemoteSessionRef(serverId: "srv_test", agentId: "agent.chatgpt", runtimeId: "runtime_test", sessionId: "ss_2")
        _ = try await journal.replace(ref: ref, projection: .init(control: .init(executionEpoch: "epoch", controlRevision: 1,
            state: "running", controlMode: "readOnly", currentTurnId: "turn", allowedActions: ["history.read"]),
            messages: [], pendingRequests: [], olderHistoryCursor: nil, hasOlder: false))
        try await sessions.register(ref: ref, journal: journal, available: {false})
        let history = try await service.sessions(principal: principal, agentId: "agent.chatgpt", runtimeId: "runtime_test", state: "history")
        #expect(history.items.map(\.sessionId) == ["ss_1"] && history.unknownStateCount == 2)
        let active = try await service.sessions(principal: principal, agentId: "agent.chatgpt", runtimeId: "runtime_test", state: "active")
        #expect(active.items.isEmpty && active.unknownStateCount == 2)
    }

    @Test func stateFilteringUsesExactRegisteredJournalsBeforePagingAndBindsCursors() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try RemoteSessionJournal(databaseURL: root.appendingPathComponent("events.sqlite"))
        let sessions = RemoteSessionService(serverId: "srv_test")
        let service = RemoteReadService(serverId: "srv_test", sessionService: sessions), access = RemoteAccessStore()
        await access.setDevelopmentEnabled(true)
        let principal = try await owner(access)
        try await service.register(SearchAdapter())
        for (id, state, runtime) in [("ss_1", "running", "runtime_test"), ("ss_2", "waitingForUser", "runtime_test"),
                                     ("ss_3", "completed", "runtime_test"), ("ss_4", "running", "different_runtime")] {
            let ref = RemoteSessionRef(serverId: "srv_test", agentId: "agent.chatgpt", runtimeId: runtime, sessionId: id)
            _ = try await journal.replace(ref: ref, projection: .init(control: .init(executionEpoch: "epoch", controlRevision: 1,
                state: state, controlMode: "readOnly", currentTurnId: state == "completed" ? nil : "turn", allowedActions: ["history.read"]),
                messages: [], pendingRequests: [], olderHistoryCursor: nil, hasOlder: false))
            try await sessions.register(ref: ref, journal: journal)
        }
        let all = try await service.sessions(principal: principal, agentId: "agent.chatgpt", runtimeId: "runtime_test")
        #expect(all.items.count == 30 && all.items.allSatisfy { $0.executionState == "unknown" })
        #expect(all.unknownStateCount == 67)
        let active = try await service.sessions(principal: principal, agentId: "agent.chatgpt", runtimeId: "runtime_test", limit: 1, query: "搜索", state: "active")
        #expect(active.items.map(\.sessionId) == ["ss_2"] && active.items.first?.executionState == "waitingForUser")
        #expect(active.stateFilter == "active" && active.unknownStateCount == 0 && active.hasMore)
        let next = try await service.sessions(principal: principal, agentId: "agent.chatgpt", runtimeId: "runtime_test", cursor: active.nextCursor, query: "搜索", state: "active")
        #expect(next.items.map(\.sessionId) == ["ss_1"])
        await #expect(throws: RemoteReadError.cursorExpired) {
            try await service.sessions(principal: principal, agentId: "agent.chatgpt", runtimeId: "runtime_test", cursor: active.nextCursor, query: "搜索", state: "history")
        }
        let history = try await service.sessions(principal: principal, agentId: "agent.chatgpt", runtimeId: "runtime_test", state: "history")
        #expect(history.items.map(\.sessionId) == ["ss_3"] && history.unknownStateCount == 67)
        await sessions.unregister(sessionId: "ss_1")
        let fresh = try await service.sessions(principal: principal, agentId: "agent.chatgpt", runtimeId: "runtime_test", state: "active")
        #expect(fresh.items.map(\.sessionId) == ["ss_2"] && fresh.unknownStateCount == 68)
        let restricted = try await access.issueDevelopment(scopes: [
            .init(agentId: "agent.chatgpt", runtimeId: "runtime_test", sessionId: nil, actions: [.listSessions]),
            .init(agentId: "agent.chatgpt", runtimeId: "runtime_test", sessionId: "ss_3", actions: [.readHistory])], origin: nil).principal
        let hidden = try await service.sessions(principal: restricted, agentId: "agent.chatgpt", runtimeId: "runtime_test", state: "active")
        #expect(hidden.items.isEmpty && hidden.unknownStateCount == 0)
        let wire = try await service.response(path: "/api/v1/remote/sessions", query: ["agent_id": "agent.chatgpt", "runtime_id": "runtime_test", "state": "history"], principal: principal)
        let body = try #require(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        #expect(body["stateFilter"] as? String == "history")
        await #expect(throws: RemoteReadError.invalidRequest) {
            try await service.sessions(principal: principal, agentId: "agent.chatgpt", runtimeId: "runtime_test", state: "completed")
        }
    }

    @Test func searchFindsUnloadedTitlesAndBindsEveryPageToItsQuery() async throws {
        let service = RemoteReadService(serverId: "srv_test"), access = RemoteAccessStore()
        await access.setDevelopmentEnabled(true)
        try await service.register(SearchAdapter())
        let principal = try await owner(access)
        let initial = try await service.sessions(principal: principal, agentId: "agent.chatgpt", runtimeId: "runtime_test")
        #expect(initial.items.allSatisfy { !$0.title.contains("搜索") })
        let search = try await service.sessions(principal: principal, agentId: "agent.chatgpt", runtimeId: "runtime_test", limit: 1, query: " CAFE 搜索 🐙 ")
        #expect(search.items.map(\.sessionId) == ["ss_3"])
        #expect(search.indexState == "partial")
        let next = try await service.sessions(principal: principal, agentId: "agent.chatgpt", runtimeId: "runtime_test", cursor: search.nextCursor, limit: 1, query: "café 搜索 🐙")
        #expect(next.items.map(\.sessionId) == ["ss_2"])
        for changed in ["", "Title", "搜索"] {
            await #expect(throws: RemoteReadError.cursorExpired) {
                try await service.sessions(principal: principal, agentId: "agent.chatgpt", runtimeId: "runtime_test", cursor: search.nextCursor, query: changed)
            }
        }
        let wire = try await service.response(path: "/api/v1/remote/sessions", query: ["agent_id": "agent.chatgpt", "runtime_id": "runtime_test", "q": "搜索", "limit": "1"], principal: principal)
        let json = try #require(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        #expect((json["items"] as? [[String: Any]])?.first?["sessionId"] as? String == "ss_3")
        for invalid in [String(repeating: "中", count: 86), "bad\nquery", "bad\0query"] {
            await #expect(throws: RemoteReadError.invalidRequest) {
                try await service.sessions(principal: principal, agentId: "agent.chatgpt", runtimeId: "runtime_test", query: invalid)
            }
        }
    }
    @Test func searchNeverReturnsTitlesOutsideSessionReadScopes() async throws {
        let service = RemoteReadService(serverId: "srv_test"), access = RemoteAccessStore()
        try await service.register(SearchAdapter())
        await access.setDevelopmentEnabled(true)
        let principal = try await access.issueDevelopment(scopes: [
            .init(agentId: "agent.chatgpt", runtimeId: "runtime_test", sessionId: nil, actions: [.listSessions]),
            .init(agentId: "agent.chatgpt", runtimeId: "runtime_test", sessionId: "ss_1", actions: [.readHistory])
        ], origin: nil).principal
        let search = try await service.sessions(principal: principal, agentId: "agent.chatgpt", runtimeId: "runtime_test", limit: 1, query: "搜索")
        #expect(search.items.map(\.sessionId) == ["ss_1"])
        #expect(!search.hasMore)
    }
    @Test func fileHistoryRetainsBoundedPositionsPastSnapshotTTLButNeverPastAccessExpiry() async throws {
        let service = RemoteReadService(serverId: "srv_test")
        try await service.register(Adapter())
        let now = Date(), scope = RemoteAccessStore.Scope(agentId: "agent.chatgpt", runtimeId: "runtime_test", sessionId: nil,
            actions: [.listSessions, .readHistory])
        let owner = RemoteAccessStore.Principal(id: UUID(), expiresAt: now.addingTimeInterval(1000), scopes: [scope], origin: nil, generation: 0)
        let latest = try await service.history(principal: owner, agentId: "agent.chatgpt", runtimeId: "runtime_test", sessionId: "ss_3", limit: 1, now: now)
        let cursor = try #require(latest.olderHistoryCursor)
        let older = try await service.history(principal: owner, agentId: "agent.chatgpt", runtimeId: "runtime_test", sessionId: "ss_3", cursor: cursor, limit: 1, now: now.addingTimeInterval(301))
        #expect(older.messages.map(\.messageId) == ["msg_2"])
        let expired = RemoteAccessStore.Principal(id: owner.id, expiresAt: now.addingTimeInterval(300), scopes: [scope], origin: nil, generation: 0)
        await #expect(throws: RemoteAccessError.forbidden) {
            try await service.history(principal: expired, agentId: "agent.chatgpt", runtimeId: "runtime_test", sessionId: "ss_3", cursor: cursor, now: now.addingTimeInterval(301))
        }
        let renewed = RemoteAccessStore.Principal(id: owner.id, expiresAt: now.addingTimeInterval(100000), scopes: [scope], origin: nil, generation: 0)
        await #expect(throws: RemoteReadError.cursorExpired) {
            try await service.history(principal: renewed, agentId: "agent.chatgpt", runtimeId: "runtime_test", sessionId: "ss_3", cursor: cursor, now: now.addingTimeInterval(86701))
        }
    }
    @Test func catalogAndPagesAreBoundToOwnerAndFullResourceTuple() async throws {
        let service = RemoteReadService(serverId: "srv_test")
        try await service.register(Adapter())
        let access = RemoteAccessStore()
        await access.setDevelopmentEnabled(true)
        let principal = try await owner(access)
        let stranger = try await owner(access)
        let other = try await owner(access, runtime: "runtime_other")
        let client = RemoteClientCapabilities(descriptorMajors: [1], apiMajors: [1], eventMajors: [1], contentMajors: [1], clientFeatures: [])
        #expect(await service.catalog(principal: principal, client: client).runtimes.count == 1)
        #expect(await service.catalog(principal: other, client: client).runtimes.isEmpty)
        let page = try await service.sessions(principal: principal, agentId: "agent.chatgpt", runtimeId: "runtime_test", limit: 1)
        #expect(page.items[0].sessionId == "ss_3")
        let next = try await service.sessions(principal: principal, agentId: "agent.chatgpt", runtimeId: "runtime_test", cursor: page.nextCursor, limit: 1)
        #expect(next.items[0].sessionId == "ss_2")
        await #expect(throws: RemoteReadError.cursorExpired) {
            try await service.sessions(principal: stranger, agentId: "agent.chatgpt", runtimeId: "runtime_test", cursor: page.nextCursor)
        }
        let history = try await service.history(principal: principal, agentId: "agent.chatgpt", runtimeId: "runtime_test", sessionId: "ss_3", limit: 1)
        let older = try await service.history(principal: principal, agentId: "agent.chatgpt", runtimeId: "runtime_test", sessionId: "ss_3", cursor: history.olderHistoryCursor, limit: 1)
        #expect(older.messages[0].messageId == "msg_2")
        await #expect(throws: RemoteReadError.cursorExpired) {
            try await service.history(principal: principal, agentId: "agent.chatgpt", runtimeId: "runtime_test", sessionId: "ss_2", cursor: history.olderHistoryCursor)
        }
        await #expect(throws: RemoteAccessError.forbidden) {
            try await service.history(principal: other, agentId: "agent.chatgpt", runtimeId: "runtime_test", sessionId: "ss_3")
        }
        let data = try await service.response(path: "/api/v1/remote/sessions/ss_3/messages", query: ["agent_id": "agent.chatgpt", "runtime_id": "runtime_test"], principal: principal)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("snapshotBytes"))
        #expect(!json.contains("beforeOffset"))
    }
    @Test func catalogExposesOnlyTrustedWorkspaceAliasForIsolatedRuntime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TomoGo-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = RemoteReadService(serverId: "srv_test")
        let workspace = try await service.authorizationRegistry.registerWorkspace(id: "ws_test", root: root)
        try await service.register(Adapter(), workspace: workspace)
        let access = RemoteAccessStore()
        await access.setDevelopmentEnabled(true)
        let principal = try await owner(access)
        let client = RemoteClientCapabilities(descriptorMajors: [1], apiMajors: [1], eventMajors: [1], contentMajors: [1], clientFeatures: [])
        let catalog = await service.catalog(principal: principal, client: client)
        #expect(catalog.runtimes.first?.workspaceId == "ws_test")
        #expect(catalog.runtimes.first?.workspaceLabel == root.lastPathComponent)
        let wire = String(decoding: try JSONEncoder().encode(catalog), as: UTF8.self)
        #expect(!wire.contains(root.path))
        await service.unregister(agentId: "agent.chatgpt", runtimeId: "runtime_test")
        try await service.register(Adapter())
        #expect(await service.catalog(principal: principal, client: client).runtimes.first?.workspaceId == nil)
    }
    @Test func duplicateRuntimeInvalidInputAndCursorExpiryFailExplicitly() async throws {
        let service = RemoteReadService(serverId: "srv_test")
        try await service.register(Adapter())
        await #expect(throws: RemoteReadError.duplicateRuntime) { try await service.register(Adapter()) }
        let access = RemoteAccessStore()
        await access.setDevelopmentEnabled(true)
        let principal = try await owner(access)
        let page = try await service.sessions(principal: principal, agentId: "agent.chatgpt", runtimeId: "runtime_test", limit: 1)
        await #expect(throws: RemoteReadError.cursorExpired) {
            try await service.sessions(principal: principal, agentId: "agent.chatgpt", runtimeId: "runtime_test", cursor: page.nextCursor, now: Date().addingTimeInterval(301))
        }
        await #expect(throws: RemoteReadError.invalidRequest) {
            try await service.response(path: "/api/v1/remote/sessions", query: ["agent_id": "agent.chatgpt", "runtime_id": "runtime_test", "limit": "nan"], principal: principal)
        }
    }
}
