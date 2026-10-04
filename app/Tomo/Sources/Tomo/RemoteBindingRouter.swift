import Foundation

/// HTTPS device-possession boundary for pairing. Local owner approval remains
/// outside this router; submitting a signed identity never grants permissions.
struct RemoteBindingRouter: Sendable {
    static let root = "/api/v1/remote/bindings"
    let endpoint: URL
    let cloud: RemoteCloudGrantVerifier
    let proof: RemoteDPoPVerifier
    let approval: RemoteBindingApproval

    init(endpoint: URL, cloud: RemoteCloudGrantVerifier, proof: RemoteDPoPVerifier, approval: RemoteBindingApproval) throws {
        guard let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false), parts.scheme == "https",
              parts.host?.isEmpty == false, parts.user == nil, parts.password == nil, parts.query == nil,
              parts.fragment == nil, parts.path.isEmpty || parts.path == "/" else { throw RemoteAccessError.invalidConfiguration }
        self.endpoint = endpoint; self.cloud = cloud; self.proof = proof; self.approval = approval
    }

    func handle(_ request: RemoteProductionAccessRouter.Request, now: Date = Date()) async -> RemoteProductionAccessRouter.Response {
        let started = ContinuousClock.now
        func current() -> Date {
            let elapsed = started.duration(to: .now).components
            return now.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
        }
        do {
            let headers = try checkedHeaders(request)
            guard headers["origin"] == nil else { throw RemoteAccessError.forbidden }
            guard now.timeIntervalSince1970.isFinite, request.query.isEmpty else { throw RemoteReadError.invalidRequest }
            let assertion: String
            let submit = request.path == Self.root + "/requests"
            let nonce = request.path == Self.root + "/nonce"
            var id: UUID?
            if nonce || submit {
                guard request.method == "POST", headers["authorization"] == nil,
                      headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json",
                      let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: String],
                      Set(json.keys) == ["identityAssertion"], let token = json["identityAssertion"] else { throw RemoteReadError.invalidRequest }
                assertion = token
            } else {
                let prefix = Self.root + "/requests/"
                guard request.method == "GET", request.body.isEmpty, request.path.hasPrefix(prefix),
                      let parsed = UUID(uuidString: String(request.path.dropFirst(prefix.count))),
                      let auth = headers["authorization"], auth.hasPrefix("DPoP ") else { throw RemoteReadError.invalidRequest }
                id = parsed; assertion = String(auth.dropFirst(5))
            }
            let claims = try await cloud.verifyBindingIdentity(assertion, now: current())
            if nonce {
                guard headers["dpop"] == nil else { throw RemoteReadError.invalidRequest }
                let value = try await proof.challenge(thumbprint: claims.cnf.jkt,
                    expiresAt: Date(timeIntervalSince1970: Double(claims.exp)), now: current())
                return try response(200, ["nonceRequired": true], headers: ["DPoP-Nonce": value])
            }
            guard let dpop = headers["dpop"], let target = URL(string: request.path, relativeTo: endpoint)?.absoluteURL else { throw RemoteAccessError.unauthorized }
            try await proof.verify(dpop, thumbprint: claims.cnf.jkt, token: assertion,
                method: request.method, url: target, now: current())
            guard Double(claims.exp) > current().timeIntervalSince1970 else { throw RemoteAccessError.unauthorized }
            if submit {
                let pending = try await approval.prepare(assertion: assertion, now: current())
                return try response(202, ["status": "pending", "requestId": pending.id.uuidString.lowercased(),
                    "expiresAt": ISO8601DateFormatter().string(from: pending.expiresAt)])
            }
            guard let id, UUID(uuidString: claims.challengeId) == id else { throw RemoteAccessError.forbidden }
            _ = try await cloud.verifyBindingIdentity(assertion, now: current())
            switch try await approval.outcome(id: id, assertion: assertion, now: current()) {
            case .pending(let expires): return try response(200, ["status": "pending", "requestId": id.uuidString.lowercased(), "expiresAt": ISO8601DateFormatter().string(from: expires)])
            case .approved(let receipt): return try response(200, ["status": "approved", "requestId": id.uuidString.lowercased(), "receipt": receipt])
            case .rejected: return try response(403, ["status": "rejected", "requestId": id.uuidString.lowercased()])
            }
        } catch RemoteReadError.invalidRequest { return self.error(400, "invalid_binding_request") }
        catch RemoteAccessError.unauthorized { return self.error(401, "binding_identity_required") }
        catch RemoteAccessError.forbidden { return self.error(403, "binding_denied") }
        catch { return self.error(503, "binding_unavailable") }
    }

    private func checkedHeaders(_ request: RemoteProductionAccessRouter.Request) throws -> [String: String] {
        guard request.headers.count <= 100, request.body.count <= 40960, request.path.utf8.count <= 2048,
              !request.path.contains(where: { $0.isWhitespace }), !request.path.contains("?"), !request.path.contains("#") else {
            throw RemoteReadError.invalidRequest
        }
        var headers: [String: String] = [:], bytes = 0
        for (name, value) in request.headers {
            bytes += name.utf8.count + value.utf8.count + 4
            let lower = name.lowercased()
            guard bytes <= 16384, name.range(of: "^[!#$%&'*+.^_`|~A-Za-z0-9-]+$", options: .regularExpression) != nil,
                  !value.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 }), headers[lower] == nil else { throw RemoteReadError.invalidRequest }
            headers[lower] = value.trimmingCharacters(in: .whitespaces)
        }
        return headers
    }
    private func response(_ status: Int, _ object: [String: Any], headers: [String: String] = [:]) throws -> RemoteProductionAccessRouter.Response {
        .init(status: status, headers: ["Content-Type": "application/json", "Cache-Control": "no-store"].merging(headers) { _, value in value },
            body: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }
    private func error(_ status: Int, _ code: String) -> RemoteProductionAccessRouter.Response {
        .init(status: status, headers: ["Content-Type": "application/json", "Cache-Control": "no-store"], body: Data("{\"error\":\"\(code)\"}".utf8))
    }
}
