import XCTest
import CryptoKit
import Security
import CTomoKeychain
@testable import Tomo

private final class PhoneIdentityStorage: RemoteServerIdentityStorage, @unchecked Sendable {
    private let lock = NSLock()
    private let bytes = Data([1]) + P256.Signing.PrivateKey().rawRepresentation
    private var authorized = false
    private var denied = false
    private var reads = 0, prompts = 0, writes = 0
    var counts: (silent: Int, interactive: Int, writes: Int) { lock.withLock { (reads, prompts, writes) } }
    func denyNextAuthorization() { lock.withLock { denied = true } }
    func loadWithoutInteraction() throws -> Data? {
        try lock.withLock {
            reads += 1
            guard authorized else { throw RemoteServerIdentityError.authorizationRequired }
            return bytes
        }
    }
    func load() throws -> Data? {
        try lock.withLock {
            prompts += 1
            guard !denied else { denied = false; throw RemoteServerIdentityError.authorizationRequired }
            authorized = true
            return bytes
        }
    }
    func insertIfAbsent(_ data: Data) throws -> Bool { lock.withLock { writes += 1; return false } }
}

private final class BlockingPhoneIdentityStorage: RemoteServerIdentityStorage, @unchecked Sendable {
    let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let deny: Bool
    init(deny: Bool) { self.deny = deny }
    func waitUntilStarted() -> Bool { started.wait(timeout: .now() + 3) == .success }
    func load() throws -> Data? { try loadWithoutInteraction() }
    func loadWithoutInteraction() throws -> Data? {
        started.signal()
        guard release.wait(timeout: .now() + 5) == .success else { throw RemoteServerIdentityError.storageUnavailable }
        if deny { throw RemoteServerIdentityError.authorizationRequired }
        return Data([1]) + P256.Signing.PrivateKey().rawRepresentation
    }
    func insertIfAbsent(_ data: Data) throws -> Bool { XCTFail("must not replace identity"); return false }
}

private actor PhoneIdentityHost: RemoteProductionHosting {
    nonisolated let states: AsyncStream<RemoteHTTPSListener.State>
    private let continuation: AsyncStream<RemoteHTTPSListener.State>.Continuation
    init() {
        let pair = AsyncStream<RemoteHTTPSListener.State>.makeStream()
        states = pair.stream; continuation = pair.continuation
        continuation.yield(.running)
    }
    func stop() { continuation.yield(.stopped); continuation.finish() }
}

@MainActor final class PhoneIdentityAuthorizationTests: XCTestCase {
    func testStoppingDuringIdentityAccessCannotRestartOrOverwriteStoppedState() async throws {
        for deny in [false, true] {
            let suite = "PhoneIdentityStop." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let storage = BlockingPhoneIdentityStorage(deny: deny)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            let remote = RemoteProductionManager(cloud: DesktopCloudManager(defaults: defaults), directory: root,
                sources: { _ in [] }, signingIdentity: RemoteServerIdentity(storage: storage),
                localFactory: { _, _, _, _, _, _ in XCTFail("stale authorization must not start a listener"); return PhoneIdentityHost() })
            let pending = Task { await remote.startPhoneSessions(host: "127.0.0.1", preferredPort: 0,
                pairingToken: "synthetic", storageRoot: root) }
            let started = await Task.detached { storage.waitUntilStarted() }.value
            XCTAssertTrue(started)
            await remote.stop()
            storage.release.signal()
            await pending.value
            XCTAssertEqual(remote.status, .stopped)
            XCTAssertFalse(remote.phonePairingEnabled)
            XCTAssertFalse(remote.needsIdentityAuthorization)
        }
    }

    func testLegacyNoUIScopeRestoresPolicyOnSuccessAndFailure() throws {
        var initial = false
        XCTAssertEqual(TomoKeychain.perform { TomoKeychainGetInteractionAllowed(&initial) }, errSecSuccess)
        for returned in [errSecSuccess, errSecAuthFailed, errSecInteractionNotAllowed] {
            let result = TomoKeychain.perform(allowInteraction: false) {
                var allowed = true
                XCTAssertEqual(TomoKeychainGetInteractionAllowed(&allowed), errSecSuccess)
                XCTAssertFalse(allowed)
                return returned
            }
            XCTAssertEqual(result, returned)
            var restored = false
            XCTAssertEqual(TomoKeychain.perform { TomoKeychainGetInteractionAllowed(&restored) }, errSecSuccess)
            XCTAssertEqual(restored, initial)
        }
    }

    func testBackgroundIdentityNeverPromptsOrReplacesBlockedKey() async throws {
        let storage = PhoneIdentityStorage(), identity = RemoteServerIdentity(storage: storage)
        for _ in 0..<3 {
            do { try await identity.prepareForBackgroundUse(); XCTFail("authorization required") }
            catch { XCTAssertEqual(error as? RemoteServerIdentityError, .authorizationRequired) }
        }
        XCTAssertEqual(storage.counts.silent, 3)
        XCTAssertEqual(storage.counts.interactive, 0)
        XCTAssertEqual(storage.counts.writes, 0)
        try await identity.authorizeForUse()
        let original = try await identity.publicIdentity()
        try await identity.prepareForBackgroundUse()
        let next = try await RemoteServerIdentity(storage: storage).publicIdentity()
        XCTAssertEqual(original, next)
        XCTAssertEqual(storage.counts.writes, 0)
    }

    func testAutomaticRestoreWaitsForAnExplicitRetryAndSurvivesDenial() async throws {
        let suite = "PhoneIdentityAuthorization." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "tomo.mobileSync.phoneSessionsEnabled")
        let storage = PhoneIdentityStorage()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let remote = RemoteProductionManager(cloud: DesktopCloudManager(defaults: defaults), directory: root,
            sources: { _ in [] }, signingIdentity: RemoteServerIdentity(storage: storage),
            localFactory: { _, _, _, _, _, _ in PhoneIdentityHost() })
        let phone = PhoneSessionManager(defaults: defaults, remote: remote, storageRoot: root)
        phone.updateConnection(host: "127.0.0.1", preferredPort: 0, pairingToken: "test-pairing")
        await phone.settled()
        XCTAssertEqual(phone.status, .failed)
        XCTAssertTrue(phone.needsIdentityAuthorization)
        XCTAssertEqual(storage.counts.interactive, 0)
        XCTAssertEqual(storage.counts.writes, 0)

        storage.denyNextAuthorization()
        phone.retry(); await phone.settled()
        XCTAssertEqual(phone.status, .failed)
        XCTAssertTrue(phone.needsIdentityAuthorization)
        XCTAssertEqual(storage.counts.interactive, 1)
        // A network change is background work, not permission to reopen the dialog.
        phone.updateConnection(host: "127.0.0.2", preferredPort: 0, pairingToken: "test-pairing")
        await phone.settled()
        XCTAssertEqual(storage.counts.interactive, 1)
        XCTAssertEqual(phone.status, .failed)

        phone.retry(); await phone.settled()
        XCTAssertEqual(phone.status, .ready)
        XCTAssertFalse(phone.needsIdentityAuthorization)
        XCTAssertEqual(storage.counts.interactive, 2)
        phone.suspend(); await phone.settled()
        phone.updateConnection(host: "127.0.0.1", preferredPort: 0, pairingToken: "test-pairing")
        await phone.settled()
        XCTAssertEqual(phone.status, .ready)
        XCTAssertEqual(storage.counts.interactive, 2)
        XCTAssertEqual(storage.counts.writes, 0)
        phone.setEnabled(false); await phone.settled()
    }
}
