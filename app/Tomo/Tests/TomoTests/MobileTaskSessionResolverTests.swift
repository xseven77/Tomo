import Foundation
import SQLite3
import Testing
@testable import Tomo

struct MobileTaskSessionResolverTests {
    @Test func referencesUseRegisteredRuntimeAndExactDatabaseProvenance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("state_5.sqlite")
        var connection: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &connection) == SQLITE_OK)
        let database = try #require(connection)
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, title TEXT, updated_at INTEGER, archived INTEGER, thread_source TEXT)", nil, nil, nil) == SQLITE_OK)
        for (id, archived, source) in [("thread-a", 0, "user"), ("archive", 1, "user"), ("child", 0, "subagent")] {
            let path = root.appendingPathComponent(id + ".jsonl").path.replacingOccurrences(of: "'", with: "''")
            #expect(sqlite3_exec(database, "INSERT INTO threads VALUES ('\(id)', '\(path)', 'Title', 1, \(archived), '\(source)')", nil, nil, nil) == SQLITE_OK)
        }
        let directory = ChatGPTSessionDirectory(databaseURL: databaseURL, storageRoot: root, runtimeId: "rt_registered")
        func task(_ id: String, source: URL?) -> CodexTaskActivity {
            .init(id: id, state: .thinking, detail: "", title: "Title", updatedAt: Date(), sessionSourceDatabaseURL: source)
        }
        let valid = task("thread-a", source: databaseURL)
        let otherAccount = task("thread-a", source: root.appendingPathComponent("other.sqlite"))
        let hookWithoutProvenance = task("thread-a", source: nil)
        let tasks = [valid, otherAccount, hookWithoutProvenance, task("missing", source: databaseURL),
                     task("archive", source: databaseURL), task("child", source: databaseURL)]
        let result = try MobileTaskSessionResolver.resolve(tasks: tasks, directory: directory, serverId: "srv_actual")
        let key = try #require(MobileTaskSessionResolver.key(valid))
        let reference = try #require(result[key])
        let entry = try #require(directory.snapshot().entries.first { $0.vendorSessionId == valid.id })
        #expect(result.count == 1)
        #expect(reference == .init(serverId: "srv_actual", agentId: "agent.chatgpt", runtimeId: "rt_registered", sessionId: entry.sessionId))
        #expect(reference.sessionId != valid.id)
        #expect(result[try #require(MobileTaskSessionResolver.key(otherAccount))] == nil)
        #expect(MobileTaskSessionResolver.key(hookWithoutProvenance) == nil)
        let otherRuntime = ChatGPTSessionDirectory(databaseURL: databaseURL, storageRoot: root, runtimeId: "rt_other")
        let other = try MobileTaskSessionResolver.resolve(tasks: [valid], directory: otherRuntime, serverId: "srv_actual")
        #expect(other[key]?.sessionId != reference.sessionId)
        let production = try MobileTaskSessionResolver.resolve(tasks: tasks,
            source: .init(id: "production", serverId: "real-cloud-server", directories: [directory]))
        #expect(production[key]?.serverId == "real-cloud-server")
        #expect(production[key]?.runtimeId == "rt_registered")
        #expect(production[key]?.sessionId == reference.sessionId)
        let ambiguous = try MobileTaskSessionResolver.resolve(tasks: tasks,
            source: .init(id: "production", serverId: "real-cloud-server", directories: [directory, otherRuntime]))
        #expect(ambiguous.isEmpty)
    }

    @Test func snapshotReferenceIsOptionalAndDoesNotExposeSourceLocator() throws {
        let decoder = JSONDecoder()
        let legacy = Data(#"{"id":"task","state":"thinking","title":"Title","agent":"ChatGPT"}"#.utf8)
        #expect(try decoder.decode(MobileTaskPayload.self, from: legacy).sessionRef == nil)
        let payload = MobileTaskPayload(id: "thread-a", state: "thinking", title: "Title", agent: "ChatGPT",
                                       sessionRef: .init(serverId: "srv_actual", agentId: "agent.chatgpt", runtimeId: "rt_registered", sessionId: "ss_opaque"))
        let data = try JSONEncoder().encode(payload)
        #expect(try decoder.decode(MobileTaskPayload.self, from: data) == payload)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let reference = try #require(object["sessionRef"] as? [String: String])
        #expect(Set(reference.keys) == ["serverId", "agentId", "runtimeId", "sessionId"])
        #expect(object["sessionSourceDatabaseURL"] == nil)
    }
}
