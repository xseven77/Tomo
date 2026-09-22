import Foundation
import Security

public enum KeychainError: LocalizedError {
    case unhandledError(status: OSStatus)
    case itemNotFound
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .unhandledError(let status):
            if let message = SecCopyErrorMessageString(status, nil) {
                return "Keychain 错误: \(message as String) (\(status))"
            }
            return "Keychain 错误代码: \(status)"
        case .itemNotFound:
            return "未在 Keychain 中找到对应凭据"
        case .invalidData:
            return "Keychain 数据格式无效"
        }
    }
}

/// Secure credential broker using macOS Security.framework.
/// Ensures real API keys are held exclusively in the macOS Keychain.
public final class GatewaySecretBroker: Sendable {
    public static let shared = GatewaySecretBroker()
    private let serviceName = "com.qiizo.tomo.gateway"

    public init() {}

    /// Save or update a secret item in macOS Keychain.
    public func saveSecret(_ secret: String, for account: String) throws {
        guard let data = secret.data(using: .utf8) else {
            throw KeychainError.invalidData
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let attributesToUpdate: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unhandledError(status: updateStatus)
            }
        } else if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unhandledError(status: addStatus)
            }
        } else {
            throw KeychainError.unhandledError(status: status)
        }
    }

    /// Retrieve a secret item from macOS Keychain.
    public func retrieveSecret(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, let secret = String(data: data, encoding: .utf8) {
            return secret
        }

        // Fallback: try retrieving legacy Codexling keychain secret
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.qiizo.Codexling.gateway",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var legacyItem: CFTypeRef?
        let legacyStatus = SecItemCopyMatching(legacyQuery as CFDictionary, &legacyItem)
        if legacyStatus == errSecSuccess, let data = legacyItem as? Data, let secret = String(data: data, encoding: .utf8) {
            // Auto migrate to new Tomo keychain service
            try? saveSecret(secret, for: account)
            return secret
        }

        return nil
    }

    /// Delete a secret item from macOS Keychain.
    public func deleteSecret(for account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledError(status: status)
        }
    }

    /// Safely migrate legacy 0600 disk files into Keychain and remove old files.
    public func migrateLegacyFile(at fileURL: URL, for account: String) -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return false
        }

        do {
            let content = try String(contentsOf: fileURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return false }
            try saveSecret(content, for: account)
            try? FileManager.default.removeItem(at: fileURL)
            return true
        } catch {
            return false
        }
    }
}
