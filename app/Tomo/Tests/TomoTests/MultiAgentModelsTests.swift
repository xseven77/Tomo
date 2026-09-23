import XCTest
@testable import Tomo

final class MultiAgentModelsTests: XCTestCase {
    func testPriorityOrderMatchesCommittedRoadmap() {
        XCTAssertEqual(
            BuiltInAgentCatalog.developmentPriority,
            [
                .init(agentID: .codex, surface: nil),
                .init(agentID: .deepseekHarness, surface: .deepseekHarnessCLI),
                .init(agentID: .hermes, surface: .hermesCLI),
                .init(agentID: .antigravity, surface: .antigravityDesktop),
                .init(agentID: .pi, surface: .piCLI),
            ]
        )
    }

    func testCodexHasTwoSurfacesWhileOthersAreCLIOnly() throws {
        let codex = try XCTUnwrap(
            BuiltInAgentCatalog.prioritized.first(where: { $0.id == .codex })
        )
        let dsh = try XCTUnwrap(
            BuiltInAgentCatalog.prioritized.first(where: { $0.id == .deepseekHarness })
        )
        let hermes = try XCTUnwrap(
            BuiltInAgentCatalog.prioritized.first(where: { $0.id == .hermes })
        )
        let pi = try XCTUnwrap(
            BuiltInAgentCatalog.prioritized.first(where: { $0.id == .pi })
        )

        XCTAssertTrue(codex.surfaces.contains(.codexCLI))
        XCTAssertTrue(codex.surfaces.contains(.codexDesktop))
        XCTAssertEqual(dsh.surfaces, [.deepseekHarnessCLI])
        XCTAssertEqual(hermes.surfaces, [.hermesCLI])
        XCTAssertEqual(pi.surfaces, [.piCLI])
    }

    func testSameVendorSessionIDDoesNotCollideAcrossCodexAccounts() {
        let personal = ConnectionID(rawValue: UUID())
        let work = ConnectionID(rawValue: UUID())

        let first = AgentSessionID(
            agentID: .codex,
            connectionID: personal,
            vendorSessionID: "thread-1"
        )
        let second = AgentSessionID(
            agentID: .codex,
            connectionID: work,
            vendorSessionID: "thread-1"
        )

        XCTAssertNotEqual(first, second)
    }

    func testCodexAccountsUseSeparateHomes() {
        let personal = AgentConnection(
            id: ConnectionID(rawValue: UUID()),
            agentID: .codex,
            label: "Personal",
            isolation: .codexHome(relativeDirectory: "codex/personal")
        )
        let work = AgentConnection(
            id: ConnectionID(rawValue: UUID()),
            agentID: .codex,
            label: "Work",
            isolation: .codexHome(relativeDirectory: "codex/work")
        )

        XCTAssertNotEqual(personal.isolation, work.isolation)
    }

    func testDeepSeekBalancesRemainConnectionScopedButAccountLevel() {
        let firstConnection = ConnectionID(rawValue: UUID())
        let secondConnection = ConnectionID(rawValue: UUID())
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let first = ProviderBalanceSnapshot(
            connectionID: firstConnection,
            providerID: .deepSeek,
            scope: .account,
            currency: "CNY",
            total: 110,
            granted: 10,
            toppedUp: 100,
            fetchedAt: timestamp
        )
        let second = ProviderBalanceSnapshot(
            connectionID: secondConnection,
            providerID: .deepSeek,
            scope: .account,
            currency: "CNY",
            total: 110,
            granted: 10,
            toppedUp: 100,
            fetchedAt: timestamp
        )

        XCTAssertNotEqual(first.connectionID, second.connectionID)
        XCTAssertEqual(first.scope, .account)
        XCTAssertEqual(second.scope, .account)
    }

    func testProviderBalanceIndicatorUsesRequestedThresholds() {
        XCTAssertEqual(ProviderBalanceIndicator.resolve(total: 42.80, authenticationState: .connected), .healthy)
        XCTAssertEqual(ProviderBalanceIndicator.resolve(total: 10, authenticationState: .connected), .low)
        XCTAssertEqual(ProviderBalanceIndicator.resolve(total: 0.01, authenticationState: .connected), .low)
        XCTAssertEqual(ProviderBalanceIndicator.resolve(total: 0, authenticationState: .connected), .depleted)
        XCTAssertEqual(ProviderBalanceIndicator.resolve(total: -1, authenticationState: .connected), .depleted)
        XCTAssertEqual(ProviderBalanceIndicator.resolve(total: nil, authenticationState: .invalid), .depleted)
    }

    func testDeepSeekCredentialFilesArePrivateAndRoundTripWithoutAuthenticationUI() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tomo-deepseek-credentials-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DeepSeekCredentialStore(credentialsDir: root)

        try store.save(apiKey: "sk-test", handle: "test-handle")

        XCTAssertEqual(try store.read(handle: "test-handle"), "sk-test")
        let attributes = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent("test-handle.json").path
        )
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
    }

    func testOpenCodeCredentialFilesArePrivateAndRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tomo-opencode-credentials-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OpenCodeCredentialStore(credentialsDir: root)

        try store.save(apiKey: "sk-opencode-test", handle: "test-handle")

        XCTAssertEqual(try store.read(handle: "test-handle"), "sk-opencode-test")
        let attributes = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent("test-handle.json").path
        )
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
    }

    @MainActor
    func testUnifiedRefreshValidatesOpenCodeGoAndZenSeparately() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tomo-opencode-refresh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let goID = ConnectionID(rawValue: UUID())
        let zenID = ConnectionID(rawValue: UUID())
        let registry = ConnectionRegistryStorage(fileURL: root.appendingPathComponent("connections.json"))
        try registry.save(ConnectionRegistrySnapshot(openCodeConnections: [
            OpenCodeAPIConnection(
                id: goID, label: "Go", plan: .go, credentialHandle: "go", keySuffix: "1111",
                authenticationState: .checking, availableModelCount: nil, lastValidatedAt: nil, createdAt: Date()
            ),
            OpenCodeAPIConnection(
                id: zenID, label: "Zen", plan: .zen, credentialHandle: "zen", keySuffix: "2222",
                authenticationState: .checking, availableModelCount: nil, lastValidatedAt: nil, createdAt: Date()
            ),
        ]))
        let models = TestOpenCodeModelsService()
        let store = MultiAgentSettingsStore(
            hookManager: AgentHookManager(homeDirectory: root.appendingPathComponent("home", isDirectory: true)),
            registryStorage: registry,
            codexRuntimeManager: CodexAccountRuntimeManager(runtimesRoot: root.appendingPathComponent("runtimes", isDirectory: true)),
            credentialStore: TestDeepSeekCredentialStore(values: [:]),
            deepSeekBalanceService: TestDeepSeekBalanceService(),
            openCodeCredentialStore: TestOpenCodeCredentialStore(values: ["go": "go-key", "zen": "zen-key"]),
            openCodeModelsService: models,
            startsAutomaticRefresh: false,
            migratesLegacyAccount: false
        )

        let outcome = await store.refreshAllConnections()

        XCTAssertEqual(outcome.successCount, 2)
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertEqual(store.openCodeConnections.map(\.authenticationState), [.connected, .connected])
        XCTAssertEqual(store.openCodeConnections.map(\.availableModelCount), [19, 56])
        let validatedPlans = await models.plans()
        XCTAssertEqual(Set(validatedPlans), Set([.go, .zen]))
        XCTAssertEqual(store.connectionKey(for: store.openCodeConnections[0]).split(separator: ".").first, "opencode-go")
        XCTAssertEqual(store.connectionKey(for: store.openCodeConnections[1]).split(separator: ".").first, "opencode-zen")
    }

    func testConnectionRegistryWithoutOrderFieldRemainsDecodable() throws {
        let data = try XCTUnwrap(
            #"{"schemaVersion":2,"codexAccounts":[],"deepSeekConnections":[]}"#.data(using: .utf8)
        )
        let snapshot = try JSONDecoder().decode(ConnectionRegistrySnapshot.self, from: data)

        XCTAssertTrue(snapshot.connectionOrder.isEmpty)
    }

    /// 回归：老版本保存的 OpenCode 连接没有 availableModelIDs / workspaceURL，
    /// 解码不得抛错（否则整个注册表会被当作空数据，导致所有登录被清空）。
    func testOpenCodeConnectionWithoutNewFieldsRemainsDecodable() throws {
        let data = try XCTUnwrap(#"""
        {
          "codexAccounts": [
            {
              "authenticationState": "connected",
              "createdAt": "2026-08-18T08:08:25Z",
              "id": {"rawValue": "6DDB6D5B-0543-4BFE-A700-C574049B4174"},
              "isEnabled": true,
              "label": "seven x",
              "relativeHomeDirectory": "6ddb6d5b-0543-4bfe-a700-c574049b4174",
              "usage": null
            }
          ],
          "openCodeConnections": [
            {
              "authenticationState": "connected",
              "availableModelCount": 26,
              "createdAt": "2026-08-18T10:22:00Z",
              "credentialHandle": "abcd",
              "id": {"rawValue": "25FAD053-E3D0-4E23-AF19-33A4B48CA0C6"},
              "keySuffix": "1234",
              "label": "Go",
              "lastValidatedAt": "2026-08-18T10:22:00Z",
              "plan": "go"
            }
          ],
          "deepSeekConnections": [],
          "schemaVersion": 3
        }
        """#.data(using: .utf8))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(ConnectionRegistrySnapshot.self, from: data)
        XCTAssertEqual(snapshot.codexAccounts.count, 1)
        XCTAssertEqual(snapshot.openCodeConnections.count, 1)
        XCTAssertEqual(snapshot.openCodeConnections[0].availableModelCount, 26)
        XCTAssertTrue(snapshot.openCodeConnections[0].availableModelIDs.isEmpty)
        XCTAssertNil(snapshot.openCodeConnections[0].workspaceURL)
    }

    @MainActor
    func testUnifiedRefreshUpdatesEveryDeepSeekConnection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tomo-unified-refresh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let firstID = ConnectionID(rawValue: UUID())
        let secondID = ConnectionID(rawValue: UUID())
        let registry = ConnectionRegistryStorage(fileURL: root.appendingPathComponent("connections.json"))
        try registry.save(ConnectionRegistrySnapshot(
            codexAccounts: [],
            deepSeekConnections: [
                DeepSeekAPIConnection(
                    id: firstID,
                    label: "First",
                    credentialHandle: "first",
                    keySuffix: "1111",
                    authenticationState: .checking,
                    createdAt: Date()
                ),
                DeepSeekAPIConnection(
                    id: secondID,
                    label: "Second",
                    credentialHandle: "second",
                    keySuffix: "2222",
                    authenticationState: .checking,
                    createdAt: Date()
                ),
            ]
        ))
        let credentialStore = TestDeepSeekCredentialStore(values: [
            "first": "first-key",
            "second": "second-key",
        ])
        let balanceService = TestDeepSeekBalanceService()
        let store = MultiAgentSettingsStore(
            hookManager: AgentHookManager(
                homeDirectory: root.appendingPathComponent("home", isDirectory: true)
            ),
            registryStorage: registry,
            codexRuntimeManager: CodexAccountRuntimeManager(
                runtimesRoot: root.appendingPathComponent("runtimes", isDirectory: true)
            ),
            credentialStore: credentialStore,
            deepSeekBalanceService: balanceService,
            startsAutomaticRefresh: false,
            migratesLegacyAccount: false
        )

        let outcome = await store.refreshAllConnections()
        let refreshedConnectionIDs = await balanceService.recordedConnectionIDs()

        XCTAssertFalse(store.isRefreshingConnections)
        XCTAssertEqual(outcome.successCount, 2)
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertEqual(store.deepSeekConnections.map(\.authenticationState), [.connected, .connected])
        XCTAssertEqual(store.deepSeekConnections.map { $0.balance?.total }, [11, 22])
        XCTAssertEqual(Set(refreshedConnectionIDs), Set([firstID, secondID]))
    }

    /// 回归：DeepSeek 官方模型目录只能来自官方接口。
    /// 拉取失败时必须保留上一次的官方结果，绝不能回退到本地写死的型号清单。
    @MainActor
    func testDeepSeekCatalogKeepsLastOfficialResultWhenFetchFails() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tomo-deepseek-catalog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let connection = DeepSeekAPIConnection(
            id: ConnectionID(rawValue: UUID()),
            label: "DSH",
            credentialHandle: "handle",
            keySuffix: "1234",
            authenticationState: .connected,
            availableModelIDs: ["deepseek-flash", "deepseek-v4-pro"],
            lastValidatedAt: Date(timeIntervalSince1970: 1_789_000_000),
            createdAt: Date()
        )
        let registry = ConnectionRegistryStorage(fileURL: root.appendingPathComponent("connections.json"))
        try registry.save(ConnectionRegistrySnapshot(codexAccounts: [], deepSeekConnections: [connection]))

        let store = MultiAgentSettingsStore(
            hookManager: AgentHookManager(homeDirectory: root.appendingPathComponent("home", isDirectory: true)),
            registryStorage: registry,
            codexRuntimeManager: CodexAccountRuntimeManager(
                runtimesRoot: root.appendingPathComponent("runtimes", isDirectory: true)
            ),
            credentialStore: TestDeepSeekCredentialStore(values: ["handle": "official-key"]),
            deepSeekBalanceService: TestDeepSeekBalanceService(),
            deepSeekModelsService: FailingDeepSeekModelsService(),
            startsAutomaticRefresh: false,
            migratesLegacyAccount: false
        )

        await store.refreshDeepSeekConnection(store.deepSeekConnections[0])

        let refreshed = try XCTUnwrap(store.deepSeekConnections.first)
        XCTAssertEqual(
            refreshed.availableModelIDs,
            ["deepseek-flash", "deepseek-v4-pro"],
            "官方目录拉取失败时应保留上一次官方结果，不得写入本地写死的型号"
        )
        XCTAssertEqual(
            refreshed.lastValidatedAt,
            Date(timeIntervalSince1970: 1_789_000_000),
            "失败不应刷新目录时间戳"
        )
    }

    @MainActor
    func testRefreshingConnectionIDsTrackPerAccountLoading() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tomo-per-account-refresh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let firstID = ConnectionID(rawValue: UUID())
        let secondID = ConnectionID(rawValue: UUID())
        let registry = ConnectionRegistryStorage(fileURL: root.appendingPathComponent("connections.json"))
        try registry.save(ConnectionRegistrySnapshot(
            codexAccounts: [],
            deepSeekConnections: [
                DeepSeekAPIConnection(
                    id: firstID,
                    label: "Fast",
                    credentialHandle: "first",
                    keySuffix: "1111",
                    authenticationState: .checking,
                    createdAt: Date()
                ),
                DeepSeekAPIConnection(
                    id: secondID,
                    label: "Slow",
                    credentialHandle: "second",
                    keySuffix: "2222",
                    authenticationState: .checking,
                    createdAt: Date()
                ),
            ]
        ))
        let store = MultiAgentSettingsStore(
            hookManager: AgentHookManager(
                homeDirectory: root.appendingPathComponent("home", isDirectory: true)
            ),
            registryStorage: registry,
            codexRuntimeManager: CodexAccountRuntimeManager(
                runtimesRoot: root.appendingPathComponent("runtimes", isDirectory: true)
            ),
            credentialStore: TestDeepSeekCredentialStore(values: [
                "first": "first-key",
                "second": "second-key",
            ]),
            deepSeekBalanceService: TestDelayedDeepSeekBalanceService(delays: [
                "first-key": 150_000_000,  // 0.15s
                "second-key": 600_000_000, // 0.60s
            ]),
            deepSeekModelsService: TestDeepSeekModelsService(),
            startsAutomaticRefresh: false,
            migratesLegacyAccount: false
        )

        let refreshTask = Task { await store.refreshAllConnections() }

        // 两个账号都在加载中。
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(store.refreshingConnectionIDs, Set([firstID, secondID]))
        XCTAssertTrue(store.isRefreshingConnection(store.deepSeekConnections[0]))
        XCTAssertTrue(store.isRefreshingConnection(store.deepSeekConnections[1]))

        // 快的账号已加载完，慢的账号仍在加载（分开加载、逐个移除）。
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(store.refreshingConnectionIDs, Set([secondID]))
        XCTAssertFalse(store.isRefreshingConnection(store.deepSeekConnections[0]))
        XCTAssertTrue(store.isRefreshingConnection(store.deepSeekConnections[1]))
        XCTAssertNotNil(store.deepSeekConnections[0].balance, "加载完成的账号应直接展示数据")

        let outcome = await refreshTask.value
        XCTAssertEqual(outcome.successCount, 2)
        XCTAssertTrue(store.refreshingConnectionIDs.isEmpty, "全部加载完后清空加载状态")
    }

    @MainActor
    func testLastSelectedProviderConnectionPersistsAndReloads() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tomo-selected-connection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let defaultsKey = "dashboard.selectedConnection"
        let previousSelection = UserDefaults.standard.object(forKey: defaultsKey)
        defer {
            if let previousSelection {
                UserDefaults.standard.set(previousSelection, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }
        UserDefaults.standard.set("", forKey: defaultsKey)

        let firstID = ConnectionID(rawValue: UUID())
        let secondID = ConnectionID(rawValue: UUID())
        let registry = ConnectionRegistryStorage(fileURL: root.appendingPathComponent("connections.json"))
        try registry.save(ConnectionRegistrySnapshot(
            deepSeekConnections: [
                DeepSeekAPIConnection(
                    id: firstID,
                    label: "First",
                    credentialHandle: "first",
                    keySuffix: "1111",
                    authenticationState: .connected,
                    createdAt: Date()
                ),
                DeepSeekAPIConnection(
                    id: secondID,
                    label: "Second",
                    credentialHandle: "second",
                    keySuffix: "2222",
                    authenticationState: .connected,
                    createdAt: Date()
                ),
            ]
        ))

        func makeStore() -> MultiAgentSettingsStore {
            MultiAgentSettingsStore(
                hookManager: AgentHookManager(
                    homeDirectory: root.appendingPathComponent("home", isDirectory: true)
                ),
                registryStorage: registry,
                codexRuntimeManager: CodexAccountRuntimeManager(
                    runtimesRoot: root.appendingPathComponent("runtimes", isDirectory: true)
                ),
                credentialStore: TestDeepSeekCredentialStore(values: [:]),
                deepSeekBalanceService: TestDeepSeekBalanceService(),
                startsAutomaticRefresh: false,
                migratesLegacyAccount: false
            )
        }

        let store = makeStore()
        let selectedConnection = store.deepSeekConnections[1]
        let selectedKey = store.connectionKey(for: selectedConnection)
        store.selectDeepSeekConnection(selectedConnection)

        XCTAssertEqual(store.selectedConnectionKey, selectedKey)
        XCTAssertEqual(makeStore().selectedConnectionKey, selectedKey)
        XCTAssertEqual(makeStore().selectedDeepSeekConnection?.id, selectedConnection.id)
    }

    @MainActor
    func testConnectionOrderPersistsAndDrivesCarousel() throws {
        let defaultsKey = "dashboard.selectedConnection"
        let previousSelection = UserDefaults.standard.object(forKey: defaultsKey)
        defer {
            if let previousSelection {
                UserDefaults.standard.set(previousSelection, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }
        UserDefaults.standard.set("", forKey: defaultsKey)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tomo-connection-order-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let firstID = ConnectionID(rawValue: UUID())
        let secondID = ConnectionID(rawValue: UUID())
        let registry = ConnectionRegistryStorage(fileURL: root.appendingPathComponent("connections.json"))
        try registry.save(ConnectionRegistrySnapshot(deepSeekConnections: [
            DeepSeekAPIConnection(
                id: firstID,
                label: "First",
                credentialHandle: "first",
                keySuffix: "1111",
                authenticationState: .connected,
                createdAt: Date()
            ),
            DeepSeekAPIConnection(
                id: secondID,
                label: "Second",
                credentialHandle: "second",
                keySuffix: "2222",
                authenticationState: .connected,
                createdAt: Date()
            ),
        ]))

        func makeStore() -> MultiAgentSettingsStore {
            MultiAgentSettingsStore(
                hookManager: AgentHookManager(
                    homeDirectory: root.appendingPathComponent("home", isDirectory: true)
                ),
                registryStorage: registry,
                codexRuntimeManager: CodexAccountRuntimeManager(
                    runtimesRoot: root.appendingPathComponent("runtimes", isDirectory: true)
                ),
                credentialStore: TestDeepSeekCredentialStore(values: [:]),
                deepSeekBalanceService: TestDeepSeekBalanceService(),
                startsAutomaticRefresh: false,
                migratesLegacyAccount: false
            )
        }

        let store = makeStore()
        let secondKey = store.connectionKey(for: store.deepSeekConnections[1])
        store.moveConnection(key: secondKey, to: 0, among: store.orderedConnectionKeys)

        XCTAssertEqual(store.orderedConnectionKeys.first, secondKey)
        XCTAssertEqual(makeStore().orderedConnectionKeys.first, secondKey)

        store.selectConnection(key: secondKey)
        store.selectNextConnection()
        XCTAssertEqual(store.selectedConnectionKey, store.connectionKey(for: store.deepSeekConnections[0]))
    }

    @MainActor
    func testAccountCarouselRemainsPausedUntilEveryHoveredSurfaceExits() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tomo-carousel-pause-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = MultiAgentSettingsStore(
            hookManager: AgentHookManager(
                homeDirectory: root.appendingPathComponent("home", isDirectory: true)
            ),
            registryStorage: ConnectionRegistryStorage(fileURL: root.appendingPathComponent("connections.json")),
            codexRuntimeManager: CodexAccountRuntimeManager(
                runtimesRoot: root.appendingPathComponent("runtimes", isDirectory: true)
            ),
            credentialStore: TestDeepSeekCredentialStore(values: [:]),
            deepSeekBalanceService: TestDeepSeekBalanceService(),
            startsAutomaticRefresh: false,
            migratesLegacyAccount: false
        )
        var pauseChanges: [Bool] = []
        store.onAccountCarouselPauseChanged = { pauseChanges.append($0) }

        store.setAccountCarouselPaused(true, source: .dashboard)
        store.setAccountCarouselPaused(true, source: .dashboardInfo)
        store.setAccountCarouselPaused(true, source: .notch(screenNumber: 1))
        store.setAccountCarouselPaused(false, source: .dashboard)

        XCTAssertTrue(store.isAccountCarouselPaused)
        XCTAssertEqual(pauseChanges, [true])

        store.setAccountCarouselPaused(false, source: .notch(screenNumber: 1))

        XCTAssertTrue(store.isAccountCarouselPaused)
        XCTAssertEqual(pauseChanges, [true])

        store.setAccountCarouselPaused(false, source: .dashboardInfo)

        XCTAssertFalse(store.isAccountCarouselPaused)
        XCTAssertEqual(pauseChanges, [true, false])
    }

    func testManualRefreshToastSummarizesSuccessPartialFailureAndFailure() {
        let success = RefreshToast(outcome: RefreshOutcome(successCount: 3))
        XCTAssertTrue(success.isSuccess)
        XCTAssertEqual(success.message, "刷新成功 · 已更新 3 个连接")

        let partial = RefreshToast(outcome: RefreshOutcome(
            successCount: 2,
            failures: ["Hermes 未能刷新"]
        ))
        XCTAssertFalse(partial.isSuccess)
        XCTAssertEqual(partial.message, "部分刷新失败 · 1 个连接")

        let failure = RefreshToast(outcome: RefreshOutcome(failures: ["DeepSeek：网络不可用"]))
        XCTAssertFalse(failure.isSuccess)
        XCTAssertEqual(failure.message, "刷新失败 · DeepSeek：网络不可用")
    }
}

private final class TestDeepSeekCredentialStore: DeepSeekCredentialStoring, @unchecked Sendable {
    private let values: [String: String]

    init(values: [String: String]) {
        self.values = values
    }

    func save(apiKey: String, handle: String) throws {}

    func read(handle: String) throws -> String {
        guard let value = values[handle] else { throw DeepSeekCredentialError.missing }
        return value
    }

    func delete(handle: String) throws {}
}

private final class TestOpenCodeCredentialStore: OpenCodeCredentialStoring, @unchecked Sendable {
    private let values: [String: String]

    init(values: [String: String]) {
        self.values = values
    }

    func save(apiKey: String, handle: String) throws {}

    func read(handle: String) throws -> String {
        guard let value = values[handle] else { throw DeepSeekCredentialError.missing }
        return value
    }

    func delete(handle: String) throws {}
}

private actor TestOpenCodeModelsService: OpenCodeModelsFetching {
    private var validatedPlans: [OpenCodePlan] = []

    func validate(apiKey: String, plan: OpenCodePlan) async throws -> [String] {
        validatedPlans.append(plan)
        return plan == .go
            ? (0..<19).map { "go-model-\($0)" }
            : (0..<56).map { "zen-model-\($0)" }
    }

    func plans() -> [OpenCodePlan] { validatedPlans }
}

private actor TestDelayedDeepSeekBalanceService: DeepSeekBalanceFetching {
    private let delays: [String: UInt64]

    init(delays: [String: UInt64]) {
        self.delays = delays
    }

    func fetch(apiKey: String, connectionID: ConnectionID) async throws -> ProviderBalanceSnapshot {
        if let delay = delays[apiKey] {
            try await Task.sleep(nanoseconds: delay)
        }
        let total: Decimal = apiKey == "first-key" ? 11 : 22
        return ProviderBalanceSnapshot(
            connectionID: connectionID,
            providerID: .deepSeek,
            scope: .account,
            currency: "CNY",
            total: total,
            granted: 0,
            toppedUp: total,
            fetchedAt: Date()
        )
    }
}

private actor TestDeepSeekBalanceService: DeepSeekBalanceFetching {
    private var connectionIDs: [ConnectionID] = []

    func recordedConnectionIDs() -> [ConnectionID] {
        connectionIDs
    }

    func fetch(apiKey: String, connectionID: ConnectionID) async throws -> ProviderBalanceSnapshot {
        connectionIDs.append(connectionID)
        let total: Decimal = apiKey == "first-key" ? 11 : 22
        return ProviderBalanceSnapshot(
            connectionID: connectionID,
            providerID: .deepSeek,
            scope: .account,
            currency: "CNY",
            total: total,
            granted: 0,
            toppedUp: total,
            fetchedAt: Date()
        )
    }
}

private struct TestDeepSeekModelsService: DeepSeekModelsFetching {
    func validate(apiKey: String) async throws -> [String] {
        ["deepseek-chat", "deepseek-reasoner", "deepseek-v4-pro"]
    }
}

/// 官方模型目录接口失败：用于验证「保留上一次官方结果」而不是回退硬编码清单。
private struct FailingDeepSeekModelsService: DeepSeekModelsFetching {
    func validate(apiKey: String) async throws -> [String] {
        throw DeepSeekValidationError.unavailable
    }
}
