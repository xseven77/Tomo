import XCTest
import CryptoKit
@testable import Tomo

@MainActor final class RemoteLocalGrantAuthorityTests: XCTestCase {
    private let device = "33333333-3333-4333-8333-333333333333"
    private let now = Date(timeIntervalSince1970: 1_900_000_000)
    private struct Setup {
        let key: P256.Signing.PrivateKey, deviceKey: P256.Signing.PrivateKey
        let authority: RemoteLocalGrantAuthority, ledger: RemoteAuthorizationLedger
        let approval: RemoteBindingApproval, router: RemoteBindingRouter
        let root: URL
    }
    private func encoded(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private func jwk(_ key: P256.Signing.PrivateKey) -> [String: String] {
        let bytes = key.publicKey.x963Representation
        return ["kty": "EC", "crv": "P-256", "x": encoded(bytes.subdata(in: 1..<33)), "y": encoded(bytes.subdata(in: 33..<65))]
    }
    private func setup() throws -> Setup {
        let key = P256.Signing.PrivateKey(), identity = try RemoteLocalGrantAuthority.identity(for: key.publicKey)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tomo-local-authority-\(UUID())")
        let ledger = try RemoteAuthorizationLedger(databaseURL: root.appendingPathComponent("acl.sqlite"),
            serverId: identity.serverId.uuidString.lowercased())
        let authority = try RemoteLocalGrantAuthority(key: key, ledger: ledger)
        let approval = try RemoteBindingApproval(cloud: authority, ledger: ledger,
            serverId: identity.serverId.uuidString.lowercased(), issuer: identity.issuer,
            registeredKey: key, registeredThumbprint: identity.thumbprint)
        let router = try RemoteBindingRouter(endpoint: URL(string: "http://localhost:58352")!, cloud: authority,
            proof: RemoteDPoPVerifier(), approval: approval)
        return .init(key: key, deviceKey: P256.Signing.PrivateKey(), authority: authority,
            ledger: ledger, approval: approval, router: router, root: root)
    }
    private func assertion(_ setup: Setup) async throws -> String {
        try await setup.authority.deviceAssertion(JSONSerialization.data(withJSONObject: [
            "deviceId": device, "deviceName": "本地 iPhone", "publicKey": jwk(setup.deviceKey)]), now: now)
    }
    private func resource() throws -> [RemoteCloudGrantVerifier.Resource] {
        try JSONDecoder().decode([RemoteCloudGrantVerifier.Resource].self,
            from: Data("[{\"kind\":\"runtime\",\"agentId\":\"agent.chatgpt\",\"runtimeId\":\"runtime-1\"}]".utf8))
    }
    private func approve(_ setup: Setup, assertion: String, version: Int = 0) async throws {
        let pending = try await setup.approval.prepare(assertion: assertion, now: now)
        _ = try await setup.approval.approve(id: pending.id, scopes: ["discovery", "session.read"],
            resources: resource(), expectedLocalVersion: version, now: now)
    }
    private func denied(_ work: () async throws -> Void) async {
        do { try await work(); XCTFail("Unexpected local access") } catch {}
    }
    func testPublicIdentityStableAndSeparatedFromOtherServer() throws {
        let key = P256.Signing.PrivateKey()
        let first = try RemoteLocalGrantAuthority.identity(for: key.publicKey)
        XCTAssertEqual(first, try RemoteLocalGrantAuthority.identity(for: key.publicKey))
        XCTAssertNotEqual(first, try RemoteLocalGrantAuthority.identity(for: P256.Signing.PrivateKey().publicKey))
        XCTAssertNotEqual(first.serverId, first.ownerId)
    }
    func testIdenticalReapprovalInAnotherLedgerCannotReviveAnOldGrant() async throws {
        let s = try setup(); defer {try? FileManager.default.removeItem(at: s.root)}
        let assertion = try await assertion(s), claims = try await s.authority.verifyBindingIdentity(assertion, now: now)
        try await approve(s, assertion: assertion)
        let oldGrant = try await s.authority.issueBoundDevice(claims, now: now)
        let binding = try await s.ledger.ownerBinding(userId: claims.sub, deviceId: device)
        let previous = try XCTUnwrap(binding)
        let url = s.root.appendingPathComponent("rotated/acl.sqlite")
        let next = try RemoteAuthorizationLedger(databaseURL: url, serverId: claims.aud)
        _ = try await next.approve(.init(userId: previous.userId, deviceId: previous.deviceId,
            thumbprint: previous.thumbprint, bindingRevision: previous.bindingRevision,
            cloudBindingId: nil, localVersion: 0, scopes: previous.scopes, resources: previous.resources, revoked: false), expectedLocalVersion: 0)
        let authority = try RemoteLocalGrantAuthority(key: s.key, ledger: next)
        await denied {_ = try await authority.verify(oldGrant, now: self.now)}
        let fresh = try await authority.issue(deviceId: device, thumbprint: previous.thumbprint, expectedLocalVersion: 1, now: now)
        let reopened = try RemoteAuthorizationLedger(databaseURL: url, serverId: claims.aud)
        let restartedAuthority = try RemoteLocalGrantAuthority(key: s.key, ledger: reopened)
        _ = try await restartedAuthority.verify(fresh, now: now)
        await denied {_ = try await s.authority.verify(fresh, now: self.now)}
    }
    func testDeviceAssertionDoesNotGrantAccessAndOwnerApprovalLimitsGrant() async throws {
        let s = try setup(); defer { try? FileManager.default.removeItem(at: s.root) }
        let assertion = try await assertion(s), claims = try await s.authority.verifyBindingIdentity(assertion, now: now)
        XCTAssertEqual(claims.userEmail, "本地设备")
        await denied { _ = try await s.authority.issueBoundDevice(claims, now: self.now) }
        try await approve(s, assertion: assertion)
        let grant = try await s.authority.issueBoundDevice(claims, now: now)
        let access = try await s.authority.verify(grant, now: now)
        XCTAssertEqual(access.scope, "discovery session.read")
        XCTAssertEqual(access.resources, try resource())
        XCTAssertEqual(access.entitlementVersion, 1)
        XCTAssertEqual(access.exp - access.iat, 300)
        if let path = ProcessInfo.processInfo.environment["TOMO_LOCAL_AUTHORITY_INTEROP_OUTPUT"] {
            let fixture: [String: Any] = ["kind": "synthetic-local-authority-interop",
                "publicKeyPem": s.authority.identity.publicKeyPem, "serverId": claims.aud,
                "ownerId": claims.sub, "deviceId": claims.deviceId, "deviceThumbprint": claims.cnf.jkt,
                "now": Int(now.timeIntervalSince1970), "assertion": assertion, "grant": grant]
            try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys, .prettyPrinted]).write(to: URL(fileURLWithPath: path))
        }
        await denied { _ = try await s.authority.verify(grant, now: self.now.addingTimeInterval(300)) }
        await denied { _ = try await s.authority.verifyBindingIdentity(grant, now: self.now) }
        await denied { _ = try await s.authority.verify(assertion, now: self.now) }
    }
    func testACLChangeAndPersistentRevocationInvalidateOldGrants() async throws {
        let s = try setup(); defer { try? FileManager.default.removeItem(at: s.root) }
        let assertion = try await assertion(s), claims = try await s.authority.verifyBindingIdentity(assertion, now: now)
        try await approve(s, assertion: assertion)
        let oldGrant = try await s.authority.issueBoundDevice(claims, now: now)
        let secondAssertion = try await self.assertion(s)
        try await approve(s, assertion: secondAssertion, version: 1)
        await denied { _ = try await s.authority.verify(oldGrant, now: self.now) }
        let fresh = try await s.authority.issueBoundDevice(claims, now: now)
        _ = try await s.authority.verify(fresh, now: now)
        _ = try await s.ledger.revoke(userId: claims.sub, deviceId: device, expectedLocalVersion: 2)
        let restarted = try RemoteLocalGrantAuthority(key: s.key, ledger:
            RemoteAuthorizationLedger(databaseURL: s.root.appendingPathComponent("acl.sqlite"), serverId: claims.aud))
        await denied { _ = try await restarted.verify(fresh, now: self.now) }
        await denied { _ = try await restarted.issueBoundDevice(claims, now: self.now) }
        let rebind = try await self.assertion(s), revised = try await s.authority.verifyBindingIdentity(rebind, now: now)
        XCTAssertEqual(revised.bindingRevision, claims.bindingRevision + 1)
        try await approve(s, assertion: rebind, version: 3)
        let reissued = try await s.authority.issueBoundDevice(revised, now: now)
        _ = try await s.authority.verify(reissued, now: now)
        await denied { _ = try await s.authority.issueBoundDevice(claims, now: self.now) }
    }
    func testRequestedPermissionsCanNarrowButCannotExpandAndCloudRejectsLocalType() async throws {
        let s = try setup(); defer { try? FileManager.default.removeItem(at: s.root) }
        let assertion = try await assertion(s), claims = try await s.authority.verifyBindingIdentity(assertion, now: now)
        try await approve(s, assertion: assertion)
        let narrowed = try await s.authority.issueBoundDevice(claims, scopes: ["session.read"], resources: resource(), now: now)
        let verified = try await s.authority.verify(narrowed, now: now)
        XCTAssertEqual(verified.scope, "session.read")
        let upperBound = try await s.authority.issueBoundDevice(claims, scopes: ["session.read", "session.write"], resources: resource(), now: now)
        let intersected = try await s.authority.verify(upperBound, now: now)
        XCTAssertEqual(intersected.scope, "session.read")
        await denied { _ = try await s.authority.issueBoundDevice(claims, scopes: ["session.write"], resources: self.resource(), now: self.now) }
        await denied { _ = try await s.authority.issueBoundDevice(claims, scopes: [], resources: self.resource(), now: self.now) }
        await denied { _ = try await s.authority.issueBoundDevice(claims, resources: self.resource() + self.resource(), now: self.now) }
        let jwk = jwk(s.key).merging(["kid": s.authority.identity.thumbprint, "alg": "ES256", "use": "sig"]) { _, value in value }
        let cloud = try await RemoteCloudGrantVerifier.configured(jwks: JSONSerialization.data(withJSONObject: ["keys": [jwk]]),
            issuer: "https://cloud.example.test", serverId: claims.aud, trustedUntil: now.addingTimeInterval(60), now: now)
        await denied { _ = try await cloud.verify(narrowed, now: self.now) }
    }
    func testUnknownDeviceWrongKeyMalformedBootstrapAndShutdownRejected() async throws {
        let s = try setup(); defer { try? FileManager.default.removeItem(at: s.root) }
        let assertion = try await assertion(s), claims = try await s.authority.verifyBindingIdentity(assertion, now: now)
        try await approve(s, assertion: assertion)
        await denied { _ = try await s.authority.issue(deviceId: UUID().uuidString, thumbprint: claims.cnf.jkt, expectedLocalVersion: 1, now: self.now) }
        await denied { _ = try await s.authority.issue(deviceId: self.device, thumbprint: String(repeating: "A", count: 43), expectedLocalVersion: 1, now: self.now) }
        let changed = try JSONSerialization.data(withJSONObject: ["deviceId": device, "deviceName": "iPhone", "publicKey": jwk(P256.Signing.PrivateKey())])
        await denied { _ = try await s.authority.deviceAssertion(changed, now: self.now) }
        for data in [Data("{}".utf8), try JSONSerialization.data(withJSONObject: ["deviceId": device, "deviceName": "iPhone", "publicKey": jwk(s.deviceKey), "approved": true])] {
            await denied { _ = try await s.authority.deviceAssertion(data, now: self.now) }
        }
        let grant = try await s.authority.issueBoundDevice(claims, now: now)
        let altered = String(grant.dropLast()) + (grant.last == "A" ? "B" : "A")
        await denied { _ = try await s.authority.verify(altered, now: self.now) }
        await s.authority.shutdown()
        await denied { _ = try await s.authority.verify(grant, now: self.now) }
    }
    func testLocalGrantUsesSameExchangeDeviceProofAndRevocationChecks() async throws {
        let s = try setup(); defer { try? FileManager.default.removeItem(at: s.root) }
        let assertion = try await assertion(s), claims = try await s.authority.verifyBindingIdentity(assertion, now: now)
        try await approve(s, assertion: assertion)
        let grant = try await s.authority.issueBoundDevice(claims, now: now)
        let exchange = try RemoteGrantExchange(cloud: s.authority, ledger: s.ledger, proof: RemoteDPoPVerifier(),
            endpoint: URL(string: "http://localhost:58352")!, resolve: { _, actions, _ in
                [.init(agentId: "agent.chatgpt", runtimeId: "runtime-1", sessionId: nil, actions: actions)]
            })
        let nonce = try await exchange.exchangeNonce(grant: grant, now: now)
        let body = Data("{\"真实正文\":\"本地测试\"}".utf8)
        let payload: [String: Any] = ["jti": UUID().uuidString, "htm": "POST",
            "htu": "http://localhost:58352/api/v1/remote/access/exchange", "iat": Int(now.timeIntervalSince1970),
            "nonce": nonce, "ath": encoded(Data(SHA256.hash(data: Data(grant.utf8)))),
            "tomo_bht": encoded(Data(SHA256.hash(data: body)))]
        let input = try encoded(JSONSerialization.data(withJSONObject: ["alg": "ES256", "typ": "dpop+jwt", "jwk": jwk(s.deviceKey)]))
            + "." + encoded(JSONSerialization.data(withJSONObject: payload))
        let dpop = input + "." + encoded(try s.deviceKey.signature(for: Data(input.utf8)).rawRepresentation)
        await denied { _ = try await exchange.exchange(grant: grant, dpop: dpop, client: .v1, body: Data("altered".utf8), now: self.now) }
        let access = try await exchange.exchange(grant: grant, dpop: dpop, client: .v1, body: body, now: now)
        XCTAssertTrue(access.principal.permits(agentId: "agent.chatgpt", runtimeId: "runtime-1", sessionId: "session-1", action: .readHistory))
        XCTAssertFalse(access.principal.permits(agentId: "agent.chatgpt", runtimeId: "runtime-1", sessionId: "session-1", action: .sendMessage))
        _ = try await s.ledger.revoke(userId: claims.sub, deviceId: device, expectedLocalVersion: 1)
        await denied { try await exchange.validate(access.principal, now: self.now) }
    }
}
