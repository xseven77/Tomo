import Foundation

/// Authorization boundary for the opt-in trusted HTTPS listener. This is not
/// mounted on the legacy plaintext MobileSyncServer. The listener must reject
/// malformed framing and supply a platform verifier backed by native attestation.
struct RemoteProductionAccessRouter: Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [(String, String)] // Preserve duplicates; do not flatten beforehand.
        let body: Data
    }
    struct Response: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
    }
    enum Result: Sendable {
        case response(Response)
        case authorized(RemoteAccessStore.Principal)
    }
    let exchange: RemoteGrantExchange
    /// Trusted integration dependency, never derived from Origin/User-Agent or
    /// an app=true flag. No default pass-through is provided.
    let verifyPlatform: @Sendable (Request) async throws -> Void

    static func cloudVerified(exchange: RemoteGrantExchange, cloud: RemoteCloudGrantVerifier) -> Self {
        .init(exchange: exchange, verifyPlatform: { request in try await cloud.verifyPlatformRequest(request) })
    }

    /// The local profile authenticates the desktop-approved device grant. It
    /// makes no cloud membership or platform-attestation assertion.
    static func localApproved(exchange: RemoteGrantExchange, authority: RemoteLocalGrantAuthority) -> Self {
        .init(exchange: exchange, verifyPlatform: { request in
            guard let object = try JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let grant = object["grant"] as? String else { throw RemoteAccessError.forbidden }
            _ = try await authority.verify(grant)
        })
    }

    func handle(_ request: Request, now: Date? = nil) async -> Result {
        let started = ContinuousClock.now
        func checkedAt() -> Date? {
            guard let now else { return nil }
            let elapsed = started.duration(to: .now).components
            return now.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
        }
        do {
            guard now?.timeIntervalSince1970.isFinite ?? true else { throw RemoteReadError.invalidRequest }
            let headers = try checkedHeaders(request)
            guard headers["origin"] == nil else { throw RemoteAccessError.forbidden }
            let exchangePath = "/api/v1/remote/access/exchange"
            if request.path == exchangePath || request.path == exchangePath + "/nonce" {
                let nonceRequest = request.path.hasSuffix("/nonce")
                guard request.method == "POST", request.query.isEmpty, headers["authorization"] == nil,
                      headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json",
                      request.body.count <= 40960,
                      let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
                      Set(json.keys) == (nonceRequest ? ["grant"] : ["grant", "clientCapabilities"]),
                      let grant = json["grant"] as? String, !grant.isEmpty else { throw RemoteReadError.invalidRequest }
                let client = nonceRequest ? nil : try clientCapabilities(json["clientCapabilities"])
                try await verifyPlatform(request)
                if nonceRequest {
                    guard headers["dpop"] == nil else { throw RemoteReadError.invalidRequest }
                    let nonce = try await exchange.exchangeNonce(grant: grant, now: checkedAt())
                    return .response(try response(200, ["DPoP-Nonce": nonce], object: ["nonceRequired": true]))
                }
                guard let proof = headers["dpop"], !proof.isEmpty, let client else { throw RemoteAccessError.unauthorized }
                let issued = try await exchange.exchange(grant: grant, dpop: proof, client: client, body: request.body, now: checkedAt())
                let formatter = ISO8601DateFormatter()
                let negotiated = try client.negotiatedProtocol()
                return .response(try response(201, object: ["serverId": exchange.serverId, "accessId": issued.principal.id.uuidString,
                    "accessToken": issued.token, "tokenType": issued.tokenType, "expiresAt": formatter.string(from: issued.principal.expiresAt),
                    "negotiatedProtocol": ["apiMajor": negotiated.apiMajor, "eventMajor": negotiated.eventMajor, "contentMajor": negotiated.contentMajor]]))
            }
            if request.path == "/api/v1/remote/access/nonce" {
                guard request.method == "POST", request.query.isEmpty, request.body.isEmpty, headers["dpop"] == nil else {
                    throw RemoteReadError.invalidRequest
                }
                let nonce = try await exchange.accessNonce(authorization: headers["authorization"], now: checkedAt())
                return .response(try response(200, ["DPoP-Nonce": nonce], object: ["nonceRequired": true]))
            }
            guard let proof = headers["dpop"], !proof.isEmpty else { throw RemoteAccessError.unauthorized }
            let principal = try await exchange.authenticate(authorization: headers["authorization"], dpop: proof,
                method: request.method, path: request.path, body: request.body, now: checkedAt())
            if request.path == "/api/v1/remote/access/current" {
                guard request.method == "DELETE", request.query.isEmpty, request.body.isEmpty else { throw RemoteReadError.invalidRequest }
                try await exchange.revoke(principal)
                return .response(try response(204))
            }
            return .authorized(principal)
        } catch RemoteReadError.invalidRequest {
            return .response(error(400, "invalid_remote_request"))
        } catch RemoteAccessError.forbidden {
            return .response(error(403, "remote_access_denied"))
        } catch RemoteAccessError.unauthorized {
            return .response(error(401, "remote_access_required"))
        } catch RemoteAccessError.unavailable {
            return .response(self.error(503, "remote_access_unavailable"))
        } catch RemoteAccessError.protocolIncompatible {
            return .response(self.error(426, "protocol_incompatible"))
        } catch {
            // Invalid native verifier/configuration/data must never expose an
            // underlying error, token, private path or partially issued access.
            return .response(self.error(503, "remote_access_unavailable"))
        }
    }
    private func clientCapabilities(_ value: Any?) throws -> RemoteClientCapabilities {
        guard let object = value as? [String: Any], Set(object.keys) == ["descriptorMajors", "apiMajors", "eventMajors", "contentMajors", "clientFeatures"],
              let data = try? JSONSerialization.data(withJSONObject: object),
              let result = try? JSONDecoder().decode(RemoteClientCapabilities.self, from: data) else { throw RemoteReadError.invalidRequest }
        let normalized = try result.normalized()
        _ = try normalized.negotiatedProtocol()
        return normalized
    }
    private func checkedHeaders(_ request: Request) throws -> [String: String] {
        guard validRequest(request), !request.query.keys.contains(where: {
            ["token", "access_token", "grant", "dpop", "authorization"].contains($0.lowercased())
        }) else { throw RemoteReadError.invalidRequest }
        var headers: [String: String] = [:]
        var bytes = 0
        for (name, value) in request.headers {
            bytes += name.utf8.count + value.utf8.count + 4
            let normalized = name.lowercased()
            guard bytes <= 16384, name.range(of: "^[!#$%&'*+.^_`|~A-Za-z0-9-]+$", options: .regularExpression) != nil,
                  !value.utf8.contains(where: { $0 == 13 || $0 == 10 || $0 == 0 }), headers[normalized] == nil else {
                throw RemoteReadError.invalidRequest
            }
            headers[normalized] = value.trimmingCharacters(in: .whitespaces)
        }
        return headers
    }
    private func validRequest(_ request: Request) -> Bool {
        request.headers.count <= 100 && request.body.count <= HTTPRequestFramer.maxBodyBytes &&
        request.method.range(of: "^[A-Z]{1,16}$", options: .regularExpression) != nil &&
        request.path.hasPrefix("/api/v1/remote/") && request.path.utf8.count <= 2048 &&
        !request.path.contains(where: { $0.isWhitespace }) && !request.path.contains("?") &&
        !request.path.contains("#") && !request.path.contains("\\")
    }
    private func response(_ status: Int, _ additional: [String: String] = [:], object: [String: Any]? = nil) throws -> Response {
        let headers = ["Content-Type": "application/json", "Cache-Control": "no-store", "Pragma": "no-cache"].merging(additional) { _, new in new }
        return Response(status: status, headers: headers, body: try object.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) } ?? Data())
    }
    private func error(_ status: Int, _ code: String) -> Response {
        Response(status: status, headers: ["Content-Type": "application/json", "Cache-Control": "no-store"], body: Data("{\"error\":\"\(code)\"}".utf8))
    }
}
