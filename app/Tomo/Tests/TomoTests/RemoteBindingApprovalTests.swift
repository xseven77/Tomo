import XCTest
import CryptoKit
@testable import Tomo

@MainActor
final class RemoteBindingApprovalTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let server = "11111111-1111-4111-8111-111111111111", issuer = "https://accounts.example.test"
    func encoded(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    func claims() -> [String: Any] {
        ["iss": issuer, "aud": server, "sub": "22222222-2222-4222-8222-222222222222",
         "deviceId": "33333333-3333-4333-8333-333333333333", "cnf": ["jkt": String(repeating: "A", count: 43)],
         "deviceName": "iPhone", "userEmail": "a@example.test", "challengeId": "44444444-4444-4444-8444-444444444444",
         "nonce": String(repeating: "A", count: 43), "bindingRevision": 1, "scope": "server.bind",
         "iat": Int(now.timeIntervalSince1970), "nbf": Int(now.timeIntervalSince1970), "exp": Int(now.timeIntervalSince1970) + 300,
         "jti": "44444444-4444-4444-8444-444444444444"]
    }
    func token(_ key: P256.Signing.PrivateKey, changes: [String: Any] = [:], header: [String: String]? = nil) throws -> String {
        let h = try JSONSerialization.data(withJSONObject: header ?? ["alg": "ES256", "typ": "tomo-binding-identity+jwt", "kid": "cloud"])
        let p = try JSONSerialization.data(withJSONObject: claims().merging(changes) { _, new in new })
        let input = encoded(h) + "." + encoded(p)
        return input + "." + encoded(try key.signature(for: Data(input.utf8)).rawRepresentation)
    }
    func setup(at date: Date? = nil) async throws -> (RemoteBindingApproval, RemoteCloudGrantVerifier, P256.Signing.PrivateKey, P256.Signing.PrivateKey, URL) {
        let date = date ?? now
        let cloudKey = P256.Signing.PrivateKey(), desktopKey = P256.Signing.PrivateKey(), bytes = cloudKey.publicKey.x963Representation
        let jwk = ["kty": "EC", "crv": "P-256", "x": encoded(bytes.subdata(in: 1..<33)), "y": encoded(bytes.subdata(in: 33..<65)), "alg": "ES256", "use": "sig", "kid": "cloud"]
        let cloud = try await RemoteCloudGrantVerifier.configured(jwks: JSONSerialization.data(withJSONObject: ["keys": [jwk]]),
            issuer: issuer, serverId: server, trustedUntil: date.addingTimeInterval(300), now: date)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ledger = try RemoteAuthorizationLedger(databaseURL: directory.appendingPathComponent("ledger.sqlite"), serverId: server)
        let approval = try RemoteBindingApproval(cloud: cloud, ledger: ledger, serverId: server, issuer: issuer,
            registeredKey: desktopKey, registeredThumbprint: RemoteBindingApproval.thumbprint(desktopKey.publicKey))
        return (approval, cloud, cloudKey, desktopKey, directory)
    }
    func resources() throws -> [RemoteCloudGrantVerifier.Resource] {
        try JSONDecoder().decode([RemoteCloudGrantVerifier.Resource].self, from: Data("[{\"kind\":\"runtime\",\"agentId\":\"chatgpt\",\"runtimeId\":\"runtime-1\"}]".utf8))
    }
    func deviceProof(_ key: P256.Signing.PrivateKey, token: String, nonce: String, method: String, url: URL, now: Date) throws -> String {
        let bytes = key.publicKey.x963Representation
        let jwk = ["crv": "P-256", "kty": "EC", "x": encoded(bytes.subdata(in: 1..<33)), "y": encoded(bytes.subdata(in: 33..<65))]
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "typ": "dpop+jwt", "jwk": jwk])
        let payload: [String: Any] = ["jti": UUID().uuidString, "htm": method, "htu": url.absoluteString,
            "iat": Int(now.timeIntervalSince1970), "nonce": nonce, "ath": encoded(Data(SHA256.hash(data: Data(token.utf8))))]
        let input = encoded(header) + "." + encoded(try JSONSerialization.data(withJSONObject: payload))
        return input + "." + encoded(try key.signature(for: Data(input.utf8)).rawRepresentation)
    }
    func testPairingRouterRequiresPossessionAndReturnsOnlyOwnerApprovedReceipt() async throws {
        let (approval, cloud, key, _, directory) = try await setup(); defer { try? FileManager.default.removeItem(at: directory) }
        let device = P256.Signing.PrivateKey(), endpoint = URL(string: "https://desktop.example.test")!
        let assertion = try token(key, changes: ["cnf": ["jkt": RemoteBindingApproval.thumbprint(device.publicKey)]])
        let router = try RemoteBindingRouter(endpoint: endpoint, cloud: cloud, proof: RemoteDPoPVerifier(), approval: approval)
        let body = try JSONSerialization.data(withJSONObject: ["identityAssertion": assertion])
        func request(_ path: String, _ method: String = "POST", proof: String? = nil, extra: [(String, String)] = []) -> RemoteProductionAccessRouter.Request {
            var headers = [("Content-Type", "application/json")] + extra
            if let proof { headers.append(("DPoP", proof)) }
            if method == "GET" { headers.append(("Authorization", "DPoP " + assertion)) }
            return .init(method: method, path: path, query: [:], headers: headers, body: method == "GET" ? Data() : body)
        }
        let root = RemoteBindingRouter.root
        let challenge = await router.handle(request(root + "/nonce"), now: now)
        XCTAssertEqual(challenge.status, 200); let nonce = try XCTUnwrap(challenge.headers["DPoP-Nonce"])
        let missing = await router.handle(request(root + "/requests"), now: now); XCTAssertEqual(missing.status, 401)
        let firstProof = try deviceProof(device, token: assertion, nonce: nonce, method: "POST", url: endpoint.appendingPathComponent("api/v1/remote/bindings/requests"), now: now)
        let submission = await router.handle(request(root + "/requests", proof: firstProof), now: now)
        XCTAssertEqual(submission.status, 202)
        let submitted = try XCTUnwrap(JSONSerialization.jsonObject(with: submission.body) as? [String: String])
        let id = try XCTUnwrap(submitted["requestId"]), uuid = try XCTUnwrap(UUID(uuidString: id))
        XCTAssertNil(submitted["receipt"])
        let replay = await router.handle(request(root + "/requests", proof: firstProof), now: now); XCTAssertEqual(replay.status, 401)
        let path = root + "/requests/" + id
        func getProof(_ signer: P256.Signing.PrivateKey) throws -> String {
            try deviceProof(signer, token: assertion, nonce: nonce, method: "GET", url: URL(string: path, relativeTo: endpoint)!.absoluteURL, now: now)
        }
        let wrong = await router.handle(request(path, "GET", proof: try getProof(P256.Signing.PrivateKey())), now: now); XCTAssertEqual(wrong.status, 401)
        let pending = await router.handle(request(path, "GET", proof: try getProof(device)), now: now)
        XCTAssertEqual(pending.status, 200); XCTAssertFalse(String(decoding: pending.body, as: UTF8.self).contains("receipt"))
        let receipt = try await approval.approve(id: uuid, scopes: ["session.read"], resources: resources(), expectedLocalVersion: 0, now: now)
        let result = await router.handle(request(path, "GET", proof: try getProof(device)), now: now)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: result.body) as? [String: String])
        XCTAssertEqual(result.status, 200); XCTAssertEqual(value["receipt"], receipt)
        let origin = await router.handle(request(root + "/nonce", extra: [("Origin", "https://website.test")]), now: now); XCTAssertEqual(origin.status, 403)
        let duplicate = await router.handle(request(root + "/nonce", extra: [("Content-Type", "application/json")]), now: now); XCTAssertEqual(duplicate.status, 400)
        let unwanted = await router.handle(.init(method: "POST", path: root + "/requests", query: [:],
            headers: [("Content-Type", "application/json")],
            body: try JSONSerialization.data(withJSONObject: ["identityAssertion": assertion, "scopes": ["session.write"]])), now: now)
        XCTAssertEqual(unwanted.status, 400)
        let query = await router.handle(.init(method: "POST", path: root + "/nonce", query: ["token": assertion],
            headers: [("Content-Type", "application/json")], body: body), now: now); XCTAssertEqual(query.status, 400)
        let otherPath = root + "/requests/" + UUID().uuidString.lowercased()
        let otherProof = try deviceProof(device, token: assertion, nonce: nonce, method: "GET", url: URL(string: otherPath, relativeTo: endpoint)!.absoluteURL, now: now)
        let other = await router.handle(request(otherPath, "GET", proof: otherProof), now: now); XCTAssertEqual(other.status, 403)
    }
    func testRealHTTPSPairingListenerWaitsForLocalApprovalAndEnforcesDeviceProof() async throws {
        let tls = try RemoteTLSFixture(); defer { tls.remove() }
        let date = Date()
        let (approval, cloud, key, _, directory) = try await setup(at: date); defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = URL(string: "https://127.0.0.1:\(try RemoteTLSFixture.freePort())")!, device = P256.Signing.PrivateKey()
        let assertion = try token(key, changes: ["cnf": ["jkt": RemoteBindingApproval.thumbprint(device.publicKey)],
            "iat": Int(date.timeIntervalSince1970), "nbf": Int(date.timeIntervalSince1970), "exp": Int(date.timeIntervalSince1970) + 300])
        let ledger = try RemoteAuthorizationLedger(databaseURL: directory.appendingPathComponent("ledger.sqlite"), serverId: server)
        let exchange = try RemoteGrantExchange(cloud: cloud, ledger: ledger, proof: RemoteDPoPVerifier(), endpoint: endpoint, resources: RemoteRuntimeScopeRegistry())
        let router = try RemoteBindingRouter(endpoint: endpoint, cloud: cloud, proof: RemoteDPoPVerifier(), approval: approval)
        let listener = try RemoteHTTPSListener(identity: tls.identity, router: .cloudVerified(exchange: exchange, cloud: cloud),
            bindHost: "127.0.0.1", bindingRouter: router) { _, _ in throw RemoteReadError.notImplemented }
        try await listener.start()
        let client = tls.session(); defer { client.invalidateAndCancel() }
        do {
            func call(_ path: String, method: String = "POST", proof: String? = nil, origin: String? = nil) async throws -> (Data, HTTPURLResponse) {
                var request = URLRequest(url: URL(string: path, relativeTo: endpoint)!.absoluteURL)
                request.httpMethod = method; request.timeoutInterval = 5
                if method == "POST" {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: ["identityAssertion": assertion])
                } else { request.setValue("DPoP " + assertion, forHTTPHeaderField: "Authorization") }
                if let proof { request.setValue(proof, forHTTPHeaderField: "DPoP") }
                if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
                let (data, response) = try await client.data(for: request)
                return (data, try XCTUnwrap(response as? HTTPURLResponse))
            }
            let root = RemoteBindingRouter.root
            let (_, nonceResponse) = try await call(root + "/nonce")
            XCTAssertEqual(nonceResponse.statusCode, 200)
            let nonce = try XCTUnwrap(nonceResponse.value(forHTTPHeaderField: "DPoP-Nonce"))
            func signed(_ path: String, method: String, signer: P256.Signing.PrivateKey? = nil) throws -> String {
                try deviceProof(signer ?? device, token: assertion, nonce: nonce, method: method,
                    url: URL(string: path, relativeTo: endpoint)!.absoluteURL, now: Date())
            }
            let (data, submitted) = try await call(root + "/requests", proof: signed(root + "/requests", method: "POST"))
            XCTAssertEqual(submitted.statusCode, 202)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
            let id = try XCTUnwrap(json["requestId"]), path = root + "/requests/" + id
            let (pending, pendingResponse) = try await call(path, method: "GET", proof: signed(path, method: "GET"))
            XCTAssertEqual(pendingResponse.statusCode, 200); XCTAssertFalse(String(decoding: pending, as: UTF8.self).contains("receipt"))
            let (_, denied) = try await call(path, method: "GET", proof: signed(path, method: "GET", signer: P256.Signing.PrivateKey()))
            XCTAssertEqual(denied.statusCode, 401)
            let receipt = try await approval.approve(id: XCTUnwrap(UUID(uuidString: id)), scopes: ["session.read"], resources: resources(), expectedLocalVersion: 0)
            let (approved, approvedResponse) = try await call(path, method: "GET", proof: signed(path, method: "GET"))
            XCTAssertEqual(approvedResponse.statusCode, 200)
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with: approved) as? [String: String])
            XCTAssertEqual(result["receipt"], receipt)
            let (_, browser) = try await call(root + "/nonce", origin: "https://website.test")
            XCTAssertEqual(browser.statusCode, 403)
        } catch { await listener.stop(); throw error }
        await listener.stop()
    }
    func testCloudIdentityProducesOwnerSelectedSignedReceiptAndExactRetry() async throws {
        let (approval, _, cloudKey, desktopKey, directory) = try await setup(); defer { try? FileManager.default.removeItem(at: directory) }
        let assertion = try token(cloudKey), pending = try await approval.prepare(assertion: assertion, now: now)
        XCTAssertEqual(pending.deviceName, "iPhone"); XCTAssertEqual(pending.userEmail, "a@example.test")
        let duplicate = try await approval.prepare(assertion: assertion, now: now); XCTAssertEqual(duplicate.id, pending.id)
        let receipt = try await approval.approve(id: pending.id, scopes: ["discovery", "session.read"], resources: resources(), expectedLocalVersion: 0, now: now)
        let parts = receipt.split(separator: ".").map(String.init)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: XCTUnwrap(RemoteJWTCodec.base64URL(parts[2])))
        XCTAssertTrue(desktopKey.publicKey.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8)))
        let header = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(RemoteJWTCodec.base64URL(parts[0]))) as? [String: String])
        XCTAssertEqual(header["typ"], "tomo-binding-receipt+jwt"); XCTAssertEqual(header["kid"], try RemoteBindingApproval.thumbprint(desktopKey.publicKey))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(RemoteJWTCodec.base64URL(parts[1]))) as? [String: Any])
        XCTAssertEqual(payload["iss"] as? String, server); XCTAssertEqual(payload["aud"] as? String, issuer)
        XCTAssertEqual(payload["challengeId"] as? String, pending.id.uuidString.lowercased())
        XCTAssertEqual(payload["scopes"] as? [String], ["discovery", "session.read"])
        // Explicit fixture export for cross-language integration; no private key.
        if let path = ProcessInfo.processInfo.environment["TOMO_BINDING_INTEROP_OUTPUT"], path.hasPrefix("/private/tmp/") {
            let fixture: [String: Any] = ["receipt": receipt, "publicKeyPem": desktopKey.publicKey.pemRepresentation,
                "thumbprint": try RemoteBindingApproval.thumbprint(desktopKey.publicKey), "claims": payload]
            try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        let retry = try await approval.approve(id: pending.id, scopes: ["discovery", "session.read"], resources: resources(), expectedLocalVersion: 0, now: now)
        XCTAssertEqual(retry, receipt)
        do { _ = try await approval.approve(id: pending.id, scopes: ["session.write"], resources: resources(), expectedLocalVersion: 0, now: now); XCTFail() }
        catch { XCTAssertEqual(error as? RemoteAccessError, .forbidden) }
        // Persisted ACL is present after receipt generation; stale owner CAS fails.
        let ledger = try RemoteAuthorizationLedger(databaseURL: directory.appendingPathComponent("ledger.sqlite"), serverId: server)
        do { _ = try await ledger.approve(.init(userId: pending.userId, deviceId: pending.deviceId, thumbprint: pending.thumbprint,
            bindingRevision: 1, cloudBindingId: nil, localVersion: 0, scopes: ["session.read"], resources: resources(), revoked: false), expectedLocalVersion: 0); XCTFail() }
        catch { XCTAssertEqual(error as? RemoteAccessError, .forbidden) }
    }
    func testWrongSignatureTypeIdentityNonceTimeAndExtraFieldsCannotPrepare() async throws {
        let (approval, _, key, _, directory) = try await setup(); defer { try? FileManager.default.removeItem(at: directory) }
        for changes: [String: Any] in [["aud": UUID().uuidString], ["iss": "https://other.test"], ["nonce": "bad"], ["scope": "session.write"],
            ["jti": UUID().uuidString], ["deviceName": "bad\nname"], ["exp": Int(now.timeIntervalSince1970) + 301], ["unexpected": true], ["cnf": ["jkt": String(repeating: "A", count: 43), "extra": "bad"]]] {
            do { _ = try await approval.prepare(assertion: token(key, changes: changes), now: now); XCTFail() }
            catch { XCTAssertEqual(error as? RemoteAccessError, .unauthorized) }
        }
        for signed in [try token(P256.Signing.PrivateKey()), try token(key, header: ["alg": "ES256", "typ": "tomo-remote-grant+jwt", "kid": "cloud"]),
            try token(key, header: ["alg": "ES256", "typ": "tomo-binding-identity+jwt", "kid": "cloud", "jku": "https://other.test"])] {
            do { _ = try await approval.prepare(assertion: signed, now: now); XCTFail() }
            catch { XCTAssertEqual(error as? RemoteAccessError, .unauthorized) }
        }
    }
    func testRevokedBindingDoesNotReturnCachedApprovalReceipt() async throws {
        let (approval, _, key, _, directory) = try await setup()
        defer { try? FileManager.default.removeItem(at: directory) }
        let assertion = try token(key), pending = try await approval.prepare(assertion: assertion, now: now)
        _ = try await approval.approve(id: pending.id, scopes: ["session.read"], resources: resources(), expectedLocalVersion: 0, now: now)
        let ledger = try RemoteAuthorizationLedger(databaseURL: directory.appendingPathComponent("ledger.sqlite"), serverId: server)
        let before = try await ledger.ownerBindings(); XCTAssertEqual(before.count, 1)
        _ = try await ledger.revoke(userId: pending.userId, deviceId: pending.deviceId, expectedLocalVersion: 1)
        for retry in [false, true] {
            do {
                if retry { _ = try await approval.approve(id: pending.id, scopes: ["session.read"], resources: resources(), expectedLocalVersion: 0, now: now) }
                else { _ = try await approval.outcome(id: pending.id, assertion: assertion, now: now) }
                XCTFail("Revocation must invalidate cached receipt")
            } catch { XCTAssertEqual(error as? RemoteAccessError, .forbidden) }
        }
        let persisted = try await ledger.ownerBinding(userId: pending.userId, deviceId: pending.deviceId)
        XCTAssertEqual(persisted?.revoked, true); XCTAssertEqual(persisted?.localVersion, 2)
    }
    func testRejectedExpiredOrChangedChallengeCannotApprove() async throws {
        let (approval, _, key, _, directory) = try await setup(); defer { try? FileManager.default.removeItem(at: directory) }
        let assertion = try token(key), pending = try await approval.prepare(assertion: assertion, now: now)
        do { _ = try await approval.prepare(assertion: token(key, changes: ["deviceName": "Changed"]), now: now); XCTFail() }
        catch { XCTAssertEqual(error as? RemoteAccessError, .forbidden) }
        do { _ = try await approval.approve(id: pending.id, scopes: ["session.read"], resources: resources(), expectedLocalVersion: 0, now: pending.expiresAt); XCTFail() }
        catch { XCTAssertEqual(error as? RemoteAccessError, .forbidden) }
        try await approval.reject(id: pending.id)
        do { _ = try await approval.prepare(assertion: assertion, now: now); XCTFail() }
        catch { XCTAssertEqual(error as? RemoteAccessError, .forbidden) }
        do { _ = try await approval.approve(id: pending.id, scopes: ["session.read"], resources: resources(), expectedLocalVersion: 0, now: now); XCTFail() }
        catch { XCTAssertEqual(error as? RemoteAccessError, .forbidden) }
    }
}
