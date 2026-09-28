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

        let models = [
            CodexCatalogModelItem(slug: "google/gemini-2.5-flash", displayName: "Gemini 2.5 Flash"),
            CodexCatalogModelItem(slug: "openai/gpt-6-astra", displayName: "GPT-6 Astra")
        ]

        // 1. 首次配置
        try configurator.configure(
            baseURL: "http://127.0.0.1:58349/v1",
            apiKey: "test-token-123",
            models: models,
            setAsDefaultProvider: true
        )

        XCTAssertTrue(configurator.isConfigured)
        XCTAssertTrue(configurator.isTomoDefaultProvider)

        let content = try String(contentsOf: configurator.configFileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("[model_providers.tomo]"))
        XCTAssertTrue(content.contains("http://127.0.0.1:58349/v1"))
        XCTAssertTrue(content.contains("test-token-123"))
        XCTAssertTrue(content.contains("model_provider = \"tomo\""))
        XCTAssertTrue(content.contains("model_catalog_json = \"\(configurator.modelsCatalogFileURL.path)\""))

        // 验证 tomo_models.json 存在且内容正确
        XCTAssertTrue(FileManager.default.fileExists(atPath: configurator.modelsCatalogFileURL.path))
        let catalogData = try Data(contentsOf: configurator.modelsCatalogFileURL)
        let catalogJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
        let catalogModels = try XCTUnwrap(catalogJSON["models"] as? [[String: Any]])
        XCTAssertEqual(catalogModels.count, 2)
        XCTAssertEqual(catalogModels[0]["slug"] as? String, "google/gemini-2.5-flash")
        XCTAssertEqual(catalogModels[1]["slug"] as? String, "openai/gpt-6-astra")

        // 2. 更新模型列表
        try configurator.updateModelsCatalog(models: [
            CodexCatalogModelItem(slug: "google/claude-sonnet-4-6", displayName: "Claude Sonnet 4 6")
        ])
        let updatedCatalogData = try Data(contentsOf: configurator.modelsCatalogFileURL)
        let updatedCatalogJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: updatedCatalogData) as? [String: Any])
        let updatedCatalogModels = try XCTUnwrap(updatedCatalogJSON["models"] as? [[String: Any]])
        XCTAssertEqual(updatedCatalogModels.count, 1)
        XCTAssertEqual(updatedCatalogModels[0]["slug"] as? String, "google/claude-sonnet-4-6")

        // 3. 更新 API Key
        try configurator.updateApiKey("new-token-456")
        let updatedContent = try String(contentsOf: configurator.configFileURL, encoding: .utf8)
        XCTAssertTrue(updatedContent.contains("new-token-456"))
        XCTAssertFalse(updatedContent.contains("test-token-123"))

        // 4. 卸载配置
        try configurator.unconfigure()
        XCTAssertFalse(configurator.isConfigured)
        let unconfiguredContent = try String(contentsOf: configurator.configFileURL, encoding: .utf8)
        XCTAssertFalse(unconfiguredContent.contains("[model_providers.tomo]"))
        XCTAssertTrue(unconfiguredContent.contains("model_provider = \"openai\""))
        XCTAssertFalse(unconfiguredContent.contains("model_catalog_json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurator.modelsCatalogFileURL.path))
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
    func testSanitizeTaskTitle() {
        XCTAssertEqual(
            ClineActivityService.sanitizeTaskTitle("<user_input mode=\"act\">理解一下当前项目，并且理解一下最近在做什么？</user_input>"),
            "理解一下当前项目，并且理解一下最近在做什么？"
        )
        XCTAssertEqual(
            ClineActivityService.sanitizeTaskTitle("Context summary:\n\n## Goal\n优化一下 cline 的任务标题\n\n## State"),
            "优化一下 cline 的任务标题"
        )
        XCTAssertEqual(
            ClineActivityService.sanitizeTaskTitle("### 这是一个带标题的任务\n第二行内容"),
            "这是一个带标题的任务"
        )
        XCTAssertEqual(
            ClineActivityService.sanitizeTaskTitle("<task>执行系统构建</task>"),
            "执行系统构建"
        )
    }

    func testLiveClineActivitySnapshot() {
        let liveService = ClineActivityService()
        let snapshot = liveService.loadSnapshot()
        print("Live snapshot: state=\(snapshot.state), title=\(snapshot.threadTitle ?? "nil"), detail=\(snapshot.detail), activeCount=\(snapshot.activeTaskCount)")
        // 当前 Cline 会话正在运行，应能成功读取到 executing 状态且不是空闲/unavailable
        XCTAssertEqual(snapshot.state, .executing)
        XCTAssertFalse(snapshot.activeTasks.isEmpty)
        XCTAssertNotNil(snapshot.threadTitle)
        XCTAssertFalse(snapshot.threadTitle?.contains("<user_input") ?? false)
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
