import Foundation
import Testing
@testable import Tomo

struct MobilePairingIsolationTests {
    @Test @MainActor func publicPairingDoesNotGrantSessionAccessOnStartupOrRepeatedRequests() async throws {
        let domain = "tomo-pairing-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        // A port the system just handed out instead of a fixed one: fixed
        // ports sit in the ephemeral range, and macOS refuses to listen on a
        // port that any connection still uses — even a TIME_WAIT leftover.
        let port = try RemoteTLSFixture.freePort()
        defaults.set(Int(port), forKey: "tomo.mobileSync.port")
        defaults.set("synthetic-status-pairing", forKey: "tomo.mobileSync.token")
        let manager = MobileSyncManager(defaults: defaults, listenOnLoopbackOnly: true)
        manager.start()
        defer { manager.stop() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let origin = "http://127.0.0.1:\(port)"
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !manager.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(manager.isRunning)
        for _ in 0..<2 {
            let (data, response) = try await session.data(from: URL(string: origin + "/api/v1/companion/config")!)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            let config = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
            #expect(config == ["contractVersion": "2", "serverURL": origin,
                               "token": "synthetic-status-pairing", "mode": "development-snapshot"])
            var request = URLRequest(url: URL(string: origin + "/api/v1/remote/catalog")!)
            request.setValue("Bearer synthetic-status-pairing", forHTTPHeaderField: "Authorization")
            let (_, denied) = try await session.data(for: request)
            #expect((denied as? HTTPURLResponse)?.statusCode == 401)
        }
    }
}
