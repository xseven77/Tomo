import XCTest
import CryptoKit
import SQLite3
@testable import Tomo

private actor ProductionCloudHTTP: DesktopCloudHTTP {
    let auth = DesktopCloudFixture()
    let jwks: Data
    private var blocked = false, waiting = false
    private var pending: CheckedContinuation<Void, Never>?, observer: CheckedContinuation<Void, Never>?
    init(_ jwks: Data) { self.jwks = jwks }
    func blockJWKS() { blocked = true }
    func waitForJWKS() async { if waiting { return }; await withCheckedContinuation { observer = $0 } }
    func resumeJWKS() { blocked = false; pending?.resume(); pending = nil; waiting = false }
    func send(_ request: URLRequest) async throws -> DesktopCloudReply {
        if request.url?.path == "/.well-known/jwks.json" {
            if blocked { await withCheckedContinuation { pending = $0; waiting = true; observer?.resume(); observer = nil } }
            return .init(status: 200, body: jwks, contentType: "application/json", headers: ["cache-control": "max-age=60"])
        }
        return try await auth.send(request)
    }
}

@MainActor final class RemoteProductionServiceTests: XCTestCase {
    func encoded(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    func signed(_ key: P256.Signing.PrivateKey, header: [String: Any], claims: [String: Any]) throws -> String {
        let input = encoded(try JSONSerialization.data(withJSONObject: header)) + "." + encoded(try JSONSerialization.data(withJSONObject: claims))
        return input + "." + encoded(try key.signature(for: Data(input.utf8)).rawRepresentation)
    }
    func jwk(_ key: P256.Signing.PrivateKey) -> [String: String] {
        let bytes = key.publicKey.x963Representation
        return ["kty": "EC", "crv": "P-256", "x": encoded(bytes.subdata(in: 1..<33)), "y": encoded(bytes.subdata(in: 33..<65))]
    }
    private func cloud(_ key: P256.Signing.PrivateKey, signer: RemoteServerIdentity) async throws -> (DesktopCloudSession, ProductionCloudHTTP) {
        let keys = jwk(key).merging(["alg": "ES256", "use": "sig", "kid": "cloud"]) { _, new in new }
        let http = ProductionCloudHTTP(try JSONSerialization.data(withJSONObject: ["keys": [keys]]))
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let cloud = try DesktopCloudSession(endpoint: URL(string: "https://cloud.example.test")!, storage: DesktopSessionMemory(),
            http: http, identity: signer, clock: { date })
        try await cloud.beginLogin(email: "owner@example.test"); _ = try await cloud.completeLogin(code: "123456")
        _ = try await cloud.registerServer(name: "Studio Mac"); return (cloud, http)
    }
    private func adapter(_ directory: URL) throws -> ChatGPTReadAdapter {
        let database = directory.appendingPathComponent("threads.sqlite")
        var db: OpaquePointer?
        guard sqlite3_open(database.path, &db) == SQLITE_OK, let db else { throw RemoteReadError.unavailable }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "CREATE TABLE threads(id TEXT,rollout_path TEXT,title TEXT,updated_at INTEGER)", nil, nil, nil) == SQLITE_OK else { throw RemoteReadError.unavailable }
        return ChatGPTReadAdapter(directory: .init(databaseURL: database, storageRoot: directory, runtimeId: "runtime-1"), runtimeLabel: "Test directory")
    }
    func testRealTLSAssemblyBindingApprovalAndStop() async throws {
        let tls = try RemoteTLSFixture(); defer { tls.remove() }
        let signer = RemoteServerIdentity(storage: DesktopIdentityMemory()), key = P256.Signing.PrivateKey(), deviceKey = P256.Signing.PrivateKey()
        let (cloud, http) = try await cloud(key, signer: signer)
        let endpoint = URL(string: "https://127.0.0.1:\(try RemoteTLSFixture.freePort())")!
        let readAdapter = try adapter(tls.directory)
        let service = try await RemoteProductionService.start(cloudSession: cloud, issuer: URL(string: "https://cloud.example.test")!, endpoint: endpoint,
            tlsIdentity: tls.identity, signingIdentity: signer, directory: tls.directory.appendingPathComponent("service"), adapters: [readAdapter], cloudHTTP: http, bindHost: "127.0.0.1")
        let suite = "RemoteProductionOwnerTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cloudManager = DesktopCloudManager(defaults: defaults, factory: { _ in cloud })
        await cloudManager.configure("https://cloud.example.test")
        let manager = RemoteProductionManager(cloud: cloudManager, catalog: ManagerTLSCatalog(tls.identity), directory: tls.directory,
            sources: { _ in [readAdapter] }, factory: { _, _, _, _, _, _ in service })
        await manager.loadCertificates()
        await manager.start(endpoint: endpoint.absoluteString, certificateId: "fixture", storageRoot: tls.directory)
        XCTAssertEqual(manager.status, .running)
        let session = tls.session(); defer { session.invalidateAndCancel() }
        let request = URLRequest(url: endpoint.appendingPathComponent("api/v1/remote/catalog"))
        let (_, denied) = try await session.data(for: request)
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 401)
        let now = Int(Date().timeIntervalSince1970), id = UUID().uuidString.lowercased()
        let thumb = try RemoteBindingApproval.thumbprint(deviceKey.publicKey)
        let assertion = try signed(key, header: ["alg": "ES256", "typ": "tomo-binding-identity+jwt", "kid": "cloud"], claims: [
            "iss": "https://cloud.example.test", "aud": service.server.id.uuidString.lowercased(),
            "sub": "33333333-3333-4333-8333-333333333333", "deviceId": "22222222-2222-4222-8222-222222222222",
            "cnf": ["jkt": thumb], "deviceName": "Phone", "userEmail": "owner@example.test", "challengeId": id,
            "nonce": String(repeating: "A", count: 43), "scope": "server.bind", "bindingRevision": 1,
            "iat": now, "nbf": now, "exp": now + 300, "jti": id])
        var nonceRequest = URLRequest(url: endpoint.appendingPathComponent("api/v1/remote/bindings/nonce"))
        nonceRequest.httpMethod = "POST"; nonceRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        nonceRequest.httpBody = try JSONSerialization.data(withJSONObject: ["identityAssertion": assertion])
        let (_, nonceResponse) = try await session.data(for: nonceRequest)
        XCTAssertEqual((nonceResponse as? HTTPURLResponse)?.statusCode, 200)
        let nonce = try XCTUnwrap((nonceResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "DPoP-Nonce"))
        var submit = nonceRequest; submit.url = endpoint.appendingPathComponent("api/v1/remote/bindings/requests")
        let proof = try signed(deviceKey, header: ["alg": "ES256", "typ": "dpop+jwt", "jwk": jwk(deviceKey)], claims: [
            "jti": UUID().uuidString, "htm": "POST", "htu": submit.url!.absoluteString,
            "iat": now, "nonce": nonce, "ath": encoded(Data(SHA256.hash(data: Data(assertion.utf8))))])
        submit.setValue(proof, forHTTPHeaderField: "DPoP")
        let (_, response) = try await session.data(for: submit)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 202)
        let pending = await service.approval.pendingItems(); XCTAssertEqual(pending.count, 1)
        let owner = try await service.ownerState()
        XCTAssertEqual(owner.pending.count, 1); XCTAssertTrue(owner.bindings.isEmpty)
        XCTAssertEqual(owner.runtimes.map(\.id), ["agent.chatgpt:runtime-1"])
        XCTAssertEqual(RemoteProductionService.ownerScopes(owner.runtimes), ["discovery", "session.read"])
        for (scopes, ids, version) in [(["session.write"], Set(["agent.chatgpt:runtime-1"]), 0),
                                      (["session.read"], Set(["foreign:runtime"]), 0),
                                      (["session.read"], Set(["agent.chatgpt:runtime-1"]), 1)] {
            do { try await service.ownerApprove(id: UUID(uuidString: id)!, scopes: scopes, runtimeIds: ids, expectedVersion: version); XCTFail("Invalid owner selection accepted") }
            catch { XCTAssertEqual(error as? RemoteAccessError, .forbidden) }
        }
        let resources = try JSONDecoder().decode([RemoteCloudGrantVerifier.Resource].self,
            from: Data("[{\"kind\":\"runtime\",\"agentId\":\"agent.chatgpt\",\"runtimeId\":\"runtime-1\"}]".utf8))
        await manager.refreshOwnerState()
        XCTAssertEqual(manager.ownerState?.pending.count, 1)
        await manager.approveDevice(id: UUID(uuidString: id)!, scopes: ["discovery", "session.read"], runtimeIds: ["agent.chatgpt:runtime-1"], expectedVersion: 0, lease: owner.lease)
        XCTAssertNil(manager.ownerMessage)
        guard case .approved(let receipt) = try await service.approval.outcome(id: UUID(uuidString: id)!, assertion: assertion) else { return XCTFail("Missing approved receipt") }
        let pieces = receipt.split(separator: "."), identity = try await signer.publicIdentity()
        let bytes = String(pieces[2]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let decoded = try XCTUnwrap(Data(base64Encoded: bytes + String(repeating: "=", count: (4 - bytes.count % 4) % 4)))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: decoded)
        XCTAssertTrue(try P256.Signing.PublicKey(pemRepresentation: identity.publicKeyPem).isValidSignature(signature, for: Data("\(pieces[0]).\(pieces[1])".utf8)))
        let scopes = try await service.registry.resolve(resources, actions: [.listSessions, .readHistory], client: .v1)
        XCTAssertEqual(scopes.count, 1); XCTAssertFalse(scopes[0].actions.contains(.sendMessage))
        let approved = try await service.ownerState()
        XCTAssertTrue(approved.pending.isEmpty); XCTAssertEqual(approved.bindings.first?.localVersion, 1)
        await manager.revokeDevice(userId: "33333333-3333-4333-8333-333333333333", deviceId: "22222222-2222-4222-8222-222222222222", expectedVersion: 1, lease: UUID())
        XCTAssertEqual(manager.ownerState?.bindings.first?.revoked, false)
        await manager.revokeDevice(userId: "33333333-3333-4333-8333-333333333333", deviceId: "22222222-2222-4222-8222-222222222222", expectedVersion: 1, lease: owner.lease)
        XCTAssertNil(manager.ownerMessage)
        let revoked = try await service.ownerState()
        XCTAssertEqual(revoked.bindings.first?.revoked, true); XCTAssertEqual(revoked.bindings.first?.localVersion, 2)
        do { _ = try await service.approval.outcome(id: UUID(uuidString: id)!, assertion: assertion); XCTFail("Revocation exposed old receipt") }
        catch { XCTAssertEqual(error as? RemoteAccessError, .forbidden) }
        let (_, freshNonceResponse) = try await session.data(for: nonceRequest)
        let freshNonce = try XCTUnwrap((freshNonceResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "DPoP-Nonce"))
        var query = URLRequest(url: endpoint.appendingPathComponent("api/v1/remote/bindings/requests/" + id))
        query.setValue("DPoP " + assertion, forHTTPHeaderField: "Authorization")
        query.setValue(try signed(deviceKey, header: ["alg": "ES256", "typ": "dpop+jwt", "jwk": jwk(deviceKey)], claims: [
            "jti": UUID().uuidString, "htm": "GET", "htu": query.url!.absoluteString,
            "iat": Int(Date().timeIntervalSince1970), "nonce": freshNonce, "ath": encoded(Data(SHA256.hash(data: Data(assertion.utf8))))]), forHTTPHeaderField: "DPoP")
        let (revokedBody, revokedResponse) = try await session.data(for: query)
        XCTAssertEqual((revokedResponse as? HTTPURLResponse)?.statusCode, 403)
        XCTAssertFalse(String(decoding: revokedBody, as: UTF8.self).contains(receipt))
        await manager.stop()
        XCTAssertNil(manager.ownerState)
        do { _ = try await service.ownerState(); XCTFail("Stopped owner service remained available") }
        catch { XCTAssertEqual(error as? RemoteAccessError, .unavailable) }
        XCTAssertEqual(manager.status, .stopped)
        do { _ = try await session.data(for: request); XCTFail("Stopped listener accepted connection") } catch {}
        do { _ = try await service.approval.prepare(assertion: assertion); XCTFail("Stopped trust accepted assertion") } catch {}
    }
    func testMismatchedIssuerOrSigningKeyCannotStartListener() async throws {
        let tls = try RemoteTLSFixture(); defer { tls.remove() }
        let signer = RemoteServerIdentity(storage: DesktopIdentityMemory()), key = P256.Signing.PrivateKey()
        let (cloud, http) = try await cloud(key, signer: signer)
        let adapter = try adapter(tls.directory), endpoint = URL(string: "https://127.0.0.1:\(try RemoteTLSFixture.freePort())")!
        for (issuer, signing) in [(URL(string: "https://foreign.example.test")!, signer),
                                  (URL(string: "https://cloud.example.test")!, RemoteServerIdentity(storage: DesktopIdentityMemory()))] {
            do {
                _ = try await RemoteProductionService.start(cloudSession: cloud, issuer: issuer, endpoint: endpoint, tlsIdentity: tls.identity,
                    signingIdentity: signing, directory: tls.directory.appendingPathComponent("service"), adapters: [adapter], cloudHTTP: http, bindHost: "127.0.0.1")
                XCTFail("Mismatched native identity accepted")
            } catch { XCTAssertEqual(error as? RemoteAccessError, .invalidConfiguration) }
        }
    }
    func testOwnerLogoutDuringJWKSFetchPreventsListenerStartup() async throws {
        let tls = try RemoteTLSFixture(); defer { tls.remove() }
        let signer = RemoteServerIdentity(storage: DesktopIdentityMemory()), key = P256.Signing.PrivateKey()
        let (cloud, http) = try await cloud(key, signer: signer)
        let adapter = try adapter(tls.directory), endpoint = URL(string: "https://127.0.0.1:\(try RemoteTLSFixture.freePort())")!
        await http.blockJWKS()
        let starting = Task {
            try await RemoteProductionService.start(cloudSession: cloud, issuer: URL(string: "https://cloud.example.test")!, endpoint: endpoint,
                tlsIdentity: tls.identity, signingIdentity: signer, directory: tls.directory.appendingPathComponent("service"), adapters: [adapter], cloudHTTP: http, bindHost: "127.0.0.1")
        }
        await http.waitForJWKS(); try await cloud.logout(); await http.resumeJWKS()
        do { _ = try await starting.value; XCTFail("Logout allowed listener startup") }
        catch { XCTAssertEqual(error as? RemoteAccessError, .unauthorized) }
        let session = tls.session(); defer { session.invalidateAndCancel() }
        do { _ = try await session.data(from: endpoint); XCTFail("Unauthenticated owner started listener") } catch {}
    }
}
