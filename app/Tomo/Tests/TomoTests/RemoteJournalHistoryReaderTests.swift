import Foundation
import SQLite3
import Testing
@testable import Tomo

struct RemoteJournalHistoryReaderTests {
    private let ref = RemoteSessionRef(serverId: "history-server", agentId: "agent.chatgpt", runtimeId: "rt_phone_history", sessionId: "history-session")
    private func message(_ n: Int, revision: Int = 1, text: String? = nil, status: String = "completed") -> RemoteHistoryMessage {
        .init(messageId: "message-\(n)", turnId: n >= 120 ? "turn-active" : "turn-\(n)", messageRevision: revision, role: "assistant",
            createdAt: "2026-10-16T00:00:00Z", status: status, content: [.init(partId: "text", type: "text", text: text ?? "Message \(n)")])
    }
    private func projection() -> RemoteSessionProjection {
        .init(control: .init(executionEpoch: "executor", controlRevision: 1, state: "running", controlMode: "readOnly",
            currentTurnId: "turn-active", allowedActions: ["history.read"]), messages: (1...120).map {message($0, status: $0 == 120 ? "streaming" : "completed")},
            pendingRequests: [], olderHistoryCursor: nil, hasOlder: false)
    }
    private func principal() -> RemoteAccessStore.Principal {
        .init(id: UUID(), expiresAt: Date().addingTimeInterval(1000), scopes: [.init(agentId: ref.agentId,
            runtimeId: ref.runtimeId, sessionId: ref.sessionId, actions: [.listSessions, .readHistory])], origin: nil, generation: 1)
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("journal-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    @Test func frozenPagesSurviveNewMessagesAndStreamingRevisions() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let journal = try RemoteSessionJournal(databaseURL: root.appendingPathComponent("journal.sqlite"))
        let original = try await journal.replace(ref: ref, projection: projection())
        let reader = RemoteJournalHistoryReader(journal: journal, ref: ref), owner = principal()
        _ = try await journal.append(ref: ref, mutations: [.delta(messageId: "message-120", partId: "text", revision: 2, text: " updated"), .message(message(121))])
        let first = try await reader.page(principal: owner, captured: original)
        #expect(first.messages.first?.messageId == "message-71" && first.messages.last?.messageId == "message-120")
        #expect(first.messages.last?.content.first?.text == "Message 120")
        let second = try await reader.page(principal: owner, cursor: first.olderHistoryCursor)
        #expect(second.messages.first?.messageId == "message-21" && second.messages.last?.messageId == "message-70")
        let last = try await reader.page(principal: owner, cursor: second.olderHistoryCursor)
        #expect(last.messages.count == 20 && !last.hasOlder)
        #expect(Set((last.messages + second.messages + first.messages).map(\.messageId)).count == 120)
        let latest = try await reader.page(principal: owner)
        #expect(latest.messages.last?.messageId == "message-121")
        let retry = try await reader.page(principal: owner, cursor: first.olderHistoryCursor)
        #expect(retry.messages == second.messages && retry.olderHistoryCursor == second.olderHistoryCursor)
    }
    @Test func cursorOwnerEpochExpiryAndCacheBoundsAreEnforced() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let journal = try RemoteSessionJournal(databaseURL: root.appendingPathComponent("journal.sqlite"))
        _ = try await journal.replace(ref: ref, projection: projection())
        let reader = RemoteJournalHistoryReader(journal: journal, ref: ref, maximumSnapshots: 1), owner = principal()
        let first = try await reader.page(principal: owner)
        await #expect(throws: RemoteReadError.self) {try await reader.page(principal: principal(), cursor: first.olderHistoryCursor)}
        #expect(try await reader.page(principal: owner, cursor: first.olderHistoryCursor, now: Date().addingTimeInterval(301)).messages.first?.messageId == "message-21")
        let second = try await reader.page(principal: owner)
        _ = try await journal.append(ref: ref, mutation: .message(message(121)))
        _ = try await reader.page(principal: owner)
        #expect(try await reader.page(principal: owner, cursor: second.olderHistoryCursor).messages.first?.messageId == "message-21")
        let third = try await reader.page(principal: owner)
        _ = try await journal.replace(ref: ref, projection: projection())
        await #expect(throws: RolloutHistoryError.self) {try await reader.page(principal: owner, cursor: third.olderHistoryCursor)}
    }
    @Test func expiredSnapshotsResumeAtTheSameBoundaryWithoutLosingAuthorizationOrRetryStability() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let journal = try RemoteSessionJournal(databaseURL: root.appendingPathComponent("journal.sqlite"))
        _ = try await journal.replace(ref: ref, projection: projection())
        let reader = RemoteJournalHistoryReader(journal: journal, ref: ref), owner = principal(), now = Date()
        let first = try await reader.page(principal: owner, now: now)
        let cursor = try #require(first.olderHistoryCursor)
        _ = try await journal.append(ref: ref, mutation: .message(message(121)))
        let later = now.addingTimeInterval(301)
        let recovered = try await reader.page(principal: owner, cursor: cursor, now: later)
        #expect(recovered.messages.map(\.messageId) == (21...70).map {"message-\($0)"})
        _ = try await journal.append(ref: ref, mutation: .message(message(21, revision: 2, text: "revised after recovery")))
        let retry = try await reader.page(principal: owner, cursor: cursor, now: later.addingTimeInterval(1))
        #expect(retry.messages == recovered.messages && retry.olderHistoryCursor == recovered.olderHistoryCursor)
        let oldest = try await reader.page(principal: owner, cursor: recovered.olderHistoryCursor, now: later.addingTimeInterval(2))
        #expect(oldest.messages.map(\.messageId) == (1...20).map {"message-\($0)"} && !oldest.hasOlder)
        await #expect(throws: RemoteReadError.self) {try await reader.page(principal: principal(), cursor: cursor, now: later)}
        let expired = RemoteAccessStore.Principal(id: owner.id, expiresAt: now.addingTimeInterval(300), scopes: owner.scopes,
            origin: owner.origin, generation: owner.generation, pagingOwner: owner.pagingOwner)
        await #expect(throws: RemoteAccessError.self) {try await reader.page(principal: expired, cursor: cursor, now: later)}
        _ = try await journal.replace(ref: ref, projection: projection())
        await #expect(throws: RolloutHistoryError.snapshotChanged) {try await reader.page(principal: owner, cursor: cursor, now: later)}
    }
    @Test func liveSyncAndHistoryUseOneAtomicOwnerBoundPage() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let url = root.appendingPathComponent("journal.sqlite"), journal = try RemoteSessionJournal(databaseURL: url)
        _ = try await journal.replace(ref: ref, projection: projection())
        let service = RemoteSessionService(serverId: ref.serverId)
        _ = try await service.register(ref: ref, journal: journal)
        let reads = RemoteReadService(serverId: ref.serverId, sessionService: service)
        let base = ChatGPTReadAdapter(directory: .init(databaseURL: root.appendingPathComponent("unused.sqlite"), storageRoot: root,
            runtimeId: ref.runtimeId), runtimeLabel: "Synthetic history")
        // Production's runtime and reader have distinct actors on the same DB.
        try await reads.register(ChatGPTJournalReadAdapter(base: base, journal: RemoteSessionJournal(databaseURL: url), ref: ref, title: "Synthetic"))
        let owner = principal()
        let bytes = try await service.sync(sessionId: ref.sessionId, query: ["agent_id": ref.agentId, "runtime_id": ref.runtimeId], principal: owner)
        let wire = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect((wire["messages"] as? [[String: Any]])?.count == 50 && wire["hasOlder"] as? Bool == true)
        let cursor = try #require(wire["olderHistoryCursor"] as? String)
        _ = try await journal.append(ref: ref, mutation: .message(message(121)))
        let older = try await reads.history(principal: owner, agentId: ref.agentId, runtimeId: ref.runtimeId, sessionId: ref.sessionId, cursor: cursor)
        #expect(older.messages.first?.messageId == "message-21" && older.messages.last?.messageId == "message-70")
        await #expect(throws: RemoteAccessError.self) {
            try await reads.history(principal: owner, agentId: ref.agentId, runtimeId: ref.runtimeId, sessionId: "another-session", cursor: cursor)
        }
    }
    @Test func actualHTTPPagingKeepsTheSyncBoundaryAndRejectsAnotherOwner() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let server = MobileSyncServer(port: 0, token: "synthetic-history-pair", listenOnLoopbackOnly: true,
            dataProvider: MobileSyncServerTests.MockDataProvider())
        defer {server.stop()}
        // Bind atomically rather than probing/releasing an ephemeral port that
        // concurrent HTTP clients can claim while the fixture is populated.
        try server.start()
        let readyBy = ContinuousClock.now.advanced(by: .seconds(3))
        while server.status != .ready, ContinuousClock.now < readyBy {try await Task.sleep(for: .milliseconds(10))}
        let port = try #require(server.listeningPort)
        let httpRef = RemoteSessionRef(serverId: await server.remoteSessionService.serverId, agentId: ref.agentId, runtimeId: ref.runtimeId, sessionId: ref.sessionId)
        let journal = try RemoteSessionJournal(databaseURL: root.appendingPathComponent("journal.sqlite"))
        _ = try await journal.replace(ref: httpRef, projection: projection())
        _ = try await server.remoteSessionService.register(ref: httpRef, journal: journal)
        let base = ChatGPTReadAdapter(directory: .init(databaseURL: root.appendingPathComponent("unused.sqlite"), storageRoot: root,
            runtimeId: ref.runtimeId), runtimeLabel: "Synthetic HTTP history")
        try await server.remoteReadService.register(ChatGPTJournalReadAdapter(base: base, journal: journal, ref: httpRef, title: "Synthetic"))
        await server.remoteAccess.setDevelopmentEnabled(true)
        let scope = RemoteAccessStore.Scope(agentId: ref.agentId, runtimeId: ref.runtimeId, sessionId: ref.sessionId, actions: [.listSessions, .readHistory])
        let token = try await server.remoteAccess.issueDevelopment(scopes: [scope], origin: nil)
        let client = URLSession(configuration: .ephemeral); defer {client.invalidateAndCancel()}
        func request(_ suffix: String, cursor: String? = nil, bearer: String? = nil, expected: Int = 200) async throws -> [String: Any] {
            var url = URLComponents(string: "http://127.0.0.1:\(port)/api/v1/remote/sessions/\(ref.sessionId)/\(suffix)")!
            url.queryItems = [.init(name: "agent_id", value: ref.agentId), .init(name: "runtime_id", value: ref.runtimeId)]
            if let cursor {url.queryItems!.append(.init(name: "history_cursor", value: cursor))}
            var request = URLRequest(url: url.url!); request.timeoutInterval = 5
            request.setValue("Bearer " + (bearer ?? token.token), forHTTPHeaderField: "Authorization")
            let (data, response) = try await client.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == expected)
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let sync = try await request("sync"), cursor = try #require(sync["olderHistoryCursor"] as? String)
        #expect((sync["messages"] as? [[String: Any]])?.count == 50)
        _ = try await journal.append(ref: httpRef, mutation: .message(message(121)))
        // Expire only this synthetic database's snapshot; exercise the actual
        // HTTP route without sleeping for five minutes or changing any ACL.
        var db: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("journal.sqlite").path, &db) == SQLITE_OK)
        let connection = try #require(db); defer {sqlite3_close(connection)}
        #expect(sqlite3_exec(connection, "UPDATE remote_message_snapshots SET expires=0", nil, nil, nil) == SQLITE_OK)
        let page = try await request("messages", cursor: cursor)
        let messages = try #require(page["messages"] as? [[String: Any]])
        #expect(messages.first?["messageId"] as? String == "message-21" && messages.last?["messageId"] as? String == "message-70")
        let other = try await server.remoteAccess.issueDevelopment(scopes: [scope], origin: nil)
        _ = try await request("messages", cursor: cursor, bearer: other.token, expected: 409)
    }
    @Test func staleUnregisterCannotRemoveReinstalledReader() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let journal = try RemoteSessionJournal(databaseURL: root.appendingPathComponent("journal.sqlite"))
        _ = try await journal.replace(ref: ref, projection: projection())
        let service = RemoteSessionService(serverId: ref.serverId), reader = RemoteJournalHistoryReader(journal: journal, ref: ref)
        _ = try await service.register(ref: ref, journal: journal)
        let old = UUID(), replacement = UUID()
        try await service.installHistoryReader(reader, lease: old)
        try await service.installHistoryReader(reader, lease: replacement)
        await service.removeHistoryReader(reader, lease: old)
        let bytes = try await service.sync(sessionId: ref.sessionId, query: ["agent_id": ref.agentId, "runtime_id": ref.runtimeId], principal: principal())
        let result = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect((result["messages"] as? [[String: Any]])?.count == 50 && result["hasOlder"] as? Bool == true)
    }
    @Test func syncRetainsAnActiveTurnLongerThanTheUsualPage() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let journal = try RemoteSessionJournal(databaseURL: root.appendingPathComponent("journal.sqlite"))
        var full = projection()
        full.messages = full.messages.enumerated().map {index, value in
            guard index >= 40 else {return value}
            return .init(messageId: value.messageId, turnId: "turn-active", messageRevision: 1, role: value.role,
                createdAt: value.createdAt, status: "streaming", content: value.content)
        }
        _ = try await journal.replace(ref: ref, projection: full)
        let service = RemoteSessionService(serverId: ref.serverId), reader = RemoteJournalHistoryReader(journal: journal, ref: ref), owner = principal()
        _ = try await service.register(ref: ref, journal: journal); try await service.installHistoryReader(reader, lease: UUID())
        let bytes = try await service.sync(sessionId: ref.sessionId, query: ["agent_id": ref.agentId, "runtime_id": ref.runtimeId], principal: owner)
        let result = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let messages = try #require(result["messages"] as? [[String: Any]])
        #expect(messages.count == 80 && messages.first?["messageId"] as? String == "message-41")
        _ = try await journal.append(ref: ref, mutation: .delta(messageId: "message-60", partId: "text", revision: 2, text: " continued"))
        let older = try await reader.page(principal: owner, cursor: result["olderHistoryCursor"] as? String)
        #expect(older.messages.count == 40 && older.messages.last?.messageId == "message-40" && !older.hasOlder)
    }
    @Test func credentialRenewalKeepsPagesButChangedDevicePolicyCannotReuseThem() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let journal = try RemoteSessionJournal(databaseURL: root.appendingPathComponent("journal.sqlite"))
        _ = try await journal.replace(ref: ref, projection: projection())
        let reader = RemoteJournalHistoryReader(journal: journal, ref: ref), now = Date()
        let scopes: [RemoteAccessStore.Scope] = [.init(agentId: ref.agentId, runtimeId: ref.runtimeId,
            sessionId: ref.sessionId, actions: [.listSessions, .readHistory])]
        func access(device: String = "same-device", key: String = "same-key", version: Int = 1,
                    permissions: [RemoteAccessStore.Scope]? = nil, expires: Date? = nil) -> RemoteAccessStore.Principal {
            let permissions = permissions ?? scopes
            return .init(id: UUID(), expiresAt: expires ?? now.addingTimeInterval(1000), scopes: permissions, origin: nil, generation: 0,
                pagingOwner: .device(server: ref.serverId, user: "same-user", device: device, binding: "same-binding",
                    bindingRevision: 1, localVersion: version, key: key, scopes: Set(permissions)))
        }
        let initial = access(expires: now.addingTimeInterval(10))
        let page = try await reader.page(principal: initial, now: now)
        let renewed = access()
        #expect(initial.id != renewed.id && initial.pagingOwner == renewed.pagingOwner)
        let older = try await reader.page(principal: renewed, cursor: page.olderHistoryCursor, now: now.addingTimeInterval(11))
        #expect(older.messages.first?.messageId == "message-21")
        await #expect(throws: RemoteAccessError.self) {
            try await reader.page(principal: initial, cursor: page.olderHistoryCursor, now: now.addingTimeInterval(11))
        }
        let narrower: [RemoteAccessStore.Scope] = [.init(agentId: ref.agentId, runtimeId: ref.runtimeId, sessionId: ref.sessionId, actions: [.readHistory])]
        for different in [access(device: "other-device"), access(key: "other-key"), access(version: 2), access(permissions: narrower)] {
            await #expect(throws: RemoteReadError.self) {try await reader.page(principal: different, cursor: page.olderHistoryCursor)}
        }
    }
}
