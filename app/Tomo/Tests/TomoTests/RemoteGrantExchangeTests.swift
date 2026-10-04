import XCTest
import CryptoKit
@testable import Tomo

@MainActor
final class RemoteGrantExchangeTests: XCTestCase {
    private actor RuntimeAvailability {
        private var available = true
        func withdraw() { available = false }
        func scopes(_ actions: Set<RemoteAction>) -> [RemoteAccessStore.Scope] {
            available ? [.init(agentId: "agent.chatgpt", runtimeId: "runtime-1", sessionId: nil, actions: actions)] : []
        }
    }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let endpoint = URL(string: "https://desktop.example.test:58350")!
    private let server = "11111111-1111-4111-8111-111111111111"
    private let user = "22222222-2222-4222-8222-222222222222"
    private let device = "33333333-3333-4333-8333-333333333333"
    private struct Setup {
        let exchange: RemoteGrantExchange
        let ledger: RemoteAuthorizationLedger
        let grant: String
        let key: P256.Signing.PrivateKey
        let directory: URL
        let endpoint: URL
        let time: Date
    }
    private func encoded(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private func jwk(_ key: P256.Signing.PrivateKey) -> [String: String] {
        let data = key.publicKey.x963Representation
        return ["crv": "P-256", "kty": "EC", "x": encoded(data.subdata(in: 1..<33)), "y": encoded(data.subdata(in: 33..<65))]
    }
    private func signed(_ key: P256.Signing.PrivateKey, header: [String: Any], claims: [String: Any]) throws -> String {
        let input = try encoded(JSONSerialization.data(withJSONObject: header)) + "." + encoded(JSONSerialization.data(withJSONObject: claims))
        return input + "." + encoded(try key.signature(for: Data(input.utf8)).rawRepresentation)
    }
    private func proof(_ setup: Setup, token: String, nonce: String, method: String = "POST",
                       path: String = "/api/v1/remote/access/exchange", key: P256.Signing.PrivateKey? = nil) throws -> String {
        let key = key ?? setup.key
        return try signed(key, header: ["alg": "ES256", "typ": "dpop+jwt", "jwk": jwk(key)], claims:
            ["jti": UUID().uuidString, "htm": method, "htu": setup.endpoint.absoluteString + path,
             "iat": Int(setup.time.timeIntervalSince1970), "nonce": nonce, "ath": encoded(Data(SHA256.hash(data: Data(token.utf8))))])
    }
    private func setup(approve: Bool = true, maximum: Int = 128, at: Date? = nil, target: URL? = nil,
                       registry suppliedRegistry: RemoteRuntimeScopeRegistry? = nil, resources suppliedResources: [[String: String]]? = nil,
                       resolve custom: RemoteGrantExchange.ResourceResolver? = nil) async throws -> Setup {
        let now = at ?? self.now, endpoint = target ?? self.endpoint
        let timestamp = Int(now.timeIntervalSince1970)
        let cloudKey = P256.Signing.PrivateKey(), deviceKey = P256.Signing.PrivateKey()
        let thumb = try encoded(Data(SHA256.hash(data: JSONSerialization.data(withJSONObject: jwk(deviceKey), options: [.sortedKeys]))))
        let resource: [[String: String]] = suppliedResources ?? [["kind": "runtime", "agentId": "agent.chatgpt", "runtimeId": "runtime-1"]]
        let payload: [String: Any] = ["iss": "https://accounts.example.test", "aud": server, "sub": user, "deviceId": device,
            "cnf": ["jkt": thumb], "bindingId": "44444444-4444-4444-8444-444444444444", "bindingRevision": 1,
            "entitlementVersion": 1, "scope": "discovery session.read", "resources": resource,
            "iat": timestamp, "nbf": timestamp, "exp": timestamp + 300, "jti": UUID().uuidString]
        let grant = try signed(cloudKey, header: ["alg": "ES256", "typ": "tomo-remote-grant+jwt", "kid": "cloud"], claims: payload)
        let cloudJWK = jwk(cloudKey).merging(["alg": "ES256", "use": "sig", "kid": "cloud"]) { _, value in value }
        let cloud = try await RemoteCloudGrantVerifier.configured(jwks: JSONSerialization.data(withJSONObject: ["keys": [cloudJWK]]),
            issuer: "https://accounts.example.test", serverId: server, trustedUntil: now.addingTimeInterval(60), now: now)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("remote-exchange-\(UUID().uuidString)")
        let ledger = try RemoteAuthorizationLedger(databaseURL: directory.appendingPathComponent("ledger.sqlite"), serverId: server)
        if approve {
            _ = try await ledger.approve(.init(userId: user, deviceId: device, thumbprint: thumb, bindingRevision: 1,
                cloudBindingId: nil, localVersion: 0, scopes: ["discovery", "session.read"],
                resources: JSONDecoder().decode([RemoteCloudGrantVerifier.Resource].self, from: JSONSerialization.data(withJSONObject: resource)),
                revoked: false), expectedLocalVersion: 0)
        }
        let registry = suppliedRegistry ?? RemoteRuntimeScopeRegistry()
        if suppliedRegistry == nil {
            _ = try await registry.register(descriptor: RemoteReadServiceTests.Adapter().descriptor, runtimeId: "runtime-1")
        }
        let exchange: RemoteGrantExchange
        if let custom {
            exchange = try RemoteGrantExchange(cloud: cloud, ledger: ledger, proof: RemoteDPoPVerifier(), endpoint: endpoint, maximumCredentials: maximum, resolve: custom)
        } else {
            exchange = try RemoteGrantExchange(cloud: cloud, ledger: ledger, proof: RemoteDPoPVerifier(), endpoint: endpoint, maximumCredentials: maximum, resources: registry)
        }
        return .init(exchange: exchange, ledger: ledger, grant: grant, key: deviceKey, directory: directory, endpoint: endpoint, time: now)
    }
    private func issued(_ setup: Setup, client: RemoteClientCapabilities = .v1) async throws -> RemoteGrantExchange.Issued {
        let nonce = try await setup.exchange.exchangeNonce(grant: setup.grant, now: setup.time)
        return try await setup.exchange.exchange(grant: setup.grant, dpop: proof(setup, token: setup.grant, nonce: nonce), client: client, now: setup.time)
    }
    private func denied(_ work: () async throws -> Void, error expected: RemoteAccessError = .unauthorized) async {
        do { try await work(); XCTFail("Unexpected production access") }
        catch { XCTAssertEqual(error as? RemoteAccessError, expected) }
    }
    func testProductionOperationOwnerComesFromVerifiedReceiptAndRevocation() async throws {
        let setup = try await setup(at: Date()); defer { try? FileManager.default.removeItem(at: setup.directory) }
        let access = try await issued(setup)
        let owner = try await setup.exchange.owner(access.principal)
        XCTAssertEqual(owner.userId, user); XCTAssertEqual(owner.deviceId, device)
        _ = try await setup.ledger.revoke(userId: user, deviceId: device, expectedLocalVersion: 1)
        await denied { _ = try await setup.exchange.owner(access.principal) }
    }
    func testShutdownInvalidatesCapturedProductionPrincipalWithoutDeletingACL() async throws {
        let setup = try await setup(at: Date()); defer { try? FileManager.default.removeItem(at: setup.directory) }
        let access = try await issued(setup)
        await setup.exchange.shutdown()
        await denied { try await setup.exchange.validate(access.principal) }
        await denied { _ = try await setup.exchange.owner(access.principal) }
        await denied({ _ = try await setup.exchange.exchangeNonce(grant: setup.grant) }, error: .unavailable)
    }
    func testSignedGrantProofLocalApprovalAndBusinessProofChain() async throws {
        let setup = try await setup(); defer { try? FileManager.default.removeItem(at: setup.directory) }
        let access = try await issued(setup), later = now.addingTimeInterval(1)
        XCTAssertEqual(access.tokenType, "DPoP")
        XCTAssertEqual(access.principal.expiresAt, now.addingTimeInterval(300))
        XCTAssertTrue(access.principal.permits(agentId: "agent.chatgpt", runtimeId: "runtime-1", sessionId: "session-1", action: .readHistory))
        XCTAssertFalse(access.principal.permits(agentId: "agent.chatgpt", runtimeId: "runtime-1", sessionId: "session-1", action: .sendMessage))
        let authorization = "DPoP " + access.token
        let nonce = try await setup.exchange.accessNonce(authorization: authorization, now: later)
        let requestProof = try proof(setup, token: access.token, nonce: nonce, method: "GET", path: "/api/v1/remote/catalog")
        let principal = try await setup.exchange.authenticate(authorization: authorization, dpop: requestProof, method: "GET", path: "/api/v1/remote/catalog", now: later)
        XCTAssertEqual(principal.id, access.principal.id)
        await denied { _ = try await setup.exchange.authenticate(authorization: authorization, dpop: requestProof, method: "GET", path: "/api/v1/remote/catalog", now: later.addingTimeInterval(1)) }
        await denied { _ = try await setup.exchange.accessNonce(authorization: "Bearer " + access.token, now: later.addingTimeInterval(1)) }
        await denied({ _ = try await setup.exchange.accessNonce(authorization: authorization, origin: "https://desktop.example.test", now: later.addingTimeInterval(1)) }, error: .forbidden)
    }
    func testExchangeRetryReturnsSameSecretWithoutExpiryExtension() async throws {
        let setup = try await setup(); defer { try? FileManager.default.removeItem(at: setup.directory) }
        let first = try await issued(setup), later = now.addingTimeInterval(1)
        let nonce = try await setup.exchange.exchangeNonce(grant: setup.grant, now: later)
        let retry = try await setup.exchange.exchange(grant: setup.grant, dpop: proof(setup, token: setup.grant, nonce: nonce), client: .v1, now: later)
        XCTAssertEqual(first.token, retry.token)
        XCTAssertEqual(first.principal.id, retry.principal.id)
        XCTAssertEqual(first.principal.expiresAt, retry.principal.expiresAt)
        try await setup.exchange.revoke(first.principal)
        await denied { try await setup.exchange.validate(first.principal, now: later.addingTimeInterval(1)) }
        await denied { _ = try await setup.exchange.exchange(grant: setup.grant, dpop: self.proof(setup, token: setup.grant, nonce: nonce), client: .v1, now: later.addingTimeInterval(1)) }
    }
    func testCloudGrantCannotReplaceDeviceProofOrLocalApproval() async throws {
        let setup = try await setup(approve: false); defer { try? FileManager.default.removeItem(at: setup.directory) }
        let nonce = try await setup.exchange.exchangeNonce(grant: setup.grant, now: now)
        await denied { _ = try await setup.exchange.exchange(grant: setup.grant, dpop: self.proof(setup, token: setup.grant, nonce: nonce, key: P256.Signing.PrivateKey()), client: .v1, now: self.now) }
        await denied { _ = try await self.issued(setup) }
        await denied({ _ = try await setup.exchange.exchange(grant: setup.grant, dpop: "", client: .v1, origin: "http://localhost", now: self.now) }, error: .forbidden)
    }
    func testPersistentRevocationInvalidatesCapturedPrincipalAndSecret() async throws {
        let setup = try await setup(); defer { try? FileManager.default.removeItem(at: setup.directory) }
        let access = try await issued(setup)
        _ = try await setup.ledger.revoke(userId: user, deviceId: device, expectedLocalVersion: 1)
        await denied { try await setup.exchange.validate(access.principal, now: self.now.addingTimeInterval(1)) }
        await denied { _ = try await setup.exchange.accessNonce(authorization: "DPoP " + access.token, now: self.now.addingTimeInterval(1)) }
    }
    func testResolverCannotExpandStrictRuntimeOrActions() async throws {
        let resolvers: [RemoteGrantExchange.ResourceResolver] = [
            { _, actions, _ in [.init(agentId: "agent.other", runtimeId: "runtime-2", sessionId: nil, actions: actions)] },
            { _, _, _ in [.init(agentId: "agent.chatgpt", runtimeId: "runtime-1", sessionId: nil, actions: [.sendMessage])] }
        ]
        for resolve in resolvers {
            let setup = try await setup(resolve: resolve); defer { try? FileManager.default.removeItem(at: setup.directory) }
            await denied({ _ = try await self.issued(setup) }, error: .invalidConfiguration)
        }
    }
    func testRuntimeWithdrawalInvalidatesLiveStreamPrincipal() async throws {
        let availability = RuntimeAvailability()
        let setup = try await setup(resolve: { _, actions, _ in await availability.scopes(actions) })
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let access = try await issued(setup)
        let validator: any RemotePrincipalValidator = setup.exchange
        try await validator.validate(access.principal, now: now.addingTimeInterval(1))
        await availability.withdraw()
        await denied { try await validator.validate(access.principal, now: self.now.addingTimeInterval(2)) }
    }
    func testPreviouslySignedWorkspaceGrantIncludesLaterRegisteredAgentAtExchange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("exchange-workspace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = RemoteRuntimeScopeRegistry()
        let workspace = try await registry.registerWorkspace(id: "workspace_one", root: root)
        let descriptor = RemoteReadServiceTests.Adapter().descriptor
        _ = try await registry.register(descriptor: descriptor, runtimeId: "runtime-1", workspace: workspace)
        let setup = try await setup(registry: registry, resources: [["kind": "workspace", "workspaceId": workspace.id, "agentPolicy": "registered"]])
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        // Cloud grant already exists. Register a new compatible adapter locally.
        var wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(descriptor)) as? [String: Any])
        wire["agentId"] = "agent.new"
        let added = try JSONDecoder().decode(RemoteAgentDescriptor.self, from: JSONSerialization.data(withJSONObject: wire))
        _ = try await registry.register(descriptor: added, runtimeId: "runtime_new", workspace: workspace)
        _ = try await registry.register(descriptor: descriptor, runtimeId: "runtime_host")
        let access = try await issued(setup)
        XCTAssertEqual(Set(access.principal.scopes.map(\.agentId)), ["agent.chatgpt", "agent.new"])
        XCTAssertFalse(access.principal.scopes.contains { $0.runtimeId == "runtime_host" })
        await registry.unregisterWorkspace(id: workspace.id)
        await denied { try await setup.exchange.validate(access.principal, now: self.now.addingTimeInterval(1)) }
    }
    private func routerResponse(_ result: RemoteProductionAccessRouter.Result) throws -> RemoteProductionAccessRouter.Response {
        guard case .response(let response) = result else { XCTFail("Expected response"); throw RemoteReadError.invalidRequest }
        return response
    }
    func testProductionRouterNonceExchangeBusinessAndPersistentRevoke() async throws {
        let setup = try await setup(); defer { try? FileManager.default.removeItem(at: setup.directory) }
        // Synthetic test platform verifier only; production must provide native attestation.
        let router = RemoteProductionAccessRouter(exchange: setup.exchange, verifyPlatform: { _ in })
        let grantBody = try JSONSerialization.data(withJSONObject: ["grant": setup.grant])
        let capabilities = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RemoteClientCapabilities.v1))
        let exchangeBody = try JSONSerialization.data(withJSONObject: ["grant": setup.grant, "clientCapabilities": capabilities])
        let jsonHeaders = [("Content-Type", "application/json")]
        let nonce = try routerResponse(await router.handle(.init(method: "POST", path: "/api/v1/remote/access/exchange/nonce", query: [:], headers: jsonHeaders, body: grantBody), now: now))
        XCTAssertEqual(nonce.status, 200)
        let challenge = try XCTUnwrap(nonce.headers["DPoP-Nonce"])
        let proof = try proof(setup, token: setup.grant, nonce: challenge)
        let exchanged = try routerResponse(await router.handle(.init(method: "POST", path: "/api/v1/remote/access/exchange", query: [:], headers: jsonHeaders + [("DPoP", proof)], body: exchangeBody), now: now.addingTimeInterval(1)))
        XCTAssertEqual(exchanged.status, 201)
        XCTAssertEqual(exchanged.headers["Cache-Control"], "no-store")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: exchanged.body) as? [String: Any])
        XCTAssertEqual(body["serverId"] as? String, server)
        XCTAssertEqual(body["tokenType"] as? String, "DPoP")
        XCTAssertEqual(body["negotiatedProtocol"] as? [String: Int], ["apiMajor": 1, "eventMajor": 1, "contentMajor": 1])
        let token = try XCTUnwrap(body["accessToken"] as? String), auth = [("Authorization", "DPoP " + token)]
        let accessNonce = try routerResponse(await router.handle(.init(method: "POST", path: "/api/v1/remote/access/nonce", query: [:], headers: auth, body: Data()), now: now.addingTimeInterval(2)))
        let nextNonce = try XCTUnwrap(accessNonce.headers["DPoP-Nonce"])
        let businessProof = try self.proof(setup, token: token, nonce: nextNonce, method: "GET", path: "/api/v1/remote/catalog")
        let business = await router.handle(.init(method: "GET", path: "/api/v1/remote/catalog", query: [:], headers: auth + [("DPoP", businessProof)], body: Data()), now: now.addingTimeInterval(3))
        guard case .authorized(let principal) = business else { XCTFail("Business access rejected"); return }
        XCTAssertEqual(principal.id.uuidString, body["accessId"] as? String)
        let revokeProof = try self.proof(setup, token: token, nonce: nextNonce, method: "DELETE", path: "/api/v1/remote/access/current")
        let revoked = try routerResponse(await router.handle(.init(method: "DELETE", path: "/api/v1/remote/access/current", query: [:], headers: auth + [("DPoP", revokeProof)], body: Data()), now: now.addingTimeInterval(4)))
        XCTAssertEqual(revoked.status, 204)
        XCTAssertTrue(revoked.body.isEmpty)
        let retry = try routerResponse(await router.handle(.init(method: "POST", path: "/api/v1/remote/access/exchange", query: [:], headers: jsonHeaders + [("DPoP", self.proof(setup, token: setup.grant, nonce: challenge))], body: exchangeBody), now: now.addingTimeInterval(5)))
        XCTAssertEqual(retry.status, 401)
    }
    func testProductionRouterRejectsHeaderConfusionURLCredentialsAndMalformedBodies() async throws {
        let setup = try await setup(); defer { try? FileManager.default.removeItem(at: setup.directory) }
        let router = RemoteProductionAccessRouter(exchange: setup.exchange, verifyPlatform: { _ in throw RemoteAccessError.unavailable })
        let capabilities = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RemoteClientCapabilities.v1))
        let path = "/api/v1/remote/access/exchange", body = try JSONSerialization.data(withJSONObject: ["grant": setup.grant, "clientCapabilities": capabilities])
        var unsupported = try XCTUnwrap(capabilities as? [String: Any])
        unsupported["apiMajors"] = [2]
        let unsupportedBody = try JSONSerialization.data(withJSONObject: ["grant": setup.grant, "clientCapabilities": unsupported])
        var malformed = try XCTUnwrap(capabilities as? [String: Any])
        malformed["apiMajors"] = [true]
        let malformedBody = try JSONSerialization.data(withJSONObject: ["grant": setup.grant, "clientCapabilities": malformed])
        let json = [("Content-Type", "application/json")]
        let cases: [(RemoteProductionAccessRouter.Request, Int)] = [
            (.init(method: "POST", path: path, query: [:], headers: json + [("DPoP", "one"), ("dpop", "two")], body: body), 400),
            (.init(method: "POST", path: path, query: [:], headers: json + [("Authorization", "one"), ("authorization", "two")], body: body), 400),
            (.init(method: "POST", path: path, query: ["access_token": "old"], headers: json, body: body), 400),
            (.init(method: "POST", path: path, query: [:], headers: json + [("Origin", "https://desktop.example.test")], body: body), 403),
            (.init(method: "POST", path: path, query: [:], headers: json + [("X-Value", "one\r\ntwo")], body: body), 400),
            (.init(method: "GET", path: path, query: [:], headers: json, body: body), 400),
            (.init(method: "POST", path: path, query: [:], headers: [], body: body), 400),
            (.init(method: "POST", path: path, query: [:], headers: json, body: Data("{".utf8)), 400),
            (.init(method: "POST", path: path, query: [:], headers: json, body: Data("{\"grant\":\"x\",\"vip\":\"true\"}".utf8)), 400),
            (.init(method: "POST", path: path, query: [:], headers: json, body: unsupportedBody), 426),
            (.init(method: "POST", path: path, query: [:], headers: json, body: malformedBody), 400),
            (.init(method: "POST", path: path, query: [:], headers: json, body: body), 503)
        ]
        for (index, entry) in cases.enumerated() {
            let (request, status) = entry
            let response = try routerResponse(await router.handle(request, now: now))
            XCTAssertEqual(response.status, status, "Request case \(index)")
            XCTAssertEqual(response.headers["Cache-Control"], "no-store")
            XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains(setup.grant))
        }
    }
    private struct CapabilityAdapter: RemoteReadAdapter {
        let descriptor: RemoteAgentDescriptor
        let runtimeId = "runtime-1"
        let runtimeLabel = "Private runtime label"
        func sessions(serverId: String) async throws -> RemoteDirectoryResult { .init(items: [], indexState: "ready") }
        func history(sessionId: String, limit: Int, snapshotBytes: UInt64?, beforeOffset: UInt64?) async throws -> RolloutHistoryWindow {
            throw RemoteReadError.notImplemented
        }
    }
    func testRequiredFeatureProducesMinimalIncompatibleCatalogAndNoSessionPermission() async throws {
        let registry = RemoteRuntimeScopeRegistry(), service = RemoteReadService(serverId: server, authorizationRegistry: registry)
        var wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(RemoteReadServiceTests.Adapter().descriptor)) as? [String: Any])
        wire["requiredClientFeatures"] = ["content.new"]
        let descriptor = try JSONDecoder().decode(RemoteAgentDescriptor.self, from: JSONSerialization.data(withJSONObject: wire))
        try await service.register(CapabilityAdapter(descriptor: descriptor))
        let setup = try await setup(registry: registry); defer { try? FileManager.default.removeItem(at: setup.directory) }
        let access = try await issued(setup)
        XCTAssertEqual(access.principal.scopes.count, 1)
        XCTAssertTrue(access.principal.scopes[0].actions.isEmpty)
        let data = try await service.response(path: "/api/v1/remote/catalog", query: [:], principal: access.principal)
        let catalog = try JSONDecoder().decode(RemoteReadService.Catalog.self, from: data)
        XCTAssertEqual(catalog.agents.items.first?.status, "incompatible")
        XCTAssertNil(catalog.agents.items.first?.descriptor)
        XCTAssertTrue(catalog.runtimes.isEmpty)
        await denied({ _ = try await service.sessions(principal: access.principal, agentId: "agent.chatgpt", runtimeId: "runtime-1") }, error: .forbidden)
        let supported = RemoteClientCapabilities(descriptorMajors: [1], apiMajors: [1], eventMajors: [1], contentMajors: [1], clientFeatures: ["content.new"])
        let laterSetup = try await self.setup(registry: registry); defer { try? FileManager.default.removeItem(at: laterSetup.directory) }
        let laterAccess = try await issued(laterSetup, client: supported)
        XCTAssertTrue(laterAccess.principal.permits(agentId: "agent.chatgpt", runtimeId: "runtime-1", sessionId: nil, action: .listSessions))
        let laterData = try await service.response(path: "/api/v1/remote/catalog", query: [:], principal: laterAccess.principal)
        XCTAssertEqual(try JSONDecoder().decode(RemoteReadService.Catalog.self, from: laterData).agents.items.first?.status, "registered")
    }
    func testProtocolVersionsAndBoundCapabilitiesCannotChangeOnRetry() async throws {
        let setup = try await setup(); defer { try? FileManager.default.removeItem(at: setup.directory) }
        let unsupported = RemoteClientCapabilities(descriptorMajors: [1], apiMajors: [2], eventMajors: [1], contentMajors: [1], clientFeatures: [])
        await denied({ _ = try await self.issued(setup, client: unsupported) }, error: .protocolIncompatible)
        let invalid = RemoteClientCapabilities(descriptorMajors: [1], apiMajors: [1, 1], eventMajors: [1], contentMajors: [1], clientFeatures: [])
        do { _ = try await issued(setup, client: invalid); XCTFail("Malformed capability list accepted") }
        catch { XCTAssertEqual(error as? RemoteReadError, .invalidRequest) }
        let access = try await issued(setup)
        XCTAssertEqual(access.principal.clientCapabilities, .v1)
        let client = RemoteClientCapabilities(descriptorMajors: [1], apiMajors: [1], eventMajors: [1], contentMajors: [1], clientFeatures: ["content.new"])
        let nonce = try await setup.exchange.exchangeNonce(grant: setup.grant, now: now.addingTimeInterval(1))
        await denied { _ = try await setup.exchange.exchange(grant: setup.grant, dpop: self.proof(setup, token: setup.grant, nonce: nonce), client: client, now: self.now.addingTimeInterval(1)) }
        let forged = RemoteAccessStore.Principal(id: access.principal.id, expiresAt: access.principal.expiresAt,
            scopes: access.principal.scopes, origin: nil, generation: 0, clientCapabilities: client)
        await denied { try await setup.exchange.validate(forged, now: self.now.addingTimeInterval(2)) }
    }
    func testTLSCertificateMustMatchFixedEndpoint() async throws {
        let tls = try RemoteTLSFixture(); defer { tls.remove() }
        let setup = try await setup(); defer { try? FileManager.default.removeItem(at: setup.directory) }
        let router = RemoteProductionAccessRouter(exchange: setup.exchange, verifyPlatform: { _ in throw RemoteAccessError.forbidden })
        do {
            _ = try RemoteHTTPSListener(identity: tls.identity, router: router) { _, _ in
                .init(status: 200, headers: [:], body: Data())
            }
            XCTFail("Certificate for localhost accepted for desktop.example.test")
        } catch { XCTAssertEqual(error as? RemoteAccessError, .invalidConfiguration) }
    }

    func testRealHTTPSExchangeBusinessReplayOriginAndRevocation() async throws {
        let tls = try RemoteTLSFixture()
        defer { tls.remove() }
        let endpoint = URL(string: "https://127.0.0.1:\(try RemoteTLSFixture.freePort())")!
        let registry = RemoteRuntimeScopeRegistry()
        let service = RemoteReadService(serverId: server, authorizationRegistry: registry)
        try await service.register(CapabilityAdapter(descriptor: RemoteReadServiceTests.Adapter().descriptor))
        let setup = try await setup(at: Date(), target: endpoint, registry: registry)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let router = RemoteProductionAccessRouter(exchange: setup.exchange, verifyPlatform: { request in
            // Synthetic test verifier only. This header is never an App attestation.
            guard request.headers.contains(where: { $0.0.lowercased() == "x-test-native" && $0.1.trimmingCharacters(in: .whitespaces) == "fixture" }) else {
                throw RemoteAccessError.forbidden
            }
        })
        let listener = try RemoteHTTPSListener(identity: tls.identity, router: router, bindHost: "127.0.0.1") { request, principal in
            let data = try await service.response(path: request.path, query: request.query, principal: principal)
            return .init(status: 200, headers: ["Content-Type": "application/json"], body: data)
        }
        try await listener.start()
        let session = tls.session()
        defer { session.invalidateAndCancel() }
        do {
            func call(_ path: String, _ method: String = "POST", headers: [String: String] = [:], body: [String: Any]? = nil) async throws -> (Data, HTTPURLResponse) {
                var request = URLRequest(url: URL(string: endpoint.absoluteString + path)!)
                request.httpMethod = method
                request.timeoutInterval = 5
                for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
                if let body {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                }
                let (data, response) = try await session.data(for: request)
                return (data, try XCTUnwrap(response as? HTTPURLResponse))
            }
            let exchangePath = "/api/v1/remote/access/exchange"
            let (_, missingPlatform) = try await call(exchangePath + "/nonce", body: ["grant": setup.grant])
            XCTAssertEqual(missingPlatform.statusCode, 403)
            let (_, originDenied) = try await call(exchangePath + "/nonce", headers: ["Origin": "https://app.example", "X-Test-Native": "fixture"], body: ["grant": setup.grant])
            XCTAssertEqual(originDenied.statusCode, 403)
            let (_, challenge) = try await call(exchangePath + "/nonce", headers: ["X-Test-Native": "fixture"], body: ["grant": setup.grant])
            XCTAssertEqual(challenge.statusCode, 200)
            let nonce = try XCTUnwrap(challenge.value(forHTTPHeaderField: "DPoP-Nonce"))
            let capabilities = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RemoteClientCapabilities.v1))
            let (exchangeBody, exchanged) = try await call(exchangePath, headers: ["X-Test-Native": "fixture", "DPoP": proof(setup, token: setup.grant, nonce: nonce)], body: ["grant": setup.grant, "clientCapabilities": capabilities])
            XCTAssertEqual(exchanged.statusCode, 201)
            let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: exchangeBody) as? [String: Any])
            let token = try XCTUnwrap(wire["accessToken"] as? String)
            let authorization = "DPoP " + token
            let (_, accessChallenge) = try await call("/api/v1/remote/access/nonce", headers: ["Authorization": authorization])
            let accessNonce = try XCTUnwrap(accessChallenge.value(forHTTPHeaderField: "DPoP-Nonce"))
            let requestProof = try proof(setup, token: token, nonce: accessNonce, method: "GET", path: "/api/v1/remote/catalog")
            let headers = ["Authorization": authorization, "DPoP": requestProof]
            let (catalogData, catalogResponse) = try await call("/api/v1/remote/catalog", "GET", headers: headers)
            XCTAssertEqual(catalogResponse.statusCode, 200)
            let catalog = try JSONDecoder().decode(RemoteReadService.Catalog.self, from: catalogData)
            XCTAssertEqual(catalog.agents.items.first?.status, "registered")
            XCTAssertEqual(catalog.runtimes.count, 1)
            let (_, replay) = try await call("/api/v1/remote/catalog", "GET", headers: headers)
            XCTAssertEqual(replay.statusCode, 401)
            _ = try await setup.ledger.revoke(userId: user, deviceId: device, expectedLocalVersion: 1)
            let (_, revoked) = try await call("/api/v1/remote/access/nonce", headers: ["Authorization": authorization])
            XCTAssertEqual(revoked.statusCode, 401)
            // TLS is mandatory. No plaintext response or authorization fallback.
            let plain = URL(string: endpoint.absoluteString.replacingOccurrences(of: "https:", with: "http:") + "/api/v1/remote/catalog")!
            var plainRequest = URLRequest(url: plain); plainRequest.timeoutInterval = 3
            do { _ = try await session.data(for: plainRequest); XCTFail("Plaintext accepted") } catch {}
            let wrongTLS = try RemoteTLSFixture(); defer { wrongTLS.remove() }
            let wrongSession = wrongTLS.session(); defer { wrongSession.invalidateAndCancel() }
            var secureRequest = URLRequest(url: URL(string: endpoint.absoluteString + "/api/v1/remote/catalog")!)
            secureRequest.timeoutInterval = 3
            do { _ = try await wrongSession.data(for: secureRequest); XCTFail("Untrusted certificate accepted") } catch {}
        } catch { await listener.stop(); throw error }
        await listener.stop()
    }

    func testRealTLSSyncReplayLiveRevocationAndIdleCancellation() async throws {
        let tls = try RemoteTLSFixture(); defer { tls.remove() }
        let endpoint = URL(string: "https://127.0.0.1:\(try RemoteTLSFixture.freePort())")!
        let setup = try await setup(at: Date(), target: endpoint)
        defer { try? FileManager.default.removeItem(at: setup.directory) }
        let service = RemoteSessionService(serverId: server)
        let journal = try RemoteSessionJournal(databaseURL: setup.directory.appendingPathComponent("events.sqlite"))
        let ref = RemoteSessionRef(serverId: server, agentId: "agent.chatgpt", runtimeId: "runtime-1", sessionId: "session")
        let projection = RemoteSessionProjection(control: .init(executionEpoch: "test-process", controlRevision: 1,
            state: "running", controlMode: "readOnly", currentTurnId: "turn", allowedActions: ["history.read"]),
            messages: [.init(messageId: "message", turnId: "turn", messageRevision: 1, role: "assistant",
                createdAt: "2026-10-03T00:00:00Z", status: "streaming",
                content: [.init(partId: "text", type: "text", text: String(repeating: "x", count: 5 * 1024 * 1024))])],
            pendingRequests: [], olderHistoryCursor: nil, hasOlder: false)
        let stale = try await journal.replace(ref: ref, projection: projection)
        let initial = try await journal.replace(ref: ref, projection: projection)
        try await service.register(ref: ref, journal: journal)
        let access = try await issued(setup)
        let router = RemoteProductionAccessRouter(exchange: setup.exchange, verifyPlatform: { _ in throw RemoteAccessError.forbidden })
        let listener = try RemoteHTTPSListener(identity: tls.identity, router: router, bindHost: "127.0.0.1", sessionService: service) { _, _ in
            throw RemoteReadError.notImplemented
        }
        try await listener.start()
        let client = tls.session(); defer { client.invalidateAndCancel() }
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            client.invalidateAndCancel()
        }
        defer { watchdog.cancel() }
        var stage = "sync"
        do {
            func request(_ suffix: String, cursor: String? = nil, client transport: URLSession? = nil) async throws -> URLRequest {
                stage = "nonce for " + suffix
                let transport = transport ?? client
                var nonceRequest = URLRequest(url: URL(string: endpoint.absoluteString + "/api/v1/remote/access/nonce")!)
                nonceRequest.httpMethod = "POST"; nonceRequest.timeoutInterval = 5
                nonceRequest.setValue("DPoP " + access.token, forHTTPHeaderField: "Authorization")
                let (_, response) = try await transport.data(for: nonceRequest)
                let nonce = try XCTUnwrap((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "DPoP-Nonce"))
                let path = "/api/v1/remote/sessions/session/" + suffix.components(separatedBy: "?")[0]
                var request = URLRequest(url: URL(string: endpoint.absoluteString + "/api/v1/remote/sessions/session/" + suffix)!)
                request.timeoutInterval = 5
                request.setValue("DPoP " + access.token, forHTTPHeaderField: "Authorization")
                request.setValue(try proof(setup, token: access.token, nonce: nonce, method: "GET", path: path), forHTTPHeaderField: "DPoP")
                if let cursor { request.setValue(cursor, forHTTPHeaderField: "Last-Event-ID") }
                return request
            }
            let scope = "agent_id=agent.chatgpt&runtime_id=runtime-1"
            let (data, syncResponse) = try await client.data(for: request("sync?" + scope))
            XCTAssertEqual((syncResponse as? HTTPURLResponse)?.statusCode, 200)
            let sync = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(sync["eventCursor"] as? String, initial.eventCursor)
            let messages = try XCTUnwrap(sync["messages"] as? [[String: Any]])
            let parts = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
            XCTAssertEqual((parts.first?["text"] as? String)?.utf8.count, 5 * 1024 * 1024)
            for (suffix, cursor, expected) in [
                ("events?" + scope, stale.eventCursor, 409),
                ("events?" + scope + "&after=different", initial.eventCursor, 400),
                ("events?" + scope, nil, 400),
                ("events?agent_id=agent.chatgpt&runtime_id=other", initial.eventCursor, 403)
            ] as [(String, String?, Int)] {
                let (_, response) = try await client.data(for: request(suffix, cursor: cursor))
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, expected)
                XCTAssertNotEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "text/event-stream")
            }
            let beforeCount = await listener.streamCount
            XCTAssertEqual(beforeCount, 0)
            let idle = tls.session()
            let (_, idleResponse) = try await idle.bytes(for: request("events?" + scope, cursor: initial.eventCursor, client: idle), delegate: tls.taskDelegate())
            XCTAssertEqual((idleResponse as? HTTPURLResponse)?.statusCode, 200)
            let active = await listener.streamCount; XCTAssertEqual(active, 1)
            idle.invalidateAndCancel()
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while await listener.streamCount != 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            let afterCancel = await listener.streamCount; XCTAssertEqual(afterCancel, 0)
            _ = try await journal.append(ref: ref, mutation: .delta(messageId: "message", partId: "text", revision: 2, text: " replay"))
            let replayClient = tls.session(); defer { replayClient.invalidateAndCancel() }
            let (replayBytes, replayResponse) = try await replayClient.bytes(for: request("events?" + scope, cursor: initial.eventCursor, client: replayClient), delegate: tls.taskDelegate())
            XCTAssertEqual((replayResponse as? HTTPURLResponse)?.statusCode, 200)
            var resumeCursor = ""
            for try await line in replayBytes.lines {
                if line.hasPrefix("id: ") { resumeCursor = String(line.dropFirst(4)) }
                if line.hasPrefix("data: ") {
                    let event = try JSONDecoder().decode(RemoteJournalEvent.self, from: Data(line.dropFirst(6).utf8))
                    XCTAssertEqual(event.type, "message.delta"); XCTAssertEqual(event.sequence, 1)
                    break
                }
            }
            XCTAssertFalse(resumeCursor.isEmpty)
            replayClient.invalidateAndCancel()
            let replayClosedBy = ContinuousClock.now.advanced(by: .seconds(3))
            while await listener.streamCount != 0, ContinuousClock.now < replayClosedBy { try await Task.sleep(for: .milliseconds(10)) }
            _ = try await journal.append(ref: ref, mutation: .delta(messageId: "message", partId: "text", revision: 3, text: " resumed"))
            let (bytes, streamResponse) = try await client.bytes(for: request("events?" + scope, cursor: resumeCursor), delegate: tls.taskDelegate())
            let http = try XCTUnwrap(streamResponse as? HTTPURLResponse)
            XCTAssertEqual(http.statusCode, 200)
            XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "text/event-stream")
            XCTAssertNil(http.value(forHTTPHeaderField: "Access-Control-Allow-Origin"))
            var count = 0, eventCursor = ""
            for try await line in bytes.lines {
                if line.hasPrefix("id: ") { eventCursor = String(line.dropFirst(4)) }
                guard line.hasPrefix("data: ") else { continue }
                let event = try JSONDecoder().decode(RemoteJournalEvent.self, from: Data(line.dropFirst(6).utf8))
                count += 1
                XCTAssertEqual(event.sequence, count + 1)
                XCTAssertEqual(event.streamEpoch, initial.streamEpoch)
                if count == 1 {
                    XCTAssertEqual(event.type, "message.delta"); XCTAssertFalse(eventCursor.isEmpty)
                    _ = try await journal.append(ref: ref, mutation: .delta(messageId: "message", partId: "text", revision: 4, text: " live"))
                } else if count == 2 {
                    XCTAssertEqual(event.type, "message.delta")
                    _ = try await setup.ledger.revoke(userId: user, deviceId: device, expectedLocalVersion: 1)
                } else {
                    XCTAssertEqual(event.type, "access.revoked"); break
                }
            }
            XCTAssertEqual(count, 3)
            let closedBy = ContinuousClock.now.advanced(by: .seconds(3))
            while await listener.streamCount != 0, ContinuousClock.now < closedBy { try await Task.sleep(for: .milliseconds(10)) }
            let finalCount = await listener.streamCount; XCTAssertEqual(finalCount, 0)
        } catch {
            await listener.stop()
            XCTFail("TLS session integration failed at \(stage): \(error)")
            return
        }
        await listener.stop()
    }

}
