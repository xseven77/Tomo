import XCTest
import CryptoKit
import Darwin
@testable import Tomo

@MainActor final class RemoteLocalServiceTests: XCTestCase {
    func testDefaultLoopbackEndpointDoesNotBindOtherLocalAddresses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-bind-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let port = try RemoteTLSFixture.freePort()
        let endpoint = URL(string: "http://127.0.0.1:\(port)")!
        let service = try await RemoteProductionService.startLocal(endpoint: endpoint, tlsIdentity: nil,
            signingIdentity: RemoteServerIdentity(storage: DesktopIdentityMemory()), directory: root,
            adapters: [RemoteReadServiceTests.Adapter()], name: "Synthetic loopback Mac")
        do {
            // Network's default wildcard listener would also occupy ::1.
            // Use an address actually assigned on macOS, not a loopback alias.
            let descriptor = socket(AF_INET6, SOCK_STREAM, 0)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            defer { Darwin.close(descriptor) }
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            XCTAssertEqual(inet_pton(AF_INET6, "::1", &address.sin6_addr), 1)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            XCTAssertEqual(bound, 0, "A loopback endpoint must leave other addresses unbound")
            let client = URLSession(configuration: .ephemeral)
            defer { client.invalidateAndCancel() }
            let (_, response) = try await client.data(from: endpoint.appendingPathComponent("api/v1/remote/catalog"))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
            await service.stop()
        } catch { await service.stop(); throw error }
    }

    func testLoopbackBindingIncludesIPv4RangeIPv6AndLocalhost() {
        for host in ["127.0.0.1", "127.3.4.5", "[::1]", "[::ffff:127.0.0.1]", "localhost", "LOCALHOST", "localhost."] {
            XCTAssertNotNil(RemoteEndpoint.loopbackBindHost(URL(string: "http://\(host):58352")!))
        }
        for host in ["192.168.1.7", "server.example", "[2001:db8::1]"] {
            XCTAssertNil(RemoteEndpoint.loopbackBindHost(URL(string: "http://\(host):58352")!))
        }
    }
    private func encoded(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private func jwk(_ key: P256.Signing.PrivateKey) -> [String: String] {
        let bytes = key.publicKey.x963Representation
        return ["kty": "EC", "crv": "P-256", "x": encoded(bytes.subdata(in: 1..<33)), "y": encoded(bytes.subdata(in: 33..<65))]
    }
    private func proof(key: P256.Signing.PrivateKey, request: URLRequest, token: String, nonce: String) throws -> String {
        var claims: [String: Any] = ["jti": UUID().uuidString, "htm": request.httpMethod ?? "GET",
            "htu": request.url!.absoluteString, "iat": Int(Date().timeIntervalSince1970), "nonce": nonce,
            "ath": encoded(Data(SHA256.hash(data: Data(token.utf8))))]
        if request.url!.scheme == "http" { claims["tomo_bht"] = encoded(Data(SHA256.hash(data: request.httpBody ?? Data()))) }
        let input = try encoded(JSONSerialization.data(withJSONObject: ["alg": "ES256", "typ": "dpop+jwt", "jwk": jwk(key)]))
            + "." + encoded(JSONSerialization.data(withJSONObject: claims))
        return input + "." + encoded(try key.signature(for: Data(input.utf8)).rawRepresentation)
    }
    private func run(scheme: String) async throws {
        let tls = try RemoteTLSFixture(); defer { tls.remove() }
        let signing = RemoteServerIdentity(storage: DesktopIdentityMemory()), device = P256.Signing.PrivateKey()
        let endpoint = URL(string: "\(scheme)://127.0.0.1:\(try RemoteTLSFixture.freePort())")!
        let service = try await RemoteProductionService.startLocal(endpoint: endpoint,
            tlsIdentity: scheme == "https" ? tls.identity : nil, signingIdentity: signing,
            directory: tls.directory.appendingPathComponent("service"), adapters: [RemoteReadServiceTests.Adapter()],
            name: "Local test Mac", bindHost: "127.0.0.1")
        let client = tls.session(); defer { client.invalidateAndCancel() }
        do {
            func request(_ path: String, body: [String: Any]? = nil) throws -> URLRequest {
                var value = URLRequest(url: endpoint.appendingPathComponent("api/v1/remote/" + path)); value.timeoutInterval = 5
                if let body { value.httpMethod = "POST"; value.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    value.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) }
                return value
            }
            func send(_ value: URLRequest, status: Int) async throws -> (Data, HTTPURLResponse) {
                let (body, raw) = try await client.data(for: value), response = try XCTUnwrap(raw as? HTTPURLResponse)
                XCTAssertEqual(response.statusCode, status, String(decoding: body, as: UTF8.self))
                return (body, response)
            }
            func object(_ value: Data) throws -> [String: Any] {
                try XCTUnwrap(JSONSerialization.jsonObject(with: value) as? [String: Any])
            }
            _ = try await send(request("catalog"), status: 401)
            let (assertionData, _) = try await send(request("bindings/local-identity", body: ["deviceId": UUID().uuidString.lowercased(),
                "deviceName": "Synthetic iPhone", "publicKey": jwk(device)]), status: 200)
            let assertion = try XCTUnwrap(object(assertionData)["identityAssertion"] as? String)
            let assertionBody: [String: Any] = ["identityAssertion": assertion]
            func bindingRequest(_ path: String, status: Int, extra: [String: Any] = [:]) async throws -> [String: Any] {
                let (_, response) = try await send(request("bindings/nonce", body: assertionBody), status: 200)
                let nonce = try XCTUnwrap(response.value(forHTTPHeaderField: "DPoP-Nonce"))
                var value = try request("bindings/" + path, body: assertionBody.merging(extra) { _, value in value })
                value.setValue(try proof(key: device, request: value, token: assertion, nonce: nonce), forHTTPHeaderField: "DPoP")
                let (body, _) = try await send(value, status: status); return try object(body)
            }
            _ = try await bindingRequest("local-grant", status: 401)
            let pending = try await bindingRequest("requests", status: 202)
            let id = try XCTUnwrap((pending["requestId"] as? String).flatMap(UUID.init(uuidString:)))
            let owner = try await service.ownerState()
            XCTAssertEqual(owner.pending.count, 1); XCTAssertTrue(owner.bindings.isEmpty)
            XCTAssertEqual(owner.pending.first?.userEmail, "本地设备")
            let runtimeIds = Set(owner.runtimes.map(\.id))
            try await service.ownerApprove(id: id, scopes: ["discovery", "session.read"], runtimeIds: runtimeIds, expectedVersion: 0)
            let issued = try await bindingRequest("local-grant", status: 200)
            let grant = try XCTUnwrap(issued["grant"] as? String)
            let requestedResources = try JSONSerialization.jsonObject(with: JSONEncoder().encode(owner.runtimes.map { try $0.resource() }))
            let limited = try await bindingRequest("local-grant", status: 200, extra: ["scopes": ["session.read", "session.write"],
                "resources": requestedResources])
            let limitedGrant = try XCTUnwrap(limited["grant"] as? String)
            let parts = limitedGrant.split(separator: ".")
            let payload = try XCTUnwrap(RemoteJWTCodec.base64URL(String(parts[1])))
            XCTAssertEqual(try object(payload)["scope"] as? String, "session.read")
            let (_, nonceResponse) = try await send(request("access/exchange/nonce", body: ["grant": grant]), status: 200)
            let nonce = try XCTUnwrap(nonceResponse.value(forHTTPHeaderField: "DPoP-Nonce"))
            let capabilities = try object(JSONEncoder().encode(RemoteClientCapabilities.v1))
            var exchange = try request("access/exchange", body: ["grant": grant, "clientCapabilities": capabilities])
            exchange.setValue(try proof(key: device, request: exchange, token: grant, nonce: nonce), forHTTPHeaderField: "DPoP")
            let (accessData, _) = try await send(exchange, status: 201)
            let access = try object(accessData), token = try XCTUnwrap(access["accessToken"] as? String)
            XCTAssertEqual(access["serverId"] as? String, service.server.id.uuidString.lowercased())
            var accessNonce = try request("access/nonce"); accessNonce.httpMethod = "POST"
            accessNonce.setValue("DPoP " + token, forHTTPHeaderField: "Authorization")
            let (_, readNonceResponse) = try await send(accessNonce, status: 200)
            let readNonce = try XCTUnwrap(readNonceResponse.value(forHTTPHeaderField: "DPoP-Nonce"))
            var catalog = try request("catalog"); catalog.setValue("DPoP " + token, forHTTPHeaderField: "Authorization")
            catalog.setValue(try proof(key: device, request: catalog, token: token, nonce: readNonce), forHTTPHeaderField: "DPoP")
            _ = try await send(catalog, status: 200)
            _ = try await send(catalog, status: 401)
            let approvedState = try await service.ownerState()
            let binding = try XCTUnwrap(approvedState.bindings.first)
            try await service.ownerRevoke(userId: binding.userId, deviceId: binding.deviceId, expectedVersion: binding.localVersion)
            _ = try await send(accessNonce, status: 401)
            _ = try await bindingRequest("local-grant", status: 401)
            var browser = try request("bindings/local-identity", body: ["deviceId": UUID().uuidString,
                "deviceName": "Untrusted browser", "publicKey": jwk(device)])
            browser.setValue("https://untrusted.example.test", forHTTPHeaderField: "Origin")
            _ = try await send(browser, status: 403)
            await service.stop()
            do { _ = try await client.data(for: catalog); XCTFail("Stopped local service accepted a connection") } catch {}
        } catch { await service.stop(); throw error }
    }
    func testRealHTTPLocalApprovalExchangeReadReplayAndRevokeWithoutCloud() async throws { try await run(scheme: "http") }
    func testRealHTTPSLocalApprovalExchangeReadReplayAndRevokeWithoutCloud() async throws { try await run(scheme: "https") }
}
