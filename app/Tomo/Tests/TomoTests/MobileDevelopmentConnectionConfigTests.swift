import Foundation
import Testing
@testable import Tomo

struct MobileDevelopmentConnectionConfigTests {
    let remoteToken = "tomo_remote_dev_" + String(repeating: "A", count: 43)

    @Test("Companion config carries the actual independent grant and expiration")
    func separateCredentials() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiration = now.addingTimeInterval(600)
        let payload = MobileDevelopmentConnectionConfig.payload(serverURL: "http://127.0.0.1:58350",
            pairingToken: "snapshot-pairing", remoteToken: remoteToken, remoteExpiresAt: expiration, now: now)
        #expect(payload["token"] == "snapshot-pairing")
        #expect(payload["mode"] == "development-snapshot")
        #expect(payload["remoteToken"] == remoteToken)
        #expect(payload["remoteExpiresAt"] == ISO8601DateFormatter().string(from: expiration))
        #expect(payload["remoteMode"] == "development-control")
        #expect(payload["contractVersion"] == "2")
    }

    @Test("Absent, expired or pairing credentials cannot be advertised as a remote grant")
    func unavailableGrants() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for (token, expiration) in [(nil, nil), (remoteToken, now), ("snapshot-pairing", now.addingTimeInterval(600))] as [(String?, Date?)] {
            let payload = MobileDevelopmentConnectionConfig.payload(serverURL: "http://127.0.0.1:58350",
                pairingToken: "snapshot-pairing", remoteToken: token, remoteExpiresAt: expiration, now: now)
            #expect(payload["token"] == "snapshot-pairing")
            #expect(payload["remoteToken"] == nil)
            #expect(payload["remoteMode"] == nil)
            #expect(payload["remoteExpiresAt"] == nil)
        }
    }
}
