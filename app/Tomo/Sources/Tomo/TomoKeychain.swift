import Foundation
import Security
import CTomoKeychain

/// Serialize this app's SecItem operations around the legacy keychain UI policy.
/// LAContext / kSecUseAuthenticationUI do not reliably suppress UI for the
/// file-based login keychain (Apple FB16959400). The legacy process-wide setting
/// is changed only inside this synchronous scope and always restored afterwards.
/// All app-owned SecItem calls use this lock, so foreground access cannot race
/// with a background operation's temporary no-UI setting.
enum TomoKeychain {
    private static let lock = NSRecursiveLock()

    static func perform(allowInteraction: Bool = true, _ operation: () -> OSStatus) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        guard !allowInteraction else { return operation() }
        var previous = false
        let read = TomoKeychainGetInteractionAllowed(&previous)
        guard read == errSecSuccess else { return read }
        let update = TomoKeychainSetInteractionAllowed(false)
        guard update == errSecSuccess else { return update }
        let result = operation()
        let restore = TomoKeychainSetInteractionAllowed(previous)
        return restore == errSecSuccess ? result : restore
    }

    static func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?,
                             allowInteraction: Bool = true) -> OSStatus {
        perform(allowInteraction: allowInteraction) { SecItemCopyMatching(query, result) }
    }
    static func add(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?,
                    allowInteraction: Bool = true) -> OSStatus {
        perform(allowInteraction: allowInteraction) { SecItemAdd(attributes, result) }
    }
    static func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        perform { SecItemUpdate(query, attributes) }
    }
    static func delete(_ query: CFDictionary) -> OSStatus {
        perform { SecItemDelete(query) }
    }
}
