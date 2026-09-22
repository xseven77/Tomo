import Foundation

struct ConnectionRegistrySnapshot: Codable, Sendable {
    static let currentSchemaVersion = 4

    var schemaVersion = currentSchemaVersion
    var codexAccounts: [CodexAccountConnection] = []
    var deepSeekConnections: [DeepSeekAPIConnection] = []
    var openCodeConnections: [OpenCodeAPIConnection] = []
    var geminiConnections: [GeminiAPIConnection] = []
    /// 用户拖拽后的连接顺序。旧配置没有此字段时按默认顺序补齐。
    var connectionOrder: [String] = []

    init(
        schemaVersion: Int = currentSchemaVersion,
        codexAccounts: [CodexAccountConnection] = [],
        deepSeekConnections: [DeepSeekAPIConnection] = [],
        openCodeConnections: [OpenCodeAPIConnection] = [],
        geminiConnections: [GeminiAPIConnection] = [],
        connectionOrder: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.codexAccounts = codexAccounts
        self.deepSeekConnections = deepSeekConnections
        self.openCodeConnections = openCodeConnections
        self.geminiConnections = geminiConnections
        self.connectionOrder = connectionOrder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        codexAccounts = try container.decodeIfPresent([CodexAccountConnection].self, forKey: .codexAccounts) ?? []
        deepSeekConnections = try container.decodeIfPresent([DeepSeekAPIConnection].self, forKey: .deepSeekConnections) ?? []
        openCodeConnections = try container.decodeIfPresent([OpenCodeAPIConnection].self, forKey: .openCodeConnections) ?? []
        geminiConnections = try container.decodeIfPresent([GeminiAPIConnection].self, forKey: .geminiConnections) ?? []
        connectionOrder = try container.decodeIfPresent([String].self, forKey: .connectionOrder) ?? []
    }
}

struct ConnectionRegistryStorage {
    let fileManager: FileManager
    let fileURL: URL

    init(fileManager: FileManager = .default, fileURL: URL? = nil) {
        self.fileManager = fileManager
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let tomoURL = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Tomo/connections-v1.json")
            if fileManager.fileExists(atPath: tomoURL.path) {
                self.fileURL = tomoURL
            } else {
                let legacyURL = fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/Codexling/connections-v1.json")
                if fileManager.fileExists(atPath: legacyURL.path) {
                    self.fileURL = legacyURL
                } else {
                    self.fileURL = tomoURL
                }
            }
        }
    }

    func load() -> ConnectionRegistrySnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? decoder.decode(ConnectionRegistrySnapshot.self, from: data),
              snapshot.schemaVersion <= ConnectionRegistrySnapshot.currentSchemaVersion else {
            return ConnectionRegistrySnapshot()
        }
        return snapshot
    }

    func save(_ snapshot: ConnectionRegistrySnapshot) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(snapshot)
        data.append(0x0A)
        try data.write(to: fileURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

enum CodexAccountRuntimeError: LocalizedError {
    case codexNotInstalled
    case invalidHome

    var errorDescription: String? {
        switch self {
        case .codexNotInstalled: "未找到 codex CLI"
        case .invalidHome: "Codex 账号运行目录无效"
        }
    }
}

struct CodexAccountRuntimeManager: @unchecked Sendable {
    let fileManager: FileManager
    let runtimesRoot: URL

    init(fileManager: FileManager = .default, runtimesRoot: URL? = nil) {
        self.fileManager = fileManager
        self.runtimesRoot = runtimesRoot ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tomo/Runtimes/Codex", isDirectory: true)
    }

    func createAccount(label: String) throws -> CodexAccountConnection {
        let id = ConnectionID(rawValue: UUID())
        let relative = id.rawValue.uuidString.lowercased()
        let home = runtimesRoot.appendingPathComponent(relative, isDirectory: true)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        let config = home.appendingPathComponent("config.toml")
        if !fileManager.fileExists(atPath: config.path) {
            try "cli_auth_credentials_store = \"file\"\n"
                .write(to: config, atomically: true, encoding: .utf8)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        }
        return CodexAccountConnection(
            id: id,
            label: label,
            relativeHomeDirectory: relative,
            authenticationState: .needsLogin,
            isEnabled: true,
            createdAt: Date()
        )
    }

    func homeURL(for connection: CodexAccountConnection) throws -> URL {
        guard !connection.relativeHomeDirectory.contains("/"),
              !connection.relativeHomeDirectory.contains("..") else {
            throw CodexAccountRuntimeError.invalidHome
        }
        return runtimesRoot.appendingPathComponent(connection.relativeHomeDirectory, isDirectory: true)
    }

    func oauthTokenURL(for connection: CodexAccountConnection) throws -> URL {
        try homeURL(for: connection).appendingPathComponent("oauth_token.json")
    }

    func authenticationState(for connection: CodexAccountConnection) -> ConnectionAuthenticationState {
        if let tokenURL = try? oauthTokenURL(for: connection),
           fileManager.fileExists(atPath: tokenURL.path),
           let data = try? Data(contentsOf: tokenURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let access = json["accessToken"] as? String, !access.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .connected
        }

        guard let codex = try? locateCodexExecutable(),
              let home = try? homeURL(for: connection) else {
            return .needsLogin
        }
        let process = Process()
        process.executableURL = codex
        process.arguments = ["login", "status"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.path
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? .connected : .needsLogin
        } catch {
            return .invalid
        }
    }

    func removeRuntime(for connection: CodexAccountConnection) throws {
        let home = try homeURL(for: connection)
        guard home.deletingLastPathComponent().standardizedFileURL == runtimesRoot.standardizedFileURL else {
            throw CodexAccountRuntimeError.invalidHome
        }
        if fileManager.fileExists(atPath: home.path) {
            try fileManager.removeItem(at: home)
        }
    }

    func locateCodexExecutable() throws -> URL {
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            home.appendingPathComponent(".local/bin/codex").path,
        ]
        if let path = candidates.first(where: fileManager.isExecutableFile(atPath:)) {
            return URL(fileURLWithPath: path)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v codex"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let path = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              fileManager.isExecutableFile(atPath: path) else {
            throw CodexAccountRuntimeError.codexNotInstalled
        }
        return URL(fileURLWithPath: path)
    }

}

protocol DeepSeekCredentialStoring: Sendable {
    func save(apiKey: String, handle: String) throws
    func read(handle: String) throws -> String
    func delete(handle: String) throws
}

enum DeepSeekCredentialError: LocalizedError {
    case keychain(OSStatus)
    case missing
    case interactionRequired

    var errorDescription: String? {
        switch self {
        case .keychain(let status): "Keychain 操作失败（\(status)）"
        case .missing: "Keychain 中没有找到此 API Key"
        case .interactionRequired: "此 Key 由旧版本签名保存，请重新添加后再刷新"
        }
    }
}

struct DeepSeekCredentialStore: DeepSeekCredentialStoring {
    private let credentialsDir: URL

    init(credentialsDir: URL? = nil) {
        self.credentialsDir = credentialsDir ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tomo/deepseek_credentials")
    }

    private func fileURL(for handle: String) -> URL {
        credentialsDir.appendingPathComponent("\(handle).json")
    }

    func save(apiKey: String, handle: String) throws {
        try FileManager.default.createDirectory(at: credentialsDir, withIntermediateDirectories: true)
        let data = Data(apiKey.utf8)
        try data.write(to: fileURL(for: handle), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL(for: handle).path)
    }

    func read(handle: String) throws -> String {
        let data = try Data(contentsOf: fileURL(for: handle))
        guard let value = String(data: data, encoding: .utf8) else {
            throw DeepSeekCredentialError.missing
        }
        return value
    }

    func delete(handle: String) throws {
        let url = fileURL(for: handle)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

enum DeepSeekBalanceError: LocalizedError {
    case invalidResponse
    case unauthorized
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "DeepSeek 返回了无法识别的余额数据"
        case .unauthorized: "DeepSeek API Key 无效或已失效"
        case .unavailable: "DeepSeek 余额当前不可用"
        }
    }
}

protocol DeepSeekBalanceFetching: Sendable {
    func fetch(apiKey: String, connectionID: ConnectionID) async throws -> ProviderBalanceSnapshot
}

struct DeepSeekBalanceService: DeepSeekBalanceFetching {
    private struct Response: Decodable {
        struct Balance: Decodable {
            let currency: String
            let totalBalance: String
            let grantedBalance: String
            let toppedUpBalance: String

            enum CodingKeys: String, CodingKey {
                case currency
                case totalBalance = "total_balance"
                case grantedBalance = "granted_balance"
                case toppedUpBalance = "topped_up_balance"
            }
        }

        let isAvailable: Bool
        let balanceInfos: [Balance]

        enum CodingKeys: String, CodingKey {
            case isAvailable = "is_available"
            case balanceInfos = "balance_infos"
        }
    }

    let session: URLSession?
    private var networkSession: URLSession { session ?? .codexlingExternal }

    init(session: URLSession? = nil) {
        self.session = session
    }

    func fetch(apiKey: String, connectionID: ConnectionID) async throws -> ProviderBalanceSnapshot {
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (data, response) = try await networkSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DeepSeekBalanceError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw DeepSeekBalanceError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw DeepSeekBalanceError.invalidResponse }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard decoded.isAvailable, let balance = decoded.balanceInfos.first else {
            throw DeepSeekBalanceError.unavailable
        }
        guard let total = Decimal(string: balance.totalBalance),
              let granted = Decimal(string: balance.grantedBalance),
              let toppedUp = Decimal(string: balance.toppedUpBalance) else {
            throw DeepSeekBalanceError.invalidResponse
        }
        return ProviderBalanceSnapshot(
            connectionID: connectionID,
            providerID: .deepSeek,
            scope: .account,
            currency: balance.currency,
            total: total,
            granted: granted,
            toppedUp: toppedUp,
            fetchedAt: Date()
        )
    }
}

protocol OpenCodeCredentialStoring: Sendable {
    func save(apiKey: String, handle: String) throws
    func read(handle: String) throws -> String
    func delete(handle: String) throws
}

/// Isolated from the DeepSeek credential directory so a provider migration can
/// never accidentally make another provider's key addressable by handle.
struct OpenCodeCredentialStore: OpenCodeCredentialStoring {
    private let credentialsDir: URL

    init(credentialsDir: URL? = nil) {
        self.credentialsDir = credentialsDir ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tomo/opencode_credentials")
    }

    private func fileURL(for handle: String) -> URL {
        credentialsDir.appendingPathComponent("\(handle).json")
    }

    func save(apiKey: String, handle: String) throws {
        try FileManager.default.createDirectory(at: credentialsDir, withIntermediateDirectories: true)
        let url = fileURL(for: handle)
        try Data(apiKey.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func read(handle: String) throws -> String {
        let data = try Data(contentsOf: fileURL(for: handle))
        guard let value = String(data: data, encoding: .utf8) else {
            throw DeepSeekCredentialError.missing
        }
        return value
    }

    func delete(handle: String) throws {
        let url = fileURL(for: handle)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

enum OpenCodeValidationError: LocalizedError {
    case invalidResponse
    case unauthorized
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "OpenCode 返回了无法识别的模型数据"
        case .unauthorized: "OpenCode API Key 无效、已失效或不属于此计划"
        case .unavailable: "OpenCode 服务暂时不可用"
        }
    }
}

enum DeepSeekValidationError: LocalizedError {
    case invalidResponse
    case unauthorized
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "DeepSeek 返回了无法识别的模型数据"
        case .unauthorized: "DeepSeek API Key 无效或未授权"
        case .unavailable: "DeepSeek 服务暂时不可用"
        }
    }
}

protocol DeepSeekModelsFetching: Sendable {
    /// 校验并返回 DeepSeek 官方可访问的模型 id 列表。
    func validate(apiKey: String) async throws -> [String]
}

struct DeepSeekModelsService: DeepSeekModelsFetching {
    private struct Response: Decodable {
        let data: [Model]
        struct Model: Decodable { let id: String }
    }

    let session: URLSession?
    private var networkSession: URLSession { session ?? .codexlingExternal }

    init(session: URLSession? = nil) {
        self.session = session
    }

    func validate(apiKey: String) async throws -> [String] {
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/models")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (data, response) = try await networkSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DeepSeekValidationError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw DeepSeekValidationError.unauthorized }
        if http.statusCode == 429 || http.statusCode >= 500 { throw DeepSeekValidationError.unavailable }
        guard (200..<300).contains(http.statusCode) else { throw DeepSeekValidationError.invalidResponse }

        // 模型目录只以官方响应为准：解析失败或返回空列表时抛错，由调用方决定
        // 「保留上一次官方结果」或「提示未取到」。绝不回退到本地写死的模型名，
        // 否则界面会显示官方根本不存在的型号。
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let modelIDs = decoded.data
            .map { $0.id.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !modelIDs.isEmpty else { throw DeepSeekValidationError.invalidResponse }
        return modelIDs
    }
}

protocol OpenCodeModelsFetching: Sendable {
    /// 校验并返回可访问的模型 id 列表（已按接口返回顺序）。
    func validate(apiKey: String, plan: OpenCodePlan) async throws -> [String]
}

/// OpenCode documents distinct model catalog endpoints for Zen and Go. They
/// are a low-cost validation call and do not infer balance or usage limits.
struct OpenCodeModelsService: OpenCodeModelsFetching {
    private struct Response: Decodable {
        let data: [Model]
        struct Model: Decodable { let id: String }
    }

    let session: URLSession?
    private var networkSession: URLSession { session ?? .codexlingExternal }

    init(session: URLSession? = nil) {
        self.session = session
    }

    func validate(apiKey: String, plan: OpenCodePlan) async throws -> [String] {
        let urlString: String = switch plan {
        case .go: "https://opencode.ai/zen/go/v1/models"
        case .zen: "https://opencode.ai/zen/v1/models"
        }
        var request = URLRequest(url: URL(string: urlString)!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (data, response) = try await networkSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenCodeValidationError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw OpenCodeValidationError.unauthorized }
        if http.statusCode == 429 || http.statusCode >= 500 { throw OpenCodeValidationError.unavailable }
        guard (200..<300).contains(http.statusCode) else { throw OpenCodeValidationError.invalidResponse }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard !decoded.data.isEmpty else { throw OpenCodeValidationError.unavailable }
        return decoded.data.map(\.id)
    }
}
