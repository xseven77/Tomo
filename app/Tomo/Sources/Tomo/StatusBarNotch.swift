import AppKit
import Foundation

// MARK: - 刘海屏检测与屏幕度量

/// 从 WindowServer 的菜单栏窗口中匹配指定显示器。外接屏启用独立 Spaces 时，
/// `visibleFrame` 可能仍等于完整 `frame`，不能据此判断菜单栏不存在。
enum MenuBarWindowGeometry {
    static func matchingHeight(
        displayBounds: CGRect,
        menuBarBounds: [CGRect]
    ) -> CGFloat? {
        let tolerance: CGFloat = 1
        return menuBarBounds.first { bounds in
            abs(bounds.minX - displayBounds.minX) <= tolerance
                && abs(bounds.minY - displayBounds.minY) <= tolerance
                && abs(bounds.width - displayBounds.width) <= tolerance
                && bounds.height > 0
        }?.height
    }
}

extension NSScreen {
    /// 是否为 MacBook 内建显示器。
    var isBuiltin: Bool {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return false
        }
        return CGDisplayIsBuiltin(number.uint32Value) != 0
    }

    /// 是否为物理刘海屏（仅内建屏可能有刘海；外接屏即使上报 safeArea 也按非刘海处理）。
    var isNotched: Bool {
        isBuiltin && (safeAreaInsets.top > 0 || auxiliaryTopLeftArea != nil)
    }

    /// 刘海高度（安全获取）：
    /// - 内建刘海屏（MacBook Pro 等）：刘海区比状态栏高，保持原有 `safeAreaInsets.top` 逻辑。
    /// - 内建非刘海屏 / 外接屏：统一走「逐屏自适应」的状态栏高度，不写死、不借用其它屏的差值。
    var notchHeight: CGFloat {
        if isNotched {
            return safeAreaInsets.top
        }
        return Self.menuBarHeight(on: self)
    }

    /// 返回「指定屏幕」顶部被系统状态栏（菜单栏）占用的高度。
    ///
    /// 关键点：不能用 `frame.maxY - visibleFrame.maxY` 去遍历所有屏幕取第一个非零值，
    /// 因为不同屏幕的顶部内缩各不相同（刘海屏是刘海内缩 ≈38pt，外接屏是它自己的菜单栏高度），
    /// 套用别屏的值会导致外接屏胶囊偏高或偏矮。优先读取本屏 `frame` 与
    /// `visibleFrame` 的顶部差；独立 Spaces 下外接屏可能错误上报为 0，此时再按
    /// Quartz 显示器坐标匹配 WindowServer 中属于本屏的 Menubar 窗口。
    private static func menuBarHeight(on screen: NSScreen) -> CGFloat {
        let top = screen.frame.maxY - screen.visibleFrame.maxY
        if top > 0 { return top }
        // With separate Spaces, an external screen can report no visibleFrame
        // inset even while WindowServer owns a 30pt menu bar on that display.
        // Match the actual main-menu-level window against this display's
        // Quartz bounds before falling back to the process-global thickness.
        if let windowHeight = menuBarWindowHeightFromWindowServer(on: screen) {
            return windowHeight
        }
        // 兜底：本屏顶部无内缩（例如全屏/自动隐藏菜单栏）时，退回系统菜单栏厚度。
        let thickness = NSStatusBar.system.thickness
        if thickness > 0 { return thickness }
        // 最后兜底：任何 API 都读不到时，用常见菜单栏高度。
        for candidate in NSScreen.screens {
            let inset = candidate.frame.maxY - candidate.visibleFrame.maxY
            if inset > 0 { return inset }
        }
        return 24
    }

    private static func menuBarWindowHeightFromWindowServer(on screen: NSScreen) -> CGFloat? {
        let displayBounds = CGDisplayBounds(screen.screenNumber)
        let menuBarLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        let menuBarBounds = windows.compactMap { window -> CGRect? in
            guard window[kCGWindowLayer as String] as? Int == menuBarLevel,
                  let dictionary = window[kCGWindowBounds as String] as? NSDictionary else {
                return nil
            }
            return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
        }
        return MenuBarWindowGeometry.matchingHeight(
            displayBounds: displayBounds,
            menuBarBounds: menuBarBounds
        )
    }

    /// 物理刘海宽度：内建刘海屏用屏幕宽减去两侧辅助区（+ 少量补偿），其余用基础值 104pt。
    var notchWidth: CGFloat {
        guard isBuiltin,
              let left = auxiliaryTopLeftArea,
              let right = auxiliaryTopRightArea else {
            return 104
        }
        return max(104, frame.width - left.width - right.width + 4)
    }

    /// 显示器名称（系统 API），用于设置列表展示。
    var displayName: String {
        localizedName.isEmpty ? "显示器" : localizedName
    }

    /// 显示器唯一编号（CGDirectDisplayID）。
    var screenNumber: UInt32 {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// 显示器硬件唯一持久标识（基于 CoreGraphics 显示器 UUID，跨插拔、端口变更与系统重启绝对稳定）。
    var persistentID: String {
        if let uuidRef = CGDisplayCreateUUIDFromDisplayID(screenNumber) {
            return CFUUIDCreateString(nil, uuidRef.takeRetainedValue()) as String
        }
        return "screen-\(screenNumber)"
    }
}

/// 监听屏幕参数变化（外接/断开、分辨率、缩放、菜单栏归属），变化后触发重算。
@MainActor
final class MenuBarNotchDetector: NSObject {
    var onChange: (() -> Void)?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        onChange?()
    }
}

// MARK: - 状态栏双维度数据模型

/// 左区 tick：本机某个 Agent 的运行状态（Codex 可登录多个账号，各自独立）。
struct StatusBarAgentTick: Identifiable, Equatable, Sendable {
    /// 刘海导航按任务而不是按 Agent 分页；同一个 Agent 的多个任务必须有独立 id。
    var id: String { taskID ?? "\(name):\(updatedAt?.timeIntervalSince1970 ?? 0)" }
    let name: String
    let state: CodexActivityState
    let taskCount: Int
    let asset: BrandAssetID
    var taskTitle: String
    var taskDetail: String
    var workspaceName: String?
    var gitBranch: String?
    var model: String?
    var updatedAt: Date?
    /// 对应的底层任务 id（用于深链打开该 Agent 的会话）。为空时退回打开 Agent 应用。
    var taskID: String?

    var statusText: String {
        state.statusBarText ?? (state == .unavailable ? "不可用" : "空闲")
    }

    /// 与主页面任务卡片一致的元信息（工作区 / 分支 / 模型）。
    var metadataItems: [(icon: String, value: String)] {
        [
            workspaceName.map { ("folder", $0) },
            gitBranch.map { ("arrow.triangle.branch", $0) },
            model.map { ("cpu", $0) }
        ].compactMap { $0 }
    }
}

extension CodexActivitySnapshot {
    /// 刘海左栏的一页对应一个任务。同 Agent 多任务会保留为多页，避免
    /// 聚合成单个 Agent tick 后左右按钮只能在不同 Agent 之间切换。
    var statusBarTaskTicks: [StatusBarAgentTick] {
        let sortedTasks = activeTasks.sorted { $0.updatedAt > $1.updatedAt }
        let countsByAgent = Dictionary(grouping: sortedTasks, by: \.agentDisplayName)
            .mapValues(\.count)

        return sortedTasks.map { task in
            StatusBarAgentTick(
                name: task.agentDisplayName,
                state: task.state,
                taskCount: countsByAgent[task.agentDisplayName] ?? 1,
                asset: BrandAssetID.forAgentDisplayName(task.agentDisplayName),
                taskTitle: task.title,
                taskDetail: task.detail,
                workspaceName: task.workspaceName,
                gitBranch: task.gitBranch,
                model: task.model,
                updatedAt: task.updatedAt,
                taskID: task.id
            )
        }
    }
}

/// 供应商额度的分段多色项（如 周 81% 与 5h 90% 各自独立根据余量着色）。
struct StatusBarQuotaSegment: Equatable, Sendable {
    let text: String
    let health: QuotaHealthLevel
}

/// 右区 tick：某个账号 / API Key 的额度（与 Agent 独立，API Key 型无对应 Agent）。
struct StatusBarProviderTick: Identifiable, Equatable, Sendable {
    let id: String
    /// 展开面板顶部标题；始终是供应商名称，不能用账号套餐/等级替代。
    let providerName: String
    let accountName: String
    let asset: BrandAssetID
    /// 胶囊短文本，如 "5h 82% · 周 76%" 或 "¥42.80"
    let quotaText: String
    /// 展开面板副值，如 "周 76%" 或 "API Key"
    let detailText: String
    /// 与主界面额度状态共用的红 / 黄 / 绿颜色等级。
    let quotaHealth: QuotaHealthLevel
    /// 分段额度彩色项（若非空则优先按项着色）
    var quotaSegments: [StatusBarQuotaSegment] = []
    /// 该供应商账号对应的工作间跳转地址（例如 OpenCode 的 workspace 页面）。
    /// nil 时面板不展示「工作区跳转」按钮。
    var workspaceURL: String?
    /// 额度刷新/重置时间展示文本（如 "3小时后刷新" 或 "今天 18:30 重置"）。
    var resetTimeText: String?
}

/// 双维度独立轮播索引：左区 Agent 与右区 Provider 各自独立计时切换。
struct StatusBarTicker: Equatable {
    var agentIndex = 0
    var providerIndex = 0

    mutating func advanceAgent(count: Int) {
        guard count > 0 else { agentIndex = 0; return }
        agentIndex = (agentIndex + 1) % count
    }

    mutating func advanceProvider(count: Int) {
        guard count > 0 else { providerIndex = 0; return }
        providerIndex = (providerIndex + 1) % count
    }

    mutating func clampAgent(to count: Int) {
        agentIndex = count > 0 ? min(agentIndex, count - 1) : 0
    }

    mutating func clampProvider(to count: Int) {
        providerIndex = count > 0 ? min(providerIndex, count - 1) : 0
    }
}

// MARK: - 品牌资产映射

extension BrandAssetID {
    /// 把 Agent 显示名映射到品牌图标；未收录的 Agent 回退到 Codex。
    static func forAgentDisplayName(_ name: String) -> BrandAssetID {
        for descriptor in BuiltInAgentCatalog.prioritized where descriptor.displayName == name {
            return agent(descriptor.id)
        }
        let lower = name.lowercased()
        if lower.contains("codex") { return .codex }
        if lower.contains("gemini") { return .googleGemini }
        if lower.contains("antigravity") { return .antigravity }
        if lower.contains("hermes") { return .hermesAgent }
        if lower.contains("deepseek") { return .deepSeek }
        if lower.contains("opencode") { return .openCode }
        return .codex
    }
}

// MARK: - 额度 tick 提取

enum StatusBarProviderTickFactory {
    private static func percentageSegment(
        label: String,
        ratio: Double,
        isConnected: Bool
    ) -> StatusBarQuotaSegment {
        let normalizedRatio = min(max(ratio, 0), 1)
        return StatusBarQuotaSegment(
            text: "\(label) \(Int(round(normalizedRatio * 100)))%",
            health: isConnected ? QuotaHealthLevel.from(ratio: normalizedRatio) : .gray
        )
    }

    private static func joinedQuotaText(_ segments: [StatusBarQuotaSegment]) -> String {
        segments.map(\.text).joined(separator: " · ")
    }

    /// Codex 连接额度：主值优先周额度（语义清晰稳定），5h 作为副值。
    static func codexTick(
        id: String,
        label: String,
        accountName: String,
        usage: CodexUsageSnapshot?,
        isConnected: Bool = true
    ) -> StatusBarProviderTick? {
        guard let usage, usage.hasShortWindow || usage.hasWeeklyWindow else { return nil }
        var segments: [StatusBarQuotaSegment] = []
        if usage.hasWeeklyWindow {
            segments.append(percentageSegment(
                label: statusBarWindowLabel(usage.weekly.label),
                ratio: usage.weekly.percent,
                isConnected: isConnected
            ))
        }
        if usage.hasShortWindow, let short = usage.shortWindow {
            segments.append(percentageSegment(
                label: statusBarWindowLabel(short.label),
                ratio: short.percent,
                isConnected: isConnected
            ))
        }
        let quotaText = segments.isEmpty ? "无额度" : joinedQuotaText(segments)
        if segments.isEmpty {
            segments = [StatusBarQuotaSegment(text: quotaText, health: .gray)]
        }
        let primaryHealth = segments.first?.health ?? .gray
        let resetRaw = (usage.hasShortWindow ? usage.shortWindow?.resetsAt : nil) ?? usage.weekly.resetsAt
        let resetTimeText: String? = if !resetRaw.isEmpty && resetRaw != "未知" {
            "\(UsageDateFormat.dateAndTime(resetRaw)) 重置"
        } else {
            nil
        }
        return StatusBarProviderTick(
            id: id,
            providerName: "Codex",
            accountName: accountName.isEmpty ? "Codex" : accountName,
            asset: .codex,
            quotaText: quotaText,
            detailText: usage.planName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            quotaHealth: primaryHealth,
            quotaSegments: segments,
            resetTimeText: resetTimeText
        )
    }

    /// DeepSeek API Key 余额。
    static func deepSeekTick(_ connection: DeepSeekAPIConnection) -> StatusBarProviderTick? {
        guard let balance = connection.balance else { return nil }
        let value = NSDecimalNumber(decimal: balance.total).stringValue
        let text = balance.currency == "CNY" ? "¥\(value)" : "\(balance.currency) \(value)"
        let quotaHealth: QuotaHealthLevel = switch ProviderBalanceIndicator.resolve(
            total: balance.total,
            authenticationState: connection.authenticationState
        ) {
        case .healthy: .green
        case .low: .yellow
        case .depleted: .red
        }
        return StatusBarProviderTick(
            id: "deepseek.\(connection.id.rawValue.uuidString.lowercased())",
            providerName: "DeepSeek",
            accountName: connection.label,
            asset: .deepSeek,
            quotaText: text,
            detailText: "API Key",
            quotaHealth: quotaHealth,
            quotaSegments: [StatusBarQuotaSegment(text: text, health: quotaHealth)]
        )
    }

    /// OpenCode 提供独立的 Go / Zen 模型目录端点，可用于验证 Key；但目前
    /// 没有稳定的公开账户额度接口，因此明确展示为不可查询而非虚构数值。
    static func openCodeTick(_ connection: OpenCodeAPIConnection) -> StatusBarProviderTick {
        let connected = connection.authenticationState == .connected
        let quotaText = connection.plan == .go ? "额度暂不可查" : "余额暂不可查"
        let detailText: String
        switch connection.plan {
        case .go: detailText = "5h / 周 / 月额度"
        case .zen:
            detailText = connection.availableModelCount.map { "已验证 \($0) 个模型" } ?? "API Key"
        }
        let health: QuotaHealthLevel = connected ? .green : .yellow
        return StatusBarProviderTick(
            id: connection.plan == .go
                ? "opencode-go.\(connection.id.rawValue.uuidString.lowercased())"
                : "opencode-zen.\(connection.id.rawValue.uuidString.lowercased())",
            providerName: connection.plan.displayName,
            accountName: connection.label,
            asset: .openCode,
            quotaText: quotaText,
            detailText: detailText,
            quotaHealth: health,
            quotaSegments: [StatusBarQuotaSegment(text: quotaText, health: health)],
            workspaceURL: connection.workspaceURL
        )
    }

    /// Google Gemini 账号连接。
    static func geminiTick(_ connection: GeminiAccountConnection) -> StatusBarProviderTick {
        let connected = connection.authenticationState == .connected
        let isRateLimited = connection.rateLimitState == "rate_limited"
        let requiresAccountValidation = connection.rateLimitState == "account_validation_required"
        let hasCompleteQuota = connection.geminiWeeklyRemaining != nil
            && connection.geminiFiveHourRemaining != nil
        let isQuotaUnavailable = connection.rateLimitState == "quota_unavailable"
            || connection.rateLimitState == "unauthorized"
            || !hasCompleteQuota
        var segments: [StatusBarQuotaSegment] = []
        let quotaText: String
        if isRateLimited {
            quotaText = "限流中"
            segments = [StatusBarQuotaSegment(text: "限流中", health: .yellow)]
        } else if requiresAccountValidation {
            quotaText = "需要验证账号"
            segments = [StatusBarQuotaSegment(text: quotaText, health: .yellow)]
        } else if isQuotaUnavailable {
            quotaText = "额度暂不可查询"
            segments = [StatusBarQuotaSegment(text: quotaText, health: .gray)]
        } else if let weekly = connection.geminiWeeklyRemaining, let fiveHour = connection.geminiFiveHourRemaining {
            segments = [
                percentageSegment(label: "5h", ratio: fiveHour, isConnected: connected),
                percentageSegment(label: "周", ratio: weekly, isConnected: connected)
            ]
            quotaText = joinedQuotaText(segments)
        } else {
            quotaText = "额度暂不可查询"
            segments = [StatusBarQuotaSegment(text: quotaText, health: .gray)]
        }
        let health: QuotaHealthLevel = if requiresAccountValidation {
            .yellow
        } else if isQuotaUnavailable {
            .gray
        } else if !connected {
            .yellow
        } else if isRateLimited {
            .yellow
        } else if min(connection.geminiWeeklyRemaining ?? 1, connection.geminiFiveHourRemaining ?? 1) < 0.15 {
            .yellow
        } else {
            .green
        }
        let friendlyName = GatewayStore.friendlyAccountName(
            displayName: connection.displayName,
            email: connection.email,
            fallbackLabel: connection.label
        )
        let resetRaw = connection.geminiFiveHourResetDesc ?? connection.geminiWeeklyResetDesc
        let resetTimeText: String? = if !isQuotaUnavailable && !requiresAccountValidation {
            GeminiQuotaResetFormatter.displayText(resetRaw)
        } else {
            nil
        }
        return StatusBarProviderTick(
            id: "gemini.\(connection.id.rawValue.uuidString.lowercased())",
            providerName: "Gemini",
            accountName: friendlyName,
            asset: .googleGemini,
            quotaText: quotaText,
            detailText: connection.resolvedPlanDisplayName,
            quotaHealth: health,
            quotaSegments: segments,
            resetTimeText: resetTimeText
        )
    }
}
