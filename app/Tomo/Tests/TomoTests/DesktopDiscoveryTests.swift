import Foundation
import XCTest
@testable import Tomo

private final class BonjourProbe: NSObject, NetServiceBrowserDelegate, @unchecked Sendable {
    let browser = NetServiceBrowser()
    var found = Set<String>()
    var removed = Set<String>()
    override init() { super.init(); browser.delegate = self }
    func start() { browser.searchForServices(ofType: "_tomogo._tcp.", inDomain: "local.") }
    func stop() { browser.delegate = nil; browser.stop() }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) { found.insert(service.name) }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) { removed.insert(service.name) }
}
final class DesktopDiscoveryTests: XCTestCase, @unchecked Sendable {
    func testStatusListenerAdvertisesAndWithdrawsWithoutPairingOrSessionGrants() async throws {
        let name = "Tomo QA " + UUID().uuidString.prefix(8)
        let probe = await MainActor.run { let value = BonjourProbe(); value.start(); return value }
        // Port 0: Bonjour advertises whichever port the system binds. A fixed
        // port in the ephemeral range was held by an unrelated outgoing
        // connection, so the listener never came up and nothing was published.
        let server = MobileSyncServer(port: 0, token: "isolated-discovery-token", bonjourServiceName: name,
            dataProvider: MobileSyncServerTests.MockDataProvider())
        try server.start()
        defer { server.stop(); Task { @MainActor in probe.stop() } }
        var discovered = false
        for _ in 0..<100 {
            discovered = await MainActor.run { probe.found.contains(name) }
            if discovered { break }; try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(discovered, "The actual status listener must publish its Bonjour record")
        server.stop()
        var withdrawn = false
        for _ in 0..<100 {
            withdrawn = await MainActor.run { probe.removed.contains(name) }
            if withdrawn { break }; try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(withdrawn, "Stopping status sync must withdraw discovery")
    }
    /// Optional short-lived publisher for product simulator UI acceptance. No real directory or credentials.
    func testProductDiscoveryFixture() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TOMO_DISCOVERY_QA_DIR"] else { throw XCTSkip("Opt-in product UI fixture") }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let server = MobileSyncServer(port: 59673, token: "isolated-discovery-qa", bonjourServiceName: "Tomo · Discovery QA",
            dataProvider: MobileSyncServerTests.MockDataProvider())
        try server.start(); defer { server.stop() }
        for _ in 0..<50 { if server.status == .ready { break }; try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(server.status, .ready)
        try Data("ready".utf8).write(to: root.appendingPathComponent("ready"))
        for _ in 0..<900 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("stop").path) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
