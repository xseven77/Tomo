import Foundation
import CryptoKit
import Security

struct RemoteTLSChoice: Sendable, Identifiable, Equatable {
    let id: String, label: String, fingerprint: String
}
protocol RemoteTLSIdentityCatalog: Sendable {
    func choices() async throws -> [RemoteTLSChoice]
    func identity(id: String) async throws -> RemoteTLSIdentity
}
/// Reads existing identities only in response to a native owner action.
/// No key export, root installation, PKCS12 import or automatic certificate choice.
actor KeychainRemoteTLSIdentityCatalog: RemoteTLSIdentityCatalog {
    private var identities: [String: RemoteTLSIdentity] = [:]
    func choices() throws -> [RemoteTLSChoice] {
        var result: CFTypeRef?
        let status = TomoKeychain.copyMatching([kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true, kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrSynchronizable as String: false] as CFDictionary, &result)
        if status == errSecItemNotFound { identities = [:]; return [] }
        guard status == errSecSuccess, let values = result as? [SecIdentity], values.count <= 256 else { throw RemoteServerIdentityError.storageUnavailable }
        var next: [String: RemoteTLSIdentity] = [:], choices: [RemoteTLSChoice] = []
        for value in values {
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(value, &certificate) == errSecSuccess, let certificate else { continue }
            let data = SecCertificateCopyData(certificate) as Data
            let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard next[fingerprint] == nil else { continue }
            next[fingerprint] = RemoteTLSIdentity(value: value)
            choices.append(.init(id: fingerprint, label: (SecCertificateCopySubjectSummary(certificate) as String?) ?? "TLS certificate", fingerprint: fingerprint))
        }
        identities = next
        return choices.sorted { ($0.label, $0.id) < ($1.label, $1.id) }
    }
    func identity(id: String) throws -> RemoteTLSIdentity {
        guard let value = identities[id] else { throw RemoteAccessError.invalidConfiguration }; return value
    }
}
