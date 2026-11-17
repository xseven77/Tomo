import XCTest
import CryptoKit
@testable import Tomo

private final class TrustTestClock: @unchecked Sendable {
    private let lock = NSLock(); private var value: Date
    init(_ value: Date) { self.value = value }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value = value.addingTimeInterval(seconds) }
}
private actor TrustHTTPFixture: DesktopCloudHTTP {
    private var reply: DesktopCloudReply
    var requests: [URLRequest] = []
    var blocking = false
    private var pending: CheckedContinuation<Void, Never>?, observer: CheckedContinuation<Void, Never>?
    private var waiting = false
    init(_ body: Data) { reply = .init(status: 200, body: body, contentType: "application/json", headers: ["cache-control": "public, max-age=60"]) }
    func update(_ body: Data, status: Int = 200, headers: [String: String] = ["cache-control": "public, max-age=60"]) {
        reply = .init(status: status, body: body, contentType: "application/json", headers: headers)
    }
    func block() { blocking = true }
    func waitForRequest() async { if waiting { return }; await withCheckedContinuation { observer = $0 } }
    func resume() { blocking = false; pending?.resume(); pending = nil; waiting = false }
    func send(_ request: URLRequest) async throws -> DesktopCloudReply {
        requests.append(request)
        if blocking { await withCheckedContinuation { pending = $0; waiting = true; observer?.resume(); observer = nil } }
        return reply
    }
}

final class RemoteCloudTrustTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let server = "33333333-3333-4333-8333-333333333333"
    func encoded(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    func jwks(_ key: P256.Signing.PrivateKey) throws -> Data {
        let bytes = key.publicKey.x963Representation
        return try JSONSerialization.data(withJSONObject: ["keys": [["kty": "EC", "crv": "P-256", "x": encoded(bytes.subdata(in: 1..<33)),
            "y": encoded(bytes.subdata(in: 33..<65)), "kid": "cloud", "alg": "ES256", "use": "sig"]]])
    }
    func token(_ key: P256.Signing.PrivateKey) throws -> String {
        let challenge = "44444444-4444-4444-8444-444444444444"
        let claims: [String: Any] = ["iss": "https://cloud.example.test", "aud": server,
            "sub": "11111111-1111-4111-8111-111111111111", "deviceId": "22222222-2222-4222-8222-222222222222",
            "cnf": ["jkt": String(repeating: "A", count: 43)], "deviceName": "Phone", "userEmail": "owner@example.test",
            "challengeId": challenge, "nonce": String(repeating: "A", count: 43), "scope": "server.bind", "bindingRevision": 1,
            "iat": Int(now.timeIntervalSince1970), "nbf": Int(now.timeIntervalSince1970), "exp": Int(now.timeIntervalSince1970) + 300, "jti": challenge]
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "typ": "tomo-binding-identity+jwt", "kid": "cloud"])
        let input = encoded(header) + "." + encoded(try JSONSerialization.data(withJSONObject: claims))
        return input + "." + encoded(try key.signature(for: Data(input.utf8)).rawRepresentation)
    }
    func testHTTPSFixedPathRefreshRotatesSameKidWithoutRetainingOldKey() async throws {
        let key = P256.Signing.PrivateKey(), next = P256.Signing.PrivateKey(), clock = TrustTestClock(now)
        let http = TrustHTTPFixture(try jwks(key))
        let trust = try RemoteCloudTrust(issuer: URL(string: "https://cloud.example.test")!, serverId: server, http: http, clock: { clock.now() })
        let cloud = try await trust.start()
        _ = try await cloud.verifyBindingIdentity(token(key), now: clock.now())
        await http.update(try jwks(next)); clock.advance(10)
        let refreshed = try await trust.refresh(); XCTAssertTrue(refreshed === cloud)
        _ = try await cloud.verifyBindingIdentity(token(next), now: clock.now())
        do { _ = try await cloud.verifyBindingIdentity(token(key), now: clock.now()); XCTFail("Retired key accepted") } catch {}
        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.url?.absoluteString, "https://cloud.example.test/.well-known/jwks.json")
            XCTAssertEqual(request.httpMethod, "GET"); XCTAssertNil(request.httpBody)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")); XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-cache")
        }
        await trust.stop()
        do { _ = try await cloud.verifyBindingIdentity(token(next), now: clock.now()); XCTFail("Stopped trust accepted") } catch {}
    }
    func testRefreshFailureNeverExtendsOldDeadline() async throws {
        let key = P256.Signing.PrivateKey(), clock = TrustTestClock(now), http = TrustHTTPFixture(try jwks(key))
        let trust = try RemoteCloudTrust(issuer: URL(string: "https://cloud.example.test")!, serverId: server, http: http, clock: { clock.now() })
        let cloud = try await trust.start(), deadline = await trust.expiresAt
        await http.update(Data("{}".utf8), status: 503); clock.advance(30)
        do { _ = try await trust.refresh(); XCTFail("Failure refreshed") } catch {}
        let expiry = await trust.expiresAt; XCTAssertEqual(expiry, deadline)
        let failed = await trust.lastRefreshFailed; XCTAssertTrue(failed)
        _ = try await cloud.verifyBindingIdentity(token(key), now: clock.now())
        clock.advance(31)
        do { _ = try await cloud.verifyBindingIdentity(token(key), now: clock.now()); XCTFail("Expired trust accepted") } catch {}
        await trust.stop()
    }
    func testStopDuringFetchCannotReinstallTrust() async throws {
        let key = P256.Signing.PrivateKey(), http = TrustHTTPFixture(try jwks(key)), date = now
        let trust = try RemoteCloudTrust(issuer: URL(string: "https://cloud.example.test")!, serverId: server, http: http, clock: { date })
        await http.block(); let task = Task { try await trust.start() }
        await http.waitForRequest(); await trust.stop(); await http.resume()
        do { _ = try await task.value; XCTFail("Late trust installed") } catch { XCTAssertEqual(error as? DesktopCloudError, .staleResponse) }
        let expiry = await trust.expiresAt; XCTAssertNil(expiry)
    }
    func testCacheAgeAndInvalidKeysetFailClosed() async throws {
        let key = P256.Signing.PrivateKey(), http = TrustHTTPFixture(try jwks(key)), date = now
        let trust = try RemoteCloudTrust(issuer: URL(string: "https://cloud.example.test")!, serverId: server, http: http, clock: { date })
        await http.update(try jwks(key), headers: ["cache-control": "public, max-age=60", "age": "40"])
        _ = try await trust.start()
        let expiry = await trust.expiresAt; XCTAssertEqual(expiry, now.addingTimeInterval(20))
        for headers in [["age": "300"], ["cache-control": "max-age=1, max-age=60"], ["age": "not-a-number"]] {
            await http.update(try jwks(key), headers: headers)
            do { _ = try await trust.refresh(); XCTFail("Bad cache headers accepted") } catch {}
        }
        await http.update(Data("{\"keys\":[]}".utf8))
        do { _ = try await trust.refresh(); XCTFail("Empty keys accepted") } catch {}
        let unchanged = await trust.expiresAt; XCTAssertEqual(unchanged, expiry)
        await trust.stop()
    }
    func testNetworkDelayDoesNotExtendDownloadedKeyTrust() async throws {
        let key = P256.Signing.PrivateKey(), clock = TrustTestClock(now), http = TrustHTTPFixture(try jwks(key))
        let trust = try RemoteCloudTrust(issuer: URL(string: "https://cloud.example.test")!, serverId: server, http: http, clock: { clock.now() })
        await http.block(); let task = Task { try await trust.start() }
        await http.waitForRequest(); clock.advance(25); await http.resume()
        _ = try await task.value
        let expiry = await trust.expiresAt; XCTAssertEqual(expiry, now.addingTimeInterval(60))
        await trust.stop()
    }
}
