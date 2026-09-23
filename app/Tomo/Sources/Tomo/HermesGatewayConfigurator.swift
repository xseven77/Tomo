import Foundation

struct HermesCommandResult {
    let output: String
    let errorOutput: String
    let terminationStatus: Int32
}

protocol HermesCommandRunning: Sendable {
    var isAvailable: Bool { get }
    var executableURL: URL? { get }
    func run(arguments: [String]) throws -> HermesCommandResult
}

enum HermesGatewayConfigurationError: LocalizedError {
    case executableNotFound
    case noGatewayModel
    case commandFailed(command: String, detail: String)
    case verificationFailed(key: String, expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "未找到 Hermes CLI；请先安装 Hermes，或确认 ~/.local/bin/hermes 可执行。"
        case .noGatewayModel:
            "Gateway 当前没有已启用的可用模型，请先在“接入与模型”中开启至少一个账号代理。"
        case .commandFailed(let command, let detail):
            "Hermes 配置命令失败（\(command)）：\(detail)"
        case .verificationFailed(let key, let expected, let actual):
            "Hermes 配置校验失败：\(key) 应为 \(expected)，实际为 \(actual.isEmpty ? "<空>" : actual)。"
        }
    }
}

struct HermesCLICommandRunner: HermesCommandRunning {
    let homeDirectory: URL
    let environment: [String: String]
    let allowShellFallback: Bool
    private let fixedExecutableURL: URL?

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowShellFallback: Bool = true,
        executableURL: URL? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.allowShellFallback = allowShellFallback
        self.fixedExecutableURL = executableURL
    }

    var executableURL: URL? {
        if let fixedExecutableURL { return fixedExecutableURL }
        return AgentHookManager(
            homeDirectory: homeDirectory,
            allowShellFallback: allowShellFallback
        ).locateExecutable(for: .hermes)
    }

    var isAvailable: Bool { executableURL != nil }

    func run(arguments: [String]) throws -> HermesCommandResult {
        guard let executableURL else {
            throw HermesGatewayConfigurationError.executableNotFound
        }
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        var env = environment
        if env["PATH"] == nil {
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        process.environment = env
        try process.run()
        process.waitUntilExit()
        return HermesCommandResult(
            output: String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            errorOutput: String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            terminationStatus: process.terminationStatus
        )
    }
}

struct HermesGatewayConfigurator: Sendable {
    private static let providerID = "custom:tomo"
    private static let providerKeys = [
        "providers.tomo.name",
        "providers.tomo.api",
        "providers.tomo.api_key",
        "providers.tomo.transport",
        "providers.tomo.default_model",
        "providers.tomo.discover_models",
        "providers.tomo.models",
        "providers.tomo.extra_headers.X-Tomo-Catalog-Version",
        "providers.tomo.extra_headers.X-Agent-Name",
    ]

    public static let lanBypassSnippet = """
# 局域网内不走代理
NO_PROXY=127.0.0.1,localhost,192.168.0.0/16,10.0.0.0/8
no_proxy=127.0.0.1,localhost,192.168.0.0/16,10.0.0.0/8
"""

    let runner: any HermesCommandRunning
    let configURL: URL
    let envURL: URL

    init(
        runner: any HermesCommandRunning = HermesCLICommandRunner(),
        configURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/config.yaml"),
        envURL: URL? = nil
    ) {
        self.runner = runner
        self.configURL = configURL
        self.envURL = envURL ?? configURL.deletingLastPathComponent().appendingPathComponent(".env")
    }

    var isLanBypassConfigured: Bool {
        guard let data = try? Data(contentsOf: envURL),
              let content = String(data: data, encoding: .utf8) else {
            return false
        }
        let lower = content.lowercased()
        return lower.contains("no_proxy") && lower.contains("192.168.0.0/16")
    }

    func configureLanBypass() throws {
        let parentDir = envURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        var existingContent = ""
        if FileManager.default.fileExists(atPath: envURL.path) {
            existingContent = (try? String(contentsOf: envURL, encoding: .utf8)) ?? ""
        }

        if isLanBypassConfigured {
            return
        }

        var newContent = existingContent
        if !newContent.isEmpty && !newContent.hasSuffix("\n") {
            newContent += "\n"
        }
        newContent += Self.lanBypassSnippet + "\n"

        try newContent.write(to: envURL, atomically: true, encoding: .utf8)
    }

    func unconfigureLanBypass() throws {
        guard FileManager.default.fileExists(atPath: envURL.path),
              let content = try? String(contentsOf: envURL, encoding: .utf8) else {
            return
        }

        let lines = content.components(separatedBy: .newlines)
        let filteredLines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "# 局域网内不走代理" { return false }
            if (trimmed.hasPrefix("NO_PROXY=") || trimmed.hasPrefix("no_proxy=")) && trimmed.contains("192.168.0.0/16") {
                return false
            }
            return true
        }

        var cleaned = filteredLines.joined(separator: "\n")
        while cleaned.hasSuffix("\n\n") {
            cleaned.removeLast()
        }
        if !cleaned.isEmpty && !cleaned.hasSuffix("\n") {
            cleaned += "\n"
        }

        try cleaned.write(to: envURL, atomically: true, encoding: .utf8)
    }

    var isHermesInstalled: Bool { runner.isAvailable }
    var executableURL: URL? { runner.executableURL }

    var isConfigured: Bool {
        guard runner.isAvailable else { return false }
        // Do not scan the YAML for the word "tomo": hooks, historical
        // sessions and backup entries may legitimately contain it after this
        // provider has been removed.
        if configValue(for: "providers.tomo.api") != nil {
            return true
        }
        return configValue(for: "model.provider") == Self.providerID
    }

    func unconfigure() throws {
        guard runner.isAvailable else {
            throw HermesGatewayConfigurationError.executableNotFound
        }
        let originalConfig = try? Data(contentsOf: configURL)
        do {
            let currentProvider = configValue(for: "model.provider") ?? ""

            // Hermes' `config unset providers.tomo` is not recursive:
            // it reports success while nested values remain in config.yaml.
            // Remove each Tomo-owned leaf explicitly, then ask Hermes to
            // discard an empty parent when its CLI supports that operation.
            for key in Self.providerKeys {
                try unset(key)
            }
            try unset("providers.tomo")

            if currentProvider == Self.providerID {
                try unset("model.provider")
                try unset("model.default")
            }

            for key in Self.providerKeys {
                try verifyUnset(key)
            }
            if currentProvider == Self.providerID {
                try verifyUnset("model.provider")
                try verifyUnset("model.default")
            }
        } catch {
            if let originalConfig {
                try? originalConfig.write(to: configURL, options: .atomic)
            }
            throw error
        }
    }

    func configure(baseURL: String, apiKey: String, models: [String], defaultModel: String) throws {
        guard runner.isAvailable else {
            throw HermesGatewayConfigurationError.executableNotFound
        }
        let uniqueModels = models.reduce(into: [String]()) { result, model in
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace }), !result.contains(trimmed) else {
                return
            }
            result.append(trimmed)
        }
        // The preferred default does not have to be the first display entry:
        // for example, Gemini 3.6 Flash is chosen ahead of an unverified 3.7
        // alias. It only needs to be part of the registered allowlist.
        guard uniqueModels.contains(defaultModel) else {
            throw HermesGatewayConfigurationError.noGatewayModel
        }
        let modelsJSON = String(
            data: try JSONSerialization.data(withJSONObject: uniqueModels),
            encoding: .utf8
        ) ?? "[]"
        let originalConfig = try? Data(contentsOf: configURL)
        do {
            try set("providers.tomo.name", to: "Tomo")
            try set("providers.tomo.api", to: baseURL)
            try set("providers.tomo.api_key", to: apiKey)
            try set("providers.tomo.transport", to: "chat_completions")
            try set("providers.tomo.default_model", to: defaultModel)
            try set("providers.tomo.discover_models", to: "false")
            try set("providers.tomo.models", to: modelsJSON)
            try set("providers.tomo.extra_headers.X-Tomo-Catalog-Version", to: "2")
            try set("providers.tomo.extra_headers.X-Agent-Name", to: "Hermes")
            try set("model.provider", to: Self.providerID)
            try set("model.default", to: defaultModel)
            // These are legacy unnamed-custom-endpoint keys. Keeping them
            // alongside a named provider makes Hermes surface an extra bare
            // model row in addition to the Tomo allowlist.
            try unset("model.base_url")
            try unset("model.api_key")
            try verify("providers.tomo.name", equals: "Tomo")
            try verify("providers.tomo.api", equals: baseURL)
            try verify("providers.tomo.api_key", equals: apiKey)
            try verify("providers.tomo.transport", equals: "chat_completions")
            try verify("providers.tomo.default_model", equals: defaultModel)
            try verify("providers.tomo.discover_models", equals: "false")
            try verify("providers.tomo.extra_headers.X-Tomo-Catalog-Version", equals: "2")
            try verify("providers.tomo.extra_headers.X-Agent-Name", equals: "Hermes")
            try verify("model.provider", equals: Self.providerID)
            try verify("model.default", equals: defaultModel)
        } catch {
            if let originalConfig {
                try? originalConfig.write(to: configURL, options: .atomic)
            }
            throw error
        }
    }

    func updateApiKey(_ newApiKey: String) throws {
        guard runner.isAvailable else {
            throw HermesGatewayConfigurationError.executableNotFound
        }
        guard isConfigured else { return }
        try set("providers.tomo.api_key", to: newApiKey)
        try verify("providers.tomo.api_key", equals: newApiKey)
    }

    private func set(_ key: String, to value: String) throws {
        let result = try runner.run(arguments: ["config", "set", key, value])
        guard result.terminationStatus == 0 else {
            throw commandError(for: "hermes config set \(key)", result: result)
        }
    }

    private func unset(_ key: String) throws {
        let result = try runner.run(arguments: ["config", "unset", key])
        // Hermes exits non-zero when an optional legacy key does not exist.
        // That is already the desired state, so it must not abort an otherwise
        // valid named-provider configuration.
        let detail = [result.errorOutput, result.output]
            .joined(separator: "\n")
            .lowercased()
        if result.terminationStatus != 0,
           !detail.contains("config key not set"),
           !detail.contains("key not set"),
           !detail.contains("not found") {
            throw commandError(for: "hermes config unset \(key)", result: result)
        }
    }

    private func verify(_ key: String, equals expected: String) throws {
        let result = try runner.run(arguments: ["config", "get", key])
        guard result.terminationStatus == 0 else {
            throw commandError(for: "hermes config get \(key)", result: result)
        }
        let actual = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard actual == expected else {
            throw HermesGatewayConfigurationError.verificationFailed(
                key: key,
                expected: expected,
                actual: actual
            )
        }
    }

    private func configValue(for key: String) -> String? {
        guard let result = try? runner.run(arguments: ["config", "get", key]),
              result.terminationStatus == 0 else {
            return nil
        }
        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func verifyUnset(_ key: String) throws {
        guard let value = configValue(for: key) else { return }
        throw HermesGatewayConfigurationError.verificationFailed(
            key: key,
            expected: "<未设置>",
            actual: value
        )
    }

    private func commandError(for command: String, result: HermesCommandResult) -> HermesGatewayConfigurationError {
        let detail = [result.errorOutput, result.output]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "未知错误"
        return .commandFailed(command: command, detail: detail)
    }
}
