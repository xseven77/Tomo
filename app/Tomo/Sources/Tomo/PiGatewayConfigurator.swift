import Foundation

struct PiCommandResult {
    let output: String
    let errorOutput: String
    let terminationStatus: Int32
}

protocol PiCommandRunning: Sendable {
    var isAvailable: Bool { get }
    var executableURL: URL? { get }
    func run(arguments: [String], agentDirectory: URL) throws -> PiCommandResult
}

enum PiGatewayConfigurationError: LocalizedError {
    case executableNotFound
    case noGatewayModel
    case invalidJSON(path: String)
    case modelDiscoveryFailed(String)
    case modelNotDiscovered(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "未找到 Pi CLI；请先安装 Pi，或确认 pi 命令可执行。"
        case .noGatewayModel:
            "Gateway 当前没有已启用的可用模型，请先在“接入与模型”中开启至少一个账号代理。"
        case .invalidJSON(let path):
            "Pi 配置文件不是有效的 JSON：\(path)"
        case .modelDiscoveryFailed(let detail):
            "Pi 无法加载 Tomo 模型：\(detail)"
        case .modelNotDiscovered(let model):
            "配置已写入，但 Pi 未发现模型 codexling/\(model)。"
        }
    }
}

struct PiCLICommandRunner: PiCommandRunning {
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
        ).locateExecutable(for: .pi)
    }

    var isAvailable: Bool { executableURL != nil }

    func run(arguments: [String], agentDirectory: URL) throws -> PiCommandResult {
        guard let executableURL else {
            throw PiGatewayConfigurationError.executableNotFound
        }
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PI_CODING_AGENT_DIR"] = agentDirectory.path
        environment["PATH"] = "\(executableURL.deletingLastPathComponent().path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        return PiCommandResult(
            output: String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            errorOutput: String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            terminationStatus: process.terminationStatus
        )
    }
}

struct PiGatewayConfigurator: Sendable {
    let runner: any PiCommandRunning
    let agentDirectory: URL

    init(
        runner: any PiCommandRunning = PiCLICommandRunner(),
        agentDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent")
    ) {
        self.runner = runner
        self.agentDirectory = agentDirectory
    }

    var isPiInstalled: Bool { runner.isAvailable }
    var executableURL: URL? { runner.executableURL }

    var isConfigured: Bool {
        guard runner.isAvailable else { return false }
        let modelsURL = agentDirectory.appendingPathComponent("models.json")
        guard FileManager.default.fileExists(atPath: modelsURL.path) else { return false }
        guard let modelsRoot = try? loadJSONObject(at: modelsURL) else { return false }
        let providers = modelsRoot["providers"] as? [String: Any]
        return providers?["codexling"] != nil
    }

    func unconfigure() throws {
        guard runner.isAvailable else {
            throw PiGatewayConfigurationError.executableNotFound
        }
        let modelsURL = agentDirectory.appendingPathComponent("models.json")
        let settingsURL = agentDirectory.appendingPathComponent("settings.json")
        let originalModels = try? Data(contentsOf: modelsURL)
        let originalSettings = try? Data(contentsOf: settingsURL)

        do {
            if FileManager.default.fileExists(atPath: modelsURL.path) {
                var modelsRoot = try loadJSONObject(at: modelsURL)
                if var providers = modelsRoot["providers"] as? [String: Any] {
                    providers.removeValue(forKey: "codexling")
                    if providers.isEmpty {
                        modelsRoot.removeValue(forKey: "providers")
                    } else {
                        modelsRoot["providers"] = providers
                    }
                    try writeJSONObject(modelsRoot, to: modelsURL)
                }
            }

            if FileManager.default.fileExists(atPath: settingsURL.path) {
                var settings = try loadJSONObject(at: settingsURL)
                if settings["defaultProvider"] as? String == "codexling" {
                    settings.removeValue(forKey: "defaultProvider")
                    settings.removeValue(forKey: "defaultModel")
                    try writeJSONObject(settings, to: settingsURL)
                }
            }
        } catch {
            restore(originalModels, to: modelsURL)
            restore(originalSettings, to: settingsURL)
            throw error
        }
    }

    func configure(baseURL: String, apiKey: String, models: [String], defaultModel: String) throws {
        guard runner.isAvailable else {
            throw PiGatewayConfigurationError.executableNotFound
        }
        let uniqueModels = models.reduce(into: [String]()) { result, model in
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !result.contains(trimmed) { result.append(trimmed) }
        }
        guard !uniqueModels.isEmpty else {
            throw PiGatewayConfigurationError.noGatewayModel
        }

        try FileManager.default.createDirectory(
            at: agentDirectory,
            withIntermediateDirectories: true
        )
        let modelsURL = agentDirectory.appendingPathComponent("models.json")
        let settingsURL = agentDirectory.appendingPathComponent("settings.json")
        let originalModels = try? Data(contentsOf: modelsURL)
        let originalSettings = try? Data(contentsOf: settingsURL)

        do {
            var modelsRoot = try loadJSONObject(at: modelsURL)
            var providers = modelsRoot["providers"] as? [String: Any] ?? [:]
            providers["codexling"] = [
                "baseUrl": baseURL,
                "api": "openai-completions",
                "apiKey": apiKey,
                "authHeader": true,
                "headers": [
                    "User-Agent": "pi-coding-agent",
                    "X-Agent-Name": "Pi",
                ],
                "models": uniqueModels.map { [
                    "id": $0,
                    "name": $0,
                    "headers": [
                        "User-Agent": "pi-coding-agent",
                        "X-Agent-Name": "Pi",
                    ],
                ] },
            ] as [String: Any]
            modelsRoot["providers"] = providers
            try writeJSONObject(modelsRoot, to: modelsURL)

            var settings = try loadJSONObject(at: settingsURL)
            settings.removeValue(forKey: "provider")
            settings.removeValue(forKey: "baseURL")
            settings.removeValue(forKey: "apiKey")
            settings["defaultProvider"] = "codexling"
            settings["defaultModel"] = defaultModel
            try writeJSONObject(settings, to: settingsURL)

            let result = try runner.run(
                arguments: ["--offline", "--list-models", "codexling"],
                agentDirectory: agentDirectory
            )
            guard result.terminationStatus == 0 else {
                let detail = [result.errorOutput, result.output]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty } ?? "未知错误"
                throw PiGatewayConfigurationError.modelDiscoveryFailed(detail)
            }
            let discoveredDefaultModel = result.output
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .contains { line in
                    line.split(whereSeparator: \.isWhitespace).first == "codexling"
                        && line.contains(defaultModel)
                }
            guard discoveredDefaultModel else {
                throw PiGatewayConfigurationError.modelNotDiscovered(defaultModel)
            }
        } catch {
            restore(originalModels, to: modelsURL)
            restore(originalSettings, to: settingsURL)
            throw error
        }
    }

    func updateApiKey(_ newApiKey: String) throws {
        guard runner.isAvailable else {
            throw PiGatewayConfigurationError.executableNotFound
        }
        guard isConfigured else { return }
        let modelsURL = agentDirectory.appendingPathComponent("models.json")
        guard FileManager.default.fileExists(atPath: modelsURL.path) else { return }
        var modelsRoot = try loadJSONObject(at: modelsURL)
        guard var providers = modelsRoot["providers"] as? [String: Any],
              var codexling = providers["codexling"] as? [String: Any] else {
            return
        }
        codexling["apiKey"] = newApiKey
        providers["codexling"] = codexling
        modelsRoot["providers"] = providers
        try writeJSONObject(modelsRoot, to: modelsURL)
    }

    private func loadJSONObject(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PiGatewayConfigurationError.invalidJSON(path: url.path)
        }
        return object
    }

    private func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }

    private func restore(_ original: Data?, to url: URL) {
        if let original {
            try? original.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
