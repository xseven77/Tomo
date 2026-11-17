import Foundation
import SQLite3
import Testing
@testable import Tomo

struct RemoteSessionMetadataTests {
    @Test func historyMetadataComesFromRegisteredDirectoryWithoutExposingLocators() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("state.sqlite")
        var pointer: OpaquePointer?
        #expect(sqlite3_open(database.path, &pointer) == SQLITE_OK)
        let db = try #require(pointer); defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db,"CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, title TEXT, updated_at INTEGER, archived INTEGER, cwd TEXT, model TEXT, git_branch TEXT)",nil,nil,nil) == SQLITE_OK)
        #expect(sqlite3_exec(db,"INSERT INTO threads VALUES ('old', '/private/no-history-read.jsonl', '真实历史标题', 1900000000, 1, '/Users/private/work/TomoGo', 'qa-model', 'main')",nil,nil,nil) == SQLITE_OK)
        let directory = ChatGPTSessionDirectory(databaseURL: database, storageRoot: root, runtimeId: "rt_history")
        let entry = try #require(directory.snapshot().entries.first)
        let service = RemoteReadService(serverId: "server-real")
        try await service.register(ChatGPTReadAdapter(directory: directory, runtimeLabel: "History"))
        let store = RemoteAccessStore()
        await store.setDevelopmentEnabled(true)
        let owner = try await store.issueDevelopment(scopes: [.init(agentId: "agent.chatgpt", runtimeId: "rt_history", sessionId: entry.sessionId, actions: [.readHistory])], origin: nil).principal
        let data = try await service.response(path: "/api/v1/remote/sessions/\(entry.sessionId)/metadata", query: ["agent_id":"agent.chatgpt","runtime_id":"rt_history"], principal: owner)
        let value = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(value.keys) == ["serverId","agentId","runtimeId","sessionId","title","updatedAt","archived","workspaceName","model","gitBranch"])
        #expect(value["workspaceName"] as? String == "TomoGo")
        #expect(value["model"] as? String == "qa-model")
        #expect(value["archived"] as? Bool == true)
        #expect(value["sessionId"] as? String == entry.sessionId)
        #expect(!String(decoding:data,as:UTF8.self).contains("/Users/"))
        #expect(!String(decoding:data,as:UTF8.self).contains("no-history-read"))
        await #expect(throws: RemoteAccessError.forbidden) {
            try await service.metadata(principal: owner, agentId: "agent.chatgpt", runtimeId: "rt_history", sessionId: "other")
        }
        await #expect(throws: RemoteReadError.invalidRequest) {
            try await service.response(path: "/api/v1/remote/sessions/\(entry.sessionId)/metadata", query: ["agent_id":"agent.chatgpt","runtime_id":"rt_history","path":"/private"], principal: owner)
        }
    }

    @Test func legacyAdaptersKeepOptionalFieldsAbsentAndUnregisterRejectsLateMetadata() async throws {
        let service = RemoteReadService(serverId: "server-real"), store = RemoteAccessStore()
        await store.setDevelopmentEnabled(true)
        try await service.register(RemoteReadServiceTests.Adapter())
        let owner = try await store.issueDevelopment(scopes: [.init(agentId:"agent.chatgpt",runtimeId:"runtime_test",sessionId:nil,actions:[.readHistory])],origin:nil).principal
        let value = try await service.metadata(principal:owner,agentId:"agent.chatgpt",runtimeId:"runtime_test",sessionId:"ss_1")
        #expect(value.title == "Title 1")
        #expect(value.model == nil && value.workspaceName == nil)
        let gate = RemoteReadServiceTests.Gate()
        await service.unregister(agentId:"agent.chatgpt",runtimeId:"runtime_test")
        try await service.register(RemoteReadServiceTests.SuspendedAdapter(gate:gate))
        let task = Task {try await service.metadata(principal:owner,agentId:"agent.chatgpt",runtimeId:"runtime_test",sessionId:"ss_1")}
        for await _ in gate.entered {break}
        await service.unregister(agentId:"agent.chatgpt",runtimeId:"runtime_test")
        await gate.release()
        await #expect(throws: RemoteReadError.unavailable) { try await task.value }
    }
}
