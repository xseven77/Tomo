import Foundation
import CryptoKit
import Security

enum RemoteServerIdentityError: Error, Equatable {
    case storageUnavailable, corruptIdentity, invalidChallenge
}

protocol RemoteServerIdentityStorage: Sendable {
    func load() throws -> Data?
    func insertIfAbsent(_ data: Data) throws -> Bool
}

struct KeychainRemoteServerIdentityStorage: RemoteServerIdentityStorage {
    private let service = "com.qiizo.tomo.remote"
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "server_signing_p256_v1", kSecAttrSynchronizable as String: false]
    }
    func load() throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw RemoteServerIdentityError.storageUnavailable }
        return data
    }
    func insertIfAbsent(_ data: Data) throws -> Bool {
        var query = query
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem { return false }
        guard status == errSecSuccess else { throw RemoteServerIdentityError.storageUnavailable }
        return true
    }
}

/// Native-owned persistent signing identity, independent of the TLS certificate.
/// Corrupt or unavailable storage must never silently rotate a registered key.
actor RemoteServerIdentity {
    struct PublicIdentity: Sendable, Equatable {
        let publicKeyPem: String, keyThumbprint: String
    }
    struct RegistrationProof: Sendable {
        let publicKeyPem: String, keyThumbprint: String, signature: String
    }
    private let storage: any RemoteServerIdentityStorage
    private var cached: P256.Signing.PrivateKey?
    init(storage: any RemoteServerIdentityStorage = KeychainRemoteServerIdentityStorage()) { self.storage = storage }

    func publicIdentity() throws -> PublicIdentity {
        let publicKey = try key().publicKey
        return .init(publicKeyPem: publicKey.pemRepresentation,
                     keyThumbprint: try RemoteBindingApproval.thumbprint(publicKey))
    }

    func localIdentity() throws -> RemoteLocalGrantAuthority.Identity {
        try RemoteLocalGrantAuthority.identity(for: key().publicKey)
    }
    func localGrantAuthority(ledger: RemoteAuthorizationLedger) throws -> RemoteLocalGrantAuthority {
        try RemoteLocalGrantAuthority(key: key(), ledger: ledger)
    }
    func localBindingApproval(authority: RemoteLocalGrantAuthority, ledger: RemoteAuthorizationLedger) throws -> RemoteBindingApproval {
        try RemoteBindingApproval(cloud: authority, ledger: ledger,
            serverId: authority.identity.serverId.uuidString.lowercased(), issuer: authority.identity.issuer,
            registeredKey: key(), registeredThumbprint: authority.identity.thumbprint)
    }

    /// Only sign challenges fetched by a native trusted cloud session.
    func registrationProof(signingInput: String, challengeId: String, sessionId: String,
                           algorithm: String, expiresAt: Date, now: Date = Date()) throws -> RegistrationProof {
        let fields = signingInput.components(separatedBy: "\n")
        guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 > 0,
              expiresAt > now, expiresAt <= now.addingTimeInterval(301), algorithm == "ES256",
              UUID(uuidString: challengeId) != nil, UUID(uuidString: sessionId) != nil,
              signingInput.utf8.count <= 1024, fields.count == 4,
              fields[0] == "TomoServer/server-registration/v1", fields[1] == challengeId,
              fields[2] == sessionId,
              let nonce = Self.decodeNonce(fields[3]), nonce.count == 32 else { throw RemoteServerIdentityError.invalidChallenge }
        let identity = try publicIdentity()
        return .init(publicKeyPem: identity.publicKeyPem, keyThumbprint: identity.keyThumbprint,
            signature: try key().signature(for: Data(signingInput.utf8)).derRepresentation.base64EncodedString())
    }

    func bindingApproval(cloud: RemoteCloudGrantVerifier, ledger: RemoteAuthorizationLedger,
                         serverId: String, issuer: String, registeredThumbprint: String) throws -> RemoteBindingApproval {
        try RemoteBindingApproval(cloud: cloud, ledger: ledger, serverId: serverId, issuer: issuer,
            registeredKey: key(), registeredThumbprint: registeredThumbprint)
    }

    private func key() throws -> P256.Signing.PrivateKey {
        if let cached { return cached }
        if let data = try storage.load() { let key = try decode(data); cached = key; return key }
        let candidate = P256.Signing.PrivateKey()
        if try storage.insertIfAbsent(Data([1]) + candidate.rawRepresentation) { cached = candidate; return candidate }
        guard let winner = try storage.load() else { throw RemoteServerIdentityError.storageUnavailable }
        let key = try decode(winner); cached = key; return key
    }
    private func decode(_ data: Data) throws -> P256.Signing.PrivateKey {
        guard data.count == 33, data.first == 1 else { throw RemoteServerIdentityError.corruptIdentity }
        do { return try P256.Signing.PrivateKey(rawRepresentation: data.dropFirst()) }
        catch { throw RemoteServerIdentityError.corruptIdentity }
    }
    private static func decodeNonce(_ value: String) -> Data? {
        guard value.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              let data = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=") else { return nil }
        let canonical = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return canonical == value ? data : nil
    }
}
