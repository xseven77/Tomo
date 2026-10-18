import Foundation

/// Public state pairing cannot carry or mint a remote session authorization.
enum MobilePairingConnectionConfig {
    static func payload(serverURL: String, pairingToken: String) -> [String: String] {
        ["contractVersion": "2", "serverURL": serverURL,
         "token": pairingToken, "mode": "development-snapshot"]
    }
}
