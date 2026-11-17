import XCTest
@testable import Tomo

@MainActor final class DesktopCloudManagerTests: XCTestCase {
    private func setup() throws -> (DesktopCloudManager, DesktopCloudFixture, DesktopSessionMemory, UserDefaults, String) {
        let name = "DesktopCloudManagerTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let http = DesktopCloudFixture(), storage = DesktopSessionMemory()
        let identity = RemoteServerIdentity(storage: DesktopIdentityMemory())
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let manager = DesktopCloudManager(defaults: defaults, factory: {
            try DesktopCloudSession(endpoint: $0, storage: storage, http: http, identity: identity, clock: { date })
        })
        return (manager, http, storage, defaults, name)
    }
    private func login(_ manager: DesktopCloudManager) async {
        await manager.configure("https://cloud.example.test")
        await manager.sendCode(email: "owner@example.test")
        await manager.signIn(code: "123456")
    }
    func testUserFlowPublishesOnlySessionAndRegisteredServerMetadata() async throws {
        let (manager, http, storage, defaults, name) = try setup()
        defer { defaults.removePersistentDomain(forName: name) }
        await manager.configure("http://cloud.example.test")
        XCTAssertFalse(manager.isConfigured); XCTAssertNotNil(manager.message)
        await login(manager)
        XCTAssertNotNil(manager.summary); XCTAssertFalse(manager.codeSent); XCTAssertNil(manager.message)
        await manager.register(name: "Studio Mac")
        XCTAssertEqual(manager.server?.name, "Studio Mac"); XCTAssertFalse(manager.isBusy)
        let proof = await http.verifiedProof; XCTAssertTrue(proof)
        XCTAssertEqual(defaults.string(forKey: "tomo.cloud.owner.issuer"), "https://cloud.example.test")
        XCTAssertEqual(defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("tomo.cloud.") }.count, 1)
        await manager.logout()
        XCTAssertNil(manager.summary); XCTAssertNil(manager.server); XCTAssertNil(try storage.load())
        XCTAssertTrue(manager.isConfigured); XCTAssertFalse(manager.isBusy)
    }
    func testRestoreUsesSavedIssuerAndSessionWithoutSendingOTP() async throws {
        let (manager, http, storage, defaults, name) = try setup()
        defer { defaults.removePersistentDomain(forName: name) }
        await login(manager)
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let restored = DesktopCloudManager(defaults: defaults, factory: {
            try DesktopCloudSession(endpoint: $0, storage: storage, http: http, clock: { date })
        })
        await restored.restore()
        XCTAssertEqual(restored.summary, manager.summary)
        let sent = await http.count("auth/challenges"); XCTAssertEqual(sent, 1)
    }
    func testLogoutDuringCodeDeliveryDoesNotShowLateLoginForm() async throws {
        let (manager, http, _, defaults, name) = try setup()
        defer { defaults.removePersistentDomain(forName: name) }
        await manager.configure("https://cloud.example.test")
        await http.configure(block: "auth/challenges")
        let sending = Task { await manager.sendCode(email: "owner@example.test") }
        await http.waitForRequest()
        XCTAssertEqual(manager.operation, .sendingCode)
        await manager.logout(); await http.resume(); await sending.value
        XCTAssertFalse(manager.codeSent); XCTAssertNil(manager.summary); XCTAssertEqual(manager.operation, .idle)
    }
    func testLogoutDuringRegistrationDiscardsUIResultAndConfigurationCanBeChanged() async throws {
        let (manager, http, storage, defaults, name) = try setup()
        defer { defaults.removePersistentDomain(forName: name) }
        await login(manager); await http.configure(block: "/servers")
        let registration = Task { await manager.register(name: "Studio Mac") }
        await http.waitForRequest(); XCTAssertEqual(manager.operation, .registering)
        await manager.logout(clearConfiguration: true)
        await manager.configure("https://second.example.test")
        await http.resume(); await registration.value
        XCTAssertNil(manager.server); XCTAssertNil(manager.summary); XCTAssertNil(try storage.load())
        XCTAssertEqual(manager.configuredURL, "https://second.example.test"); XCTAssertNil(manager.message)
    }
    func testCloudRevocationClearsVisibleIdentity() async throws {
        let (manager, http, storage, defaults, name) = try setup()
        defer { defaults.removePersistentDomain(forName: name) }
        await login(manager); await http.configure(revoked: true)
        await manager.register(name: "Studio Mac")
        XCTAssertNil(manager.summary); XCTAssertNil(manager.server); XCTAssertNil(try storage.load())
        XCTAssertNotNil(manager.message); XCTAssertFalse(manager.isBusy)
    }
    func testFailedKeychainDeletionRetainsConfigurationAndCanBeRetried() async throws {
        let (manager, http, storage, defaults, name) = try setup()
        defer { defaults.removePersistentDomain(forName: name) }
        await login(manager); storage.rejectClear(true)
        await manager.logout(clearConfiguration: true)
        XCTAssertNil(manager.summary); XCTAssertNil(manager.server); XCTAssertTrue(manager.isConfigured)
        XCTAssertNotNil(try storage.load()); XCTAssertNotNil(manager.message)
        XCTAssertEqual(manager.configuredURL, "https://cloud.example.test")
        let revocations = await http.count("auth/logout"); XCTAssertEqual(revocations, 1)
        storage.rejectClear(false); await manager.logout(clearConfiguration: true)
        XCTAssertNil(try storage.load()); XCTAssertFalse(manager.isConfigured); XCTAssertEqual(manager.configuredURL, "")
        XCTAssertNil(defaults.string(forKey: "tomo.cloud.owner.issuer"))
    }
}
