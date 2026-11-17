import Foundation
import CryptoKit
import Security

/// Local grants derive exclusively from a durable owner-approved device ACL.
/// They have a distinct JWT type and issuer; cloud verification never trusts
/// this profile. This actor exposes no approval or arbitrary signing operation.
actor RemoteLocalGrantAuthority: RemoteGrantVerifier, RemoteBindingIdentityVerifier {
    struct Identity: Sendable, Equatable {
        let serverId: UUID, ownerId: UUID
        let publicKeyPem: String, thumbprint: String
        var issuer: String { "tomo-local:" + serverId.uuidString.lowercased() }
    }
    nonisolated let identity: Identity
    private let key: P256.Signing.PrivateKey
    private let ledger: RemoteAuthorizationLedger
    private var stopped = false

    static func identity(for key: P256.Signing.PublicKey) throws -> Identity {
        let thumbprint = try RemoteBindingApproval.thumbprint(key)
        return .init(serverId: identifier(["tomo-local-server-v1", thumbprint]),
            ownerId: identifier(["tomo-local-owner-v1", thumbprint]),
            publicKeyPem: key.pemRepresentation, thumbprint: thumbprint)
    }
    init(key: P256.Signing.PrivateKey, ledger: RemoteAuthorizationLedger) throws {
        let identity = try Self.identity(for: key.publicKey)
        guard ledger.serverId == identity.serverId.uuidString.lowercased() else {
            throw RemoteAccessError.invalidConfiguration
        }
        self.key = key; self.ledger = ledger; self.identity = identity
    }
    func shutdown() { stopped = true }

    /// Bootstrap supplies public device identity only. This assertion grants
    /// nothing; the binding router requires device DPoP before creating a request.
    func deviceAssertion(_ data: Data, now: Date = Date()) async throws -> String {
        guard !stopped, now.timeIntervalSince1970.isFinite, (1...9_007_199_254_740_691).contains(now.timeIntervalSince1970),
              data.count <= 4096, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["deviceId", "deviceName", "publicKey"],
              let rawDevice = object["deviceId"] as? String, let device = UUID(uuidString: rawDevice),
              let name = object["deviceName"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 80, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let jwk = object["publicKey"] as? [String: String], Set(jwk.keys) == ["kty", "crv", "x", "y"],
              jwk["kty"] == "EC", jwk["crv"] == "P-256",
              let x = RemoteJWTCodec.base64URL(jwk["x"] ?? ""), x.count == 32,
              let y = RemoteJWTCodec.base64URL(jwk["y"] ?? ""), y.count == 32 else {
            throw RemoteReadError.invalidRequest
        }
        let publicKey = try P256.Signing.PublicKey(x963Representation: Data([4]) + x + y)
        let deviceId = device.uuidString.lowercased(), thumbprint = try RemoteBindingApproval.thumbprint(publicKey)
        let owner = identity.ownerId.uuidString.lowercased()
        let previous = try await ledger.ownerBinding(userId: owner, deviceId: deviceId)
        if let previous, !previous.revoked, previous.thumbprint != thumbprint { throw RemoteAccessError.forbidden }
        let revision = (previous?.bindingRevision ?? 0) + (previous == nil || previous?.revoked == true ? 1 : 0)
        guard !stopped, revision > 0, revision <= 9_007_199_254_740_991 else { throw RemoteAccessError.unavailable }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw RemoteAccessError.unavailable }
        let issued = Int(now.timeIntervalSince1970), challenge = UUID().uuidString.lowercased()
        let claims = RemoteCloudGrantVerifier.BindingIdentity(iss: identity.issuer,
            aud: identity.serverId.uuidString.lowercased(), sub: owner, deviceId: deviceId,
            cnf: .init(jkt: thumbprint), deviceName: name, userEmail: "本地设备",
            challengeId: challenge, nonce: Self.encoded(Data(bytes)), scope: "server.bind",
            bindingRevision: revision, iat: issued, nbf: issued, exp: issued + 300, jti: challenge)
        return try signed(claims, type: "tomo-local-binding-identity+jwt")
    }

    func verifyBindingIdentity(_ token: String, now: Date = Date()) async throws -> RemoteCloudGrantVerifier.BindingIdentity {
        do {
            guard !stopped, now.timeIntervalSince1970.isFinite else { throw RemoteAccessError.unauthorized }
            let payload = try verifiedPayload(token, type: "tomo-local-binding-identity+jwt")
            guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  Set(object.keys) == ["iss", "aud", "sub", "deviceId", "cnf", "deviceName", "userEmail",
                      "challengeId", "nonce", "scope", "bindingRevision", "iat", "nbf", "exp", "jti"],
                  let cnf = object["cnf"] as? [String: String], Set(cnf.keys) == ["jkt"] else { throw RemoteAccessError.unauthorized }
            let claims = try JSONDecoder().decode(RemoteCloudGrantVerifier.BindingIdentity.self, from: payload)
            let time = now.timeIntervalSince1970
            guard claims.iss == identity.issuer, claims.aud == identity.serverId.uuidString.lowercased(),
                  claims.sub == identity.ownerId.uuidString.lowercased(), claims.userEmail == "本地设备",
                  UUID(uuidString: claims.deviceId) != nil, UUID(uuidString: claims.challengeId) != nil,
                  claims.jti == claims.challengeId, claims.scope == "server.bind",
                  claims.bindingRevision > 0, claims.bindingRevision <= 9_007_199_254_740_991,
                  RemoteJWTCodec.base64URL(claims.nonce)?.count == 32, RemoteJWTCodec.base64URL(claims.cnf.jkt)?.count == 32,
                  !claims.deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, claims.deviceName.count <= 80,
                  !claims.deviceName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  claims.iat > 0, claims.nbf == claims.iat, claims.exp > claims.iat, claims.exp - claims.iat <= 300,
                  Double(claims.iat) <= time, Double(claims.exp) > time else { throw RemoteAccessError.unauthorized }
            try Task.checkCancellation()
            return claims
        } catch { throw RemoteAccessError.unauthorized }
    }

    func issueBoundDevice(_ assertion: RemoteCloudGrantVerifier.BindingIdentity,
                          scopes: [String]? = nil, resources: [RemoteCloudGrantVerifier.Resource]? = nil,
                          now: Date = Date()) async throws -> String {
        guard assertion.iss == identity.issuer, assertion.aud == identity.serverId.uuidString.lowercased(),
              assertion.sub == identity.ownerId.uuidString.lowercased(), Double(assertion.exp) > now.timeIntervalSince1970,
              let binding = try await ledger.ownerBinding(userId: assertion.sub, deviceId: assertion.deviceId),
              binding.bindingRevision == assertion.bindingRevision else { throw RemoteAccessError.unauthorized }
        return try await issue(deviceId: assertion.deviceId, thumbprint: assertion.cnf.jkt,
            expectedLocalVersion: binding.localVersion, scopes: scopes, resources: resources, now: now)
    }

    private func signed(_ claims: some Encodable, type: String) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let header = ["alg": "ES256", "typ": type, "kid": identity.thumbprint]
        let input = Self.encoded(try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]))
            + "." + Self.encoded(try encoder.encode(claims))
        return input + "." + Self.encoded(try key.signature(for: Data(input.utf8)).rawRepresentation)
    }
    private func verifiedPayload(_ token: String, type: String) throws -> Data {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard token.utf8.count <= 32768, parts.count == 3,
              let head = RemoteJWTCodec.base64URL(String(parts[0])), let body = RemoteJWTCodec.base64URL(String(parts[1])),
              let signature = RemoteJWTCodec.base64URL(String(parts[2])), signature.count == 64,
              let header = try JSONSerialization.jsonObject(with: head) as? [String: String],
              Set(header.keys) == ["alg", "typ", "kid"], header["alg"] == "ES256",
              header["typ"] == type, header["kid"] == identity.thumbprint,
              key.publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signature),
                  for: Data((String(parts[0]) + "." + String(parts[1])).utf8)) else { throw RemoteAccessError.unauthorized }
        return body
    }

    /// A caller first proves possession of the approved device key. Grants
    /// contain the persisted scopes/resources, never phone-provided permissions.
    func issue(deviceId: String, thumbprint: String, expectedLocalVersion: Int,
               scopes requestedScopes: [String]? = nil, resources requestedResources: [RemoteCloudGrantVerifier.Resource]? = nil,
               now: Date = Date()) async throws -> String {
        let started = ContinuousClock.now
        guard !stopped, now.timeIntervalSince1970.isFinite, (1...9_007_199_254_740_691).contains(now.timeIntervalSince1970),
              UUID(uuidString: deviceId) != nil,
              let binding = try await ledger.ownerBinding(userId: identity.ownerId.uuidString.lowercased(), deviceId: deviceId),
              !binding.revoked, binding.thumbprint == thumbprint, binding.localVersion == expectedLocalVersion else {
            throw RemoteAccessError.unauthorized
        }
        try Task.checkCancellation()
        let wantedScopes = requestedScopes ?? binding.scopes, wantedResources = requestedResources ?? binding.resources
        guard !wantedScopes.isEmpty, Set(wantedScopes).count == wantedScopes.count,
              Set(wantedScopes).isSubset(of: ["discovery", "session.read", "session.write", "session.approve"]),
              !wantedResources.isEmpty, wantedResources.count <= 128,
              wantedResources.enumerated().allSatisfy({ !wantedResources.prefix($0.offset).contains($0.element) }) else {
            throw RemoteAccessError.forbidden
        }
        // Configuration is an upper bound. A desktop owner may approve fewer
        // resources/actions without forcing the phone to import a new config.
        let scopes = wantedScopes.filter { binding.scopes.contains($0) }
        let resources = wantedResources.filter { binding.resources.contains($0) }
        guard !scopes.isEmpty, !resources.isEmpty else { throw RemoteAccessError.forbidden }
        let issued = Int(Self.current(now, started).timeIntervalSince1970)
        let claims = RemoteCloudGrantVerifier.Claims(iss: identity.issuer,
            aud: identity.serverId.uuidString.lowercased(), sub: binding.userId, deviceId: binding.deviceId,
            cnf: .init(jkt: binding.thumbprint),
            bindingId: Self.bindingId(identity: identity, binding: binding, domain: ledger.authorizationDomain),
            // In the local JWT profile this revision is the local ACL version;
            // it never asserts cloud membership or a cloud entitlement.
            bindingRevision: binding.bindingRevision, entitlementVersion: binding.localVersion,
            scope: scopes.sorted().joined(separator: " "), resources: resources,
            iat: issued, nbf: issued, exp: issued + 300, jti: UUID().uuidString.lowercased())
        try claims.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let header = ["alg": "ES256", "typ": "tomo-local-grant+jwt", "kid": identity.thumbprint]
        let input = Self.encoded(try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]))
            + "." + Self.encoded(try encoder.encode(claims))
        let token = input + "." + Self.encoded(try key.signature(for: Data(input.utf8)).rawRepresentation)
        // Recheck after the ledger actor suspension; approval/revocation can
        // race issuance. All exchanges and business frames also check the ACL.
        guard !stopped, let current = try await ledger.ownerBinding(userId: binding.userId, deviceId: binding.deviceId),
              current == binding, Double(claims.exp) > Self.current(now, started).timeIntervalSince1970 else {
            throw RemoteAccessError.unauthorized
        }
        return token
    }

    func verify(_ token: String, now: Date = Date()) async throws -> RemoteCloudGrantVerifier.Claims {
        let started = ContinuousClock.now
        do {
            guard !stopped, now.timeIntervalSince1970.isFinite, token.utf8.count <= 32768 else {
                throw RemoteAccessError.unauthorized
            }
            let parts = token.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3, let head = RemoteJWTCodec.base64URL(String(parts[0])),
                  let body = RemoteJWTCodec.base64URL(String(parts[1])),
                  let signature = RemoteJWTCodec.base64URL(String(parts[2])), signature.count == 64,
                  let header = try JSONSerialization.jsonObject(with: head) as? [String: String],
                  Set(header.keys) == ["alg", "typ", "kid"], header["alg"] == "ES256",
                  header["typ"] == "tomo-local-grant+jwt", header["kid"] == identity.thumbprint,
                  key.publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signature),
                      for: Data((String(parts[0]) + "." + String(parts[1])).utf8)),
                  let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  Set(payload.keys) == ["iss", "aud", "sub", "deviceId", "cnf", "bindingId", "bindingRevision",
                      "entitlementVersion", "scope", "resources", "iat", "nbf", "exp", "jti"],
                  let cnf = payload["cnf"] as? [String: String], Set(cnf.keys) == ["jkt"] else {
                throw RemoteAccessError.unauthorized
            }
            let claims = try JSONDecoder().decode(RemoteCloudGrantVerifier.Claims.self, from: body)
            try claims.validate()
            let time = Self.current(now, started).timeIntervalSince1970
            guard claims.iss == identity.issuer, claims.aud == identity.serverId.uuidString.lowercased(),
                  claims.sub == identity.ownerId.uuidString.lowercased(),
                  Double(claims.nbf) <= time, Double(claims.iat) <= time, Double(claims.exp) > time,
                  let binding = try await ledger.ownerBinding(userId: claims.sub, deviceId: claims.deviceId),
                  !binding.revoked, binding.bindingRevision == claims.bindingRevision,
                  binding.localVersion == claims.entitlementVersion,
                  binding.thumbprint == claims.cnf.jkt,
                  Self.bindingId(identity: identity, binding: binding, domain: ledger.authorizationDomain) == claims.bindingId,
                  Set(claims.scope.split(separator: " ").map(String.init)).isSubset(of: Set(binding.scopes)),
                  claims.resources.allSatisfy({ binding.resources.contains($0) }),
                  !stopped, Double(claims.exp) > Self.current(now, started).timeIntervalSince1970 else {
                throw RemoteAccessError.unauthorized
            }
            try Task.checkCancellation()
            return claims
        } catch { throw RemoteAccessError.unauthorized }
    }
    private static func bindingId(identity: Identity, binding: RemoteAuthorizationLedger.Binding, domain: UUID) -> String {
        identifier(["tomo-local-binding-v2", domain.uuidString.lowercased(), identity.serverId.uuidString.lowercased(), binding.userId,
            binding.deviceId, binding.thumbprint, String(binding.bindingRevision)]).uuidString.lowercased()
    }
    private static func identifier(_ fields: [String]) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(fields.joined(separator: "\n").utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    private static func encoded(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func current(_ now: Date, _ started: ContinuousClock.Instant) -> Date {
        let elapsed = started.duration(to: .now).components
        return now.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    }
}
