import Foundation
import JWTKit
import CryptoKit

/// Only constructs trust from an explicitly configured control-plane JWKS.
/// Does not fetch keys or follow a token's jku/jwk/x5u headers.
actor RemoteCloudGrantVerifier {
    struct Resource: Codable, Equatable, Sendable {
        let kind: String
        let agentId: String?
        let runtimeId: String?
        let workspaceId: String?
        let agentPolicy: String?

        private struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: Key.self)
            func read(_ name: String) throws -> String { try values.decode(String.self, forKey: Key(stringValue: name)!) }
            kind = try read("kind")
            let names = Set(values.allKeys.map(\.stringValue))
            switch kind {
            case "runtime":
                guard names == ["kind", "agentId", "runtimeId"] else { throw RemoteAccessError.unauthorized }
                agentId = try read("agentId"); runtimeId = try read("runtimeId")
                workspaceId = nil; agentPolicy = nil
                guard agentId!.range(of: "^[a-z][a-z0-9._-]{0,127}$", options: .regularExpression) != nil,
                      Self.validID(runtimeId!) else { throw RemoteAccessError.unauthorized }
            case "workspace":
                guard names == ["kind", "workspaceId", "agentPolicy"] else { throw RemoteAccessError.unauthorized }
                workspaceId = try read("workspaceId"); agentPolicy = try read("agentPolicy")
                agentId = nil; runtimeId = nil
                guard Self.validID(workspaceId!), agentPolicy == "registered" else { throw RemoteAccessError.unauthorized }
            default: throw RemoteAccessError.unauthorized
            }
        }
        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: Key.self)
            try values.encode(kind, forKey: Key(stringValue: "kind")!)
            for (name, value) in [("agentId", agentId), ("runtimeId", runtimeId), ("workspaceId", workspaceId), ("agentPolicy", agentPolicy)] {
                if let value { try values.encode(value, forKey: Key(stringValue: name)!) }
            }
        }
        private static func validID(_ value: String) -> Bool {
            value.range(of: "^[A-Za-z0-9_-]{1,160}$", options: .regularExpression) != nil
        }
    }
    struct Confirmation: Codable, Sendable { let jkt: String }
    struct Claims: JWTPayload {
        let iss: String
        let aud: String
        let sub: String
        let deviceId: String
        let cnf: Confirmation
        let bindingId: String
        let bindingRevision: Int
        let entitlementVersion: Int
        let scope: String
        let resources: [Resource]
        let iat: Int
        let nbf: Int
        let exp: Int
        let jti: String

        func verify(using algorithm: some JWTAlgorithm) async throws {
            try validate()
        }
        func validate() throws {
            guard iat > 0, exp > iat, exp - iat <= 300, nbf == iat,
                  bindingRevision > 0, entitlementVersion >= 0,
                  [aud, sub, deviceId, bindingId, jti].allSatisfy({ UUID(uuidString: $0) != nil }),
                  cnf.jkt.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
                  resources.count <= 128, scope.utf8.count <= 128 else { throw RemoteAccessError.unauthorized }
            let scopes = scope.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            let known: Set<String> = ["server.identity", "discovery", "session.read", "session.write", "session.approve"]
            guard !scopes.isEmpty, Set(scopes).count == scopes.count, Set(scopes).isSubset(of: known),
                  scopes.contains(where: { $0 != "server.identity" }) ? !resources.isEmpty : resources.isEmpty
            else { throw RemoteAccessError.unauthorized }
        }
    }
    private var keys: JWTKeyCollection
    private var keyIDs: Set<String>
    private let issuer: String
    private let serverId: String
    private var trustedUntil: Date
    private var trustGeneration: UInt64 = 0

    private init(keys: JWTKeyCollection, keyIDs: Set<String>, issuer: String, serverId: String, trustedUntil: Date) {
        self.keys = keys; self.keyIDs = keyIDs; self.issuer = issuer
        self.serverId = serverId; self.trustedUntil = trustedUntil
    }
    static func configured(jwks: Data, issuer: String, serverId: String, trustedUntil: Date,
                           now: Date = Date()) async throws -> RemoteCloudGrantVerifier {
        guard jwks.count <= 65536, let url = URLComponents(string: issuer), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              UUID(uuidString: serverId) != nil, trustedUntil.timeIntervalSince(now).isFinite,
              trustedUntil > now, trustedUntil.timeIntervalSince(now) <= 300 else { throw RemoteAccessError.invalidConfiguration }
        do {
            let object = try JSONSerialization.jsonObject(with: jwks) as? [String: Any]
            guard let object, Set(object.keys) == ["keys"], let entries = object["keys"] as? [[String: Any]],
                  !entries.isEmpty, entries.count <= 16 else { throw RemoteAccessError.invalidConfiguration }
            var ids = Set<String>()
            for entry in entries {
                guard Set(entry.keys).isSubset(of: ["kty", "crv", "x", "y", "kid", "alg", "use"]),
                      entry["kty"] as? String == "EC", entry["crv"] as? String == "P-256",
                      entry["alg"] as? String == "ES256", entry["use"] as? String == "sig",
                      let kid = entry["kid"] as? String, kid.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil,
                      ids.insert(kid).inserted, let x = entry["x"] as? String, let y = entry["y"] as? String,
                      base64URL(x)?.count == 32, base64URL(y)?.count == 32 else { throw RemoteAccessError.invalidConfiguration }
            }
            let keys = JWTKeyCollection()
            try await keys.add(jwksJSON: String(decoding: jwks, as: UTF8.self))
            return RemoteCloudGrantVerifier(keys: keys, keyIDs: ids, issuer: issuer, serverId: serverId, trustedUntil: trustedUntil)
        } catch { throw RemoteAccessError.invalidConfiguration }
    }
    func verify(_ token: String, now: Date = Date()) async throws -> Claims {
        let generation = trustGeneration, started = ContinuousClock.now
        guard now < trustedUntil, now.timeIntervalSince1970.isFinite, token.utf8.count <= 32768 else { throw RemoteAccessError.unauthorized }
        do {
            let parts = token.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3, parts.allSatisfy({ Self.base64URL(String($0)) != nil }),
                  let headerData = Self.base64URL(String(parts[0])),
                  let header = try JSONSerialization.jsonObject(with: headerData) as? [String: String],
                  Set(header.keys) == ["alg", "typ", "kid"], header["alg"] == "ES256",
                  header["typ"] == "tomo-remote-grant+jwt", let kid = header["kid"], keyIDs.contains(kid)
            else { throw RemoteAccessError.unauthorized }
            let claims = try await keys.verify(token, as: Claims.self)
            try checkTrust(generation, now: now, started: started)
            let time = Self.current(now, started: started).timeIntervalSince1970
            guard claims.iss == issuer, claims.aud == serverId, Double(claims.nbf) <= time,
                  Double(claims.exp) > time, Double(claims.iat) <= time else { throw RemoteAccessError.unauthorized }
            return claims
        } catch { throw RemoteAccessError.unauthorized }
    }
    struct BindingIdentity: JWTPayload {
        let iss: String, aud: String, sub: String, deviceId: String
        let cnf: Confirmation
        let deviceName: String, userEmail: String, challengeId: String, nonce: String, scope: String
        let bindingRevision: Int, iat: Int, nbf: Int, exp: Int
        let jti: String
        func verify(using algorithm: some JWTAlgorithm) async throws {
            guard [aud, sub, deviceId, challengeId, jti].allSatisfy({ UUID(uuidString: $0) != nil }),
                  jti == challengeId, scope == "server.bind", bindingRevision > 0,
                  bindingRevision <= 9_007_199_254_740_991, iat > 0, nbf == iat, exp > iat, exp - iat <= 300,
                  RemoteJWTCodec.base64URL(cnf.jkt)?.count == 32, RemoteJWTCodec.base64URL(nonce)?.count == 32,
                  !deviceName.isEmpty, deviceName.count <= 80, !userEmail.isEmpty, userEmail.utf8.count <= 254,
                  userEmail.contains("@"), [deviceName, userEmail].allSatisfy({ !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else {
                throw RemoteAccessError.unauthorized
            }
        }
    }
    func verifyBindingIdentity(_ token: String, now: Date = Date()) async throws -> BindingIdentity {
        let generation = trustGeneration, started = ContinuousClock.now
        guard now < trustedUntil, now.timeIntervalSince1970.isFinite, token.utf8.count <= 32768 else { throw RemoteAccessError.unauthorized }
        do {
            let parts = token.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3, parts.allSatisfy({ Self.base64URL(String($0)) != nil }),
                  let headerData = Self.base64URL(String(parts[0])),
                  let header = try JSONSerialization.jsonObject(with: headerData) as? [String: String],
                  Set(header.keys) == ["alg", "typ", "kid"], header["alg"] == "ES256",
                  header["typ"] == "tomo-binding-identity+jwt", let kid = header["kid"], keyIDs.contains(kid),
                  let payloadData = Self.base64URL(String(parts[1])),
                  let object = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
                  Set(object.keys) == ["iss", "aud", "sub", "deviceId", "cnf", "deviceName", "userEmail", "challengeId", "nonce", "bindingRevision", "iat", "nbf", "exp", "jti", "scope"],
                  let cnf = object["cnf"] as? [String: String], Set(cnf.keys) == ["jkt"] else { throw RemoteAccessError.unauthorized }
            let claims = try await keys.verify(token, as: BindingIdentity.self)
            try checkTrust(generation, now: now, started: started)
            let time = Self.current(now, started: started).timeIntervalSince1970
            guard claims.iss == issuer, claims.aud == serverId, Double(claims.nbf) <= time,
                  Double(claims.exp) > time, Double(claims.iat) <= time else { throw RemoteAccessError.unauthorized }
            return claims
        } catch { throw RemoteAccessError.unauthorized }
    }
    private struct PlatformClaims: JWTPayload {
        let iss: String, aud: String, sub: String, deviceId: String, grantId: String, requestHash: String
        let cnf: Confirmation
        let platform: String, environment: String, version: String
        let category: Int?
        let deviceIntegrity: String?
        let iat: Int, nbf: Int, exp: Int, jti: String
        func verify(using algorithm: some JWTAlgorithm) async throws {
            guard iat > 0, nbf == iat, exp > iat, exp - iat <= 60,
                  environment == "production", !version.isEmpty, version.utf8.count <= 64,
                  [aud, sub, deviceId, grantId, jti].allSatisfy({ UUID(uuidString: $0) != nil }),
                  RemoteJWTCodec.base64URL(requestHash)?.count == 32,
                  RemoteJWTCodec.base64URL(cnf.jkt)?.count == 32 else { throw RemoteAccessError.forbidden }
            switch platform {
            case "ios":
                guard let category, (1...10).contains(category), ![7, 8, 9].contains(category), deviceIntegrity == nil else {
                    throw RemoteAccessError.forbidden
                }
            case "android":
                guard category == nil, deviceIntegrity == "MEETS_DEVICE_INTEGRITY",
                      version.range(of: "^[1-9][0-9]{0,9}$", options: .regularExpression) != nil,
                      let code = Int(version), code <= 2_100_000_000 else { throw RemoteAccessError.forbidden }
            default: throw RemoteAccessError.forbidden
            }
        }
    }
    /// A cloud-signed proof of this exact native HTTP exchange. It adds no scope;
    /// grant, DPoP and persistent local ACL are still checked by the router.
    func verifyPlatformRequest(_ request: RemoteProductionAccessRouter.Request, now: Date = Date()) async throws {
        let generation = trustGeneration, started = ContinuousClock.now
        do {
            guard now < trustedUntil, now.timeIntervalSince1970.isFinite, request.method == "POST", request.query.isEmpty,
                  ["/api/v1/remote/access/exchange/nonce", "/api/v1/remote/access/exchange"].contains(request.path),
                  request.body.count <= 40960,
                  let body = try JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let grant = body["grant"] as? String else { throw RemoteAccessError.forbidden }
            let headers = request.headers.filter { $0.0.lowercased() == "x-tomo-platform-receipt" }
            guard headers.count == 1, headers[0].1.utf8.count <= 8192 else { throw RemoteAccessError.forbidden }
            let token = headers[0].1, parts = token.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3, parts.allSatisfy({ Self.base64URL(String($0)) != nil }),
                  let headerData = Self.base64URL(String(parts[0])),
                  let header = try JSONSerialization.jsonObject(with: headerData) as? [String: String],
                  Set(header.keys) == ["alg", "typ", "kid"], header["alg"] == "ES256",
                  header["typ"] == "tomo-platform-receipt+jwt", let kid = header["kid"], keyIDs.contains(kid),
                  let payloadData = Self.base64URL(String(parts[1])),
                  let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
                  Self.validPlatformFields(payload),
                  let confirmation = payload["cnf"] as? [String: String], Set(confirmation.keys) == ["jkt"] else {
                throw RemoteAccessError.forbidden
            }
            let grantClaims = try await verify(grant, now: now)
            let claims = try await keys.verify(token, as: PlatformClaims.self)
            try checkTrust(generation, now: now, started: started)
            guard let targetId = UUID(uuidString: grantClaims.aud), let grantId = UUID(uuidString: grantClaims.jti) else {
                throw RemoteAccessError.forbidden
            }
            let bodyHash = Self.encoded(Data(SHA256.hash(data: request.body)))
            let input = ["tomo-platform-http-v1", targetId.uuidString.lowercased(), grantId.uuidString.lowercased(),
                         request.method, request.path, bodyHash].joined(separator: "\n")
            let expected = Self.encoded(Data(SHA256.hash(data: Data(input.utf8))))
            let time = Self.current(now, started: started).timeIntervalSince1970
            guard claims.iss == issuer, claims.aud == grantClaims.aud, claims.sub == grantClaims.sub,
                  claims.deviceId == grantClaims.deviceId, claims.cnf.jkt == grantClaims.cnf.jkt,
                  claims.grantId == grantClaims.jti, claims.requestHash == expected,
                  Double(claims.iat) <= time, Double(claims.exp) > time,
                  claims.exp <= grantClaims.exp else { throw RemoteAccessError.forbidden }
        } catch { throw RemoteAccessError.forbidden }
    }
    private static func validPlatformFields(_ payload: [String: Any]) -> Bool {
        let common: Set<String> = ["iss", "aud", "sub", "deviceId", "cnf", "grantId", "requestHash", "platform", "environment", "version", "iat", "nbf", "exp", "jti"]
        switch payload["platform"] as? String {
        case "ios": return Set(payload.keys) == common.union(["category"])
        case "android": return Set(payload.keys) == common.union(["deviceIntegrity"])
        default: return false
        }
    }
    /// Native control-plane refresh. Replacement drops all retired keys.
    func replaceTrust(jwks: Data, trustedUntil: Date, now: Date = Date()) async throws {
        let generation = trustGeneration, started = ContinuousClock.now
        let candidate = try await Self.configured(jwks: jwks, issuer: issuer, serverId: serverId,
                                                  trustedUntil: trustedUntil, now: now)
        let snapshot = await candidate.snapshot()
        try Task.checkCancellation()
        guard generation == trustGeneration, trustedUntil > Self.current(now, started: started) else { throw RemoteAccessError.unauthorized }
        trustGeneration &+= 1; keys = snapshot.0; keyIDs = snapshot.1; self.trustedUntil = trustedUntil
    }
    func invalidateTrust() { trustGeneration &+= 1; trustedUntil = .distantPast }
    private func snapshot() -> (JWTKeyCollection, Set<String>) { (keys, keyIDs) }
    private func checkTrust(_ generation: UInt64, now: Date, started: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard generation == trustGeneration, Self.current(now, started: started) < trustedUntil else { throw RemoteAccessError.unauthorized }
    }
    private static func current(_ now: Date, started: ContinuousClock.Instant) -> Date {
        let elapsed = started.duration(to: .now).components
        return now.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    }
    private static func encoded(_ value: Data) -> String {
        value.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func base64URL(_ value: String) -> Data? { RemoteJWTCodec.base64URL(value) }
}
