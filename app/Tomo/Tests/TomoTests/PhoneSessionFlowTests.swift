import XCTest
import CryptoKit
import Network
import SQLite3
import Darwin
@testable import Tomo

@MainActor final class PhoneSessionFlowTests: XCTestCase {
    func testReplayReadyHeartbeatKeepsTheCommittedCursorAndSequence() throws {
        let ref = RemoteSessionRef(serverId: "synthetic", agentId: "agent.chatgpt", runtimeId: "runtime", sessionId: "session")
        let data = try RemoteSessionService.readyFrame(ref: ref, epoch: "log", sequence: 7, cursor: "opaque-current")
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        XCTAssertTrue(lines.contains("id: opaque-current")); XCTAssertTrue(lines.contains("event: heartbeat"))
        let line = try XCTUnwrap(lines.first {$0.hasPrefix("data: ")})
        let event = try JSONDecoder().decode(RemoteJournalEvent.self, from: Data(line.dropFirst(6).utf8))
        XCTAssertEqual(event.type, "heartbeat"); XCTAssertEqual(event.sequence, 7); XCTAssertEqual(event.streamEpoch, "log")
        XCTAssertEqual(event.sessionId, "session"); XCTAssertEqual(event.payload, .object([:]))
    }
    private func encoded(_ data: Data) -> String {data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")}
    private func jwk(_ key: P256.Signing.PrivateKey) -> [String: String] {
        let bytes = key.publicKey.x963Representation
        return ["kty": "EC", "crv": "P-256", "x": encoded(bytes.subdata(in: 1..<33)), "y": encoded(bytes.subdata(in: 33..<65))]
    }
    private func proof(_ key: P256.Signing.PrivateKey, _ request: URLRequest, token: String, nonce: String) throws -> String {
        let header: [String: Any] = ["alg": "ES256", "typ": "dpop+jwt", "jwk": jwk(key)]
        var target = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)!
        target.query = nil; target.fragment = nil
        let claims: [String: Any] = ["jti": UUID().uuidString, "htm": request.httpMethod ?? "GET",
            "htu": try XCTUnwrap(target.url).absoluteString,
            "iat": Int(Date().timeIntervalSince1970), "nonce": nonce,
            "ath": encoded(Data(SHA256.hash(data: Data(token.utf8)))),
            "tomo_bht": encoded(Data(SHA256.hash(data: request.httpBody ?? Data())))]
        let input = encoded(try JSONSerialization.data(withJSONObject: header)) + "." + encoded(try JSONSerialization.data(withJSONObject: claims))
        return input + "." + encoded(try key.signature(for: Data(input.utf8)).rawRepresentation)
    }
    private func ready(_ api: MobileSyncManager) async throws {
        let until = ContinuousClock.now.advanced(by: .seconds(8))
        while !api.isRunning, ContinuousClock.now < until {try await Task.sleep(for: .milliseconds(20))}
        XCTAssertTrue(api.isRunning)
    }
    func testSwitchPairedGatewayWritableCrashRecoveryGrantRotationAndStopWithoutCloud() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("phone-session-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {try? FileManager.default.removeItem(at: directory)}
        let suite = "PhoneSessionFlow." + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {defaults.removePersistentDomain(forName: suite)}
        defaults.set(Int(try RemoteTLSFixture.freePort()), forKey: "tomo.mobileSync.port")
        defaults.set("synthetic-phone-pairing", forKey: "tomo.mobileSync.token")
        let home = directory.appendingPathComponent("account")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let database = home.appendingPathComponent("state.sqlite")
        var db: OpaquePointer?
        guard sqlite3_open(database.path, &db) == SQLITE_OK, let db else {throw ChatGPTDirectoryError.unavailable}
        let schema = sqlite3_exec(db, "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, title TEXT, updated_at INTEGER, archived INTEGER, thread_source TEXT)", nil, nil, nil)
        sqlite3_close(db)
        guard schema == SQLITE_OK else {throw ChatGPTDirectoryError.incompatibleSchema}
        let executable = try PhoneConversationTests.syntheticExecutable(root: directory)
        let remote = RemoteProductionManager(cloud: DesktopCloudManager(defaults: defaults), directory: directory,
            sources: {_ in [RemoteReadServiceTests.Adapter(), ChatGPTReadAdapter(directory: .init(databaseURL: database,
                storageRoot: home, runtimeId: "rt_account"), runtimeLabel: "Synthetic account")]},
            signingIdentity: RemoteServerIdentity(storage: DesktopIdentityMemory()),
            preparePhoneConversation: {service in _ = try await service.ownedChatGPT.preparePhoneConversation(executable: executable)})
        let phone = PhoneSessionManager(defaults: defaults, remote: remote, storageRoot: directory)
        let api = MobileSyncManager(defaults: defaults, listenOnLoopbackOnly: true, phoneSessions: phone)
        let client = URLSession(configuration: .ephemeral); defer {client.invalidateAndCancel()}
        func make(_ base: URL, _ path: String, body: [String: Any]? = nil) throws -> URLRequest {
            var request = URLRequest(url: base.appendingPathComponent(path)); request.timeoutInterval = 4
            if let body {request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")}
            return request
        }
        func send(_ request: URLRequest, _ expected: Int) async throws -> (Data, HTTPURLResponse) {
            let (data, raw) = try await client.data(for: request), response = try XCTUnwrap(raw as? HTTPURLResponse)
            XCTAssertEqual(response.statusCode, expected, request.url?.path ?? "HTTP status")
            return (data, response)
        }
        func object(_ data: Data) throws -> [String: Any] {try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])}
        api.start()
        do {
            try await ready(api)
            let gateway = try XCTUnwrap(URL(string: "http://127.0.0.1:\(api.port)"))
            func paired(_ path: String, body: [String: Any]? = nil, token: String = "synthetic-phone-pairing") throws -> URLRequest {
                var request = try make(gateway, "api/v1/companion/" + path, body: body)
                request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization"); return request
            }
            _ = try await send(make(gateway, "api/v1/companion/session-setup"), 401)
            _ = try await send(paired("session-setup"), 404)
            phone.setEnabled(true); await phone.settled(); XCTAssertEqual(phone.status, .ready)
            XCTAssertTrue(remote.phonePairingEnabled); XCTAssertEqual(remote.authorizationMode, .local)
            let endpoint = try XCTUnwrap(remote.endpoint)
            let (descriptor, _) = try await send(paired("session-setup"), 200)
            let hosts = try XCTUnwrap(object(descriptor)["hosts"] as? [[String: Any]])
            let host = try XCTUnwrap(hosts.first), serverId = try XCTUnwrap(host["id"] as? String)
            XCTAssertEqual(host["endpoint"] as? String, endpoint.absoluteString)
            XCTAssertEqual((host["authorization"] as? [String: Any])?["kind"] as? String, "local")
            var crossSite = try paired("session-setup"); crossSite.setValue("https://other.example", forHTTPHeaderField: "Origin")
            _ = try await send(crossSite, 403)
            let device = P256.Signing.PrivateKey(), deviceId = UUID().uuidString.lowercased()
            let (identityData, _) = try await send(make(endpoint, "api/v1/remote/bindings/local-identity", body:
                ["deviceId": deviceId, "deviceName": "Synthetic phone", "publicKey": jwk(device)]), 200)
            var assertion = try XCTUnwrap(object(identityData)["identityAssertion"] as? String)
            func signedBinding(_ target: URL, _ path: String, expected: Int) async throws -> [String: Any] {
                let (_, challenge) = try await send(make(target, "api/v1/remote/bindings/nonce", body: ["identityAssertion": assertion]), 200)
                let nonce = try XCTUnwrap(challenge.value(forHTTPHeaderField: "DPoP-Nonce"))
                var request = try make(target, "api/v1/remote/bindings/" + path, body: ["identityAssertion": assertion])
                request.setValue(try proof(device, request, token: assertion, nonce: nonce), forHTTPHeaderField: "DPoP")
                return try object(try await send(request, expected).0)
            }
            _ = try await signedBinding(endpoint, "local-grant", expected: 401)
            let pending = try await signedBinding(endpoint, "requests", expected: 202)
            let requestId = try XCTUnwrap(pending["requestId"] as? String)
            _ = try await send(paired("session-pair", body: ["serverId": serverId, "requestId": requestId], token: "wrong"), 401)
            _ = try await send(paired("session-pair", body: ["serverId": serverId, "requestId": requestId, "scopes": ["*"]]), 400)
            _ = try await send(paired("session-pair", body: ["serverId": UUID().uuidString, "requestId": requestId]), 403)
            _ = try await send(paired("session-pair", body: ["serverId": serverId, "requestId": requestId]), 200)
            _ = try await send(paired("session-pair", body: ["serverId": serverId, "requestId": requestId]), 200)
            let grantValue = try await signedBinding(endpoint, "local-grant", expected: 200)
            let grant = try XCTUnwrap(grantValue["grant"] as? String)
            let (_, exchangeNonce) = try await send(make(endpoint, "api/v1/remote/access/exchange/nonce", body: ["grant": grant]), 200)
            let capabilities = try object(JSONEncoder().encode(RemoteClientCapabilities.v1))
            var exchange = try make(endpoint, "api/v1/remote/access/exchange", body: ["grant": grant, "clientCapabilities": capabilities])
            exchange.setValue(try proof(device, exchange, token: grant, nonce: XCTUnwrap(exchangeNonce.value(forHTTPHeaderField: "DPoP-Nonce"))), forHTTPHeaderField: "DPoP")
            let access = try object(try await send(exchange, 201).0), accessToken = try XCTUnwrap(access["accessToken"] as? String)
            var nonceRequest = try make(endpoint, "api/v1/remote/access/nonce"); nonceRequest.httpMethod = "POST"
            nonceRequest.setValue("DPoP " + accessToken, forHTTPHeaderField: "Authorization")
            let (_, nonceResponse) = try await send(nonceRequest, 200)
            var catalog = try make(endpoint, "api/v1/remote/catalog"); catalog.setValue("DPoP " + accessToken, forHTTPHeaderField: "Authorization")
            catalog.setValue(try proof(device, catalog, token: accessToken, nonce: XCTUnwrap(nonceResponse.value(forHTTPHeaderField: "DPoP-Nonce"))), forHTTPHeaderField: "DPoP")
            _ = try await send(catalog, 200)

            func readPage(_ path: String, token: String, body: [String: Any]? = nil,
                          expected: Int = 200, headers: [String: String] = [:], base: URL? = nil) async throws -> [String: Any] {
                let base = base ?? endpoint
                var challenge = try make(base, "api/v1/remote/access/nonce"); challenge.httpMethod = "POST"
                challenge.setValue("DPoP " + token, forHTTPHeaderField: "Authorization")
                let (_, nonce) = try await send(challenge, 200)
                var request = URLRequest(url: URL(string: base.absoluteString + path)!); request.timeoutInterval = 4
                if let body {
                    request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
                for (key, value) in headers {request.setValue(value, forHTTPHeaderField: key)}
                request.setValue("DPoP " + token, forHTTPHeaderField: "Authorization")
                request.setValue(try proof(device, request, token: token, nonce: XCTUnwrap(nonce.value(forHTTPHeaderField: "DPoP-Nonce"))), forHTTPHeaderField: "DPoP")
                return try object(try await send(request, expected).0)
            }
            // Exercise the production switch, pairing gateway, device proofs,
            // operation ledger and real private stdio process in one flow.
            let runtimeCatalog = try await readPage("/api/v1/remote/catalog", token: accessToken)
            let runtimes = try XCTUnwrap(runtimeCatalog["runtimes"] as? [[String: Any]])
            let phoneRuntime = try XCTUnwrap(runtimes.first {($0["runtimeId"] as? String)?.hasPrefix("rt_phone_") == true})
            let runtimeId = try XCTUnwrap(phoneRuntime["runtimeId"] as? String)
            XCTAssertTrue((phoneRuntime["allowedActions"] as? [String])?.contains("message.send") == true)
            let source = "agent_id=agent.chatgpt&runtime_id=" + runtimeId
            let directoryValue = try await readPage("/api/v1/remote/sessions?" + source, token: accessToken)
            let sessionId = try XCTUnwrap((directoryValue["items"] as? [[String: Any]])?.first?["sessionId"] as? String)
            let sessionPath = "/api/v1/remote/sessions/" + sessionId
            func sendMessage(_ text: String) async throws {
                let control = try await readPage(sessionPath + "/sync?" + source, token: accessToken)
                let operation = try await readPage(sessionPath + "/messages?" + source, token: accessToken, body: [
                    "executionEpoch": try XCTUnwrap(control["executionEpoch"] as? String),
                    "expectedControlRevision": try XCTUnwrap(control["controlRevision"] as? Int),
                    "clientMessageId": UUID().uuidString, "mode": "start", "input": [["type": "text", "text": text]]
                ], expected: 202, headers: ["Idempotency-Key": UUID().uuidString])
                let operationId = try XCTUnwrap(operation["operationId"] as? String)
                for _ in 0..<200 {
                    let result = try await readPage("/api/v1/remote/operations/" + operationId + "?" + source + "&session_id=" + sessionId, token: accessToken)
                    let state = try XCTUnwrap(result["state"] as? String)
                    if state == "applied" {return}
                    guard state == "accepted" || state == "dispatching" else {XCTFail("Synthetic send failed: " + state); return}
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTFail("Synthetic send did not settle")
            }
            try await sendMessage("before synthetic process exit")
            let before = try await readPage(sessionPath + "/sync?" + source, token: accessToken)
            let statePath = home.appendingPathComponent("synthetic-state.json")
            let oldProcess = try XCTUnwrap(try object(Data(contentsOf: statePath))["pid"] as? Int32)
            XCTAssertGreaterThan(oldProcess, 1)
            // This PID was written by the isolated synthetic executable launched
            // above. Terminate that child only; never target a vendor app/process.
            guard oldProcess > 1, Darwin.kill(oldProcess, SIGTERM) == 0 else {throw RemoteReadError.unavailable}
            let until = ContinuousClock.now.advanced(by: .seconds(5))
            while Darwin.kill(oldProcess, 0) == 0, ContinuousClock.now < until {try await Task.sleep(for: .milliseconds(10))}
            XCTAssertEqual(Darwin.kill(oldProcess, 0), -1)
            var recoveredDescriptor = Data(), replacementPID = oldProcess
            let recoveryDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            repeat {
                recoveredDescriptor = try await send(paired("session-setup"), 200).0
                replacementPID = try XCTUnwrap(try object(Data(contentsOf: statePath))["pid"] as? Int32)
                if replacementPID != oldProcess {break}
                try await Task.sleep(for: .milliseconds(100))
            } while ContinuousClock.now < recoveryDeadline
            XCTAssertNil(phone.message)
            XCTAssertNotEqual(replacementPID, oldProcess, "Paired configuration checks must launch a replacement")
            XCTAssertEqual(try object(recoveredDescriptor) as NSDictionary, try object(descriptor) as NSDictionary)
            let recovered = try await readPage(sessionPath + "/sync?" + source, token: accessToken)
            XCTAssertNotEqual(recovered["executionEpoch"] as? String, before["executionEpoch"] as? String)
            XCTAssertEqual((recovered["messages"] as? [[String: Any]])?.count, 2)
            _ = try await readPage(sessionPath + "/events?" + source, token: accessToken, expected: 409,
                headers: ["Last-Event-ID": try XCTUnwrap(before["eventCursor"] as? String)])
            try await sendMessage("after synthetic process exit")
            let after = try await readPage(sessionPath + "/sync?" + source, token: accessToken)
            XCTAssertEqual((after["messages"] as? [[String: Any]])?.count, 4)
            let agent = try object(Data(contentsOf: statePath))
            XCTAssertEqual(agent["starts"] as? Int, 1); XCTAssertEqual(agent["resumes"] as? Int, 1)
            XCTAssertEqual((agent["turns"] as? [Any])?.count, 2)
            await remote.refreshOwnerState()
            XCTAssertEqual(remote.ownerState?.bindings.first?.localVersion, 1, "Recovery must not require pairing again")
            let historyPath = "/api/v1/remote/sessions/ss_3/messages?agent_id=agent.chatgpt&runtime_id=runtime_test&limit=1"
            let historyFirst = try await readPage(historyPath, token: accessToken)
            let historyCursor = try XCTUnwrap(historyFirst["olderHistoryCursor"] as? String)
            let listPath = "/api/v1/remote/sessions?agent_id=agent.chatgpt&runtime_id=runtime_test&limit=1"
            let listFirst = try await readPage(listPath, token: accessToken), listCursor = try XCTUnwrap(listFirst["nextCursor"] as? String)
            let renewedGrantValue = try await signedBinding(endpoint, "local-grant", expected: 200)
            let renewedGrant = try XCTUnwrap(renewedGrantValue["grant"] as? String)
            let (_, renewalNonce) = try await send(make(endpoint, "api/v1/remote/access/exchange/nonce", body: ["grant": renewedGrant]), 200)
            var renewal = try make(endpoint, "api/v1/remote/access/exchange", body: ["grant": renewedGrant, "clientCapabilities": capabilities])
            renewal.setValue(try proof(device, renewal, token: renewedGrant, nonce: XCTUnwrap(renewalNonce.value(forHTTPHeaderField: "DPoP-Nonce"))), forHTTPHeaderField: "DPoP")
            let renewedAccess = try object(try await send(renewal, 201).0)
            let renewedToken = try XCTUnwrap(renewedAccess["accessToken"] as? String)
            XCTAssertNotEqual(renewedAccess["accessId"] as? String, access["accessId"] as? String)
            let olderPage = try await readPage(historyPath + "&history_cursor=" + historyCursor, token: renewedToken)
            XCTAssertEqual((olderPage["messages"] as? [[String: Any]])?.first?["messageId"] as? String, "msg_2")
            let olderList = try await readPage(listPath + "&cursor=" + listCursor, token: renewedToken)
            XCTAssertEqual((olderList["items"] as? [[String: Any]])?.first?["sessionId"] as? String, "ss_2")

            // The same already-paired phone can request the current desktop
            // policy after a default conversation becomes available. It still
            // needs a fresh device proof and the pairing gateway token.
            let (refreshIdentity, _) = try await send(make(endpoint, "api/v1/remote/bindings/local-identity", body:
                ["deviceId": deviceId, "deviceName": "Synthetic phone", "publicKey": jwk(device)]), 200)
            assertion = try XCTUnwrap(object(refreshIdentity)["identityAssertion"] as? String)
            let refreshPending = try await signedBinding(endpoint, "requests", expected: 202)
            let refreshId = try XCTUnwrap(refreshPending["requestId"] as? String)
            _ = try await send(paired("session-pair", body: ["serverId": serverId, "requestId": refreshId]), 200)
            _ = try await send(paired("session-pair", body: ["serverId": serverId, "requestId": requestId]), 403)
            _ = try await send(nonceRequest, 401)

            await remote.refreshOwnerState()
            let owner = try XCTUnwrap(remote.ownerState), binding = try XCTUnwrap(owner.bindings.first)
            XCTAssertEqual(binding.localVersion, 2)
            await remote.revokeDevice(userId: binding.userId, deviceId: binding.deviceId, expectedVersion: binding.localVersion, lease: owner.lease)
            _ = try await send(nonceRequest, 401)
            let (newIdentity, _) = try await send(make(endpoint, "api/v1/remote/bindings/local-identity", body:
                ["deviceId": deviceId, "deviceName": "Synthetic phone", "publicKey": jwk(device)]), 200)
            assertion = try XCTUnwrap(object(newIdentity)["identityAssertion"] as? String)
            let revokedPending = try await signedBinding(endpoint, "requests", expected: 202)
            let revokedId = try XCTUnwrap(revokedPending["requestId"] as? String)
            let (revokedBody, _) = try await send(paired("session-pair", body: ["serverId": serverId, "requestId": revokedId]), 403)
            XCTAssertEqual(try object(revokedBody)["error"] as? String, "phone_device_revoked")

            api.token = "rotated-synthetic-phone-pairing"
            try await ready(api); await phone.settled(); XCTAssertEqual(phone.status, .ready)
            XCTAssertNil(phone.message, "Rotating a pairing code must not replace or lose the durable conversation")
            let (rotatedData, _) = try await send(paired("session-setup", token: "rotated-synthetic-phone-pairing"), 200)
            let rotatedHost = try XCTUnwrap((try object(rotatedData)["hosts"] as? [[String: Any]])?.first)
            XCTAssertTrue((rotatedHost["resources"] as? [[String: Any]])?.contains {$0["runtimeId"] as? String == runtimeId} == true)
            _ = try await send(paired("session-setup"), 401)
            let newEndpoint = try XCTUnwrap(remote.endpoint)
            _ = try await signedBinding(newEndpoint, "local-grant", expected: 401)
            let (rotatedIdentity, _) = try await send(make(newEndpoint, "api/v1/remote/bindings/local-identity", body:
                ["deviceId": deviceId, "deviceName": "Synthetic phone", "publicKey": jwk(device)]), 200)
            assertion = try XCTUnwrap(object(rotatedIdentity)["identityAssertion"] as? String)
            let rotatedPending = try await signedBinding(newEndpoint, "requests", expected: 202)
            let rotatedRequestId = try XCTUnwrap(rotatedPending["requestId"] as? String)
            _ = try await send(paired("session-pair", body: ["serverId": serverId, "requestId": rotatedRequestId],
                token: "rotated-synthetic-phone-pairing"), 200)
            let rotatedGrantValue = try await signedBinding(newEndpoint, "local-grant", expected: 200)
            let rotatedGrant = try XCTUnwrap(rotatedGrantValue["grant"] as? String)
            func exchangeAfterRotation(_ value: String) async throws -> [String: Any] {
                let (_, nonce) = try await send(make(newEndpoint, "api/v1/remote/access/exchange/nonce", body: ["grant": value]), 200)
                var request = try make(newEndpoint, "api/v1/remote/access/exchange", body: ["grant": value, "clientCapabilities": capabilities])
                request.setValue(try proof(device, request, token: value, nonce: XCTUnwrap(nonce.value(forHTTPHeaderField: "DPoP-Nonce"))), forHTTPHeaderField: "DPoP")
                return try object(try await send(request, 201).0)
            }
            _ = try await send(make(newEndpoint, "api/v1/remote/access/exchange/nonce", body: ["grant": grant]), 401)
            let rotatedAccess = try await exchangeAfterRotation(rotatedGrant)
            let rotatedAccessToken = try XCTUnwrap(rotatedAccess["accessToken"] as? String)
            let preserved = try await readPage(sessionPath + "/sync?" + source, token: rotatedAccessToken, base: newEndpoint)
            XCTAssertEqual((preserved["messages"] as? [[String: Any]])?.count, 4)
            phone.setEnabled(false); await phone.settled(); XCTAssertEqual(phone.status, .disabled)
            _ = try await send(paired("session-setup", token: "rotated-synthetic-phone-pairing"), 404)
            _ = try await send(paired("session-pair", body: ["serverId": serverId, "requestId": requestId], token: "rotated-synthetic-phone-pairing"), 403)
            XCTAssertFalse(remote.phonePairingEnabled); XCTAssertEqual(remote.status, .stopped)
            phone.setEnabled(true); await phone.settled(); XCTAssertEqual(phone.status, .ready)
            XCTAssertNil(phone.message)
            api.isEnabled = false; await phone.settled()
            XCTAssertFalse(phone.isEnabled); XCTAssertFalse(remote.phonePairingEnabled); XCTAssertFalse(api.isRunning)
        } catch {phone.setEnabled(false); await phone.settled(); api.stop(); throw error}
        api.stop()
    }

    func testCompanionSecretIsLoopbackOnlyAndRejectsBrowserOriginAndDNSRebinding() {
        let port: UInt16 = 58350, local = NWEndpoint.hostPort(host: .ipv4(.loopback), port: 10000)
        let headers = ["host": "127.0.0.1:58350"]
        XCTAssertTrue(MobileSyncServer.allowsLocalCompanionConfiguration(peer: local, method: "GET", headers: headers, duplicateHeaders: [], port: port))
        XCTAssertFalse(MobileSyncServer.allowsLocalCompanionConfiguration(peer: .hostPort(host: "192.168.1.42", port: 10000), method: "GET", headers: headers, duplicateHeaders: [], port: port))
        XCTAssertFalse(MobileSyncServer.allowsLocalCompanionConfiguration(peer: local, method: "GET", headers: headers.merging(["origin": "https://other.example"]) {$1}, duplicateHeaders: [], port: port))
        XCTAssertFalse(MobileSyncServer.allowsLocalCompanionConfiguration(peer: local, method: "GET", headers: ["host": "rebind.example:58350"], duplicateHeaders: [], port: port))
        XCTAssertFalse(MobileSyncServer.allowsLocalCompanionConfiguration(peer: local, method: "GET", headers: headers, duplicateHeaders: ["host"], port: port))
    }
}
