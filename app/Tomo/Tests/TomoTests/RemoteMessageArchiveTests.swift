import Foundation
import SQLite3
import Testing
@testable import Tomo

struct RemoteMessageArchiveTests {
    private let ref = RemoteSessionRef(serverId: "archive-server", agentId: "agent.chatgpt", runtimeId: "archive-runtime", sessionId: "archive-session")
    private func message(_ n: Int, revision: Int = 1, text: String? = nil, turn: String? = nil, streaming: Bool = false) -> RemoteHistoryMessage {
        .init(messageId: "message-\(n)", turnId: turn ?? "turn-\(n)", messageRevision: revision, role: n.isMultiple(of: 2) ? "assistant" : "user",
            createdAt: "2026-10-16T00:00:00Z", status: streaming ? "streaming" : "completed",
            content: [.init(partId: "text", type: "text", text: text ?? "Synthetic \(n)")])
    }
    private func projection(_ messages: [RemoteHistoryMessage], active: String? = nil) -> RemoteSessionProjection {
        .init(control: .init(executionEpoch: "executor", controlRevision: 1, state: active == nil ? "completed" : "running",
            controlMode: "readOnly", currentTurnId: active, allowedActions: ["history.read"]),
            messages: messages, pendingRequests: [], olderHistoryCursor: nil, hasOlder: false)
    }
    private func location() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("archive-" + UUID().uuidString).appendingPathComponent("journal.sqlite") }
    private func principal() -> RemoteAccessStore.Principal {
        .init(id: UUID(), expiresAt: Date().addingTimeInterval(3000), scopes: [.init(agentId: ref.agentId,
            runtimeId: ref.runtimeId, sessionId: ref.sessionId, actions: [.readHistory])], origin: nil, generation: 1)
    }

    @Test func thousandsOfMessagesPersistWithoutGrowingLiveProjectionAndFrozenPagesSurviveChanges() async throws {
        let url = location(); defer {try? FileManager.default.removeItem(at: url.deletingLastPathComponent())}
        let journal = try RemoteSessionJournal(databaseURL: url)
        let initial = try await journal.replace(ref: ref, projection: projection((1...1500).map {message($0)}))
        #expect(initial.projection.messages.count == 200 && initial.projection.messages.first?.messageId == "message-1301")
        #expect(try JSONEncoder().encode(initial).count < 100_000)
        let reader = RemoteJournalHistoryReader(journal: journal, ref: ref), owner = principal()
        let first = try await reader.page(principal: owner, limit: 100, captured: initial)
        for start in stride(from: 1501, through: 2500, by: 200) {
            _ = try await journal.append(ref: ref, mutations: (start...min(start + 199, 2500)).map {.message(message($0))})
        }
        // Revise a row that has left the live window; it must not be appended
        // at the end or alter the already captured history.
        _ = try await journal.append(ref: ref, mutation: .message(message(50, revision: 2, text: "New full revision")))
        let head = try await journal.snapshot(ref: ref)
        #expect(head.projection.messages.count == 200 && head.projection.messages.first?.messageId == "message-2301")
        #expect(head.projection.messages.last?.messageId == "message-2500")
        #expect(try await journal.append(ref: ref, mutation: .message(message(50, revision: 2, text: "New full revision"))) == nil)
        await #expect(throws: RemoteJournalError.revisionConflict) {try await journal.append(ref: ref, mutation: .message(message(50)))}
        #expect(try await journal.snapshot(ref: ref).sequence == head.sequence)

        var all = first.messages, cursor = first.olderHistoryCursor, pages = 1
        while let current = cursor {
            let page = try await reader.page(principal: owner, cursor: current, limit: 100)
            all = page.messages + all; cursor = page.olderHistoryCursor; pages += 1
            #expect(pages <= 15)
        }
        #expect(pages == 15 && all.map(\.messageId) == (1...1500).map {"message-\($0)"})
        #expect(all[49].content.first?.text == "Synthetic 50")
        let restarted = try RemoteSessionJournal(databaseURL: url)
        let fresh = try await restarted.historySnapshot(ref: ref)
        #expect(fresh.count == 2500)
        let revised = try await restarted.historyWindow(ref: ref, snapshot: fresh, before: 50, limit: 1, maximumBytes: 8 * 1024 * 1024)
        #expect(revised.messages.first?.content.first?.text == "New full revision")
        let persisted = try await restarted.snapshot(ref: ref)
        #expect(persisted.sequence == head.sequence && persisted.eventCursor == head.eventCursor)
        #expect(persisted.projection.messages == head.projection.messages)
        // Archive/head/replay updates roll back as one transaction.
        await #expect(throws: RemoteJournalError.revisionConflict) {
            try await restarted.append(ref: ref, mutations: [.message(message(2501)), .message(message(50))])
        }
        #expect(try await restarted.historySnapshot(ref: ref).count == 2500)
        #expect(try await restarted.snapshot(ref: ref).sequence == head.sequence)
    }

    @Test func activeTurnRemainsCompleteEvenWhenOlderHistoryIsArchived() async throws {
        let url = location(); defer {try? FileManager.default.removeItem(at: url.deletingLastPathComponent())}
        let journal = try RemoteSessionJournal(databaseURL: url)
        let old = (1...1200).map {message($0)}
        let active = (1201...1500).map {message($0, turn: "active", streaming: true)}
        _ = try await journal.replace(ref: ref, projection: projection(old + active, active: "active"))
        let snapshot = try await journal.snapshot(ref: ref, includeHistorySnapshot: true)
        #expect(snapshot.projection.messages.count == 300)
        let reader = RemoteJournalHistoryReader(journal: journal, ref: ref), owner = principal()
        let live = try await reader.page(principal: owner, captured: snapshot, retainingTurn: "active")
        #expect(live.messages == active && live.hasOlder)
        _ = try await journal.append(ref: ref, mutation: .delta(messageId: "message-1210", partId: "text", revision: 2, text: " continued"))
        let fresh = try await journal.snapshot(ref: ref)
        #expect(fresh.projection.messages[9].messageRevision == 2)
        let older = try await reader.page(principal: owner, cursor: live.olderHistoryCursor)
        #expect(older.messages.first?.messageId == "message-1151" && older.messages.last?.messageId == "message-1200")
    }

    @Test func byteLimitedPagesMakeProgressWithoutSkippingMessages() async throws {
        let url = location(); defer {try? FileManager.default.removeItem(at: url.deletingLastPathComponent())}
        let journal = try RemoteSessionJournal(databaseURL: url)
        let messages = (1...5).map {message($0, text: String(repeating: "x", count: 800))}
        _ = try await journal.replace(ref: ref, projection: projection(messages))
        let reader = RemoteJournalHistoryReader(journal: journal, ref: ref, maximumBytes: 1300), owner = principal()
        var cursor: String?, all: [RemoteHistoryMessage] = [], pages = 0
        repeat {
            let page = try await reader.page(principal: owner, cursor: cursor)
            #expect(page.messages.count == 1)
            all = page.messages + all; cursor = page.olderHistoryCursor; pages += 1
            #expect(pages <= 5)
        } while cursor != nil
        #expect(all == messages && pages == 5)
    }

    @Test func boundedCursorMetadataDoesNotStopAConversationAfter128Pages() async throws {
        let url = location(); defer {try? FileManager.default.removeItem(at: url.deletingLastPathComponent())}
        let journal = try RemoteSessionJournal(databaseURL: url)
        _ = try await journal.replace(ref: ref, projection: projection((1...7000).map {message($0)}))
        let reader = RemoteJournalHistoryReader(journal: journal, ref: ref), owner = principal()
        let first = try await reader.page(principal: owner)
        var cursor = first.olderHistoryCursor, messages = first.messages, lastCursor: String?, last: [RemoteHistoryMessage] = [], pages = 1
        while let current = cursor {
            let page = try await reader.page(principal: owner, cursor: current)
            messages = page.messages + messages; cursor = page.olderHistoryCursor
            lastCursor = current; last = page.messages; pages += 1
            #expect(pages <= 140)
        }
        #expect(pages == 140 && messages.map(\.messageId) == (1...7000).map {"message-\($0)"})
        let retry = try await reader.page(principal: owner, cursor: lastCursor)
        #expect(retry.messages == last && !retry.hasOlder)
        await #expect(throws: RemoteReadError.cursorExpired) {try await reader.page(principal: owner, cursor: first.olderHistoryCursor)}
    }

    @Test func streamingStoresOneOldVersionPerSnapshotAndCopyBytesAreBounded() async throws {
        let url = location(); defer {try? FileManager.default.removeItem(at: url.deletingLastPathComponent())}
        let journal = try RemoteSessionJournal(databaseURL: url)
        _ = try await journal.replace(ref: ref, projection: projection([message(1, text: "Initial", turn: "active", streaming: true)], active: "active"))
        let original = try await journal.historySnapshot(ref: ref)
        for revision in 2...41 {
            _ = try await journal.append(ref: ref, mutation: .delta(messageId: "message-1", partId: "text", revision: revision, text: " more"))
        }
        #expect(try integers(url, "SELECT COUNT(*) FROM remote_message_versions") == [1])
        let frozen = try await journal.historyWindow(ref: ref, snapshot: original, before: nil, limit: 1, maximumBytes: 1024)
        #expect(frozen.messages.first?.content.first?.text == "Initial")
        await #expect(throws: RolloutHistoryError.snapshotChanged) {
            try await journal.historyWindow(ref: ref, snapshot: original, before: nil, limit: 1, maximumBytes: 1024, now: original.expires.addingTimeInterval(1))
        }
        for index in 2...6 {
            _ = try await journal.append(ref: ref, mutation: .message(message(index)))
            _ = try await journal.historySnapshot(ref: ref)
        }
        #expect(try integers(url, "SELECT COUNT(*) FROM remote_message_snapshots") == [4])
        await #expect(throws: RolloutHistoryError.snapshotChanged) {
            try await journal.historyWindow(ref: ref, snapshot: original, before: nil, limit: 1, maximumBytes: 1024)
        }
        let full = projection((1...8).map {message($0, text: String(repeating: "a", count: 700_000))})
        _ = try await journal.replace(ref: ref, projection: full)
        let first = try await journal.historySnapshot(ref: ref)
        _ = try await journal.append(ref: ref, mutations: (1...8).map {.message(message($0, revision: 2, text: String(repeating: "b", count: 700_000)))})
        let second = try await journal.historySnapshot(ref: ref)
        _ = try await journal.append(ref: ref, mutations: (1...8).map {.message(message($0, revision: 3, text: String(repeating: "c", count: 700_000)))})
        #expect(try integers(url, "SELECT COALESCE(SUM(length(content)),0) FROM remote_message_versions")[0] <= 8 * 1024 * 1024)
        await #expect(throws: RolloutHistoryError.snapshotChanged) {
            try await journal.historyWindow(ref: ref, snapshot: first, before: nil, limit: 8, maximumBytes: 8 * 1024 * 1024)
        }
        let stillFrozen = try await journal.historyWindow(ref: ref, snapshot: second, before: nil, limit: 8, maximumBytes: 8 * 1024 * 1024)
        #expect(stillFrozen.messages.count == 8 && stillFrozen.messages.allSatisfy {$0.messageRevision == 2})
    }

    @Test func versionOneMigrationPreservesMessagesReplayAndAtomicFailure() async throws {
        let url = location(); defer {try? FileManager.default.removeItem(at: url.deletingLastPathComponent())}
        let baseline = projection((1...350).map {message($0)})
        try legacy(url, projection: baseline)
        let migrated = try RemoteSessionJournal(databaseURL: url)
        #expect(try integers(url, "PRAGMA user_version") == [2])
        let state = try await migrated.snapshot(ref: ref)
        #expect(state.projection.messages.count == 200 && state.streamEpoch == "legacy-epoch" && state.eventCursor == "legacy-head")
        let replay = try await migrated.replay(ref: ref, after: "legacy-cursor")
        #expect(replay.count == 1 && replay.first?.event.sequence == 1 && replay.first?.cursor == "legacy-head")
        let frozen = try await migrated.historySnapshot(ref: ref)
        #expect(frozen.count == 350)
        let oldest = try await migrated.historyWindow(ref: ref, snapshot: frozen, before: 50, limit: 50, maximumBytes: 100_000)
        #expect(oldest.messages == Array(baseline.messages.prefix(50)))
        _ = try RemoteSessionJournal(databaseURL: url) // Migration is idempotent.
        #expect(try integers(url, "SELECT COUNT(*) FROM remote_messages") == [350])

        let invalidURL = location(); defer {try? FileManager.default.removeItem(at: invalidURL.deletingLastPathComponent())}
        let secret = RemoteHistoryMessage(messageId: "hidden", turnId: nil, messageRevision: 1, role: "system",
            createdAt: "2026-10-16T00:00:00Z", status: "completed", content: [])
        try legacy(invalidURL, projection: projection([secret]))
        #expect(throws: RemoteJournalError.invalidProjection) {try RemoteSessionJournal(databaseURL: invalidURL)}
        #expect(try integers(invalidURL, "PRAGMA user_version") == [1])
        #expect(try integers(invalidURL, "SELECT COUNT(*) FROM sqlite_master WHERE name='remote_messages'") == [0])
        #expect(try integers(invalidURL, "SELECT COUNT(*) FROM remote_session_streams") == [1])
    }

    private func database<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var pointer: OpaquePointer?
        guard sqlite3_open(url.path, &pointer) == SQLITE_OK, let db = pointer else {throw RemoteJournalError.unavailable}
        defer {sqlite3_close(db)}
        return try body(db)
    }
    private func integers(_ url: URL, _ sql: String) throws -> [Int] {
        try database(url) {db in
            var pointer: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &pointer, nil) == SQLITE_OK, let stmt = pointer else {throw RemoteJournalError.unavailable}
            defer {sqlite3_finalize(stmt)}
            guard sqlite3_step(stmt) == SQLITE_ROW else {throw RemoteJournalError.unavailable}
            return (0..<sqlite3_column_count(stmt)).map {Int(sqlite3_column_int64(stmt, $0))}
        }
    }
    private func legacy(_ url: URL, projection: RemoteSessionProjection) throws {
        try database(url) {db in
            guard sqlite3_exec(db, "CREATE TABLE remote_session_streams(ref TEXT PRIMARY KEY,state BLOB NOT NULL); CREATE TABLE remote_session_events(ref TEXT NOT NULL REFERENCES remote_session_streams(ref) ON DELETE CASCADE,sequence INTEGER NOT NULL,cursor TEXT NOT NULL UNIQUE,occurred REAL NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(ref,sequence)); PRAGMA user_version=1", nil, nil, nil) == SQLITE_OK else {throw RemoteJournalError.unavailable}
            let last = try #require(projection.messages.last)
            let projection = try JSONSerialization.jsonObject(with: JSONEncoder().encode(projection))
            let data = try JSONSerialization.data(withJSONObject: ["projection": projection, "epoch": "legacy-epoch", "sequence": 1, "cursor": "legacy-head"])
            let key = String(decoding: try JSONEncoder().encode([ref.serverId, ref.agentId, ref.runtimeId, ref.sessionId]), as: UTF8.self)
            var pointer: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO remote_session_streams VALUES(?,?)", -1, &pointer, nil) == SQLITE_OK, let stmt = pointer else {throw RemoteJournalError.unavailable}
            defer {sqlite3_finalize(stmt)}
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            guard sqlite3_bind_text(stmt, 1, key, -1, transient) == SQLITE_OK,
                  data.withUnsafeBytes({sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32(data.count), transient)}) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_DONE else {throw RemoteJournalError.unavailable}
            let payload = try JSONDecoder().decode(AgentJSON.self, from: JSONEncoder().encode(last))
            let event = RemoteJournalEvent(schemaVersion: 1, sessionId: ref.sessionId, streamEpoch: "legacy-epoch", sequence: 1,
                occurredAt: "2026-10-16T00:00:00Z", type: "message.completed", payload: payload)
            for sequence in 0...1 {
                var pointer: OpaquePointer?
                guard sqlite3_prepare_v2(db, "INSERT INTO remote_session_events VALUES(?,?,?,?,?)", -1, &pointer, nil) == SQLITE_OK, let stmt = pointer else {throw RemoteJournalError.unavailable}
                defer {sqlite3_finalize(stmt)}
                let data = sequence == 0 ? Data() : try JSONEncoder().encode(event)
                let cursor = sequence == 0 ? "legacy-cursor" : "legacy-head"
                guard sqlite3_bind_text(stmt, 1, key, -1, transient) == SQLITE_OK,
                      sqlite3_bind_int(stmt, 2, Int32(sequence)) == SQLITE_OK,
                      sqlite3_bind_text(stmt, 3, cursor, -1, transient) == SQLITE_OK,
                      sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970) == SQLITE_OK,
                      (data.isEmpty ? sqlite3_bind_zeroblob(stmt, 5, 0) : data.withUnsafeBytes {sqlite3_bind_blob(stmt, 5, $0.baseAddress, Int32(data.count), transient)}) == SQLITE_OK,
                      sqlite3_step(stmt) == SQLITE_DONE else {throw RemoteJournalError.unavailable}
            }
        }
    }
}
