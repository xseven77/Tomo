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
