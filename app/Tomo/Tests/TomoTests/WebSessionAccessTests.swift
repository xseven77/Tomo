import Foundation
import Network
import SQLite3
import Testing
@testable import Tomo

/// A hand-moved clock, so a window's hour passes without waiting.
private final class WebTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    var date: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

private final class WebTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var prepared = 0, tornDown = 0
    var prepareCount: Int { lock.withLock { prepared } }
    var teardownCount: Int { lock.withLock { tornDown } }
    func didPrepare() { lock.withLock { prepared += 1 } }
    func didTeardown() { lock.withLock { tornDown += 1 } }
}

private struct WebSessionFixture {
    static let origin = "http://localhost:8081"
    let access = RemoteAccessStore()
    let clock = WebTestClock()
    let counter = WebTestCounter()
    let web: WebSessionAccess

    init(actions: Set<RemoteAction> = [.listSessions, .readHistory], prepareFails: Bool = false,
         limits: WebSessionAccess.Limits = .init()) {
        let counter = counter, clock = clock
        web = WebSessionAccess(access: access,
            scopes: { [.init(agentId: "agent.chatgpt", runtimeId: "rt_test", sessionId: nil, actions: actions)] },
            prepare: { counter.didPrepare(); if prepareFails { throw RemoteAccessError.unavailable } },
            teardown: { counter.didTeardown() },
            now: { clock.date }, limits: limits)
    }

    /// Request, approve and take the first credential, the way a page does.
    func connect(origin: String = WebSessionFixture.origin) async throws -> (credential: WebSessionAccess.Credential, renewal: String) {
        let pending = try await web.request(origin: origin)
        await web.decide(id: pending.id, allow: true)
        guard case .approved(let credential, let renewal) = try await web.poll(id: pending.id, origin: origin) else {
            throw WebSessionAccess.AccessError.unavailable
        }
        return (credential, renewal)
    }
    func authenticate(_ token: String, origin: String = WebSessionFixture.origin) async throws -> RemoteAccessStore.Principal {
        try await access.authenticate(authorization: "Bearer " + token, origin: origin)
    }
}

struct WebSessionAccessTests {
    @Test func aSwitchThatIsOffRefusesEveryRequest() async throws {
        let fixture = WebSessionFixture()
        await #expect(throws: WebSessionAccess.AccessError.disabled) { try await fixture.web.request(origin: WebSessionFixture.origin) }
    }

    @Test func onlyLoopbackHTTPPagesMayAsk() async throws {
        for allowed in ["http://localhost:8081", "http://127.0.0.1:5200", "http://localhost"] {
            #expect(WebSessionAccess.isAllowedOrigin(allowed), Comment(rawValue: allowed))
        }
        for refused in ["https://example.com", "https://localhost:8081", "http://192.168.1.5:8081", "http://localhost.evil.com",
                        "http://localhost:8081/path", "http://user@localhost:8081", "http://localhost:8081/", "null", ""] {
            #expect(!WebSessionAccess.isAllowedOrigin(refused), Comment(rawValue: refused))
        }
        let fixture = WebSessionFixture()
        await fixture.web.setEnabled(true)
        await #expect(throws: WebSessionAccess.AccessError.originNotAllowed) { try await fixture.web.request(origin: "https://example.com") }
    }

    @Test func askingAgainReturnsTheRequestTheOwnerIsLookingAt() async throws {
        let fixture = WebSessionFixture()
        await fixture.web.setEnabled(true)
        let first = try await fixture.web.request(origin: WebSessionFixture.origin)
        let second = try await fixture.web.request(origin: WebSessionFixture.origin)
        #expect(first == second)
        #expect(first.code.count == 4 && first.code.allSatisfy(\.isNumber))
        #expect(await fixture.web.pendingRequests() == [first])
    }

    @Test func approvalHandsOverAReadOnlyCredentialAndTheRenewalSecretOnce() async throws {
        let fixture = WebSessionFixture()
        await fixture.web.setEnabled(true)
        let pending = try await fixture.web.request(origin: WebSessionFixture.origin)
        let outcome1 = try await fixture.web.poll(id: pending.id, origin: WebSessionFixture.origin)
        #expect(outcome1 == .pending)
        await fixture.web.decide(id: pending.id, allow: true)
        guard case .approved(let credential, let renewal) = try await fixture.web.poll(id: pending.id, origin: WebSessionFixture.origin) else {
            Issue.record("expected an approved request"); return
        }
        #expect(!credential.controls)
        #expect(renewal.hasPrefix("tomo_web_renew_"))
        #expect(credential.expiresAt.timeIntervalSince(fixture.clock.date) <= 300)
        #expect(credential.windowExpiresAt.timeIntervalSince(fixture.clock.date) <= 3600)

        let principal = try await fixture.authenticate(credential.token)
        #expect(principal.permits(agentId: "agent.chatgpt", runtimeId: "rt_test", sessionId: "s", action: .readHistory))
        #expect(!principal.permits(agentId: "agent.chatgpt", runtimeId: "rt_test", sessionId: "s", action: .approve))
        #expect(!principal.permits(agentId: "agent.chatgpt", runtimeId: "rt_test", sessionId: "s", action: .answer))
        // Bound to the approved page: any other origin is refused.
        await #expect(throws: RemoteAccessError.forbidden) { try await fixture.authenticate(credential.token, origin: "http://localhost:9999") }
        // The secret is delivered once.
        await #expect(throws: WebSessionAccess.AccessError.notFound) { try await fixture.web.poll(id: pending.id, origin: WebSessionFixture.origin) }
        #expect(fixture.counter.prepareCount == 1)
    }

    @Test func aPageCannotCollectAnotherPagesAnswer() async throws {
        let fixture = WebSessionFixture()
        await fixture.web.setEnabled(true)
        let pending = try await fixture.web.request(origin: WebSessionFixture.origin)
        await fixture.web.decide(id: pending.id, allow: true)
        await #expect(throws: WebSessionAccess.AccessError.notFound) { try await fixture.web.poll(id: pending.id, origin: "http://localhost:9999") }
    }

    @Test func refusalGivesNothing() async throws {
        let fixture = WebSessionFixture()
        await fixture.web.setEnabled(true)
        let pending = try await fixture.web.request(origin: WebSessionFixture.origin)
        await fixture.web.decide(id: pending.id, allow: false)
        let outcome2 = try await fixture.web.poll(id: pending.id, origin: WebSessionFixture.origin)
        #expect(outcome2 == .denied)
        #expect(await fixture.web.activeWindows().isEmpty)
        #expect(fixture.counter.prepareCount == 0)
    }

    @Test func anUnansweredRequestLapses() async throws {
        let fixture = WebSessionFixture()
        await fixture.web.setEnabled(true)
        let pending = try await fixture.web.request(origin: WebSessionFixture.origin)
        fixture.clock.advance(121)
        let outcome3 = try await fixture.web.poll(id: pending.id, origin: WebSessionFixture.origin)
        #expect(outcome3 == .expired)
        await fixture.web.decide(id: pending.id, allow: true)
        #expect(await fixture.web.activeWindows().isEmpty, "a lapsed request cannot be approved late")
    }

    @Test func renewalNeedsTheSecretAndTheSameOrigin() async throws {
        let fixture = WebSessionFixture()
        await fixture.web.setEnabled(true)
        let (first, renewal) = try await fixture.connect()
        let next = try await fixture.web.renew(renewal: renewal, origin: WebSessionFixture.origin)
        #expect(next.token != first.token)
        _ = try await fixture.authenticate(next.token)
        await #expect(throws: WebSessionAccess.AccessError.unauthorized) {
            try await fixture.web.renew(renewal: "tomo_web_renew_wrong", origin: WebSessionFixture.origin)
        }
        await #expect(throws: WebSessionAccess.AccessError.unauthorized) {
            try await fixture.web.renew(renewal: renewal, origin: "http://localhost:9999")
        }
    }

    @Test func theWindowEndsAfterAnHourAndTakesItsCredentialsWithIt() async throws {
        let fixture = WebSessionFixture()
        await fixture.web.setEnabled(true)
        let (credential, renewal) = try await fixture.connect()
        fixture.clock.advance(3601)
        await fixture.web.tick()
        #expect(await fixture.web.activeWindows().isEmpty)
        await #expect(throws: WebSessionAccess.AccessError.unauthorized) {
            try await fixture.web.renew(renewal: renewal, origin: WebSessionFixture.origin)
        }
        await #expect(throws: RemoteAccessError.unauthorized) { try await fixture.authenticate(credential.token) }
        #expect(fixture.counter.teardownCount == 1)
    }

    @Test func aCredentialNeverOutlivesItsWindow() async throws {
        let fixture = WebSessionFixture()
        await fixture.web.setEnabled(true)
        let (_, renewal) = try await fixture.connect()
        fixture.clock.advance(3550)
        let late = try await fixture.web.renew(renewal: renewal, origin: WebSessionFixture.origin)
        #expect(late.expiresAt <= late.windowExpiresAt)
    }

    @Test func turningTheSwitchOffRevokesEverything() async throws {
        let fixture = WebSessionFixture()
        await fixture.web.setEnabled(true)
        let (credential, renewal) = try await fixture.connect()
        await fixture.web.setEnabled(false)
        await #expect(throws: RemoteAccessError.unauthorized) { try await fixture.authenticate(credential.token) }
        await #expect(throws: WebSessionAccess.AccessError.disabled) {
            try await fixture.web.renew(renewal: renewal, origin: WebSessionFixture.origin)
        }
        await #expect(throws: WebSessionAccess.AccessError.disabled) { try await fixture.web.request(origin: WebSessionFixture.origin) }
        #expect(fixture.counter.teardownCount == 1)
    }

    @Test func disconnectingOnePageLeavesTheOthers() async throws {
        let fixture = WebSessionFixture()
        await fixture.web.setEnabled(true)
        let (first, _) = try await fixture.connect(origin: "http://localhost:8081")
        let (second, secondRenewal) = try await fixture.connect(origin: "http://localhost:5200")
        let windows = await fixture.web.activeWindows()
        #expect(windows.count == 2)
        let firstWindow = try #require(windows.first { $0.origin == "http://localhost:8081" })
        await fixture.web.disconnect(windowId: firstWindow.id)
        await #expect(throws: RemoteAccessError.unauthorized) { try await fixture.authenticate(first.token, origin: "http://localhost:8081") }
        _ = try await fixture.authenticate(second.token, origin: "http://localhost:5200")
        #expect(fixture.counter.teardownCount == 0, "sources stay while any window is open")
        try await fixture.web.revoke(renewal: secondRenewal, origin: "http://localhost:5200")
        #expect(fixture.counter.teardownCount == 1)
    }

    @Test func requestsAreRateLimited() async throws {
        var limits = WebSessionAccess.Limits()
        limits.maxRequestsPerMinute = 2
        let fixture = WebSessionFixture(limits: limits)
        await fixture.web.setEnabled(true)
        _ = try await fixture.web.request(origin: "http://localhost:3001")
        _ = try await fixture.web.request(origin: "http://localhost:3002")
        await #expect(throws: WebSessionAccess.AccessError.tooManyRequests) { try await fixture.web.request(origin: "http://localhost:3003") }
        fixture.clock.advance(61)
        _ = try await fixture.web.request(origin: "http://localhost:3003")
    }

    @Test func sourcesThatCannotBePreparedFailTheApproval() async throws {
        let fixture = WebSessionFixture(prepareFails: true)
        await fixture.web.setEnabled(true)
        let pending = try await fixture.web.request(origin: WebSessionFixture.origin)
        await fixture.web.decide(id: pending.id, allow: true)
        await #expect(throws: WebSessionAccess.AccessError.unavailable) { try await fixture.web.poll(id: pending.id, origin: WebSessionFixture.origin) }
        #expect(await fixture.web.activeWindows().isEmpty)
        await #expect(throws: RemoteAccessError.unavailable) {
            try await fixture.access.issueDevelopment(scopes: [.init(agentId: "a", runtimeId: "r", sessionId: nil, actions: [.readHistory])], origin: nil)
        }
    }

    @Test func controlIsReportedOnlyWhenTheScopesAllowIt() async throws {
        let fixture = WebSessionFixture(actions: [.listSessions, .readHistory, .sendMessage, .interrupt])
        await fixture.web.setEnabled(true)
        let (credential, _) = try await fixture.connect()
        #expect(credential.controls)
    }

    @Test func loopbackPeersAndHostsAreTheOnlyOnesAccepted() {
        let port: UInt16 = 58350
        func peer(_ address: String) -> NWEndpoint { .hostPort(host: .ipv4(IPv4Address(address)!), port: 40000) }
        func allowed(_ peer: NWEndpoint, host: String, duplicates: Set<String> = []) -> Bool {
            MobileSyncServer.allowsLocalWebSession(peer: peer, headers: ["host": host], duplicateHeaders: duplicates, port: port)
        }
        #expect(allowed(peer("127.0.0.1"), host: "127.0.0.1:58350"))
        #expect(allowed(peer("127.0.0.1"), host: "localhost:58350"))
        #expect(!allowed(peer("192.168.1.5"), host: "127.0.0.1:58350"), "another device on the network")
        #expect(!allowed(peer("127.0.0.1"), host: "192.168.1.5:58350"), "reached under a LAN name")
        #expect(!allowed(peer("127.0.0.1"), host: "evil.example:58350"), "DNS rebinding")
        #expect(!allowed(peer("127.0.0.1"), host: "127.0.0.1:58351"))
        #expect(!allowed(peer("127.0.0.1"), host: "127.0.0.1:58350", duplicates: ["origin"]))
    }
}

/// The routes, through a real listener, with real session sources behind them.
struct WebSessionRouteTests {
    private static let origin = "http://localhost:8081"

    private struct Rig {
        let server: MobileSyncServer
        let web: WebSessionAccess
        let root: URL
        let base: String
        let session = URLSession(configuration: .ephemeral)

        struct Reply {
            let status: Int
            let http: HTTPURLResponse
            let json: [String: Any]
            func header(_ name: String) -> String? { http.value(forHTTPHeaderField: name) }
        }

        func call(_ method: String, _ path: String, origin: String? = WebSessionRouteTests.origin,
                  bearer: String? = nil) async throws -> Reply {
            var request = URLRequest(url: try #require(URL(string: base + path)))
            request.httpMethod = method
            if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
            if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
            let (data, response) = try await session.data(for: request)
            let http = try #require(response as? HTTPURLResponse)
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            return Reply(status: http.statusCode, http: http, json: json)
        }
        func stop() async {
            session.invalidateAndCancel()
            server.installWebSessionAccess(nil)
            await web.setEnabled(false)
            server.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func withRig(install: Bool = true, _ body: (Rig) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("state.sqlite")
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK, let database = db else { throw ChatGPTDirectoryError.unavailable }
        let rollout = root.appendingPathComponent("a.jsonl").path.replacingOccurrences(of: "'", with: "''")
        let setup = ["CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, title TEXT, updated_at INTEGER, archived INTEGER, thread_source TEXT)",
                     "INSERT INTO threads VALUES ('a', '\(rollout)', 'Real session title', 100, 0, 'user')"]
        for sql in setup { guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw ChatGPTDirectoryError.invalidRecord } }
        sqlite3_close(database)

        let server = MobileSyncServer(port: 0, token: "web-session-test-token", listenOnLoopbackOnly: true,
                                      dataProvider: MobileSyncServerTests.MockDataProvider())
        try server.start()
        for _ in 0..<100 where server.listeningPort == nil { try await Task.sleep(for: .milliseconds(50)) }
        let port = try #require(server.listeningPort)

        let adapter = ChatGPTReadAdapter(directory: .init(databaseURL: databaseURL, storageRoot: root, runtimeId: "rt_web_test"),
                                         runtimeLabel: "test")
        let sources = WebSessionSources(reads: server.remoteReadService, load: { [adapter] in [adapter] })
        let web = WebSessionAccess(access: server.remoteAccess, scopes: { await sources.scopes() },
                                   prepare: { try await sources.prepare() }, teardown: { await sources.teardown() })
        if install { server.installWebSessionAccess(web) }
        await web.setEnabled(true)
        let rig = Rig(server: server, web: web, root: root, base: "http://127.0.0.1:\(port)")
        do { try await body(rig) } catch { await rig.stop(); throw error }
        await rig.stop()
    }

    @Test func theRoutesDoNotExistUntilTheOwnerInstallsThem() async throws {
        try await withRig(install: false) { rig in
            let outcome4 = try await rig.call("POST", "/api/v1/web-session/request").status
            #expect(outcome4 == 404)
        }
    }

    @Test func aPageConnectsReadsRealSessionsRenewsAndDisconnects() async throws {
        try await withRig { rig in
            let request = try await rig.call("POST", "/api/v1/web-session/request")
            #expect(request.status == 202)
            #expect(request.header("Access-Control-Allow-Origin") == Self.origin)
            let requestId = try #require(request.json["requestId"] as? String)
            let code = try #require(request.json["code"] as? String)
            #expect(code.count == 4)

            let waiting = try await rig.call("GET", "/api/v1/web-session/request/" + requestId)
            #expect(waiting.json["status"] as? String == "pending")

            // The owner sees the same code, and allows it.
            let shown = try #require(await rig.web.pendingRequests().first)
            #expect(shown.code == code && shown.origin == Self.origin)
            await rig.web.decide(id: shown.id, allow: true)

            let approved = try await rig.call("GET", "/api/v1/web-session/request/" + requestId)
            #expect(approved.json["status"] as? String == "approved")
            let token = try #require(approved.json["token"] as? String)
            let renewal = try #require(approved.json["renewal"] as? String)
            #expect(approved.json["mode"] as? String == "development-read-only")
            #expect(token.hasPrefix("tomo_remote_dev_") && token.count == 59)

            // The real session sources are reachable with that credential, from that origin only.
            let outcome5 = try await rig.call("GET", "/api/v1/remote/catalog", bearer: token).status
            #expect(outcome5 == 200)
            let sessions = try await rig.call("GET", "/api/v1/remote/sessions?agent_id=agent.chatgpt&runtime_id=rt_web_test", bearer: token)
            #expect(sessions.status == 200)
            #expect(String(describing: sessions.json).contains("Real session title"))
            let outcome6 = try await rig.call("GET", "/api/v1/remote/catalog", origin: "http://localhost:9999", bearer: token).status
            #expect(outcome6 == 403)

            let renewed = try await rig.call("POST", "/api/v1/web-session/renew", bearer: renewal)
            #expect(renewed.status == 200)
            let nextToken = try #require(renewed.json["token"] as? String)
            #expect(nextToken != token)
            let outcome7 = try await rig.call("GET", "/api/v1/remote/catalog", bearer: nextToken).status
            #expect(outcome7 == 200)

            let outcome8 = try await rig.call("DELETE", "/api/v1/web-session/current", bearer: renewal).status
            #expect(outcome8 == 204)
            let outcome9 = try await rig.call("GET", "/api/v1/remote/catalog", bearer: nextToken).status
            #expect(outcome9 == 401)
            let outcome10 = try await rig.call("POST", "/api/v1/web-session/renew", bearer: renewal).status
            #expect(outcome10 == 401)
        }
    }

    @Test func nothingIsReadableBeforeTheOwnerApproves() async throws {
        try await withRig { rig in
            let request = try await rig.call("POST", "/api/v1/web-session/request")
            let requestId = try #require(request.json["requestId"] as? String)
            for _ in 0..<3 {
                let outcome11 = try await rig.call("GET", "/api/v1/web-session/request/" + requestId).json["token"]
                #expect(outcome11 == nil)
            }
            let outcome12 = try await rig.call("GET", "/api/v1/remote/catalog", bearer: "tomo_remote_dev_" + String(repeating: "A", count: 43)).status
            #expect(outcome12 == 401)
        }
    }

    @Test func foreignAndMissingOriginsAreRefused() async throws {
        try await withRig { rig in
            for origin in ["https://example.com", "http://192.168.1.5:8081", nil] {
                let result = try await rig.call("POST", "/api/v1/web-session/request", origin: origin)
                #expect(result.status == 403, Comment(rawValue: origin ?? "no origin"))
            }
            #expect(await rig.web.pendingRequests().isEmpty, "a refused page never makes the desktop ask")
        }
    }

    @Test func preflightEchoesOnlyTheExactOrigin() async throws {
        try await withRig { rig in
            let result = try await rig.call("OPTIONS", "/api/v1/web-session/renew")
            #expect(result.status == 204)
            #expect(result.header("Access-Control-Allow-Origin") == Self.origin)
            #expect(result.header("Vary") == "Origin")
            #expect(result.header("Access-Control-Allow-Headers")?.contains("Authorization") == true)
        }
    }

    @Test func aSwitchThatIsOffAnswersForbidden() async throws {
        try await withRig { rig in
            await rig.web.setEnabled(false)
            let result = try await rig.call("POST", "/api/v1/web-session/request")
            #expect(result.status == 403)
            #expect(result.json["error"] as? String == "web_sessions_disabled")
        }
    }
}
