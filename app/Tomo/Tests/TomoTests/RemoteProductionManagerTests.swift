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

@MainActor final class RemoteProductionManagerTests: XCTestCase {
    private func cloud(defaults: UserDefaults) async throws -> DesktopCloudManager {
        let storage = DesktopSessionMemory(), http = DesktopCloudFixture(), signer = RemoteServerIdentity(storage: DesktopIdentityMemory())
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let cloud = DesktopCloudManager(defaults: defaults, factory: {
            try DesktopCloudSession(endpoint: $0, storage: storage, http: http, identity: signer, clock: { date })
        })
        await cloud.configure("https://cloud.example.test"); await cloud.sendCode(email: "owner@example.test"); await cloud.signIn(code: "123456")
        await cloud.register(name: "Studio Mac"); return cloud
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
        await cloud.logout()
        let stopped = await host.stopped; XCTAssertTrue(stopped)
        XCTAssertEqual(manager.status, .stopped); XCTAssertNil(manager.endpoint); XCTAssertNil(cloud.summary)
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
        for endpoint in ["http://localhost:58352", "https://user@localhost:58352", "https://localhost/api", "https://localhost/?token=x"] {
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
        let tls = try RemoteTLSFixture(); defer { tls.remove() }
        let name = "RemoteProductionManagerTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let cloud = try await cloud(defaults: defaults)
        let manager = RemoteProductionManager(cloud: cloud, catalog: ManagerTLSCatalog(tls.identity), directory: tls.directory,
            factory: { _, _, _, _, _, _ in XCTFail("Missing real directory must fail before factory"); return ManagerHost() })
        await manager.loadCertificates()
        await manager.start(endpoint: "https://localhost:58352", certificateId: "fixture", storageRoot: tls.directory)
        XCTAssertEqual(manager.status, .failed); XCTAssertNil(manager.endpoint)
    }
}
