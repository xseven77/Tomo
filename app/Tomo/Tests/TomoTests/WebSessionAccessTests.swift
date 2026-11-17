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

    @Test func lanOriginsMustBePrivateIPv4Literals() {
        for host in ["10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.1.5"] {
            #expect(WebSessionAccess.isAllowedOrigin("http://\(host):8081", allowLAN: true))
        }
        for host in ["172.15.0.1", "172.32.0.1", "8.8.8.8", "169.254.1.1", "0.0.0.0", "224.0.0.1", "mac.local", "192.168.1.1.evil.test", "192.168.001.1"] {
            #expect(!WebSessionAccess.isAllowedOrigin("http://\(host):8081", allowLAN: true))
        }
        for origin in ["http://192.168.1.5:8081/", "http://user@192.168.1.5:8081", "http://192.168.1.5:0", "null"] {
            #expect(!WebSessionAccess.isAllowedOrigin(origin, allowLAN: true))
        }
    }

    @Test func lanClientsNeedOptInAndCannotCollectEachOthersGrant() async throws {
        let fixture = WebSessionFixture()
        let origin = "http://192.168.1.2:8081", firstPeer = "192.168.1.3", otherPeer = "192.168.1.4"
        await fixture.web.setEnabled(true)
        let (localToken, _) = try await fixture.connect()
        await #expect(throws: WebSessionAccess.AccessError.originNotAllowed) {
            try await fixture.web.request(origin: origin, peer: firstPeer)
        }
        await fixture.web.setLANEnabled(true)
        let first = try await fixture.web.request(origin: origin, peer: firstPeer)
        let other = try await fixture.web.request(origin: origin, peer: otherPeer)
        #expect(first.id != other.id)
        #expect(first.peer == firstPeer)
        #expect(try await fixture.web.request(origin: origin, peer: firstPeer) == first)
        await fixture.web.decide(id: first.id, allow: true)
        await #expect(throws: WebSessionAccess.AccessError.notFound) {
            try await fixture.web.poll(id: first.id, origin: origin, peer: otherPeer)
        }
        guard case .approved(let granted, let renewal) = try await fixture.web.poll(id: first.id, origin: origin, peer: firstPeer) else {
            Issue.record("missing LAN grant"); return
        }
        _ = try await fixture.authenticate(granted.token, origin: origin)
        await #expect(throws: WebSessionAccess.AccessError.unauthorized) {
            try await fixture.web.renew(renewal: renewal, origin: origin, peer: otherPeer)
        }
        await #expect(throws: WebSessionAccess.AccessError.unauthorized) {
            try await fixture.web.revoke(renewal: renewal, origin: origin, peer: otherPeer)
        }
        // More than four simultaneous credentials must all be revoked with the window.
        for _ in 0..<6 { _ = try await fixture.web.renew(renewal: renewal, origin: origin, peer: firstPeer) }
        await fixture.web.setLANEnabled(false)
        await #expect(throws: RemoteAccessError.unauthorized) { try await fixture.authenticate(granted.token, origin: origin) }
        await #expect(throws: WebSessionAccess.AccessError.unauthorized) {
            try await fixture.web.renew(renewal: renewal, origin: origin, peer: firstPeer)
        }
        await fixture.web.decide(id: other.id, allow: true)
        #expect(await fixture.web.activeWindows().count == 1)
        _ = try await fixture.authenticate(localToken.token)
    }

    @Test func lanHostAndPeerValidationRejectsPublicAddressesAndRebinding() {
        func allowed(_ address: String, host: String, duplicates: Set<String> = []) -> Bool {
            MobileSyncServer.allowsLocalWebSession(peer: .hostPort(host: .ipv4(IPv4Address(address)!), port: 40000),
                headers: ["host": host], duplicateHeaders: duplicates, port: 58350, allowLAN: true)
        }
        #expect(allowed("192.168.1.3", host: "192.168.1.2:58350"))
        #expect(allowed("127.0.0.1", host: "192.168.1.2:58350"))
        #expect(!allowed("8.8.8.8", host: "192.168.1.2:58350"))
        #expect(!allowed("192.168.1.3", host: "localhost:58350"))
        #expect(!allowed("192.168.1.3", host: "evil.test:58350"))
        #expect(!allowed("192.168.1.3", host: "192.168.1.2:58351"))
        #expect(!allowed("192.168.1.3", host: "192.168.1.2:58350", duplicates: ["origin"]))
        let mapped = NWEndpoint.hostPort(host: .ipv6(IPv6Address("::ffff:192.168.1.3")!), port: 40000)
        #expect(MobileSyncServer.webSessionPeer(mapped) == "192.168.1.3")
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
                  bearer: String? = nil, body: [String: Any]? = nil, key: String? = nil) async throws -> Reply {
            var request = URLRequest(url: try #require(URL(string: base + path)))
            request.httpMethod = method
            if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
            if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
            if let body {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            if let key { request.setValue(key, forHTTPHeaderField: "Idempotency-Key") }
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

    private func withRig(install: Bool = true, host: String = "127.0.0.1", control: Bool = false, resumeDelay: Double = 0, resumeConflict: Bool = false, _ body: (Rig) async throws -> Void) async throws {
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
        try Data("{}\n".utf8).write(to: root.appendingPathComponent("a.jsonl"))

        let server = MobileSyncServer(port: 0, token: "web-session-test-token", listenOnLoopbackOnly: host == "127.0.0.1",
                                      dataProvider: MobileSyncServerTests.MockDataProvider())
        try server.start()
        for _ in 0..<100 where server.listeningPort == nil { try await Task.sleep(for: .milliseconds(50)) }
        let port = try #require(server.listeningPort)

        let adapter = ChatGPTReadAdapter(directory: .init(databaseURL: databaseURL, storageRoot: root, runtimeId: "rt_web_test"),
                                         runtimeLabel: "test")
        let executable = root.appendingPathComponent("synthetic-agent")
        if control {
            let script = """
            #!/usr/bin/python3
            import json,sys,time
            resumed=False
            for line in sys.stdin:
                frame=json.loads(line); method=frame.get('method'); event=None
                if method=='initialized': continue
                if method=='initialize': result={'userAgent':'web-synthetic'}
                elif method=='thread/resume':
                    if \(resumeConflict ? "True" : "False"):
                        print(json.dumps({'id':frame['id'],'error':{'code':-32600,'message':'thread a already has an active writer'}}),flush=True)
                        continue
                    assert not resumed
                    assert frame['params']=={'threadId':'a','excludeTurns':True}
                    open(\(String(reflecting: root.appendingPathComponent("resume-started").path)),'w').close()
                    time.sleep(\(resumeDelay))
                    resumed=True; result={'thread':{'id':'a'}}
                elif method=='thread/read':
                    assert resumed
                    result={'thread':{'id':'a','createdAt':1,'updatedAt':100,'status':{'type':'idle'},'turns':[]}}
                elif method=='turn/start':
                    assert frame['params']['threadId']=='a'
                    assert frame['params']['input'][0]['text']=='hello web'
                    result={'turn':{'id':'turn','status':'completed','items':[]}}
                    event={'method':'turn/completed','params':{'threadId':'a','turn':{'id':'turn','status':'completed','items':[
                        {'id':'user','type':'userMessage','content':[{'type':'text','text':'hello web'}]},
                        {'id':'answer','type':'agentMessage','text':'web reply'}]}}}
                else: raise RuntimeError('unexpected method: '+str(method))
                print(json.dumps({'id':frame['id'],'result':result}),flush=True)
                if event: print(json.dumps(event),flush=True)
            """
            try Data(script.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        let controls = control ? WebSessionRuntimeService(server: server, directory: root.appendingPathComponent("web-runtime"),
            executable: { executable }) : nil
        let sources = WebSessionSources(reads: server.remoteReadService, controls: controls, load: { [adapter] in [adapter] })
        let web = WebSessionAccess(access: server.remoteAccess, scopes: { await sources.scopes() },
                                   prepare: { try await sources.prepare() }, teardown: { await sources.teardown() })
        if install { server.installWebSessionAccess(web) }
        await web.setEnabled(true)
        let rig = Rig(server: server, web: web, root: root, base: "http://\(host):\(port)")
        do { try await body(rig) } catch { await rig.stop(); throw error }
        await rig.stop()
    }

    @Test func aSessionHeldByAnotherWriterAnswersLockedNotAGenericFailure() async throws {
        try await withRig(control: true, resumeConflict: true) { rig in
            let pending = try await rig.web.request(origin: Self.origin)
            await rig.web.decide(id: pending.id, allow: true)
            guard case .approved(let credential, _) = try await rig.web.poll(id: pending.id, origin: Self.origin) else {
                Issue.record("approval failed"); return
            }
            let query = "?agent_id=agent.chatgpt&runtime_id=rt_web_test"
            let page = try await rig.call("GET", "/api/v1/remote/sessions" + query, bearer: credential.token)
            let sid = try #require((page.json["items"] as? [[String: Any]])?.first?["sessionId"] as? String)
            let reply = try await rig.call("POST", "/api/v1/remote/sessions/" + sid + "/resume" + query, bearer: credential.token, body: [:])
            #expect(reply.status == 423)
            #expect(reply.json["error"] as? String == "session_in_use")
        }
    }

    @Test func handoffsAreReadableOnlyWithAGrantAndNeverExposeTheFullPath() async throws {
        try await withRig { rig in
            let dir = rig.root.appendingPathComponent("handoffs", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "---\ntomo-handoff: 1\ntitle: 交接测试\nagent: Codex\nworkspace: /Users/me/private/Tomo\nstatus: blocked\n---\n## 下一步\n继续\n"
                .write(to: dir.appendingPathComponent("h1.md"), atomically: true, encoding: .utf8)
            rig.server.handoffInbox = HandoffInbox(directory: dir)
            #expect(try await rig.call("GET", "/api/v1/remote/handoffs").status == 401)
            let pending = try await rig.web.request(origin: Self.origin)
            await rig.web.decide(id: pending.id, allow: true)
            guard case .approved(let credential, _) = try await rig.web.poll(id: pending.id, origin: Self.origin) else {
                Issue.record("approval failed"); return
            }
            let list = try await rig.call("GET", "/api/v1/remote/handoffs", bearer: credential.token)
            #expect(list.status == 200)
            let first = try #require((list.json["items"] as? [[String: Any]])?.first)
            #expect(first["title"] as? String == "交接测试")
            #expect(first["workspaceName"] as? String == "Tomo")
            let detail = try await rig.call("GET", "/api/v1/remote/handoffs/h1", bearer: credential.token)
            #expect(detail.status == 200)
            #expect((detail.json["body"] as? String)?.contains("继续") == true)
            #expect(!String(decoding: try JSONSerialization.data(withJSONObject: detail.json), as: UTF8.self).contains("/Users/me"))
            #expect(try await rig.call("GET", "/api/v1/remote/handoffs/missing", bearer: credential.token).status == 404)
            #expect(try await rig.call("GET", "/api/v1/remote/handoffs?x=1", bearer: credential.token).status == 400)
        }
    }

    @Test func theRoutesDoNotExistUntilTheOwnerInstallsThem() async throws {
        try await withRig(install: false) { rig in
            let outcome4 = try await rig.call("POST", "/api/v1/web-session/request").status
            #expect(outcome4 == 404)
        }
    }

    @Test func approvedWebHistoryCanExplicitlyResumeSendRenewAndRevoke() async throws {
        try await withRig(control: true) { rig in
            let pending = try await rig.web.request(origin: Self.origin)
            await rig.web.decide(id: pending.id, allow: true)
            guard case .approved(let credential, let renewal) = try await rig.web.poll(id: pending.id, origin: Self.origin) else {
                Issue.record("approval failed"); return
            }
            #expect(credential.controls)
            let token = credential.token
            let query = "?agent_id=agent.chatgpt&runtime_id=rt_web_test"
            let page = try await rig.call("GET", "/api/v1/remote/sessions" + query, bearer: token)
            let item = try #require((page.json["items"] as? [[String: Any]])?.first)
            #expect(item["controlMode"] as? String == "resumable")
            #expect((item["allowedActions"] as? [String])?.contains("session.resume") == true)
            let sid = try #require(item["sessionId"] as? String)
            let path = "/api/v1/remote/sessions/" + sid
            #expect(try await rig.call("POST", "/api/v1/remote/sessions/unknown/resume" + query, bearer: token, body: [:]).status == 404)
            #expect(try await rig.call("GET", path + "/sync" + query, bearer: token).status == 501,
                    "a GET must not start an owned runtime")
            #expect(try await rig.call("POST", path + "/resume" + query, bearer: token, body: ["path": "/tmp/other"]).status == 400)
            #expect(try await rig.call("POST", path + "/resume" + query, origin: "http://localhost:9999", bearer: token, body: [:]).status == 403)
            let readOnly = try await rig.server.remoteAccess.issueDevelopment(scopes: [
                .init(agentId: "agent.chatgpt", runtimeId: "rt_web_test", sessionId: nil, actions: [.readHistory])], origin: Self.origin)
            #expect(try await rig.call("POST", path + "/resume" + query, bearer: readOnly.token, body: [:]).status == 401)
            async let first = rig.call("POST", path + "/resume" + query, bearer: token, body: [:])
            async let duplicate = rig.call("POST", path + "/resume" + query, bearer: token, body: [:])
            let outcomes = try await [first, duplicate]
            #expect(outcomes.allSatisfy { $0.status == 202 })
            let sync = try await rig.call("GET", path + "/sync" + query, bearer: token)
            #expect(sync.status == 200)
            #expect(sync.json["controlMode"] as? String == "live")
            #expect((sync.json["allowedActions"] as? [String])?.contains("message.send") == true)
            let expiredStream = try await rig.call("GET", path + "/events" + query + "&after=stale-cursor", bearer: token)
            #expect(expiredStream.status == 409, "expired replay must request resync, never become an inert read-only stream")
            let oldPrincipal = try await rig.server.remoteAccess.authenticate(authorization: "Bearer " + token, origin: Self.origin)
            let owner = try await rig.web.operationOwner(oldPrincipal)
            let renewed = try await rig.call("POST", "/api/v1/web-session/renew", bearer: renewal)
            let newToken = try #require(renewed.json["token"] as? String)
            let newPrincipal = try await rig.server.remoteAccess.authenticate(authorization: "Bearer " + newToken, origin: Self.origin)
            #expect(try await rig.web.operationOwner(newPrincipal) == owner)
            let sent = try await rig.call("POST", path + "/messages" + query, bearer: newToken, body: [
                "executionEpoch": try #require(sync.json["executionEpoch"]),
                "expectedControlRevision": try #require(sync.json["controlRevision"]),
                "mode": "start", "clientMessageId": "web-message", "input": [["type": "text", "text": "hello web"]]
            ], key: UUID().uuidString)
            #expect(sent.status == 202)
            var received = false
            for _ in 0..<100 {
                let updated = try await rig.call("GET", path + "/sync" + query, bearer: newToken)
                received = String(describing: updated.json["messages"]).contains("web reply")
                if received { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(received)
            #expect(try await rig.call("DELETE", "/api/v1/web-session/current", bearer: renewal).status == 204)
            #expect(try await rig.call("POST", path + "/resume" + query, bearer: newToken, body: [:]).status == 401)
            #expect(try await rig.call("GET", path + "/sync" + query, bearer: newToken).status == 401)
        }
    }

    @Test func revokingDuringWebResumeCannotPublishALateWritableSession() async throws {
        try await withRig(control: true, resumeDelay: 1) { rig in
            let request = try await rig.web.request(origin: Self.origin)
            await rig.web.decide(id: request.id, allow: true)
            guard case .approved(let credential, let renewal) = try await rig.web.poll(id: request.id, origin: Self.origin) else {
                Issue.record("approval failed"); return
            }
            let query = "?agent_id=agent.chatgpt&runtime_id=rt_web_test"
            let page = try await rig.call("GET", "/api/v1/remote/sessions" + query, bearer: credential.token)
            let sid = try #require((page.json["items"] as? [[String: Any]])?.first?["sessionId"] as? String)
            let path = "/api/v1/remote/sessions/" + sid
            let pending = Task { try await rig.call("POST", path + "/resume" + query, bearer: credential.token, body: [:]).status }
            let marker = rig.root.appendingPathComponent("resume-started").path
            for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker) { try await Task.sleep(for: .milliseconds(20)) }
            #expect(FileManager.default.fileExists(atPath: marker))
            #expect(try await rig.call("DELETE", "/api/v1/web-session/current", bearer: renewal).status == 204)
            #expect(try await pending.value != 202)
            #expect(try await rig.call("GET", path + "/sync" + query, bearer: credential.token).status == 401)
            #expect(await rig.web.activeWindows().isEmpty)
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

    @Test func lanPageCanApproveReadRenewAndLoseAccessWhenLANDisabled() async throws {
        try await withRig { rig in
            let origin = "http://192.168.1.2:8081"
            #expect(try await rig.call("POST", "/api/v1/web-session/request", origin: origin).status == 403)
            await rig.web.setLANEnabled(true)
            let preflight = try await rig.call("OPTIONS", "/api/v1/web-session/renew", origin: origin)
            #expect(preflight.status == 204)
            #expect(preflight.header("Access-Control-Allow-Origin") == origin)
            let request = try await rig.call("POST", "/api/v1/web-session/request", origin: origin)
            #expect(request.status == 202)
            let id = try #require(request.json["requestId"] as? String)
            await rig.web.decide(id: try #require(UUID(uuidString: id)), allow: true)
            let approved = try await rig.call("GET", "/api/v1/web-session/request/" + id, origin: origin)
            let renewal = try #require(approved.json["renewal"] as? String)
            let renewed = try await rig.call("POST", "/api/v1/web-session/renew", origin: origin, bearer: renewal)
            #expect(renewed.status == 200)
            let token = try #require(renewed.json["token"] as? String)
            #expect(try await rig.call("GET", "/api/v1/remote/catalog", origin: origin, bearer: token).status == 200)
            await rig.web.setLANEnabled(false)
            #expect(try await rig.call("GET", "/api/v1/remote/catalog", origin: origin, bearer: token).status == 401)
            #expect(try await rig.call("POST", "/api/v1/web-session/renew", origin: origin, bearer: renewal).status == 403)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOMO_TEST_LAN_HOST"] != nil))
    func actualLANInterfaceSupportsTheAuthorizationFlow() async throws {
        let host = try #require(ProcessInfo.processInfo.environment["TOMO_TEST_LAN_HOST"])
        #expect(WebSessionAccess.isPrivateIPv4(host))
        try await withRig(host: host) { rig in
            let origin = "http://\(host):8081"
            #expect(try await rig.call("POST", "/api/v1/web-session/request", origin: origin).status == 403)
            await rig.web.setLANEnabled(true)
            let result = try await rig.call("POST", "/api/v1/web-session/request", origin: origin)
            #expect(result.status == 202)
            let id = try #require(result.json["requestId"] as? String)
            let pending = try #require(await rig.web.pendingRequests().first)
            #expect(pending.peer == host)
            await rig.web.decide(id: pending.id, allow: true)
            let approved = try await rig.call("GET", "/api/v1/web-session/request/" + id, origin: origin)
            let renewal = try #require(approved.json["renewal"] as? String)
            let renewed = try await rig.call("POST", "/api/v1/web-session/renew", origin: origin, bearer: renewal)
            #expect(renewed.status == 200)
            let token = try #require(renewed.json["token"] as? String)
            #expect(try await rig.call("GET", "/api/v1/remote/catalog", origin: origin, bearer: token).status == 200)
            #expect(try await rig.call("DELETE", "/api/v1/web-session/current", origin: origin, bearer: renewal).status == 204)
            #expect(try await rig.call("GET", "/api/v1/remote/catalog", origin: origin, bearer: token).status == 401)
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

struct WebSessionDurationTests {
    private func open(_ fixture: WebSessionFixture, duration: TimeInterval?) async throws -> (WebSessionAccess.Credential, String) {
        let pending = try await fixture.web.request(origin: WebSessionFixture.origin)
        await fixture.web.decide(id: pending.id, allow: true, duration: duration)
        guard case .approved(let credential, let renewal) = try await fixture.web.poll(id: pending.id, origin: WebSessionFixture.origin) else {
            throw WebSessionAccess.AccessError.unavailable
        }
        return (credential, renewal)
    }

    @Test func theOwnerPicksHowLongTheWindowLasts() async throws {
        let fixture = WebSessionFixture()
        await fixture.web.setEnabled(true)
        let (credential, renewal) = try await open(fixture, duration: 900)
        #expect(credential.windowExpiresAt.timeIntervalSince(fixture.clock.date) <= 900)
        fixture.clock.advance(901)
        await #expect(throws: WebSessionAccess.AccessError.unauthorized) {
            try await fixture.web.renew(renewal: renewal, origin: WebSessionFixture.origin)
        }
    }

    @Test func aPermanentWindowSurvivesDaysButStillRenewsFiveMinuteCredentials() async throws {
        let fixture = WebSessionFixture()
        await fixture.web.setEnabled(true)
        let (first, renewal) = try await open(fixture, duration: WebSessionAccess.permanent)
        #expect(first.windowExpiresAt == .distantFuture)
        fixture.clock.advance(10 * 86400)
        let later = try await fixture.web.renew(renewal: renewal, origin: WebSessionFixture.origin)
        #expect(later.expiresAt.timeIntervalSince(fixture.clock.date) <= 300)
        await fixture.web.setEnabled(false)
        await #expect(throws: WebSessionAccess.AccessError.disabled) {
            try await fixture.web.renew(renewal: renewal, origin: WebSessionFixture.origin)
        }
    }

    @Test func renewingAWindowMovesItsEndFromNow() async throws {
        let fixture = WebSessionFixture()
        await fixture.web.setEnabled(true)
        let (_, renewal) = try await open(fixture, duration: 900)
        let window = try #require(await fixture.web.activeWindows().first)
        fixture.clock.advance(600)
        await fixture.web.extend(windowId: window.id, duration: 3600)
        fixture.clock.advance(1200)
        let renewed = try await fixture.web.renew(renewal: renewal, origin: WebSessionFixture.origin)
        #expect(renewed.windowExpiresAt.timeIntervalSince(fixture.clock.date) > 1800)
        await fixture.web.extend(windowId: window.id, duration: WebSessionAccess.permanent)
        #expect(await fixture.web.activeWindows().first?.expiresAt == .distantFuture)
    }

    @Test func aLapsedWindowCannotBeRevivedByExtending() async throws {
        let fixture = WebSessionFixture()
        await fixture.web.setEnabled(true)
        _ = try await open(fixture, duration: 900)
        let window = try #require(await fixture.web.activeWindows().first)
        fixture.clock.advance(901)
        await fixture.web.extend(windowId: window.id, duration: 3600)
        #expect(await fixture.web.activeWindows().isEmpty)
    }
}
