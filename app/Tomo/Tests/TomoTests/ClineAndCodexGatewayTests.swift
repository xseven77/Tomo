import XCTest
import SQLite3

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
        for item in catalogModels {
            XCTAssertEqual(item["use_responses_lite"] as? Bool, false)
            XCTAssertEqual(item["prefer_websockets"] as? Bool, false)
            XCTAssertTrue(item["tool_mode"] is NSNull)
        }

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
        // The original empty config uses the built-in OpenAI provider implicitly.
        XCTAssertFalse(unconfiguredContent.contains("model_provider"))
        XCTAssertFalse(unconfiguredContent.contains("model_catalog_json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configurator.modelsCatalogFileURL.path))
    }
    func testCodexGatewayConfiguratorWithCustomMappingsAndReasoning() throws {
        let configurator = CodexGatewayConfigurator(codexHomeURL: tempDirectory)
        let models = [
            CodexCatalogModelItem(
                slug: "deepseek-chat",
                displayName: "DeepSeek V3",
                description: "Tomo Gateway · DeepSeek V3",
                defaultReasoningEffort: "medium",
                contextWindow: 128000
            ),
            CodexCatalogModelItem(
                slug: "deepseek-reasoner",
                displayName: "DeepSeek R1",
                description: "Tomo Gateway · DeepSeek R1",
                defaultReasoningEffort: "high",
                contextWindow: 131072
            )
        ]

        try configurator.configure(
            baseURL: "http://127.0.0.1:58349/v1",
            apiKey: "test-token-custom",
            models: models,
            setAsDefaultProvider: true
        )

        let catalogData = try Data(contentsOf: configurator.modelsCatalogFileURL)
        let catalogJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
        let catalogModels = try XCTUnwrap(catalogJSON["models"] as? [[String: Any]])
        XCTAssertEqual(catalogModels.count, 2)

        let first = catalogModels[0]
        XCTAssertEqual(first["slug"] as? String, "deepseek-chat")
        XCTAssertEqual(first["display_name"] as? String, "DeepSeek V3")
        XCTAssertEqual(first["default_reasoning_level"] as? String, "medium")
        XCTAssertEqual(first["context_window"] as? Int, 128000)

        let second = catalogModels[1]
        XCTAssertEqual(second["slug"] as? String, "deepseek-reasoner")
        XCTAssertEqual(second["display_name"] as? String, "DeepSeek R1")
        XCTAssertEqual(second["default_reasoning_level"] as? String, "high")
        XCTAssertEqual(second["context_window"] as? Int, 131072)
    }

    func testCodexProviderRegistrationPreservesOfficialDefaultsAndProfiles() throws {
        let configurator = CodexGatewayConfigurator(codexHomeURL: tempDirectory)
        let original = """
        model = "gpt-original"
        model_provider = "openai"
        [profiles.work]
        model = "profile-model"
        model_provider = "other"
        """
        try original.write(to: configurator.configFileURL, atomically: true, encoding: .utf8)
        try configurator.configure(baseURL: "http://127.0.0.1:1234/v1", apiKey: "token",
                                   models: [.init(slug: "google/test", displayName: "Test")],
                                   setAsDefaultProvider: false, defaultModel: "google/test")
        let content = try String(contentsOf: configurator.configFileURL, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix(original))
        XCTAssertFalse(content.contains("model_catalog_json ="))
        XCTAssertFalse(configurator.isTomoDefaultProvider)
        try configurator.unconfigure()
        XCTAssertEqual(try String(contentsOf: configurator.configFileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), original)
    }

    func testCodexDefaultTakeoverRestoresSettingsAfterRepeatedUpdates() throws {
        let configurator = CodexGatewayConfigurator(codexHomeURL: tempDirectory)
        let original = """
        model_provider = 'openai' # official
        model = "gpt-original"
        model_reasoning_effort = "high"
        model_catalog_json = "/original/catalog.json"
        profile = "work"
        [profiles.work]
        model_provider = "openai"
        model = "profile-model"
        """
        try original.write(to: configurator.configFileURL, atomically: true, encoding: .utf8)
        for model in ["google/first", "openai/second"] {
            try configurator.configure(baseURL: "http://127.0.0.1:1234/v1", apiKey: "token",
                                       models: [.init(slug: model, displayName: model)], defaultModel: model,
                                       defaultReasoningEffort: "low")
            XCTAssertTrue(configurator.isTomoDefaultProvider)
        }
        let connected = try String(contentsOf: configurator.configFileURL, encoding: .utf8)
        XCTAssertFalse(connected.contains("profile ="))
        XCTAssertTrue(connected.contains("[profiles.work]\nmodel_provider = \"openai\"\nmodel = \"profile-model\""))
        try configurator.unconfigure()
        let restored = try String(contentsOf: configurator.configFileURL, encoding: .utf8)
        for line in original.components(separatedBy: "\n") { XCTAssertTrue(restored.contains(line)) }
        XCTAssertFalse(restored.contains("google/first"))
        XCTAssertFalse(restored.contains("openai/second"))
    }

    func testCodexResumeCommandQuotesArgumentsAndPinsProvider() {
        let session = CodexGatewaySession(id: "session-id", title: "Test", cwd: "/work/o'brien", provider: "openai")
        let command = CodexGatewaySessionCatalog.resumeCommand(
            session: session, model: "google/test$(touch /tmp/unsafe)",
            homeURL: tempDirectory, executable: "/path with spaces/codex")
        XCTAssertTrue(command.contains("cd '/work/o'\"'\"'brien' && CODEX_HOME="))
        XCTAssertTrue(command.contains("'/path with spaces/codex' 'resume' 'session-id'"))
        XCTAssertTrue(command.contains("'model_provider=\"tomo\"'"))
        XCTAssertTrue(command.contains("'google/test$(touch /tmp/unsafe)'"))
        XCTAssertFalse(command.contains("token"))
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

    func testClineHubLifecycleOverridesStaleSessionAndPreviousReply() throws {
        let dbDir = tempDirectory.appendingPathComponent("db")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let now = Date()
        let messages = tempDirectory.appendingPathComponent("messages.json")
        try JSONSerialization.data(withJSONObject: ["messages": [
            ["role": "assistant", "content": "Previous turn finished", "ts": (now.timeIntervalSince1970 - 30) * 1000]
        ]]).write(to: messages)
        func execute(_ name: String, _ sql: String) throws {
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(dbDir.appendingPathComponent(name).path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        }
        try execute("sessions.db", """
            CREATE TABLE sessions (session_id TEXT, prompt TEXT, status TEXT, updated_at TEXT, cwd TEXT, model TEXT, pid INTEGER, messages_path TEXT);
            INSERT INTO sessions VALUES ('s1', 'Task', 'completed', '2020-01-01T00:00:00Z', '/tmp', 'model', \(ProcessInfo.processInfo.processIdentifier), '\(messages.path)');
            """)
        try execute("hub-events-a.db", "CREATE TABLE hub_events (sequence INTEGER PRIMARY KEY, event TEXT, session_id TEXT, created_at INTEGER);")
        try execute("hub-events-z.db", "CREATE TABLE hub_events (sequence INTEGER PRIMARY KEY, event TEXT, session_id TEXT, created_at INTEGER);")
        let service = ClineActivityService(clineDataURL: tempDirectory)
        let millis = Int64(now.timeIntervalSince1970 * 1000)
        try execute("hub-events-a.db", "INSERT INTO hub_events VALUES (1, 'agent.done', 's1', \(millis - 20_000));")
        for (index, pair) in [("iteration.started", CodexActivityState.thinking), ("tool.started", .executing), ("approval.requested", .waitingForUser), ("tool.finished", .thinking), ("run.aborted", .idle)].enumerated() {
            let seq = index * 2 + 1
            try execute("hub-events-z.db", """
                INSERT INTO hub_events VALUES (\(seq), '\(pair.0)', 's1', \(millis + Int64(index)));
                INSERT INTO hub_events VALUES (\(seq + 1), 'session.updated', 's1', \(millis + Int64(index)));
                """)
            let snapshot = service.loadSnapshot(now: now.addingTimeInterval(1))
            XCTAssertEqual(snapshot.state, pair.1, pair.0)
            XCTAssertEqual(snapshot.activeTaskCount, pair.1 == .idle ? 0 : 1)
        }
        try execute("sessions.db", "UPDATE sessions SET status = 'running';")
        XCTAssertEqual(service.loadSnapshot(now: now.addingTimeInterval(600)).state, .idle)
    }

    func testClineCompletedSessionIsNotActive() throws {
        // 构建临时 Cline 数据目录与 sessions.db
        let dbDir = tempDirectory.appendingPathComponent("db", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let sessionsDB = dbDir.appendingPathComponent("sessions.db")

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(sessionsDB.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        defer { sqlite3_close(db) }

        let schema = """
        CREATE TABLE sessions (
            session_id TEXT PRIMARY KEY,
            prompt TEXT,
            status TEXT,
            updated_at TEXT,
            cwd TEXT,
            model TEXT,
            pid INTEGER,
            messages_path TEXT
        );
        """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)

        // 插入一条已停止的会话（status 为 idle，并且最后一条消息是完成文本）
        let sessionID = "test_completed_session_1"
        let sessionDir = tempDirectory.appendingPathComponent("sessions/\(sessionID)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let messagesURL = sessionDir.appendingPathComponent("\(sessionID).messages.json")

        let messagesJson: [String: Any] = [
            "messages": [
                [
                    "role": "user",
                    "content": "请帮我重构代码"
                ],
                [
                    "role": "assistant",
                    "say": "completion_result",
                    "content": "代码重构已完成！"
                ]
            ]
        ]
        let msgData = try JSONSerialization.data(withJSONObject: messagesJson)
        try msgData.write(to: messagesURL)

        let insertSQL = """
        INSERT INTO sessions (session_id, prompt, status, updated_at, cwd, model, pid, messages_path)
        VALUES ('\(sessionID)', '请帮我重构代码', 'idle', '2026-09-29T12:00:00.000Z', '/tmp', 'gpt-4o', 1234, '\(messagesURL.path)');
        """
        XCTAssertEqual(sqlite3_exec(db, insertSQL, nil, nil, nil), SQLITE_OK)

        let service = ClineActivityService(clineDataURL: tempDirectory)
        let snapshot = service.loadSnapshot()
        // 任务已完成且为 idle 状态，不应作为活跃任务
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertEqual(snapshot.activeTaskCount, 0)
        XCTAssertTrue(snapshot.activeTasks.isEmpty)
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
