import XCTest
import CryptoKit
@testable import Tomo

@MainActor
final class RemoteCloudGrantVerifierTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let server = "11111111-1111-4111-8111-111111111111"
    let issuer = "https://accounts.example.test"
    let kid = "test-key"

    func encoded(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    func jwk(_ key: P256.Signing.PrivateKey) -> [String: String] {
        let bytes = key.publicKey.x963Representation
        return ["kty": "EC", "crv": "P-256", "x": encoded(bytes.subdata(in: 1..<33)), "y": encoded(bytes.subdata(in: 33..<65)),
                "alg": "ES256", "use": "sig", "kid": kid]
    }
    func claims() -> [String: Any] {
        ["iss": issuer, "aud": server, "sub": "22222222-2222-4222-8222-222222222222", "deviceId": "33333333-3333-4333-8333-333333333333",
         "cnf": ["jkt": String(repeating: "A", count: 43)], "bindingId": "44444444-4444-4444-8444-444444444444", "bindingRevision": 1,
         "entitlementVersion": 0, "scope": "discovery session.read", "resources": [["kind": "runtime", "agentId": "chatgpt", "runtimeId": "runtime-1"]],
         "iat": Int(now.timeIntervalSince1970), "nbf": Int(now.timeIntervalSince1970), "exp": Int(now.timeIntervalSince1970) + 300,
         "jti": "55555555-5555-4555-8555-555555555555"]
    }
    func token(_ key: P256.Signing.PrivateKey, payload: [String: Any]? = nil, header: [String: String]? = nil) throws -> String {
        let h = try JSONSerialization.data(withJSONObject: header ?? ["alg": "ES256", "typ": "tomo-remote-grant+jwt", "kid": kid])
        let p = try JSONSerialization.data(withJSONObject: payload ?? claims())
        let input = encoded(h) + "." + encoded(p)
        return input + "." + encoded(try key.signature(for: Data(input.utf8)).rawRepresentation)
    }
    func verifier(_ key: P256.Signing.PrivateKey) async throws -> RemoteCloudGrantVerifier {
        try await RemoteCloudGrantVerifier.configured(jwks: JSONSerialization.data(withJSONObject: ["keys": [jwk(key)]]),
            issuer: issuer, serverId: server, trustedUntil: now.addingTimeInterval(60), now: now)
    }
    func denied(_ token: String, by verifier: RemoteCloudGrantVerifier, at date: Date? = nil) async {
        do { _ = try await verifier.verify(token, now: date ?? now); XCTFail("Unexpected grant acceptance") }
        catch { XCTAssertEqual(error as? RemoteAccessError, .unauthorized) }
    }
    func testValidSignatureAndBoundClaims() async throws {
        let key = P256.Signing.PrivateKey()
        let verifier = try await verifier(key)
        let result = try await verifier.verify(token(key), now: now)
        XCTAssertEqual(result.aud, server)
        XCTAssertEqual(result.scope, "discovery session.read")
        XCTAssertEqual(result.resources.first?.runtimeId, "runtime-1")
        XCTAssertEqual(result.exp - result.iat, 300)
    }
    func testUnknownKeysAlgorithmsTypesAndEmbeddedKeysDenied() async throws {
        let key = P256.Signing.PrivateKey(), verifier = try await verifier(key)
        await denied(try token(P256.Signing.PrivateKey()), by: verifier)
        for header in [
            ["alg": "ES256", "typ": "tomo-remote-grant+jwt", "kid": "unknown"],
            ["alg": "HS256", "typ": "tomo-remote-grant+jwt", "kid": kid],
            ["alg": "none", "typ": "tomo-remote-grant+jwt", "kid": kid],
            ["alg": "ES256", "typ": "tomo-binding-identity+jwt", "kid": kid],
            ["alg": "ES256", "typ": "tomo-remote-grant+jwt", "kid": kid, "jku": "https://attacker.example"]
        ] { await denied(try token(key, header: header), by: verifier) }
    }
    func testAudienceIssuerTimeAndTrustExpiryDenied() async throws {
        let key = P256.Signing.PrivateKey(), verifier = try await verifier(key)
        for change: [String: Any] in [["aud": UUID().uuidString], ["iss": "https://other.example"],
                                     ["exp": Int(now.timeIntervalSince1970)], ["exp": Int(now.timeIntervalSince1970) + 301],
                                     ["iat": Int(now.timeIntervalSince1970) + 1, "nbf": Int(now.timeIntervalSince1970) + 1]] {
            await denied(try token(key, payload: claims().merging(change) { _, new in new }), by: verifier)
        }
        await denied(try token(key), by: verifier, at: now.addingTimeInterval(60))
        await denied(String(repeating: "A", count: 32769), by: verifier)
        await denied("not.a.token", by: verifier)
    }
    func testUnsupportedScopesResourcesAndClaimTypesDenied() async throws {
        let key = P256.Signing.PrivateKey(), verifier = try await verifier(key)
        for change: [String: Any] in [["scope": "admin"], ["scope": "session.read session.read"], ["scope": " session.read"],
            ["scope": "server.identity"], ["bindingRevision": 0], ["entitlementVersion": -1], ["deviceId": "wrong"],
            ["resources": [["kind": "runtime", "agentId": "*", "runtimeId": "runtime-1"]]],
            ["resources": [["kind": "runtime", "agentId": "chatgpt", "runtimeId": "runtime-1", "path": "/private"]]],
            ["resources": [["kind": "workspace", "workspaceId": "workspace-1", "agentPolicy": "all"]]]] {
            await denied(try token(key, payload: claims().merging(change) { _, new in new }), by: verifier)
        }
        let basic = claims().merging(["scope": "server.identity", "resources": []]) { _, new in new }
        let result = try await verifier.verify(token(key, payload: basic), now: now)
        XCTAssertTrue(result.resources.isEmpty)
        let workspace = claims().merging(["resources": [["kind": "workspace", "workspaceId": "workspace-1", "agentPolicy": "registered"]]]) { _, new in new }
        let registered = try await verifier.verify(token(key, payload: workspace), now: now)
        XCTAssertEqual(registered.resources.first?.workspaceId, "workspace-1")
    }
    func testInvalidTrustConfigurationDenied() async throws {
        let key = P256.Signing.PrivateKey()
        for entries in [[jwk(key), jwk(key)], [jwk(key).merging(["d": "private"]) { _, new in new }],
                        [jwk(key).merging(["alg": "HS256"]) { _, new in new }]] {
            do {
                _ = try await RemoteCloudGrantVerifier.configured(jwks: JSONSerialization.data(withJSONObject: ["keys": entries]),
                    issuer: issuer, serverId: server, trustedUntil: now.addingTimeInterval(60), now: now)
                XCTFail("Unexpected trust acceptance")
            } catch { XCTAssertEqual(error as? RemoteAccessError, .invalidConfiguration) }
        }
    }
    func testRubyJwtSignedFixtureInteroperates() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "RemoteCloudGrantRuby", withExtension: "json"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let jwks = try JSONSerialization.data(withJSONObject: XCTUnwrap(fixture["jwks"]))
        let token = try XCTUnwrap(fixture["token"] as? String)
        let verifier = try await RemoteCloudGrantVerifier.configured(jwks: jwks, issuer: issuer,
            serverId: server, trustedUntil: now.addingTimeInterval(60), now: now)
        let result = try await verifier.verify(token, now: now)
        XCTAssertEqual(result.entitlementVersion, 7)
        XCTAssertEqual(result.bindingRevision, 1)
        XCTAssertEqual(result.resources.first?.agentId, "chatgpt")
    }

}
