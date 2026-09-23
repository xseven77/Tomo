import AppKit
import XCTest
@testable import Tomo

@MainActor
final class GatewayTests: XCTestCase {
    func testAgentCompatibleModelIDUsesGatewayAccountSyntaxWithoutSpaces() {
        XCTAssertEqual(
            GatewayStore.agentCompatibleModelID("gemini-3.7-flash (Seven X)"),
            "gemini-3.7-flash@seven-x"
        )
        XCTAssertEqual(
            GatewayStore.agentCompatibleModelID("deepseek-chat"),
            "deepseek-chat"
        )
        XCTAssertEqual(
            GatewayStore.hermesPickerModelID(
                provider: "Google Gemini",
                modelName: "gemini-3.7-flash",
                accountName: "X Seven"
            ),
            "Google-Gemini·gemini-3.7-flash·X-Seven"
        )
    }

    func testConnectionShortIDAndCompositeModelFormatting() {
        let uuid = UUID(uuidString: "12345678-ABCD-EF01-2345-6789ABCDEF01")!
        let connID = ConnectionID(rawValue: uuid)
        let shortID = GatewayStore.connectionShortID(id: connID)
        XCTAssertEqual(shortID, "12345678")

        let slug = "\(GatewayStore.accountSlug(name: "Work"))-google-\(shortID)"
        XCTAssertEqual(slug, "work-google-12345678")

        let agentModelID = GatewayStore.agentCompatibleModelID("gemini-2.5-flash (\(slug))")
        XCTAssertEqual(agentModelID, "gemini-2.5-flash@work-google-12345678")
    }

    func testCodexServableSlugsReadsCliauthoritativeCacheAndExcludesHidden() throws {
        let fm = FileManager.default
        let runtimesRoot = fm.temporaryDirectory.appendingPathComponent("codex-runtimes-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: runtimesRoot) }
        let relative = "abc123-def456"
        let home = runtimesRoot.appendingPathComponent(relative, isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try """
        {"models":[
          {"slug":"gpt-reserve","visibility":"hide","display_name":"Reserve"},
          {"slug":"codex-auto-review","visibility":"hide","display_name":"Review"},
          {"slug":"gpt-5.6-sol","visibility":"list","display_name":"GPT-5.6 Sol"},
          {"slug":"gpt-brand-new","visibility":"list"}
        ]}
        """.data(using: .utf8)!.write(to: home.appendingPathComponent("models_cache.json"))

        // availableModelIDs (the OpenAI/ChatGPT API catalog) is now the source
        // of truth, exactly matching how Gemini/OpenCode/DeepSeek operate — the
        // requirement is to run on the OpenAI API, not a local codex CLI.
        let connection = CodexAccountConnection(
            id: ConnectionID(rawValue: UUID()),
            label: "Seven X",
            relativeHomeDirectory: relative,
            authenticationState: .connected,
            isEnabled: true,
            usage: nil,
            availableModelIDs: [
                "gpt-5.6-sol-wm",
                "gpt-5.6-terra-wm",
                "gpt-5.5-wm",
                "gpt-5-6",
                "research",
            ],
            createdAt: Date()
        )
        let slugs = GatewayStore.codexServableSlugs(from: connection, runtimesRoot: runtimesRoot)
        // -wm watermark suffix is stripped, `research` is dropped, flagship order is applied.
        XCTAssertEqual(slugs, ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5-6", "gpt-5.5"])
        XCTAssertFalse(slugs.contains("research"), "research is an internal entry")

        // When availableModelIDs is empty, fall back to the CLI cache and still
        // exclude hidden/internal entries.
        let cacheConnection = CodexAccountConnection(
            id: ConnectionID(rawValue: UUID()),
            label: "Cache Only",
            relativeHomeDirectory: relative,
            authenticationState: .connected,
            isEnabled: true,
            usage: nil,
            availableModelIDs: [],
            createdAt: Date()
        )
        let cacheSlugs = GatewayStore.codexServableSlugs(from: cacheConnection, runtimesRoot: runtimesRoot)
        XCTAssertEqual(cacheSlugs, ["gpt-5.6-sol", "gpt-brand-new"])
        XCTAssertFalse(cacheSlugs.contains("gpt-reserve"))
        XCTAssertFalse(cacheSlugs.contains("codex-auto-review"))
    }

    func testHermesGatewayConfigurationUsesOfficialCustomProviderContractAndVerifiesWrites() throws {
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-config-\(UUID().uuidString).yaml")
        try Data("model:\n  provider: opencode-free\n".utf8).write(to: configURL)
        defer { try? FileManager.default.removeItem(at: configURL) }

        let runner = TestHermesCommandRunner()
        let configurator = HermesGatewayConfigurator(runner: runner, configURL: configURL)
        try configurator.configure(
            baseURL: "http://127.0.0.1:58349/v1",
            apiKey: "local-test-token",
            models: ["deepseek-chat", "gemini-3.1-pro-preview"],
            defaultModel: "gemini-3.1-pro-preview"
        )

        XCTAssertEqual(runner.values["providers.tomo.name"], "Tomo")
        XCTAssertEqual(runner.values["providers.tomo.api"], "http://127.0.0.1:58349/v1")
        XCTAssertEqual(runner.values["providers.tomo.api_key"], "local-test-token")
        XCTAssertEqual(runner.values["providers.tomo.transport"], "chat_completions")
        XCTAssertEqual(runner.values["providers.tomo.default_model"], "gemini-3.1-pro-preview")
        XCTAssertEqual(runner.values["providers.tomo.discover_models"], "false")
        XCTAssertEqual(runner.values["providers.tomo.models"], "[\"deepseek-chat\",\"gemini-3.1-pro-preview\"]")
        XCTAssertEqual(runner.values["providers.tomo.extra_headers.X-Tomo-Catalog-Version"], "2")
        XCTAssertEqual(runner.values["providers.tomo.extra_headers.X-Agent-Name"], "Hermes")
        XCTAssertEqual(runner.values["model.provider"], "custom:tomo")
        XCTAssertEqual(runner.values["model.default"], "gemini-3.1-pro-preview")
        XCTAssertEqual(runner.commands.filter { $0.starts(with: ["config", "set"]) }.count, 11)
        XCTAssertEqual(runner.commands.filter { $0.starts(with: ["config", "unset"]) }.count, 2)
        XCTAssertEqual(runner.commands.filter { $0.starts(with: ["config", "get"]) }.count, 10)
    }

    func testHermesGatewayConfigurationRejectsFalseSuccessWhenReadbackDiffers() throws {
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-config-\(UUID().uuidString).yaml")
        let original = Data("model:\n  provider: opencode-free\n".utf8)
        try original.write(to: configURL)
        defer { try? FileManager.default.removeItem(at: configURL) }

        let runner = TestHermesCommandRunner(forcedReadback: ["model.provider": "opencode-free"])
        let configurator = HermesGatewayConfigurator(runner: runner, configURL: configURL)

        XCTAssertThrowsError(
            try configurator.configure(
                baseURL: "http://127.0.0.1:58349/v1",
                apiKey: "local-test-token",
                models: ["deepseek-chat"],
                defaultModel: "deepseek-chat"
            )
        )
        XCTAssertEqual(try Data(contentsOf: configURL), original)
    }

    func testHermesGatewayUnconfigurationRemovesProviderAndResetsModel() throws {
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-config-\(UUID().uuidString).yaml")
        try Data("providers:\n  tomo:\n    name: Tomo\n".utf8).write(to: configURL)
        defer { try? FileManager.default.removeItem(at: configURL) }

        let runner = TestHermesCommandRunner()
        let configurator = HermesGatewayConfigurator(runner: runner, configURL: configURL)

        // First configure
        try configurator.configure(
            baseURL: "http://127.0.0.1:58349/v1",
            apiKey: "local-test-token",
            models: ["deepseek-chat"],
            defaultModel: "deepseek-chat"
        )
        XCTAssertTrue(configurator.isConfigured)

        // Now unconfigure
        try configurator.unconfigure()
        XCTAssertFalse(configurator.isConfigured)
        XCTAssertNil(runner.values["providers.tomo.name"])
        XCTAssertNil(runner.values["providers.tomo.api"])
        XCTAssertNil(runner.values["providers.tomo.api_key"])
        XCTAssertNil(runner.values["providers.tomo.models"])
        XCTAssertNil(runner.values["model.provider"])
        XCTAssertNil(runner.values["model.default"])
    }

    func testPiGatewayConfigurationWritesModelsContractAndPreservesSettings() throws {
        let agentDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: agentDirectory) }

        let modelsURL = agentDirectory.appendingPathComponent("models.json")
        let settingsURL = agentDirectory.appendingPathComponent("settings.json")
        try Data(#"{"providers":{"existing":{"baseUrl":"http://example.test","api":"openai-completions","apiKey":"x","models":[{"id":"old"}]}}}"#.utf8).write(to: modelsURL)
        try Data(#"{"theme":"dark","provider":"stale","baseURL":"stale","apiKey":"stale"}"#.utf8).write(to: settingsURL)

        let runner = TestPiCommandRunner(discoveredModel: "deepseek-chat")
        let configurator = PiGatewayConfigurator(runner: runner, agentDirectory: agentDirectory)
        try configurator.configure(
            baseURL: "http://127.0.0.1:58349/v1",
            apiKey: "local-test-token",
            models: ["deepseek-chat", "gemini-3.1-pro-preview", "deepseek-chat"],
            defaultModel: "deepseek-chat"
        )

        let modelsRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: modelsURL)) as? [String: Any]
        )
        let providers = try XCTUnwrap(modelsRoot["providers"] as? [String: Any])
        XCTAssertNotNil(providers["existing"])
        let tomo = try XCTUnwrap(providers["tomo"] as? [String: Any])
        XCTAssertEqual(tomo["baseUrl"] as? String, "http://127.0.0.1:58349/v1")
        XCTAssertEqual(tomo["api"] as? String, "openai-completions")
        XCTAssertEqual(tomo["apiKey"] as? String, "local-test-token")
        XCTAssertEqual((tomo["models"] as? [[String: Any]])?.count, 2)

        let settings = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
        )
        XCTAssertEqual(settings["theme"] as? String, "dark")
        XCTAssertEqual(settings["defaultProvider"] as? String, "tomo")
        XCTAssertEqual(settings["defaultModel"] as? String, "deepseek-chat")
        XCTAssertNil(settings["provider"])
        XCTAssertNil(settings["baseURL"])
        XCTAssertNil(settings["apiKey"])
        XCTAssertEqual(runner.commands, [["--offline", "--list-models", "tomo"]])
    }

    func testPiGatewayUnconfigurationRemovesProviderAndResetsDefaults() throws {
        let agentDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: agentDirectory) }

        let modelsURL = agentDirectory.appendingPathComponent("models.json")
        let settingsURL = agentDirectory.appendingPathComponent("settings.json")
        try Data(#"{"providers":{"tomo":{"baseUrl":"http://example.test"},"other":{"baseUrl":"http://other.test"}}}"#.utf8).write(to: modelsURL)
        try Data(#"{"defaultProvider":"tomo","defaultModel":"gemini-3.7-flash","otherSetting":"keep"}"#.utf8).write(to: settingsURL)

        let runner = TestPiCommandRunner(discoveredModel: "gemini-3.7-flash")
        let configurator = PiGatewayConfigurator(runner: runner, agentDirectory: agentDirectory)

        XCTAssertTrue(configurator.isConfigured)

        try configurator.unconfigure()

        XCTAssertFalse(configurator.isConfigured)

        let modelsRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: modelsURL)) as? [String: Any]
        )
        let providers = try XCTUnwrap(modelsRoot["providers"] as? [String: Any])
        XCTAssertNil(providers["tomo"])
        XCTAssertNotNil(providers["other"])

        let settings = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
        )
        XCTAssertNil(settings["defaultProvider"])
        XCTAssertNil(settings["defaultModel"])
        XCTAssertEqual(settings["otherSetting"] as? String, "keep")
    }

    func testGatewaySupervisorStateAndToggle() {
        let supervisor = GatewaySupervisor.shared
        XCTAssertTrue(supervisor.isRunning)
        XCTAssertEqual(supervisor.port, 58349)
        XCTAssertEqual(supervisor.endpoint?.absoluteString, "http://127.0.0.1:58349")
        XCTAssertFalse(supervisor.localToken.isEmpty)
        XCTAssertEqual(supervisor.statusText, "运行中")

        supervisor.stop()
        XCTAssertFalse(supervisor.isRunning)
        XCTAssertEqual(supervisor.statusText, "已停止")

        supervisor.start()
        XCTAssertTrue(supervisor.isRunning)
        XCTAssertEqual(supervisor.statusText, "运行中")
    }

    func testGatewayStoreTelemetryAndChecks() {
        let store = GatewayStore.shared
        XCTAssertEqual(store.telemetryItems.count, 7)
        XCTAssertEqual(store.doctorChecks.count, 5)
        XCTAssertTrue(store.doctorChecks.contains { $0.id == "sec" && $0.isSuccess })
        XCTAssertTrue(store.doctorChecks.contains { !$0.isSuccess })
        XCTAssertGreaterThanOrEqual(store.accountModelGroups.count, 4)
        // Set health response to nil or available in test to ensure model exportable test isn't filtered by stale live health file
        store.modelHealthResponse = nil
        XCTAssertEqual(store.openAIBaseURL, "http://127.0.0.1:58349/v1")
        XCTAssertEqual(store.anthropicBaseURL, "http://127.0.0.1:58349")
        XCTAssertFalse(store.localToken.isEmpty)
        XCTAssertEqual(store.agentRows.count, 5)
        XCTAssertTrue(store.requestsList.isEmpty)

        // Test Codex group exists
        let codexGroup = store.accountModelGroups.first { $0.id.hasPrefix("codex") }
        XCTAssertNotNil(codexGroup)

        // Custom entries are explicitly user-added and are exported alongside
        // the account's discovered model catalog.
        let geminiGroupId = store.accountModelGroups.first { $0.id.hasPrefix("google_gemini") }?.id ?? "google_gemini"
        store.addCustomModel("custom-gemini-test", toGroupId: geminiGroupId)
        let geminiGroup = store.accountModelGroups.first { $0.id == geminiGroupId }
        XCTAssertTrue(geminiGroup?.models.contains(where: { $0.modelName.contains("custom-gemini-test") }) ?? false)

        store.removeCustomModel("custom-gemini-test", fromGroupId: geminiGroupId)
        let geminiGroupAfter = store.accountModelGroups.first { $0.id == geminiGroupId }
        XCTAssertFalse(geminiGroupAfter?.models.contains(where: { $0.modelName.contains("custom-gemini-test") }) ?? true)

        // Test Tab Switching
        store.selectedTab = .connect
        XCTAssertEqual(store.selectedTab.rawValue, "模型接入")
        XCTAssertEqual(store.selectedTab.symbolName, "network")

        // Test metric updates
        store.updateGatewayMetrics(totalRequests: 10, inputTokens: 5000, outputTokens: 2000, toolCalls: 4)
        XCTAssertEqual(store.totalRequests, 10)
        XCTAssertEqual(store.totalInputTokens, 5000)
        XCTAssertEqual(store.totalOutputTokens, 2000)
        XCTAssertEqual(store.totalToolCalls, 4)
        XCTAssertFalse(store.todayDurationText.isEmpty)
    }

    func testGatewayStorePerAgentDurationAttribution() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("companion-stats-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let now = Date()
        let statsStore = CompanionStatsStore(fileURL: fileURL, now: now)
        statsStore.setActivityState(.executing, agentID: "antigravity", now: now)
        statsStore.tick(now: now.addingTimeInterval(60))
        statsStore.tick(now: now.addingTimeInterval(120))
        statsStore.setActivityState(.idle, agentID: nil, now: now.addingTimeInterval(120))

        statsStore.setActivityState(.executing, agentID: "hermes", now: now.addingTimeInterval(120))
        statsStore.tick(now: now.addingTimeInterval(180))
        statsStore.tick(now: now.addingTimeInterval(240))
        statsStore.setActivityState(.idle, agentID: nil, now: now.addingTimeInterval(240))

        let store = GatewayStore(companionStatsStore: statsStore)
        let rows = store.agentRows
        let codexRow = rows.first { $0.id == "codex" }
        let agRow = rows.first { $0.id == "antigravity" }
        let hermesRow = rows.first { $0.id == "hermes" }
        let dshRow = rows.first { $0.id == "dsh" }
        let piRow = rows.first { $0.id == "pi" }

        XCTAssertEqual(codexRow?.durationText, "0 分钟")
        XCTAssertEqual(agRow?.durationText, "2 分钟")
        XCTAssertEqual(hermesRow?.durationText, "2 分钟")
        XCTAssertEqual(dshRow?.durationText, "0 分钟")
        XCTAssertEqual(piRow?.durationText, "0 分钟")
    }

    func testGatewayWindowControllerProperties() {
        let controller = GatewayWindowController.shared
        controller.show()
        
        // Window should not release on close, and windowShouldClose must return false
        // to keep supervisor process alive
        let window = NSApp.windows.first { $0.title == "Tomo Gateway" }
        XCTAssertNotNil(window)
        if let window {
            XCTAssertFalse(window.isReleasedWhenClosed)
            XCTAssertFalse(controller.windowShouldClose(window))
        }
        controller.close()
    }

    func testGatewaySecretBrokerSaveAndRetrieve() throws {
        let broker = GatewaySecretBroker.shared
        let testAccount = "test-provider-key-\(UUID().uuidString)"
        let secret = "sk-test-secret-value-12345"

        try broker.saveSecret(secret, for: testAccount)
        let retrieved = broker.retrieveSecret(for: testAccount)
        XCTAssertEqual(retrieved, secret)

        try broker.deleteSecret(for: testAccount)
        let afterDelete = broker.retrieveSecret(for: testAccount)
        XCTAssertNil(afterDelete)
    }

    func testGatewaySettingsStorageDefaultAndRoundtrip() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gateway-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let settingsURL = tempDir.appendingPathComponent("gateway-settings.json")
        let storage = GatewaySettingsStorage(fileURL: settingsURL)

        // Initial load when file does not exist should yield default settings
        let defaultSettings = storage.load()
        XCTAssertEqual(defaultSettings.schemaVersion, GatewaySettings.currentSchemaVersion)
        XCTAssertFalse(defaultSettings.modelConsolidationEnabled)
        XCTAssertFalse(defaultSettings.autoCheckOnStartupWithHistory)
        XCTAssertEqual(defaultSettings.healthCheckInterval, HealthCheckInterval.oneHour.rawValue)
        XCTAssertTrue(defaultSettings.allowFailover)
        XCTAssertEqual(defaultSettings.cooldownSeconds, 300)
        XCTAssertEqual(defaultSettings.maxFailoverRetries, 2)
        XCTAssertFalse(defaultSettings.allowLanAccess)
        XCTAssertEqual(defaultSettings.routingMode(for: "google"), .smooth)

        // Save customized settings
        var custom = GatewaySettings(
            modelConsolidationEnabled: true,
            allowFailover: false,
            cooldownSeconds: 600,
            maxFailoverRetries: 3,
            autoCheckOnStartupWithHistory: true,
            healthCheckInterval: HealthCheckInterval.midnight.rawValue,
            allowLanAccess: true
        )
        custom.setRoutingMode(for: "google", mode: ProviderRoutingMode.smooth)
        custom.setRoutingMode(for: "openai", mode: ProviderRoutingMode.pinnedAccount, pinnedAccountId: "pinned-uuid-1")
        try storage.save(custom)

        // Verify file permissions 0600
        let attrs = try FileManager.default.attributesOfItem(atPath: settingsURL.path)
        let perms = attrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)

        // Readback check
        let loaded = storage.load()
        XCTAssertEqual(loaded, custom)
        XCTAssertTrue(loaded.autoCheckOnStartupWithHistory)
        XCTAssertEqual(loaded.healthCheckInterval, HealthCheckInterval.midnight.rawValue)
        XCTAssertTrue(loaded.allowLanAccess)
        XCTAssertEqual(loaded.routingMode(for: "google"), ProviderRoutingMode.smooth)
        XCTAssertEqual(loaded.routingMode(for: "openai"), ProviderRoutingMode.pinnedAccount)
        XCTAssertEqual(loaded.pinnedAccountId(for: "openai"), "pinned-uuid-1")
        XCTAssertNil(loaded.pinnedAccountId(for: "google"))
    }

    func testGatewayStoreAllowLanAccessTogglePersists() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gateway-lan-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let settingsURL = tempDir.appendingPathComponent("gateway-settings.json")
        let storage = GatewaySettingsStorage(fileURL: settingsURL)
        let store = GatewayStore(settingsStorage: storage)

        XCTAssertFalse(store.allowLanAccess)
        store.allowLanAccess = true
        XCTAssertTrue(store.allowLanAccess)

        // Verify storage on disk was updated
        let reloaded = storage.load()
        XCTAssertTrue(reloaded.allowLanAccess)
    }

    func testGatewayNetworkInfoAndLanURLs() {
        let ip = GatewayNetworkInfo.currentLANIPv4()
        let store = GatewayStore.shared
        if let ip {
            XCTAssertFalse(ip.isEmpty)
            XCTAssertFalse(ip.hasPrefix("127."))
            XCTAssertEqual(store.lanOpenAIBaseURL, "http://\(ip):\(GatewaySupervisor.shared.port)/v1")
            XCTAssertEqual(store.lanAnthropicBaseURL, "http://\(ip):\(GatewaySupervisor.shared.port)")
        } else {
            XCTAssertNil(store.lanOpenAIBaseURL)
            XCTAssertNil(store.lanAnthropicBaseURL)
        }
    }

    func testGatewayStoreModelConsolidationTogglePersists() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gateway-store-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let settingsURL = tempDir.appendingPathComponent("gateway-settings.json")
        let storage = GatewaySettingsStorage(fileURL: settingsURL)
        let store = GatewayStore(settingsStorage: storage)

        XCTAssertFalse(store.isModelConsolidationEnabled)
        store.isModelConsolidationEnabled = true
        XCTAssertTrue(store.isModelConsolidationEnabled)

        // Verify storage on disk was updated
        let reloaded = storage.load()
        XCTAssertTrue(reloaded.modelConsolidationEnabled)
    }

    func testHermesTwoSegmentPickerModelID() {
        // Test 2-segment picker formatting for consolidated pool routing
        let pickerID1 = GatewayStore.hermesPickerModelID(
            provider: "Google Gemini",
            modelName: "gemini-3.7-flash"
        )
        XCTAssertEqual(pickerID1, "Google-Gemini·gemini-3.7-flash")

        let pickerID2 = GatewayStore.hermesPickerModelID(
            provider: "OpenAI",
            modelName: "gpt-5.6-sol"
        )
        XCTAssertEqual(pickerID2, "OpenAI·gpt-5.6-sol")

        let pickerID3 = GatewayStore.hermesPickerModelID(
            provider: "Google",
            modelName: "gemini-2.5-pro-tiered"
        )
        // Ensure `-tiered` implementation suffix is removed
        XCTAssertEqual(pickerID3, "Google·gemini-2.5-pro")
    }

    func testConsolidatedExportedModelsSwitching() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gateway-store-consolidation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let settingsURL = tempDir.appendingPathComponent("gateway-settings.json")
        let storage = GatewaySettingsStorage(fileURL: settingsURL)
        let store = GatewayStore(settingsStorage: storage)

        // When consolidation is disabled, allExportedModels reflects account-scoped models
        XCTAssertFalse(store.isModelConsolidationEnabled)
        let unconsolidatedCount = store.allExportedModels.count

        // Enable consolidation
        store.isModelConsolidationEnabled = true
        XCTAssertTrue(store.isModelConsolidationEnabled)

        // All exported models should now be deduplicated by (provider, baseModel)
        let consolidated = store.allExportedModels
        XCTAssertEqual(consolidated, store.consolidatedExportedModels)

        // Ensure no scoped account suffixes "(...)" exist in consolidated model names
        // and that each modelName is prefixed with "供应商 · "
        for model in consolidated {
            XCTAssertFalse(model.modelName.contains(" ("), "Consolidated model should not contain account scope: \(model.modelName)")
            XCTAssertTrue(model.modelName.contains(" · "), "Consolidated model should contain provider prefix: \(model.modelName)")
            XCTAssertTrue(model.sourceBadge.contains("聚合"))
        }

        // Toggle back
        store.isModelConsolidationEnabled = false
        XCTAssertEqual(store.allExportedModels.count, unconsolidatedCount)
    }

    func testConsolidatedModelNamingAndAgentCompatibility() {
        XCTAssertEqual(
            GatewayStore.agentCompatibleModelID("OpenCode · glm-5.3-flash"),
            "opencode/glm-5.3-flash"
        )
        XCTAssertEqual(
            GatewayStore.agentCompatibleModelID("OpenAI · gpt-5.6-sol"),
            "openai/gpt-5.6-sol"
        )
        XCTAssertEqual(
            GatewayStore.agentCompatibleModelID("Google · gemini-2.5-flash"),
            "google/gemini-2.5-flash"
        )
        XCTAssertEqual(
            GatewayStore.unscopedModelName("OpenCode · glm-5.3-flash"),
            "glm-5.3-flash"
        )
        XCTAssertEqual(
            GatewayStore.unscopedModelName("OpenAI · gpt-5.6-sol"),
            "gpt-5.6-sol"
        )
        XCTAssertEqual(
            GatewayStore.providerName(for: "opencode"),
            "OpenCode"
        )
        XCTAssertEqual(
            GatewayStore.providerName(for: "google"),
            "Google"
        )
    }

    func testPerProviderConsolidationSwitchingAndPersistence() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gateway-store-per-provider-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let settingsURL = tempDir.appendingPathComponent("gateway-settings.json")
        let storage = GatewaySettingsStorage(fileURL: settingsURL)
        let store = GatewayStore(settingsStorage: storage)

        // Initially no providers are consolidated
        XCTAssertFalse(store.isProviderConsolidated("openai"))
        XCTAssertFalse(store.isProviderConsolidated("google"))
        XCTAssertFalse(store.isProviderConsolidated("deepseek"))
        XCTAssertFalse(store.isProviderConsolidated("opencode"))

        // Enable only OpenAI consolidation
        store.setProviderConsolidated("openai", enabled: true)
        XCTAssertTrue(store.isProviderConsolidated("openai"))
        XCTAssertTrue(store.isProviderConsolidated("codex"))
        XCTAssertFalse(store.isProviderConsolidated("google"))
        XCTAssertFalse(store.isProviderConsolidated("deepseek"))
        XCTAssertFalse(store.isProviderConsolidated("opencode"))
        XCTAssertTrue(store.isModelConsolidationEnabled)

        // Reload from disk into a fresh store to verify persistence
        let storeReloaded = GatewayStore(settingsStorage: storage)
        XCTAssertTrue(storeReloaded.isProviderConsolidated("openai"))
        XCTAssertFalse(storeReloaded.isProviderConsolidated("google"))

        // Enable Google as well
        store.setProviderConsolidated("google", enabled: true)
        XCTAssertTrue(store.isProviderConsolidated("google"))
        XCTAssertTrue(store.isProviderConsolidated("gemini"))

        // Disable OpenAI
        store.setProviderConsolidated("openai", enabled: false)
        XCTAssertFalse(store.isProviderConsolidated("openai"))
        XCTAssertTrue(store.isProviderConsolidated("google"))

        // Disable Google
        store.setProviderConsolidated("google", enabled: false)
        XCTAssertFalse(store.isProviderConsolidated("google"))
        XCTAssertFalse(store.isModelConsolidationEnabled)
    }

    func testGeminiProxyEnabledDoesNotDependOnEmptyModels() {
        let store = GatewayStore()
        let googleGroups = store.accountModelGroups.filter { $0.id.hasPrefix("google_gemini_") }
        for group in googleGroups {
            XCTAssertTrue(group.isProxyAllowed)
            XCTAssertEqual(group.isProxyEnabled, true)
        }
    }

    func testPlanBModelNamingAndAgentCompatibility() {
        // Consolidated models format: 供应商 · 模型名
        let consolidatedName = "OpenCode · glm-5.3-flash"
        XCTAssertEqual(GatewayStore.unscopedModelName(consolidatedName), "glm-5.3-flash")
        XCTAssertEqual(GatewayStore.agentCompatibleModelID(consolidatedName), "opencode/glm-5.3-flash")

        // Unconsolidated models format: 供应商 · 模型名 (账号标识)
        let unconsolidatedOpenCode = "OpenCode · glm-5.3-flash (go-opencode-1e29e790)"
        XCTAssertEqual(GatewayStore.unscopedModelName(unconsolidatedOpenCode), "glm-5.3-flash")
        XCTAssertEqual(GatewayStore.agentCompatibleModelID(unconsolidatedOpenCode), "opencode/glm-5.3-flash@go-opencode-1e29e790")

        let unconsolidatedOpenAI = "OpenAI · gpt-5.6-sol (my-openai-a1b2)"
        XCTAssertEqual(GatewayStore.unscopedModelName(unconsolidatedOpenAI), "gpt-5.6-sol")
        XCTAssertEqual(GatewayStore.agentCompatibleModelID(unconsolidatedOpenAI), "openai/gpt-5.6-sol@my-openai-a1b2")

        let unconsolidatedGoogle = "Google · gemini-2.5-flash (x-seven-gemini-a1b2)"
        XCTAssertEqual(GatewayStore.unscopedModelName(unconsolidatedGoogle), "gemini-2.5-flash")
        XCTAssertEqual(GatewayStore.agentCompatibleModelID(unconsolidatedGoogle), "google/gemini-2.5-flash@x-seven-gemini-a1b2")

        let unconsolidatedDeepSeek = "DeepSeek · deepseek-chat (deepseek-official-a1b2)"
        XCTAssertEqual(GatewayStore.unscopedModelName(unconsolidatedDeepSeek), "deepseek-chat")
        XCTAssertEqual(GatewayStore.agentCompatibleModelID(unconsolidatedDeepSeek), "deepseek/deepseek-chat@deepseek-official-a1b2")

        // Also ensure backward compatibility for old style without provider prefix: "模型名 (账号标识)"
        let legacyUnconsolidated = "glm-5.3-flash (go-opencode-1e29e790)"
        XCTAssertEqual(GatewayStore.unscopedModelName(legacyUnconsolidated), "glm-5.3-flash")
        XCTAssertEqual(GatewayStore.agentCompatibleModelID(legacyUnconsolidated), "glm-5.3-flash@go-opencode-1e29e790")
    }

    func testModelExportableFiltersUnavailableModels() {
        let store = GatewayStore()
        let testConnID = ConnectionID(rawValue: UUID(uuidString: "1E29E790-7565-4D03-923A-91BA5E18E174")!)

        let healthyItem = GatewayModelHealthItem(
            id: "deepseek-v4-flash",
            scopedId: "opencode/deepseek-v4-flash@GO-opencode-1e29e790",
            status: "available",
            reason: nil,
            latencyMs: 2200,
            checkedAt: 12345,
            retries: 0,
            exported: true
        )
        let unavailableItem = GatewayModelHealthItem(
            id: "grok-4.5",
            scopedId: "opencode/grok-4.5@GO-opencode-1e29e790",
            status: "unavailable",
            reason: "Endpoint is unavailable",
            latencyMs: 1000,
            checkedAt: 12345,
            retries: 0,
            exported: false
        )
        let errorItem = GatewayModelHealthItem(
            id: "grok-4.6",
            scopedId: "opencode/grok-4.6@GO-opencode-1e29e790",
            status: "error",
            reason: "Internal error",
            latencyMs: 800,
            checkedAt: 12345,
            retries: 1,
            exported: false
        )

        let accountHealth = GatewayAccountHealth(
            provider: "opencode",
            providerName: "OpenCode",
            connectionId: "1E29E790-7565-4D03-923A-91BA5E18E174",
            slug: "GO-opencode-1e29e790",
            label: "OpenCode (GO)",
            checkedAt: 12345,
            summary: GatewayModelHealthSummary(total: 3, available: 1, unavailable: 1, error: 1),
            models: [healthyItem, unavailableItem, errorItem]
        )

        store.modelHealthResponse = GatewayModelHealthResponse(
            lastFullCheckAt: 12345,
            summary: GatewayModelHealthSummary(total: 3, available: 1, unavailable: 1, error: 1),
            accounts: [accountHealth],
            job: nil
        )

        // Non-consolidated checks
        XCTAssertTrue(store.isModelExportable(baseModel: "deepseek-v4-flash", providerId: "opencode", connectionID: testConnID, isConsolidated: false))
        XCTAssertFalse(store.isModelExportable(baseModel: "grok-4.5", providerId: "opencode", connectionID: testConnID, isConsolidated: false))
        XCTAssertFalse(store.isModelExportable(baseModel: "grok-4.6", providerId: "opencode", connectionID: testConnID, isConsolidated: false))
        // Verify display names with spaces also match normalized IDs
        XCTAssertFalse(store.isModelExportable(baseModel: "Grok 4.5", providerId: "opencode", connectionID: testConnID, isConsolidated: false))
        XCTAssertFalse(store.isModelExportable(baseModel: "Grok 4.6", providerId: "opencode", connectionID: testConnID, isConsolidated: false))

        // Consolidated checks
        XCTAssertTrue(store.isModelExportable(baseModel: "deepseek-v4-flash", providerId: "opencode", connectionID: nil, isConsolidated: true))
        XCTAssertFalse(store.isModelExportable(baseModel: "grok-4.5", providerId: "opencode", connectionID: nil, isConsolidated: true))
        XCTAssertFalse(store.isModelExportable(baseModel: "grok-4.6", providerId: "opencode", connectionID: nil, isConsolidated: true))
        // Consolidated checks with display names containing spaces
        XCTAssertFalse(store.isModelExportable(baseModel: "Grok 4.5", providerId: "opencode", connectionID: nil, isConsolidated: true))
        XCTAssertFalse(store.isModelExportable(baseModel: "Grok 4.6", providerId: "opencode", connectionID: nil, isConsolidated: true))

        // Codex -wm normalization tests
        XCTAssertEqual(GatewayStore.normalizedModelLookupKey("gpt-5.6-sol-wm"), "gpt-5.6-sol")
        XCTAssertEqual(GatewayStore.normalizedModelLookupKey("openai/gpt-5.6-sol-wm@Seven-X-openai-037708e3"), "gpt-5.6-sol")
        XCTAssertEqual(GatewayStore.normalizedModelLookupKey("OpenAI · gpt-5.6-sol"), "gpt-5.6-sol")

        let codexHealthy = GatewayModelHealthItem(id: "gpt-5.6-sol-wm", scopedId: "openai/gpt-5.6-sol-wm@Seven-X-openai-037708e3", status: "available", reason: nil, latencyMs: 5500, checkedAt: 12345, retries: 0, exported: true)
        let codexError = GatewayModelHealthItem(id: "gpt-5.6-terra-wm", scopedId: "openai/gpt-5.6-terra-wm@Seven-X-openai-037708e3", status: "error", reason: "SSE error", latencyMs: 3500, checkedAt: 12345, retries: 1, exported: false)
        let codexAccountHealth = GatewayAccountHealth(
            provider: "openai",
            providerName: "OpenAI",
            connectionId: "037708E3-A0EF-4B53-9D6C-A79BDA74ACFC",
            slug: "Seven-X-openai-037708e3",
            label: "Seven X",
            checkedAt: 12345,
            summary: GatewayModelHealthSummary(total: 2, available: 1, unavailable: 0, error: 1),
            models: [codexHealthy, codexError]
        )
        store.modelHealthResponse = GatewayModelHealthResponse(
            lastFullCheckAt: 12345,
            summary: GatewayModelHealthSummary(total: 5, available: 2, unavailable: 1, error: 2),
            accounts: [accountHealth, codexAccountHealth],
            job: nil
        )
        XCTAssertTrue(store.isModelExportable(baseModel: "gpt-5.6-sol", providerId: "openai", connectionID: nil, isConsolidated: true))
        XCTAssertFalse(store.isModelExportable(baseModel: "gpt-5.6-terra", providerId: "openai", connectionID: nil, isConsolidated: true))

        // Persistence test: persist and reload
        let resp = store.modelHealthResponse!
        store.persistModelHealth(resp)
        store.modelHealthResponse = nil
        store.loadCachedModelHealth()
        XCTAssertNotNil(store.modelHealthResponse)
        XCTAssertEqual(store.modelHealthResponse?.accounts.first?.models.count, 3)
    }

    func testGatewayAutomationTasksStorageAndStoreCRUD() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gateway-automation-tasks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let settingsURL = tempDir.appendingPathComponent("gateway-settings.json")
        let storage = GatewaySettingsStorage(fileURL: settingsURL)
        let store = GatewayStore(settingsStorage: storage)

        XCTAssertTrue(store.automationTasks.isEmpty)

        // 1. Add task
        let task1 = GatewayAutomationTask(
            name: "Codex 每日三检",
            taskType: .modelHealthCheck,
            enabled: true,
            providers: ["openai"],
            allAccounts: true,
            accountIds: [],
            hours: [8, 14, 21]
        )
        store.addAutomationTask(task1)
        XCTAssertEqual(store.automationTasks.count, 1)
        XCTAssertEqual(store.automationTasks.first?.name, "Codex 每日三检")
        XCTAssertEqual(store.automationTasks.first?.hours, [8, 14, 21])
        XCTAssertEqual(store.automationTasks.first?.hoursDescription, "08:00, 14:00, 21:00")

        // 2. Verify disk persistence
        let reloadedSettings = storage.load()
        XCTAssertEqual(reloadedSettings.automationTasks.count, 1)
        XCTAssertEqual(reloadedSettings.automationTasks.first?.id, task1.id)

        // 3. Toggle task
        store.toggleAutomationTask(id: task1.id)
        XCTAssertFalse(store.automationTasks.first!.enabled)

        // 4. Update task
        var modified = task1
        modified.name = "Codex 每日两检"
        modified.hours = [9, 18]
        store.updateAutomationTask(modified)
        XCTAssertEqual(store.automationTasks.first?.name, "Codex 每日两检")
        XCTAssertEqual(store.automationTasks.first?.hours, [9, 18])

        // 5. Delete task
        store.deleteAutomationTask(id: task1.id)
        XCTAssertTrue(store.automationTasks.isEmpty)
        let finalReload = storage.load()
        XCTAssertTrue(finalReload.automationTasks.isEmpty)
    }

    /// 定时触发的执行日志由网关进程写入同一个 settings 文件，
    /// App 侧的任意一次落盘、以及重新打开日志弹窗的读盘，都不能把记录丢掉。
    func testAutomationRunLogsSurviveGatewayAndStoreWrites() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gateway-automation-runlogs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let settingsURL = tempDir.appendingPathComponent("gateway-settings.json")
        let storage = GatewaySettingsStorage(fileURL: settingsURL)
        let store = GatewayStore(settingsStorage: storage)

        let task = GatewayAutomationTask(name: "5小时额度对齐巡检", hours: [5, 10, 15, 20])
        store.addAutomationTask(task)

        // 1. 网关进程在 20 点那次定时触发后写入的记录与运行态
        let gatewayLog = GatewayAutomationRunLog(
            id: "\(task.id)-1789030000",
            taskId: task.id,
            taskName: task.name,
            startedAt: 1789030000,
            finishedAt: 1789030120,
            isSuccess: true,
            summary: "可用 60 · 异常 4"
        )
        try simulateGatewaySettingsWrite(
            at: settingsURL,
            runLogs: [gatewayLog],
            taskLastRunAt: 1789030000,
            taskLastRunSummary: "可用 60 · 异常 4"
        )

        // 2. App 侧一次普通设置改动不应覆盖掉网关写入的内容
        store.allowLanAccess = true
        let afterStoreSave = storage.load()
        XCTAssertEqual(afterStoreSave.automationRunLogs.map(\.id), [gatewayLog.id])
        XCTAssertEqual(afterStoreSave.automationTasks.first?.lastRunAt, 1789030000)
        XCTAssertEqual(afterStoreSave.automationTasks.first?.lastRunSummary, "可用 60 · 异常 4")

        // 3. 打开执行日志弹窗时的读盘同步
        store.reloadAutomationStateFromDisk()
        XCTAssertEqual(store.gatewaySettings.automationRunLogs.map(\.id), [gatewayLog.id])
        XCTAssertEqual(store.automationTasks.first?.lastRunAt, 1789030000)

        // 4. App 手动“立即运行一次”的记录与网关记录共存
        store.recordAutomationRunStart(
            taskId: task.id,
            taskName: task.name,
            taskType: .modelHealthCheck,
            startedAt: 1789030500
        )
        let afterManualRun = storage.load()
        XCTAssertEqual(afterManualRun.automationRunLogs.count, 2)
        XCTAssertTrue(afterManualRun.automationRunLogs.contains { $0.id == gatewayLog.id })
        XCTAssertTrue(afterManualRun.automationRunLogs.contains { $0.startedAt == 1789030500 })
    }

    /// 执行日志的模型探测明细结果必须能够落盘并完整读回。
    func testAutomationRunLogsModelResultsPersistence() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gateway-automation-results-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let settingsURL = tempDir.appendingPathComponent("gateway-settings.json")
        let storage = GatewaySettingsStorage(fileURL: settingsURL)
        let store = GatewayStore(settingsStorage: storage)

        let task = GatewayAutomationTask(name: "健康巡检测试", hours: [5])
        store.addAutomationTask(task)

        let probeResults = [
            GatewayModelCheckResult(scopedId: "openai/gpt-4o@acc1", status: "available", reason: nil, latencyMs: 320),
            GatewayModelCheckResult(scopedId: "anthropic/claude-3-5-sonnet@acc2", status: "unavailable", reason: "404 Not Found", latencyMs: 150)
        ]

        store.recordAutomationRunStart(taskId: task.id, taskName: task.name, taskType: .modelHealthCheck, startedAt: 1789030000)
        store.finishAutomationRun(taskId: task.id, finishedAt: 1789030100, isSuccess: true, summary: "可用 1 · 异常 1", results: probeResults)

        // 落盘验证
        let loaded = storage.load()
        let log = try XCTUnwrap(loaded.automationRunLogs.first)
        XCTAssertEqual(log.results?.count, 2)
        XCTAssertEqual(log.results?[0].scopedId, "openai/gpt-4o@acc1")
        XCTAssertEqual(log.results?[0].status, "available")
        XCTAssertEqual(log.results?[1].scopedId, "anthropic/claude-3-5-sonnet@acc2")
        XCTAssertEqual(log.results?[1].reason, "404 Not Found")
    }

    /// 取消巡检后，这次巡检的执行日志必须收尾为「已取消」，并且要能落盘再读回来。
    ///
    /// 复现的 bug：`cancelModelCheck` 曾把本地 `isModelCheckRunning` 提前置为 false，
    /// 收尾逻辑（写 finishedAt / 更新任务状态）被整段跳过，日志永远停在「进行中」。
    func testCancelledModelCheckSettlesRunLogAsCancelled() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gateway-cancelled-runlog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let settingsURL = tempDir.appendingPathComponent("gateway-settings.json")
        let storage = GatewaySettingsStorage(fileURL: settingsURL)
        let store = GatewayStore(settingsStorage: storage)

        let task = GatewayAutomationTask(name: "5小时额度对齐巡检", hours: [5, 10, 15, 20])
        store.addAutomationTask(task)

        // 手动「立即运行一次」：先写入进行中的任务态与一条没有结束时间的记录
        let startedAt = Int64(Date().timeIntervalSince1970) - 30
        store.recordAutomationRunStart(
            taskId: task.id,
            taskName: task.name,
            taskType: .modelHealthCheck,
            startedAt: startedAt
        )
        let taskIdx = try XCTUnwrap(store.gatewaySettings.automationTasks.firstIndex { $0.id == task.id })
        store.gatewaySettings.automationTasks[taskIdx].lastRunStatus = "running"

        let running = try XCTUnwrap(store.gatewaySettings.automationRunLogs.first)
        XCTAssertTrue(running.isUnfinished)
        XCTAssertEqual(running.outcome, .running)
        XCTAssertEqual(running.outcome.label, "进行中")

        // 用户点了「取消巡检」
        let marked = store.markUnfinishedAutomationRunsCancelled(summary: "已取消 · 可用 9 · 异常 83")
        XCTAssertEqual(marked, 1)

        let cancelled = try XCTUnwrap(store.gatewaySettings.automationRunLogs.first)
        XCTAssertFalse(cancelled.isUnfinished, "取消后必须写入结束时点，否则执行日志永远停在「进行中」")
        XCTAssertEqual(cancelled.outcome, .cancelled)
        XCTAssertEqual(cancelled.outcome.label, "已取消")
        XCTAssertEqual(cancelled.cancelled, true)
        XCTAssertEqual(cancelled.isSuccess, false)
        XCTAssertEqual(cancelled.summary, "已取消 · 可用 9 · 异常 83")
        XCTAssertEqual(store.automationTasks.first?.lastRunStatus, "cancelled")

        // 落盘 → 读回：`cancelled` 必须能穿过 App 的 settings 读写
        store.allowLanAccess = true
        let reloaded = storage.load()
        XCTAssertEqual(reloaded.automationRunLogs.first?.cancelled, true)
        XCTAssertEqual(reloaded.automationRunLogs.first?.outcome, .cancelled)
        XCTAssertEqual(reloaded.automationRunLogs.first?.finishedAt, cancelled.finishedAt)

        // 新的 GatewayStore 冷启动读盘后，旧记录仍应是「已取消」而不是「进行中」
        let reopened = GatewayStore(settingsStorage: storage)
        reopened.reloadAutomationStateFromDisk()
        XCTAssertEqual(reopened.gatewaySettings.automationRunLogs.first?.outcome, .cancelled)
    }

    /// 网关从「运行中」切到空闲时，App 必须收尾这次巡检并按摘要里的 cancelled 记为「已取消」。
    ///
    /// 旧逻辑只按 `available > 0` 判断结果，被取消的巡检（可用 > 0）会被错记成「成功」。
    func testModelCheckIdleAfterCancelSettlesRunLogAsCancelled() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gateway-idle-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let settingsURL = tempDir.appendingPathComponent("gateway-settings.json")
        let store = GatewayStore(settingsStorage: GatewaySettingsStorage(fileURL: settingsURL))

        let task = GatewayAutomationTask(name: "账号模型健康巡检", hours: [9])
        store.addAutomationTask(task)
        store.recordAutomationRunStart(
            taskId: task.id,
            taskName: task.name,
            taskType: .modelHealthCheck,
            startedAt: Int64(Date().timeIntervalSince1970) - 30
        )
        let taskIdx = try XCTUnwrap(store.gatewaySettings.automationTasks.firstIndex { $0.id == task.id })
        store.gatewaySettings.automationTasks[taskIdx].lastRunStatus = "running"

        // App 认为巡检在跑，网关随后上报空闲 + 被取消的摘要
        store.isModelCheckRunning = true
        store.updateModelCheckJobStatus(from: [
            "running": false,
            "scope": "all",
            "done": 92,
            "total": 154,
            "current": "",
            "startedAt": Int64(Date().timeIntervalSince1970) - 30,
            "lastFinishedAt": Int64(Date().timeIntervalSince1970),
            "lastSummary": [
                "total": 154, "available": 9, "unavailable": 0,
                "error": 83, "unchecked": 0, "skipped": 62, "cancelled": true,
            ],
        ])

        XCTAssertFalse(store.isModelCheckRunning)
        let log = try XCTUnwrap(store.gatewaySettings.automationRunLogs.first)
        XCTAssertEqual(log.outcome, .cancelled, "取消的巡检不能被记成成功/失败")
        XCTAssertNotNil(log.finishedAt)
        XCTAssertEqual(log.summary, "已取消 · 可用 9 · 异常 83")
        XCTAssertEqual(store.automationTasks.first?.lastRunStatus, "cancelled")
        XCTAssertEqual(store.automationTasks.first?.lastRunSummary, "已取消 · 可用 9 · 异常 83")
    }

    /// 正常跑完的巡检仍要记为「成功」，不能被取消逻辑误伤。
    func testModelCheckIdleWithoutCancelSettlesRunLogAsSuccess() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gateway-idle-success-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let settingsURL = tempDir.appendingPathComponent("gateway-settings.json")
        let store = GatewayStore(settingsStorage: GatewaySettingsStorage(fileURL: settingsURL))

        let task = GatewayAutomationTask(name: "账号模型健康巡检", hours: [9])
        store.addAutomationTask(task)
        store.recordAutomationRunStart(
            taskId: task.id,
            taskName: task.name,
            taskType: .modelHealthCheck,
            startedAt: Int64(Date().timeIntervalSince1970) - 30
        )
        let taskIdx = try XCTUnwrap(store.gatewaySettings.automationTasks.firstIndex { $0.id == task.id })
        store.gatewaySettings.automationTasks[taskIdx].lastRunStatus = "running"

        store.isModelCheckRunning = true
        store.updateModelCheckJobStatus(from: [
            "running": false,
            "scope": "all",
            "done": 154,
            "total": 154,
            "current": "",
            "startedAt": Int64(Date().timeIntervalSince1970) - 30,
            "lastFinishedAt": Int64(Date().timeIntervalSince1970),
            "lastSummary": [
                "total": 154, "available": 60, "unavailable": 0,
                "error": 4, "unchecked": 0, "skipped": 90, "cancelled": false,
            ],
        ])

        let log = try XCTUnwrap(store.gatewaySettings.automationRunLogs.first)
        XCTAssertEqual(log.outcome, .success)
        XCTAssertNotNil(log.finishedAt)
        XCTAssertEqual(log.cancelled, nil)
        XCTAssertEqual(log.summary, "可用 60 · 异常 4")
        XCTAssertEqual(store.automationTasks.first?.lastRunStatus, "success")
    }

    /// 网关空闲但记录仍停在「进行中」（App 被杀、推送丢失等历史遗留）要能自动收尾。
    func testStaleUnfinishedRunLogIsRepairedWhenGatewayIsIdle() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gateway-stale-runlog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let settingsURL = tempDir.appendingPathComponent("gateway-settings.json")
        let storage = GatewaySettingsStorage(fileURL: settingsURL)
        let store = GatewayStore(settingsStorage: storage)

        let task = GatewayAutomationTask(name: "5小时额度对齐巡检", hours: [5, 10, 15, 20])
        store.addAutomationTask(task)

        // 一条两小时前开始、永远没有结束时间的遗留记录
        let staleStart = Int64(Date().timeIntervalSince1970) - 7200
        store.recordAutomationRunStart(
            taskId: task.id, taskName: task.name, taskType: .modelHealthCheck, startedAt: staleStart
        )
        XCTAssertEqual(store.gatewaySettings.automationRunLogs.first?.outcome, .running)

        // 网关空闲上报：宽限期已过，遗留记录按「已取消」收尾
        store.updateModelCheckJobStatus(from: [
            "running": false,
            "scope": "all",
            "done": 0,
            "total": 0,
            "current": "",
            "startedAt": staleStart,
        ])

        let log = try XCTUnwrap(store.gatewaySettings.automationRunLogs.first)
        XCTAssertEqual(log.outcome, .cancelled)
        let finishedAt = try XCTUnwrap(log.finishedAt)
        XCTAssertGreaterThanOrEqual(finishedAt, staleStart, "结束时间不能早于开始时间")
    }

    /// 刚发起、网关还没来得及上报 running 的巡检，不能被宽限期内的清理误判为「已取消」。
    func testFreshUnfinishedRunLogIsNotSweptByStaleRepair() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gateway-fresh-runlog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let settingsURL = tempDir.appendingPathComponent("gateway-settings.json")
        let store = GatewayStore(settingsStorage: GatewaySettingsStorage(fileURL: settingsURL))

        let task = GatewayAutomationTask(name: "账号模型健康巡检", hours: [9])
        store.addAutomationTask(task)
        store.recordAutomationRunStart(
            taskId: task.id,
            taskName: task.name,
            taskType: .modelHealthCheck,
            startedAt: Int64(Date().timeIntervalSince1970)
        )

        store.updateModelCheckJobStatus(from: [
            "running": false,
            "scope": "all",
            "done": 0,
            "total": 0,
            "current": "",
            "startedAt": Int64(Date().timeIntervalSince1970),
        ])

        XCTAssertEqual(store.gatewaySettings.automationRunLogs.first?.outcome, .running)
        XCTAssertTrue(store.gatewaySettings.automationRunLogs.first?.isUnfinished == true)
    }

    /// 模拟网关进程（Rust）直接改写 settings 文件：追加执行日志并更新任务运行态。
    private func simulateGatewaySettingsWrite(
        at url: URL,
        runLogs: [GatewayAutomationRunLog],
        taskLastRunAt: Int64,
        taskLastRunSummary: String
    ) throws {
        let data = try Data(contentsOf: url)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let encodedLogs = try JSONEncoder().encode(runLogs)
        json["automationRunLogs"] = try JSONSerialization.jsonObject(with: encodedLogs)

        if var tasks = json["automationTasks"] as? [[String: Any]] {
            for idx in tasks.indices {
                tasks[idx]["lastRunAt"] = taskLastRunAt
                tasks[idx]["lastRunStatus"] = "success"
                tasks[idx]["lastRunSummary"] = taskLastRunSummary
            }
            json["automationTasks"] = tasks
        }

        let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: url)
    }

    func testDynamicHermesAndPiExecutableResolution() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dynamic-agent-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Initialize runner BEFORE binary exists
        let runner = HermesCLICommandRunner(homeDirectory: tempDir, environment: [:], allowShellFallback: false)
        XCTAssertNil(runner.executableURL)
        XCTAssertFalse(runner.isAvailable)

        let piRunner = PiCLICommandRunner(homeDirectory: tempDir, environment: [:], allowShellFallback: false)
        XCTAssertNil(piRunner.executableURL)
        XCTAssertFalse(piRunner.isAvailable)

        // Simulate user installing hermes and pi CLI in ~/.local/bin
        let localBin = tempDir.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true)

        let hermesBin = localBin.appendingPathComponent("hermes")
        try "#!/bin/sh\necho 0.1.0\n".write(to: hermesBin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hermesBin.path)

        let piBin = localBin.appendingPathComponent("pi")
        try "#!/bin/sh\necho 0.1.0\n".write(to: piBin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: piBin.path)

        // Runner should dynamically detect new executables without being recreated
        XCTAssertEqual(runner.executableURL?.standardized.path, hermesBin.standardized.path)
        XCTAssertTrue(runner.isAvailable)

        XCTAssertEqual(piRunner.executableURL?.standardized.path, piBin.standardized.path)
        XCTAssertTrue(piRunner.isAvailable)
    }

    func testAgentIntegrationStatusNotificationPostedAndReceived() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-notification-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let settingsURL = tempDir.appendingPathComponent("gateway-settings.json")
        let storage = GatewaySettingsStorage(fileURL: settingsURL)
        let store = GatewayStore(settingsStorage: storage)

        let expectation = expectation(description: "agentIntegrationStatusDidChange notification received")
        let observer = NotificationCenter.default.addObserver(
            forName: .agentIntegrationStatusDidChange,
            object: nil,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        await store.refreshAgentIntegrationStatus(notifyPeers: true)

        await fulfillment(of: [expectation], timeout: 2.0)
    }

    func testHermesLanBypassConfigureAndUnconfigure() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-bypass-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configURL = tempDir.appendingPathComponent(".hermes/config.yaml")
        let envURL = tempDir.appendingPathComponent(".hermes/.env")
        let runner = TestHermesCommandRunner()
        let configurator = HermesGatewayConfigurator(runner: runner, configURL: configURL, envURL: envURL)

        XCTAssertFalse(configurator.isLanBypassConfigured)

        // 1. Configure bypass
        try configurator.configureLanBypass()
        XCTAssertTrue(configurator.isLanBypassConfigured)
        let writtenContent = try String(contentsOf: envURL, encoding: .utf8)
        XCTAssertTrue(writtenContent.contains("# 局域网内不走代理"))
        XCTAssertTrue(writtenContent.contains("NO_PROXY=127.0.0.1,localhost,192.168.0.0/16,10.0.0.0/8"))
        XCTAssertTrue(writtenContent.contains("no_proxy=127.0.0.1,localhost,192.168.0.0/16,10.0.0.0/8"))

        // Idempotent configure
        try configurator.configureLanBypass()
        XCTAssertTrue(configurator.isLanBypassConfigured)

        // 2. Unconfigure bypass
        try configurator.unconfigureLanBypass()
        XCTAssertFalse(configurator.isLanBypassConfigured)
        let unconfiguredContent = try String(contentsOf: envURL, encoding: .utf8)
        XCTAssertFalse(unconfiguredContent.contains("NO_PROXY"))
        XCTAssertFalse(unconfiguredContent.contains("192.168.0.0/16"))
    }

    func testGatewaySettingsSecureTokenGenerationAndMigration() throws {
        // 1. Generation format
        let token1 = GatewaySettings.generateSecureToken()
        let token2 = GatewaySettings.generateSecureToken()
        XCTAssertTrue(token1.hasPrefix("cdx_"))
        XCTAssertEqual(token1.count, 36)
        XCTAssertNotEqual(token1, token2)

        // 2. Migration from legacy tomo-local-token
        let legacyJSON = Data(#"{"$schemaVersion": 2, "authToken": "tomo-local-token"}"#.utf8)
        let decoded = try JSONDecoder().decode(GatewaySettings.self, from: legacyJSON)
        XCTAssertTrue(decoded.authToken.hasPrefix("cdx_"))
        XCTAssertNotEqual(decoded.authToken, "tomo-local-token")

        // 3. Preservation of existing cdx_ token
        let existingJSON = Data(#"{"$schemaVersion": 2, "authToken": "cdx_custom_valid_1234567890abcdef"}"#.utf8)
        let preserved = try JSONDecoder().decode(GatewaySettings.self, from: existingJSON)
        XCTAssertEqual(preserved.authToken, "cdx_custom_valid_1234567890abcdef")
    }

    func testHermesUpdateApiKey() throws {
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-key-\(UUID().uuidString).yaml")
        defer { try? FileManager.default.removeItem(at: configURL) }

        let runner = TestHermesCommandRunner()
        let configurator = HermesGatewayConfigurator(runner: runner, configURL: configURL)

        // Configure first
        try configurator.configure(
            baseURL: "http://127.0.0.1:58349/v1",
            apiKey: "cdx_initial_token",
            models: ["deepseek-chat"],
            defaultModel: "deepseek-chat"
        )
        XCTAssertTrue(configurator.isConfigured)

        // Now update API key
        try configurator.updateApiKey("cdx_new_token_999")
        XCTAssertEqual(runner.values["providers.tomo.api_key"], "cdx_new_token_999")
        XCTAssertEqual(runner.values["model.default"], "deepseek-chat") // preserved
    }

    func testPiUpdateApiKey() throws {
        let agentDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: agentDirectory) }

        let runner = TestPiCommandRunner(discoveredModel: "deepseek-chat")
        let configurator = PiGatewayConfigurator(runner: runner, agentDirectory: agentDirectory)

        // Configure first
        try configurator.configure(
            baseURL: "http://127.0.0.1:58349/v1",
            apiKey: "cdx_initial_pi_token",
            models: ["deepseek-chat"],
            defaultModel: "deepseek-chat"
        )
        XCTAssertTrue(configurator.isConfigured)

        // Now update API key
        try configurator.updateApiKey("cdx_new_pi_token_888")

        let modelsURL = agentDirectory.appendingPathComponent("models.json")
        let modelsRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: modelsURL)) as? [String: Any]
        )
        let providers = try XCTUnwrap(modelsRoot["providers"] as? [String: Any])
        let tomo = try XCTUnwrap(providers["tomo"] as? [String: Any])
        XCTAssertEqual(tomo["apiKey"] as? String, "cdx_new_pi_token_888")
    }

    func testGatewayStoreRotateAuthToken() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-rotate-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let settingsURL = tempDir.appendingPathComponent("gateway-settings.json")
        let storage = GatewaySettingsStorage(fileURL: settingsURL)
        let store = GatewayStore(settingsStorage: storage)

        let initialToken = store.localToken
        XCTAssertTrue(initialToken.hasPrefix("cdx_"))

        let result = await store.rotateAuthToken()
        XCTAssertTrue(result.success, "rotateAuthToken 失败：\(result.message)")
        XCTAssertNotEqual(store.localToken, initialToken)
        XCTAssertTrue(store.localToken.hasPrefix("cdx_"))
        XCTAssertEqual(GatewaySupervisor.shared.localToken, store.localToken)
    }

    // MARK: - DSH (DeepSeek Harness) 一键接入

    /// A realistic pre-integration `settings.yaml`: unrelated top-level
    /// sections, comments and an empty dormant `llm-pi-ai` section.
    private static let dshSettingsFixture = """
    ui-onboarding:
      welcomeNoticeVersion: 2026-08-13.1
    agent-default-model:
      provider: deepseek-official
      model: deepseek-v4-flash-vision-exp
      reasoningEffort: high
    ui-theme:
      preference: system # keep me
    llm-pi-ai:
      providers: {}
    """

    private static let dshCredentialsFixture = """
    version: 1

    refs:
      DEEPSEEK_API_KEY: dummy-deepseek-value

    records:
      llm-pi-ai/openai-codex:
        kind: api-key
        key: dummy-record-value
    """

    private func makeDSHDocuments(
        settings: String? = GatewayTests.dshSettingsFixture,
        credentials: String? = GatewayTests.dshCredentialsFixture
    ) throws -> (directory: URL, settingsURL: URL, credentialsURL: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settingsURL = directory.appendingPathComponent("settings.yaml")
        let credentialsURL = directory.appendingPathComponent(".credentials.yaml")
        if let settings {
            try Data(settings.utf8).write(to: settingsURL)
        }
        if let credentials {
            try Data(credentials.utf8).write(to: credentialsURL)
        }
        return (directory, settingsURL, credentialsURL)
    }

    private func dshModels(_ ids: [String] = ["openai/gpt-5-6", "deepseek/deepseek-v4-pro"]) -> [DSHModel] {
        ids.map { id in
            let cap = ModelCapabilityRegistry.resolveCapability(for: id, override: nil)
            return DSHModel(
                id: id,
                name: id,
                contextWindow: cap.contextWindow,
                maxTokens: cap.maxTokens,
                input: DSHModelModality.input(supportsImage: cap.supportsImage),
                reasoning: DSHModelReasoning.from(levels: cap.reasoningLevels)
            )
        }
    }

    func testDSHGatewayConfigurationWritesRouteAndCredentialDocuments() throws {
        let docs = try makeDSHDocuments()
        defer { try? FileManager.default.removeItem(at: docs.directory) }

        let configurator = DSHGatewayConfigurator(
            settingsURL: docs.settingsURL,
            credentialsURL: docs.credentialsURL,
            environment: [:]
        )
        XCTAssertTrue(configurator.isDSHInstalled)
        XCTAssertFalse(configurator.isConfigured)

        try configurator.configure(
            baseURL: "http://127.0.0.1:58349/v1",
            apiKey: "cdx_testtoken",
            models: dshModels(),
            setAsAgentDefaultModel: false
        )

        XCTAssertTrue(configurator.isConfigured)
        let state = configurator.state
        XCTAssertEqual(state.baseURL, "http://127.0.0.1:58349/v1")
        XCTAssertEqual(state.apiKeyEnv, DSHGatewayConfigurator.credentialRef)
        XCTAssertEqual(state.modelIDs, ["openai/gpt-5-6", "deepseek/deepseek-v4-pro"])
        XCTAssertTrue(state.credentialPresent)

        let settings = try String(contentsOf: docs.settingsURL, encoding: .utf8)
        XCTAssertTrue(settings.contains("tomo:"))
        XCTAssertTrue(settings.contains("api: openai-completions"))
        XCTAssertTrue(settings.contains("X-Agent-Name: DSH"))

        let credentials = try String(contentsOf: docs.credentialsURL, encoding: .utf8)
        XCTAssertTrue(credentials.contains("TOMO_GATEWAY_TOKEN: cdx_testtoken"))

        // The credential provider refuses to parse a document any other user
        // can read, so the mode is part of the contract.
        let attributes = try FileManager.default.attributesOfItem(atPath: docs.credentialsURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testDSHGatewayConfigurationPreservesUnrelatedKeysCommentsAndSiblingRoutes() throws {
        // A sibling route written by the DSH Models page must survive both
        // directions; only the Tomo span may ever change.
        let settingsWithSibling = Self.dshSettingsFixture.replacingOccurrences(
            of: "  providers: {}",
            with: """
              providers:
                someone-elses-route:
                  api: openai-completions
                  baseURL: https://example.invalid/v1
                  models:
                    - id: their-model
            """
        )
        let docs = try makeDSHDocuments(settings: settingsWithSibling)
        defer { try? FileManager.default.removeItem(at: docs.directory) }

        let configurator = DSHGatewayConfigurator(
            settingsURL: docs.settingsURL,
            credentialsURL: docs.credentialsURL,
            environment: [:]
        )
        try configurator.configure(
            baseURL: "http://127.0.0.1:58349/v1",
            apiKey: "cdx_testtoken",
            models: dshModels(["openai/gpt-5-6"]),
            setAsAgentDefaultModel: false
        )

        var settings = try String(contentsOf: docs.settingsURL, encoding: .utf8)
        XCTAssertTrue(settings.contains("someone-elses-route:"))
        XCTAssertTrue(settings.contains("baseURL: https://example.invalid/v1"))
        XCTAssertTrue(settings.contains("- id: their-model"))
        // Untouched sections keep their exact bytes, comment included.
        XCTAssertTrue(settings.contains("preference: system # keep me"))
        XCTAssertTrue(settings.contains("welcomeNoticeVersion: 2026-08-13.1"))
        XCTAssertTrue(settings.contains("reasoningEffort: high"))

        try configurator.unconfigure()

        settings = try String(contentsOf: docs.settingsURL, encoding: .utf8)
        XCTAssertFalse(settings.contains("tomo:"))
        XCTAssertTrue(settings.contains("someone-elses-route:"))
        XCTAssertTrue(settings.contains("- id: their-model"))
        XCTAssertTrue(settings.contains("preference: system # keep me"))
        // The sibling route must keep the section alive rather than letting
        // the empty-section collapse delete it.
        XCTAssertTrue(settings.contains("llm-pi-ai:"))

        let credentials = try String(contentsOf: docs.credentialsURL, encoding: .utf8)
        XCTAssertFalse(credentials.contains(DSHGatewayConfigurator.credentialRef))
        XCTAssertTrue(credentials.contains("DEEPSEEK_API_KEY: dummy-deepseek-value"))
        XCTAssertTrue(credentials.contains("llm-pi-ai/openai-codex:"))
    }

    func testDSHGatewayConfigurationRollsBackWhenCredentialDocumentIsLegacy() throws {
        // A refusal after the settings document was already rewritten must
        // restore it byte for byte, never leave a half-applied route.
        let legacyCredentials = "DEEPSEEK_API_KEY: dummy-deepseek-value\n"
        let docs = try makeDSHDocuments(credentials: legacyCredentials)
        defer { try? FileManager.default.removeItem(at: docs.directory) }

        let originalSettings = try Data(contentsOf: docs.settingsURL)
        let configurator = DSHGatewayConfigurator(
            settingsURL: docs.settingsURL,
            credentialsURL: docs.credentialsURL,
            environment: [:]
        )

        XCTAssertThrowsError(
            try configurator.configure(
                baseURL: "http://127.0.0.1:58349/v1",
                apiKey: "cdx_testtoken",
                models: dshModels(),
                setAsAgentDefaultModel: false
            )
        ) { error in
            guard case DSHGatewayConfigurationError.legacyCredentialDocument = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: docs.settingsURL), originalSettings)
        XCTAssertEqual(
            try String(contentsOf: docs.credentialsURL, encoding: .utf8),
            legacyCredentials
        )
    }

    func testDSHGatewayConfigurationRejectsEmptyModelList() throws {
        let docs = try makeDSHDocuments()
        defer { try? FileManager.default.removeItem(at: docs.directory) }
        let configurator = DSHGatewayConfigurator(
            settingsURL: docs.settingsURL,
            credentialsURL: docs.credentialsURL,
            environment: [:]
        )

        XCTAssertThrowsError(
            try configurator.configure(
                baseURL: "http://127.0.0.1:58349/v1",
                apiKey: "cdx_testtoken",
                models: [],
                setAsAgentDefaultModel: false
            )
        ) { error in
            guard case DSHGatewayConfigurationError.noGatewayModel = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(configurator.isConfigured)
    }

    func testDSHRefreshModelsReplacesCatalogWholesale() throws {
        let docs = try makeDSHDocuments()
        defer { try? FileManager.default.removeItem(at: docs.directory) }
        let configurator = DSHGatewayConfigurator(
            settingsURL: docs.settingsURL,
            credentialsURL: docs.credentialsURL,
            environment: [:]
        )

        try configurator.configure(
            baseURL: "http://127.0.0.1:58349/v1",
            apiKey: "cdx_testtoken",
            models: dshModels(["openai/gpt-5-6", "opencode/glm-5.3-flash"]),
            setAsAgentDefaultModel: false
        )

        // A refresh rewrites the route span: the retired model must be gone,
        // not merely shadowed by a newer entry.
        let changed = try configurator.refreshModels(
            baseURL: "http://127.0.0.1:58349/v1",
            apiKey: "cdx_testtoken",
            models: dshModels(["openai/gpt-5-6", "google/gemini-2.5-pro"])
        )
        XCTAssertTrue(changed)
        XCTAssertEqual(configurator.state.modelIDs, ["openai/gpt-5-6", "google/gemini-2.5-pro"])

        let settings = try String(contentsOf: docs.settingsURL, encoding: .utf8)
        XCTAssertFalse(settings.contains("opencode/glm-5.3-flash"))

        // An unchanged catalog reports no change so the UI can say "已是最新".
        let changedAgain = try configurator.refreshModels(
            baseURL: "http://127.0.0.1:58349/v1",
            apiKey: "cdx_testtoken",
            models: dshModels(["openai/gpt-5-6", "google/gemini-2.5-pro"])
        )
        XCTAssertFalse(changedAgain)
    }

    func testDSHGatewaySetsAndClearsAgentDefaultModel() throws {
        let docs = try makeDSHDocuments()
        defer { try? FileManager.default.removeItem(at: docs.directory) }
        let configurator = DSHGatewayConfigurator(
            settingsURL: docs.settingsURL,
            credentialsURL: docs.credentialsURL,
            environment: [:]
        )

        try configurator.configure(
            baseURL: "http://127.0.0.1:58349/v1",
            apiKey: "cdx_testtoken",
            models: dshModels(["openai/gpt-5-6"]),
            setAsAgentDefaultModel: true
        )

        var settings = try String(contentsOf: docs.settingsURL, encoding: .utf8)
        XCTAssertTrue(settings.contains("provider: tomo"))
        XCTAssertTrue(settings.contains("model: openai/gpt-5-6"))
        // The pre-existing reasoning preference is not ours to erase.
        XCTAssertTrue(settings.contains("reasoningEffort: high"))

        try configurator.unconfigure()
        settings = try String(contentsOf: docs.settingsURL, encoding: .utf8)
        XCTAssertFalse(settings.contains("provider: tomo"))
        XCTAssertTrue(settings.contains("reasoningEffort: high"))
    }

    func testDSHCredentialShadowedByEnvironmentIsDetectedBeforeWriting() throws {
        let docs = try makeDSHDocuments()
        defer { try? FileManager.default.removeItem(at: docs.directory) }
        let configurator = DSHGatewayConfigurator(
            settingsURL: docs.settingsURL,
            credentialsURL: docs.credentialsURL,
            environment: [DSHGatewayConfigurator.credentialRef: "cdx_from_shell"]
        )

        XCTAssertTrue(configurator.isCredentialShadowedByEnvironment)

        // The environment wins over the managed document inside DSH, so a
        // write that would be silently shadowed has to fail loudly instead.
        XCTAssertThrowsError(
            try configurator.configure(
                baseURL: "http://127.0.0.1:58349/v1",
                apiKey: "cdx_testtoken",
                models: dshModels(),
                setAsAgentDefaultModel: false
            )
        ) { error in
            guard case DSHGatewayConfigurationError.verificationFailed(let key, _, _) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(key, DSHGatewayConfigurator.credentialRef)
        }
        XCTAssertFalse(configurator.isConfigured)
    }

    func testDSHModelModalityDeclaresImagesOnlyForVisionFamilies() {
        // A hand-declared route has no installed catalog entry, so an entry
        // that omits `input` is text-only and DSH refuses attachments in the
        // client with "当前模型不支持图片".
        let gemini = ModelCapabilityRegistry.resolveCapability(for: "google/gemini-3.8-flash-tiered", override: nil)
        let claude = ModelCapabilityRegistry.resolveCapability(for: "google/claude-sonnet-4-6", override: nil)
        let qwenVl = ModelCapabilityRegistry.resolveCapability(for: "opencode/qwen3-vl-235b", override: nil)
        XCTAssertEqual(DSHModelModality.input(supportsImage: gemini.supportsImage), ["text", "image"])
        XCTAssertEqual(DSHModelModality.input(supportsImage: claude.supportsImage), ["text", "image"])
        XCTAssertEqual(DSHModelModality.input(supportsImage: qwenVl.supportsImage), ["text", "image"])

        // Over-claiming is the expensive direction, so text-only families must
        // stay text-only.
        let deepseek = ModelCapabilityRegistry.resolveCapability(for: "deepseek/deepseek-v4-pro", override: nil)
        let kimi = ModelCapabilityRegistry.resolveCapability(for: "opencode/kimi-k2.5", override: nil)
        XCTAssertEqual(DSHModelModality.input(supportsImage: deepseek.supportsImage), ["text"])
        XCTAssertEqual(DSHModelModality.input(supportsImage: kimi.supportsImage), ["text"])
    }

    func testDSHConfigurationWritesInputModalitiesPerModel() throws {
        let docs = try makeDSHDocuments()
        defer { try? FileManager.default.removeItem(at: docs.directory) }
        let configurator = DSHGatewayConfigurator(
            settingsURL: docs.settingsURL,
            credentialsURL: docs.credentialsURL,
            environment: [:]
        )
        try configurator.configure(
            baseURL: "http://127.0.0.1:58349/v1",
            apiKey: "cdx_testtoken",
            models: dshModels(["google/gemini-3.8-flash-tiered", "deepseek/deepseek-v4-pro"]),
            setAsAgentDefaultModel: false
        )

        let settings = try String(contentsOf: docs.settingsURL, encoding: .utf8)
        XCTAssertTrue(settings.contains("input: [text, image]"))
        XCTAssertTrue(settings.contains("input: [text]"))
        // The modality list must not disturb the id scan used for refresh.
        XCTAssertEqual(
            configurator.state.modelIDs,
            ["google/gemini-3.8-flash-tiered", "deepseek/deepseek-v4-pro"]
        )

        // Refreshing rewrites the modality declaration with the catalog.
        try configurator.refreshModels(
            baseURL: "http://127.0.0.1:58349/v1",
            apiKey: "cdx_testtoken",
            models: dshModels(["deepseek/deepseek-v4-pro"])
        )
        let after = try String(contentsOf: docs.settingsURL, encoding: .utf8)
        XCTAssertFalse(after.contains("input: [text, image]"))
        XCTAssertEqual(configurator.state.modelIDs, ["deepseek/deepseek-v4-pro"])
    }

    func testDSHSettingsDocumentKeepsItsExistingMode() throws {
        let docs = try makeDSHDocuments()
        defer { try? FileManager.default.removeItem(at: docs.directory) }
        // The user had locked the settings document down; an atomic rewrite
        // must not quietly widen it back to the umask default.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: docs.settingsURL.path
        )
        let configurator = DSHGatewayConfigurator(
            settingsURL: docs.settingsURL,
            credentialsURL: docs.credentialsURL,
            environment: [:]
        )
        try configurator.configure(
            baseURL: "http://127.0.0.1:58349/v1",
            apiKey: "cdx_testtoken",
            models: dshModels(),
            setAsAgentDefaultModel: false
        )

        let settingsMode = (try FileManager.default.attributesOfItem(atPath: docs.settingsURL.path))[
            .posixPermissions
        ] as? NSNumber
        XCTAssertEqual(settingsMode?.intValue, 0o600)
        // The credential mode is a contract, not a preference.
        let credentialsMode = (try FileManager.default.attributesOfItem(atPath: docs.credentialsURL.path))[
            .posixPermissions
        ] as? NSNumber
        XCTAssertEqual(credentialsMode?.intValue, 0o600)
    }

    func testDSHModelReasoningOnlyClaimsLevelsTheGatewayHonours() {
        // Official profiles define the verified thinking levels.
        let gemini = ModelCapabilityRegistry.resolveCapability(for: "google/gemini-3.8-flash-tiered", override: nil)
        let efforts = DSHModelReasoning.from(levels: gemini.reasoningLevels)
        XCTAssertEqual(efforts.map(\.level), ["off", "low", "medium", "high"])
        // `off` sends nothing: the provider's own default stays in charge.
        XCTAssertNil(efforts.first?.wire)
        XCTAssertEqual(efforts.dropFirst().compactMap(\.wire), ["low", "medium", "high"])

        let claude = ModelCapabilityRegistry.resolveCapability(for: "google/claude-3-7-sonnet", override: nil)
        XCTAssertFalse(DSHModelReasoning.from(levels: claude.reasoningLevels).isEmpty)

        // Models without reasoning levels in official spec return empty
        let gpt4o = ModelCapabilityRegistry.resolveCapability(for: "openai/gpt-4o", override: nil)
        XCTAssertTrue(DSHModelReasoning.from(levels: gpt4o.reasoningLevels).isEmpty)
        let deepseek = ModelCapabilityRegistry.resolveCapability(for: "deepseek/deepseek-chat", override: nil)
        XCTAssertTrue(DSHModelReasoning.from(levels: deepseek.reasoningLevels).isEmpty)

        // User overrides take precedence
        let userCustom = GatewayModelCapabilityOverride(
            modelID: "custom/my-model",
            reasoningLevels: ["low", "high"],
            defaultReasoningLevel: "high"
        )
        let customResolved = ModelCapabilityRegistry.resolveCapability(for: "custom/my-model", override: userCustom)
        XCTAssertEqual(customResolved.reasoningLevels, ["low", "high"])
        XCTAssertEqual(customResolved.defaultReasoningLevel, "high")
    }

    func testDSHConfigurationWritesReasoningEfforts() throws {
        let docs = try makeDSHDocuments()
        defer { try? FileManager.default.removeItem(at: docs.directory) }
        let configurator = DSHGatewayConfigurator(
            settingsURL: docs.settingsURL,
            credentialsURL: docs.credentialsURL,
            environment: [:]
        )
        try configurator.configure(
            baseURL: "http://127.0.0.1:58349/v1",
            apiKey: "cdx_testtoken",
            models: dshModels(["google/gemini-3.8-flash-tiered", "deepseek/deepseek-chat"]),
            setAsAgentDefaultModel: false
        )

        var settings = try String(contentsOf: docs.settingsURL, encoding: .utf8)
        XCTAssertTrue(settings.contains("reasoningEfforts:"))
        // `off` must stay value-less; a value there would send it on the wire.
        XCTAssertTrue(settings.contains("\n            off:"))
        XCTAssertTrue(settings.contains("\n            high: high"))
        // Only the gemini entry declares it (deepseek-chat does not).
        XCTAssertEqual(settings.components(separatedBy: "reasoningEfforts:").count - 1, 1)
        XCTAssertEqual(configurator.state.modelIDs.count, 2)

        // Dropping the reasoning family removes the declaration with it.
        try configurator.refreshModels(
            baseURL: "http://127.0.0.1:58349/v1",
            apiKey: "cdx_testtoken",
            models: dshModels(["deepseek/deepseek-chat"])
        )
        settings = try String(contentsOf: docs.settingsURL, encoding: .utf8)
        XCTAssertFalse(settings.contains("reasoningEfforts:"))
    }

    func testDSHCatalogFingerprintCoversCapacityAndModalitiesNotJustIDs() {
        let textOnly = DSHModel(
            id: "google/gemini-2.5-pro", name: "gemini",
            contextWindow: 1_000_000, maxTokens: 65_536, input: ["text"], reasoning: []
        )
        // Same id, modality corrected: the automatic sync must see a change.
        let withImage = DSHModel(
            id: "google/gemini-2.5-pro", name: "gemini",
            contextWindow: 1_000_000, maxTokens: 65_536, input: ["text", "image"], reasoning: []
        )
        // Same id and modalities, capacity corrected: likewise.
        let resized = DSHModel(
            id: "google/gemini-2.5-pro", name: "gemini",
            contextWindow: 200_000, maxTokens: 32_000, input: ["text"], reasoning: []
        )
        XCTAssertNotEqual(
            GatewayStore.dshCatalogFingerprint([textOnly]),
            GatewayStore.dshCatalogFingerprint([withImage])
        )
        XCTAssertNotEqual(
            GatewayStore.dshCatalogFingerprint([textOnly]),
            GatewayStore.dshCatalogFingerprint([resized])
        )
        // A display-name change is cosmetic and must not trigger a rewrite.
        let renamed = DSHModel(
            id: "google/gemini-2.5-pro", name: "Google · gemini-2.5-pro",
            contextWindow: 1_000_000, maxTokens: 65_536, input: ["text"], reasoning: []
        )
        XCTAssertEqual(
            GatewayStore.dshCatalogFingerprint([textOnly]),
            GatewayStore.dshCatalogFingerprint([renamed])
        )
        // Catalog order is not a change.
        XCTAssertEqual(
            GatewayStore.dshCatalogFingerprint([textOnly, resized]),
            GatewayStore.dshCatalogFingerprint([resized, textOnly])
        )
    }

    func testDSHModelCapacityStaysConservative() {
        // Over-claiming a context window is the expensive direction, so every
        // table entry must stay at or below the published model card.
        let gemini = DSHModelCapacity.resolve(modelID: "google/gemini-2.5-pro")
        XCTAssertEqual(gemini.contextWindow, 1_048_576)
        XCTAssertLessThanOrEqual(gemini.maxTokens, 65_536)

        let unknown = DSHModelCapacity.resolve(modelID: "opencode/some-new-model")
        XCTAssertEqual(unknown.contextWindow, DSHModelCapacity.fallbackContextWindow)
        XCTAssertEqual(unknown.maxTokens, DSHModelCapacity.fallbackMaxTokens)
        // Never the adapter's own larger default.
        XCTAssertLessThan(unknown.contextWindow, 262_144)
        XCTAssertLessThan(unknown.maxTokens, 32_768)
    }

    func testDSHConfigurationRoundTripsQuotedScalars() throws {
        let docs = try makeDSHDocuments()
        defer { try? FileManager.default.removeItem(at: docs.directory) }
        let configurator = DSHGatewayConfigurator(
            settingsURL: docs.settingsURL,
            credentialsURL: docs.credentialsURL,
            environment: [:]
        )
        // A display name with YAML-significant characters must survive the
        // write/read cycle unchanged.
        let model = DSHModel(
            id: "openai/gpt-5-6",
            name: "OpenAI · gpt-5-6 (整合 3 账号) # not-a-comment",
            contextWindow: 272_000,
            maxTokens: 32_768,
            input: DSHModelModality.textOnly,
            reasoning: []
        )
        try configurator.configure(
            baseURL: "http://127.0.0.1:58349/v1",
            apiKey: "cdx_testtoken",
            models: [model],
            setAsAgentDefaultModel: false
        )

        let settings = try String(contentsOf: docs.settingsURL, encoding: .utf8)
        XCTAssertTrue(settings.contains("not-a-comment"))
        XCTAssertEqual(configurator.state.modelIDs, ["openai/gpt-5-6"])
        XCTAssertTrue(configurator.isConfigured)
    }

    func testDSHCredentialRemovalCollapsesEmptyRefsMap() throws {
        // The only reference in the document is ours, so removing it must leave
        // an explicit empty mapping: a bare `refs:` parses as null, which the
        // credential document rejects.
        let docs = try makeDSHDocuments(
            credentials: "version: 1\n\nrefs:\n  # Tomo gateway\n  TOMO_GATEWAY_TOKEN: cdx_seed\n"
        )
        defer { try? FileManager.default.removeItem(at: docs.directory) }

        let configurator = DSHGatewayConfigurator(
            settingsURL: docs.settingsURL,
            credentialsURL: docs.credentialsURL,
            environment: [:]
        )
        try configurator.unconfigure()

        let credentials = try String(contentsOf: docs.credentialsURL, encoding: .utf8)
        XCTAssertTrue(credentials.contains("refs: {}"))
        XCTAssertFalse(credentials.contains("Tomo gateway"))
        XCTAssertTrue(credentials.contains("version: 1"))
    }

    func testDSHStoreRefreshesAndUnconfiguresInjectedDocuments() async throws {
        let docs = try makeDSHDocuments(credentials: "version: 1\n\nrefs:\n  DEEPSEEK_API_KEY: dummy\n")
        defer { try? FileManager.default.removeItem(at: docs.directory) }

        let configurator = DSHGatewayConfigurator(
            settingsURL: docs.settingsURL,
            credentialsURL: docs.credentialsURL,
            environment: [:]
        )
        try configurator.configure(
            baseURL: "http://127.0.0.1:58349/v1",
            apiKey: "cdx_testtoken",
            models: dshModels(["openai/gpt-5-6"]),
            setAsAgentDefaultModel: false
        )

        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-dsh-\(UUID().uuidString)/gateway-settings.json")
        let store = GatewayStore(
            dshConfigurator: configurator,
            settingsStorage: GatewaySettingsStorage(fileURL: settingsURL)
        )
        defer { try? FileManager.default.removeItem(at: settingsURL.deletingLastPathComponent()) }

        // Detection runs off the main actor but must land on the store.
        await store.refreshAgentIntegrationStatus()
        XCTAssertTrue(store.hasLoadedAgentIntegrationStatus)
        XCTAssertTrue(store.dshAgentInstalled)
        XCTAssertTrue(store.dshAgentConfigured)
        XCTAssertFalse(store.dshCredentialShadowed)

        let result = await store.unconfigureDSHAgent()
        XCTAssertTrue(result.success)
        XCTAssertFalse(store.dshAgentConfigured)
        XCTAssertFalse(configurator.isConfigured)
        let credentials = try String(contentsOf: docs.credentialsURL, encoding: .utf8)
        XCTAssertFalse(credentials.contains(DSHGatewayConfigurator.credentialRef))
    }

}

private final class TestHermesCommandRunner: HermesCommandRunning, @unchecked Sendable {
    let isAvailable = true
    var executableURL: URL? { URL(fileURLWithPath: "/usr/local/bin/hermes") }
    private let forcedReadback: [String: String]
    private(set) var values: [String: String] = [:]
    private(set) var commands: [[String]] = []

    init(forcedReadback: [String: String] = [:]) {
        self.forcedReadback = forcedReadback
    }

    func run(arguments: [String]) throws -> HermesCommandResult {
        commands.append(arguments)
        if arguments.count == 4, arguments[0] == "config", arguments[1] == "set" {
            values[arguments[2]] = arguments[3]
            return HermesCommandResult(output: "saved\n", errorOutput: "", terminationStatus: 0)
        }
        if arguments.count == 3, arguments[0] == "config", arguments[1] == "unset" {
            values.removeValue(forKey: arguments[2])
            return HermesCommandResult(output: "removed\n", errorOutput: "", terminationStatus: 0)
        }
        if arguments.count == 3, arguments[0] == "config", arguments[1] == "get" {
            let key = arguments[2]
            return HermesCommandResult(
                output: "\(forcedReadback[key] ?? values[key] ?? "")\n",
                errorOutput: "",
                terminationStatus: 0
            )
        }
        return HermesCommandResult(output: "", errorOutput: "unexpected command", terminationStatus: 1)
    }
}

private final class TestPiCommandRunner: PiCommandRunning, @unchecked Sendable {
    let isAvailable = true
    var executableURL: URL? { URL(fileURLWithPath: "/usr/local/bin/pi") }
    private let discoveredModel: String
    private(set) var commands: [[String]] = []

    init(discoveredModel: String) {
        self.discoveredModel = discoveredModel
    }

    func run(arguments: [String], agentDirectory: URL) throws -> PiCommandResult {
        commands.append(arguments)
        return PiCommandResult(
            output: "provider   model\ntomo  \(discoveredModel)\n",
            errorOutput: "",
            terminationStatus: 0
        )
    }
}
