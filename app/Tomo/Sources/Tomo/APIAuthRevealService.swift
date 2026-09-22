import Foundation
import LocalAuthentication

enum APIKeyRevealError: LocalizedError {
    case connectionNotFound

    var errorDescription: String? {
        switch self {
        case .connectionNotFound: "找不到此连接的凭据"
        }
    }
}

enum APIAuthRevealError: LocalizedError {
    case notAvailable
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            "当前设备无法进行系统认证"
        case .cancelled:
            "已取消认证"
        case let .failed(message):
            message
        }
    }
}

/// Presents the native macOS system-credential prompt (Touch ID / Apple Watch /
/// login password) before revealing a stored API key. This delegates the
/// password check to the OS rather than re-implementing it.
enum APIAuthRevealService {
    /// Evaluate `.deviceOwnerAuthentication`. When the context lacks a
    /// passcode/biometry, LAPolicy falls back to the user's password prompt.
    @MainActor
    static func authorize() async throws {
        let context = LAContext()

        // Localized reason is shown even on the fallback password sheet.
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw APIAuthRevealError.notAvailable
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "查看已保存的 API Key"
            )
            guard success else {
                throw APIAuthRevealError.cancelled
            }
        } catch let authError as NSError {
            if authError.code == LAError.userCancel.rawValue
                || authError.code == LAError.appCancel.rawValue
                || authError.code == LAError.systemCancel.rawValue {
                throw APIAuthRevealError.cancelled
            }
            throw APIAuthRevealError.failed(authError.localizedDescription)
        }
    }
}
