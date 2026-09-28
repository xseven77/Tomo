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

/// 负责将 Tomo Gateway 配置安全注入到 ~/.codex/config.toml 中，或从其中安全移除。
///
/// Codex (CLI/Desktop) 原生支持：
/// ```toml
/// model_provider = "tomo"
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

    func configure(
        baseURL: String,
        apiKey: String,
        setAsDefaultProvider: Bool = true
    ) throws {
        try FileManager.default.createDirectory(at: codexHomeURL, withIntermediateDirectories: true)

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

        // 1. 如果需要设为默认 model_provider
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
                // 在文件头部合适位置插入
                lines.insert("model_provider = \"tomo\"", at: 0)
            }
        }

        // 2. 移除旧的 [model_providers.tomo] 块（如果存在）
        lines = removeModelProvidersTomoBlock(from: lines)

        // 3. 构建新的 [model_providers.tomo] 块并追加
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

        // 2. 如果 model_provider = "tomo"，重置或注释掉
        for i in 0..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("model_provider") && trimmed.contains("\"tomo\"") {
                // 恢复默认 openai
                lines[i] = "model_provider = \"openai\""
            }
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
