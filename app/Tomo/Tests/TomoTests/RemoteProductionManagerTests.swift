import XCTest
import SQLite3
@testable import Tomo

actor ManagerTLSCatalog: RemoteTLSIdentityCatalog {
    let value: RemoteTLSIdentity
    init(_ value: RemoteTLSIdentity) { self.value = value }
    func choices() -> [RemoteTLSChoice] { [.init(id: "fixture", label: "Fixture localhost", fingerprint: "test-only")] }
    func identity(id: String) throws -> RemoteTLSIdentity {
        guard id == "fixture" else { throw RemoteAccessError.invalidConfiguration }; return value
    }
}
private struct ManagerDirectoryFixture: Sendable {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("phone-manager-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func remove() {try? FileManager.default.removeItem(at: directory)}
}
private struct ManagerNoTLSCatalog: RemoteTLSIdentityCatalog {
    func choices() async throws -> [RemoteTLSChoice] {XCTFail("HTTP must not load TLS choices"); return []}
    func identity(id: String) async throws -> RemoteTLSIdentity {XCTFail("HTTP must not load a TLS identity"); throw RemoteAccessError.invalidConfiguration}
}
private actor ManagerHost: RemoteProductionHosting {
    nonisolated let states: AsyncStream<RemoteHTTPSListener.State>
    let continuation: AsyncStream<RemoteHTTPSListener.State>.Continuation
    var stopped = false
    let onStop: @Sendable () -> Void
    init(onStop: @escaping @Sendable () -> Void = {}) {
        self.onStop = onStop
        let pair = AsyncStream<RemoteHTTPSListener.State>.makeStream(bufferingPolicy: .bufferingNewest(1))
        states = pair.stream; continuation = pair.continuation; continuation.yield(.running)
    }
    func stop() { stopped = true; continuation.yield(.stopped); continuation.finish(); onStop() }
    func fail() { continuation.yield(.failed); continuation.finish() }
    func endStates() { continuation.finish() }
}
private actor ManagerStartGate {
    private var pending: CheckedContinuation<Void, Never>?, observer: CheckedContinuation<Void, Never>?
    private var waiting = false
    func hold() async { await withCheckedContinuation { pending = $0; waiting = true; observer?.resume(); observer = nil } }
    func wait() async { if waiting { return }; await withCheckedContinuation { observer = $0 } }
    func resume() { pending?.resume(); pending = nil }
}
private actor ManagerPhoneAttempts {
    private var value = 0, failing = false
    func setFailing(_ value: Bool) {failing = value}
    func prepare() throws -> Int {
        value += 1
        if failing {throw ChatGPTRuntimeError.authenticationRequired}
        return value
    }
    func count() -> Int {value}
}
private final class ManagerPhoneClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_900_000_000)
    func now() -> Date {lock.lock(); defer {lock.unlock()}; return date}
    func advance(_ seconds: TimeInterval) {lock.lock(); defer {lock.unlock()}; date = date.addingTimeInterval(seconds)}
}

@MainActor final class RemoteProductionManagerTests: XCTestCase {
    func testInvalidPhoneLocationKeepsHostAvailableWithoutReplacingRecoveryData() async throws {
        let fixture = try ManagerDirectoryFixture(); defer {fixture.remove()}
        let suite = "InvalidPhoneLocation." + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {defaults.removePersistentDomain(forName: suite)}
        let signer = RemoteServerIdentity(storage: DesktopIdentityMemory()), identity = try await signer.localIdentity()
        let folder = fixture.directory.appendingPathComponent("phone/" + identity.serverId.uuidString.lowercased())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let record = folder.appendingPathComponent("conversation-namespace"), invalid = Data("../invalid".utf8)
        try invalid.write(to: record)
        let home = fixture.directory.appendingPathComponent("account")
        let manager = RemoteProductionManager(cloud: DesktopCloudManager(defaults: defaults), directory: fixture.directory,
            sources: {_ in [RemoteReadServiceTests.Adapter(), ChatGPTReadAdapter(directory: .init(databaseURL: home.appendingPathComponent("state.sqlite"),
                storageRoot: home, runtimeId: "rt_account"), runtimeLabel: "Synthetic account")]}, signingIdentity: signer,
            preparePhoneConversation: {service in _ = try await service.ownedChatGPT.preparePhoneConversation(executable: fixture.directory.appendingPathComponent("must-not-run"))})
        await manager.startPhoneSessions(host: "127.0.0.1", preferredPort: try RemoteTLSFixture.freePort(),
            pairingToken: "synthetic-invalid-phone-location", storageRoot: fixture.directory)
        do {
            XCTAssertEqual(manager.status, .running); XCTAssertTrue(manager.phonePairingEnabled)
            XCTAssertTrue(manager.message?.contains("本地恢复记录不可用") == true)
            let configuration = try await manager.mobileHostConfiguration(includeInteraction: true)
            XCTAssertTrue(configuration.contains("runtime_test")); XCTAssertFalse(configuration.contains("rt_phone_"))
            XCTAssertEqual(try Data(contentsOf: record), invalid)
            await manager.stop()
        } catch {await manager.stop(); throw error}
    }
    func testPhoneConfigurationRetriesPreparationWithBackoffAndKeepsHistoryAvailable() async throws {
        let fixture = try ManagerDirectoryFixture(); defer {fixture.remove()}
        let suite = "PhoneMaintenance." + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {defaults.removePersistentDomain(forName: suite)}
        let attempts = ManagerPhoneAttempts(), clock = ManagerPhoneClock()
        await attempts.setFailing(true)
        let manager = RemoteProductionManager(cloud: DesktopCloudManager(defaults: defaults), directory: fixture.directory,
            sources: {_ in [RemoteReadServiceTests.Adapter()]}, signingIdentity: RemoteServerIdentity(storage: DesktopIdentityMemory()),
            preparePhoneConversation: {_ in _ = try await attempts.prepare()}, phoneClock: {clock.now()})
        await manager.startPhoneSessions(host: "127.0.0.1", preferredPort: try RemoteTLSFixture.freePort(),
            pairingToken: "synthetic-phone-maintenance", storageRoot: fixture.directory)
        do {
            XCTAssertEqual(manager.status, .running); XCTAssertTrue(manager.phonePairingEnabled)
            XCTAssertNotNil(manager.message)
            _ = try await manager.mobileHostConfiguration(includeInteraction: true)
            let startupCount = await attempts.count(); XCTAssertEqual(startupCount, 1)
            clock.advance(31)
            _ = try await manager.mobileHostConfiguration(includeInteraction: true)
            _ = try await manager.mobileHostConfiguration(includeInteraction: true)
            let failedCount = await attempts.count(); XCTAssertEqual(failedCount, 2)
            await attempts.setFailing(false); clock.advance(31)
            let descriptor = try await manager.mobileHostConfiguration(includeInteraction: true)
            let recoveredCount = await attempts.count(); XCTAssertEqual(recoveredCount, 3)
            XCTAssertNil(manager.message)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(descriptor.utf8)) as? [String: Any])
            let hosts = try XCTUnwrap(object["hosts"] as? [[String: Any]])
            XCTAssertTrue((hosts.first?["scopes"] as? [String])?.contains("session.read") == true)
            await manager.stop()
        } catch {await manager.stop(); throw error}
    }
    func testConcurrentPhoneConfigurationReadsShareOnePreparation() async throws {
        let fixture = try ManagerDirectoryFixture(); defer {fixture.remove()}
        let suite = "PhoneMaintenance." + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {defaults.removePersistentDomain(forName: suite)}
        let attempts = ManagerPhoneAttempts(), gate = ManagerStartGate()
        let manager = RemoteProductionManager(cloud: DesktopCloudManager(defaults: defaults), directory: fixture.directory,
            sources: {_ in [RemoteReadServiceTests.Adapter()]}, signingIdentity: RemoteServerIdentity(storage: DesktopIdentityMemory()),
            preparePhoneConversation: {_ in if try await attempts.prepare() == 2 {await gate.hold()}})
        await manager.startPhoneSessions(host: "127.0.0.1", preferredPort: try RemoteTLSFixture.freePort(),
            pairingToken: "synthetic-phone-maintenance", storageRoot: fixture.directory)
        let first = Task {try await manager.mobileHostConfiguration(includeInteraction: true)}
        await gate.wait()
        let started = AsyncStream<Void>.makeStream()
        let second = Task {
            started.continuation.yield(()); started.continuation.finish()
            return try await manager.mobileHostConfiguration(includeInteraction: true)
        }
        for await _ in started.stream {break}
        await gate.resume()
        do {
            _ = try await first.value; _ = try await second.value
            let count = await attempts.count(); XCTAssertEqual(count, 2)
            await manager.stop()
        } catch {await manager.stop(); throw error}
    }
    func testStoppingPhoneServiceRejectsLateConfigurationPreparation() async throws {
        let fixture = try ManagerDirectoryFixture(); defer {fixture.remove()}
        let suite = "PhoneMaintenance." + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {defaults.removePersistentDomain(forName: suite)}
        let attempts = ManagerPhoneAttempts(), gate = ManagerStartGate()
        let manager = RemoteProductionManager(cloud: DesktopCloudManager(defaults: defaults), directory: fixture.directory,
            sources: {_ in [RemoteReadServiceTests.Adapter()]}, signingIdentity: RemoteServerIdentity(storage: DesktopIdentityMemory()),
            preparePhoneConversation: {_ in if try await attempts.prepare() == 2 {await gate.hold()}})
        await manager.startPhoneSessions(host: "127.0.0.1", preferredPort: try RemoteTLSFixture.freePort(),
            pairingToken: "synthetic-phone-maintenance", storageRoot: fixture.directory)
        let pending = Task {try await manager.mobileHostConfiguration(includeInteraction: true)}
        await gate.wait(); manager.invalidatePhonePairing(); await manager.stopPhoneSessions(); await gate.resume()
        do {_ = try await pending.value; XCTFail("Stopped service returned a configuration")}
        catch {XCTAssertEqual(error as? RemoteAccessError, .unavailable)}
        XCTAssertEqual(manager.status, .stopped); XCTAssertFalse(manager.phonePairingEnabled); XCTAssertNil(manager.endpoint)
        let count = await attempts.count(); XCTAssertEqual(count, 2)
    }
    func testLocalModeStartsWithoutCloudAndCloudLogoutDoesNotStopIt() async throws {
        let fixture = try ManagerDirectoryFixture(); defer {fixture.remove()}
        let name = "RemoteLocalManagerTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        let cloud = DesktopCloudManager(defaults: defaults), signer = RemoteServerIdentity(storage: DesktopIdentityMemory())
        let identity = try await signer.localIdentity(), host = ManagerHost()
        let manager = RemoteProductionManager(cloud: cloud, catalog: ManagerNoTLSCatalog(), directory: fixture.directory,
            sources: { _ in [RemoteReadServiceTests.Adapter()] }, signingIdentity: signer,
            localFactory: { endpoint, tls, _, directory, conversationDirectory, adapters in
                XCTAssertEqual(endpoint.scheme, "http"); XCTAssertNil(tls)
                XCTAssertNil(conversationDirectory)
                XCTAssertTrue(directory.path.contains("/local/")); XCTAssertEqual(adapters.count, 1); return host
            }, factory: { _, _, _, _, _, _ in XCTFail("Local mode called cloud factory"); return host })
        await manager.start(endpoint: "http://localhost:58352", certificateId: "", storageRoot: fixture.directory, mode: .local)
        XCTAssertEqual(manager.status, .running); XCTAssertNil(cloud.server)
        XCTAssertEqual(manager.mobileTaskSource?.serverId, identity.serverId.uuidString.lowercased())
        await cloud.logout(clearConfiguration: true)
        XCTAssertEqual(manager.status, .running)
        await manager.stop(); XCTAssertEqual(manager.status, .stopped)
    }
    private func cloud(defaults: UserDefaults) async throws -> DesktopCloudManager {
        let storage = DesktopSessionMemory(), http = DesktopCloudFixture(), signer = RemoteServerIdentity(storage: DesktopIdentityMemory())
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let cloud = DesktopCloudManager(defaults: defaults, factory: {
            try DesktopCloudSession(endpoint: $0, storage: storage, http: http, identity: signer, clock: { date })
        })
        await cloud.configure("https://cloud.example.test"); await cloud.sendCode(email: "owner@example.test"); await cloud.signIn(code: "123456")
        await cloud.register(name: "Studio Mac"); return cloud
    }
    func testHTTPServiceStartsWithoutLoadingOrSupplyingTLSIdentity() async throws {
        let fixture = try ManagerDirectoryFixture(); defer {fixture.remove()}
        let name = "RemoteProductionManagerTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let cloud = try await cloud(defaults: defaults), host = ManagerHost()
        let manager = RemoteProductionManager(cloud: cloud, catalog: ManagerNoTLSCatalog(), directory: fixture.directory,
            sources: { _ in [RemoteReadServiceTests.Adapter()] }, factory: { _, _, endpoint, identity, _, _ in
                XCTAssertEqual(endpoint.scheme, "http"); XCTAssertNil(identity); return host
            })
        XCTAssertTrue(manager.choices.isEmpty)
        await manager.start(endpoint: "http://localhost:58352", certificateId: "", storageRoot: fixture.directory)
        XCTAssertEqual(manager.status, .running)
        XCTAssertEqual(manager.endpoint?.absoluteString, "http://localhost:58352")
        await manager.stop()
    }

    func testConfiguredServiceStartsAndCloudLogoutStopsIt() async throws {
        let tls = try RemoteTLSFixture(); defer { tls.remove() }
        let name = "RemoteProductionManagerTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let cloud = try await cloud(defaults: defaults), host = ManagerHost()
        let manager = RemoteProductionManager(cloud: cloud, catalog: ManagerTLSCatalog(tls.identity), directory: tls.directory,
            sources: { _ in [RemoteReadServiceTests.Adapter()] }, factory: { _, _, _, _, _, adapters in
                XCTAssertEqual(adapters.count, 1); return host
            })
        await manager.loadCertificates(); XCTAssertEqual(manager.choices.count, 1)
        await manager.start(endpoint: "https://localhost:58352", certificateId: "fixture", storageRoot: tls.directory)
        XCTAssertEqual(manager.status, .running); XCTAssertNotNil(manager.endpoint)
        XCTAssertEqual(manager.mobileTaskSource?.serverId, cloud.server?.id.uuidString.lowercased())
        XCTAssertEqual(manager.mobileTaskSource?.directories.count, 0)
        await cloud.logout()
        let stopped = await host.stopped; XCTAssertTrue(stopped)
        XCTAssertEqual(manager.status, .stopped); XCTAssertNil(manager.endpoint); XCTAssertNil(cloud.summary)
        XCTAssertNil(manager.mobileTaskSource)
    }
    func testStopDuringStartupDisposesLateService() async throws {
        let tls = try RemoteTLSFixture(); defer { tls.remove() }
        let name = "RemoteProductionManagerTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let cloud = try await cloud(defaults: defaults), host = ManagerHost(), gate = ManagerStartGate()
        let manager = RemoteProductionManager(cloud: cloud, catalog: ManagerTLSCatalog(tls.identity), directory: tls.directory,
            sources: { _ in [RemoteReadServiceTests.Adapter()] }, factory: { _, _, _, _, _, _ in await gate.hold(); return host })
        await manager.loadCertificates()
        let task = Task { await manager.start(endpoint: "https://localhost:58352", certificateId: "fixture", storageRoot: tls.directory) }
        await gate.wait(); XCTAssertEqual(manager.status, .starting)
        await manager.stop(); await gate.resume(); await task.value
        let stopped = await host.stopped; XCTAssertTrue(stopped)
        XCTAssertEqual(manager.status, .stopped); XCTAssertNil(manager.endpoint)
        XCTAssertNil(manager.mobileTaskSource)
    }
    func testCloudLogoutDuringStartupDoesNotRestoreOldService() async throws {
        let tls = try RemoteTLSFixture(); defer { tls.remove() }
        let name = "RemoteProductionManagerTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let cloud = try await cloud(defaults: defaults), host = ManagerHost(), gate = ManagerStartGate()
        let manager = RemoteProductionManager(cloud: cloud, catalog: ManagerTLSCatalog(tls.identity), directory: tls.directory,
            sources: { _ in [RemoteReadServiceTests.Adapter()] }, factory: { _, _, _, _, _, _ in await gate.hold(); return host })
        await manager.loadCertificates()
        let task = Task { await manager.start(endpoint: "https://localhost:58352", certificateId: "fixture", storageRoot: tls.directory) }
        await gate.wait(); await cloud.logout(clearConfiguration: true); await gate.resume(); await task.value
        let stopped = await host.stopped; XCTAssertTrue(stopped)
        XCTAssertEqual(manager.status, .stopped); XCTAssertNil(cloud.server); XCTAssertEqual(cloud.configuredURL, "")
    }
    func testInvalidEndpointOrMissingCertificateDoesNotRunFactory() async throws {
        let tls = try RemoteTLSFixture(); defer { tls.remove() }
        let name = "RemoteProductionManagerTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let cloud = try await cloud(defaults: defaults)
        let manager = RemoteProductionManager(cloud: cloud, catalog: ManagerTLSCatalog(tls.identity), directory: tls.directory,
            sources: { _ in [RemoteReadServiceTests.Adapter()] }, factory: { _, _, _, _, _, _ in XCTFail("Invalid config ran factory"); return ManagerHost() })
        await manager.loadCertificates()
        for endpoint in ["ftp://localhost:58352", "https://user@localhost:58352", "https://localhost/api", "https://localhost/?token=x"] {
            await manager.start(endpoint: endpoint, certificateId: "fixture", storageRoot: tls.directory)
            XCTAssertEqual(manager.status, .failed); XCTAssertNotNil(manager.message)
        }
        await manager.start(endpoint: "https://localhost:58352", certificateId: "missing", storageRoot: tls.directory)
        XCTAssertEqual(manager.status, .failed)
    }
    func testCallerCancellationWhileResolvingSourceResetsStartingStatus() async throws {
        let tls = try RemoteTLSFixture(); defer { tls.remove() }
        let name = "RemoteProductionManagerTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let cloud = try await cloud(defaults: defaults), gate = ManagerStartGate()
        let manager = RemoteProductionManager(cloud: cloud, catalog: ManagerTLSCatalog(tls.identity), directory: tls.directory,
            sources: { _ in await gate.hold(); return [RemoteReadServiceTests.Adapter()] },
            factory: { _, _, _, _, _, _ in XCTFail("Canceled source must not start a host"); return ManagerHost() })
        await manager.loadCertificates()
        let task = Task { await manager.start(endpoint: "https://localhost:58352", certificateId: "fixture", storageRoot: tls.directory) }
        await gate.wait(); task.cancel(); await gate.resume(); await task.value
        XCTAssertEqual(manager.status, .stopped); XCTAssertNil(manager.message); XCTAssertNil(manager.endpoint)
    }
    func testCallerCancellationDisposesFactoryIgnoringCancellation() async throws {
        let tls = try RemoteTLSFixture(); defer { tls.remove() }
        let name = "RemoteProductionManagerTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let cloud = try await cloud(defaults: defaults), host = ManagerHost(), gate = ManagerStartGate()
        let manager = RemoteProductionManager(cloud: cloud, catalog: ManagerTLSCatalog(tls.identity), directory: tls.directory,
            sources: { _ in [RemoteReadServiceTests.Adapter()] }, factory: { _, _, _, _, _, _ in await gate.hold(); return host })
        await manager.loadCertificates()
        let task = Task { await manager.start(endpoint: "https://localhost:58352", certificateId: "fixture", storageRoot: tls.directory) }
        await gate.wait(); task.cancel(); await gate.resume(); await task.value
        let stopped = await host.stopped; XCTAssertTrue(stopped)
        XCTAssertEqual(manager.status, .stopped); XCTAssertNil(manager.message); XCTAssertNil(manager.endpoint)
    }
    func testListenerFailureAndUnexpectedStreamEndDisposeHost() async throws {
        let tls = try RemoteTLSFixture(); defer { tls.remove() }
        let name = "RemoteProductionManagerTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let cloud = try await cloud(defaults: defaults)
        for emitFailure in [true, false] {
            let stopped = expectation(description: "Host stops after state stream terminates")
            let host = ManagerHost(onStop: { stopped.fulfill() })
            let manager = RemoteProductionManager(cloud: cloud, catalog: ManagerTLSCatalog(tls.identity), directory: tls.directory,
                sources: { _ in [RemoteReadServiceTests.Adapter()] }, factory: { _, _, _, _, _, _ in host })
            await manager.loadCertificates()
            await manager.start(endpoint: "https://localhost:58352", certificateId: "fixture", storageRoot: tls.directory)
            if emitFailure { await host.fail() } else { await host.endStates() }
            await fulfillment(of: [stopped], timeout: 3)
            XCTAssertEqual(manager.status, .failed); XCTAssertNil(manager.endpoint); XCTAssertNotNil(manager.message)
        }
    }
    func testDefaultSourceReadsRealDirectoryAndPublishesOnlyReadActions() async throws {
        let tls = try RemoteTLSFixture(); defer { tls.remove() }
        let name = "RemoteProductionManagerTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(tls.directory.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        let database = try XCTUnwrap(db)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE threads(id TEXT,rollout_path TEXT,title TEXT,updated_at INTEGER)", nil, nil, nil), SQLITE_OK)
        let cloud = try await cloud(defaults: defaults), host = ManagerHost()
        let manager = RemoteProductionManager(cloud: cloud, catalog: ManagerTLSCatalog(tls.identity), directory: tls.directory,
            factory: { _, _, _, _, _, adapters in
                let adapter = try XCTUnwrap(adapters.first)
                XCTAssertEqual(adapters.count, 1); XCTAssertEqual(adapter.descriptor.agentId, "agent.chatgpt")
                XCTAssertTrue(adapter.runtimeId.hasPrefix("rt_chatgpt_"))
                XCTAssertEqual(adapter.runtimeActions, [.listSessions, .readHistory])
                let listing = try await adapter.sessions(serverId: "test-server")
                XCTAssertTrue(listing.items.isEmpty)
                return host
            })
        await manager.loadCertificates()
        await manager.start(endpoint: "https://localhost:58352", certificateId: "fixture", storageRoot: tls.directory)
        XCTAssertEqual(manager.status, .running)
        await manager.stop()
    }
    func testMissingRealDirectoryCannotPublishPlaceholderRuntime() async throws {
        let fixture = try ManagerDirectoryFixture(); defer {fixture.remove()}
        let name = "RemoteProductionManagerTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let cloud = try await cloud(defaults: defaults)
        let manager = RemoteProductionManager(cloud: cloud, catalog: ManagerNoTLSCatalog(), directory: fixture.directory,
            factory: { _, _, _, _, _, _ in XCTFail("Missing real directory must fail before factory"); return ManagerHost() })
        await manager.start(endpoint: "http://localhost:58352", certificateId: "", storageRoot: fixture.directory)
        XCTAssertEqual(manager.status, .failed); XCTAssertNil(manager.endpoint)
    }
}
