import Foundation

/// Snapshot pairing and remote session grants are different credentials.
/// This development-only wire format preserves the existing snapshot fields.
enum MobileDevelopmentConnectionConfig {
    static func payload(serverURL: String, pairingToken: String,
                        remoteToken: String?, remoteExpiresAt: Date?, now: Date = Date()) -> [String: String] {
        var result = ["contractVersion": "2", "serverURL": serverURL,
                      "token": pairingToken, "mode": "development-snapshot"]
        if let remoteToken, let remoteExpiresAt, remoteExpiresAt > now,
           remoteToken.range(of: "^tomo_remote_dev_[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil {
            result["remoteToken"] = remoteToken
            result["remoteExpiresAt"] = ISO8601DateFormatter().string(from: remoteExpiresAt)
            result["remoteMode"] = "development-control"
        }
        return result
    }
}
