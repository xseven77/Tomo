import Foundation

enum CodexGatewayConfigurationError: LocalizedError {
    case configFileNotFound(path: String)
    case configFileUnreadable(path: String)
    case configFileUnwritable(path: String)
    case noGatewayModel

    var errorDescription: String? {
        switch self {
        case .configFileNotFound(let path):
            "未找到 Codex 配置文件：\(path)。请确认是否已安装并初始化 Codex。"
        case .configFileUnreadable(let path):
            "无法读取 Codex 配置文件：\(path)。"
        case .configFileUnwritable(let path):
            "无法写入 Codex 配置文件：\(path)。"
        case .noGatewayModel:
            "Gateway 当前没有可用模型，请先在模型池中启用至少一个模型。"
        }
    }
}

/// 表示注入到 Codex 模型清单中的条目信息
public struct CodexCatalogModelItem: Sendable {
    public let slug: String
    public let displayName: String
    public let description: String?
    public let defaultReasoningEffort: String?
    public let contextWindow: Int?

    public init(
        slug: String,
        displayName: String,
        description: String? = nil,
        defaultReasoningEffort: String? = nil,
        contextWindow: Int? = nil
    ) {
        self.slug = slug
        self.displayName = displayName
        self.description = description
        self.defaultReasoningEffort = defaultReasoningEffort
        self.contextWindow = contextWindow
    }
}

/// 负责将 Tomo Gateway 配置安全注入到 ~/.codex/config.toml 中，或从其中安全移除。
/// 同时管理 model_catalog_json (~/.codex/tomo_models.json)，让 Codex 动态识别 Gateway 模型列表。
///
/// Codex (CLI/Desktop) 原生支持：
/// ```toml
/// model_provider = "tomo"
/// model_catalog_json = "/Users/.../.codex/tomo_models.json"
///
/// [model_providers.tomo]
/// name = "Tomo Gateway"
/// base_url = "http://127.0.0.1:<port>/v1"
/// wire_api = "responses"
/// experimental_bearer_token = "<token>"
/// ```
struct CodexGatewayConfigurator: Sendable {
    let codexHomeURL: URL

    init(
        codexHomeURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    ) {
        self.codexHomeURL = codexHomeURL
    }

    var configFileURL: URL {
        codexHomeURL.appendingPathComponent("config.toml")
    }

    var modelsCatalogFileURL: URL {
        codexHomeURL.appendingPathComponent("tomo_models.json")
    }

    var modelsCacheFileURL: URL {
        codexHomeURL.appendingPathComponent("models_cache.json")
    }

    var isCodexInstalled: Bool {
        AgentHookManager().locateExecutable(for: .codex) != nil
            || FileManager.default.fileExists(atPath: codexHomeURL.path)
            || FileManager.default.fileExists(atPath: "/Applications/ChatGPT.app")
            || FileManager.default.fileExists(atPath: "/Applications/Codex.app")
    }

    var isConfigured: Bool {
        guard FileManager.default.fileExists(atPath: configFileURL.path),
              let content = try? String(contentsOf: configFileURL, encoding: .utf8) else {
            return false
        }
        return content.contains("[model_providers.tomo]")
    }

    /// 检查当前默认 provider 是否就是 tomo
    var isTomoDefaultProvider: Bool {
        guard FileManager.default.fileExists(atPath: configFileURL.path),
              let content = try? String(contentsOf: configFileURL, encoding: .utf8) else {
            return false
        }
        let lines = content.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("model_provider") && trimmed.contains("\"tomo\"") {
                return true
            }
        }
        return false
    }

    /// 生成或更新 `tomo_models.json` 模型清单文件
    func updateModelsCatalog(models: [CodexCatalogModelItem]) throws {
        guard !models.isEmpty else { return }

        // 尝试从 models_cache.json 读取基准模板（保留 Codex 所需的完整字段如 supported_reasoning_levels 等）
        var baseTemplate: [String: Any]? = nil
        if FileManager.default.fileExists(atPath: modelsCacheFileURL.path),
           let data = try? Data(contentsOf: modelsCacheFileURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cachedList = json["models"] as? [[String: Any]],
           let first = cachedList.first {
            baseTemplate = first
        }

        var catalogModels: [[String: Any]] = []
        for (index, item) in models.enumerated() {
            var modelDict = baseTemplate ?? [
                "default_reasoning_level": "low",
                "supported_reasoning_levels": [
                    ["effort": "low", "description": "Fast responses with lighter reasoning"],
                    ["effort": "medium", "description": "Balances speed and reasoning depth for everyday tasks"],
                    ["effort": "high", "description": "Greater reasoning depth for complex problems"]
                ],
                "shell_type": "unified_exec",
                "visibility": "list",
                "supported_in_api": true,
                "context_window": 272000,
                "tool_mode": "code_mode_only",
                "use_responses_lite": true
            ]

            // Gateway exposes standard Responses SSE. Do not inherit OpenAI's
            // private Responses Lite transport or code-mode-only tool contract.
            modelDict["use_responses_lite"] = false
            modelDict["tool_mode"] = NSNull()
            modelDict["prefer_websockets"] = false

            modelDict["slug"] = item.slug
            modelDict["display_name"] = item.displayName
            modelDict["description"] = item.description ?? "Tomo Gateway · \(item.displayName)"
            modelDict["priority"] = index + 1
            if let effort = item.defaultReasoningEffort, !effort.isEmpty {
                modelDict["default_reasoning_level"] = effort
            }
            if let cw = item.contextWindow, cw > 0 {
                modelDict["context_window"] = cw
            }

            catalogModels.append(modelDict)
        }

        let root: [String: Any] = ["models": catalogModels]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: codexHomeURL, withIntermediateDirectories: true)
        try data.write(to: modelsCatalogFileURL, options: .atomic)
    }

    func configure(
        baseURL: String,
        apiKey: String,
        models: [CodexCatalogModelItem] = [],
        setAsDefaultProvider: Bool = true,
        defaultModel: String? = nil,
        defaultReasoningEffort: String? = nil
    ) throws {
        try FileManager.default.createDirectory(at: codexHomeURL, withIntermediateDirectories: true)

        // 1. 如果提供了模型列表，生成或更新 tomo_models.json
        if !models.isEmpty {
            try updateModelsCatalog(models: models)
        }

        let originalContent: String
        if FileManager.default.fileExists(atPath: configFileURL.path) {
            guard let text = try? String(contentsOf: configFileURL, encoding: .utf8) else {
                throw CodexGatewayConfigurationError.configFileUnreadable(path: configFileURL.path)
            }
            originalContent = text
        } else {
            originalContent = ""
        }

        var lines = originalContent.components(separatedBy: "\n")

        // 2. 如果需要设为默认 model_provider
        if setAsDefaultProvider {
            var foundModelProvider = false
            for i in 0..<lines.count {
                let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("model_provider") && trimmed.contains("=") {
                    lines[i] = "model_provider = \"tomo\""
                    foundModelProvider = true
                    break
                }
            }
            if !foundModelProvider {
                lines.insert("model_provider = \"tomo\"", at: 0)
            }
        }

        // 2.1 如果指定了默认 model 或 defaultReasoningEffort，更新 ~/.codex/config.toml
        if let defaultModel, !defaultModel.isEmpty {
            var foundModel = false
            for i in 0..<lines.count {
                let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("model") && !trimmed.hasPrefix("model_") && trimmed.contains("=") {
                    lines[i] = "model = \"\(defaultModel)\""
                    foundModel = true
                    break
                }
            }
            if !foundModel {
                let insertIdx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("model_provider") })
                    .map { $0 + 1 } ?? 0
                lines.insert("model = \"\(defaultModel)\"", at: insertIdx)
            }
        }

        if let defaultReasoningEffort, !defaultReasoningEffort.isEmpty {
            var foundEffort = false
            for i in 0..<lines.count {
                let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("model_reasoning_effort") && trimmed.contains("=") {
                    lines[i] = "model_reasoning_effort = \"\(defaultReasoningEffort)\""
                    foundEffort = true
                    break
                }
            }
            if !foundEffort {
                let insertIdx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("model =") || $0.trimmingCharacters(in: .whitespaces).hasPrefix("model=") })
                    .map { $0 + 1 } ?? (lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("model_provider") }).map { $0 + 1 } ?? 0)
                lines.insert("model_reasoning_effort = \"\(defaultReasoningEffort)\"", at: insertIdx)
            }
        }

        // 3. 配置 model_catalog_json 指向 tomo_models.json（当文件存在时）
        if FileManager.default.fileExists(atPath: modelsCatalogFileURL.path) {
            let catalogLine = "model_catalog_json = \"\(modelsCatalogFileURL.path)\""
            var foundCatalog = false
            for i in 0..<lines.count {
                let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("model_catalog_json") && trimmed.contains("=") {
                    lines[i] = catalogLine
                    foundCatalog = true
                    break
                }
            }
            if !foundCatalog {
                let insertIdx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("model_provider") })
                    .map { $0 + 1 } ?? 0
                lines.insert(catalogLine, at: insertIdx)
            }
        }

        // 4. 移除旧的 [model_providers.tomo] 块（如果存在）
        lines = removeModelProvidersTomoBlock(from: lines)

        // 5. 构建新的 [model_providers.tomo] 块并追加
        let tomoBlock = """

[model_providers.tomo]
name = "Tomo Gateway"
base_url = "\(baseURL)"
wire_api = "responses"
experimental_bearer_token = "\(apiKey)"
"""
        var newContent = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        newContent += "\n" + tomoBlock + "\n"

        do {
            try newContent.write(to: configFileURL, atomically: true, encoding: .utf8)
        } catch {
            throw CodexGatewayConfigurationError.configFileUnwritable(path: configFileURL.path)
        }
    }

    func unconfigure() throws {
        guard FileManager.default.fileExists(atPath: configFileURL.path) else { return }
        guard let text = try? String(contentsOf: configFileURL, encoding: .utf8) else {
            throw CodexGatewayConfigurationError.configFileUnreadable(path: configFileURL.path)
        }

        var lines = text.components(separatedBy: "\n")

        // 1. 移除 [model_providers.tomo] 块
        lines = removeModelProvidersTomoBlock(from: lines)

        // 2. 如果 model_provider = "tomo"，重置回 openai
        for i in 0..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("model_provider") && trimmed.contains("\"tomo\"") {
                lines[i] = "model_provider = \"openai\""
            }
        }

        // 3. 移除 model_catalog_json 配置行（如果指向 tomo_models.json）
        lines.removeAll { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("model_catalog_json") && trimmed.contains("tomo_models.json")
        }

        // 4. 清理 tomo_models.json
        if FileManager.default.fileExists(atPath: modelsCatalogFileURL.path) {
            try? FileManager.default.removeItem(at: modelsCatalogFileURL)
        }

        let newContent = lines.joined(separator: "\n")
        do {
            try newContent.write(to: configFileURL, atomically: true, encoding: .utf8)
        } catch {
            throw CodexGatewayConfigurationError.configFileUnwritable(path: configFileURL.path)
        }
    }

    func updateApiKey(_ newKey: String) throws {
        guard FileManager.default.fileExists(atPath: configFileURL.path),
              let text = try? String(contentsOf: configFileURL, encoding: .utf8) else {
            return
        }
        guard text.contains("[model_providers.tomo]") else { return }

        var lines = text.components(separatedBy: "\n")
        var inTomoBlock = false

        for i in 0..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed == "[model_providers.tomo]" {
                inTomoBlock = true
                continue
            }
            if inTomoBlock && trimmed.hasPrefix("[") {
                inTomoBlock = false
                continue
            }
            if inTomoBlock && trimmed.hasPrefix("experimental_bearer_token") {
                lines[i] = "experimental_bearer_token = \"\(newKey)\""
                break
            }
        }

        let newContent = lines.joined(separator: "\n")
        try newContent.write(to: configFileURL, atomically: true, encoding: .utf8)
    }

    private func removeModelProvidersTomoBlock(from lines: [String]) -> [String] {
        var result: [String] = []
        var inTomoBlock = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "[model_providers.tomo]" {
                inTomoBlock = true
                continue
            }
            if inTomoBlock {
                if trimmed.hasPrefix("[") {
                    inTomoBlock = false
                    result.append(line)
                }
                // 忽略 tomo 块内的行
                continue
            }
            result.append(line)
        }

        return result
    }
}
