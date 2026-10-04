import Foundation
import CryptoKit

/// Identity is cloud-verified; permission selection is a local owner action.
/// No network route exposes approve/reject. Server key provisioning is separate.
actor RemoteBindingApproval {
    enum Outcome: Sendable { case pending(Date), approved(String), rejected }
    struct Pending: Sendable {
        let id: UUID, userId: String, deviceId: String, deviceName: String, userEmail: String
        let thumbprint: String, bindingRevision: Int
        let expiresAt: Date
    }
    private struct Record {
        let identity: RemoteCloudGrantVerifier.BindingIdentity
        let assertionDigest: Data
        let assertion: String
        let pending: Pending
        var processing = false, rejected = false
        var approvedScopes: [String]?
        var approvedResources: [RemoteCloudGrantVerifier.Resource]?
        var expectedVersion: Int?
        var receipt: String?
    }
    private let cloud: RemoteCloudGrantVerifier
    private let ledger: RemoteAuthorizationLedger
    private let key: P256.Signing.PrivateKey
    private let serverId: String
    private let issuer: String
    private var records: [UUID: Record] = [:]

    init(cloud: RemoteCloudGrantVerifier, ledger: RemoteAuthorizationLedger, serverId: String,
         issuer: String, registeredKey: P256.Signing.PrivateKey, registeredThumbprint: String) throws {
        guard ledger.serverId == serverId, UUID(uuidString: serverId) != nil,
              let url = URLComponents(string: issuer), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              try Self.thumbprint(registeredKey.publicKey) == registeredThumbprint else { throw RemoteAccessError.invalidConfiguration }
        self.cloud = cloud; self.ledger = ledger; self.serverId = serverId; self.issuer = issuer; self.key = registeredKey
    }

    func prepare(assertion: String, now: Date = Date()) async throws -> Pending {
        let started = ContinuousClock.now
        let claims = try await cloud.verifyBindingIdentity(assertion, now: now)
        try Task.checkCancellation()
        let current = Self.current(now, since: started)
        guard claims.iss == issuer, claims.aud == serverId, Double(claims.exp) > current.timeIntervalSince1970,
              let id = UUID(uuidString: claims.challengeId) else { throw RemoteAccessError.unauthorized }
        records = records.filter { $0.value.pending.expiresAt > current }
        let digest = Data(SHA256.hash(data: Data(assertion.utf8)))
        if let existing = records[id] {
            guard existing.assertionDigest == digest, !existing.rejected else { throw RemoteAccessError.forbidden }
            return existing.pending
        }
        guard records.count < 32 else { throw RemoteAccessError.unavailable }
        let pending = Pending(id: id, userId: claims.sub, deviceId: claims.deviceId, deviceName: claims.deviceName,
            userEmail: claims.userEmail, thumbprint: claims.cnf.jkt, bindingRevision: claims.bindingRevision,
            expiresAt: Date(timeIntervalSince1970: Double(claims.exp)))
        records[id] = .init(identity: claims, assertionDigest: digest, assertion: assertion, pending: pending)
        return pending
    }

    func approve(id: UUID, scopes: [String], resources: [RemoteCloudGrantVerifier.Resource],
                 expectedLocalVersion: Int, now: Date = Date()) async throws -> String {
        guard now.timeIntervalSince1970.isFinite, var record = records[id], !record.rejected,
              !record.processing, record.pending.expiresAt > now else { throw RemoteAccessError.forbidden }
        if let receipt = record.receipt {
            guard record.approvedScopes == scopes, record.approvedResources == resources,
                  record.expectedVersion == expectedLocalVersion else { throw RemoteAccessError.forbidden }
            guard let binding = try await ledger.ownerBinding(userId: record.pending.userId, deviceId: record.pending.deviceId),
                  !binding.revoked, binding.localVersion == expectedLocalVersion + 1,
                  binding.thumbprint == record.pending.thumbprint, binding.bindingRevision == record.pending.bindingRevision,
                  binding.scopes == scopes, binding.resources == resources else { throw RemoteAccessError.forbidden }
            return receipt
        }
        guard !scopes.isEmpty, scopes.count <= 4, Set(scopes).count == scopes.count,
              Set(scopes).isSubset(of: ["discovery", "session.read", "session.write", "session.approve"]),
              !resources.isEmpty, resources.count <= 128, expectedLocalVersion >= 0 else { throw RemoteAccessError.invalidConfiguration }
        try Task.checkCancellation()
        record.processing = true; records[id] = record
        defer { records[id]?.processing = false }
        let started = ContinuousClock.now
        let claims = try await cloud.verifyBindingIdentity(record.assertion, now: now)
        try Task.checkCancellation()
        let issued = Int(Self.current(now, since: started).timeIntervalSince1970)
        guard issued >= claims.iat, issued < claims.exp else { throw RemoteAccessError.forbidden }
        let payload: [String: Any] = ["iss": serverId, "aud": issuer, "sub": claims.sub, "serverId": serverId,
            "deviceId": claims.deviceId, "cnf": ["jkt": claims.cnf.jkt], "challengeId": claims.challengeId,
            "nonce": claims.nonce, "bindingRevision": claims.bindingRevision, "iat": issued, "nbf": issued,
            "exp": claims.exp, "jti": UUID().uuidString.lowercased(), "scopes": scopes,
            "resources": try JSONSerialization.jsonObject(with: JSONEncoder().encode(resources))]
        let header = ["alg": "ES256", "typ": "tomo-binding-receipt+jwt", "kid": try Self.thumbprint(key.publicKey)]
        let input = Self.encoded(try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])) + "." +
            Self.encoded(try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        let receipt = input + "." + Self.encoded(try key.signature(for: Data(input.utf8)).rawRepresentation)
        _ = try await ledger.approve(.init(userId: claims.sub, deviceId: claims.deviceId, thumbprint: claims.cnf.jkt,
            bindingRevision: claims.bindingRevision, cloudBindingId: nil, localVersion: 0,
            scopes: scopes, resources: resources, revoked: false), expectedLocalVersion: expectedLocalVersion)
        guard record.pending.expiresAt > Self.current(now, since: started) else { throw RemoteAccessError.forbidden }
        record.receipt = receipt; record.approvedScopes = scopes; record.approvedResources = resources
        record.expectedVersion = expectedLocalVersion; records[id] = record
        return receipt
    }

    func reject(id: UUID) throws {
        guard var record = records[id], !record.processing, record.receipt == nil else { throw RemoteAccessError.forbidden }
        record.rejected = true; records[id] = record
    }

    func pendingItems(now: Date = Date()) -> [Pending] {
        records.values.filter { !$0.rejected && $0.receipt == nil && $0.pending.expiresAt > now }
            .map(\.pending).sorted { $0.expiresAt < $1.expiresAt }
    }

    func outcome(id: UUID, assertion: String, now: Date = Date()) async throws -> Outcome {
        guard now.timeIntervalSince1970.isFinite, let record = records[id], record.pending.expiresAt > now,
              record.assertionDigest == Data(SHA256.hash(data: Data(assertion.utf8))) else { throw RemoteAccessError.forbidden }
        if record.rejected { return .rejected }
        if let receipt = record.receipt {
            guard let version = record.expectedVersion,
                  let binding = try await ledger.ownerBinding(userId: record.pending.userId, deviceId: record.pending.deviceId),
                  !binding.revoked, binding.localVersion == version + 1,
                  binding.thumbprint == record.pending.thumbprint, binding.bindingRevision == record.pending.bindingRevision else {
                throw RemoteAccessError.forbidden
            }
            return .approved(receipt)
        }
        return .pending(record.pending.expiresAt)
    }

    static func thumbprint(_ key: P256.Signing.PublicKey) throws -> String {
        let bytes = key.x963Representation
        let jwk = ["crv": "P-256", "kty": "EC", "x": encoded(bytes.subdata(in: 1..<33)), "y": encoded(bytes.subdata(in: 33..<65))]
        return encoded(Data(SHA256.hash(data: try JSONSerialization.data(withJSONObject: jwk, options: [.sortedKeys, .withoutEscapingSlashes]))))
    }
    private static func encoded(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func current(_ now: Date, since started: ContinuousClock.Instant) -> Date {
        let elapsed = started.duration(to: .now).components
        return now.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    }
}
