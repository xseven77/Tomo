import Foundation

enum CodexGatewayConfigurationError: LocalizedError {
    case configFileNotFound(path: String)
    case configFileUnreadable(path: String)
    case configFileUnwritable(path: String)
    case noGatewayModel

    var errorDescription: String? {
        switch self {
        case .configFileNotFound(let path):
            "未找到 ChatGPT 配置文件：\(path)。请确认是否已安装并初始化 ChatGPT。"
        case .configFileUnreadable(let path):
            "无法读取 ChatGPT 配置文件：\(path)。"
        case .configFileUnwritable(let path):
            "无法写入 ChatGPT 配置文件：\(path)。"
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
        return Self.rootValue("model_provider", in: content.components(separatedBy: "\n")) == "\"tomo\""
    }

    private var originalSettingsFileURL: URL {
        codexHomeURL.appendingPathComponent("tomo_original_settings.json")
    }

    private struct OriginalSettings: Codable {
        var originalLines: [String: String]
        var appliedValues: [String: String]
    }

    private static let managedKeys = ["model_provider", "model", "model_reasoning_effort", "model_catalog_json", "profile"]

    // Only root settings belong to the default provider. Profile/table settings are independent.
    private static func rootIndices(_ key: String, in lines: [String]) -> [Int] {
        var indices: [Int] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }
            guard let equals = trimmed.firstIndex(of: "="),
                  trimmed[..<equals].trimmingCharacters(in: .whitespaces) == key else { continue }
            indices.append(index)
        }
        return indices
    }

    private static func rootValue(_ key: String, in lines: [String]) -> String? {
        guard let index = rootIndices(key, in: lines).first,
              let equals = lines[index].firstIndex(of: "=") else { return nil }
        let value = String(lines[index][lines[index].index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        // Ignore inline comments while keeping hashes inside quoted strings intact.
        if let range = value.range(of: #"^("(?:[^"\\]|\\.)*"|'[^']*'|[^#]+)"#, options: .regularExpression) {
            let token = String(value[range]).trimmingCharacters(in: .whitespaces)
            if token.hasPrefix("'"), token.hasSuffix("'") {
                return tomlString(String(token.dropFirst().dropLast()))
            }
            return token
        }
        return value
    }

    private static func setRoot(_ key: String, value: String?, in lines: inout [String]) {
        for index in rootIndices(key, in: lines).reversed() { lines.remove(at: index) }
        if let value { lines.insert("\(key) = \(value)", at: 0) }
    }

    static func tomlString(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(data: try! encoder.encode(value), encoding: .utf8)!
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

        let originalLines = originalContent.components(separatedBy: "\n")
        var lines = removeModelProvidersTomoBlock(from: originalLines)

        if setAsDefaultProvider {
            guard let model = defaultModel ?? models.first?.slug, !model.isEmpty else {
                throw CodexGatewayConfigurationError.noGatewayModel
            }
            var settings: OriginalSettings
            if FileManager.default.fileExists(atPath: originalSettingsFileURL.path) {
                settings = try JSONDecoder().decode(OriginalSettings.self, from: Data(contentsOf: originalSettingsFileURL))
            } else {
                var saved: [String: String] = [:]
                for key in Self.managedKeys {
                    if let index = Self.rootIndices(key, in: originalLines).first {
                        saved[key] = originalLines[index]
                    }
                }
                // Legacy installs left Gateway model IDs behind when removing the provider.
                // An OpenAI default cannot use a provider-prefixed Gateway model ID.
                let provider = Self.rootValue("model_provider", in: originalLines) ?? "\"openai\""
                if provider == "\"tomo\"" {
                    saved.removeValue(forKey: "model_provider")
                    saved.removeValue(forKey: "model")
                    saved.removeValue(forKey: "model_reasoning_effort")
                    saved.removeValue(forKey: "model_catalog_json")
                } else if provider == "\"openai\"",
                          Self.rootValue("model", in: originalLines)?.contains("/") == true {
                    saved.removeValue(forKey: "model")
                }
                settings = OriginalSettings(originalLines: saved, appliedValues: [:])
            }

            var values = ["model_provider": Self.tomlString("tomo"), "model": Self.tomlString(model)]
            if let effort = defaultReasoningEffort ?? models.first(where: { $0.slug == model })?.defaultReasoningEffort {
                values["model_reasoning_effort"] = Self.tomlString(effort)
            }
            if FileManager.default.fileExists(atPath: modelsCatalogFileURL.path) {
                values["model_catalog_json"] = Self.tomlString(modelsCatalogFileURL.path)
            }
            for (key, value) in values {
                Self.setRoot(key, value: value, in: &lines)
                settings.appliedValues[key] = value
            }
            // An active profile can override the root provider. Keep its table intact,
            // and restore the profile selection when the Gateway is removed.
            if Self.rootValue("profile", in: lines) != nil {
                Self.setRoot("profile", value: nil, in: &lines)
                settings.appliedValues["profile"] = ""
            }
            // Save only settings that Tomo owns, without credentials or unrelated config.
            try JSONEncoder().encode(settings).write(to: originalSettingsFileURL, options: .atomic)
        }

        let tomoBlock = """

[model_providers.tomo]
name = "Tomo Gateway"
base_url = \(Self.tomlString(baseURL))
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
experimental_bearer_token = \(Self.tomlString(apiKey))
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
        var lines = removeModelProvidersTomoBlock(from: text.components(separatedBy: "\n"))
        if FileManager.default.fileExists(atPath: originalSettingsFileURL.path) {
            let settings = try JSONDecoder().decode(OriginalSettings.self, from: Data(contentsOf: originalSettingsFileURL))
            for key in Self.managedKeys {
                // Preserve manual changes made after connecting to Gateway.
                guard let applied = settings.appliedValues[key], (Self.rootValue(key, in: lines) ?? "") == applied else { continue }
                Self.setRoot(key, value: nil, in: &lines)
                if let original = settings.originalLines[key] { lines.insert(original, at: 0) }
            }
        } else if Self.rootValue("model_provider", in: lines) == "\"tomo\"" {
            // Migrate installations created before the original-settings backup existed.
            Self.setRoot("model_provider", value: nil, in: &lines)
            Self.setRoot("model", value: nil, in: &lines)
            Self.setRoot("model_reasoning_effort", value: nil, in: &lines)
        }
        if Self.rootValue("model_catalog_json", in: lines) == Self.tomlString(modelsCatalogFileURL.path) {
            Self.setRoot("model_catalog_json", value: nil, in: &lines)
        }
        if (Self.rootValue("model_provider", in: lines) ?? "\"openai\"") == "\"openai\"",
           Self.rootValue("model", in: lines)?.contains("/") == true {
            Self.setRoot("model", value: nil, in: &lines)
        }
        do {
            try lines.joined(separator: "\n").write(to: configFileURL, atomically: true, encoding: .utf8)
        } catch {
            throw CodexGatewayConfigurationError.configFileUnwritable(path: configFileURL.path)
        }
        // Delete generated files only after the restored config has been written successfully.
        for url in [modelsCatalogFileURL, originalSettingsFileURL] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
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
                lines[i] = "experimental_bearer_token = \(Self.tomlString(newKey))"
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
