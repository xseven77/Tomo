import Foundation

enum ClineGatewayConfigurationError: LocalizedError {
    case settingsUnreadable(path: String)
    case settingsUnwritable(path: String)
    case noGatewayModel

    var errorDescription: String? {
        switch self {
        case .settingsUnreadable(let path):
            "无法读取 Cline 配置文件：\(path)。"
        case .settingsUnwritable(let path):
            "无法写入 Cline 配置文件：\(path)。"
        case .noGatewayModel:
            "Gateway 当前没有可用模型，请先在模型池中启用至少一个模型。"
        }
    }
}

/// 负责将 Tomo Gateway 作为 Cline 的一个命名配置写入配置文件。
///
/// 注意：Cline 会直接把 `providers` 的顶层 key 写入新会话的
/// `providerId`，而不是以 `settings.provider` 作为最终路由依据。因此配置
/// key 也必须是 Cline 已注册的 `openai-compatible`；`Tomo Gateway` 只作为
/// models.json 中的展示名称。使用自定义 key `tomo` 会导致
/// `Unknown or disabled provider "tomo"`。
///
/// Cline 的 Provider 配置存储在 `~/.cline/data/settings/providers.json`，
/// 相应的模型列表与供应商展示信息存储在 `~/.cline/data/settings/models.json`。
///
/// 其 providers.json 模式为：
/// ```json
/// {
///   "version": 1,
///   "lastUsedProvider": "openai-compatible",
///   "providers": {
///     "openai-compatible": {
///       "settings": {
///         "provider": "openai-compatible",
///         "protocol": "openai-chat",
///         "client": "openai-compatible",
///         "baseUrl": "http://127.0.0.1:<port>/v1",
///         "apiKey": "<token>",
///         "model": "<defaultModel>"
///       },
///       "updatedAt": "...",
///       "tokenSource": "manual"
///     }
///   }
/// }
/// ```
///
/// 其 models.json 模式为：
/// ```json
/// {
///   "version": 1,
///   "providers": {
///     "openai-compatible": {
///       "provider": {
///         "name": "Tomo Gateway",
///         "baseUrl": "http://127.0.0.1:<port>/v1",
///         "modelsSourceUrl": "http://127.0.0.1:<port>/v1/models",
///         "defaultModelId": "<defaultModel>",
///         "protocol": "openai-chat",
///         "client": "openai-compatible",
///         "capabilities": ["reasoning", "tools", "vision"]
///       },
///       "models": {
///         "<model_id>": {
///           "id": "<model_id>",
///           "name": "<display_name>",
///           "supportsVision": true,
///           "supportsReasoning": true
///         }
///       }
///     }
///   }
/// }
/// ```
struct ClineGatewayConfigurator: Sendable {
    let clineHomeURL: URL

    init(
        clineHomeURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cline", isDirectory: true)
    ) {
        self.clineHomeURL = clineHomeURL
    }

    var settingsDirURL: URL {
        clineHomeURL.appendingPathComponent("data/settings", isDirectory: true)
    }

    var providersFileURL: URL {
        settingsDirURL.appendingPathComponent("providers.json")
    }

    var modelsFileURL: URL {
        settingsDirURL.appendingPathComponent("models.json")
    }

    var isClineInstalled: Bool {
        AgentHookManager().locateExecutable(for: .cline) != nil
            || FileManager.default.fileExists(atPath: "/Applications/Cline.app")
            || FileManager.default.fileExists(atPath: clineHomeURL.path)
    }

    var isConfigured: Bool {
        guard FileManager.default.fileExists(atPath: providersFileURL.path),
              let data = try? Data(contentsOf: providersFileURL),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let providers = json["providers"] as? [String: Any] else {
            return false
        }
        guard let entry = providers["openai-compatible"] as? [String: Any],
              let settings = entry["settings"] as? [String: Any],
              let baseURL = settings["baseUrl"] as? String else {
            return false
        }
        return baseURL.contains("127.0.0.1") && baseURL.contains("/v1")
    }

    func configure(
        baseURL: String,
        apiKey: String,
        models: [String],
        defaultModel: String
    ) throws {
        try FileManager.default.createDirectory(at: settingsDirURL, withIntermediateDirectories: true)

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let nowIso = isoFormatter.string(from: Date())

        // 1. 写入 providers.json
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: providersFileURL.path),
           let data = try? Data(contentsOf: providersFileURL),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            root = json
        } else {
            root["version"] = 1
            root["modes"] = [String: Any]()
        }

        var providers = root["providers"] as? [String: Any] ?? [:]
        let tomoSettings: [String: Any] = [
            // Runtime routing must use a provider registered by Cline's
            // provider registry; arbitrary dictionary keys become provider IDs.
            "provider": "openai-compatible",
            "protocol": "openai-chat",
            "client": "openai-compatible",
            "baseUrl": baseURL,
            "apiKey": apiKey,
            "model": defaultModel,
            "headers": [
                "User-Agent": "cline-desktop",
                "X-Agent-Name": "Cline"
            ]
        ]

        let tomoEntry: [String: Any] = [
            "settings": tomoSettings,
            "updatedAt": nowIso,
            "tokenSource": "manual"
        ]

        // Remove the legacy profile. Cline uses the dictionary key as the
        // runtime provider ID, so keeping it selectable recreates the error.
        providers.removeValue(forKey: "tomo")
        providers["openai-compatible"] = tomoEntry
        root["providers"] = providers
        root["lastUsedProvider"] = "openai-compatible"

        do {
            let outData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try outData.write(to: providersFileURL, options: .atomic)
        } catch {
            throw ClineGatewayConfigurationError.settingsUnwritable(path: providersFileURL.path)
        }

        // 2. 写入 models.json (使 Cline 展示为 "Tomo Gateway" 并且读取所有 models 与 modelsSourceUrl)
        var modelsRoot: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: modelsFileURL.path),
           let data = try? Data(contentsOf: modelsFileURL),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            modelsRoot = json
        } else {
            modelsRoot["version"] = 1
        }

        var modelsProviders = modelsRoot["providers"] as? [String: Any] ?? [:]

        // 构建 models 映射
        var modelsDict: [String: Any] = [:]
        for m in models {
            let trimmed = m.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            modelsDict[trimmed] = [
                "id": trimmed,
                "name": trimmed,
                "supportsVision": true,
                "supportsAttachments": true,
                "supportsReasoning": true
            ]
        }

        // 保证 defaultModel 至少存在
        if modelsDict[defaultModel] == nil {
            modelsDict[defaultModel] = [
                "id": defaultModel,
                "name": defaultModel,
                "supportsVision": true,
                "supportsAttachments": true,
                "supportsReasoning": true
            ]
        }

        let modelsSourceUrl = baseURL.hasSuffix("/") ? "\(baseURL)models" : "\(baseURL)/models"

        let tomoModelProviderEntry: [String: Any] = [
            "provider": [
                "name": "Tomo Gateway",
                "baseUrl": baseURL,
                "modelsSourceUrl": modelsSourceUrl,
                "defaultModelId": defaultModel,
                "protocol": "openai-chat",
                "client": "openai-compatible",
                "capabilities": ["reasoning", "tools", "vision", "streaming", "prompt-cache"]
            ],
            "models": modelsDict
        ]

        modelsProviders.removeValue(forKey: "tomo")
        modelsProviders["openai-compatible"] = tomoModelProviderEntry
        modelsRoot["providers"] = modelsProviders

        do {
            let outData = try JSONSerialization.data(withJSONObject: modelsRoot, options: [.prettyPrinted, .sortedKeys])
            try outData.write(to: modelsFileURL, options: .atomic)
        } catch {
            throw ClineGatewayConfigurationError.settingsUnwritable(path: modelsFileURL.path)
        }
    }

    func unconfigure() throws {
        // 1. 从 providers.json 移除
        if FileManager.default.fileExists(atPath: providersFileURL.path),
           let data = try? Data(contentsOf: providersFileURL),
           var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           var providers = root["providers"] as? [String: Any] {
            providers.removeValue(forKey: "tomo")
            if let entry = providers["openai-compatible"] as? [String: Any],
               let settings = entry["settings"] as? [String: Any],
               let baseURL = settings["baseUrl"] as? String,
               baseURL.contains("127.0.0.1") {
                providers.removeValue(forKey: "openai-compatible")
            }
            root["providers"] = providers
            if ["tomo", "openai-compatible"].contains(root["lastUsedProvider"] as? String ?? "") {
                root.removeValue(forKey: "lastUsedProvider")
            }
            if let outData = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
                try? outData.write(to: providersFileURL, options: .atomic)
            }
        }

        // 2. 从 models.json 移除
        if FileManager.default.fileExists(atPath: modelsFileURL.path),
           let data = try? Data(contentsOf: modelsFileURL),
           var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           var providers = root["providers"] as? [String: Any] {
            providers.removeValue(forKey: "tomo")
            if let entry = providers["openai-compatible"] as? [String: Any],
               let provider = entry["provider"] as? [String: Any],
               provider["name"] as? String == "Tomo Gateway" {
                providers.removeValue(forKey: "openai-compatible")
            }
            root["providers"] = providers
            if let outData = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
                try? outData.write(to: modelsFileURL, options: .atomic)
            }
        }
    }

    func updateApiKey(_ newKey: String) throws {
        guard FileManager.default.fileExists(atPath: providersFileURL.path),
              let data = try? Data(contentsOf: providersFileURL),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var providers = root["providers"] as? [String: Any],
              var tomoEntry = providers["openai-compatible"] as? [String: Any],
              var settings = tomoEntry["settings"] as? [String: Any] else {
            return
        }

        settings["apiKey"] = newKey
        tomoEntry["settings"] = settings
        providers["openai-compatible"] = tomoEntry
        root["providers"] = providers

        let outData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try outData.write(to: providersFileURL, options: .atomic)
    }
}
