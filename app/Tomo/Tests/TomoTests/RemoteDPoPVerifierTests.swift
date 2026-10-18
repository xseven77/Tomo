import XCTest
import CryptoKit
@testable import Tomo

@MainActor
final class RemoteDPoPVerifierTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let url = URL(string: "https://desktop.example/api/v1/remote/access/exchange")!
    let token = "synthetic-access-token"
    func encoded(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    func jwk(_ key: P256.Signing.PrivateKey) -> [String: String] {
        let data = key.publicKey.x963Representation
        return ["crv": "P-256", "kty": "EC", "x": encoded(data.subdata(in: 1..<33)), "y": encoded(data.subdata(in: 33..<65))]
    }
    func thumbprint(_ key: P256.Signing.PrivateKey) throws -> String {
        encoded(Data(SHA256.hash(data: try JSONSerialization.data(withJSONObject: jwk(key), options: [.sortedKeys, .withoutEscapingSlashes]))))
    }
    func proof(_ key: P256.Signing.PrivateKey, nonce: String, changes: [String: Any] = [:], header: [String: Any]? = nil) throws -> String {
        let claims: [String: Any] = ["jti": UUID().uuidString, "htm": "POST", "htu": url.absoluteString,
            "iat": Int(now.timeIntervalSince1970), "nonce": nonce, "ath": encoded(Data(SHA256.hash(data: Data(token.utf8))))]
        let h = try JSONSerialization.data(withJSONObject: header ?? ["alg": "ES256", "typ": "dpop+jwt", "jwk": jwk(key)])
        let p = try JSONSerialization.data(withJSONObject: claims.merging(changes) { _, new in new })
        let input = encoded(h) + "." + encoded(p)
        return input + "." + encoded(try key.signature(for: Data(input.utf8)).rawRepresentation)
    }
    func verify(_ proof: String, key: P256.Signing.PrivateKey, with verifier: RemoteDPoPVerifier,
                at date: Date? = nil, requestURL: URL? = nil, body: Data = Data()) async throws {
        try await verifier.verify(proof, thumbprint: thumbprint(key), token: token, method: "POST", url: requestURL ?? url, body: body, now: date ?? now)
    }
    func denied(_ proof: String, key: P256.Signing.PrivateKey, with verifier: RemoteDPoPVerifier,
                at date: Date? = nil, requestURL: URL? = nil) async {
        do { try await verify(proof, key: key, with: verifier, at: date, requestURL: requestURL); XCTFail("Unexpected DPoP acceptance") }
        catch { XCTAssertEqual(error as? RemoteAccessError, .unauthorized) }
    }
    func testHTTPProofKeepsSchemeAndNormalizesOnlyHTTPDefaultPort() async throws {
        let key = P256.Signing.PrivateKey(), verifier = RemoteDPoPVerifier()
        let nonce = try await verifier.challenge(thumbprint: thumbprint(key), expiresAt: now.addingTimeInterval(300), now: now)
        let target = URL(string: "http://desktop.example/api/v1/remote/access/exchange")!
        try await verify(proof(key, nonce: nonce, changes: ["htu": "http://DESKTOP.example:80/api/v1/remote/access/exchange", "tomo_bht": encoded(Data(SHA256.hash(data: Data()))) ]),
            key: key, with: verifier, requestURL: target)
        await denied(try proof(key, nonce: nonce, changes: ["htu": "https://desktop.example/api/v1/remote/access/exchange"]),
            key: key, with: verifier, requestURL: target)
        await denied(try proof(key, nonce: nonce, changes: ["htu": "http://desktop.example:443/api/v1/remote/access/exchange"]),
            key: key, with: verifier, requestURL: target)
    }

    func testPossessionNonceTokenAndReplay() async throws {
        let key = P256.Signing.PrivateKey(), verifier = RemoteDPoPVerifier()
        let nonce = try await verifier.challenge(thumbprint: thumbprint(key), expiresAt: now.addingTimeInterval(300), now: now)
        let first = try proof(key, nonce: nonce)
        try await verify(first, key: key, with: verifier)
        await denied(first, key: key, with: verifier)
        try await verify(proof(key, nonce: nonce), key: key, with: verifier)
    }
    func testHTTPRequiresExactBodyDigestBeforeConsumingProof() async throws {
        let key = P256.Signing.PrivateKey(), verifier = RemoteDPoPVerifier()
        let nonce = try await verifier.challenge(thumbprint: thumbprint(key), expiresAt: now.addingTimeInterval(300), now: now)
        let target = URL(string: "http://desktop.example/api/v1/remote/sessions/session/messages")!
        let original = Data("{\"text\":\"继续检查\"}".utf8)
        let changes: [String: Any] = ["htu": target.absoluteString, "tomo_bht": encoded(Data(SHA256.hash(data: original)))]
        let signed = try proof(key, nonce: nonce, changes: changes)
        for changed in [Data("{\"text\":\"中断检查\"}".utf8), Data("{ \"text\":\"继续检查\"}".utf8), Data()] {
            do { try await verify(signed, key: key, with: verifier, requestURL: target, body: changed); XCTFail("Altered body accepted") }
            catch { XCTAssertEqual(error as? RemoteAccessError, .unauthorized) }
        }
        try await verify(signed, key: key, with: verifier, requestURL: target, body: original)
        do { try await verify(signed, key: key, with: verifier, requestURL: target, body: original); XCTFail("Replay accepted") }
        catch { XCTAssertEqual(error as? RemoteAccessError, .unauthorized) }
        for digest in [nil, "bad", String(repeating: "A", count: 43)] as [String?] {
            var extra: [String: Any] = ["htu": target.absoluteString]
            if let digest { extra["tomo_bht"] = digest }
            do { try await verify(proof(key, nonce: nonce, changes: extra), key: key, with: verifier, requestURL: target, body: original); XCTFail("Missing or invalid body digest accepted") }
            catch { XCTAssertEqual(error as? RemoteAccessError, .unauthorized) }
        }
    }
    func testWrongDeviceMethodTargetTokenTimeAndNonceDenied() async throws {
        let key = P256.Signing.PrivateKey(), verifier = RemoteDPoPVerifier()
        let nonce = try await verifier.challenge(thumbprint: thumbprint(key), expiresAt: now.addingTimeInterval(300), now: now)
        for change: [String: Any] in [["htm": "GET"], ["htu": "https://other.example/api/v1/remote/access/exchange"],
            ["htu": "http://desktop.example/api/v1/remote/access/exchange"], ["ath": String(repeating: "A", count: 43)],
            ["iat": Int(now.timeIntervalSince1970) - 31], ["iat": Int(now.timeIntervalSince1970) + 31],
            ["nonce": String(repeating: "A", count: 43)], ["jti": ""], ["htu": url.absoluteString + "?query=1"]] {
            await denied(try proof(key, nonce: nonce, changes: change), key: key, with: verifier)
        }
        await denied(try proof(P256.Signing.PrivateKey(), nonce: nonce), key: key, with: verifier)
        try await verify(proof(key, nonce: nonce), key: key, with: verifier)
    }
    func testAlgorithmsPrivateKeysAndHeaderConfusionDenied() async throws {
        let key = P256.Signing.PrivateKey(), verifier = RemoteDPoPVerifier()
        let nonce = try await verifier.challenge(thumbprint: thumbprint(key), expiresAt: now.addingTimeInterval(300), now: now)
        for header: [String: Any] in [
            ["alg": "none", "typ": "dpop+jwt", "jwk": jwk(key)],
            ["alg": "HS256", "typ": "dpop+jwt", "jwk": jwk(key)],
            ["alg": "ES256", "typ": "tomo-remote-grant+jwt", "jwk": jwk(key)],
            ["alg": "ES256", "typ": "dpop+jwt", "jwk": jwk(key).merging(["d": "private"]) { _, new in new }],
            ["alg": "ES256", "typ": "dpop+jwt", "jwk": jwk(key), "jku": "https://other.example"]] {
            await denied(try proof(key, nonce: nonce, header: header), key: key, with: verifier)
        }
    }
    func testNonceExpiresAndRevocationDoesNotAllowReusingProof() async throws {
        let key = P256.Signing.PrivateKey(), verifier = RemoteDPoPVerifier()
        let nonce = try await verifier.challenge(thumbprint: thumbprint(key), expiresAt: now.addingTimeInterval(20), now: now)
        let old = try proof(key, nonce: nonce)
        await denied(try proof(key, nonce: nonce, changes: ["iat": Int(now.timeIntervalSince1970) + 20]), key: key, with: verifier, at: now.addingTimeInterval(20))
        await verifier.revoke(thumbprint: try thumbprint(key))
        await denied(old, key: key, with: verifier)
    }
    func testQueryIsNotPartOfTargetAndSchemeHostDefaultPortAreNormalized() async throws {
        let key = P256.Signing.PrivateKey(), verifier = RemoteDPoPVerifier()
        let nonce = try await verifier.challenge(thumbprint: thumbprint(key), expiresAt: now.addingTimeInterval(300), now: now)
        try await verify(proof(key, nonce: nonce, changes: ["htu": "https://DESKTOP.example:443/api/v1/remote/access/exchange"]), key: key, with: verifier,
            requestURL: URL(string: url.absoluteString + "?account=ignored")!)
    }
    func testConcurrentCopiesOnlyOneSucceeds() async throws {
        let key = P256.Signing.PrivateKey(), verifier = RemoteDPoPVerifier()
        let thumb = try thumbprint(key)
        let nonce = try await verifier.challenge(thumbprint: thumb, expiresAt: now.addingTimeInterval(300), now: now)
        let value = try proof(key, nonce: nonce)
        let target = url, timestamp = now, access = token
        let accepted = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    do { try await verifier.verify(value, thumbprint: thumb, token: access, method: "POST", url: target, now: timestamp); return true }
                    catch { return false }
                }
            }
            var count = 0
            for await success in group { if success { count += 1 } }
            return count
        }
        XCTAssertEqual(accepted, 1)
    }
    func testInvalidSignatureDoesNotPoisonReplayAndOversizedProofIsRejected() async throws {
        let key = P256.Signing.PrivateKey(), verifier = RemoteDPoPVerifier()
        let nonce = try await verifier.challenge(thumbprint: thumbprint(key), expiresAt: now.addingTimeInterval(300), now: now)
        let jti = UUID().uuidString
        let bad = try proof(P256.Signing.PrivateKey(), nonce: nonce, changes: ["jti": jti],
            header: ["alg": "ES256", "typ": "dpop+jwt", "jwk": jwk(key)])
        await denied(bad, key: key, with: verifier)
        await denied(String(repeating: "A", count: 8193), key: key, with: verifier)
        try await verify(proof(key, nonce: nonce, changes: ["jti": jti]), key: key, with: verifier)
    }
    func testNonceSaturationFailsClosedWithoutEvictingExistingChallenges() async throws {
        let key = P256.Signing.PrivateKey(), verifier = RemoteDPoPVerifier()
        let thumb = try thumbprint(key)
        let first = try await verifier.challenge(thumbprint: thumb, expiresAt: now.addingTimeInterval(300), now: now)
        for _ in 1..<1024 { _ = try await verifier.challenge(thumbprint: thumb, expiresAt: now.addingTimeInterval(300), now: now) }
        do {
            _ = try await verifier.challenge(thumbprint: thumb, expiresAt: now.addingTimeInterval(300), now: now)
            XCTFail("Unexpected nonce overflow acceptance")
        } catch { XCTAssertEqual(error as? RemoteAccessError, .unavailable) }
        try await verify(proof(key, nonce: first), key: key, with: verifier)
        _ = try await verifier.challenge(thumbprint: thumb, expiresAt: now.addingTimeInterval(120), now: now.addingTimeInterval(61))
    }

}
