import XCTest
import CryptoKit
@testable import Tomo

final class DesktopSessionMemory: DesktopCloudStorage, @unchecked Sendable {
    private let lock = NSLock(); private var data: Data?; private var failClear = false
    func rejectClear(_ value: Bool) { lock.lock(); defer { lock.unlock() }; failClear = value }
    func load() throws -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    func save(_ value: Data?) throws {
        lock.lock(); defer { lock.unlock() }
        if value == nil && failClear { throw DesktopCloudError.storageUnavailable }; data = value
    }
}
final class DesktopIdentityMemory: RemoteServerIdentityStorage, @unchecked Sendable {
    private let lock = NSLock(); private var data: Data?
    func load() throws -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    func insertIfAbsent(_ value: Data) throws -> Bool { lock.lock(); defer { lock.unlock() }; if data != nil { return false }; data = value; return true }
}
private final class DesktopTestClock: @unchecked Sendable {
    private let lock = NSLock(); private var date: Date
    init(_ date: Date) { self.date = date }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; date = date.addingTimeInterval(seconds) }
}
actor DesktopCloudFixture: DesktopCloudHTTP {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let sessionId = "22222222-2222-4222-8222-222222222222", userId = "33333333-3333-4333-8333-333333333333"
    let challengeId = "11111111-1111-4111-8111-111111111111"
    var requests: [URLRequest] = []
    var pkce: String?
    var wrongSession = false, wrongThumbprint = false, revoked = false, refreshUnchanged = false, failRefresh = false
    var blockPath: String?, pending: CheckedContinuation<Void, Never>?, observer: CheckedContinuation<Void, Never>?
    var waiting = false, verifiedProof = false
    func configure(wrongSession: Bool = false, wrongThumbprint: Bool = false, revoked: Bool = false, refreshUnchanged: Bool = false, failRefresh: Bool = false, block: String? = nil) {
        self.wrongSession = wrongSession; self.wrongThumbprint = wrongThumbprint; self.revoked = revoked; self.refreshUnchanged = refreshUnchanged; self.failRefresh = failRefresh; blockPath = block
    }
    func waitForRequest() async { if waiting { return }; await withCheckedContinuation { observer = $0 } }
    func resume() { pending?.resume(); pending = nil; waiting = false; blockPath = nil }
    func count(_ suffix: String) -> Int { requests.filter { $0.url!.path.hasSuffix(suffix) }.count }
    func send(_ request: URLRequest) async throws -> DesktopCloudReply {
        requests.append(request)
        let path = request.url!.path
        if path.hasSuffix(blockPath ?? "never-match") {
            await withCheckedContinuation { continuation in pending = continuation; waiting = true; observer?.resume(); observer = nil }
        }
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        if path.hasSuffix("auth/logout") { return .init(status: 204, body: Data(), contentType: "") }
        if path.hasSuffix("auth/challenges") {
            pkce = body["codeChallenge"] as? String
            return try reply(202, ["challengeId": challengeId, "expiresAt": iso(now.addingTimeInterval(600))])
        }
        if path.hasSuffix("auth/exchange") {
            let verifier = body["codeVerifier"] as! String
            guard encoded(Data(SHA256.hash(data: Data(verifier.utf8)))) == pkce else { throw DesktopCloudError.invalidRequest }
            return try reply(200, credential())
        }
        if path.hasSuffix("auth/refresh") {
            if failRefresh { throw URLError(.networkConnectionLost) }
            return try reply(200, credential(rotated: !refreshUnchanged))
        }
        guard request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer tomo_a_") == true else { throw DesktopCloudError.invalidRequest }
        if revoked { return try reply(401, ["code": "session_revoked"]) }
        if path.hasSuffix("servers/registration-challenges") {
            let session = wrongSession ? userId : sessionId
            return try reply(201, ["challengeId": challengeId, "algorithm": "ES256", "expiresAt": iso(now.addingTimeInterval(300)),
                "signingInput": "TomoServer/server-registration/v1\n\(challengeId)\n\(session)\n" + String(repeating: "A", count: 43)])
        }
        if path.hasSuffix("/servers") {
            let key = try P256.Signing.PublicKey(pemRepresentation: body["publicKeyPem"] as! String)
            let signature = try P256.Signing.ECDSASignature(derRepresentation: Data(base64Encoded: body["signature"] as! String)!)
            let input = "TomoServer/server-registration/v1\n\(challengeId)\n\(sessionId)\n" + String(repeating: "A", count: 43)
            guard key.isValidSignature(signature, for: Data(input.utf8)) else { throw DesktopCloudError.invalidRequest }
            verifiedProof = true
            return try reply(201, ["serverId": "44444444-4444-4444-8444-444444444444", "name": body["name"]!,
                "keyThumbprint": wrongThumbprint ? "foreign" : RemoteBindingApproval.thumbprint(key), "verifiedAt": iso(now), "revokedAt": NSNull()])
        }
        throw DesktopCloudError.invalidRequest
    }
    func credential(rotated: Bool = false) -> [String: Any] {
        ["sessionId": sessionId, "userId": userId, "tokenType": "Bearer",
         "accessToken": "tomo_a_" + String(repeating: rotated ? "C" : "A", count: 43),
         "refreshToken": "tomo_r_" + String(repeating: rotated ? "D" : "B", count: 43),
         "accessExpiresAt": iso(now.addingTimeInterval(900)), "sessionExpiresAt": iso(now.addingTimeInterval(86400))]
    }
    private func reply(_ status: Int, _ value: [String: Any]) throws -> DesktopCloudReply {
        .init(status: status, body: try JSONSerialization.data(withJSONObject: value), contentType: "application/json; charset=utf-8")
    }
    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private func encoded(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}

final class DesktopCloudSessionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    private func setup() throws -> (DesktopCloudSession, DesktopCloudFixture, DesktopSessionMemory) {
        let http = DesktopCloudFixture(), storage = DesktopSessionMemory(), date = now
        let cloud = try DesktopCloudSession(endpoint: URL(string: "https://cloud.example.test")!, storage: storage,
            http: http, identity: RemoteServerIdentity(storage: DesktopIdentityMemory()), clock: { date })
        return (cloud, http, storage)
    }
    func login(_ cloud: DesktopCloudSession) async throws {
        try await cloud.beginLogin(email: "owner@example.test"); _ = try await cloud.completeLogin(code: "123456")
    }
    func testPKCELoginPersistentSessionAndRealRegistrationProof() async throws {
        let (cloud, http, storage) = try setup(); try await login(cloud)
        let result = try await cloud.registerServer(name: "Studio Mac")
        let proofVerified = await http.verifiedProof; XCTAssertTrue(proofVerified)
        let registered = await cloud.registeredServer(); XCTAssertEqual(registered, result)
        let date = now
        let restored = try DesktopCloudSession(endpoint: URL(string: "https://cloud.example.test")!, storage: storage, http: http, clock: { date })
        let summary = await restored.summary(); XCTAssertEqual(summary?.userId, result.userId)
        let paths = await http.requests.map { $0.url!.path }
        XCTAssertEqual(paths, ["/api/v1/auth/challenges", "/api/v1/auth/exchange", "/api/v1/servers/registration-challenges", "/api/v1/servers"])
        do { _ = try await cloud.completeLogin(code: "123456"); XCTFail("OTP replay") } catch { XCTAssertEqual(error as? DesktopCloudError, .invalidRequest) }
    }
    func testWrongChallengeSessionNeverUploadsServerProof() async throws {
        let (cloud, http, _) = try setup(); try await login(cloud); await http.configure(wrongSession: true)
        do { _ = try await cloud.registerServer(name: "Studio Mac"); XCTFail("Wrong session accepted") }
        catch { XCTAssertEqual(error as? RemoteServerIdentityError, .invalidChallenge) }
        let uploads = await http.count("/servers"); XCTAssertEqual(uploads, 0)
    }
    func testWrongThumbprintAndRevokedSessionFailClosed() async throws {
        let (cloud, http, storage) = try setup(); try await login(cloud); await http.configure(wrongThumbprint: true)
        do { _ = try await cloud.registerServer(name: "Studio Mac"); XCTFail("Wrong key accepted") }
        catch { XCTAssertEqual(error as? DesktopCloudError, .invalidResponse) }
        let registered = await cloud.registeredServer(); XCTAssertNil(registered)
        await http.configure(revoked: true)
        do { _ = try await cloud.registerServer(name: "Studio Mac"); XCTFail("Revoked accepted") }
        catch { XCTAssertEqual(error as? DesktopCloudError, .rejected("session_revoked")) }
        let summary = await cloud.summary(); XCTAssertNil(summary); XCTAssertNil(try storage.load())
    }
    func testLogoutDuringChallengePreventsProofUpload() async throws {
        let (cloud, http, storage) = try setup(); try await login(cloud); await http.configure(block: "servers/registration-challenges")
        let task = Task { try await cloud.registerServer(name: "Studio Mac") }
        await http.waitForRequest(); try await cloud.logout(); await http.resume()
        do { _ = try await task.value; XCTFail("Late registration accepted") }
        catch { XCTAssertEqual(error as? DesktopCloudError, .staleResponse) }
        let uploads = await http.count("/servers"); XCTAssertEqual(uploads, 0); XCTAssertNil(try storage.load())
    }
    func testLateLoginRevokedInsteadOfInstalled() async throws {
        let (cloud, http, storage) = try setup(); try await cloud.beginLogin(email: "owner@example.test")
        await http.configure(block: "auth/exchange")
        let task = Task { try await cloud.completeLogin(code: "123456") }
        await http.waitForRequest(); try await cloud.logout(); await http.resume()
        do { _ = try await task.value; XCTFail("Late login installed") }
        catch { XCTAssertEqual(error as? DesktopCloudError, .staleResponse) }
        let revocations = await http.count("auth/logout"); XCTAssertEqual(revocations, 1); XCTAssertNil(try storage.load())
    }
    func testUntrustedIssuerAndForeignSavedIssuerRejected() async throws {
        for target in ["http://cloud.example.test", "https://user@cloud.example.test", "https://cloud.example.test/api", "https://cloud.example.test/?x=1"] {
            XCTAssertThrowsError(try DesktopCloudSession(endpoint: URL(string: target)!, storage: DesktopSessionMemory()))
        }
        let (cloud, _, storage) = try setup(); try await login(cloud)
        _ = try DesktopCloudSession(endpoint: URL(string: "https://other.example.test")!, storage: storage)
        XCTAssertNil(try storage.load())
    }
    func testRefreshRotatesAndUnchangedTokensCannotBeReplayed() async throws {
        for unchanged in [false, true] {
            let http = DesktopCloudFixture(), storage = DesktopSessionMemory(), clock = DesktopTestClock(now)
            let cloud = try DesktopCloudSession(endpoint: URL(string: "https://cloud.example.test")!, storage: storage,
                http: http, clock: { clock.now() })
            try await login(cloud); clock.advance(880); await http.configure(refreshUnchanged: unchanged)
            if unchanged {
                do { _ = try await cloud.currentSession(); XCTFail("Unchanged tokens accepted") }
                catch { XCTAssertEqual(error as? DesktopCloudError, .invalidResponse) }
                let current = try await cloud.currentSession(); XCTAssertNil(current); XCTAssertNil(try storage.load())
            } else {
                let current = try await cloud.currentSession(); XCTAssertNotNil(current); XCTAssertNotNil(try storage.load())
            }
            let calls = await http.count("auth/refresh"); XCTAssertEqual(calls, 1)
        }
    }
    func testSessionExpiryWhileRegistrationSuspendedDiscardsReply() async throws {
        let http = DesktopCloudFixture(), storage = DesktopSessionMemory(), clock = DesktopTestClock(now)
        let cloud = try DesktopCloudSession(endpoint: URL(string: "https://cloud.example.test")!, storage: storage,
            http: http, identity: RemoteServerIdentity(storage: DesktopIdentityMemory()), clock: { clock.now() })
        try await login(cloud); await http.configure(block: "servers/registration-challenges")
        let task = Task { try await cloud.registerServer(name: "Studio Mac") }
        await http.waitForRequest(); clock.advance(901); await http.resume()
        do { _ = try await task.value; XCTFail("Expired session accepted") }
        catch { XCTAssertEqual(error as? DesktopCloudError, .signedOut) }
        let uploads = await http.count("/servers"); XCTAssertEqual(uploads, 0)
        let registered = await cloud.registeredServer(); XCTAssertNil(registered)
    }
    func testLostRefreshReplyDoesNotReplayRotatingToken() async throws {
        let http = DesktopCloudFixture(), storage = DesktopSessionMemory(), clock = DesktopTestClock(now)
        let cloud = try DesktopCloudSession(endpoint: URL(string: "https://cloud.example.test")!, storage: storage,
            http: http, clock: { clock.now() })
        try await login(cloud); clock.advance(880); await http.configure(failRefresh: true)
        do { _ = try await cloud.currentSession(); XCTFail("Lost reply accepted") }
        catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
        let current = try await cloud.currentSession(); XCTAssertNil(current); XCTAssertNil(try storage.load())
        let refreshes = await http.count("auth/refresh"); XCTAssertEqual(refreshes, 1)
    }
    func testLogoutDuringRegistrationReplyDoesNotInstallMetadata() async throws {
        let (cloud, http, storage) = try setup(); try await login(cloud); await http.configure(block: "/servers")
        let task = Task { try await cloud.registerServer(name: "Studio Mac") }
        await http.waitForRequest(); try await cloud.logout(); await http.resume()
        do { _ = try await task.value; XCTFail("Late metadata installed") }
        catch { XCTAssertEqual(error as? DesktopCloudError, .staleResponse) }
        let registered = await cloud.registeredServer(); XCTAssertNil(registered); XCTAssertNil(try storage.load())
    }
}
