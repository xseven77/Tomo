import XCTest
@testable import Tomo

final class ClineAndCodexGatewayTests: XCTestCase {
    var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        super.tearDown()
    }

    // MARK: - CodexGatewayConfigurator Tests

    func testCodexGatewayConfiguratorConfigureAndUnconfigure() throws {
        let configurator = CodexGatewayConfigurator(codexHomeURL: tempDirectory)
        XCTAssertFalse(configurator.isConfigured)

        // 1. 首次配置
        try configurator.configure(
            baseURL: "http://127.0.0.1:58349/v1",
            apiKey: "test-token-123",
            setAsDefaultProvider: true
        )

        XCTAssertTrue(configurator.isConfigured)
        XCTAssertTrue(configurator.isTomoDefaultProvider)

        let content = try String(contentsOf: configurator.configFileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("[model_providers.tomo]"))
        XCTAssertTrue(content.contains("http://127.0.0.1:58349/v1"))
        XCTAssertTrue(content.contains("test-token-123"))
        XCTAssertTrue(content.contains("model_provider = \"tomo\""))

        // 2. 更新 API Key
        try configurator.updateApiKey("new-token-456")
        let updatedContent = try String(contentsOf: configurator.configFileURL, encoding: .utf8)
        XCTAssertTrue(updatedContent.contains("new-token-456"))
        XCTAssertFalse(updatedContent.contains("test-token-123"))

        // 3. 卸载配置
        try configurator.unconfigure()
        XCTAssertFalse(configurator.isConfigured)
        let unconfiguredContent = try String(contentsOf: configurator.configFileURL, encoding: .utf8)
        XCTAssertFalse(unconfiguredContent.contains("[model_providers.tomo]"))
        XCTAssertTrue(unconfiguredContent.contains("model_provider = \"openai\""))
    }

    // MARK: - ClineGatewayConfigurator Tests

    func testClineGatewayConfiguratorConfigureAndUnconfigure() throws {
        let configurator = ClineGatewayConfigurator(clineHomeURL: tempDirectory)
        XCTAssertFalse(configurator.isConfigured)

        // 1. 配置
        try configurator.configure(
            baseURL: "http://127.0.0.1:58349/v1",
            apiKey: "test-cline-token",
            models: ["openai/gpt-4o", "anthropic/claude-3-7-sonnet"],
            defaultModel: "openai/gpt-4o"
        )

        XCTAssertTrue(configurator.isConfigured)

        let data = try Data(contentsOf: configurator.providersFileURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["lastUsedProvider"] as? String, "openai-compatible")

        let providers = try XCTUnwrap(json["providers"] as? [String: Any])
        XCTAssertNil(providers["tomo"])
        let tomoEntry = try XCTUnwrap(providers["openai-compatible"] as? [String: Any])
        let settings = try XCTUnwrap(tomoEntry["settings"] as? [String: Any])
        // Cline must route through its built-in OpenAI-compatible runtime. An
        // arbitrary provider key becomes the runtime provider ID and causes:
        // Unknown or disabled provider "tomo".
        XCTAssertEqual(settings["provider"] as? String, "openai-compatible")
        XCTAssertNil(settings["routingProviderId"])
        XCTAssertEqual(settings["baseUrl"] as? String, "http://127.0.0.1:58349/v1")
        XCTAssertEqual(settings["apiKey"] as? String, "test-cline-token")
        XCTAssertEqual(settings["model"] as? String, "openai/gpt-4o")

        let modelsData = try Data(contentsOf: configurator.modelsFileURL)
        let modelsJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: modelsData) as? [String: Any])
        let modelProviders = try XCTUnwrap(modelsJSON["providers"] as? [String: Any])
        XCTAssertNil(modelProviders["tomo"])
        let openAICompatibleModels = try XCTUnwrap(modelProviders["openai-compatible"] as? [String: Any])
        let providerMetadata = try XCTUnwrap(openAICompatibleModels["provider"] as? [String: Any])
        XCTAssertEqual(providerMetadata["name"] as? String, "Tomo Gateway")

        // 2. 更新 API Key
        try configurator.updateApiKey("rotated-cline-token")
        let updatedData = try Data(contentsOf: configurator.providersFileURL)
        let updatedJson = try XCTUnwrap(JSONSerialization.jsonObject(with: updatedData) as? [String: Any])
        let updatedProviders = try XCTUnwrap(updatedJson["providers"] as? [String: Any])
        let updatedTomo = try XCTUnwrap(updatedProviders["openai-compatible"] as? [String: Any])
        let updatedSettings = try XCTUnwrap(updatedTomo["settings"] as? [String: Any])
        XCTAssertEqual(updatedSettings["apiKey"] as? String, "rotated-cline-token")

        // 3. 卸载配置
        try configurator.unconfigure()
        XCTAssertFalse(configurator.isConfigured)
        let finalData = try Data(contentsOf: configurator.providersFileURL)
        let finalJson = try XCTUnwrap(JSONSerialization.jsonObject(with: finalData) as? [String: Any])
        let finalProviders = try XCTUnwrap(finalJson["providers"] as? [String: Any])
        XCTAssertNil(finalProviders["tomo"])
        XCTAssertNil(finalProviders["openai-compatible"])
    }

    // MARK: - ClineActivityService Tests

    func testClineActivityServiceEmptyAndLoadSnapshot() {
        let service = ClineActivityService(clineDataURL: tempDirectory)
        // 数据库不存在时返回 unavailable
        let snapshot = service.loadSnapshot()
        XCTAssertEqual(snapshot.state, .unavailable)
    }

    // MARK: - AgentCatalog Tests

    func testBuiltInAgentCatalogIncludesCline() {
        let catalog = BuiltInAgentCatalog.prioritized
        XCTAssertTrue(catalog.contains { $0.id == .cline && $0.displayName == "Cline" })

        let guide = AgentInstallGuideCatalog.guide(for: .cline)
        XCTAssertEqual(guide.name, "Cline")
        XCTAssertFalse(guide.methods.isEmpty)
    }
}
