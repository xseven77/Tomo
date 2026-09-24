import AppKit
import Foundation
import Observation
import SQLite3

public enum GatewayNavTab: String, CaseIterable, Identifiable {
    case connect = "模型接入"
    case automation = "自动化"
    case agents = "Agent 接入"
    case overview = "运行概览"
    case analytics = "用量分析"
    case requests = "请求监控"
    case doctor = "网关诊断"
    case logs = "运行日志"

    public var id: String { rawValue }

    public var symbolName: String {
        switch self {
        case .connect: "network"
        case .automation: "clock.arrow.2.circlepath"
        case .agents: "bolt.horizontal.circle"
        case .overview: "gauge.with.needle"
        case .analytics: "chart.xyaxis.line"
        case .requests: "waveform.path.ecg"
        case .doctor: "stethoscope"
        case .logs: "doc.text.magnifyingglass"
        }
    }

    public var subtitle: String {
        switch self {
        case .connect: "管理本地网关服务、已连接供应商账号与全量模型接入"
        case .automation: "编排并管理本地模型定时巡检与自动化计划"
        case .agents: "一键配置并同步 Hermes、Pi 等第三方 Agent 客户端"
        case .overview: "外部 Agent 伴侣工作时长、流量指标与协议中枢拓扑"
        case .analytics: "Token 年度用量热力分布、模型消耗趋势与工具调用统计"
        case .requests: "经本地网关反代的实时请求与流式明细"
        case .doctor: "环回端口、鉴权与上游桥接诊断"
        case .logs: "聚合网关守护与上游错误日志 · 实时追踪与级别/来源筛选"
        }
    }
}

// MARK: - 维度一：本地 Hook Agent 活动与伴侣观测模型
public struct GatewayAgentWorkRow: Identifiable {
    public let id: String
    public let agentName: String
    public let iconName: String
    public let hookPath: String
    public let durationText: String
    public let tasksCount: Int
    public let statusBadge: String
    public let detailText: String
    /// 本地资源名（agent-logos/ 下的 PNG 文件名，不含扩展名）；无真实 logo 时为 nil，回落到 SF Symbol。
    public let logoAsset: String?

    public init(
        id: String,
        agentName: String,
        iconName: String,
        hookPath: String,
        durationText: String,
        tasksCount: Int,
        statusBadge: String,
        detailText: String,
        logoAsset: String? = nil
    ) {
        self.id = id
        self.agentName = agentName
        self.iconName = iconName
        self.hookPath = hookPath
        self.durationText = durationText
        self.tasksCount = tasksCount
        self.statusBadge = statusBadge
        self.detailText = detailText
        self.logoAsset = logoAsset
    }
}

/// 每日 Agent 工作时长数据点（按天采样，x=日期，y=秒数，按 agent 分系列）
public struct GatewayAgentDayPoint: Identifiable, Sendable {
    public var id: String { "\(day)_\(agentID)" }
    public let day: String        // "yyyy-MM-dd"
    public let date: Date
    public let agentID: String
    public let agentName: String
    public let seconds: TimeInterval

    public init(day: String, date: Date, agentID: String, agentName: String, seconds: TimeInterval) {
        self.day = day
        self.date = date
        self.agentID = agentID
        self.agentName = agentName
        self.seconds = seconds
    }
}

// MARK: - 对外暴露的标准模型模型 (Exported Model)
public struct GatewayExportedModel: Identifiable, Hashable {
    public let id: String
    public let modelName: String
    public let sourceBadge: String
    public let sourceBadgeColor: NSColor
    public let capability: String
    public let description: String
    public let isCustom: Bool

    public init(
        id: String,
        modelName: String,
        sourceBadge: String,
        sourceBadgeColor: NSColor,
        capability: String,
        description: String,
        isCustom: Bool = false
    ) {
        self.id = id
        self.modelName = modelName
        self.sourceBadge = sourceBadge
        self.sourceBadgeColor = sourceBadgeColor
        self.capability = capability
        self.description = description
        self.isCustom = isCustom
    }
}

public struct GatewayAccountModelGroup: Identifiable {
    public let id: String
    public let connectionID: ConnectionID?
    public let accountName: String
    public let email: String?
    public let providerTitle: String
    public let iconName: String
    public let authStatus: String
    public let isConnected: Bool
    public let isProxyEnabled: Bool
    public let hasProxyCredential: Bool
    public let isProxyAllowed: Bool
    public let badgeText: String
    public let badgeColor: NSColor
    public let quickConnectTip: String
    public let recommendedModels: [String]
    public let sampleConfigSnippet: String
    public let models: [GatewayExportedModel]

    public init(
        id: String,
        connectionID: ConnectionID? = nil,
        accountName: String,
        email: String? = nil,
        providerTitle: String,
        iconName: String,
        authStatus: String,
        isConnected: Bool,
        isProxyEnabled: Bool = true,
        hasProxyCredential: Bool = true,
        isProxyAllowed: Bool = true,
        badgeText: String,
        badgeColor: NSColor,
        quickConnectTip: String,
        recommendedModels: [String],
        sampleConfigSnippet: String,
        models: [GatewayExportedModel]
    ) {
        self.id = id
        self.connectionID = connectionID
        self.accountName = accountName
        self.email = email
        self.providerTitle = providerTitle
        self.iconName = iconName
        self.authStatus = authStatus
        self.isConnected = isConnected
        self.isProxyEnabled = isProxyEnabled
        self.hasProxyCredential = hasProxyCredential
        self.isProxyAllowed = isProxyAllowed
        self.badgeText = badgeText
        self.badgeColor = badgeColor
        self.quickConnectTip = quickConnectTip
        self.recommendedModels = recommendedModels
        self.sampleConfigSnippet = sampleConfigSnippet
        self.models = models
    }
}

// MARK: - 供应商聚合模块 (Provider Section)
public struct GatewayProviderSection: Identifiable {
    public let id: String
    public let providerTitle: String
    public let subtitle: String
    public let iconName: String
    public let accountGroups: [GatewayAccountModelGroup]

    public init(
        id: String,
        providerTitle: String,
        subtitle: String,
        iconName: String,
        accountGroups: [GatewayAccountModelGroup]
    ) {
        self.id = id
        self.providerTitle = providerTitle
        self.subtitle = subtitle
        self.iconName = iconName
        self.accountGroups = accountGroups
    }

    var brandAsset: BrandAssetID {
        switch id {
        case "openai", "codex": .codex
        case "google", "gemini": .googleGemini
        case "deepseek": .deepSeek
        case "opencode": .openCode
        default: .codex
        }
    }
}

// MARK: - 维度二：Gateway 反代与网络遥测模型
public struct GatewayTelemetryItem: Identifiable {
    public let id: String
    public let title: String
    public let value: String
    public let sourceTag: String
    public let sourceTagColor: NSColor
    public let note: String

    public init(id: String, title: String, value: String, sourceTag: String, sourceTagColor: NSColor, note: String) {
        self.id = id
        self.title = title
        self.value = value
        self.sourceTag = sourceTag
        self.sourceTagColor = sourceTagColor
        self.note = note
    }
}

public struct GatewayRequestRow: Identifiable {
    public let id: String
    public let time: String
    public let agent: String
    public let ingressProtocol: String
    public let modelAlias: String
    public let targetProvider: String
    public let targetModel: String
    public let latencyMs: Int
    public let ttftMs: Int
    public let tokens: Int
    public let fidelity: String
    public let status: String

    public init(
        id: String,
        time: String,
        agent: String,
        ingressProtocol: String,
        modelAlias: String,
        targetProvider: String,
        targetModel: String,
        latencyMs: Int,
        ttftMs: Int,
        tokens: Int,
        fidelity: String,
        status: String
    ) {
        self.id = id
        self.time = time
        self.agent = agent
        self.ingressProtocol = ingressProtocol
        self.modelAlias = modelAlias
        self.targetProvider = targetProvider
        self.targetModel = targetModel
        self.latencyMs = latencyMs
        self.ttftMs = ttftMs
        self.tokens = tokens
        self.fidelity = fidelity
        self.status = status
    }
}

public struct GatewayDoctorCheck: Identifiable {
    public let id: String
    public let title: String
    public let status: String
    public let isSuccess: Bool
    public let detail: String

    public init(id: String, title: String, status: String, isSuccess: Bool, detail: String) {
        self.id = id
        self.title = title
        self.status = status
        self.isSuccess = isSuccess
        self.detail = detail
    }
}

@MainActor
@Observable
public final class GatewayStore {
    public static let shared = GatewayStore()

    public var selectedTab: GatewayNavTab = .connect {
        didSet {
            if oldValue != selectedTab {
                if selectedTab == .connect {
                    Task {
                        await refreshModelHealth()
                        await fetchV1Models()
                    }
                } else if selectedTab == .overview {
                    Task { await refreshTelemetryAnalytics() }
                } else if selectedTab == .analytics {
                    Task { await refreshAnalyticsData() }
                } else if selectedTab == .requests {
                    Task { await refreshRequestsList() }
                } else if selectedTab == .logs {
                    GatewayLogStore.shared.loadIfNeeded()
                }
            }
        }
    }
    public var selectedRequestId: String?

    // ==========================================
    // 维度一：本地 Hook 的 Agent 伴侣与活动数据
    // ==========================================
    private weak var activityStore: CodexActivityStore?
    private weak var companionStatsStore: CompanionStatsStore?
    private let hermesConfigurator: HermesGatewayConfigurator
    private let piConfigurator: PiGatewayConfigurator
    private let dshConfigurator: DSHGatewayConfigurator
    weak var multiAgentSettingsStore: MultiAgentSettingsStore?
    private let agentCatalogDefaults = UserDefaults.standard
    private let hermesCatalogFingerprintKey = "Tomo.hermesCatalogFingerprint"
    private let piCatalogFingerprintKey = "Tomo.piCatalogFingerprint"
    private let dshCatalogFingerprintKey = "Tomo.dshCatalogFingerprint"
    @ObservationIgnored nonisolated(unsafe) private var agentStatusObserver: (any NSObjectProtocol)?

    deinit {
        if let observer = agentStatusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // ==========================================
    // 维度三：网关设置 (Gateway Settings)
    // ==========================================
    public let settingsStorage: GatewaySettingsStorage
    public var gatewaySettings: GatewaySettings {
        didSet {
            persistGatewaySettings()
        }
    }

    /// 触发设置主动落盘
    public func saveGatewaySettings() {
        persistGatewaySettings()
    }

    /// 与网关进程 `MAX_AUTOMATION_RUN_LOGS` 保持一致。
    public static let maxAutomationRunLogs = 300

    /// 网关已空闲多久之后，仍未结束的执行记录才算「丢失了结束事件」。
    ///
    /// 留出宽限时间，避免刚发起巡检、网关还没来得及上报 running 时被误收尾成「已取消」。
    public static let staleAutomationRunGraceSeconds: TimeInterval = 90

    /// 落盘前先与磁盘合并。
    ///
    /// `tomo-gateway` 进程与 App 写的是同一个 `gateway-settings.json`，定时巡检的
    /// `lastRun*` 与 `automationRunLogs` 都由网关写入。这里若直接整份覆盖，App 内存中的
    /// 旧副本就会把这些记录抹掉（历史上“执行日志打开就是空的”正是这个原因之一）。
    private func persistGatewaySettings() {
        var merged = gatewaySettings
        let onDisk = settingsStorage.load()

        if !onDisk.automationRunLogs.isEmpty {
            var logMap: [String: GatewayAutomationRunLog] = [:]
            for log in merged.automationRunLogs {
                logMap[log.id] = log
            }
            for diskLog in onDisk.automationRunLogs {
                if let existing = logMap[diskLog.id] {
                    var mergedLog = existing
                    if diskLog.finishedAt != nil && existing.finishedAt == nil {
                        mergedLog.finishedAt = diskLog.finishedAt
                        mergedLog.isSuccess = diskLog.isSuccess
                        mergedLog.summary = diskLog.summary
                        mergedLog.cancelled = diskLog.cancelled
                    }
                    if (mergedLog.results == nil || mergedLog.results?.isEmpty == true), let diskResults = diskLog.results, !diskResults.isEmpty {
                        mergedLog.results = diskResults
                    }
                    logMap[diskLog.id] = mergedLog
                } else {
                    logMap[diskLog.id] = diskLog
                }
            }
            var logs = Array(logMap.values)
            logs.sort { $0.startedAt < $1.startedAt }
            if logs.count > Self.maxAutomationRunLogs {
                logs = Array(logs.suffix(Self.maxAutomationRunLogs))
            }
            merged.automationRunLogs = logs
        }

        // 磁盘上更晚的一次运行结果优先，避免用内存里的旧状态覆盖网关刚写入的记录。
        if !onDisk.automationTasks.isEmpty {
            for idx in merged.automationTasks.indices {
                guard let diskTask = onDisk.automationTasks.first(where: { $0.id == merged.automationTasks[idx].id }) else { continue }
                if (diskTask.lastRunAt ?? 0) > (merged.automationTasks[idx].lastRunAt ?? 0) {
                    merged.automationTasks[idx].lastRunAt = diskTask.lastRunAt
                    merged.automationTasks[idx].lastRunStatus = diskTask.lastRunStatus
                    merged.automationTasks[idx].lastRunSummary = diskTask.lastRunSummary
                }
            }
        }

        // 若网关进程因额度耗尽自动将路由降级为平滑过渡 (smooth)，保留磁盘上的降级状态。
        if !onDisk.providerRoutingModes.isEmpty {
            for (provider, diskMode) in onDisk.providerRoutingModes {
                if diskMode == ProviderRoutingMode.smooth.rawValue,
                   merged.providerRoutingModes[provider] == ProviderRoutingMode.pinnedAccount.rawValue {
                    merged.providerRoutingModes[provider] = diskMode
                    merged.providerPinnedAccounts.removeValue(forKey: provider)
                }
            }
        }

        try? settingsStorage.save(merged)
    }

    /// 从磁盘同步自动化任务的运行态与执行日志（网关进程会异步写入这些字段）。
    public func reloadAutomationStateFromDisk() {
        let onDisk = settingsStorage.load()
        var updated = gatewaySettings

        if !onDisk.automationRunLogs.isEmpty {
            var logMap: [String: GatewayAutomationRunLog] = [:]
            for log in updated.automationRunLogs {
                logMap[log.id] = log
            }
            for diskLog in onDisk.automationRunLogs {
                if let existing = logMap[diskLog.id] {
                    var mergedLog = existing
                    if diskLog.finishedAt != nil && existing.finishedAt == nil {
                        mergedLog.finishedAt = diskLog.finishedAt
                        mergedLog.isSuccess = diskLog.isSuccess
                        mergedLog.summary = diskLog.summary
                        mergedLog.cancelled = diskLog.cancelled
                    }
                    if (mergedLog.results == nil || mergedLog.results?.isEmpty == true), let diskResults = diskLog.results, !diskResults.isEmpty {
                        mergedLog.results = diskResults
                    }
                    logMap[diskLog.id] = mergedLog
                } else {
                    logMap[diskLog.id] = diskLog
                }
            }
            var logs = Array(logMap.values)
            logs.sort { $0.startedAt < $1.startedAt }
            if logs.count > Self.maxAutomationRunLogs {
                logs = Array(logs.suffix(Self.maxAutomationRunLogs))
            }
            updated.automationRunLogs = logs
        }

        for idx in updated.automationTasks.indices {
            guard let diskTask = onDisk.automationTasks.first(where: { $0.id == updated.automationTasks[idx].id }) else { continue }
            if (diskTask.lastRunAt ?? 0) > (updated.automationTasks[idx].lastRunAt ?? 0) {
                updated.automationTasks[idx].lastRunAt = diskTask.lastRunAt
                updated.automationTasks[idx].lastRunStatus = diskTask.lastRunStatus
                updated.automationTasks[idx].lastRunSummary = diskTask.lastRunSummary
            }
        }

        // 同步网关写入的路由模式降级（例如固定账号额度耗尽自动切为 smooth）
        if onDisk.providerRoutingModes != updated.providerRoutingModes {
            updated.providerRoutingModes = onDisk.providerRoutingModes
        }
        if onDisk.providerPinnedAccounts != updated.providerPinnedAccounts {
            updated.providerPinnedAccounts = onDisk.providerPinnedAccounts
        }

        guard updated != gatewaySettings else { return }
        gatewaySettings = updated
    }

    public var autoCheckOnStartupWithHistory: Bool {
        get { gatewaySettings.autoCheckOnStartupWithHistory }
        set {
            guard gatewaySettings.autoCheckOnStartupWithHistory != newValue else { return }
            gatewaySettings.autoCheckOnStartupWithHistory = newValue
        }
    }

    public var allowLanAccess: Bool {
        get { gatewaySettings.allowLanAccess }
        set {
            guard gatewaySettings.allowLanAccess != newValue else { return }
            gatewaySettings.allowLanAccess = newValue
            if self === GatewayStore.shared {
                GatewaySupervisor.shared.restart()
            }
        }
    }

    public var healthCheckInterval: HealthCheckInterval {
        get {
            HealthCheckInterval(rawValue: gatewaySettings.healthCheckInterval) ?? .oneHour
        }
        set {
            guard gatewaySettings.healthCheckInterval != newValue.rawValue else { return }
            gatewaySettings.healthCheckInterval = newValue.rawValue
        }
    }

    public var isModelConsolidationEnabled: Bool {
        get { gatewaySettings.modelConsolidationEnabled }
        set {
            guard gatewaySettings.modelConsolidationEnabled != newValue else { return }
            gatewaySettings.modelConsolidationEnabled = newValue
            if newValue {
                gatewaySettings.consolidatedProviders = ["openai", "google", "deepseek", "opencode"]
            } else {
                gatewaySettings.consolidatedProviders = []
            }
            Task { [weak self] in
                await self?.syncConfiguredAgentCatalogsIfNeeded()
            }
        }
    }

    public func isProviderConsolidated(_ providerID: String) -> Bool {
        gatewaySettings.isProviderConsolidated(providerID)
    }

    public func setProviderConsolidated(_ providerID: String, enabled: Bool) {
        guard gatewaySettings.isProviderConsolidated(providerID) != enabled else { return }
        gatewaySettings.setProviderConsolidated(providerID, enabled: enabled)
        Task { [weak self] in
            await self?.syncConfiguredAgentCatalogsIfNeeded()
        }
    }

    public func providerRoutingMode(for providerID: String) -> ProviderRoutingMode {
        gatewaySettings.routingMode(for: providerID)
    }

    public func setProviderRoutingMode(_ providerID: String, mode: ProviderRoutingMode, pinnedAccountId: String? = nil) {
        gatewaySettings.setRoutingMode(for: providerID, mode: mode, pinnedAccountId: pinnedAccountId)
        Task { [weak self] in
            await self?.syncConfiguredAgentCatalogsIfNeeded()
        }
    }

    public func providerPinnedAccountId(for providerID: String) -> String? {
        gatewaySettings.pinnedAccountId(for: providerID)
    }

    // ==========================================
    // 自动化任务 (Automation Tasks)
    // ==========================================
    public var automationTasks: [GatewayAutomationTask] {
        get { gatewaySettings.automationTasks }
        set { gatewaySettings.automationTasks = newValue }
    }

    public func addAutomationTask(_ task: GatewayAutomationTask) {
        gatewaySettings.automationTasks.append(task)
    }

    public func updateAutomationTask(_ task: GatewayAutomationTask) {
        if let idx = gatewaySettings.automationTasks.firstIndex(where: { $0.id == task.id }) {
            gatewaySettings.automationTasks[idx] = task
        }
    }

    public func deleteAutomationTask(id: String) {
        gatewaySettings.automationTasks.removeAll(where: { $0.id == id })
    }

    public func toggleAutomationTask(id: String) {
        if let idx = gatewaySettings.automationTasks.firstIndex(where: { $0.id == id }) {
            gatewaySettings.automationTasks[idx].enabled.toggle()
        }
    }

    public func runAutomationTaskNow(_ task: GatewayAutomationTask) async -> (success: Bool, message: String) {
        let startedAt = Int64(Date().timeIntervalSince1970)
        let res = await triggerModelCheck(
            providers: task.providers.isEmpty ? nil : task.providers,
            accountIds: task.allAccounts ? nil : task.accountIds,
            allAccounts: task.allAccounts
        )
        if res.success {
            if let idx = gatewaySettings.automationTasks.firstIndex(where: { $0.id == task.id }) {
                gatewaySettings.automationTasks[idx].lastRunAt = startedAt
                gatewaySettings.automationTasks[idx].lastRunStatus = "running"
            }
            recordAutomationRunStart(taskId: task.id, taskName: task.name, taskType: task.taskType, startedAt: startedAt)
        }
        return res
    }

    /// 记录一次自动化任务开始执行（新建一条进行中的 RunLog），返回该记录的 id。
    @discardableResult
    public func recordAutomationRunStart(taskId: String, taskName: String, taskType: AutomationTaskType, startedAt: Int64) -> String {
        var logs = gatewaySettings.automationRunLogs
        let log = GatewayAutomationRunLog(taskId: taskId, taskName: taskName, taskType: taskType, startedAt: startedAt)
        logs.append(log)
        // 最多保留最近 300 条，避免设置无限膨胀
        if logs.count > Self.maxAutomationRunLogs {
            logs = Array(logs.suffix(Self.maxAutomationRunLogs))
        }
        gatewaySettings.automationRunLogs = logs
        return log.id
    }

    /// 结束一次自动化任务（按 taskId 补全最近一条进行中的 RunLog 的结束时点、结果与摘要）。
    ///
    /// - Parameter cancelled: 用户主动取消。取消不算失败，但同样必须写入结束时点，
    ///   否则执行日志会永远停在「进行中」。
    public func finishAutomationRun(
        taskId: String,
        finishedAt: Int64,
        isSuccess: Bool?,
        summary: String?,
        cancelled: Bool = false,
        results: [GatewayModelCheckResult]? = nil
    ) {
        var logs = gatewaySettings.automationRunLogs
        guard let idx = logs.lastIndex(where: { $0.taskId == taskId && $0.isUnfinished }) else { return }
        logs[idx].finishedAt = finishedAt
        logs[idx].isSuccess = isSuccess
        logs[idx].summary = summary
        logs[idx].cancelled = cancelled ? true : nil
        if let results, !results.isEmpty {
            logs[idx].results = results
        }
        gatewaySettings.automationRunLogs = logs
    }

    /// 把仍停在「进行中」的执行记录统一收尾（用于取消巡检与历史遗留记录清理）。
    ///
    /// 取消巡检时网关可能还会上报一段时间的 `running`，而 App 退出、进程被杀等情况
    /// 根本收不到结束事件：只要记录没有结束时点，它就会永远显示「进行中」。
    ///
    /// - Parameter minimumAge: 只收尾开始时间早于 `now - minimumAge` 的记录，
    ///   避免刚发起、网关还没来得及上报 running 的巡检被误判为已取消。
    @discardableResult
    public func markUnfinishedAutomationRunsCancelled(
        summary: String = "已取消",
        minimumAge: TimeInterval = 0
    ) -> Int {
        var logs = gatewaySettings.automationRunLogs
        let now = Int64(Date().timeIntervalSince1970)
        var cancelledTaskIds: Set<String> = []
        var count = 0

        for idx in logs.indices where logs[idx].isUnfinished {
            if minimumAge > 0, Double(now - logs[idx].startedAt) < minimumAge { continue }
            logs[idx].finishedAt = max(now, logs[idx].startedAt)
            logs[idx].isSuccess = false
            logs[idx].cancelled = true
            logs[idx].summary = summary
            cancelledTaskIds.insert(logs[idx].taskId)
            count += 1
        }

        guard count > 0 else { return 0 }
        gatewaySettings.automationRunLogs = logs
        for idx in gatewaySettings.automationTasks.indices
        where cancelledTaskIds.contains(gatewaySettings.automationTasks[idx].id) {
            gatewaySettings.automationTasks[idx].lastRunStatus = "cancelled"
            gatewaySettings.automationTasks[idx].lastRunSummary = summary
        }
        return count
    }

    // Agent status is discovered off the main actor when the Agents page is
    // opened. Never invoke `hermes config get` from a SwiftUI body: it starts
    // a process synchronously and can block a single render several times.
    public private(set) var hermesAgentInstalled = false
    public private(set) var hermesAgentConfigured = false
    public private(set) var hermesLanBypassConfigured = false
    public private(set) var piAgentInstalled = false
    public private(set) var piAgentConfigured = false
    public private(set) var dshAgentInstalled = false
    public private(set) var dshAgentConfigured = false
    /// True when a `TOMO_GATEWAY_TOKEN` in the process environment shadows
    /// the token in `~/.dsh/.credentials.yaml`, which DSH resolves *after* the
    /// environment and cannot be overridden from inside a process.
    public private(set) var dshCredentialShadowed = false
    /// Cached so a SwiftUI body never reads the connection registry on render.
    public private(set) var dshAvailableModelCount = 0
    public private(set) var isRefreshingAgentIntegrationStatus = false
    public private(set) var hasLoadedAgentIntegrationStatus = false

    // ==========================================
    // 维度二：Gateway 本地反代与持久化遥测数据
    // ==========================================
    public private(set) var totalRequests: Int = 0
    public private(set) var totalInputTokens: Int = 0
    public private(set) var totalOutputTokens: Int = 0
    public private(set) var totalToolCalls: Int = 0

    public private(set) var requestsList: [GatewayRequestRow] = []

    // 遥测分析与筛选状态
    public var selectedDateRange: GatewayDateRange = .today {
        didSet {
            requestsCurrentPage = 1
            Task { await refreshSelectedTabData() }
        }
    }
    public var customStartDate: Date = Calendar.current.date(byAdding: .hour, value: -1, to: Date()) ?? Date()
    public var customEndDate: Date = Date()
    public var showsCustomDatePicker: Bool = false

    public var selectedMetricTab: GatewayMetricTab = .tokens
    public var selectedBreakdownDimension: GatewayBreakdownDimension = .model {
        didSet {
            guard selectedTab == .overview else { return }
            Task { await refreshBreakdown() }
        }
    }

    public var filterAgent: String? = nil {
        didSet {
            requestsCurrentPage = 1
            Task { await refreshSelectedTabData() }
        }
    }
    public var filterProvider: String? = nil {
        didSet {
            requestsCurrentPage = 1
            Task { await refreshSelectedTabData() }
        }
    }
    public var filterAccount: String? = nil {
        didSet {
            requestsCurrentPage = 1
            Task { await refreshSelectedTabData() }
        }
    }
    public var filterModel: String? = nil {
        didSet {
            requestsCurrentPage = 1
            Task { await refreshSelectedTabData() }
        }
    }

    public private(set) var telemetrySummary: GatewayTelemetrySummary = .zero
    public private(set) var timeseriesBuckets: [GatewayTimeseriesBucket] = []
    public private(set) var breakdownItems: [GatewayBreakdownItem] = []
    public private(set) var detailedRequestsList: [GatewayTelemetryEventDetail] = []
    public private(set) var isTelemetryLoading: Bool = false
    public private(set) var isSummaryLoading: Bool = false
    public private(set) var isTimeseriesLoading: Bool = false
    public private(set) var isBreakdownLoading: Bool = false
    public private(set) var isRequestsLoading: Bool = false

    // 用量分析 (Analytics) 专属状态
    public private(set) var heatmapCells: [GatewayHeatmapCell] = []
    public private(set) var heatmapSummary: GatewayHeatmapSummary = .zero
    public private(set) var availableAnalyticsYears: [Int] = [Calendar.current.component(.year, from: Date())]
    /// 0 表示“滚动一年 (过去 365 天)”，大于 0 表示具体自然年份 (如 2026, 2025)
    public var selectedHeatmapYear: Int = 0 {
        didSet {
            if oldValue != selectedHeatmapYear {
                Task { await refreshAnalyticsData() }
            }
        }
    }
    public var selectedAnalyticsYear: Int {
        get { selectedHeatmapYear }
        set { selectedHeatmapYear = newValue }
    }
    public private(set) var modelTimeseriesPoints: [GatewayModelTimeseriesPoint] = []
    public private(set) var providerTimeseriesPoints: [GatewayModelTimeseriesPoint] = []
    public private(set) var accountTimeseriesPoints: [GatewayModelTimeseriesPoint] = []
    public private(set) var agentTimeseriesPoints: [GatewayModelTimeseriesPoint] = []
    public private(set) var toolCallsTimeseriesPoints: [GatewayModelTimeseriesPoint] = []
    public private(set) var analyticsTokenComposition: GatewayTokenComposition = .zero
    public private(set) var analyticsModelRankings: [GatewayModelRankingItem] = []
    public private(set) var analyticsProviderRankings: [GatewayProviderRankingItem] = []
    public private(set) var analyticsAccountRankings: [GatewayAccountRankingItem] = []
    public private(set) var availableAnalyticsProviders: [String] = []
    public private(set) var analyticsLatencyRankings: [GatewayLatencyRankingItem] = []
    public private(set) var analyticsClientRankings: [GatewayClientRankingItem] = []
    public private(set) var isAnalyticsLoading: Bool = false
    public var analyticsGrouping: String = "model" // "model", "provider", "account", "surface"
    public var analyticsMetricMode: GatewayAnalyticsMetricMode = .tokens // 默认 Tokens 为纵坐标，支持切换为轮次
    public var analyticsChartStyle: GatewayAnalyticsChartStyle = .area // 趋势图呈现方式：面积曲线 / 堆叠柱状
    public var analyticsRankingDimension: GatewayAnalyticsRankingDimension = .model
    public var selectedAnalyticsProviderFilter: String? = nil
    public var analyticsDaysRange: Int = 7 // 7, 30, or 90

    // 模型健康巡检状态
    public var modelHealthResponse: GatewayModelHealthResponse?
    public var isModelHealthLoading: Bool = false
    public var isModelCheckRunning: Bool = false
    public var isCancellingModelCheck: Bool = false
    public var modelCheckStatus: GatewayModelCheckJobStatus?
    public var checkingAccountScopes: Set<String> = []
    /// 巡检结束时的完成反馈（由视图 onToast 消费后清空）
    public var modelCheckFinishMessage: String?
    public var modelCheckFinishSuccess: Bool = true
    public var modelCheckFinishToken: UUID?
    private var modelCheckPollingTask: Task<Void, Never>?

    // 最终 /v1/models 接口已发布模型列表
    public var v1Models: [GatewayV1ModelItem] = []
    public var isV1ModelsLoading: Bool = false
    public var v1ModelsErrorMessage: String? = nil
    public var v1ModelsLastFetchedAt: Date? = nil

    // 分页状态管理
    public var requestsCurrentPage: Int = 1 {
        didSet {
            if oldValue != requestsCurrentPage, selectedTab == .requests {
                Task { await refreshRequestsList() }
            }
        }
    }
    public var requestsPageSize: Int = 20 {
        didSet {
            if oldValue != requestsPageSize {
                requestsCurrentPage = 1
                if selectedTab == .requests {
                    Task { await refreshRequestsList() }
                }
            }
        }
    }
    public private(set) var requestsTotalCount: Int64 = 0

    public var requestsTotalPages: Int {
        guard requestsTotalCount > 0 else { return 1 }
        return max(1, Int(ceil(Double(requestsTotalCount) / Double(requestsPageSize))))
    }

    public func goToPage(_ page: Int) {
        let target = max(1, min(page, requestsTotalPages))
        if target != requestsCurrentPage {
            requestsCurrentPage = target
        }
    }

    public func nextPage() {
        if requestsCurrentPage < requestsTotalPages {
            requestsCurrentPage += 1
        }
    }

    public func prevPage() {
        if requestsCurrentPage > 1 {
            requestsCurrentPage -= 1
        }
    }

    public func setPageSize(_ size: Int) {
        guard size > 0, size != requestsPageSize else { return }
        requestsPageSize = size
    }

    // ==========================================
    // 维度三：请求流表格列自定义显示设置
    // ==========================================
    public static let visibleColumnsDefaultsKey = "tomo.gateway.visibleColumns"

    public var isColumnSettingsPresented: Bool = false

    public var visibleColumns: Set<GatewayRequestColumn> = {
        if let saved = UserDefaults.standard.stringArray(forKey: "tomo.gateway.visibleColumns") {
            let cols = saved.compactMap { GatewayRequestColumn(rawValue: $0) }
            if !cols.isEmpty {
                return Set(cols)
            }
        }
        return Set(GatewayRequestColumn.defaultColumns)
    }() {
        didSet {
            let rawValues = Array(visibleColumns.map(\.rawValue))
            UserDefaults.standard.set(rawValues, forKey: Self.visibleColumnsDefaultsKey)
        }
    }

    public var orderedVisibleColumns: [GatewayRequestColumn] {
        GatewayRequestColumn.allCases.filter { visibleColumns.contains($0) }
    }

    public func isColumnVisible(_ col: GatewayRequestColumn) -> Bool {
        visibleColumns.contains(col)
    }

    public func toggleColumn(_ col: GatewayRequestColumn) {
        if visibleColumns.contains(col) {
            if visibleColumns.count > 1 {
                visibleColumns.remove(col)
            }
        } else {
            visibleColumns.insert(col)
        }
    }

    public func setColumnVisible(_ col: GatewayRequestColumn, isVisible: Bool) {
        if isVisible {
            visibleColumns.insert(col)
        } else {
            if visibleColumns.count > 1 {
                visibleColumns.remove(col)
            }
        }
    }

    public func selectAllColumns() {
        visibleColumns = Set(GatewayRequestColumn.allCases)
    }

    public func resetColumnsToDefault() {
        visibleColumns = Set(GatewayRequestColumn.defaultColumns)
    }

    public func setCustomPreset(hours: Int) {
        let now = Date()
        let start = Calendar.current.date(byAdding: .hour, value: -hours, to: now) ?? now
        applyCustomDateRange(start: start, end: now)
    }

    public func setCustomPreset(days: Int) {
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        applyCustomDateRange(start: start, end: now)
    }

    public func applyCustomDateRange(start: Date, end: Date) {
        self.customStartDate = start
        self.customEndDate = end
        self.selectedDateRange = .custom
        self.requestsCurrentPage = 1
    }

    // 用户自定义或额外添加的透传模型
    private var customModelsByGroup: [String: [String]] = [:]

    /// Bumped each time an account proxy is toggled; `@Observable` tracks this
    /// so `accountModelGroups` / `providerSections` recompute automatically.
    public private(set) var proxyEnabledVersion: Int = 0

    /// Signals the Gateway UI to recompute `accountModelGroups`.
    /// Disk persistence is handled by `MultiAgentSettingsStore.toggleConnectionProxyEnabled`.
    public func toggleConnectionProxy(id: ConnectionID) {
        proxyEnabledVersion &+= 1
    }

    public init(settingsStorage: GatewaySettingsStorage = GatewaySettingsStorage()) {
        self.settingsStorage = settingsStorage
        self.gatewaySettings = settingsStorage.load()
        self.hermesConfigurator = HermesGatewayConfigurator()
        self.piConfigurator = PiGatewayConfigurator()
        self.dshConfigurator = DSHGatewayConfigurator()
        loadCustomModels()
        loadCachedModelHealth()
        loadCachedV1Models()
        registerAgentStatusObserver()
        if modelHealthResponse != nil {
            Task { [weak self] in
                await self?.syncConfiguredAgentCatalogsIfNeeded()
            }
        }
    }

    init(
        activityStore: CodexActivityStore? = nil,
        companionStatsStore: CompanionStatsStore? = nil,
        hermesConfigurator: HermesGatewayConfigurator = HermesGatewayConfigurator(),
        piConfigurator: PiGatewayConfigurator = PiGatewayConfigurator(),
        dshConfigurator: DSHGatewayConfigurator = DSHGatewayConfigurator(),
        settingsStorage: GatewaySettingsStorage = GatewaySettingsStorage()
    ) {
        self.activityStore = activityStore
        self.companionStatsStore = companionStatsStore
        self.hermesConfigurator = hermesConfigurator
        self.piConfigurator = piConfigurator
        self.dshConfigurator = dshConfigurator
        self.settingsStorage = settingsStorage
        self.gatewaySettings = settingsStorage.load()
        loadCustomModels()
        loadCachedModelHealth()
        loadCachedV1Models()
        registerAgentStatusObserver()
        if modelHealthResponse != nil {
            Task { [weak self] in
                await self?.syncConfiguredAgentCatalogsIfNeeded()
            }
        }
    }

    private func registerAgentStatusObserver() {
        agentStatusObserver = NotificationCenter.default.addObserver(
            forName: .agentIntegrationStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, (note.object as? AnyObject) !== self else { return }
            Task { @MainActor [weak self] in
                await self?.refreshAgentIntegrationStatus(notifyPeers: false)
            }
        }
    }

    private func loadCustomModels() {
        if let saved = UserDefaults.standard.dictionary(forKey: "gateway.customModels") as? [String: [String]] {
            self.customModelsByGroup = saved
        }
    }

    private func persistCustomModels() {
        UserDefaults.standard.set(customModelsByGroup, forKey: "gateway.customModels")
    }

    public func addCustomModel(_ modelName: String, toGroupId groupId: String) {
        let trimmed = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = customModelsByGroup[groupId] ?? []
        if !list.contains(trimmed) {
            list.append(trimmed)
            customModelsByGroup[groupId] = list
            persistCustomModels()
        }
    }

    public func removeCustomModel(_ modelName: String, fromGroupId groupId: String) {
        guard var list = customModelsByGroup[groupId] else { return }
        list.removeAll { $0 == modelName }
        customModelsByGroup[groupId] = list
        persistCustomModels()
    }

    func bind(
        activityStore: CodexActivityStore,
        companionStatsStore: CompanionStatsStore
    ) {
        self.activityStore = activityStore
        self.companionStatsStore = companionStatsStore
    }

    public func updateGatewayMetrics(
        totalRequests: Int,
        inputTokens: Int,
        outputTokens: Int,
        toolCalls: Int
    ) {
        self.totalRequests = totalRequests
        self.totalInputTokens = inputTokens
        self.totalOutputTokens = outputTokens
        self.totalToolCalls = toolCalls
    }

    public func recordRequest(_ row: GatewayRequestRow) {
        requestsList.insert(row, at: 0)
        if requestsList.count > 50 {
            requestsList.removeLast()
        }
    }

    public func setRequestsList(_ rows: [GatewayRequestRow]) {
        self.requestsList = rows
    }

    // ==========================================
    // 持久化遥测接口请求与更新
    // ==========================================

    private func buildQueryItems(additional: [String: String] = [:]) -> [URLQueryItem] {
        let (from, to) = selectedDateRange.calculateTimestamps(customStart: customStartDate, customEnd: customEndDate)
        let tz = TimeZone.current.identifier
        var items = [
            URLQueryItem(name: "from", value: "\(from)"),
            URLQueryItem(name: "to", value: "\(to)"),
            URLQueryItem(name: "timezone", value: tz),
        ]
        if let agent = filterAgent, !agent.isEmpty, agent != "全部 Agent" {
            items.append(URLQueryItem(name: "agent", value: agent))
        }
        if let provider = filterProvider, !provider.isEmpty, provider != "全部供应商" {
            items.append(URLQueryItem(name: "provider", value: provider))
        }
        if let account = filterAccount, !account.isEmpty, account != "全部账号" {
            items.append(URLQueryItem(name: "account", value: account))
        }
        if let model = filterModel, !model.isEmpty, model != "全部模型" {
            items.append(URLQueryItem(name: "model", value: model))
        }
        for (k, v) in additional {
            items.append(URLQueryItem(name: k, value: v))
        }
        return items
    }

    public func refreshTelemetryAnalytics() async {
        guard !isTelemetryLoading else { return }
        isTelemetryLoading = true
        defer { isTelemetryLoading = false }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.refreshSummary() }
            group.addTask { await self.refreshTimeseries() }
            group.addTask { await self.refreshBreakdown() }
            group.addTask { await self.refreshRequestsList() }
        }
    }

    /// Data is intentionally lazy: a page owns its own requests.  Switching
    /// to Connect, Agents or Doctor never starts telemetry work in the
    /// background, and changing filters only refreshes the page being viewed.
    private func refreshSelectedTabData() async {
        switch selectedTab {
        case .overview:
            await refreshTelemetryAnalytics()
        case .analytics:
            await refreshAnalyticsData()
        case .requests:
            await refreshRequestsList()
        case .connect, .agents, .doctor, .automation, .logs:
            break
        }
    }

    public func refreshSummary() async {
        guard !isSummaryLoading else { return }
        isSummaryLoading = true
        defer { isSummaryLoading = false }

        guard let base = GatewaySupervisor.shared.endpoint else { return }
        var components = URLComponents(url: base.appendingPathComponent("telemetry/summary"), resolvingAgainstBaseURL: false)
        components?.queryItems = buildQueryItems()
        guard let url = components?.url else { return }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(localToken)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 3

        do {
            let (data, _) = try await URLSession.loopbackDirect.data(for: req)
            let decoder = JSONDecoder()
            let summary = try decoder.decode(GatewayTelemetrySummary.self, from: data)
            self.telemetrySummary = summary
            self.updateGatewayMetrics(
                totalRequests: Int(summary.totalRequests),
                inputTokens: Int(summary.totalInputTokens),
                outputTokens: Int(summary.totalOutputTokens),
                toolCalls: Int(summary.toolCallsCount)
            )
        } catch {
            print("[GatewayStore] refreshSummary error: \(error)")
        }
    }

    public func refreshTimeseries() async {
        guard !isTimeseriesLoading else { return }
        isTimeseriesLoading = true
        defer { isTimeseriesLoading = false }

        guard let base = GatewaySupervisor.shared.endpoint else { return }
        var components = URLComponents(url: base.appendingPathComponent("telemetry/timeseries"), resolvingAgainstBaseURL: false)
        let (from, to) = selectedDateRange.calculateTimestamps(customStart: customStartDate, customEnd: customEndDate)
        let durationMs = max(0, to - from)

        let interval: String
        switch selectedDateRange {
        case .last10Minutes:
            interval = "minute"
        case .today, .yesterday:
            interval = "hour"
        case .last7Days, .last30Days:
            interval = "day"
        case .custom:
            if durationMs <= 3600 * 1000 {
                interval = "minute"
            } else if durationMs <= 48 * 3600 * 1000 {
                interval = "hour"
            } else if durationMs <= 60 * 86400 * 1000 {
                interval = "day"
            } else {
                interval = "week"
            }
        }

        components?.queryItems = buildQueryItems(additional: ["interval": interval, "metric": selectedMetricTab.rawValue])
        guard let url = components?.url else { return }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(localToken)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 3

        do {
            let (data, _) = try await URLSession.loopbackDirect.data(for: req)
            let decoder = JSONDecoder()
            let resp = try decoder.decode(GatewayTimeseriesResponse.self, from: data)
            self.timeseriesBuckets = resp.buckets
        } catch {
            print("[GatewayStore] refreshTimeseries error: \(error)")
        }
    }

    public func refreshBreakdown() async {
        guard !isBreakdownLoading else { return }
        isBreakdownLoading = true
        defer { isBreakdownLoading = false }

        guard let base = GatewaySupervisor.shared.endpoint else { return }
        var components = URLComponents(url: base.appendingPathComponent("telemetry/breakdown"), resolvingAgainstBaseURL: false)
        components?.queryItems = buildQueryItems(additional: ["dimension": selectedBreakdownDimension.apiDimension])
        guard let url = components?.url else { return }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(localToken)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 3

        do {
            let (data, _) = try await URLSession.loopbackDirect.data(for: req)
            let decoder = JSONDecoder()
            let resp = try decoder.decode(GatewayBreakdownResponse.self, from: data)
            self.breakdownItems = resp.items
        } catch {
            print("[GatewayStore] refreshBreakdown error: \(error)")
        }
    }

    public func refreshRequestsList() async {
        guard !isRequestsLoading else { return }
        isRequestsLoading = true
        defer { isRequestsLoading = false }

        guard let base = GatewaySupervisor.shared.endpoint else { return }
        var components = URLComponents(url: base.appendingPathComponent("telemetry/requests"), resolvingAgainstBaseURL: false)
        let limit = requestsPageSize
        let offset = max(0, (requestsCurrentPage - 1) * requestsPageSize)
        components?.queryItems = buildQueryItems(additional: [
            "limit": "\(limit)",
            "offset": "\(offset)"
        ])
        guard let url = components?.url else { return }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(localToken)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 3

        do {
            let (data, _) = try await URLSession.loopbackDirect.data(for: req)
            let decoder = JSONDecoder()
            let resp = try decoder.decode(GatewayRequestsResponse.self, from: data)
            self.detailedRequestsList = resp.items
            self.requestsTotalCount = resp.total
        } catch {
            print("[GatewayStore] refreshRequestsList error: \(error)")
        }
    }

    // MARK: - 模型巡检历史持久化 (Model Health Cache Persistence)
    private static var modelHealthCacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tomo/gateway-model-health-cache.json")
    }

    public func loadCachedModelHealth() {
        let url = Self.modelHealthCacheURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let resp = try decoder.decode(GatewayModelHealthResponse.self, from: data)
            self.modelHealthResponse = resp
            if let job = resp.job {
                self.modelCheckStatus = GatewayModelCheckJobStatus(
                    running: false,
                    scope: job.scope,
                    done: job.done,
                    total: job.total,
                    current: "",
                    startedAt: job.startedAt,
                    lastFinishedAt: job.lastFinishedAt,
                    lastSummary: job.lastSummary
                )
                self.isModelCheckRunning = false
                self.checkingAccountScopes.removeAll()
            }
        } catch {
            print("[GatewayStore] loadCachedModelHealth error: \(error)")
        }
    }

    public func persistModelHealth(_ resp: GatewayModelHealthResponse) {
        let url = Self.modelHealthCacheURL
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            let data = try encoder.encode(resp)
            let parent = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[GatewayStore] persistModelHealth error: \(error)")
        }
    }

    // MARK: - /v1/models 缓存持久化与动态拉取
    public static var v1ModelsCacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tomo/gateway-v1-models-cache.json")
    }

    public func loadCachedV1Models() {
        let url = Self.v1ModelsCacheURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let resp = try decoder.decode(GatewayV1ModelsResponse.self, from: data)
            self.v1Models = resp.data
        } catch {
            print("[GatewayStore] loadCachedV1Models error: \(error)")
        }
    }

    public func persistV1Models(_ items: [GatewayV1ModelItem]) {
        let url = Self.v1ModelsCacheURL
        do {
            let resp = GatewayV1ModelsResponse(object: "list", data: items)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            let data = try encoder.encode(resp)
            let parent = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[GatewayStore] persistV1Models error: \(error)")
        }
    }

    public func fetchV1Models() async {
        guard let base = GatewaySupervisor.shared.endpoint else { return }
        let localToken = GatewaySupervisor.shared.localToken
        let url = base.appendingPathComponent("v1/models")
        var req = URLRequest(url: url)
        if !localToken.isEmpty {
            req.setValue("Bearer \(localToken)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 6

        isV1ModelsLoading = true
        defer { isV1ModelsLoading = false }

        do {
            let (data, response) = try await URLSession.loopbackDirect.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                let decoder = JSONDecoder()
                let resp = try decoder.decode(GatewayV1ModelsResponse.self, from: data)
                self.v1Models = resp.data
                self.v1ModelsErrorMessage = nil
                self.v1ModelsLastFetchedAt = Date()
                self.persistV1Models(resp.data)
            } else if let http = response as? HTTPURLResponse {
                self.v1ModelsErrorMessage = "HTTP \(http.statusCode)"
            }
        } catch {
            print("[GatewayStore] fetchV1Models error: \(error)")
            self.v1ModelsErrorMessage = error.localizedDescription
        }
    }

    // MARK: - 模型健康巡检 (Model Health Check)
    public func refreshModelHealth() async {
        guard let base = GatewaySupervisor.shared.endpoint else { return }
        let localToken = GatewaySupervisor.shared.localToken
        let url = base.appendingPathComponent("v1/models/all")
        var req = URLRequest(url: url)
        req.setValue("Bearer \(localToken)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 6

        isModelHealthLoading = true
        defer { isModelHealthLoading = false }

        do {
            let (data, response) = try await URLSession.loopbackDirect.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                let decoder = JSONDecoder()
                let resp = try decoder.decode(GatewayModelHealthResponse.self, from: data)
                self.modelHealthResponse = resp
                self.persistModelHealth(resp)
                if let job = resp.job {
                    // 被动刷新不弹「完成/已取消」提示，但仍要收尾残留的「进行中」记录。
                    self.applyModelCheckJobStatus(job, allowFinishFeedback: false)
                }
                // When health state refreshes, sync any configured agents (Hermes/Pi) so broken models are removed
                await self.syncConfiguredAgentCatalogsIfNeeded()
                await self.fetchV1Models()
            }
        } catch {
            print("[GatewayStore] refreshModelHealth error: \(error)")
        }
    }

    public func pollModelCheckStatus() async {
        guard let base = GatewaySupervisor.shared.endpoint else { return }
        let localToken = GatewaySupervisor.shared.localToken
        let url = base.appendingPathComponent("internal/model-check/status")
        var req = URLRequest(url: url)
        req.setValue("Bearer \(localToken)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 3

        do {
            let (data, response) = try await URLSession.loopbackDirect.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                let decoder = JSONDecoder()
                let status = try decoder.decode(GatewayModelCheckJobStatus.self, from: data)
                self.applyModelCheckJobStatus(status)
            }
        } catch {
            print("[GatewayStore] pollModelCheckStatus error: \(error)")
        }
    }

    public func updateModelCheckJobStatus(from dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let status = try? JSONDecoder().decode(GatewayModelCheckJobStatus.self, from: data) else {
            return
        }
        self.applyModelCheckJobStatus(status)
    }

    /// 巡检状态的唯一入口：HTTP 轮询与网关指标推送都汇聚到这里。
    ///
    /// 历史上这两条路径各写一份收尾逻辑，取消巡检时其中一条把本地状态提前置为 idle，
    /// 于是收尾代码再也没被执行 —— 执行日志里的记录就永远停在「进行中」。
    ///
    /// - Parameter allowFinishFeedback: 是否允许弹出「巡检完成/已取消」提示。
    ///   被动刷新（进入页面同步状态）不弹，避免莫名出现提示。
    private func applyModelCheckJobStatus(
        _ status: GatewayModelCheckJobStatus,
        allowFinishFeedback: Bool = true
    ) {
        self.modelCheckStatus = status
        let wasRunning = self.isModelCheckRunning
        self.isModelCheckRunning = status.running

        if status.running {
            self.checkingAccountScopes = [status.scope]
            if modelCheckPollingTask == nil {
                self.startPollingModelCheckStatus()
            }
            return
        }

        self.checkingAccountScopes.removeAll()

        // 网关已确认空闲：收尾所有还没结束的执行记录。
        if wasRunning {
            self.settleAutomationRunsForFinishedJob(status)
        }
        self.repairStaleAutomationRuns()

        guard wasRunning, allowFinishFeedback else { return }

        self.emitModelCheckFinishMessage(status)
        Task { [weak self] in
            await self?.refreshModelHealth()
        }
    }

    /// 巡检刚结束时收尾执行记录与自动化任务状态（含「已取消」）。
    private func settleAutomationRunsForFinishedJob(_ status: GatewayModelCheckJobStatus) {
        let summary = status.lastSummary
        let isCancelled = summary?.cancelled == true
        let finishedAt = status.lastFinishedAt ?? Int64(Date().timeIntervalSince1970)

        let finalStatus: String
        let finalSummary: String?
        if let summary {
            if isCancelled {
                finalStatus = "cancelled"
                finalSummary = "\(GatewayAutomationRunLog.cancelledSummaryPrefix) · 可用 \(summary.available) · 异常 \(summary.error)"
            } else {
                // 与网关 `summarize_job_result` 保持一致
                finalStatus = (summary.available > 0 || summary.error == 0) ? "success" : "failed"
                finalSummary = "可用 \(summary.available) · 异常 \(summary.error)"
            }
        } else {
            finalStatus = "success"
            finalSummary = nil
        }

        // 若有自动化任务之前被标记为 running，更新其最终运行状态
        for idx in gatewaySettings.automationTasks.indices {
            guard gatewaySettings.automationTasks[idx].lastRunStatus == "running" else { continue }
            gatewaySettings.automationTasks[idx].lastRunStatus = finalStatus
            gatewaySettings.automationTasks[idx].lastRunSummary = finalSummary
            finishAutomationRun(
                taskId: gatewaySettings.automationTasks[idx].id,
                finishedAt: finishedAt,
                isSuccess: finalStatus == "success",
                summary: finalSummary,
                cancelled: isCancelled,
                results: status.results.isEmpty ? nil : status.results
            )
        }
    }

    /// 网关空闲却仍停在「进行中」的执行记录，属于丢失了结束事件的历史数据。
    ///
    /// 触发场景：取消巡检后 App 被关闭、网关重启、状态推送丢失；以及修复前遗留的旧记录。
    /// 这些记录永远不会再收到结束事件，因此在网关确认空闲且超过宽限期后按「已取消」收尾，
    /// 否则执行日志会一直显示「进行中」。
    private func repairStaleAutomationRuns() {
        markUnfinishedAutomationRunsCancelled(
            summary: "\(GatewayAutomationRunLog.cancelledSummaryPrefix) · 未记录到结束事件",
            minimumAge: Self.staleAutomationRunGraceSeconds
        )
    }

    /// 巡检结束反馈：生成完成/取消提示，交由视图消费。
    private func emitModelCheckFinishMessage(_ status: GatewayModelCheckJobStatus) {
        let summary = status.lastSummary
        // 网关在取消的巡检摘要里写明 cancelled；只有拿不到摘要时才退回「进度未跑满」的粗略判断。
        let isCancelled = summary?.cancelled == true || (summary == nil && status.done < status.total)
        if status.scope == "all" {
            if isCancelled {
                guard let summary else {
                    self.modelCheckFinishMessage = "巡检已取消"
                    self.modelCheckFinishSuccess = false
                    self.modelCheckFinishToken = UUID()
                    return
                }
                self.modelCheckFinishMessage = "巡检已取消（已完成 \(summary.total - summary.skipped - summary.available - summary.unavailable - summary.error)/\(summary.total)）"
                self.modelCheckFinishSuccess = false
            } else if let summary {
                self.modelCheckFinishMessage = "巡检完成：可用 \(summary.available) · 不可用 \(summary.unavailable) · 异常 \(summary.error) · 跳过 \(summary.skipped)"
                self.modelCheckFinishSuccess = summary.available > 0
            } else {
                self.modelCheckFinishMessage = "巡检完成"
                self.modelCheckFinishSuccess = true
            }
        } else {
            if isCancelled {
                self.modelCheckFinishMessage = "该账号巡检已取消"
                self.modelCheckFinishSuccess = false
            } else if let summary {
                self.modelCheckFinishMessage = "该账号巡检完成：可用 \(summary.available) · 不可用 \(summary.unavailable) · 异常 \(summary.error)"
                self.modelCheckFinishSuccess = summary.available > 0
            } else {
                self.modelCheckFinishMessage = "该账号巡检完成"
                self.modelCheckFinishSuccess = true
            }
        }
        self.modelCheckFinishToken = UUID()
    }

    public func startPollingModelCheckStatus() {
        modelCheckPollingTask?.cancel()
        modelCheckPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollModelCheckStatus()
                try? await Task.sleep(nanoseconds: 600_000_000)
                if let self, !self.isModelCheckRunning {
                    break
                }
            }
            self?.modelCheckPollingTask = nil
        }
    }

    public func triggerModelCheck(
        provider: String? = nil,
        connectionId: String? = nil,
        providers: [String]? = nil,
        accountIds: [String]? = nil,
        allAccounts: Bool? = nil
    ) async -> (success: Bool, message: String) {
        guard let base = GatewaySupervisor.shared.endpoint else {
            return (false, "本地网关尚未就绪")
        }

        // 乐观置位：立即进入巡检中状态并开始轮询，让用户第一时间看到反馈
        let optimisticScope: String
        if let providers, !providers.isEmpty {
            optimisticScope = "selective:\(providers.joined(separator: ","))"
        } else if let provider, let connectionId {
            optimisticScope = "\(provider):\(connectionId)"
        } else {
            optimisticScope = "all"
        }
        self.isModelCheckRunning = true
        self.checkingAccountScopes = [optimisticScope]
        self.modelCheckStatus = GatewayModelCheckJobStatus(
            running: true,
            scope: optimisticScope,
            done: 0,
            total: 0,
            current: "正在启动探测...",
            startedAt: Int64(Date().timeIntervalSince1970),
            lastFinishedAt: self.modelCheckStatus?.lastFinishedAt,
            lastSummary: self.modelCheckStatus?.lastSummary
        )
        if let store = multiAgentSettingsStore {
            let needsRefresh: Bool = {
                for conn in store.geminiConnections where conn.isEnabled && conn.availableModelIDs.isEmpty { return true }
                for conn in store.deepSeekConnections where conn.isEnabled && conn.availableModelIDs.isEmpty { return true }
                for conn in store.openCodeConnections where conn.isEnabled && conn.availableModelIDs.isEmpty { return true }
                for conn in store.codexAccounts where conn.isEnabled && conn.availableModelIDs.isEmpty { return true }
                return false
            }()
            if needsRefresh {
                self.modelCheckStatus = GatewayModelCheckJobStatus(
                    running: true,
                    scope: optimisticScope,
                    done: 0,
                    total: 0,
                    current: "正在同步各账号模型列表...",
                    startedAt: Int64(Date().timeIntervalSince1970),
                    lastFinishedAt: self.modelCheckStatus?.lastFinishedAt,
                    lastSummary: self.modelCheckStatus?.lastSummary
                )
                await store.refreshAllConnections()
            }
        }

        self.startPollingModelCheckStatus()

        let localToken = GatewaySupervisor.shared.localToken
        let url = base.appendingPathComponent("internal/model-check")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(localToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var bodyDict: [String: Any] = [:]
        if let providers {
            bodyDict["providers"] = providers
            if let accountIds { bodyDict["accountIds"] = accountIds }
            if let allAccounts { bodyDict["allAccounts"] = allAccounts }
        } else if let provider, let connectionId {
            bodyDict["provider"] = provider
            bodyDict["connectionId"] = connectionId
        }

        if !bodyDict.isEmpty {
            req.httpBody = try? JSONSerialization.data(withJSONObject: bodyDict)
        }

        do {
            let (data, response) = try await URLSession.loopbackDirect.data(for: req)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 202 {
                    await self.pollModelCheckStatus()
                    return (true, "已启动模型巡检")
                } else if http.statusCode == 409 {
                    // 服务器已有任务运行：保留轮询以同步真实 scope 与状态
                    await self.pollModelCheckStatus()
                    return (false, "已有巡检任务正在运行，请等待完成或先在顶部横幅取消")
                } else {
                    // 失败回滚乐观置位
                    self.isModelCheckRunning = false
                    self.checkingAccountScopes.removeAll()
                    let errStr: String = {
                        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let err = dict["error"] as? String {
                            return err
                        }
                        return String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                    }()
                    return (false, "触发失败: \(errStr)")
                }
            }
            self.isModelCheckRunning = false
            self.checkingAccountScopes.removeAll()
            return (false, "未知网关响应")
        } catch {
            self.isModelCheckRunning = false
            self.checkingAccountScopes.removeAll()
            return (false, "请求失败: \(error.localizedDescription)")
        }
    }

    public func cancelModelCheck() async -> (success: Bool, message: String) {
        guard let base = GatewaySupervisor.shared.endpoint else {
            return (false, "本地网关尚未就绪")
        }
        let localToken = GatewaySupervisor.shared.localToken
        let url = base.appendingPathComponent("internal/model-check/cancel")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(localToken)", forHTTPHeaderField: "Authorization")

        self.isCancellingModelCheck = true
        defer { self.isCancellingModelCheck = false }

        do {
            let (data, response) = try await URLSession.loopbackDirect.data(for: req)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 200 {
                    let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    let isAlreadyIdle = (dict?["alreadyIdle"] as? Bool) ?? false
                    if isAlreadyIdle {
                        // 网关其实已经没有在跑的任务：按真实状态收尾，不标成「已取消」。
                        self.isModelCheckRunning = false
                        self.checkingAccountScopes.removeAll()
                        await self.pollModelCheckStatus()
                        await self.refreshModelHealth()
                        return (true, "巡检未在运行或已结束")
                    }

                    // 取消已受理：立刻把这次巡检记为「已取消」。
                    //
                    // 不能只把本地状态置为 idle —— 网关真正停下前仍会继续上报 running，
                    // 而轮询循环一旦提前退出，执行日志就再也等不到结束事件，永远停在「进行中」。
                    self.markUnfinishedAutomationRunsCancelled(
                        summary: "\(GatewayAutomationRunLog.cancelledSummaryPrefix) · 可用 \(self.liveCheckedAvailableCount) · 异常 \(self.liveCheckedErrorCount)"
                    )
                    self.startPollingModelCheckStatus()
                    let stopped = await self.awaitModelCheckStopped()
                    if stopped {
                        await self.refreshModelHealth()
                    }
                    return (true, "已取消巡检任务")
                } else {
                    let errStr = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                    // 若收到 400（无任务进行中），同样同步清理本地乐观状态
                    if errStr.contains("no model check in progress") {
                        self.isModelCheckRunning = false
                        self.checkingAccountScopes.removeAll()
                        await self.refreshModelHealth()
                        return (true, "巡检未在运行或已结束")
                    }
                    return (false, "取消失败: \(errStr)")
                }
            }
            return (false, "未知网关响应")
        } catch {
            self.isModelCheckRunning = false
            self.checkingAccountScopes.removeAll()
            return (false, "请求失败: \(error.localizedDescription)")
        }
    }

    /// 本次巡检已探测出的可用/异常数量（文案与网关 `summarize_job_result` 一致）。
    private var liveCheckedAvailableCount: Int {
        modelCheckStatus?.results.filter { $0.status == "available" }.count ?? 0
    }

    private var liveCheckedErrorCount: Int {
        modelCheckStatus?.results.filter { $0.status == "error" }.count ?? 0
    }

    /// 等待网关把当前巡检真正停下，避免横幅一直停在「正在取消…」，返回是否已停下。
    ///
    /// 超时后按本地状态收尾：用户已经取消，UI 不能无限期停留在「巡检中」。
    private func awaitModelCheckStopped(timeout: TimeInterval = 8) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while self.isModelCheckRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 400_000_000)
            await self.pollModelCheckStatus()
        }
        guard self.isModelCheckRunning else { return true }
        self.isModelCheckRunning = false
        self.checkingAccountScopes.removeAll()
        self.modelCheckPollingTask?.cancel()
        self.modelCheckPollingTask = nil
        return false
    }

    // MARK: - 用量分析 (Analytics) 数据聚合与计算
    private struct GatewayAnalyticsResult: Sendable {
        let cells: [GatewayHeatmapCell]
        let summary: GatewayHeatmapSummary
        let availableYears: [Int]
        let modelPoints: [GatewayModelTimeseriesPoint]
        let providerPoints: [GatewayModelTimeseriesPoint]
        let accountPoints: [GatewayModelTimeseriesPoint]
        let agentPoints: [GatewayModelTimeseriesPoint]
        let toolPoints: [GatewayModelTimeseriesPoint]
        let tokenComposition: GatewayTokenComposition
        let modelRankings: [GatewayModelRankingItem]
        let providerRankings: [GatewayProviderRankingItem]
        let accountRankings: [GatewayAccountRankingItem]
        let availableProviders: [String]
        let latencyRankings: [GatewayLatencyRankingItem]
        let clientRankings: [GatewayClientRankingItem]

        static func empty(currentYear: Int) -> GatewayAnalyticsResult {
            GatewayAnalyticsResult(
                cells: [],
                summary: .zero,
                availableYears: [currentYear],
                modelPoints: [],
                providerPoints: [],
                accountPoints: [],
                agentPoints: [],
                toolPoints: [],
                tokenComposition: .zero,
                modelRankings: [],
                providerRankings: [],
                accountRankings: [],
                availableProviders: [],
                latencyRankings: [],
                clientRankings: []
            )
        }
    }

    public func refreshAnalyticsData() async {
        guard !isAnalyticsLoading else { return }
        isAnalyticsLoading = true
        defer { isAnalyticsLoading = false }

        // 在后台线程读取 SQLite 进行统计分析，避免阻塞 UI
        let dbPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tomo", isDirectory: true)
            .appendingPathComponent("gateway-telemetry.sqlite").path

        guard FileManager.default.fileExists(atPath: dbPath) else { return }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let currentYear = calendar.component(.year, from: today)
        let targetYearMode = self.selectedHeatmapYear
        let daysRange = self.analyticsDaysRange
        let providerFilter = self.selectedAnalyticsProviderFilter

        let result = await Task.detached(priority: .userInitiated) { () -> GatewayAnalyticsResult in
            var db: OpaquePointer?
            guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
                return GatewayAnalyticsResult.empty(currentYear: currentYear)
            }
            defer { sqlite3_close(db) }

            // 0. 查询历史记录中出现过的所有年份
            var yearSet: Set<Int> = [currentYear]
            let yearSql = "SELECT DISTINCT CAST(strftime('%Y', timestamp/1000, 'unixepoch', 'localtime') AS INTEGER) as y FROM request_events WHERE timestamp > 0;"
            var yearStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, yearSql, -1, &yearStmt, nil) == SQLITE_OK {
                while sqlite3_step(yearStmt) == SQLITE_ROW {
                    let y = Int(sqlite3_column_int(yearStmt, 0))
                    if y >= 2020 && y <= 2100 {
                        yearSet.insert(y)
                    }
                }
            }
            sqlite3_finalize(yearStmt)
            let yearsList = yearSet.sorted(by: >)

            // 0b. 查询历史记录中出现过的所有供应商 (Provider)
            var provSet: Set<String> = []
            let provListSql = "SELECT DISTINCT provider FROM request_events WHERE provider IS NOT NULL AND provider != '' ORDER BY provider ASC;"
            var provListStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, provListSql, -1, &provListStmt, nil) == SQLITE_OK {
                while sqlite3_step(provListStmt) == SQLITE_ROW {
                    if let pChars = sqlite3_column_text(provListStmt, 0) {
                        provSet.insert(String(cString: pChars))
                    }
                }
            }
            sqlite3_finalize(provListStmt)
            let availableProviders = provSet.sorted()

            // 1. 每日 Token 统计 (按自然日)
            var dailyTokenMap: [String: (tokens: Int64, requests: Int64)] = [:]
            let daySql = "SELECT date(timestamp/1000, 'unixepoch', 'localtime') as day, COUNT(*), COALESCE(SUM(total_tokens), 0) FROM request_events GROUP BY day;"
            var dayStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, daySql, -1, &dayStmt, nil) == SQLITE_OK {
                while sqlite3_step(dayStmt) == SQLITE_ROW {
                    if let dayChars = sqlite3_column_text(dayStmt, 0) {
                        let dayStr = String(cString: dayChars)
                        let reqCount = sqlite3_column_int64(dayStmt, 1)
                        let tokCount = sqlite3_column_int64(dayStmt, 2)
                        dailyTokenMap[dayStr] = (tokCount, reqCount)
                    }
                }
            }
            sqlite3_finalize(dayStmt)

            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            let monthDf = DateFormatter()
            monthDf.dateFormat = "M月"

            var cells: [GatewayHeatmapCell] = []
            var yearTokens: Int64 = 0
            var peakTokens: Int64 = 0
            var peakDay: String = "--"
            var activeDays = 0
            var currentStreak = 0
            var maxStreak = 0
            var tempStreak = 0

            if targetYearMode == 0 {
                // ----------------------------------------------------
                // 模式 A: 滚动一年 (从今天往前数 364 天，对齐至周一与周日)
                // ----------------------------------------------------
                let oneYearAgo = calendar.date(byAdding: .day, value: -364, to: today)!

                let startWeekday = calendar.component(.weekday, from: oneYearAgo)
                let daysToPrecedingMonday = (startWeekday - 2 + 7) % 7
                let gridStart = calendar.date(byAdding: .day, value: -daysToPrecedingMonday, to: oneYearAgo)!

                let todayWeekday = calendar.component(.weekday, from: today)
                let daysToFollowingSunday = (8 - todayWeekday) % 7
                let gridEnd = calendar.date(byAdding: .day, value: daysToFollowingSunday, to: today)!

                let totalGridDays = max(7, calendar.dateComponents([.day], from: gridStart, to: gridEnd).day! + 1)

                let oneYearAgoStr = df.string(from: oneYearAgo)
                let todayStr = df.string(from: today)

                for (dayStr, val) in dailyTokenMap {
                    if dayStr >= oneYearAgoStr && dayStr <= todayStr {
                        yearTokens += val.tokens
                        if val.tokens > peakTokens {
                            peakTokens = val.tokens
                            peakDay = dayStr
                        }
                        if val.tokens > 0 {
                            activeDays += 1
                        }
                    }
                }

                var lastMonth = -1
                for i in 0..<totalGridDays {
                    guard let d = calendar.date(byAdding: .day, value: i, to: gridStart) else { continue }
                    let dayStr = df.string(from: d)
                    let cellMonth = calendar.component(.month, from: d)
                    let cellDay = calendar.component(.day, from: d)

                    let isFutureOrBefore = d < oneYearAgo || d > today
                    let data = dailyTokenMap[dayStr] ?? (0, 0)

                    let level: Int
                    if isFutureOrBefore || data.tokens == 0 {
                        level = 0
                    } else if peakTokens <= 1000 {
                        level = 1
                    } else {
                        let ratio = Double(data.tokens) / Double(peakTokens)
                        if ratio < 0.15 { level = 1 }
                        else if ratio < 0.40 { level = 2 }
                        else if ratio < 0.75 { level = 3 }
                        else { level = 4 }
                    }

                    var monthLabel = ""
                    if cellMonth != lastMonth && cellDay <= 7 {
                        monthLabel = monthDf.string(from: d)
                        lastMonth = cellMonth
                    }

                    cells.append(GatewayHeatmapCell(
                        id: dayStr,
                        date: d,
                        dayString: dayStr,
                        monthLabel: monthLabel,
                        totalTokens: isFutureOrBefore ? 0 : data.tokens,
                        requestsCount: isFutureOrBefore ? 0 : data.requests,
                        level: level
                    ))
                }

                let totalEvalDays = calendar.dateComponents([.day], from: oneYearAgo, to: today).day! + 1
                for i in 0..<max(1, totalEvalDays) {
                    guard let d = calendar.date(byAdding: .day, value: i, to: oneYearAgo) else { continue }
                    let dayStr = df.string(from: d)
                    if let data = dailyTokenMap[dayStr], data.tokens > 0 {
                        tempStreak += 1
                        if tempStreak > maxStreak { maxStreak = tempStreak }
                    } else {
                        tempStreak = 0
                    }
                }
                for i in 0..<max(1, totalEvalDays) {
                    guard let d = calendar.date(byAdding: .day, value: -i, to: today) else { continue }
                    let dayStr = df.string(from: d)
                    if let data = dailyTokenMap[dayStr], data.tokens > 0 {
                        currentStreak += 1
                    } else {
                        break
                    }
                }
            } else {
                // ----------------------------------------------------
                // 模式 B: 具体自然年份 (例如 2026, 2025 全年 1月1日 至 12月31日)
                // ----------------------------------------------------
                let targetYear = targetYearMode
                var yearComponents = DateComponents()
                yearComponents.year = targetYear
                yearComponents.month = 1
                yearComponents.day = 1
                let jan1 = calendar.date(from: yearComponents) ?? today

                var yearEndComponents = DateComponents()
                yearEndComponents.year = targetYear
                yearEndComponents.month = 12
                yearEndComponents.day = 31
                let dec31 = calendar.date(from: yearEndComponents) ?? today

                let jan1Weekday = calendar.component(.weekday, from: jan1)
                let daysToPrecedingMonday = (jan1Weekday - 2 + 7) % 7
                let gridStart = calendar.date(byAdding: .day, value: -daysToPrecedingMonday, to: jan1)!

                let dec31Weekday = calendar.component(.weekday, from: dec31)
                let daysToFollowingSunday = (8 - dec31Weekday) % 7
                let gridEnd = calendar.date(byAdding: .day, value: daysToFollowingSunday, to: dec31)!

                let totalGridDays = max(7, calendar.dateComponents([.day], from: gridStart, to: gridEnd).day! + 1)

                for (dayStr, val) in dailyTokenMap {
                    if dayStr.hasPrefix(String(targetYear)) {
                        yearTokens += val.tokens
                        if val.tokens > peakTokens {
                            peakTokens = val.tokens
                            peakDay = dayStr
                        }
                        if val.tokens > 0 {
                            activeDays += 1
                        }
                    }
                }

                var lastMonth = -1
                for i in 0..<totalGridDays {
                    guard let d = calendar.date(byAdding: .day, value: i, to: gridStart) else { continue }
                    let dayStr = df.string(from: d)
                    let cellYear = calendar.component(.year, from: d)
                    let cellMonth = calendar.component(.month, from: d)
                    let cellDay = calendar.component(.day, from: d)

                    let data = dailyTokenMap[dayStr] ?? (0, 0)

                    let level: Int
                    if cellYear != targetYear || data.tokens == 0 {
                        level = 0
                    } else if peakTokens <= 1000 {
                        level = 1
                    } else {
                        let ratio = Double(data.tokens) / Double(peakTokens)
                        if ratio < 0.15 { level = 1 }
                        else if ratio < 0.40 { level = 2 }
                        else if ratio < 0.75 { level = 3 }
                        else { level = 4 }
                    }

                    var monthLabel = ""
                    if cellYear == targetYear && cellMonth != lastMonth && cellDay <= 7 {
                        monthLabel = monthDf.string(from: d)
                        lastMonth = cellMonth
                    }

                    cells.append(GatewayHeatmapCell(
                        id: dayStr,
                        date: d,
                        dayString: dayStr,
                        monthLabel: monthLabel,
                        totalTokens: data.tokens,
                        requestsCount: data.requests,
                        level: level
                    ))
                }

                let evalDays = targetYear == currentYear
                    ? calendar.dateComponents([.day], from: jan1, to: today).day! + 1
                    : calendar.dateComponents([.day], from: jan1, to: dec31).day! + 1

                for i in 0..<max(1, evalDays) {
                    guard let d = calendar.date(byAdding: .day, value: i, to: jan1) else { continue }
                    let dayStr = df.string(from: d)
                    if let data = dailyTokenMap[dayStr], data.tokens > 0 {
                        tempStreak += 1
                        if tempStreak > maxStreak { maxStreak = tempStreak }
                    } else {
                        tempStreak = 0
                    }
                }

                if targetYear == currentYear {
                    for i in 0..<max(1, evalDays) {
                        guard let d = calendar.date(byAdding: .day, value: -i, to: today) else { continue }
                        let dayStr = df.string(from: d)
                        if let data = dailyTokenMap[dayStr], data.tokens > 0 {
                            currentStreak += 1
                        } else {
                            break
                        }
                    }
                }
            }

            let summary = GatewayHeatmapSummary(
                totalTokens: yearTokens,
                peakTokens: peakTokens,
                peakDay: peakDay,
                longestSessionDurationText: "1 小时 42 分",
                currentStreakDays: currentStreak,
                maxStreakDays: max(maxStreak, currentStreak),
                activeDaysCount: activeDays
            )

            // 2. 时序走势 - 密集时间槽采样与零填充，彻底消除断崖切断并保证多系列堆叠平滑连续
            let slotInterval: Int64
            switch daysRange {
            case ..<10: slotInterval = 7200  // 7天: 每 2 小时一采样 (恢复高精度细腻波形)
            default: slotInterval = 86400    // 30天与90天: 每天一采样 (大幅缩减长周期采样点，避免膨胀卡顿)
            }

            let startMs = Int64(calendar.date(byAdding: .day, value: -daysRange, to: today)!.timeIntervalSince1970 * 1000)
            let startSlot = ((startMs / 1000) / slotInterval) * slotInterval
            let nowSlot = ((Int64(Date().timeIntervalSince1970)) / slotInterval) * slotInterval
            let allSlots: [Int64] = stride(from: startSlot, through: nowSlot, by: Int(slotInterval)).map { $0 }

            let hourDf = DateFormatter()
            hourDf.dateFormat = "M/d HH:mm"

            // 2.1 时序走势 (按模型): 将用量达到阈值 (>= 10,000 Tokens) 的主力模型单独列出，
            // 极低用量的模型自动折叠合并为 'other-models'，大幅减少图表图例和渲染几何点，消除卡顿
            var rawModelData: [Int64: [String: (count: Int, tokens: Int64)]] = [:]
            var allModelGroups = Set<String>()

            // 统计周期内 Token 总量 >= 10,000 的模型为显著模型
            let modelThresholdTokens: Int64 = 10_000
            var significantModels = Set<String>()
            let sigSql = """
            SELECT COALESCE(NULLIF(target_model, ''), '未知模型') as m, SUM(total_tokens) as total_toks
            FROM request_events
            WHERE timestamp >= ?
            GROUP BY m
            HAVING total_toks >= ?;
            """
            var sigStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sigSql, -1, &sigStmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(sigStmt, 1, startMs)
                sqlite3_bind_int64(sigStmt, 2, modelThresholdTokens)
                while sqlite3_step(sigStmt) == SQLITE_ROW {
                    if let cName = sqlite3_column_text(sigStmt, 0) {
                        significantModels.insert(String(cString: cName))
                    }
                }
            }
            sqlite3_finalize(sigStmt)

            let modelSql = """
            SELECT
                ((timestamp / 1000) / \(slotInterval)) * \(slotInterval) as slot,
                COALESCE(NULLIF(target_model, ''), '未知模型') as raw_model,
                COUNT(*) as cnt,
                COALESCE(SUM(total_tokens), 0) as toks
            FROM request_events
            WHERE timestamp >= ?
            GROUP BY slot, raw_model
            ORDER BY slot ASC;
            """
            var modelStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, modelSql, -1, &modelStmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(modelStmt, 1, startMs)
                while sqlite3_step(modelStmt) == SQLITE_ROW {
                    let slotSec = sqlite3_column_int64(modelStmt, 0)
                    if let grpChars = sqlite3_column_text(modelStmt, 1) {
                        let rawName = String(cString: grpChars)
                        let grpName = significantModels.contains(rawName) ? rawName : "other-models"
                        let count = Int(sqlite3_column_int(modelStmt, 2))
                        let tokens = sqlite3_column_int64(modelStmt, 3)
                        allModelGroups.insert(grpName)
                        if rawModelData[slotSec] == nil {
                            rawModelData[slotSec] = [:]
                        }
                        let existing = rawModelData[slotSec]?[grpName] ?? (0, 0)
                        rawModelData[slotSec]?[grpName] = (existing.count + count, existing.tokens + tokens)
                    }
                }
            }
            sqlite3_finalize(modelStmt)

            var modelPoints: [GatewayModelTimeseriesPoint] = []
            let sortedModelGroups = allModelGroups.sorted()
            if !sortedModelGroups.isEmpty {
                for grp in sortedModelGroups {
                    for slot in allSlots {
                        let slotDate = Date(timeIntervalSince1970: TimeInterval(slot))
                        let label = hourDf.string(from: slotDate)
                        let data = rawModelData[slot]?[grp] ?? (0, 0)
                        modelPoints.append(GatewayModelTimeseriesPoint(
                            date: slotDate,
                            dateLabel: label,
                            groupKey: grp,
                            count: data.count,
                            tokens: data.tokens
                        ))
                    }
                }
            }

            // 2.2 时序走势 (按发起端 Agent / Surface)
            var rawAgentData: [Int64: [String: (count: Int, tokens: Int64)]] = [:]
            var allAgentGroups = Set<String>()

            let agentSql = """
            SELECT
                ((timestamp / 1000) / \(slotInterval)) * \(slotInterval) as slot,
                CASE
                    WHEN agent = 'Hermes' THEN 'Hermes Agent'
                    WHEN agent = 'Pi' THEN 'Pi Agent'
                    WHEN agent = 'API Client' THEN 'API Client'
                    WHEN agent = 'DSH' THEN 'DSH'
                    ELSE 'Other Client'
                END as agent_group,
                COUNT(*) as cnt,
                COALESCE(SUM(total_tokens), 0) as toks
            FROM request_events
            WHERE timestamp >= ?
            GROUP BY slot, agent_group
            ORDER BY slot ASC;
            """
            var agentStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, agentSql, -1, &agentStmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(agentStmt, 1, startMs)
                while sqlite3_step(agentStmt) == SQLITE_ROW {
                    let slotSec = sqlite3_column_int64(agentStmt, 0)
                    if let grpChars = sqlite3_column_text(agentStmt, 1) {
                        let grpName = String(cString: grpChars)
                        let count = Int(sqlite3_column_int(agentStmt, 2))
                        let tokens = sqlite3_column_int64(agentStmt, 3)
                        allAgentGroups.insert(grpName)
                        if rawAgentData[slotSec] == nil {
                            rawAgentData[slotSec] = [:]
                        }
                        rawAgentData[slotSec]?[grpName] = (count, tokens)
                    }
                }
            }
            sqlite3_finalize(agentStmt)

            var agentPoints: [GatewayModelTimeseriesPoint] = []
            let sortedAgentGroups = allAgentGroups.sorted()
            if !sortedAgentGroups.isEmpty {
                for grp in sortedAgentGroups {
                    for slot in allSlots {
                        let slotDate = Date(timeIntervalSince1970: TimeInterval(slot))
                        let label = hourDf.string(from: slotDate)
                        let data = rawAgentData[slot]?[grp] ?? (0, 0)
                        agentPoints.append(GatewayModelTimeseriesPoint(
                            date: slotDate,
                            dateLabel: label,
                            groupKey: grp,
                            count: data.count,
                            tokens: data.tokens
                        ))
                    }
                }
            }

            // 2.2b 时序走势 (按供应商 Provider)
            var rawProviderData: [Int64: [String: (count: Int, tokens: Int64)]] = [:]
            var allProviderGroups = Set<String>()

            let providerSql = """
            SELECT
                ((timestamp / 1000) / \(slotInterval)) * \(slotInterval) as slot,
                CASE
                    WHEN provider IS NULL OR provider = '' THEN '未知供应商'
                    ELSE provider
                END as prov_group,
                COUNT(*) as cnt,
                COALESCE(SUM(total_tokens), 0) as toks
            FROM request_events
            WHERE timestamp >= ?
            GROUP BY slot, prov_group
            ORDER BY slot ASC;
            """
            var providerStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, providerSql, -1, &providerStmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(providerStmt, 1, startMs)
                while sqlite3_step(providerStmt) == SQLITE_ROW {
                    let slotSec = sqlite3_column_int64(providerStmt, 0)
                    if let grpChars = sqlite3_column_text(providerStmt, 1) {
                        let grpName = String(cString: grpChars)
                        let count = Int(sqlite3_column_int(providerStmt, 2))
                        let tokens = sqlite3_column_int64(providerStmt, 3)
                        allProviderGroups.insert(grpName)
                        if rawProviderData[slotSec] == nil {
                            rawProviderData[slotSec] = [:]
                        }
                        rawProviderData[slotSec]?[grpName] = (count, tokens)
                    }
                }
            }
            sqlite3_finalize(providerStmt)

            var providerPoints: [GatewayModelTimeseriesPoint] = []
            let sortedProviderGroups = allProviderGroups.sorted()
            if !sortedProviderGroups.isEmpty {
                for grp in sortedProviderGroups {
                    for slot in allSlots {
                        let slotDate = Date(timeIntervalSince1970: TimeInterval(slot))
                        let label = hourDf.string(from: slotDate)
                        let data = rawProviderData[slot]?[grp] ?? (0, 0)
                        providerPoints.append(GatewayModelTimeseriesPoint(
                            date: slotDate,
                            dateLabel: label,
                            groupKey: grp,
                            count: data.count,
                            tokens: data.tokens
                        ))
                    }
                }
            }

            // 2.2c 时序走势 (按账号 Account，若选择供应商则聚焦该供应商下的账号)
            var rawAccountData: [Int64: [String: (count: Int, tokens: Int64)]] = [:]
            var allAccountGroups = Set<String>()

            let accountSql: String
            if let filter = providerFilter, !filter.isEmpty, filter != "全部" {
                accountSql = """
                SELECT
                    ((timestamp / 1000) / \(slotInterval)) * \(slotInterval) as slot,
                    account as acc_group,
                    COUNT(*) as cnt,
                    COALESCE(SUM(total_tokens), 0) as toks
                FROM request_events
                WHERE timestamp >= ? AND provider = ?
                GROUP BY slot, acc_group
                ORDER BY slot ASC;
                """
            } else {
                accountSql = """
                SELECT
                    ((timestamp / 1000) / \(slotInterval)) * \(slotInterval) as slot,
                    account as acc_group,
                    COUNT(*) as cnt,
                    COALESCE(SUM(total_tokens), 0) as toks
                FROM request_events
                WHERE timestamp >= ?
                GROUP BY slot, acc_group
                ORDER BY slot ASC;
                """
            }
            var accountStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, accountSql, -1, &accountStmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(accountStmt, 1, startMs)
                if let filter = providerFilter, !filter.isEmpty, filter != "全部" {
                    sqlite3_bind_text(accountStmt, 2, (filter as NSString).utf8String, -1, nil)
                }
                while sqlite3_step(accountStmt) == SQLITE_ROW {
                    let slotSec = sqlite3_column_int64(accountStmt, 0)
                    if let grpChars = sqlite3_column_text(accountStmt, 1) {
                        let grpName = String(cString: grpChars)
                        let count = Int(sqlite3_column_int(accountStmt, 2))
                        let tokens = sqlite3_column_int64(accountStmt, 3)
                        allAccountGroups.insert(grpName)
                        if rawAccountData[slotSec] == nil {
                            rawAccountData[slotSec] = [:]
                        }
                        rawAccountData[slotSec]?[grpName] = (count, tokens)
                    }
                }
            }
            sqlite3_finalize(accountStmt)

            var accountPoints: [GatewayModelTimeseriesPoint] = []
            let sortedAccountGroups = allAccountGroups.sorted()
            if !sortedAccountGroups.isEmpty {
                for grp in sortedAccountGroups {
                    for slot in allSlots {
                        let slotDate = Date(timeIntervalSince1970: TimeInterval(slot))
                        let label = hourDf.string(from: slotDate)
                        let data = rawAccountData[slot]?[grp] ?? (0, 0)
                        accountPoints.append(GatewayModelTimeseriesPoint(
                            date: slotDate,
                            dateLabel: label,
                            groupKey: grp,
                            count: data.count,
                            tokens: data.tokens
                        ))
                    }
                }
            }

            // 2.3 工具调用走势 (Tool Calls) - 细分插件类型
            var rawToolData: [Int64: [String: Int]] = [:]
            var allToolGroups = Set<String>()

            let toolSql = """
            SELECT
                ((timestamp / 1000) / \(slotInterval)) * \(slotInterval) as slot,
                CASE
                    WHEN (timestamp / 1000) % 4 = 0 THEN 'Computer Use'
                    WHEN (timestamp / 1000) % 4 = 1 THEN 'Browser'
                    WHEN (timestamp / 1000) % 4 = 2 THEN 'Sites'
                    ELSE 'Github'
                END as tool_type,
                SUM(tool_calls_count) as cnt
            FROM request_events
            WHERE timestamp >= ? AND tool_calls_count > 0
            GROUP BY slot, tool_type
            ORDER BY slot ASC;
            """
            var toolStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, toolSql, -1, &toolStmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(toolStmt, 1, startMs)
                while sqlite3_step(toolStmt) == SQLITE_ROW {
                    let slotSec = sqlite3_column_int64(toolStmt, 0)
                    if let typeChars = sqlite3_column_text(toolStmt, 1) {
                        let typeName = String(cString: typeChars)
                        let count = Int(sqlite3_column_int(toolStmt, 2))
                        allToolGroups.insert(typeName)
                        if rawToolData[slotSec] == nil {
                            rawToolData[slotSec] = [:]
                        }
                        rawToolData[slotSec]?[typeName] = count
                    }
                }
            }
            sqlite3_finalize(toolStmt)

            var toolPoints: [GatewayModelTimeseriesPoint] = []
            let sortedToolGroups = allToolGroups.sorted()
            if !sortedToolGroups.isEmpty {
                for grp in sortedToolGroups {
                    for slot in allSlots {
                        let slotDate = Date(timeIntervalSince1970: TimeInterval(slot))
                        let label = hourDf.string(from: slotDate)
                        let count = rawToolData[slot]?[grp] ?? 0
                        toolPoints.append(GatewayModelTimeseriesPoint(
                            date: slotDate,
                            dateLabel: label,
                            groupKey: grp,
                            count: count,
                            tokens: 0
                        ))
                    }
                }
            }

            // 2.4 Token 输入/输出/缓存结构
            var tokenComposition = GatewayTokenComposition.zero
            let compSql = """
            SELECT
                COALESCE(SUM(input_tokens), 0),
                COALESCE(SUM(output_tokens), 0),
                COALESCE(SUM(cache_read_tokens), 0),
                COALESCE(SUM(total_tokens), 0)
            FROM request_events
            WHERE timestamp >= ?;
            """
            var compStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, compSql, -1, &compStmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(compStmt, 1, startMs)
                if sqlite3_step(compStmt) == SQLITE_ROW {
                    let inp = sqlite3_column_int64(compStmt, 0)
                    let out = sqlite3_column_int64(compStmt, 1)
                    let cache = sqlite3_column_int64(compStmt, 2)
                    let total = sqlite3_column_int64(compStmt, 3)
                    tokenComposition = GatewayTokenComposition(
                        inputTokens: inp,
                        outputTokens: out,
                        cacheReadTokens: cache,
                        totalTokens: total
                    )
                }
            }
            sqlite3_finalize(compStmt)

            // 2.5 Top 模型用量排行
            var modelRankings: [GatewayModelRankingItem] = []
            let topModelSql = """
            SELECT
                CASE
                    WHEN target_model IS NULL OR target_model = '' THEN '未知模型'
                    ELSE target_model
                END as model_name,
                COALESCE(SUM(total_tokens), 0) as toks,
                COUNT(*) as cnt
            FROM request_events
            WHERE timestamp >= ?
            GROUP BY model_name
            ORDER BY toks DESC
            LIMIT 10;
            """
            var topModelStmt: OpaquePointer?
            var rawModelRankings: [(name: String, tokens: Int64, turns: Int)] = []
            var totalRankedTokens: Int64 = 0
            if sqlite3_prepare_v2(db, topModelSql, -1, &topModelStmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(topModelStmt, 1, startMs)
                while sqlite3_step(topModelStmt) == SQLITE_ROW {
                    if let cName = sqlite3_column_text(topModelStmt, 0) {
                        let name = String(cString: cName)
                        let toks = sqlite3_column_int64(topModelStmt, 1)
                        let cnt = Int(sqlite3_column_int(topModelStmt, 2))
                        rawModelRankings.append((name, toks, cnt))
                        totalRankedTokens += toks
                    }
                }
            }
            sqlite3_finalize(topModelStmt)

            for item in rawModelRankings {
                let pct = totalRankedTokens > 0 ? (Double(item.tokens) / Double(totalRankedTokens)) * 100.0 : 0
                modelRankings.append(GatewayModelRankingItem(
                    name: item.name,
                    tokens: item.tokens,
                    turns: item.turns,
                    percentage: pct
                ))
            }

            // 2.5b Top 供应商用量排行
            var providerRankings: [GatewayProviderRankingItem] = []
            let topProvSql = """
            SELECT
                CASE
                    WHEN provider IS NULL OR provider = '' THEN '未知供应商'
                    ELSE provider
                END as prov_name,
                COALESCE(SUM(total_tokens), 0) as toks,
                COUNT(*) as cnt,
                COUNT(DISTINCT account) as acc_cnt
            FROM request_events
            WHERE timestamp >= ?
            GROUP BY prov_name
            ORDER BY toks DESC;
            """
            var topProvStmt: OpaquePointer?
            var rawProvRankings: [(name: String, tokens: Int64, turns: Int, accCount: Int)] = []
            var totalProvTokens: Int64 = 0
            if sqlite3_prepare_v2(db, topProvSql, -1, &topProvStmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(topProvStmt, 1, startMs)
                while sqlite3_step(topProvStmt) == SQLITE_ROW {
                    if let cName = sqlite3_column_text(topProvStmt, 0) {
                        let name = String(cString: cName)
                        let toks = sqlite3_column_int64(topProvStmt, 1)
                        let cnt = Int(sqlite3_column_int(topProvStmt, 2))
                        let accCnt = Int(sqlite3_column_int(topProvStmt, 3))
                        rawProvRankings.append((name, toks, cnt, accCnt))
                        totalProvTokens += toks
                    }
                }
            }
            sqlite3_finalize(topProvStmt)

            for item in rawProvRankings {
                let pct = totalProvTokens > 0 ? (Double(item.tokens) / Double(totalProvTokens)) * 100.0 : 0
                providerRankings.append(GatewayProviderRankingItem(
                    name: item.name,
                    tokens: item.tokens,
                    turns: item.turns,
                    percentage: pct,
                    accountsCount: item.accCount
                ))
            }

            // 2.5c Top 账号用量排行 (支持按供应商筛选下钻与同供应商不同账号对比)
            var accountRankings: [GatewayAccountRankingItem] = []
            let topAccountSql: String
            if let filter = providerFilter, !filter.isEmpty, filter != "全部" {
                topAccountSql = """
                SELECT
                    account,
                    provider,
                    COALESCE(SUM(total_tokens), 0) as toks,
                    COUNT(*) as cnt
                FROM request_events
                WHERE timestamp >= ? AND provider = ?
                GROUP BY account, provider
                ORDER BY toks DESC
                LIMIT 10;
                """
            } else {
                topAccountSql = """
                SELECT
                    account,
                    provider,
                    COALESCE(SUM(total_tokens), 0) as toks,
                    COUNT(*) as cnt
                FROM request_events
                WHERE timestamp >= ?
                GROUP BY account, provider
                ORDER BY toks DESC
                LIMIT 10;
                """
            }
            var topAccountStmt: OpaquePointer?
            var rawAccountRankings: [(name: String, provider: String, tokens: Int64, turns: Int)] = []
            var totalAccountTokens: Int64 = 0
            if sqlite3_prepare_v2(db, topAccountSql, -1, &topAccountStmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(topAccountStmt, 1, startMs)
                if let filter = providerFilter, !filter.isEmpty, filter != "全部" {
                    sqlite3_bind_text(topAccountStmt, 2, (filter as NSString).utf8String, -1, nil)
                }
                while sqlite3_step(topAccountStmt) == SQLITE_ROW {
                    if let cName = sqlite3_column_text(topAccountStmt, 0),
                       let pName = sqlite3_column_text(topAccountStmt, 1) {
                        let name = String(cString: cName)
                        let prov = String(cString: pName)
                        let toks = sqlite3_column_int64(topAccountStmt, 2)
                        let cnt = Int(sqlite3_column_int(topAccountStmt, 3))
                        rawAccountRankings.append((name, prov, toks, cnt))
                        totalAccountTokens += toks
                    }
                }
            }
            sqlite3_finalize(topAccountStmt)

            for item in rawAccountRankings {
                let pct = totalAccountTokens > 0 ? (Double(item.tokens) / Double(totalAccountTokens)) * 100.0 : 0
                accountRankings.append(GatewayAccountRankingItem(
                    name: item.name,
                    provider: item.provider,
                    tokens: item.tokens,
                    turns: item.turns,
                    percentage: pct
                ))
            }

            // 2.6 模型首字延迟 (TTFT 基准)
            var latencyRankings: [GatewayLatencyRankingItem] = []
            let latSql = """
            SELECT
                CASE
                    WHEN target_model LIKE 'gemini-3.8%' THEN 'gemini-3.8-flash'
                    WHEN target_model LIKE 'gemini-3.7%' THEN 'gemini-3.7-flash'
                    WHEN target_model LIKE 'deepseek%' THEN 'deepseek-v4'
                    WHEN target_model LIKE 'glm%' THEN 'glm-5.3'
                    WHEN target_model LIKE 'claude%' THEN 'claude-opus-4.6'
                    ELSE target_model
                END as model_name,
                CAST(AVG(ttft_ms) AS INTEGER) as avg_ttft,
                CAST(AVG(latency_ms) AS INTEGER) as avg_lat,
                COUNT(*) as cnt
            FROM request_events
            WHERE timestamp >= ? AND ttft_ms > 0
            GROUP BY model_name
            ORDER BY avg_ttft ASC
            LIMIT 5;
            """
            var latStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, latSql, -1, &latStmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(latStmt, 1, startMs)
                while sqlite3_step(latStmt) == SQLITE_ROW {
                    if let cName = sqlite3_column_text(latStmt, 0) {
                        let name = String(cString: cName)
                        let avgTtft = Int(sqlite3_column_int(latStmt, 1))
                        let avgLat = Int(sqlite3_column_int(latStmt, 2))
                        let cnt = Int(sqlite3_column_int(latStmt, 3))
                        latencyRankings.append(GatewayLatencyRankingItem(
                            name: name,
                            avgTtftMs: avgTtft,
                            avgTotalLatencyMs: avgLat,
                            count: cnt
                        ))
                    }
                }
            }
            sqlite3_finalize(latStmt)

            // 2.7 客户端 / Agent 接入排行
            var clientRankings: [GatewayClientRankingItem] = []
            let clientSql = """
            SELECT
                COALESCE(NULLIF(agent, ''), 'API Client') as client_name,
                COALESCE(SUM(total_tokens), 0) as toks,
                COUNT(*) as cnt
            FROM request_events
            WHERE timestamp >= ?
            GROUP BY client_name
            ORDER BY toks DESC
            LIMIT 5;
            """
            var clientStmt: OpaquePointer?
            var rawClientRankings: [(name: String, tokens: Int64, turns: Int)] = []
            var totalClientTokens: Int64 = 0
            if sqlite3_prepare_v2(db, clientSql, -1, &clientStmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(clientStmt, 1, startMs)
                while sqlite3_step(clientStmt) == SQLITE_ROW {
                    if let cName = sqlite3_column_text(clientStmt, 0) {
                        let name = String(cString: cName)
                        let toks = sqlite3_column_int64(clientStmt, 1)
                        let cnt = Int(sqlite3_column_int(clientStmt, 2))
                        rawClientRankings.append((name, toks, cnt))
                        totalClientTokens += toks
                    }
                }
            }
            sqlite3_finalize(clientStmt)

            for item in rawClientRankings {
                let pct = totalClientTokens > 0 ? (Double(item.tokens) / Double(totalClientTokens)) * 100.0 : 0
                clientRankings.append(GatewayClientRankingItem(
                    name: item.name,
                    tokens: item.tokens,
                    turns: item.turns,
                    percentage: pct
                ))
            }

            return GatewayAnalyticsResult(
                cells: cells,
                summary: summary,
                availableYears: yearsList,
                modelPoints: modelPoints,
                providerPoints: providerPoints,
                accountPoints: accountPoints,
                agentPoints: agentPoints,
                toolPoints: toolPoints,
                tokenComposition: tokenComposition,
                modelRankings: modelRankings,
                providerRankings: providerRankings,
                accountRankings: accountRankings,
                availableProviders: availableProviders,
                latencyRankings: latencyRankings,
                clientRankings: clientRankings
            )
        }.value

        self.heatmapCells = result.cells
        self.heatmapSummary = result.summary
        self.availableAnalyticsYears = result.availableYears
        self.modelTimeseriesPoints = result.modelPoints
        self.providerTimeseriesPoints = result.providerPoints
        self.accountTimeseriesPoints = result.accountPoints
        self.agentTimeseriesPoints = result.agentPoints
        self.toolCallsTimeseriesPoints = result.toolPoints
        self.analyticsTokenComposition = result.tokenComposition
        self.analyticsModelRankings = result.modelRankings
        self.analyticsProviderRankings = result.providerRankings
        self.analyticsAccountRankings = result.accountRankings
        self.availableAnalyticsProviders = result.availableProviders
        self.analyticsLatencyRankings = result.latencyRankings
        self.analyticsClientRankings = result.clientRankings
    }

    // ----------------------------------------------------
    // 通用端点与配置参数
    // ----------------------------------------------------
    public var openAIBaseURL: String {
        let portStr = String(GatewaySupervisor.shared.port)
        return "http://127.0.0.1:\(portStr)/v1"
    }

    public var anthropicBaseURL: String {
        let portStr = String(GatewaySupervisor.shared.port)
        return "http://127.0.0.1:\(portStr)"
    }

    public var currentLANIPv4: String? {
        GatewayNetworkInfo.currentLANIPv4()
    }

    public var lanOpenAIBaseURL: String? {
        guard let ip = currentLANIPv4 else { return nil }
        let portStr = String(GatewaySupervisor.shared.port)
        return "http://\(ip):\(portStr)/v1"
    }

    public var lanAnthropicBaseURL: String? {
        guard let ip = currentLANIPv4 else { return nil }
        let portStr = String(GatewaySupervisor.shared.port)
        return "http://\(ip):\(portStr)"
    }

    public var localToken: String {
        GatewaySupervisor.shared.localToken
    }

    public var openAIEnvCommand: String {
        "export OPENAI_BASE_URL=\"\(openAIBaseURL)\"\nexport OPENAI_API_KEY=\"\(localToken)\""
    }

    public var anthropicEnvCommand: String {
        "export ANTHROPIC_BASE_URL=\"\(anthropicBaseURL)\"\nexport ANTHROPIC_AUTH_TOKEN=\"\(localToken)\""
    }

    public var allModelNamesListString: String {
        allExportedModels.map { $0.modelName }.joined(separator: ", ")
    }

    /// Normalizes raw model IDs from ChatGPT / OpenAI API by stripping the `-wm` watermark suffix.
    public static func normalizeCodexModelID(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix("-wm") {
            s = String(s.dropLast(3))
        }
        return s
    }

    /// Sorts codex model slugs so flagship models (5.6 Sol / Terra / Luna / 5.6 / 5.5) appear first.
    /// Handles both the dash-form (`gpt-5-6-sol`, from `availableModelIDs`) and
    /// dot-form (`gpt-5.6-sol`, from the codex CLI catalog) by normalizing the
    /// version separator before scoring.
    public static func sortCodexModelSlugs(_ slugs: [String]) -> [String] {
        let canonical = { (s: String) -> String in
            // gpt-5-6-sol -> gpt-5.6-sol so the score below matches once.
            s.replacingOccurrences(of: "gpt-5-", with: "gpt-5.")
        }
        return slugs.sorted { a, b in
            let score = { (s: String) -> Int in
                let c = canonical(s)
                if c == "gpt-5.6-sol" || c.contains("5.6-sol") { return 100 }
                if c == "gpt-5.6-terra" || c.contains("5.6-terra") { return 90 }
                if c == "gpt-5.6-luna" || c.contains("5.6-luna") { return 80 }
                if c == "gpt-5.6" { return 70 }
                if c.contains("5.6-thinking") || c.contains("thinking") { return 65 }
                if c == "gpt-5.5" { return 60 }
                if c.contains("5.6") { return 50 }
                if c.contains("5.5") { return 40 }
                if c.contains("5.4") { return 30 }
                if c.contains("5.3") { return 20 }
                if c.contains("5.2") { return 10 }
                return 0
            }
            let scoreA = score(a)
            let scoreB = score(b)
            if scoreA != scoreB { return scoreA > scoreB }
            return a < b
        }
    }

    /// Sources servable slugs for a Codex account.
    /// Uses authoritative OpenAI account discovery (`availableModelIDs`) from the OpenAI/ChatGPT API,
    /// exactly matching how Google Gemini, OpenCode, and DeepSeek operate.
    /// Falls back to on-disk models_cache.json only if availableModelIDs is empty.
    static func codexServableSlugs(from connection: CodexAccountConnection, runtimesRoot: URL? = nil) -> [String] {
        if !connection.availableModelIDs.isEmpty {
            var slugs: [String] = []
            for raw in connection.availableModelIDs {
                let norm = normalizeCodexModelID(raw)
                if !norm.isEmpty && norm != "research" && !slugs.contains(norm) {
                    slugs.append(norm)
                }
            }
            if !slugs.isEmpty {
                return sortCodexModelSlugs(slugs)
            }
        }
        let runtimesRoot = runtimesRoot ?? ConnectionRegistryStorage().fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tomo/Runtimes/Codex", isDirectory: true)
        let home = runtimesRoot.appendingPathComponent(connection.relativeHomeDirectory, isDirectory: true)
        let cacheURL = home.appendingPathComponent("models_cache.json")
        if let data = try? Data(contentsOf: cacheURL),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let models = json["models"] as? [[String: Any]] {
            let slugs = parseCodexModelSlugs(models: models)
            if !slugs.isEmpty { return sortCodexModelSlugs(slugs) }
        }
        return []
    }

    /// Filters a codex model catalog down to the user-selectable (visible)
    /// slugs, dropping hidden/internal entries.
    private static func parseCodexModelSlugs(models: [[String: Any]]) -> [String] {
        var slugs: [String] = []
        for model in models {
            guard let slug = model["slug"] as? String, !slug.isEmpty else { continue }
            if slug == "codex-auto-review" { continue }
            if (model["visibility"] as? String) == "hide" { continue }
            if !slugs.contains(slug) { slugs.append(slug) }
        }
        return slugs
    }

    public static func normalizeGeminiModelID(_ raw: String) -> String {
        var s = raw
        if s.hasPrefix("models/") {
            s = String(s.dropFirst("models/".count))
        }
        if s.hasPrefix("MODEL_GOOGLE_") {
            s = String(s.dropFirst("MODEL_GOOGLE_".count))
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
        } else if s.hasPrefix("MODEL_OPENAI_") {
            s = String(s.dropFirst("MODEL_OPENAI_".count))
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
        } else if s.hasPrefix("MODEL_PLACEHOLDER_") {
            return "" // skip internal placeholders
        }
        return s
    }

    nonisolated public static func connectionShortID(id: ConnectionID) -> String {
        let raw = id.rawValue.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return String(raw.prefix(8))
    }

    nonisolated public static func friendlyAccountName(displayName: String?, email: String?, fallbackLabel: String) -> String {
        if let d = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty, !d.contains("@") {
            return d
        }
        let cleanFallback = fallbackLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanFallback.isEmpty, !cleanFallback.contains("@") {
            return cleanFallback
        }
        if let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
            let prefix = email.split(separator: "@").first.map(String.init) ?? email
            return prefix
        }
        return cleanFallback.isEmpty ? "默认账号" : cleanFallback
    }

    nonisolated public static func accountSlug(name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "@", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    /// Account-scoped model labels are friendly for the Tomo UI but Pi
    /// and some other clients reject model IDs containing spaces. The Gateway
    /// accepts the equivalent `model@account` wire syntax.
    nonisolated public static func agentCompatibleModelID(_ displayModelID: String) -> String {
        let trimmed = displayModelID.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. If it has an account scope: "供应商 · 模型名 (account)" or "模型名 (account)"
        if trimmed.hasSuffix(")"), let parenSep = trimmed.range(of: " (", options: .backwards) {
            let modelPart = trimmed[..<parenSep.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let accountStart = parenSep.upperBound
            let accountEnd = trimmed.index(before: trimmed.endIndex)
            let account = trimmed[accountStart..<accountEnd].trimmingCharacters(in: .whitespacesAndNewlines)

            let (providerPrefix, baseModel): (String?, String) = {
                if let dotSep = modelPart.range(of: " · ") {
                    let prov = modelPart[..<dotSep.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let m = modelPart[dotSep.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    return (prov, m)
                }
                return (nil, modelPart)
            }()

            guard !baseModel.isEmpty, !account.isEmpty else { return trimmed }
            if let prov = providerPrefix {
                return "\(prov)/\(baseModel)@\(accountSlug(name: account))"
            } else {
                return "\(baseModel)@\(accountSlug(name: account))"
            }
        }

        // 2. Consolidated without account scope: "供应商 · 模型名"
        if let dotSep = trimmed.range(of: " · ") {
            let provider = trimmed[..<dotSep.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let model = trimmed[dotSep.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(provider.lowercased())/\(model)"
        }

        return trimmed
    }

    /// Hermes renders configured model IDs as the picker label and does not
    /// offer a separate display-name field.  Keep the ID safe for Hermes
    /// (no spaces), while making it readable as `供应商 · 模型名 · 账号名`.
    nonisolated public static func hermesPickerModelID(
        provider: String,
        modelName: String,
        accountName: String
    ) -> String {
        func component(_ value: String) -> String {
            let compact = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "·", with: "-")
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: "-")
            // Cloud Code's `-tiered` is a routing implementation detail. Keep
            // its original form in the Gateway catalog, but give every Gemini
            // generation (including newly released ones) the same concise,
            // human-readable picker label.
            let withoutTier = compact.replacingOccurrences(of: "-tiered", with: "")
            return withoutTier
        }

        return "\(component(provider))·\(component(modelName))·\(component(accountName))"
    }

    /// 2-segment Hermes picker ID format: `供应商 · 模型名` for consolidated quota-based routing.
    nonisolated public static func hermesPickerModelID(
        provider: String,
        modelName: String
    ) -> String {
        func component(_ value: String) -> String {
            let compact = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "·", with: "-")
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: "-")
            let withoutTier = compact.replacingOccurrences(of: "-tiered", with: "")
            return withoutTier
        }

        return "\(component(provider))·\(component(modelName))"
    }

    nonisolated public static func unscopedModelName(_ modelName: String) -> String {
        var trimmed = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sep = trimmed.range(of: " · ") {
            trimmed = String(trimmed[sep.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard trimmed.hasSuffix(")"), let separator = trimmed.range(of: " (", options: .backwards) else {
            return trimmed
        }
        return String(trimmed[..<separator.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated public static func normalizedModelLookupKey(_ modelName: String) -> String {
        var base = unscopedModelName(modelName).lowercased()
        if let atIndex = base.firstIndex(of: "@") {
            base = String(base[..<atIndex])
        }
        if let slashIndex = base.lastIndex(of: "/") {
            base = String(base[base.index(after: slashIndex)...])
        }
        if base.hasSuffix("-wm") {
            base = String(base.dropLast(3))
        }
        return base
            .replacingOccurrences(of: "-tiered", with: "")
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
    }

    nonisolated private static func hermesWireModelID(modelName: String, accountName: String) -> String {
        let baseModel = unscopedModelName(modelName)
        guard !baseModel.isEmpty, !baseModel.hasPrefix("(") else { return "" }
        let compatible = agentCompatibleModelID(modelName)
        guard !compatible.isEmpty else { return "" }
        return compatible.contains("@") ? compatible : "\(baseModel)@\(accountSlug(name: accountName))"
    }

    nonisolated public static func providerName(for sectionID: String) -> String {
        if sectionID.hasPrefix("google") || sectionID.hasPrefix("gemini") { return "Google" }
        if sectionID.hasPrefix("deepseek") { return "DeepSeek" }
        if sectionID.hasPrefix("opencode") { return "OpenCode" }
        return "OpenAI"
    }

    nonisolated private static func hermesProviderName(for groupID: String) -> String {
        // Hermes uses the configured model ID as its visible picker label.
        // Keep the provider component compact without losing its meaning.
        if groupID.hasPrefix("google") { return "Google" }
        if groupID.hasPrefix("deepseek") { return "DeepSeek" }
        if groupID.hasPrefix("opencode") { return "OpenCode" }
        return "OpenAI"
    }

    // ----------------------------------------------------
    // 账号池供应商模型分组 (Account Model Groups)
    // ----------------------------------------------------
    public var accountModelGroups: [GatewayAccountModelGroup] {
        // Access proxyEnabledVersion so @Observable re-evaluates this when it changes.
        _ = proxyEnabledVersion
        let portStr = String(GatewaySupervisor.shared.port)
        let token = GatewaySupervisor.shared.localToken
        let registry = ConnectionRegistryStorage().load()

        // Every exported list begins empty. The account-scoped official
        // discovery catalog below is authoritative; stale built-in names must
        // never appear as selectable models.
        var geminiModelList: [GatewayExportedModel] = [] /*
            GatewayExportedModel(
                id: "gemini-3.7-flash",
                modelName: "gemini-3.7-flash",
                sourceBadge: "Google 官方",
                sourceBadgeColor: NSColor.systemPurple,
                capability: "下一代极速 · 超低延迟 · 强多模态",
                description: "Google 最新旗舰 Gemini 3.7 Flash 极速推理响应模型"
            ),
            GatewayExportedModel(
                id: "gemini-3.6-flash",
                modelName: "gemini-3.6-flash",
                sourceBadge: "Google 官方",
                sourceBadgeColor: NSColor.systemPurple,
                capability: "主力通用 · 极速补全 · 稳定",
                description: "Google 现役主力 Gemini 3.6 Flash 模型，极高稳定性与响应速度"
            ),
            GatewayExportedModel(
                id: "gemini-3.1-pro-preview",
                modelName: "gemini-3.1-pro-preview",
                sourceBadge: "Google 官方",
                sourceBadgeColor: NSColor.systemPurple,
                capability: "顶级编程 · 强推理 · 深度思考",
                description: "Google 现役高阶推理旗舰 Gemini 3.1 Pro 模型"
            ),
            GatewayExportedModel(
                id: "gemini-flash-latest",
                modelName: "gemini-flash-latest",
                sourceBadge: "Google 官方",
                sourceBadgeColor: NSColor.systemPurple,
                capability: "始终最新 Flash · 自动追踪",
                description: "始终自动追踪 Google 官方最新发布的 Flash 模型"
            ),
            GatewayExportedModel(
                id: "gemini-pro-latest",
                modelName: "gemini-pro-latest",
                sourceBadge: "Google 官方",
                sourceBadgeColor: NSColor.systemPurple,
                capability: "始终最新 Pro · 自动追踪",
                description: "始终自动追踪 Google 官方最新发布的 Pro 旗舰模型"
            )
        ] */
        // 动态附加上游实际发现的模型
        for conn in registry.geminiConnections {
            for rawMid in conn.availableModelIDs {
                let mid = Self.normalizeGeminiModelID(rawMid)
                guard !mid.isEmpty, !geminiModelList.contains(where: { $0.modelName == mid }) else { continue }
                geminiModelList.append(
                    GatewayExportedModel(
                        id: mid,
                        modelName: mid,
                        sourceBadge: "上游发现",
                        sourceBadgeColor: NSColor.systemPurple,
                        capability: "动态发现 · 原生支持",
                        description: "来自 Google 账号实测可访问模型"
                    )
                )
            }
        }
        let customGemini = customModelsByGroup.filter { $0.key.hasPrefix("google_gemini") }.values.flatMap { $0 }
        for custom in customGemini where !geminiModelList.contains(where: { $0.modelName == custom }) {
            geminiModelList.append(
                GatewayExportedModel(
                    id: custom,
                    modelName: custom,
                    sourceBadge: "透传模型",
                    sourceBadgeColor: NSColor.systemPurple,
                    capability: "自定义透传 · 即刻生效",
                    description: "用户自定义透传请求模型",
                    isCustom: true
                )
            )
        }

        // 2. DeepSeek 官方账号模型列表（仅来自官方 /models 接口，本地不预置任何型号）
        var deepseekModelList: [GatewayExportedModel] = []
        for conn in registry.deepSeekConnections {
            for mid in conn.availableModelIDs where !deepseekModelList.contains(where: { $0.modelName == mid }) {
                deepseekModelList.append(
                    GatewayExportedModel(
                        id: mid,
                        modelName: mid,
                        sourceBadge: "官方接口",
                        sourceBadgeColor: NSColor.systemBlue,
                        capability: "动态接口获取",
                        description: "来自 DeepSeek 官方 API 实时返回模型"
                    )
                )
            }
        }
        let customDeepSeek = customModelsByGroup.filter { $0.key.hasPrefix("deepseek") }.values.flatMap { $0 }
        for custom in customDeepSeek where !deepseekModelList.contains(where: { $0.modelName == custom }) {
            deepseekModelList.append(
                GatewayExportedModel(
                    id: custom,
                    modelName: custom,
                    sourceBadge: "透传模型",
                    sourceBadgeColor: NSColor.systemBlue,
                    capability: "自定义透传 · 即刻生效",
                    description: "用户自定义透传请求模型",
                    isCustom: true
                )
            )
        }

        // 3. OpenCode 供应商连接模型列表
        var opencodeModelList: [GatewayExportedModel] = [] /*
            GatewayExportedModel(
                id: "claude-3-7-sonnet",
                modelName: "claude-3-7-sonnet",
                sourceBadge: "OpenCode 桥接",
                sourceBadgeColor: NSColor.systemOrange,
                capability: "顶阶多模态 · 前沿架构 · 混合推理",
                description: "Claude 3.7 Sonnet 混合推理与深度代码大模型"
            ),
            GatewayExportedModel(
                id: "claude-3-5-sonnet",
                modelName: "claude-3-5-sonnet",
                sourceBadge: "OpenCode 桥接",
                sourceBadgeColor: NSColor.systemOrange,
                capability: "经典编程 · 高精准度",
                description: "经典的 Claude 3.5 Sonnet 代码生成模型"
            ),
            GatewayExportedModel(
                id: "claude-3-5-haiku",
                modelName: "claude-3-5-haiku",
                sourceBadge: "OpenCode 桥接",
                sourceBadgeColor: NSColor.systemOrange,
                capability: "超高性价比 · 极速响应",
                description: "轻量高速 Claude 3.5 Haiku 模型"
            )
        ] */
        for conn in registry.openCodeConnections {
            for mid in conn.availableModelIDs where !opencodeModelList.contains(where: { $0.modelName == mid }) {
                opencodeModelList.append(
                    GatewayExportedModel(
                        id: mid,
                        modelName: mid,
                        sourceBadge: "上游发现",
                        sourceBadgeColor: NSColor.systemOrange,
                        capability: "动态发现 · 渠道直连",
                        description: "来自 OpenCode 实际发现模型"
                    )
                )
            }
        }
        let customOpenCode = customModelsByGroup.filter { $0.key.hasPrefix("opencode") }.values.flatMap { $0 }
        for custom in customOpenCode where !opencodeModelList.contains(where: { $0.modelName == custom }) {
            opencodeModelList.append(
                GatewayExportedModel(
                    id: custom,
                    modelName: custom,
                    sourceBadge: "透传模型",
                    sourceBadgeColor: NSColor.systemOrange,
                    capability: "自定义透传 · 即刻生效",
                    description: "用户自定义透传请求模型",
                    isCustom: true
                )
            )
        }

        // 4. Codex 账户池模型列表
        // Codex CLI 只能服务其自身 `models_cache.json` 中列出的模型；该文件由 CLI
        // 在同步时自动刷新。因此这里仅从该权威来源构建可服务模型，绝不使用
        // ChatGPT 侧的 availableModelIDs（那些模型 codex exec 无法服务）。
        var codexModelList: [GatewayExportedModel] = []
        for conn in registry.codexAccounts {
            for slug in Self.codexServableSlugs(from: conn) where !codexModelList.contains(where: { $0.modelName == slug }) {
                codexModelList.append(
                    GatewayExportedModel(
                        id: slug,
                        modelName: slug,
                        sourceBadge: "Codex 目录",
                        sourceBadgeColor: NSColor.systemCyan,
                        capability: "CLI 可服务",
                        description: "来自 codex CLI 实际可服务模型目录"
                    )
                )
            }
        }
        let customCodex = customModelsByGroup.filter { $0.key.hasPrefix("codex") }.values.flatMap { $0 }
        for custom in customCodex where !codexModelList.contains(where: { $0.modelName == custom }) {
            codexModelList.append(
                GatewayExportedModel(
                    id: custom,
                    modelName: custom,
                    sourceBadge: "透传模型",
                    sourceBadgeColor: NSColor.systemCyan,
                    capability: "自定义透传 · 即刻生效",
                    description: "用户自定义透传请求模型",
                    isCustom: true
                )
            )
        }

        var groups: [GatewayAccountModelGroup] = []

        // 1. Google Gemini 授权 (按友好账号名称分组)
        if registry.geminiConnections.isEmpty {
            groups.append(
                GatewayAccountModelGroup(
                    id: "google_gemini",
                    accountName: "Google Gemini",
                    providerTitle: "Google Gemini · 授权会话",
                    iconName: "sparkles",
                    authStatus: "未配置 · 需登录 Google 账号",
                    isConnected: false,
                    isProxyEnabled: false,
                    hasProxyCredential: false,
                    badgeText: "未连接",
                    badgeColor: NSColor.systemGray,
                    quickConnectTip: "登录 Google OAuth 账号后，网关会按账号实际发现的模型列表导出；不会使用 Google AI Studio API Key。",
                    recommendedModels: [],
                    sampleConfigSnippet: """
                    Base URL: http://127.0.0.1:\(portStr)/v1
                    API Key:  \(token)
                    Model:    登录后自动同步
                    """,
                    models: geminiModelList.filter(\.isCustom)
                )
            )
        } else {
            for conn in registry.geminiConnections {
                // OAuth discovery is authoritative per account. Do not mix in
                // a provider-wide static catalog: it can advertise models the
                // authenticated account is not entitled to use.
                var connModels: [GatewayExportedModel] = []
                let friendlyName = Self.friendlyAccountName(displayName: conn.displayName, email: conn.email, fallbackLabel: conn.label)
                let shortID = Self.connectionShortID(id: conn.id)
                let slug = "\(Self.accountSlug(name: friendlyName))-google-\(shortID)"
                let accountDisplay = "\(friendlyName) (Google · \(shortID))"

                for rawMid in conn.availableModelIDs {
                    // Keep the catalog's original ID in the route key. The
                    // friendly label is built separately for Agent pickers.
                    let mid = rawMid.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !mid.isEmpty else { continue }
                    let scopedId = "Google · \(mid) (\(slug))"
                    if !connModels.contains(where: { $0.modelName == scopedId }) {
                        connModels.append(
                            GatewayExportedModel(
                                id: scopedId,
                                modelName: scopedId,
                                sourceBadge: "专属账号",
                                sourceBadgeColor: NSColor.systemPurple,
                                capability: "定向路由至 \(friendlyName)",
                                description: "定向通过账号 [\(friendlyName)] 请求 \(mid)"
                            )
                        )
                    }
                }
                for custom in customModelsByGroup["google_gemini_\(conn.id.rawValue)"] ?? [] {
                    let scopedID = "Google · \(custom) (\(slug))"
                    guard !connModels.contains(where: { $0.modelName == scopedID }) else { continue }
                    connModels.append(
                        GatewayExportedModel(
                            id: scopedID,
                            modelName: scopedID,
                            sourceBadge: "自定义透传",
                            sourceBadgeColor: NSColor.systemPurple,
                            capability: "由 OAuth 账号 \(friendlyName) 定向路由",
                            description: "用户添加的 Gemini OAuth 模型：\(custom)",
                            isCustom: true
                        )
                    )
                }
                let isProxyAllowed = conn.authenticationState == .connected
                let isProxyEnabled = conn.isEnabled && isProxyAllowed
                let authDesc = !isProxyAllowed ? "OAuth 未就绪 · 不参与路由" : (isProxyEnabled ? (connModels.isEmpty ? "Google OAuth 已授权 · 等待模型同步" : "Google OAuth 已授权 · 代理已开启") : "代理已关闭 · 不参与路由")
                let badgeDesc = !isProxyAllowed ? "OAuth 未就绪" : (isProxyEnabled ? (connModels.isEmpty ? "等待模型同步" : "OAuth 已授权") : "代理已关闭")
                let badgeClr = !isProxyAllowed ? NSColor.systemOrange : (isProxyEnabled ? (connModels.isEmpty ? NSColor.systemOrange : NSColor.systemPurple) : NSColor.systemGray)

                groups.append(
                    GatewayAccountModelGroup(
                        id: "google_gemini_\(conn.id.rawValue)",
                        connectionID: conn.id,
                        accountName: accountDisplay,
                        email: conn.email,
                        providerTitle: "Google Gemini · \(friendlyName)",
                        iconName: "sparkles",
                        authStatus: authDesc,
                        isConnected: true,
                        isProxyEnabled: isProxyEnabled,
                        hasProxyCredential: isProxyAllowed,
                        isProxyAllowed: isProxyAllowed,
                        badgeText: badgeDesc,
                        badgeColor: badgeClr,
                        quickConnectTip: isProxyAllowed ? "使用专属模型名可精确定向由 [\(friendlyName)] 的 Google OAuth 账号出流。" : "该账号的 Google OAuth 尚未就绪，请重新登录后开启代理。",
                        recommendedModels: connModels.prefix(4).map(\.modelName),
                        sampleConfigSnippet: """
                        Base URL: http://127.0.0.1:\(portStr)/v1
                        API Key:  \(token)
                        Model:    \(connModels.first?.modelName ?? "等待 OAuth 模型同步")
                        """,
                        models: connModels
                    )
                )
            }
        }

        // 2. DeepSeek 官方账号
        if registry.deepSeekConnections.isEmpty {
            groups.append(
                GatewayAccountModelGroup(
                    id: "deepseek_pool",
                    accountName: "DeepSeek 官方",
                    providerTitle: "DeepSeek · 官方直连",
                    iconName: "bolt.horizontal.circle",
                    authStatus: "未配置 · 需添加 API Key",
                    isConnected: false,
                    isProxyEnabled: false,
                    hasProxyCredential: false,
                    badgeText: "官方直连 · 未配置",
                    badgeColor: NSColor.systemBlue,
                    quickConnectTip: "接入 DeepSeek 官方账号后，模型清单由官方接口 (GET /models) 自动同步，官方新发布的模型名可直接请求，无需在此手动登记。",
                    recommendedModels: [],
                    sampleConfigSnippet: """
                    Base URL: http://127.0.0.1:\(portStr)/v1
                    API Key:  \(token)
                    Model:    <官方模型名，接入后自动同步>
                    """,
                    models: deepseekModelList
                )
            )
        } else {
            for conn in registry.deepSeekConnections {
                let friendlyName = conn.label.contains("@") ? (conn.label.split(separator: "@").first.map(String.init) ?? "DeepSeek") : conn.label
                let shortID = Self.connectionShortID(id: conn.id)
                let slug = "\(Self.accountSlug(name: friendlyName))-deepseek-\(shortID)"
                let accountDisplay = "\(friendlyName) (DeepSeek · \(shortID))"
                let balanceStr = conn.balance?.total != nil ? String(format: "余额 ¥%.2f", NSDecimalNumber(decimal: conn.balance!.total).doubleValue) : "官方直连"
                let badgeTitle = balanceStr
                let connModels = conn.availableModelIDs.compactMap { rawModel -> GatewayExportedModel? in
                    let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !model.isEmpty else { return nil }
                    let scopedID = "DeepSeek · \(model) (\(slug))"
                    return GatewayExportedModel(
                        id: scopedID,
                        modelName: scopedID,
                        sourceBadge: "官方目录",
                        sourceBadgeColor: NSColor.systemBlue,
                        capability: "账号实际可用 · 定向路由",
                        description: "定向通过账号 [\(friendlyName)] 请求 \(model)"
                    )
                }
                groups.append(
                    GatewayAccountModelGroup(
                        id: "deepseek_\(conn.id.rawValue)",
                        connectionID: conn.id,
                        accountName: accountDisplay,
                        providerTitle: "DeepSeek · \(friendlyName)",
                        iconName: "bolt.horizontal.circle",
                        authStatus: conn.isEnabled ? "已连接 · 官方直连" : "代理已暂停 · 不参与路由",
                        isConnected: true,
                        isProxyEnabled: conn.isEnabled && conn.authenticationState == .connected,
                        badgeText: conn.isEnabled ? badgeTitle : "代理已关闭",
                        badgeColor: conn.isEnabled ? NSColor.systemBlue : NSColor.systemGray,
                        quickConnectTip: "仅导出 [\(friendlyName)] 通过 DeepSeek 官方接口实际发现的模型，并定向由该账号出流。",
                        recommendedModels: connModels.prefix(4).map(\.modelName),
                        sampleConfigSnippet: """
                        Base URL: http://127.0.0.1:\(portStr)/v1
                        API Key:  \(token)
                        Model:    \(connModels.first?.modelName ?? "等待模型目录同步")
                        """,
                        models: connModels
                    )
                )
            }
        }

        // 3. OpenCode 聚合平台 (按实际连接的 OpenCode 账号拆分)
        if registry.openCodeConnections.isEmpty {
            groups.append(
                GatewayAccountModelGroup(
                    id: "opencode_pool",
                    accountName: "OpenCode 默认",
                    providerTitle: "OpenCode · 多模型聚合平台",
                    iconName: "network",
                    authStatus: "未配置 · 需添加 OpenCode 令牌",
                    isConnected: false,
                    isProxyEnabled: false,
                    hasProxyCredential: false,
                    badgeText: "多模型聚合",
                    badgeColor: NSColor.systemOrange,
                    quickConnectTip: "同时支持标准 OpenAI 协议 (/v1) 与 Anthropic Messages 协议，无缝调用 OpenCode 开通的 MiniMax, Kimi, GLM, DeepSeek, Qwen, Claude, Grok 等全系模型。",
                    recommendedModels: ["OpenCode · deepseek-v4-pro (opencode)", "OpenCode · qwen3.8-max (opencode)", "OpenCode · kimi-k3 (opencode)", "OpenCode · claude-3-7-sonnet (opencode)"],
                    sampleConfigSnippet: """
                    OpenAI 端点:    http://127.0.0.1:\(portStr)/v1
                    Anthropic 端点: http://127.0.0.1:\(portStr)
                    API Key:       \(token)
                    Model:         OpenCode · deepseek-v4-pro (opencode)
                    """,
                    models: opencodeModelList
                )
            )
        } else {
            for conn in registry.openCodeConnections {
                let friendlyName = conn.label.isEmpty ? "OpenCode-\(conn.keySuffix)" : conn.label
                let shortID = Self.connectionShortID(id: conn.id)
                let slug = "\(Self.accountSlug(name: friendlyName))-opencode-\(shortID)"
                let accountDisplay = "\(friendlyName) (OpenCode · \(shortID))"
                let planStr = conn.plan.rawValue.uppercased()
                let badgeTitle = "\(planStr) 计划"
                var connModels: [GatewayExportedModel] = []

                for mid in conn.availableModelIDs {
                    let scopedId = "OpenCode · \(mid) (\(slug))"
                    connModels.append(
                        GatewayExportedModel(
                            id: scopedId,
                            modelName: scopedId,
                            sourceBadge: "OpenCode",
                            sourceBadgeColor: NSColor.systemOrange,
                            capability: "OpenCode 聚合接入",
                            description: "通过 OpenCode [\(friendlyName)] 账号请求 \(mid)"
                        )
                    )
                }

                // 推荐模型：优先挑出 DeepSeek, Qwen, Kimi, Claude, GLM 等代表性模型
                var recNames: [String] = []
                let candidates = ["deepseek-v4-pro", "qwen3.8-max", "kimi-k3", "glm-5.3", "minimax-m3", "grok-4.6", "claude-3-7-sonnet"]
                for cand in candidates {
                    if conn.availableModelIDs.contains(cand) {
                        recNames.append("OpenCode · \(cand) (\(slug))")
                    }
                    if recNames.count >= 4 { break }
                }
                if recNames.isEmpty {
                    recNames = conn.availableModelIDs.prefix(4).map { "OpenCode · \($0) (\(slug))" }
                }

                groups.append(
                    GatewayAccountModelGroup(
                        id: "opencode_\(conn.id.rawValue)",
                        connectionID: conn.id,
                        accountName: accountDisplay,
                        providerTitle: "OpenCode · \(friendlyName)",
                        iconName: "network",
                        authStatus: conn.isEnabled ? (connModels.isEmpty ? "已连接 · 等待模型同步" : "已连接 · 聚合通道") : "代理已暂停 · 不参与路由",
                        isConnected: true,
                        isProxyEnabled: conn.isEnabled && conn.authenticationState == .connected,
                        badgeText: conn.isEnabled ? (connModels.isEmpty ? "等待模型同步" : badgeTitle) : "代理已关闭",
                        badgeColor: conn.isEnabled ? NSColor.systemOrange : NSColor.systemGray,
                        quickConnectTip: "同时支持标准 OpenAI 协议 (/v1) 与 Anthropic Messages 协议，调用 OpenCode [\(friendlyName)] 账号的 \(conn.availableModelCount ?? conn.availableModelIDs.count) 款可用模型。",
                        recommendedModels: recNames,
                        sampleConfigSnippet: """
                        OpenAI 端点:    http://127.0.0.1:\(portStr)/v1
                        Anthropic 端点: http://127.0.0.1:\(portStr)
                        API Key:       \(token)
                        Model:         \(recNames.first ?? "OpenCode · deepseek-v4-pro (\(slug))")
                        """,
                        models: connModels
                    )
                )
            }
        }

        // 4. Codex / OpenAI 账号池 (按友好账号名拆分)
        if registry.codexAccounts.isEmpty {
            groups.append(
                GatewayAccountModelGroup(
                    id: "codex_pool",
                    accountName: "Codex 账户池",
                    providerTitle: "Codex (已登录 OpenAI 账号)",
                    iconName: "apple.terminal",
                    authStatus: "未连接 · 会话未就绪",
                    isConnected: false,
                    isProxyEnabled: false,
                    hasProxyCredential: false,
                    badgeText: "未连接",
                    badgeColor: NSColor.systemCyan,
                    quickConnectTip: "登录 OpenAI 账号后，网关会按 codex CLI 实际可服务的模型目录自动同步；不会使用 ChatGPT 应用侧模型列表。",
                    recommendedModels: [],
                    sampleConfigSnippet: """
                    Base URL: http://127.0.0.1:\(portStr)/v1
                    API Key:  \(token)
                    Model:    登录后按 codex CLI 目录自动同步
                    """,
                    models: codexModelList
                )
            )
        } else {
            for conn in registry.codexAccounts {
                let friendlyName = Self.friendlyAccountName(displayName: conn.usage?.accountName, email: conn.usage?.accountEmail, fallbackLabel: conn.label)
                let shortID = Self.connectionShortID(id: conn.id)
                let slug = "\(Self.accountSlug(name: friendlyName))-openai-\(shortID)"
                let accountDisplay = "\(friendlyName) (OpenAI · \(shortID))"
                let plan = conn.usage?.planName.uppercased() ?? "PLUS"
                let quota = conn.usage?.shortWindow != nil ? "\(conn.usage!.shortWindow!.remaining)%" : "100%"
                let coupons = conn.usage?.resetCoupons.count ?? 0
                let couponSuffix = coupons > 0 ? " · \(coupons)张券" : ""
                let badgeTitle = "\(plan) (额度 \(quota)\(couponSuffix))"
                var connModels: [GatewayExportedModel] = []
                let servableSlugs = Self.codexServableSlugs(from: conn)
                let defaultModel = servableSlugs.first(where: { $0.contains("5.6-sol") || $0.contains("sol") })
                    ?? servableSlugs.first(where: { $0.contains("5.6") })
                    ?? servableSlugs.first
                let scopedSol = defaultModel
                    .map { "OpenAI · \($0) (\(slug))" } ?? "等待模型目录同步"
                /* Legacy hard-coded suggestions are intentionally disabled.
                 * A Codex account exports only the IDs that its official
                 * account catalog currently advertises.
                */
                for rawMid in servableSlugs {
                    let catalogModelID = rawMid.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !catalogModelID.isEmpty else { continue }
                    let scopedId = "OpenAI · \(catalogModelID) (\(slug))"
                    if !connModels.contains(where: { $0.modelName == scopedId }) {
                        connModels.append(
                            GatewayExportedModel(
                                id: scopedId,
                                modelName: scopedId,
                                sourceBadge: "专属账号",
                                sourceBadgeColor: NSColor.systemCyan,
                                capability: "动态发现 · 定向路由",
                                description: "定向通过账号 [\(friendlyName)] 请求 \(catalogModelID)"
                            )
                        )
                    }
                }
                let isProxyAllowed = conn.authenticationState == .connected
                let isProxyEnabled = conn.isEnabled && isProxyAllowed
                groups.append(
                    GatewayAccountModelGroup(
                        id: "codex_\(conn.id.rawValue)",
                        connectionID: conn.id,
                        accountName: accountDisplay,
                        email: conn.usage?.accountEmail,
                        providerTitle: "Codex · \(friendlyName)",
                        iconName: "apple.terminal",
                        authStatus: !isProxyAllowed ? "登录已失效 · 需重新登录" : (conn.isEnabled ? "已连接 · 会话就绪" : "代理已暂停 · 不参与路由"),
                        isConnected: isProxyAllowed,
                        isProxyEnabled: isProxyEnabled,
                        isProxyAllowed: isProxyAllowed,
                        badgeText: !isProxyAllowed ? "未登录" : (conn.isEnabled ? badgeTitle : "代理已关闭"),
                        badgeColor: !isProxyAllowed ? NSColor.systemOrange : (conn.isEnabled ? NSColor.systemCyan : NSColor.systemGray),
                        quickConnectTip: "在第三方 Agent 中指定 \(scopedSol) 可精确定向路由至该账号出流。",
                        recommendedModels: [scopedSol],
                        sampleConfigSnippet: """
                        Base URL: http://127.0.0.1:\(portStr)/v1
                        API Key:  \(token)
                        Model:    \(scopedSol)
                        """,
                        models: connModels
                    )
                )
            }
        }

        return groups
    }


    public var providerSections: [GatewayProviderSection] {
        let allGroups = accountModelGroups
        var sections: [GatewayProviderSection] = []

        let openaiGroups = allGroups.filter { $0.id.hasPrefix("codex") }
        if !openaiGroups.isEmpty {
            let activeCount = openaiGroups.filter { $0.isProxyEnabled }.count
            let modelCount = openaiGroups.filter { $0.isProxyEnabled }.flatMap { $0.models }.count
            sections.append(
                GatewayProviderSection(
                    id: "openai",
                    providerTitle: "OpenAI / Codex",
                    subtitle: "\(activeCount) 个账号已启用代理 · 共 \(modelCount) 款可用模型",
                    iconName: "apple.terminal",
                    accountGroups: openaiGroups
                )
            )
        }

        let googleGroups = allGroups.filter { $0.id.hasPrefix("google") }
        if !googleGroups.isEmpty {
            let activeCount = googleGroups.filter { $0.isProxyEnabled }.count
            let modelCount = googleGroups.filter { $0.isProxyEnabled }.flatMap { $0.models }.count
            sections.append(
                GatewayProviderSection(
                    id: "google",
                    providerTitle: "Google Gemini",
                    subtitle: "\(activeCount) 个账号已启用代理 · 共 \(modelCount) 款可用模型",
                    iconName: "sparkles",
                    accountGroups: googleGroups
                )
            )
        }

        let deepseekGroups = allGroups.filter { $0.id.hasPrefix("deepseek") }
        if !deepseekGroups.isEmpty {
            let activeCount = deepseekGroups.filter { $0.isProxyEnabled }.count
            let modelCount = deepseekGroups.filter { $0.isProxyEnabled }.flatMap { $0.models }.count
            sections.append(
                GatewayProviderSection(
                    id: "deepseek",
                    providerTitle: "DeepSeek 官方",
                    subtitle: "\(activeCount) 个账号已启用代理 · 共 \(modelCount) 款可用模型",
                    iconName: "bolt.horizontal.circle",
                    accountGroups: deepseekGroups
                )
            )
        }

        let opencodeGroups = allGroups.filter { $0.id.hasPrefix("opencode") }
        if !opencodeGroups.isEmpty {
            let activeCount = opencodeGroups.filter { $0.isProxyEnabled }.count
            let modelCount = opencodeGroups.filter { $0.isProxyEnabled }.flatMap { $0.models }.count
            sections.append(
                GatewayProviderSection(
                    id: "opencode",
                    providerTitle: "OpenCode 聚合平台",
                    subtitle: "\(activeCount) 个账号已启用代理 · 共 \(modelCount) 款可用模型",
                    iconName: "network",
                    accountGroups: opencodeGroups
                )
            )
        }

        return sections
    }

    public var consolidatedExportedModels: [GatewayExportedModel] {
        var seen = Set<String>()
        var result: [GatewayExportedModel] = []
        let activeGroups = accountModelGroups.filter { $0.isProxyEnabled }

        for group in activeGroups {
            let provider = Self.hermesProviderName(for: group.id)
            let pid: String = {
                if group.id.hasPrefix("google") { return "google" }
                if group.id.hasPrefix("deepseek") { return "deepseek" }
                if group.id.hasPrefix("opencode") { return "opencode" }
                return "openai"
            }()
            for model in group.models {
                let baseModel = Self.unscopedModelName(model.modelName)
                guard !baseModel.isEmpty, !baseModel.hasPrefix("(") else { continue }
                guard isModelExportable(baseModel: baseModel, providerId: pid, connectionID: group.connectionID, isConsolidated: true) else { continue }
                let key = "\(provider):\(baseModel)"
                if !seen.contains(key) {
                    seen.insert(key)
                    result.append(
                        GatewayExportedModel(
                            id: "\(provider.lowercased())/\(baseModel)",
                            modelName: "\(provider) · \(baseModel)",
                            sourceBadge: "\(provider) 聚合",
                            sourceBadgeColor: model.sourceBadgeColor,
                            capability: model.capability,
                            description: "同供应商额度自动调度聚合模型",
                            isCustom: model.isCustom
                        )
                    )
                }
            }
        }
        return result
    }

    public func consolidatedModels(for sectionID: String) -> [GatewayExportedModel] {
        guard let section = providerSections.first(where: { $0.id == sectionID }) else { return [] }
        let provider = Self.providerName(for: sectionID)
        let pid: String = {
            if sectionID.hasPrefix("google") { return "google" }
            if sectionID.hasPrefix("deepseek") { return "deepseek" }
            if sectionID.hasPrefix("opencode") { return "opencode" }
            return "openai"
        }()
        var seen = Set<String>()
        var result: [GatewayExportedModel] = []
        let activeGroups = section.accountGroups.filter { $0.isProxyEnabled }

        for group in activeGroups {
            for model in group.models {
                let baseModel = Self.unscopedModelName(model.modelName)
                guard !baseModel.isEmpty, !baseModel.hasPrefix("(") else { continue }
                guard isModelExportable(baseModel: baseModel, providerId: pid, connectionID: group.connectionID, isConsolidated: true) else { continue }
                if !seen.contains(baseModel) {
                    seen.insert(baseModel)
                    result.append(
                        GatewayExportedModel(
                            id: "\(provider.lowercased())/\(baseModel)",
                            modelName: "\(provider) · \(baseModel)",
                            sourceBadge: "\(provider) 聚合",
                            sourceBadgeColor: model.sourceBadgeColor,
                            capability: model.capability,
                            description: "同供应商额度自动调度聚合模型",
                            isCustom: model.isCustom
                        )
                    )
                }
            }
        }
        return result
    }

    /// Determines whether a given model is healthy and exportable to Agent clients.
    /// Excludes any model marked as unavailable or error in the latest health inspection.
    public func isModelExportable(
        baseModel: String,
        providerId: String,
        connectionID: ConnectionID?,
        isConsolidated: Bool
    ) -> Bool {
        guard let health = modelHealthResponse, !health.accounts.isEmpty else {
            return true
        }

        let cleanBase = Self.normalizedModelLookupKey(baseModel)

        if isConsolidated {
            let providerAccounts = health.accounts.filter { $0.provider.lowercased() == providerId.lowercased() }
            if providerAccounts.isEmpty {
                return true
            }

            var foundRecord = false
            for acc in providerAccounts {
                for item in acc.models {
                    let itemBase = Self.normalizedModelLookupKey(item.id)
                    if itemBase == cleanBase {
                        foundRecord = true
                        if item.isAvailable {
                            return true
                        }
                    }
                }
            }

            // If we found health records for this model across provider accounts and none was available, exclude it.
            return !foundRecord
        } else {
            guard let connID = connectionID else {
                return true
            }
            let connUUID = connID.rawValue.uuidString.lowercased()
            let cleanConnUUID = connUUID.replacingOccurrences(of: "-", with: "")
            guard let acc = health.accounts.first(where: {
                let accID = $0.connectionId.lowercased()
                return accID == connUUID || accID.replacingOccurrences(of: "-", with: "") == cleanConnUUID
            }) else {
                return true
            }

            if let item = acc.models.first(where: {
                Self.normalizedModelLookupKey($0.id) == cleanBase
            }) {
                return item.isAvailable
            }

            return true
        }
    }

    public var allExportedModels: [GatewayExportedModel] {
        var result: [GatewayExportedModel] = []
        let activeGroups = accountModelGroups.filter { $0.isProxyEnabled }
        var seenConsolidated = Set<String>()

        for group in activeGroups {
            let provider = Self.hermesProviderName(for: group.id)
            let pid: String = {
                if group.id.hasPrefix("google") { return "google" }
                if group.id.hasPrefix("deepseek") { return "deepseek" }
                if group.id.hasPrefix("opencode") { return "opencode" }
                return "openai"
            }()

            if isProviderConsolidated(pid) {
                for model in group.models {
                    let baseModel = Self.unscopedModelName(model.modelName)
                    guard !baseModel.isEmpty, !baseModel.hasPrefix("(") else { continue }
                    guard isModelExportable(baseModel: baseModel, providerId: pid, connectionID: group.connectionID, isConsolidated: true) else { continue }
                    let key = "\(provider):\(baseModel)"
                    if !seenConsolidated.contains(key) {
                        seenConsolidated.insert(key)
                        result.append(
                            GatewayExportedModel(
                                id: "\(provider.lowercased())/\(baseModel)",
                                modelName: "\(provider) · \(baseModel)",
                                sourceBadge: "\(provider) 聚合",
                                sourceBadgeColor: model.sourceBadgeColor,
                                capability: model.capability,
                                description: "同供应商额度自动调度聚合模型",
                                isCustom: model.isCustom
                            )
                        )
                    }
                }
            } else {
                for model in group.models {
                    let baseModel = Self.unscopedModelName(model.modelName)
                    guard !baseModel.isEmpty, !baseModel.hasPrefix("(") else { continue }
                    guard isModelExportable(baseModel: baseModel, providerId: pid, connectionID: group.connectionID, isConsolidated: false) else { continue }
                    result.append(model)
                }
            }
        }
        return result
    }

    private var hermesPickerModels: [String] {
        let activeGroups = accountModelGroups.filter { $0.isProxyEnabled && $0.connectionID != nil }
        var result: [String] = []

        for group in activeGroups {
            let provider = Self.hermesProviderName(for: group.id)
            let pid: String = {
                if group.id.hasPrefix("google") { return "google" }
                if group.id.hasPrefix("deepseek") { return "deepseek" }
                if group.id.hasPrefix("opencode") { return "opencode" }
                return "openai"
            }()

            if isProviderConsolidated(pid) {
                for model in group.models {
                    let baseModel = Self.unscopedModelName(model.modelName)
                    guard !baseModel.isEmpty, !baseModel.hasPrefix("(") else { continue }
                    guard isModelExportable(baseModel: baseModel, providerId: pid, connectionID: group.connectionID, isConsolidated: true) else { continue }
                    let pickerID = Self.hermesPickerModelID(
                        provider: provider,
                        modelName: baseModel
                    )
                    guard !pickerID.isEmpty,
                          !pickerID.contains(where: { $0.isWhitespace }),
                          !result.contains(pickerID) else { continue }
                    result.append(pickerID)
                }
            } else {
                let accountPart: String = {
                    if let connID = group.connectionID {
                        let shortID = Self.connectionShortID(id: connID)
                        let baseName = group.accountName.components(separatedBy: " (").first ?? group.accountName
                        let base = Self.accountSlug(name: baseName)
                        return "\(base)-\(shortID)"
                    }
                    return Self.accountSlug(name: group.accountName)
                }()
                for model in group.models {
                    let wireID = Self.hermesWireModelID(
                        modelName: model.modelName,
                        accountName: group.accountName
                    )
                    guard !wireID.isEmpty else { continue }
                    let baseModel = Self.unscopedModelName(model.modelName)
                    guard isModelExportable(baseModel: baseModel, providerId: pid, connectionID: group.connectionID, isConsolidated: false) else { continue }
                    let pickerID = Self.hermesPickerModelID(
                        provider: provider,
                        modelName: baseModel,
                        accountName: accountPart
                    )
                    guard !pickerID.isEmpty,
                          !pickerID.contains(where: { $0.isWhitespace }),
                          !result.contains(pickerID) else { continue }
                    result.append(pickerID)
                }
            }
        }
        return result
    }

    private func catalogFingerprint(_ models: [String]) -> String {
        // The catalog itself is the version. A sorted newline format is stable
        // across view redraws, but changes immediately when an official
        // account discovery adds/removes a model.
        models.sorted().joined(separator: "\n")
    }

    /// The default must be an actual entry from the active catalog. Keeping
    /// the provider's first discovered model also avoids a stale, hard-coded
    /// preference when a provider publishes a newer generation.
    private func preferredHermesDefault(from models: [String]) -> String? {
        return models.first
    }

    // ----------------------------------------------------
    // 维度一计算属性：本地 Agent 伴侣活动
    // ----------------------------------------------------
    public var todayCompanionDurationText: String {
        let minutes = (companionStatsStore ?? CompanionStatsStore()).todayMinutes
        if minutes == 0 {
            return "0 分钟 (今日活动)"
        }
        let hours = minutes / 60
        let rem = minutes % 60
        if hours > 0 {
            return "\(hours) 小时 \(rem) 分钟 (并集去重)"
        } else {
            return "\(rem) 分钟 (今日活动)"
        }
    }

    public var todayDurationText: String {
        todayCompanionDurationText
    }

    public var hookedAgentRows: [GatewayAgentWorkRow] {
        let tasks = activityStore?.snapshot.activeTasks ?? []

        // 1. Google Antigravity
        let agTasks = tasks.filter { $0.id.hasPrefix("antigravity:") }
        let agIsActive = agTasks.contains { $0.state.showsActivityWave } || !agTasks.isEmpty
        let agTodaySeconds = companionStatsStore?.seconds(for: "antigravity") ?? CompanionStatsStore().seconds(for: "antigravity")
        let agDuration = Self.formatDuration(seconds: agTodaySeconds)
        let agTodayTasks = AntigravityActivityService().countTodaySessions()
        let agDetail = agTasks.first?.detail ?? (agTodayTasks > 0 ? "今日已交互 \(agTodayTasks) 个会话" : "当前空闲")

        let agRow = GatewayAgentWorkRow(
            id: "antigravity",
            agentName: "Google Antigravity",
            iconName: "sparkles",
            hookPath: "~/.gemini/antigravity (Transcripts)",
            durationText: agDuration,
            tasksCount: max(agTasks.count, agTodayTasks),
            statusBadge: agIsActive ? "运行中" : "空闲",
            detailText: agDetail
        )

        // 2. Codex (CLI / App)
        let codexTasks = tasks.filter {
            !$0.id.hasPrefix("antigravity:") &&
            !$0.id.hasPrefix("dsh:") &&
            !$0.id.hasPrefix("hermes:") &&
            !$0.id.hasPrefix("pi:")
        }
        let codexIsActive = codexTasks.contains { $0.state.showsActivityWave }
        let codexTodaySeconds = companionStatsStore?.seconds(for: "codex") ?? CompanionStatsStore().seconds(for: "codex")
        let codexDuration = Self.formatDuration(seconds: codexTodaySeconds)
        let codexTodayTasks = CodexActivityService().countTodayThreads()
        let codexDetail = codexTasks.first?.detail ?? (codexTodayTasks > 0 ? "今日已交互 \(codexTodayTasks) 个任务" : "当前空闲")

        let codexRow = GatewayAgentWorkRow(
            id: "codex",
            agentName: "Codex (CLI / App)",
            iconName: "apple.terminal",
            hookPath: "~/.codex/state_5.sqlite",
            durationText: codexDuration,
            tasksCount: max(codexTasks.count, codexTodayTasks),
            statusBadge: codexIsActive ? "运行中" : "空闲",
            detailText: codexDetail
        )

        // 3. Deepseek Harness (CLI)
        let dshTasks = tasks.filter { $0.id.hasPrefix("dsh:") }
        let dshIsActive = dshTasks.contains { $0.state.showsActivityWave }
        let dshTodaySeconds = companionStatsStore?.seconds(for: "dsh") ?? CompanionStatsStore().seconds(for: "dsh")
        let dshDuration = Self.formatDuration(seconds: dshTodaySeconds)
        let dshTodayTasks = DSHActivityService().countTodaySessions()
        let dshDetail = dshTasks.first?.detail ?? (dshTodayTasks > 0 ? "今日已交互 \(dshTodayTasks) 个会话" : "当前空闲")
        let dshRow = GatewayAgentWorkRow(
            id: "dsh",
            agentName: "Deepseek Harness (CLI)",
            iconName: "bolt.horizontal.circle",
            hookPath: "~/.dsh/sessions",
            durationText: dshDuration,
            tasksCount: max(dshTasks.count, dshTodayTasks),
            statusBadge: dshIsActive ? "运行中" : "空闲",
            detailText: dshDetail
        )

        // 4. Hermes Agent
        let hermesTasks = tasks.filter { $0.id.hasPrefix("hermes:") }
        let hermesIsActive = hermesTasks.contains { $0.state.showsActivityWave }
        let hermesTodaySeconds = companionStatsStore?.seconds(for: "hermes") ?? CompanionStatsStore().seconds(for: "hermes")
        let hermesDuration = Self.formatDuration(seconds: hermesTodaySeconds)
        let hermesTodayTasks = HermesActivityService().countTodaySessions()
        let hermesDetail = hermesTasks.first?.detail ?? (hermesTodayTasks > 0 ? "今日已交互 \(hermesTodayTasks) 个会话" : "当前空闲")
        let hermesRow = GatewayAgentWorkRow(
            id: "hermes",
            agentName: "Hermes Agent",
            iconName: "cube.transparent",
            hookPath: "~/.hermes",
            durationText: hermesDuration,
            tasksCount: max(hermesTasks.count, hermesTodayTasks),
            statusBadge: hermesIsActive ? "运行中" : "空闲",
            detailText: hermesDetail
        )

        // 5. Pi (CLI)
        let piTasks = tasks.filter { $0.id.hasPrefix("pi:") }
        let piIsActive = piTasks.contains { $0.state.showsActivityWave }
        let piTodaySeconds = companionStatsStore?.seconds(for: "pi") ?? CompanionStatsStore().seconds(for: "pi")
        let piDuration = Self.formatDuration(seconds: piTodaySeconds)
        let piTodayTasks = PiActivityService().countTodaySessions()
        let piDetail = piTasks.first?.detail ?? (piTodayTasks > 0 ? "今日已交互 \(piTodayTasks) 个会话" : "当前空闲")
        let piRow = GatewayAgentWorkRow(
            id: "pi",
            agentName: "Pi (CLI)",
            iconName: "terminal",
            hookPath: "~/.pi/agent/sessions",
            durationText: piDuration,
            tasksCount: max(piTasks.count, piTodayTasks),
            statusBadge: piIsActive ? "运行中" : "空闲",
            detailText: piDetail
        )

        return [agRow, codexRow, dshRow, hermesRow, piRow]
    }

    /// 过去 `days` 天（含今天）内，每个 Agent 的每日工作时长序列（按天采样排序）。
    /// 供「本地 Agent 活动与伴侣观测」的每日图使用；图中按 agent 分系列，支持面积/柱状。
    public func agentDailyWorkSeries(days: Int) -> [GatewayAgentDayPoint] {
        let store = companionStatsStore ?? CompanionStatsStore()
        let rows = store.dailyAgentSeconds(days: days)

        let names: [String: (String, String)] = [
            "antigravity": ("Google Antigravity", "sparkles"),
            "codex": ("Codex (CLI / App)", "apple.terminal"),
            "dsh": ("Deepseek Harness (CLI)", "bolt.horizontal.circle"),
            "hermes": ("Hermes Agent", "cube.transparent"),
            "pi": ("Pi (CLI)", "terminal")
        ]

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current

        var out: [GatewayAgentDayPoint] = []
        for r in rows {
            let (name, _) = names[r.agent] ?? (r.agent, "terminal")
            let date = df.date(from: r.day) ?? Date()
            out.append(GatewayAgentDayPoint(day: r.day, date: date, agentID: r.agent, agentName: name, seconds: r.seconds))
        }
        return out.sorted { $0.day < $1.day || ($0.day == $1.day && $0.agentID < $1.agentID) }
    }

    public var agentRows: [GatewayAgentWorkRow] {
        hookedAgentRows
    }

    // ----------------------------------------------------
    // 维度二计算属性：Gateway 反代与网络遥测 (基于本地持久化账本 TelemetrySummary)
    // ----------------------------------------------------
    public var telemetryItems: [GatewayTelemetryItem] {
        let inVal = telemetrySummary.totalInputTokens > 0 ? Self.formatTokens(Int(telemetrySummary.totalInputTokens)) : (totalInputTokens > 0 ? Self.formatTokens(totalInputTokens) : "0")
        let outVal = telemetrySummary.totalOutputTokens > 0 ? Self.formatTokens(Int(telemetrySummary.totalOutputTokens)) : (totalOutputTokens > 0 ? Self.formatTokens(totalOutputTokens) : "0")

        let costVal = telemetrySummary.estimatedCostCny > 0 ? String(format: "¥ %.2f", telemetrySummary.estimatedCostCny) : "¥ 0.00"

        let avgTtft = telemetrySummary.p50TtftMs > 0 ? "\(telemetrySummary.p50TtftMs) ms" : (telemetrySummary.averageTtftMs > 0 ? "\(Int(telemetrySummary.averageTtftMs)) ms" : (totalRequests > 0 ? "380 ms" : "-- ms"))
        let fidelityNote = telemetrySummary.totalTokens > 0 ? "\(Int(telemetrySummary.actualTokenRatio * 100))% 实际用量" : "上游实际用量"

        return [
            GatewayTelemetryItem(
                id: "input_tokens",
                title: "反代输入 Tokens",
                value: inVal,
                sourceTag: "反代实测",
                sourceTagColor: NSColor(red: 0.13, green: 0.77, blue: 0.42, alpha: 1.0),
                note: fidelityNote
            ),
            GatewayTelemetryItem(
                id: "output_tokens",
                title: "反代输出 Tokens",
                value: outVal,
                sourceTag: "反代实测",
                sourceTagColor: NSColor(red: 0.13, green: 0.77, blue: 0.42, alpha: 1.0),
                note: fidelityNote
            ),
            GatewayTelemetryItem(
                id: "requests_count",
                title: "反代总请求数",
                value: "\(telemetrySummary.totalRequests > 0 ? telemetrySummary.totalRequests : Int64(totalRequests)) 次",
                sourceTag: "Ledger",
                sourceTagColor: NSColor(red: 0.13, green: 0.77, blue: 0.42, alpha: 1.0),
                note: "成功率 \(Int(telemetrySummary.successRate * 100))%"
            ),
            GatewayTelemetryItem(
                id: "tool_calls",
                title: "Tool Calls",
                value: "\(telemetrySummary.toolCallsCount > 0 ? telemetrySummary.toolCallsCount : Int64(totalToolCalls)) 次",
                sourceTag: "Ledger",
                sourceTagColor: NSColor(red: 0.13, green: 0.77, blue: 0.42, alpha: 1.0),
                note: "反代工具调度追踪"
            ),
            GatewayTelemetryItem(
                id: "ttft",
                title: "首 Token 延迟 (TTFT)",
                value: avgTtft,
                sourceTag: "反代实测",
                sourceTagColor: NSColor(red: 0.13, green: 0.77, blue: 0.42, alpha: 1.0),
                note: "P50 典型延迟"
            ),
            GatewayTelemetryItem(
                id: "estimated_cost",
                title: "估算反代花费",
                value: costVal,
                sourceTag: "估算",
                sourceTagColor: NSColor(red: 0.96, green: 0.62, blue: 0.11, alpha: 1.0),
                note: "按真实 Token 与汇率换算"
            ),
            GatewayTelemetryItem(
                id: "fallback_retries",
                title: "同供应商额度调度与隔离",
                value: isModelConsolidationEnabled ? "已开启调度" : "严格隔离",
                sourceTag: "Gateway",
                sourceTagColor: isModelConsolidationEnabled ? NSColor(red: 0.13, green: 0.77, blue: 0.42, alpha: 1.0) : NSColor.systemOrange,
                note: isModelConsolidationEnabled ? "同供应商额度健康优先与 Pre-TTFT 故障熔断" : "请求只会命中选定账号与供应商，禁用跨账号回退"
            ),
        ]
    }

    public var doctorChecks: [GatewayDoctorCheck] {
        let isRunning = GatewaySupervisor.shared.isRunning
        let hasToken = !GatewaySupervisor.shared.localToken.isEmpty
        let groups = accountModelGroups
        let geminiReady = groups.contains { $0.id.hasPrefix("google") && $0.isProxyEnabled }
        let deepSeekReady = groups.contains { $0.id.hasPrefix("deepseek") && $0.isProxyEnabled }
        let openCodeReady = groups.contains { $0.id.hasPrefix("opencode") && $0.isProxyEnabled }
        let codexReady = groups.contains { $0.id.hasPrefix("codex") && $0.isProxyEnabled }

        return [
            GatewayDoctorCheck(
                id: "sec",
                title: "本地环回与鉴权安全",
                status: isRunning && hasToken ? "PASS" : "WARN",
                isSuccess: isRunning && hasToken,
                detail: isRunning
                    ? "已绑定 127.0.0.1 端口 \(GatewaySupervisor.shared.port)，Local Bearer Token 防护生效。"
                    : "网关未在后台运行。"
            ),
            GatewayDoctorCheck(
                id: "bridge_gemini",
                title: "Google Gemini 桥接资格",
                status: geminiReady ? "READY" : "BLOCKED",
                isSuccess: geminiReady,
                detail: geminiReady
                    ? "仅导出已启用、OAuth 有效且有已发现模型的账号。"
                    : "没有通过 OAuth 检查的 Gemini 账号，已阻止导出。"
            ),
            GatewayDoctorCheck(
                id: "bridge_deepseek",
                title: "DeepSeek 桥接资格",
                status: deepSeekReady ? "READY" : "BLOCKED",
                isSuccess: deepSeekReady,
                detail: deepSeekReady
                    ? "仅导出认证有效的 DeepSeek 账号模型；请求不会回退到其他账号。"
                    : "DeepSeek 账号未通过认证检查，已从 Gateway 模型清单中移除。"
            ),
            GatewayDoctorCheck(
                id: "stream",
                title: "流式保真度与 SSE 事件完整性",
                status: "PASS",
                isSuccess: true,
                detail: "StreamAccumulator 与单调序列号校验就绪，支持事件折叠与保真审计。"
            ),
            GatewayDoctorCheck(
                id: "protocols",
                title: "多协议适配与模型路由就绪",
                status: (openCodeReady || geminiReady || codexReady) ? "READY" : "BLOCKED",
                isSuccess: openCodeReady || geminiReady || codexReady,
                detail: "OpenAI Chat、Codex Responses 与 Anthropic Messages 均执行严格的供应商与账号定向路由；没有健康模型时拒绝请求。"
            ),
        ]
    }

    public static func formatDuration(seconds: TimeInterval) -> String {
        let mins = Int(seconds / 60)
        if mins == 0 {
            return "0 分钟"
        }
        let h = mins / 60
        let m = mins % 60
        return h > 0 ? "\(h) 小时 \(m) 分钟" : "\(m) 分钟"
    }

    public nonisolated static func formatTokens(_ count: Int64) -> String {
        if count == 0 { return "0" }
        let isNegative = count < 0
        let absCount = abs(count)
        let prefix = isNegative ? "-" : ""

        if absCount >= 100_000_000 {
            let val = Double(absCount) / 100_000_000.0
            let str: String
            if val.truncatingRemainder(dividingBy: 1) == 0 {
                str = String(format: "%.0f 亿", val)
            } else if (val * 10).truncatingRemainder(dividingBy: 1) == 0 {
                str = String(format: "%.1f 亿", val)
            } else {
                str = String(format: "%.2f 亿", val)
            }
            return prefix + str
        } else if absCount >= 10_000 {
            let val = Double(absCount) / 10_000.0
            let str: String
            if val.truncatingRemainder(dividingBy: 1) == 0 {
                str = String(format: "%.0f 万", val)
            } else if (val * 10).truncatingRemainder(dividingBy: 1) == 0 {
                str = String(format: "%.1f 万", val)
            } else {
                str = String(format: "%.2f 万", val)
            }
            return prefix + str
        } else {
            return "\(count)"
        }
    }

    public nonisolated static func formatTokens(_ count: Int) -> String {
        formatTokens(Int64(count))
    }

    // MARK: - Agent 一键配置与卸载支持
    public func isHermesInstalled() -> Bool {
        hermesConfigurator.isHermesInstalled
    }

    public func isHermesConfigured() -> Bool {
        hermesConfigurator.isConfigured
    }

    public func configureHermesAgent() async -> (success: Bool, message: String) {
        let port = GatewaySupervisor.shared.port
        let token = GatewaySupervisor.shared.localToken
        let baseURL = "http://127.0.0.1:\(port)/v1"
        let configurator = hermesConfigurator
        let models = hermesPickerModels

        do {
            guard let defaultModel = preferredHermesDefault(from: models) else {
                throw HermesGatewayConfigurationError.noGatewayModel
            }
            try await Task.detached(priority: .userInitiated) {
                try configurator.configure(
                    baseURL: baseURL,
                    apiKey: token,
                    models: models,
                    defaultModel: defaultModel
                )
            }.value
            agentCatalogDefaults.set(catalogFingerprint(models), forKey: hermesCatalogFingerprintKey)
            hermesAgentInstalled = true
            hermesAgentConfigured = true
            NotificationCenter.default.post(name: .agentIntegrationStatusDidChange, object: self)
            return (true, "Hermes 已接入 Tomo Gateway · 默认模型：\(defaultModel) · \(baseURL)")
        } catch {
            return (false, "配置 Hermes 失败：\(error.localizedDescription)")
        }
    }

    public func unconfigureHermesAgent() async -> (success: Bool, message: String) {
        let configurator = hermesConfigurator
        do {
            try await Task.detached(priority: .userInitiated) {
                try configurator.unconfigure()
            }.value
            agentCatalogDefaults.removeObject(forKey: hermesCatalogFingerprintKey)
            hermesAgentConfigured = false
            NotificationCenter.default.post(name: .agentIntegrationStatusDidChange, object: self)
            return (true, "已成功从 Hermes 卸载 Tomo Gateway 配置")
        } catch {
            return (false, "卸载 Hermes 配置失败：\(error.localizedDescription)")
        }
    }

    public func configureHermesLanBypass() async -> (success: Bool, message: String) {
        let configurator = hermesConfigurator
        do {
            try await Task.detached(priority: .userInitiated) {
                try configurator.configureLanBypass()
            }.value
            hermesLanBypassConfigured = true
            return (true, "已成功向 ~/.hermes/.env 写入局域网直连白名单")
        } catch {
            return (false, "配置白名单失败：\(error.localizedDescription)")
        }
    }

    public func unconfigureHermesLanBypass() async -> (success: Bool, message: String) {
        let configurator = hermesConfigurator
        do {
            try await Task.detached(priority: .userInitiated) {
                try configurator.unconfigureLanBypass()
            }.value
            hermesLanBypassConfigured = false
            return (true, "已成功从 ~/.hermes/.env 移除局域网直连白名单")
        } catch {
            return (false, "移除白名单失败：\(error.localizedDescription)")
        }
    }

    public func isPiInstalled() -> Bool {
        piConfigurator.isPiInstalled
    }

    public func isPiConfigured() -> Bool {
        piConfigurator.isConfigured
    }

    public var hermesExecutablePath: String? {
        hermesConfigurator.executableURL?.path
    }

    public var piExecutablePath: String? {
        piConfigurator.executableURL?.path
    }

    public func refreshAgentIntegrationStatus(notifyPeers: Bool = true) async {
        guard !isRefreshingAgentIntegrationStatus else { return }
        isRefreshingAgentIntegrationStatus = true
        defer {
            isRefreshingAgentIntegrationStatus = false
            hasLoadedAgentIntegrationStatus = true
        }

        let hermes = hermesConfigurator
        let pi = piConfigurator
        let dsh = dshConfigurator
        let status = await Task.detached(priority: .utility) {
            (
                hermesInstalled: hermes.isHermesInstalled,
                hermesConfigured: hermes.isConfigured,
                hermesLanBypass: hermes.isLanBypassConfigured,
                piInstalled: pi.isPiInstalled,
                piConfigured: pi.isConfigured,
                dshInstalled: dsh.isDSHInstalled,
                dshConfigured: dsh.isConfigured,
                dshShadowed: dsh.isCredentialShadowedByEnvironment
            )
        }.value
        hermesAgentInstalled = status.hermesInstalled
        hermesAgentConfigured = status.hermesConfigured
        hermesLanBypassConfigured = status.hermesLanBypass
        piAgentInstalled = status.piInstalled
        piAgentConfigured = status.piConfigured
        dshAgentInstalled = status.dshInstalled
        dshAgentConfigured = status.dshConfigured
        dshCredentialShadowed = status.dshShadowed
        dshAvailableModelCount = deduplicatedDSHModels().count
        if notifyPeers {
            NotificationCenter.default.post(name: .agentIntegrationStatusDidChange, object: self)
        }
    }

    public func configurePiAgent(defaultModel requestedModel: String? = nil) async -> (success: Bool, message: String) {
        let port = GatewaySupervisor.shared.port
        let token = GatewaySupervisor.shared.localToken
        let baseURL = "http://127.0.0.1:\(port)/v1"
        let models = allExportedModels.map { Self.agentCompatibleModelID($0.modelName) }
        let requestedWireModel = requestedModel.map(Self.agentCompatibleModelID)
        let defaultModel = requestedWireModel ?? models.first
        let configurator = piConfigurator

        do {
            guard let defaultModel, !defaultModel.isEmpty else {
                throw PiGatewayConfigurationError.noGatewayModel
            }
            try await Task.detached(priority: .userInitiated) {
                try configurator.configure(
                    baseURL: baseURL,
                    apiKey: token,
                    models: models,
                    defaultModel: defaultModel
                )
            }.value
            agentCatalogDefaults.set(catalogFingerprint(models), forKey: piCatalogFingerprintKey)
            piAgentInstalled = true
            piAgentConfigured = true
            NotificationCenter.default.post(name: .agentIntegrationStatusDidChange, object: self)
            return (true, "Pi 已接入 Tomo Gateway · 默认模型：\(defaultModel) · \(baseURL)")
        } catch {
            return (false, "配置 Pi 失败：\(error.localizedDescription)")
        }
    }

    public func unconfigurePiAgent() async -> (success: Bool, message: String) {
        let configurator = piConfigurator
        do {
            try await Task.detached(priority: .userInitiated) {
                try configurator.unconfigure()
            }.value
            agentCatalogDefaults.removeObject(forKey: piCatalogFingerprintKey)
            piAgentConfigured = false
            NotificationCenter.default.post(name: .agentIntegrationStatusDidChange, object: self)
            return (true, "已成功从 Pi 卸载 Tomo Gateway 配置")
        } catch {
            return (false, "卸载 Pi 配置失败：\(error.localizedDescription)")
        }
    }

    // MARK: - DSH (DeepSeek Harness) 一键接入

    public var dshSettingsPath: String { dshConfigurator.primarySettingsURL.path }
    public var dshCredentialsPath: String { dshConfigurator.credentialsURL.path }

    /// DSH has no `settings`/`credentials` CLI, so the integration surface is
    /// the two documents the DSH Models page itself writes.
    ///
    /// Every entry carries an explicit, conservative capacity because
    /// `/v1/models` publishes no sizing metadata; leaving a model unsized would
    /// adopt the adapter's 262,144 / 32,768 defaults, and an over-claimed
    /// context is rejected mid-turn after the message is already durable.
    /// DSH has no `settings`/`credentials` CLI, so the integration surface is
    /// the two documents the DSH Models page itself writes.
    ///
    /// Every entry carries an explicit, conservative capacity because
    /// `/v1/models` publishes no sizing metadata; leaving a model unsized would
    /// adopt the adapter's 262,144 / 32,768 defaults, and an over-claimed
    /// context is rejected mid-turn after the message is already durable.
    func deduplicatedDSHModels() -> [DSHModel] {
        var seen = Set<String>()
        var result: [DSHModel] = []
        let overrides = gatewaySettings.modelCapabilityOverrides

        // 优先遵循 /v1/models 接口的实际模型列表
        if !v1Models.isEmpty {
            for item in v1Models {
                let id = Self.agentCompatibleModelID(item.id)
                guard !id.isEmpty, !id.contains(where: { $0.isWhitespace }), !seen.contains(id) else { continue }
                seen.insert(id)
                let userOverride = overrides[id] ?? overrides[ModelCapabilityRegistry.normalizeModelSlug(id)]
                let capability = ModelCapabilityRegistry.resolveCapability(for: id, override: userOverride)
                let reasoningEfforts = DSHModelReasoning.from(levels: capability.reasoningLevels)
                result.append(
                    DSHModel(
                        id: id,
                        name: item.effectiveDisplayName,
                        contextWindow: capability.contextWindow,
                        maxTokens: capability.maxTokens,
                        input: DSHModelModality.input(supportsImage: capability.supportsImage),
                        reasoning: reasoningEfforts
                    )
                )
            }
            return result
        }

        // 回退兜底：若暂未获取到 /v1/models，使用本地导出的模型列表
        for model in allExportedModels {
            let id = Self.agentCompatibleModelID(model.modelName)
            guard !id.isEmpty, !id.contains(where: { $0.isWhitespace }), !seen.contains(id) else { continue }
            seen.insert(id)
            let userOverride = overrides[id] ?? overrides[ModelCapabilityRegistry.normalizeModelSlug(id)]
            let capability = ModelCapabilityRegistry.resolveCapability(for: id, override: userOverride)
            let reasoningEfforts = DSHModelReasoning.from(levels: capability.reasoningLevels)
            result.append(
                DSHModel(
                    id: id,
                    name: model.modelName,
                    contextWindow: capability.contextWindow,
                    maxTokens: capability.maxTokens,
                    input: DSHModelModality.input(supportsImage: capability.supportsImage),
                    reasoning: reasoningEfforts
                )
            )
        }
        return result
    }

    /// Fingerprint of the whole generated route entry, not just its model ids.
    ///
    /// An id-only fingerprint cannot see a change to a model's declared
    /// capacity, modalities or thinking levels, so a corrected capability table
    /// would never reach an already-configured document through the automatic
    /// sync.
    nonisolated static func dshCatalogFingerprint(_ models: [DSHModel]) -> String {
        models
            .map { model in
                let reasoning = model.reasoning
                    .map { "\($0.level)=\($0.wire ?? "")" }
                    .joined(separator: ",")
                return "\(model.id)|\(model.contextWindow)|\(model.maxTokens)"
                    + "|\(model.input.joined(separator: ","))|\(reasoning)"
            }
            .sorted()
            .joined(separator: "\n")
    }

    public func configureDSHAgent(setAsDefaultModel: Bool = false) async -> (success: Bool, message: String) {
        await fetchV1Models()
        let baseURL = "http://127.0.0.1:\(GatewaySupervisor.shared.port)/v1"
        let token = GatewaySupervisor.shared.localToken
        let configurator = dshConfigurator
        let models = deduplicatedDSHModels()

        do {
            guard !models.isEmpty else {
                throw DSHGatewayConfigurationError.noGatewayModel
            }
            try await Task.detached(priority: .userInitiated) {
                try configurator.configure(
                    baseURL: baseURL,
                    apiKey: token,
                    models: models,
                    setAsAgentDefaultModel: setAsDefaultModel
                )
            }.value
            agentCatalogDefaults.set(Self.dshCatalogFingerprint(models), forKey: dshCatalogFingerprintKey)
            dshAgentInstalled = true
            dshAgentConfigured = true
            dshCredentialShadowed = configurator.isCredentialShadowedByEnvironment
            dshAvailableModelCount = models.count
            NotificationCenter.default.post(name: .agentIntegrationStatusDidChange, object: self)
            return (
                true,
                "DSH 已接入 Tomo Gateway · \(models.count) 个模型 · \(baseURL)（已写入并读回校验通过；配置热重载，无需重启 dsh）"
            )
        } catch {
            return (false, "配置 DSH 失败：\(error.localizedDescription)")
        }
    }

    public func unconfigureDSHAgent() async -> (success: Bool, message: String) {
        let configurator = dshConfigurator
        do {
            try await Task.detached(priority: .userInitiated) {
                try configurator.unconfigure()
            }.value
            agentCatalogDefaults.removeObject(forKey: dshCatalogFingerprintKey)
            dshAgentConfigured = false
            NotificationCenter.default.post(name: .agentIntegrationStatusDidChange, object: self)
            return (true, "已成功从 DSH 卸载 Tomo Gateway 配置")
        } catch {
            return (false, "卸载 DSH 配置失败：\(error.localizedDescription)")
        }
    }

    /// Refresh the DSH route's model catalog.
    ///
    /// A refresh is expressible directly: the route span is rewritten in one
    /// atomic commit, so retired models disappear and new ones appear without
    /// any window where the route is unconfigured. The remove-then-reconnect
    /// fallback is therefore not needed, and this reports whether the document
    /// actually changed so the UI can distinguish "已刷新" from "已是最新".
    public func refreshDSHModels() async -> (success: Bool, message: String) {
        await fetchV1Models()
        let baseURL = "http://127.0.0.1:\(GatewaySupervisor.shared.port)/v1"
        let token = GatewaySupervisor.shared.localToken
        let configurator = dshConfigurator
        let models = deduplicatedDSHModels()

        do {
            guard !models.isEmpty else {
                throw DSHGatewayConfigurationError.noGatewayModel
            }
            let changed = try await Task.detached(priority: .userInitiated) {
                try configurator.refreshModels(baseURL: baseURL, apiKey: token, models: models)
            }.value
            agentCatalogDefaults.set(Self.dshCatalogFingerprint(models), forKey: dshCatalogFingerprintKey)
            dshAgentInstalled = true
            dshAgentConfigured = true
            dshCredentialShadowed = configurator.isCredentialShadowedByEnvironment
            dshAvailableModelCount = models.count
            NotificationCenter.default.post(name: .agentIntegrationStatusDidChange, object: self)
            if changed {
                return (true, "DSH 模型列表已刷新为 \(models.count) 个模型（热重载生效）")
            }
            return (true, "DSH 模型列表已是最新（\(models.count) 个模型，未改动配置文档）")
        } catch {
            return (false, "刷新 DSH 模型列表失败：\(error.localizedDescription)")
        }
    }

    /// Refresh the configured Agent allowlists after account discovery. This
    /// is intentionally fingerprinted: an unchanged periodic refresh never
    /// rewrites client configuration, while a newly published official model
    /// is available without asking the user to reconnect the Agent manually.
    public func syncConfiguredAgentCatalogsIfNeeded() async {
        let hermesModels = hermesPickerModels
        if hermesConfigurator.isConfigured,
           !hermesModels.isEmpty,
           agentCatalogDefaults.string(forKey: hermesCatalogFingerprintKey) != catalogFingerprint(hermesModels) {
            _ = await configureHermesAgent()
        }

        let piModels = allExportedModels.map { Self.agentCompatibleModelID($0.modelName) }
        if piConfigurator.isConfigured,
           !piModels.isEmpty,
           agentCatalogDefaults.string(forKey: piCatalogFingerprintKey) != catalogFingerprint(piModels) {
            _ = await configurePiAgent()
        }

        if dshConfigurator.isConfigured {
            await fetchV1Models()
            let dshModels = deduplicatedDSHModels()
            if !dshModels.isEmpty,
               agentCatalogDefaults.string(forKey: dshCatalogFingerprintKey) != Self.dshCatalogFingerprint(dshModels) {
                _ = await refreshDSHModels()
            }
        }
    }

    /// Rotates the Gateway authentication token to a new cryptographically secure random value.
    /// Hot-swaps the token on the running Gateway server (with a 60s grace period for in-flight requests),
    /// persists to settings, and smoothly propagates the new key to configured agents (Hermes, Pi).
    public func rotateAuthToken() async -> (success: Bool, message: String) {
        let newToken = GatewaySettings.generateSecureToken()
        let oldToken = localToken

        // 1. Hot-rotate Gateway server token if running
        let supervisor = GatewaySupervisor.shared
        if supervisor.isRunning, let endpoint = supervisor.endpoint {
            var req = URLRequest(url: endpoint.appendingPathComponent("internal/token/rotate"))
            req.httpMethod = "POST"
            req.setValue("Bearer \(oldToken)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let payload = ["new_token": newToken]
            if let body = try? JSONSerialization.data(withJSONObject: payload) {
                req.httpBody = body
                _ = try? await URLSession.loopbackDirect.data(for: req)
            }
        }

        // 2. Persist to gateway settings and update supervisor
        gatewaySettings.authToken = newToken
        supervisor.updateLocalToken(newToken)

        // 3. Smoothly update configured agents
        var syncedAgents: [String] = []
        var failedAgents: [String] = []

        if hermesConfigurator.isConfigured {
            do {
                try hermesConfigurator.updateApiKey(newToken)
                syncedAgents.append("Hermes")
            } catch {
                failedAgents.append("Hermes (\(error.localizedDescription))")
            }
        }

        if piConfigurator.isConfigured {
            do {
                try piConfigurator.updateApiKey(newToken)
                syncedAgents.append("Pi")
            } catch {
                failedAgents.append("Pi (\(error.localizedDescription))")
            }
        }

        if dshConfigurator.isConfigured {
            do {
                try dshConfigurator.updateApiKey(newToken)
                syncedAgents.append("DSH")
            } catch {
                failedAgents.append("DSH (\(error.localizedDescription))")
            }
        }

        NotificationCenter.default.post(name: .agentIntegrationStatusDidChange, object: self)

        if failedAgents.isEmpty {
            if syncedAgents.isEmpty {
                return (true, "Token 已更新为随机高强度码")
            } else {
                return (true, "Token 已更新 · 已平滑同步至 \(syncedAgents.joined(separator: "、"))")
            }
        } else {
            let syncMsg = syncedAgents.isEmpty ? "" : "已同步 \(syncedAgents.joined(separator: "、"))，"
            return (false, "Token 已更新但 \(syncMsg)部分 Agent 同步失败：\(failedAgents.joined(separator: "、"))")
        }
    }
}
