import Foundation
import SQLite3
import Testing
@testable import Tomo

struct ChatGPTSessionDirectoryTests {
    private func fixture(_ body: (ChatGPTSessionDirectory, URL, OpaquePointer) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("state.sqlite")
        var db: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &db) == SQLITE_OK)
        let database = try #require(db)
        defer { sqlite3_close(database) }
        try execute(database, "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, title TEXT, updated_at INTEGER, archived INTEGER, thread_source TEXT)")
        try body(.init(databaseURL: databaseURL, storageRoot: root, runtimeId: "runtime-a"), root, database)
    }
    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ChatGPTDirectoryError.invalidRecord }
    }
    private func insert(_ db: OpaquePointer, root: URL, id: String, updated: Int, archived: Int = 0, source: String = "user") throws {
        let path = root.appendingPathComponent(id + ".jsonl").path.replacingOccurrences(of: "'", with: "''")
        try execute(db, "INSERT INTO threads VALUES ('\(id)', '\(path)', 'Title', \(updated), \(archived), '\(source)')")
    }

    @Test func directoryIncludesHistoryAndArchivesAndExcludesSubagents() throws {
        try fixture { directory, root, db in
            try insert(db, root: root, id: "older", updated: 1)
            try insert(db, root: root, id: "archive", updated: 2, archived: 1)
            try insert(db, root: root, id: "child", updated: 3, source: "subagent")
            try insert(db, root: root, id: "review", updated: 4, source: "guardian_review")
            let result = try directory.snapshot()
            #expect(result.entries.map(\.vendorSessionId) == ["archive", "older"])
            #expect(result.entries[0].archived)
            #expect(result.indexState == "ready")
            #expect(try directory.snapshot(maximumRows: 1).indexState == "partial")
        }
    }

    @Test func attachmentServesOnlyImagesTheSessionMentionedAndNothingElse() throws {
        try fixture { directory, root, db in
            try insert(db, root: root, id: "s", updated: 1)
            let png = root.appendingPathComponent("shot.png"), text = root.appendingPathComponent("notes.png")
            let big = root.appendingPathComponent("big.png"), gone = root.appendingPathComponent("gone.png")
            try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0]).write(to: png)
            try Data("not an image".utf8).write(to: text)
            try (Data([0x89, 0x50, 0x4E, 0x47]) + Data(count: ChatGPTReadAdapter.attachmentLimit)).write(to: big)
            let secret = root.appendingPathComponent("secret.png")
            try Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0]).write(to: secret)
            let line = "{\"text\":\"## shot.png: \(png.path)\\n<image name=[Image #1] path=\\\"\(text.path)\\\"> \(big.path) \(gone.path) prefix\(secret.path)x\"}"
            try Data(line.utf8).write(to: root.appendingPathComponent("s.jsonl"))
            let adapter = ChatGPTReadAdapter(directory: directory, runtimeLabel: "t")
            let id = try #require(try directory.snapshot().entries.first?.sessionId)
            let ok = try adapter.attachment(sessionId: id, path: png.path)
            #expect(ok.mime == "image/png")
            #expect(throws: RemoteReadError.attachmentUnsupported) { try adapter.attachment(sessionId: id, path: text.path) }
            #expect(throws: RemoteReadError.attachmentTooLarge) { try adapter.attachment(sessionId: id, path: big.path) }
            #expect(throws: RemoteReadError.attachmentGone) { try adapter.attachment(sessionId: id, path: gone.path) }
            // Never mentioned as a whole path, even though it is a real image: refused.
            #expect(throws: RemoteReadError.notFound) { try adapter.attachment(sessionId: id, path: secret.path) }
            #expect(throws: RemoteReadError.notFound) { try adapter.attachment(sessionId: id, path: root.appendingPathComponent("other.png").path) }
            #expect(throws: RemoteReadError.invalidRequest) { try adapter.attachment(sessionId: id, path: "relative.png") }
            #expect(throws: RemoteReadError.invalidRequest) { try adapter.attachment(sessionId: id, path: root.path + "/../x.png") }
        }
    }
    @Test func stableOrderingAndRuntimeIdentityDoNotCollideAcrossAccounts() throws {
        try fixture { directory, root, db in
            try insert(db, root: root, id: "a", updated: 2)
            try insert(db, root: root, id: "b", updated: 2)
            let first = try directory.snapshot()
            #expect(first.entries.map(\.vendorSessionId) == ["b", "a"])
            #expect(try directory.snapshot().entries == first.entries)
            let other = ChatGPTSessionDirectory(databaseURL: directory.databaseURL, storageRoot: root, runtimeId: "runtime-b")
            #expect(try other.snapshot().entries[0].sessionId != first.entries[0].sessionId)
        }
    }
    @Test func locatorsRejectSiblingPrefixesAndEscapingSymlinks() throws {
        try fixture { directory, root, db in
            try insert(db, root: root, id: "a", updated: 1)
            let entry = try #require(directory.snapshot().entries.first)
            try Data("test".utf8).write(to: entry.rolloutURL)
            #expect(try Data(contentsOf: directory.historyURL(for: entry)) == Data("test".utf8))
            let outside = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-other.jsonl")
            try Data().write(to: outside)
            defer { try? FileManager.default.removeItem(at: outside) }
            try FileManager.default.removeItem(at: entry.rolloutURL)
            try FileManager.default.createSymbolicLink(at: entry.rolloutURL, withDestinationURL: outside)
            #expect(throws: ChatGPTDirectoryError.outsideStorageRoot) { try directory.historyURL(for: entry) }
            #expect(throws: ChatGPTDirectoryError.outsideStorageRoot) { try directory.readHistory(for: entry) }
        }
    }
    @Test func directoryEntryReadsAttributedHistoryThroughPinnedDescriptor() throws {
        try fixture { directory, root, db in
            try insert(db, root: root, id: "a", updated: 1)
            let entry = try #require(directory.snapshot().entries.first)
            let records: [[String: Any]] = [
                ["type": "session_meta", "payload": ["id": "a"]],
                ["type": "response_item", "timestamp": "2026-10-03T00:00:00Z", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "visible"]]]]
            ]
            var data = Data()
            for record in records { data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10) }
            try data.write(to: entry.rolloutURL)
            let window = try directory.readHistory(for: entry)
            #expect(window.messages.map { $0.content[0].text } == ["visible"])
        }
    }
    @Test func missingRolloutAndIncompatibleDatabaseAreNotEmptySuccesses() throws {
        try fixture { directory, root, db in
            try insert(db, root: root, id: "gone", updated: 1)
            let entry = try #require(directory.snapshot().entries.first)
            #expect(throws: ChatGPTDirectoryError.sessionGone) { try directory.historyURL(for: entry) }
            try execute(db, "DROP TABLE threads")
            try execute(db, "CREATE TABLE threads (id TEXT)")
            #expect(throws: ChatGPTDirectoryError.incompatibleSchema) { try directory.snapshot() }
        }
    }
    @Test func walDatabaseStaysReadableAfterOwnerQuitsWithoutCreatingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("state.sqlite")
        var db: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &db) == SQLITE_OK)
        let owner = try #require(db)
        try execute(owner, "PRAGMA journal_mode=WAL")
        try execute(owner, "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, title TEXT, updated_at INTEGER, archived INTEGER, thread_source TEXT)")
        try insert(owner, root: root, id: "a", updated: 1)
        sqlite3_close(owner)
        // Codex deletes its checkpointed -wal/-shm on exit; the system library keeps them.
        let sidecars = [databaseURL.path + "-wal", databaseURL.path + "-shm"]
        for path in sidecars { try? FileManager.default.removeItem(atPath: path) }
        let directory = ChatGPTSessionDirectory(databaseURL: databaseURL, storageRoot: root, runtimeId: "runtime-a")
        #expect(try directory.snapshot().entries.map(\.vendorSessionId) == ["a"])
        #expect(sidecars.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
    }
    @Test func liveWALOwnerRowsAreReadBeforeCheckpoint() throws {
        try fixture { directory, root, db in
            try execute(db, "PRAGMA journal_mode=WAL")
            try execute(db, "PRAGMA wal_autocheckpoint=0")
            try insert(db, root: root, id: "a", updated: 1)
            #expect(try directory.snapshot().entries.map(\.vendorSessionId) == ["a"])
        }
    }
}
