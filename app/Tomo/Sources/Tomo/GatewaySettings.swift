import Foundation

public enum ProviderRoutingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case smooth = "smooth"
    case pinnedAccount = "pinnedAccount"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .smooth: return "平滑过渡"
        case .pinnedAccount: return "固定特定账号"
        }
    }

    public var subtitle: String {
        switch self {
        case .smooth: return "多账号轮询均衡负载，各账号额度平滑消耗防并发限频"
        case .pinnedAccount: return "流量优先直通所选的特定账号；额度耗尽或异常时自动降级为平滑过渡"
        }
    }

    public var iconName: String {
        switch self {
        case .smooth: return "arrow.triangle.swap"
        case .pinnedAccount: return "pin.fill"
        }
    }
}

public enum HealthCheckInterval: String, Codable, CaseIterable, Identifiable, Sendable {
    case oneHour = "1h"
    case sixHours = "6h"
    case midnight = "midnight"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .oneHour: return "每 1 小时"
        case .sixHours: return "每 6 小时"
        case .midnight: return "每天 0 点"
        }
    }

    public var subtitle: String {
        switch self {
        case .oneHour: return "定时每隔 1 小时自动对可用模型进行巡检"
        case .sixHours: return "定时每隔 6 小时自动对可用模型进行巡检"
        case .midnight: return "每天本地时间 00:00 跨日时自动进行一次全量巡检"
        }
    }
}

public enum AutomationTaskType: String, Codable, CaseIterable, Identifiable, Sendable {
    case modelHealthCheck = "modelHealthCheck"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .modelHealthCheck: return "模型健康巡检"
        }
    }

    public var iconName: String {
        switch self {
        case .modelHealthCheck: return "stethoscope"
        }
    }

    public var subtitle: String {
        switch self {
        case .modelHealthCheck: return "按计划自动探测并验证指定供应商与账号下模型的可用性与时延"
        }
    }
}

public struct GatewayAutomationTask: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var taskType: AutomationTaskType
    public var enabled: Bool
    public var providers: [String]
    public var allAccounts: Bool
    public var accountIds: [String]
    public var hours: [Int]
    public var lastRunAt: Int64?
    public var lastRunStatus: String?
    public var lastRunSummary: String?

    public var lastRunDate: Date? {
        lastRunAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    public var hoursDescription: String {
        if hours.isEmpty { return "未设置运行时间" }
        if hours.count == 24 { return "全天候 (每小时)" }
        let sorted = hours.sorted()
        return sorted.map { String(format: "%02d:00", $0) }.joined(separator: ", ")
    }

    public init(
        id: String = UUID().uuidString,
        name: String,
        taskType: AutomationTaskType = .modelHealthCheck,
        enabled: Bool = true,
        providers: [String] = [],
        allAccounts: Bool = true,
        accountIds: [String] = [],
        hours: [Int] = [8, 14, 21],
        lastRunAt: Int64? = nil,
        lastRunStatus: String? = nil,
        lastRunSummary: String? = nil
    ) {
        self.id = id
        self.name = name
        self.taskType = taskType
        self.enabled = enabled
        self.providers = providers
        self.allAccounts = allAccounts
        self.accountIds = accountIds
        self.hours = hours.sorted()
        self.lastRunAt = lastRunAt
        self.lastRunStatus = lastRunStatus
        self.lastRunSummary = lastRunSummary
    }
}

/// 一次自动化巡检的最终结果。
///
/// `cancelled` 必须与「失败」区分：用户主动取消巡检不代表模型不可用，
/// 若把它记成失败会污染成功率统计（历史 bug：取消后记录还会停在「进行中」）。
public enum GatewayAutomationRunOutcome: String, Sendable {
    case running
    case success
    case failed
    case cancelled

    public var label: String {
        switch self {
        case .running: "进行中"
        case .success: "成功"
        case .failed: "失败"
        case .cancelled: "已取消"
        }
    }
}

public struct GatewayAutomationRunLog: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var taskId: String
    public var taskName: String
    public var taskType: AutomationTaskType
    public var startedAt: Int64
    public var finishedAt: Int64?
    public var isSuccess: Bool?
    public var summary: String?
    /// 本次巡检是否由用户取消。与 `isSuccess == false` 并存：取消同样不算成功，
    /// 但展示为「已取消」而不是「失败」。旧记录与网关进程可能没有该字段。
    public var cancelled: Bool?
    /// 单次巡检的逐个模型探测明细结果。
    public var results: [GatewayModelCheckResult]?

    /// 网关进程（Rust）为取消的巡检写的摘要前缀，App 与网关共用同一份文案。
    /// 即使取消标记在跨进程写回时丢失，也能靠摘要认出「已取消」。
    public static let cancelledSummaryPrefix = "已取消"

    public var idGenerator: String { id }

    public init(
        id: String = UUID().uuidString,
        taskId: String,
        taskName: String,
        taskType: AutomationTaskType = .modelHealthCheck,
        startedAt: Int64,
        finishedAt: Int64? = nil,
        isSuccess: Bool? = nil,
        summary: String? = nil,
        cancelled: Bool? = nil,
        results: [GatewayModelCheckResult]? = nil
    ) {
        self.id = id
        self.taskId = taskId
        self.taskName = taskName
        self.taskType = taskType
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.isSuccess = isSuccess
        self.summary = summary
        self.cancelled = cancelled
        self.results = results
    }

    public var durationMs: Int64? {
        guard let finishedAt else { return nil }
        return max(0, finishedAt - startedAt)
    }

    /// 记录是否还停在「进行中」（没有结束时点）。
    public var isUnfinished: Bool { finishedAt == nil }

    /// 展示用结果：取消优先于成功/失败，避免取消被记成失败或成功。
    public var outcome: GatewayAutomationRunOutcome {
        guard finishedAt != nil else { return .running }
        if cancelled == true { return .cancelled }
        if let summary, summary.hasPrefix(Self.cancelledSummaryPrefix) { return .cancelled }
        return isSuccess == true ? .success : .failed
    }

    enum CodingKeys: String, CodingKey {
        case id, taskId, taskName, taskType, startedAt, finishedAt, isSuccess, summary, cancelled, results
    }

    /// 容错解码：执行日志由网关进程（Rust）与 App 共同写入同一个文件，
    /// 未知的 taskType 不应让整份设置解码失败（那会导致设置被重置为默认值）。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        taskId = try container.decode(String.self, forKey: .taskId)
        taskName = try container.decodeIfPresent(String.self, forKey: .taskName) ?? taskId
        let rawTaskType = try container.decodeIfPresent(String.self, forKey: .taskType)
        taskType = rawTaskType.flatMap(AutomationTaskType.init(rawValue:)) ?? .modelHealthCheck
        startedAt = try container.decode(Int64.self, forKey: .startedAt)
        finishedAt = try container.decodeIfPresent(Int64.self, forKey: .finishedAt)
        isSuccess = try container.decodeIfPresent(Bool.self, forKey: .isSuccess)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        cancelled = try container.decodeIfPresent(Bool.self, forKey: .cancelled)
        results = try container.decodeIfPresent([GatewayModelCheckResult].self, forKey: .results)
    }

    public var durationText: String {
        guard let ms = durationMs else { return "进行中" }
        if ms < 1000 { return "\(ms)ms" }
        let seconds = ms / 1000
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let rem = seconds % 60
        return rem > 0 ? "\(minutes)m \(rem)s" : "\(minutes)m"
    }

    public var startDate: Date { Date(timeIntervalSince1970: TimeInterval(startedAt)) }
}

public struct GatewayModelCapabilityOverride: Codable, Equatable, Sendable {
    public var modelID: String
    public var contextWindow: Int?
    public var maxTokens: Int?
    public var supportsImage: Bool?
    public var reasoningLevels: [String]?
    public var defaultReasoningLevel: String?

    public init(
        modelID: String,
        contextWindow: Int? = nil,
        maxTokens: Int? = nil,
        supportsImage: Bool? = nil,
        reasoningLevels: [String]? = nil,
        defaultReasoningLevel: String? = nil
    ) {
        self.modelID = modelID
        self.contextWindow = contextWindow
        self.maxTokens = maxTokens
        self.supportsImage = supportsImage
        self.reasoningLevels = reasoningLevels
        self.defaultReasoningLevel = defaultReasoningLevel
    }
}

public struct GatewaySettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var modelConsolidationEnabled: Bool
    public var consolidatedProviders: [String]
    public var providerRoutingModes: [String: String]
    public var providerPinnedAccounts: [String: String]
    public var allowFailover: Bool
    public var cooldownSeconds: Int
    public var maxFailoverRetries: Int
    public var autoCheckOnStartupWithHistory: Bool
    public var healthCheckInterval: String
    public var automationTasks: [GatewayAutomationTask]
    public var automationRunLogs: [GatewayAutomationRunLog]
    public var modelCapabilityOverrides: [String: GatewayModelCapabilityOverride]
    public var allowLanAccess: Bool
    public var authToken: String

    public static func generateSecureToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            let hex = bytes.map { String(format: "%02x", $0) }.joined()
            return "cdx_\(hex)"
        }
        let uuidHex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "cdx_\(uuidHex)"
    }

    public enum CodingKeys: String, CodingKey {
        case schemaVersion = "$schemaVersion"
        case modelConsolidationEnabled
        case consolidatedProviders
        case providerRoutingModes
        case providerPinnedAccounts
        case allowFailover
        case cooldownSeconds
        case maxFailoverRetries
        case autoCheckOnStartupWithHistory
        case healthCheckInterval
        case automationTasks
        case automationRunLogs
        case modelCapabilityOverrides
        case allowLanAccess
        case authToken
    }

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        modelConsolidationEnabled: Bool = false,
        consolidatedProviders: [String] = [],
        providerRoutingModes: [String: String] = [:],
        providerPinnedAccounts: [String: String] = [:],
        allowFailover: Bool = true,
        cooldownSeconds: Int = 300,
        maxFailoverRetries: Int = 2,
        autoCheckOnStartupWithHistory: Bool = false,
        healthCheckInterval: String = HealthCheckInterval.oneHour.rawValue,
        automationTasks: [GatewayAutomationTask] = [],
        automationRunLogs: [GatewayAutomationRunLog] = [],
        modelCapabilityOverrides: [String: GatewayModelCapabilityOverride] = [:],
        allowLanAccess: Bool = false,
        authToken: String = Self.generateSecureToken()
    ) {
        self.schemaVersion = schemaVersion
        self.modelConsolidationEnabled = modelConsolidationEnabled
        self.consolidatedProviders = consolidatedProviders
        self.providerRoutingModes = providerRoutingModes
        self.providerPinnedAccounts = providerPinnedAccounts
        self.allowFailover = allowFailover
        self.cooldownSeconds = cooldownSeconds
        self.maxFailoverRetries = maxFailoverRetries
        self.autoCheckOnStartupWithHistory = autoCheckOnStartupWithHistory
        self.healthCheckInterval = healthCheckInterval
        self.automationTasks = automationTasks
        self.automationRunLogs = automationRunLogs
        self.modelCapabilityOverrides = modelCapabilityOverrides
        self.allowLanAccess = allowLanAccess
        self.authToken = authToken
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        modelConsolidationEnabled = try container.decodeIfPresent(Bool.self, forKey: .modelConsolidationEnabled) ?? false
        consolidatedProviders = try container.decodeIfPresent([String].self, forKey: .consolidatedProviders) ?? []
        providerRoutingModes = try container.decodeIfPresent([String: String].self, forKey: .providerRoutingModes) ?? [:]
        providerPinnedAccounts = try container.decodeIfPresent([String: String].self, forKey: .providerPinnedAccounts) ?? [:]
        allowFailover = try container.decodeIfPresent(Bool.self, forKey: .allowFailover) ?? true
        cooldownSeconds = try container.decodeIfPresent(Int.self, forKey: .cooldownSeconds) ?? 300
        maxFailoverRetries = try container.decodeIfPresent(Int.self, forKey: .maxFailoverRetries) ?? 2
        autoCheckOnStartupWithHistory = try container.decodeIfPresent(Bool.self, forKey: .autoCheckOnStartupWithHistory) ?? false
        healthCheckInterval = try container.decodeIfPresent(String.self, forKey: .healthCheckInterval) ?? HealthCheckInterval.oneHour.rawValue
        automationTasks = try container.decodeIfPresent([GatewayAutomationTask].self, forKey: .automationTasks) ?? []
        automationRunLogs = try container.decodeIfPresent([GatewayAutomationRunLog].self, forKey: .automationRunLogs) ?? []
        modelCapabilityOverrides = try container.decodeIfPresent([String: GatewayModelCapabilityOverride].self, forKey: .modelCapabilityOverrides) ?? [:]
        allowLanAccess = try container.decodeIfPresent(Bool.self, forKey: .allowLanAccess) ?? false
        let decodedToken = try container.decodeIfPresent(String.self, forKey: .authToken)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let decodedToken, !decodedToken.isEmpty, decodedToken != "tomo-local-token" {
            self.authToken = decodedToken
        } else {
            self.authToken = Self.generateSecureToken()
        }
    }

    public func isProviderConsolidated(_ providerID: String) -> Bool {
        let normalized = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if consolidatedProviders.contains(where: { $0.lowercased() == normalized }) {
            return true
        }
        // Aliases check (e.g. codex/openai, gemini/google)
        if (normalized == "openai" || normalized == "codex") &&
            consolidatedProviders.contains(where: { $0.lowercased() == "openai" || $0.lowercased() == "codex" }) {
            return true
        }
        if (normalized == "google" || normalized == "gemini") &&
            consolidatedProviders.contains(where: { $0.lowercased() == "google" || $0.lowercased() == "gemini" }) {
            return true
        }
        // Backwards compatibility: if consolidatedProviders is empty, fallback to modelConsolidationEnabled
        if consolidatedProviders.isEmpty && modelConsolidationEnabled {
            return true
        }
        return false
    }

    public mutating func setProviderConsolidated(_ providerID: String, enabled: Bool) {
        let normalized = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var current = Set(consolidatedProviders.map { $0.lowercased() })
        // If it was fallbacking to legacy modelConsolidationEnabled, populate current set first
        if consolidatedProviders.isEmpty && modelConsolidationEnabled {
            current = ["openai", "google", "deepseek", "opencode"]
        }
        if enabled {
            current.insert(normalized)
        } else {
            current.remove(normalized)
            if normalized == "openai" { current.remove("codex") }
            if normalized == "codex" { current.remove("openai") }
            if normalized == "google" { current.remove("gemini") }
            if normalized == "gemini" { current.remove("google") }
        }
        self.consolidatedProviders = Array(current).sorted()
        // Synchronize modelConsolidationEnabled as true if any provider is enabled
        self.modelConsolidationEnabled = !self.consolidatedProviders.isEmpty
    }

    public func routingMode(for providerID: String) -> ProviderRoutingMode {
        let normalized = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let modeStr = providerRoutingModes[normalized],
           let mode = ProviderRoutingMode(rawValue: modeStr) {
            return mode
        }
        if (normalized == "openai" || normalized == "codex"),
           let modeStr = providerRoutingModes["openai"] ?? providerRoutingModes["codex"],
           let mode = ProviderRoutingMode(rawValue: modeStr) {
            return mode
        }
        if (normalized == "google" || normalized == "gemini"),
           let modeStr = providerRoutingModes["google"] ?? providerRoutingModes["gemini"],
           let mode = ProviderRoutingMode(rawValue: modeStr) {
            return mode
        }
        return .smooth
    }

    public mutating func setRoutingMode(for providerID: String, mode: ProviderRoutingMode, pinnedAccountId: String? = nil) {
        let normalized = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        providerRoutingModes[normalized] = mode.rawValue
        if normalized == "openai" { providerRoutingModes["codex"] = mode.rawValue }
        if normalized == "codex" { providerRoutingModes["openai"] = mode.rawValue }
        if normalized == "google" { providerRoutingModes["gemini"] = mode.rawValue }
        if normalized == "gemini" { providerRoutingModes["google"] = mode.rawValue }

        if let pinnedAccountId, !pinnedAccountId.isEmpty {
            providerPinnedAccounts[normalized] = pinnedAccountId
            if normalized == "openai" { providerPinnedAccounts["codex"] = pinnedAccountId }
            if normalized == "codex" { providerPinnedAccounts["openai"] = pinnedAccountId }
            if normalized == "google" { providerPinnedAccounts["gemini"] = pinnedAccountId }
            if normalized == "gemini" { providerPinnedAccounts["google"] = pinnedAccountId }
        } else if mode != .pinnedAccount {
            providerPinnedAccounts.removeValue(forKey: normalized)
            if normalized == "openai" { providerPinnedAccounts.removeValue(forKey: "codex") }
            if normalized == "codex" { providerPinnedAccounts.removeValue(forKey: "openai") }
            if normalized == "google" { providerPinnedAccounts.removeValue(forKey: "gemini") }
            if normalized == "gemini" { providerPinnedAccounts.removeValue(forKey: "google") }
        }
    }

    public func pinnedAccountId(for providerID: String) -> String? {
        let normalized = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let id = providerPinnedAccounts[normalized] {
            return id
        }
        if normalized == "openai" || normalized == "codex" {
            return providerPinnedAccounts["openai"] ?? providerPinnedAccounts["codex"]
        }
        if normalized == "google" || normalized == "gemini" {
            return providerPinnedAccounts["google"] ?? providerPinnedAccounts["gemini"]
        }
        return nil
    }
}

public struct GatewaySettingsStorage: @unchecked Sendable {
    public let fileManager: FileManager
    public let fileURL: URL

    public init(fileManager: FileManager = .default, fileURL: URL? = nil) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tomo/gateway-settings.json")
    }

    public func load() -> GatewaySettings {
        let decoder = JSONDecoder()
        guard let data = try? Data(contentsOf: fileURL),
              let settings = try? decoder.decode(GatewaySettings.self, from: data) else {
            let newSettings = GatewaySettings()
            try? save(newSettings)
            return newSettings
        }
        if let rawJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (rawJson["authToken"] as? String)?.isEmpty ?? true || (rawJson["authToken"] as? String) == "tomo-local-token" {
            try? save(settings)
        }
        return settings
    }

    public func save(_ settings: GatewaySettings) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(settings)
        data.append(0x0A)
        try data.write(to: fileURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
