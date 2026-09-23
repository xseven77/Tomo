import AppKit
import SwiftUI

struct CompanionDashboardView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var store: UsageSnapshotStore
    @Bindable var settings: AppSettingsStore
    @Bindable var multiAgentSettings: MultiAgentSettingsStore
    @Bindable var activityStore: CodexActivityStore
    @Bindable var frameStore: PetFrameStore
    @Bindable var companionStatsStore: CompanionStatsStore
    let actions: UsageActions
    let layout: UsagePanelLayout
    let showsDetachedButton: Bool
    let onOpenSettings: () -> Void
    /// 竖向独立窗口上报内容自然高度。
    var onMeasuredContentHeightChange: (CGFloat, String) -> Void = { _, _ in }
    /// logo 行悬停时通知所属窗口临时关闭背景拖拽。
    var onConnectionSwitcherHoverChange: (Bool) -> Void = { _ in }
    /// 有遮罩弹窗（modal overlay）浮现时通知窗口，用于压低标题栏按钮层级。
    var onOverlayPresentationChange: (Bool) -> Void = { _ in }

    @State private var selectedTaskID: String?
    @State private var showsConnectionSheet = false
    @State private var revealedKey: RevealedAPIKey?
    @State private var revealedKeyCopyGeneration = 0
    @State private var openCodeModels: [String]?

    /// 是否正有遮罩弹窗浮现（决定标题栏按钮是否让位）。
    private var presentingOverlay: Bool {
        showsConnectionSheet || revealedKey != nil || openCodeModels != nil
    }

    private var selectedProviderContext: DashboardProviderContext {
        if let connection = multiAgentSettings.selectedDeepSeekConnection {
            let balanceText = connection.balance.map { balance in
                let value = NSDecimalNumber(decimal: balance.total).stringValue
                return balance.currency == "CNY" ? "¥\(value)" : "\(balance.currency) \(value)"
            } ?? "待查询"
            let isConnected = connection.authenticationState == .connected
            return DashboardProviderContext(
                asset: .deepSeek,
                title: connection.label,
                subtitle: "sk-•••• \(connection.keySuffix)",
                badge: "DeepSeek",
                badgeColor: .codexGreen,
                statusText: isConnected ? balanceText : "需要检查",
                statusColor: isConnected ? .codexGreen : .codexAmber,
                summaryText: "DeepSeek API · Key 保存在 macOS Keychain",
                accountLinkTitle: "DeepSeek 控制台",
                accountLinkURL: DashboardProviderLinks.deepSeekUsage,
                officialLinkHelp: "打开 DeepSeek 官方 Usage",
                officialLinkURL: DashboardProviderLinks.deepSeekUsage,
                syncState: isConnected ? "成功" : "Key 异常",
                syncedAt: connection.balance?.fetchedAt ?? connection.createdAt,
                isRefreshing: store.isUnifiedRefreshing,
                emphasizesAccountLink: false
            )
        }

        if let connection = multiAgentSettings.selectedOpenCodeConnection {
            let isConnected = connection.authenticationState == .connected
            let statusText = connection.plan == .go ? "额度暂不可查询" : "余额暂不可查询"
            let workspaceLink = connection.workspaceURL.flatMap { URL(string: $0) }
            let accountLink = workspaceLink ?? DashboardProviderLinks.openCodeConsole
            return DashboardProviderContext(
                asset: .openCode,
                title: connection.label,
                subtitle: "sk-•••• \(connection.keySuffix)",
                badge: connection.plan.displayName,
                badgeColor: .codexGreen,
                statusText: isConnected ? statusText : "需要检查",
                statusColor: isConnected ? .codexGreen : .codexAmber,
                summaryText: connection.plan == .go
                    ? "Go API · 5h / 周 / 月额度待官方 API"
                    : "Zen API · 账户余额待官方 API",
                accountLinkTitle: "OpenCode 页面",
                accountLinkURL: accountLink,
                officialLinkHelp: "打开我的 OpenCode 工作间页面",
                officialLinkURL: accountLink,
                syncState: isConnected ? "已验证" : "Key 异常",
                syncedAt: connection.lastValidatedAt ?? connection.createdAt,
                isRefreshing: store.isUnifiedRefreshing,
                emphasizesAccountLink: false,
                syncColor: isConnected ? .codexGreen : nil,
                syncStateSymbol: isConnected ? "checkmark.shield.fill" : nil
            )
        }

        if let connection = multiAgentSettings.selectedGeminiConnection {
            let isConnected = connection.authenticationState == .connected
            let statusText: String = if !isConnected {
                "需要登录"
            } else if connection.rateLimitState == "account_validation_required" {
                "需要验证 Google 账号"
            } else if connection.rateLimitState == "rate_limited" {
                "限流冷却中"
            } else if connection.rateLimitState == "quota_unavailable" {
                "额度暂不可用"
            } else {
                "额度已同步"
            }
            let plan = connection.resolvedPlanDisplayName
            let planBadgeColor: Color = if connection.rateLimitState == "account_validation_required" {
                .codexAmber
            } else if plan == "Google AI Ultra" {
                .purple
            } else if plan == "Antigravity Free" {
                .codexGreen
            } else if plan == "套餐状态未知" {
                .codexMuted
            } else {
                .codexBlue
            }
            let userName = connection.displayName ?? (connection.email?.components(separatedBy: "@").first ?? "Google 用户")
            let userEmail = connection.email ?? "Google 账号"
            return DashboardProviderContext(
                asset: .googleGemini,
                title: userName,
                subtitle: userEmail,
                badge: plan,
                badgeColor: planBadgeColor,
                statusText: statusText,
                statusColor: isConnected && connection.rateLimitState == "normal" ? .codexGreen : .codexAmber,
                summaryText: "Google AI Studio",
                accountLinkTitle: "Google AI Studio",
                accountLinkURL: DashboardProviderLinks.geminiConsole,
                officialLinkHelp: "打开 Google AI Studio 控制台",
                officialLinkURL: DashboardProviderLinks.geminiConsole,
                syncState: isConnected ? "成功" : "未授权",
                syncedAt: connection.lastValidatedAt ?? connection.createdAt,
                isRefreshing: store.isUnifiedRefreshing,
                emphasizesAccountLink: false,
                syncColor: nil,
                syncStateSymbol: nil
            )
        }

        let snapshot = displayedCodexSnapshot
        return DashboardProviderContext(
            asset: .codex,
            title: snapshot.companionAccountName,
            subtitle: snapshot.accountEmail,
            badge: snapshot.companionPlanBadgeText,
            badgeColor: .codexGreen,
            statusText: activityStore.snapshot.state.taskLabel,
            statusColor: activityStore.snapshot.state.statusColor,
            summaryText: snapshot.subscriptionCompactSummaryLine ?? "订阅与账单",
            accountLinkTitle: "官方 Billing",
            accountLinkURL: ChatGPTWebLinks.billingPage,
            officialLinkHelp: "打开 Codex 官方 Usage",
            officialLinkURL: DashboardProviderLinks.codexUsage,
            syncState: snapshot.refreshState,
            syncedAt: snapshot.fetchedAt,
            isRefreshing: store.isUnifiedRefreshing,
            emphasizesAccountLink: snapshot.showsSubscriptionExpiryReminder
        )
    }

    /// 选中的 Codex 快照来自统一连接注册表。
    private var displayedCodexSnapshot: CodexUsageSnapshot {
        if let account = multiAgentSettings.selectedCodexAccount, let usage = account.usage {
            return usage
        }
        return store.snapshot
    }

    /// 是否处于「已连接 Codex」状态。
    private var isCodexConnected: Bool {
        if multiAgentSettings.codexAccounts.isEmpty {
            return store.isLoggedIn
        }
        if let account = multiAgentSettings.selectedCodexAccount {
            return account.authenticationState == .connected
        }
        return false
    }

    private var hasSelectedAPIKeyProvider: Bool {
        multiAgentSettings.selectedDeepSeekConnection != nil
            || multiAgentSettings.selectedOpenCodeConnection != nil
    }

    private var showsCompanionAccountRow: Bool {
        (isCodexConnected || multiAgentSettings.selectedGeminiConnection != nil) && !hasSelectedAPIKeyProvider
    }

    /// 订阅到期提醒来自当前选中的 Codex 快照，仅在已连接且未切到 DeepSeek 时展示。
    private var showsCodexSubscriptionExpiryReminder: Bool {
        guard isCodexConnected else { return false }
        guard multiAgentSettings.selectedDeepSeekConnection == nil,
              multiAgentSettings.selectedOpenCodeConnection == nil,
              multiAgentSettings.selectedGeminiConnection == nil else { return false }
        return displayedCodexSnapshot.showsSubscriptionExpiryReminder
    }

    private func refreshSelectedProvider() {
        actions.refresh()
    }

    /// 当前选中供应商是否为本地保存了 API Key 的连接（OpenCode / DeepSeek）。
    private var selectedAPIKeyConnection: ConnectionID? {
        if let connection = multiAgentSettings.selectedOpenCodeConnection {
            return connection.id
        }
        if let connection = multiAgentSettings.selectedDeepSeekConnection {
            return connection.id
        }
        return nil
    }

    /// 存在可查看的 API Key 时返回眼睛按钮动作，否则返回 nil（隐藏按钮）。
    private var selectedProviderRevealAction: (() -> Void)? {
        guard selectedAPIKeyConnection != nil else { return nil }
        return { self.presentSelectedProviderKeyReveal() }
    }

    /// 点击小眼睛：先系统认证，通过后读取并展示 API Key。流程与设置页一致。
    private func presentSelectedProviderKeyReveal() {
        guard let connectionID = selectedAPIKeyConnection else { return }
        Task { @MainActor in
            do {
                try await APIAuthRevealService.authorize()
                let key = try multiAgentSettings.revealedAPIKey(for: connectionID)
                revealedKey = RevealedAPIKey(connectionID: connectionID, value: key)
            } catch {
                // 取消认证或读取失败都静默关闭；不打扰用户。
            }
        }
    }

    private func copyRevealedKey(_ key: RevealedAPIKey) {
        revealedKeyCopyGeneration += 1
        let generation = revealedKeyCopyGeneration
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key.value, forType: .string)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard generation == revealedKeyCopyGeneration else { return }
            revealedKey = nil
        }
    }

    var body: some View {
        Group {
            switch settings.dashboardOrientation {
            case .horizontal:
                dashboard
            case .vertical:
                verticalDashboard
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(Color.codexInk)
        .overlay(alignment: .topLeading) {
            if layout == .window {
                verticalDashboardHeightProbe
            }
        }
        .onPreferenceChange(DashboardMeasuredContentSizeKey.self) { size in
            guard layout == .window,
                  DetachedWindowMetrics.isValidVerticalMeasurement(size) else {
                return
            }
            onMeasuredContentHeightChange(size.height, verticalDashboardMeasureIdentity)
        }
        .onChange(of: activityStore.snapshot.activeTasks.map(\.id)) { _, ids in
            if let selectedTaskID, !ids.contains(selectedTaskID) {
                self.selectedTaskID = ids.first
            }
        }
        .onChange(of: presentingOverlay) { _, showing in
            onOverlayPresentationChange(showing)
        }
        .onAppear {
            onOverlayPresentationChange(presentingOverlay)
        }
        .overlay {
            if showsConnectionSheet {
                ZStack {
                    Rectangle()
                        .fill(Color.black.opacity(colorScheme == .dark ? 0.52 : 0.20))
                        .background(.ultraThinMaterial)
                        .ignoresSafeArea()
                        .onTapGesture { showsConnectionSheet = false }

                    AccountConnectionsModalView(store: multiAgentSettings) {
                        showsConnectionSheet = false
                    }
                    .padding(14)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
                .zIndex(20)
            }
        }
        .overlay {
            if let revealedKey {
                GeometryReader { proxy in
                    ZStack {
                        Rectangle()
                            .fill(Color.black.opacity(colorScheme == .dark ? 0.52 : 0.20))
                            .background(.ultraThinMaterial)
                            .ignoresSafeArea()
                            .onTapGesture { self.revealedKey = nil }

                        APIKeyRevealModal(
                            key: revealedKey,
                            onCopy: { copyRevealedKey(revealedKey) }
                        ) {
                            self.revealedKey = nil
                        }
                        .frame(width: min(360, proxy.size.width - 28))
                        .padding(14)
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                    }
                }
                .zIndex(30)
            }
        }
        .overlay {
            if let openCodeModels {
                GeometryReader { proxy in
                    ZStack {
                        Rectangle()
                            .fill(Color.black.opacity(colorScheme == .dark ? 0.52 : 0.20))
                            .background(.ultraThinMaterial)
                            .ignoresSafeArea()
                            .onTapGesture { self.openCodeModels = nil }

                        OpenCodeModelsModal(
                            models: openCodeModels
                        ) {
                            self.openCodeModels = nil
                        }
                        .frame(width: min(380, proxy.size.width - 28))
                        .padding(14)
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                    }
                }
                .zIndex(31)
            }
        }
        .animation(.easeOut(duration: 0.18), value: showsConnectionSheet)
    }

    private var dashboard: some View {
        Group {
            if layout == .window {
                horizontalDashboardWindowLayout
            } else {
                horizontalDashboardCompactLayout
            }
        }
    }

    /// 独立横版：`GeometryReader` 贴合 AppKit contentLayoutRect，避免 frame/content 偏差。
    private var horizontalDashboardWindowLayout: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 0) {
                CompanionPetHeader(
                    snapshot: store.snapshot,
                    activity: activityStore.snapshot,
                    integrations: multiAgentSettings.integrations,
                    settings: settings,
                    frameStore: frameStore,
                    todayMinutes: companionStatsStore.todayMinutes,
                    fillHeight: true,
                    selectedTaskID: $selectedTaskID
                )
                .frame(width: DetachedWindowMetrics.sidebarWidth)
                .frame(maxHeight: .infinity)
                .zIndex(30)

                VStack(spacing: 0) {
                    dashboardConnectionBar

                    dashboardContentFrame(fillsHeight: true) {
                        if showsCompanionAccountRow {
                            CompanionAccountRow(context: selectedProviderContext)
                        }

                        horizontalDashboardMainContent

                        Spacer(minLength: 0)

                        SyncFooterView(
                            context: selectedProviderContext,
                            actions: actions,
                            showsDetachedButton: showsDetachedButton,
                            onRefresh: refreshSelectedProvider,
                            onOpenSettings: onOpenSettings,
                            onRevealKey: selectedProviderRevealAction
                        )
                        .padding(.horizontal, DetachedWindowMetrics.dashboardContentPadding)
                        .padding(.bottom, 14)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .background {
                DashboardWindowChromeBackground(accentColor: settings.themeConfig.accentColor)
            }
        }
    }

    private var horizontalDashboardCompactLayout: some View {
        HStack(alignment: .top, spacing: 0) {
            CompanionPetHeader(
                snapshot: store.snapshot,
                activity: activityStore.snapshot,
                integrations: multiAgentSettings.integrations,
                settings: settings,
                frameStore: frameStore,
                todayMinutes: companionStatsStore.todayMinutes,
                fillHeight: true,
                selectedTaskID: $selectedTaskID
            )
            .frame(width: DetachedWindowMetrics.sidebarWidth)
            .frame(maxHeight: .infinity)
            .zIndex(30)

            VStack(spacing: 0) {
                dashboardConnectionBar

                dashboardContentFrame(fillsHeight: true) {
                    if showsCompanionAccountRow {
                        CompanionAccountRow(context: selectedProviderContext)
                    }

                    horizontalDashboardRightColumn
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            DashboardWindowChromeBackground(accentColor: settings.themeConfig.accentColor)
                .ignoresSafeArea()
        }
    }

    /// 右栏决定横版独立窗口高度；勿把侧栏 `maxHeight: .infinity` 算进测高。
    private var horizontalDashboardRightColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            horizontalDashboardMainContent
            horizontalDashboardSyncFooter
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .background(Color.codexCard.opacity(0.96))
    }

    private var horizontalDashboardMainContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsCodexSubscriptionExpiryReminder,
               let message = store.snapshot.subscriptionExpiryReminderMessage {
                SubscriptionExpiryReminderBanner(message: message)
                    .padding(.top, 12)
                    .padding(.bottom, 12)
            }

            selectedConnectionSection
        }
        .padding(.top, layout == .window ? 12 : 15)
        .padding(.horizontal, DetachedWindowMetrics.dashboardContentPadding)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dashboardConnectionBar: some View {
        DashboardConnectionSwitcher(
            snapshot: store.snapshot,
            store: multiAgentSettings,
            onAdd: { showsConnectionSheet = true },
            compact: true,
            reportsHover: true,
            onHoverChange: connectionSwitcherHoverChanged
        )
        .padding(.trailing, 7)
        .frame(height: 59)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.codexCard.opacity(0.96))
        .overlay(alignment: .bottom) { CodexDivider() }
    }

    private var horizontalDashboardSyncFooter: some View {
        SyncFooterView(
            context: selectedProviderContext,
            actions: actions,
            showsDetachedButton: showsDetachedButton,
            onRefresh: refreshSelectedProvider,
            onOpenSettings: onOpenSettings,
            onRevealKey: selectedProviderRevealAction
        )
        .padding(.horizontal, DetachedWindowMetrics.dashboardContentPadding)
        .padding(.bottom, layout == .window ? 14 : 16)
    }

    private var quotaSection: some View {
        let snapshot = displayedCodexSnapshot
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("额度")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if let nextReset = snapshot.detailWindow?.resetsAt {
                    Text("额度重置：\(UsageDateFormat.dateAndTime(nextReset))")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.codexMuted)
                }
            }

            QuotaCardsView(snapshot: snapshot, isLoggedIn: isCodexConnected)

            ResetCouponSummaryView(coupons: snapshot.resetCoupons)
                .padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)

            Label("实时同步 OpenAI Codex 额度与速率限制", systemImage: "checkmark.shield")
                .font(.system(size: 9))
                .foregroundStyle(Color.codexMuted)
        }
        .padding(.top, 18)
    }

    // MARK: - 共用：主体内容外框

    /// 统一的背景色 + 层级外框，内部内容由调用方组合。
    @ViewBuilder
    private func dashboardContentFrame<Content: View>(
        fillsHeight: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0, content: content)
        .frame(maxWidth: .infinity,
               maxHeight: fillsHeight ? .infinity : nil,
               alignment: .topLeading)
        .background(Color.codexCard, in: RoundedRectangle(cornerRadius: 0))
        .zIndex(30)
        .onHover { hovering in
            multiAgentSettings.setAccountCarouselPaused(hovering, source: .dashboardInfo)
        }
        .onDisappear {
            multiAgentSettings.setAccountCarouselPaused(false, source: .dashboardInfo)
        }
    }

    // MARK: - 竖向布局

    private var verticalDashboard: some View {
        Group {
            if layout == .window {
                verticalDashboardWindowLayout
            } else {
                verticalDashboardMeasureColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background {
                        Color.codexCard.ignoresSafeArea()
                }
            }
        }
    }

    /// 竖向独立窗口使用切换前预排版得到的自然高度，不在内容区引入滚动。
    private var verticalDashboardWindowLayout: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                CompanionPetHeader(
                    snapshot: store.snapshot,
                    activity: activityStore.snapshot,
                    integrations: multiAgentSettings.integrations,
                    settings: settings,
                    frameStore: frameStore,
                    todayMinutes: companionStatsStore.todayMinutes,
                    selectedTaskID: $selectedTaskID
                )
                .zIndex(30)

                DashboardConnectionSwitcher(
                    snapshot: store.snapshot,
                    store: multiAgentSettings,
                    onAdd: { showsConnectionSheet = true },
                    compact: true,
                    reportsHover: true,
                    onHoverChange: connectionSwitcherHoverChanged
                )
                .padding(.trailing, 7)
                .frame(height: 59)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.codexCard.opacity(0.96))
                .overlay(alignment: .bottom) { CodexDivider() }

                dashboardContentFrame(fillsHeight: true) {
                    // 供应商信息区铺满 header 与 footer 之间的剩余空间（带来呼吸感），
                    // 内容超出后在区域内竖向滚动查看；footer 固定在下方始终可见。
                    // 滚动区自身不设 padding，各内部部件自带间距与内边距。
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if showsCompanionAccountRow {
                                CompanionAccountRow(context: selectedProviderContext)
                            }

                            if showsCodexSubscriptionExpiryReminder,
                               let message = store.snapshot.subscriptionExpiryReminderMessage {
                                SubscriptionExpiryReminderBanner(message: message)
                                    .padding(.horizontal, DetachedWindowMetrics.verticalContentPadding)
                            }
                            selectedVerticalConnectionSection
                        }
                        // Codex / Gemini 页有用户信息行时顶部无需留白；OpenCode / DeepSeek 等
                        // 无该行的页面恢复顶部 18pt padding。
                        .padding(.top, showsCompanionAccountRow ? 0 : 18)
                    }
                    // 在窗口布局里铺满 header 与 footer 之间的剩余空间，footer 固定在底部始终可见。
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scrollIndicators(.never)
                }

                SyncFooterView(
                    context: selectedProviderContext,
                    actions: actions,
                    showsDetachedButton: showsDetachedButton,
                    isCompact: true,
                    onRefresh: refreshSelectedProvider,
                    onOpenSettings: onOpenSettings,
                    onRevealKey: selectedProviderRevealAction
                )
                .padding(.horizontal, DetachedWindowMetrics.verticalContentPadding)
                .padding(.bottom, 14)
                .background(Color.codexCard)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .background { Color.codexCard }
        }
    }

    private var verticalDashboardHeaderStack: some View {
        VStack(spacing: 0) {
            CompanionPetHeader(
                snapshot: store.snapshot,
                activity: activityStore.snapshot,
                integrations: multiAgentSettings.integrations,
                settings: settings,
                frameStore: frameStore,
                todayMinutes: companionStatsStore.todayMinutes,
                selectedTaskID: $selectedTaskID
            )
            .zIndex(30)

            DashboardConnectionSwitcher(
                snapshot: store.snapshot,
                store: multiAgentSettings,
                onAdd: { showsConnectionSheet = true },
                compact: true,
                reportsHover: false
            )
            .padding(.trailing, 7)
            .frame(height: 59)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.codexCard.opacity(0.96))
            .overlay(alignment: .bottom) { CodexDivider() }

            dashboardContentFrame(fillsHeight: false) {
                // 供应商信息区：测量用自然高度（至少 minHeight），窗口内用 fillsHeight 铺满剩余空间。
                // 滚动区自身不设 padding，各内部部件自带间距与内边距。
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if showsCompanionAccountRow {
                            CompanionAccountRow(context: selectedProviderContext)
                        }

                        if showsCodexSubscriptionExpiryReminder,
                           let message = store.snapshot.subscriptionExpiryReminderMessage {
                            SubscriptionExpiryReminderBanner(message: message)
                                .padding(.horizontal, DetachedWindowMetrics.verticalContentPadding)
                        }
                        selectedVerticalConnectionSection
                    }
                    .padding(.top, showsCompanionAccountRow ? 0 : 18)
                }
                .frame(minHeight: DetachedWindowMetrics.verticalScrollContentHeight)
                .scrollIndicators(.never)

                SyncFooterView(
                    context: selectedProviderContext,
                    actions: actions,
                    showsDetachedButton: showsDetachedButton,
                    isCompact: true,
                    onRefresh: refreshSelectedProvider,
                    onOpenSettings: onOpenSettings,
                    onRevealKey: selectedProviderRevealAction
                )
                .padding(.horizontal, DetachedWindowMetrics.verticalContentPadding)
                .padding(.bottom, 14)
            }
        }
    }

    private func connectionSwitcherHoverChanged(_ hovering: Bool) {
        multiAgentSettings.setAccountCarouselPaused(hovering)
        onConnectionSwitcherHoverChange(hovering)
    }

    private var verticalDashboardSyncFooter: some View {
        SyncFooterView(
            context: selectedProviderContext,
            actions: actions,
            showsDetachedButton: showsDetachedButton,
            isCompact: true,
            onRefresh: refreshSelectedProvider,
            onOpenSettings: onOpenSettings,
            onRevealKey: selectedProviderRevealAction
        )
        .padding(.horizontal, DetachedWindowMetrics.verticalContentPadding)
        .padding(.bottom, 14)
    }

    private var verticalDashboardMeasureColumn: some View {
        VStack(spacing: 0) {
            verticalDashboardHeaderStack
        }
    }

    /// 横版显示期间就按 330pt 宽度排好竖版并缓存高度，方向切换时可一次完成 resize。
    private var verticalDashboardHeightProbe: some View {
        verticalDashboardMeasureColumn
            .frame(width: DetachedWindowMetrics.verticalDashboardWidth, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: DashboardMeasuredContentSizeKey.self,
                        value: geometry.size
                    )
                }
            }
            .id(verticalDashboardMeasureIdentity)
            .hidden()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var verticalDashboardMeasureIdentity: String {
        let coupons = store.snapshot.resetCoupons.map {
            "\($0.id):\($0.count):\($0.description ?? "")"
        }.joined(separator: "|")
        return [
            multiAgentSettings.selectedConnectionKey,
            coupons,
            store.snapshot.subscriptionExpiryReminderMessage ?? "",
            store.snapshot.hasShortWindow ? "1" : "0",
            store.snapshot.hasWeeklyWindow ? "1" : "0",
            String(activityStore.snapshot.activeTasks.count),
            multiAgentSettings.selectedDeepSeekConnection?.authenticationState.rawValue ?? "",
            multiAgentSettings.selectedDeepSeekConnection?.balance.map { String(describing: $0.total) } ?? "",
            multiAgentSettings.selectedOpenCodeConnection?.authenticationState.rawValue ?? "",
            multiAgentSettings.selectedOpenCodeConnection?.availableModelCount.map(String.init) ?? "",
            multiAgentSettings.selectedGeminiConnection?.authenticationState.rawValue ?? "",
            multiAgentSettings.selectedCodexAccount?.authenticationState.rawValue ?? "",
        ].joined(separator: "-")
    }

    private var verticalQuotaSection: some View {
        let snapshot = displayedCodexSnapshot
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("额度")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 6)
                if let nextReset = snapshot.detailWindow?.resetsAt {
                    Text("额度重置：\(UsageDateFormat.dateAndTime(nextReset))")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.codexMuted)
                        .lineLimit(1)
                }
            }

            VerticalQuotaRowsView(snapshot: snapshot, isLoggedIn: isCodexConnected)

            ResetCouponSummaryView(coupons: snapshot.resetCoupons)
                .padding(.top, 2)
                .fixedSize(horizontal: false, vertical: true)

            Label("实时同步 OpenAI Codex 额度与速率限制", systemImage: "checkmark.shield")
                .font(.system(size: 9))
                .foregroundStyle(Color.codexMuted)
        }
    }

    @ViewBuilder
    private var selectedConnectionSection: some View {
        if let connection = multiAgentSettings.selectedDeepSeekConnection {
            DeepSeekDashboardCard(
                connection: connection,
                isRefreshingConnection: multiAgentSettings.isRefreshingConnection(connection),
                isRefreshingAny: store.isUnifiedRefreshing
            ) {
                actions.refresh()
            }
            .padding(.top, 18)
        } else if let connection = multiAgentSettings.selectedOpenCodeConnection {
            OpenCodeDashboardCard(
                connection: connection,
                onShowModels: { openCodeModels = connection.availableModelIDs }
            )
            .padding(.top, 18)
        } else if let connection = multiAgentSettings.selectedGeminiConnection {
            GeminiDashboardCard(connection: connection)
            .padding(.top, 18)
        } else if isCodexConnected {
            quotaSection
        } else {
            notLoggedInSection
        }
    }

    @ViewBuilder
    private var selectedVerticalConnectionSection: some View {
        // 竖向滚动区的供应商卡片：水平内边距由本部件自己控制。
        Group {
            if let connection = multiAgentSettings.selectedDeepSeekConnection {
                DeepSeekDashboardCard(
                    connection: connection,
                    isRefreshingConnection: multiAgentSettings.isRefreshingConnection(connection),
                    isRefreshingAny: store.isUnifiedRefreshing
                ) {
                    actions.refresh()
                }
            } else if let connection = multiAgentSettings.selectedOpenCodeConnection {
                OpenCodeDashboardCard(
                    connection: connection,
                    onShowModels: { openCodeModels = connection.availableModelIDs }
                )
            } else if let connection = multiAgentSettings.selectedGeminiConnection {
                GeminiDashboardCard(connection: connection)
            } else if isCodexConnected {
                verticalQuotaSection
            } else {
                notLoggedInSection
            }
        }
        .padding(.horizontal, DetachedWindowMetrics.verticalContentPadding)
    }

    /// 未登录 / 授权中的简单状态，不展示额度等账号相关 UI。
    private var notLoggedInSection: some View {
        // OAuth is now owned by the selected-connection store. Keep the
        // hourglass tied to the real authorization task rather than the
        // projected usage snapshot (which is empty before the first account
        // exists).
        let authorizing = multiAgentSettings.isCodexOAuthInProgress
        return VStack(spacing: 10) {
            Spacer(minLength: 24)
            if authorizing {
                AuthorizingHourglassIcon()
            } else {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Color.codexMuted.opacity(0.7))
            }
            Text(authorizing ? "等待授权…" : "尚未连接 Codex")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.codexInk)
            Text(authorizing
                ? "请在浏览器中完成 ChatGPT 授权"
                : "登录后即可查看额度")
                .font(.system(size: 11))
                .foregroundStyle(Color.codexMuted)

            if !authorizing {
                Button {
                    actions.loginAndFetch()
                } label: {
                    Text("登录 Codex")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 20)
                        .frame(height: 40)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(CodexPressableStyle(cornerRadius: 10, ink: .softLight))
                .padding(.top, 6)
            }
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 18)
    }
}

/// 授权等待时的沙漏：转一圈后停 1 秒，再重复。
private struct AuthorizingHourglassIcon: View {
    @State private var rotation: Double = 0

    var body: some View {
        Image(systemName: "hourglass")
            .font(.system(size: 26, weight: .medium))
            .foregroundStyle(Color.codexMuted.opacity(0.7))
            .rotationEffect(.degrees(rotation))
            .task {
                while !Task.isCancelled {
                    withAnimation(.linear(duration: 1.0)) {
                        rotation += 360
                    }
                    // 等转完一圈
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    // 停 1 秒
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
    }
}

// MARK: - Connection Credential Badge

fileprivate enum CredentialBadge {
    case account(Color)
    case apiKey(Color)

    var systemName: String {
        switch self {
        case .account: "checkmark.seal.fill"
        case .apiKey: "key.fill"
        }
    }

    var tint: Color {
        switch self {
        case .account(let color): color
        case .apiKey(let color): color
        }
    }
}

enum ConnectionLogoRowMotion {
    static var selectionAnimation: Animation {
        .snappy(duration: 0.34)
    }

    static func offset(
        viewportWidth: CGFloat,
        itemWidth: CGFloat,
        spacing: CGFloat,
        edgeMargin: CGFloat,
        itemCount: Int,
        selectedIndex: Int
    ) -> CGFloat {
        guard itemCount > 0 else { return 0 }
        let contentWidth = edgeMargin * 2
            + CGFloat(itemCount) * itemWidth
            + CGFloat(max(0, itemCount - 1)) * spacing
        guard contentWidth > viewportWidth else { return 0 }
        let clampedIndex = min(max(0, selectedIndex), itemCount - 1)
        let selectedCenter = edgeMargin
            + CGFloat(clampedIndex) * (itemWidth + spacing)
            + itemWidth / 2
        let centeredOffset = viewportWidth / 2 - selectedCenter
        return min(0, max(viewportWidth - contentWidth, centeredOffset))
    }
}

private struct DashboardConnectionSwitcher: View {
    let snapshot: CodexUsageSnapshot
    @Bindable var store: MultiAgentSettingsStore
    let onAdd: () -> Void
    var compact = false
    var reportsHover = false
    var onHoverChange: (Bool) -> Void = { _ in }

    @State private var draggingItemKey: String?
    @State private var dragOffset: CGSize = .zero
    @State private var trailingFadeVisible = false

    /// 用户拖拽后的顺序同时也是自动轮播顺序。
    private var connectionItems: [ConnectionSwitcherItem] {
        store.orderedConnectionKeys.compactMap { key in
            if let account = store.codexAccounts.first(where: { store.connectionKey(for: $0) == key }) {
                return ConnectionSwitcherItem(
                    key: key,
                    asset: .codex,
                    title: "Codex",
                    subtitle: account.label,
                    color: Color.codexGreen,
                    selected: store.isSelected(account),
                    credential: .account(codexQuotaColor(for: account)),
                    action: { store.selectCodexConnection(account) }
                )
            }
            if let connection = store.deepSeekConnections.first(where: { store.connectionKey(for: $0) == key }) {
                return ConnectionSwitcherItem(
                    key: key,
                    asset: .deepSeek,
                    title: "DeepSeek",
                    subtitle: connection.label,
                    color: .deepSeekBrand,
                    selected: store.isSelected(connection),
                    credential: .apiKey(balanceColor(for: connection)),
                    action: { store.selectDeepSeekConnection(connection) }
                )
            }
            if let connection = store.openCodeConnections.first(where: { store.connectionKey(for: $0) == key }) {
                return ConnectionSwitcherItem(
                    key: key,
                    asset: .openCode,
                    title: connection.plan.displayName,
                    subtitle: connection.label,
                    color: Color.codexGreen,
                    selected: store.isSelected(connection),
                    credential: .apiKey(connection.authenticationState == .connected ? .codexGreen : .codexAmber),
                    action: { store.selectOpenCodeConnection(connection) }
                )
            }
            if let connection = store.geminiConnections.first(where: { store.connectionKey(for: $0) == key }) {
                return ConnectionSwitcherItem(
                    key: key,
                    asset: .googleGemini,
                    title: "Gemini",
                    subtitle: connection.email ?? connection.displayName ?? connection.label,
                    color: Color.codexGreen,
                    selected: store.isSelected(connection),
                    credential: .account(connection.authenticationState == .connected ? .codexGreen : .codexAmber),
                    action: { store.selectGeminiConnection(connection) }
                )
            }
            return nil
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            GeometryReader { geometry in
                let rowOffset = connectionRowOffset(viewportWidth: geometry.size.width)
                let leadingFadeVisible = showsLeadingFade(rowOffset: rowOffset)
                let resolvedTrailingFadeVisible = showsTrailingFade(
                    viewportWidth: geometry.size.width,
                    rowOffset: rowOffset
                )
                ZStack(alignment: .leading) {
                    HStack(alignment: .center, spacing: 7) {
                        ForEach(connectionItems) { item in
                            let isDragging = draggingItemKey == item.key
                            DashboardConnectionItemButton(
                                item: item,
                                compact: compact,
                                isDragging: isDragging
                            )
                            .offset(
                                x: isDragging ? dragOffset.width : 0,
                                y: isDragging ? dragOffset.height : 0
                            )
                            .scaleEffect(isDragging ? 1.18 : 1)
                            .shadow(
                                color: isDragging ? .black.opacity(0.22) : .clear,
                                radius: isDragging ? 10 : 0,
                                y: isDragging ? 5 : 0
                            )
                            .zIndex(isDragging ? 10 : 0)
                            // Keep the tap action and reorder gesture
                            // simultaneous. The exclusive gesture could win
                            // on a tiny pointer movement in the expanded
                            // notch window, leaving the logo visually
                            // clickable but without switching the content.
                            .simultaneousGesture(connectionDragGesture(for: item))
                        }
                    }
                    .padding(.horizontal, 7)
                    .frame(height: 50)
                    .offset(x: rowOffset)
                    .animation(ConnectionLogoRowMotion.selectionAnimation, value: store.selectedConnectionKey)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .coordinateSpace(name: "connection-switcher")
                .overlay(alignment: .leading) {
                    if leadingFadeVisible {
                        connectionEdgeFade
                            .frame(
                                width: connectionFadeWidth(viewportWidth: geometry.size.width),
                                height: 50
                            )
                            .allowsHitTesting(false)
                    }
                }
                .animation(.easeOut(duration: 0.18), value: leadingFadeVisible)
                .onAppear {
                    trailingFadeVisible = resolvedTrailingFadeVisible
                }
                .onChange(of: resolvedTrailingFadeVisible) { _, visible in
                    trailingFadeVisible = visible
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .clipped()
            .onHover { hovering in
                guard reportsHover else { return }
                onHoverChange(hovering)
            }
            .onDisappear {
                guard reportsHover else { return }
                onHoverChange(false)
            }

            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(CodexPressableStyle(cornerRadius: 9))
            .foregroundStyle(Color.codexMuted)
            .background(Color.codexCard, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.codexLine, style: StrokeStyle(lineWidth: 1, dash: [3]))
            }
            .overlay(alignment: .leading) {
                if trailingFadeVisible {
                    connectionEdgeFade
                        .frame(width: 36, height: 50)
                        .scaleEffect(x: -1)
                        .offset(x: -36)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.18), value: trailingFadeVisible)
            .help("添加 Codex 账号或供应商 API Key")
        }
        .frame(height: 50, alignment: .center)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("我的连接")
    }

    private func connectionDragGesture(for item: ConnectionSwitcherItem) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("connection-switcher"))
            .onChanged { value in
                if draggingItemKey == nil {
                    draggingItemKey = item.key
                    NSCursor.closedHand.push()
                }
                guard draggingItemKey == item.key else { return }
                dragOffset = value.translation
            }
            .onEnded { value in
                NSCursor.closedHand.pop()
                guard let sourceIndex = connectionItems.firstIndex(where: { $0.key == item.key }) else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        draggingItemKey = nil
                        dragOffset = .zero
                    }
                    return
                }
                let slotWidth: CGFloat = 49
                let offsetSteps = Int(round(value.translation.width / slotWidth))
                let targetIndex = min(max(0, sourceIndex + offsetSteps), connectionItems.count - 1)

                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    draggingItemKey = nil
                    dragOffset = .zero
                    if targetIndex != sourceIndex {
                        store.moveConnection(
                            key: item.key,
                            to: targetIndex,
                            among: connectionItems.map(\.key)
                        )
                    }
                }
            }
    }

    private func connectionRowOffset(viewportWidth: CGFloat) -> CGFloat {
        let selectedIndex = connectionItems.firstIndex(where: { $0.key == store.selectedConnectionKey }) ?? 0
        return ConnectionLogoRowMotion.offset(
            viewportWidth: viewportWidth,
            itemWidth: 42,
            spacing: 7,
            edgeMargin: 7,
            itemCount: connectionItems.count,
            selectedIndex: selectedIndex
        )
    }

    private func showsLeadingFade(rowOffset: CGFloat) -> Bool {
        rowOffset < -0.5
    }

    private func showsTrailingFade(viewportWidth: CGFloat, rowOffset: CGFloat) -> Bool {
        let itemWidth: CGFloat = 42
        let spacing: CGFloat = 7
        let edgeMargin: CGFloat = 7
        let count = connectionItems.count
        guard count > 0 else { return false }
        let lastLogoMaxX = rowOffset
            + edgeMargin
            + CGFloat(count) * itemWidth
            + CGFloat(max(0, count - 1)) * spacing
        return lastLogoMaxX > viewportWidth + 0.5
    }

    private func connectionFadeWidth(viewportWidth: CGFloat) -> CGFloat {
        min(36, max(0, viewportWidth / 2))
    }

    private var connectionEdgeFade: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color.codexCard, location: 0),
                .init(color: Color.codexCard.opacity(0.82), location: 0.38),
                .init(color: Color.codexCard.opacity(0), location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

private struct DashboardConnectionItemButton: View {
    let item: ConnectionSwitcherItem
    let compact: Bool
    let isDragging: Bool

    @State private var ripples: [CodexMaterialWaveToken] = []
    @State private var didSpawnForTouch = false

    var body: some View {
        Group {
            if compact {
                connectionIcon
                    .frame(width: 42, height: 42)
            } else {
                HStack(spacing: 6) {
                    connectionIcon
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.system(size: 10, weight: .bold))
                        Text(item.subtitle).font(.system(size: 8)).foregroundStyle(Color.codexMuted).lineLimit(1)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 42)
            }
        }
        .frame(height: 42)
        .background(item.selected ? item.color.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            CodexMaterialWaveLayer(ripples: $ripples, ink: .adaptiveMint)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(item.selected ? item.color.opacity(0.25) : Color.clear, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    guard !didSpawnForTouch else { return }
                    didSpawnForTouch = true
                    ripples.spawnWave(at: value.startLocation)
                }
                .onEnded { value in
                    defer { didSpawnForTouch = false }
                    let travel = hypot(value.translation.width, value.translation.height)
                    let hit = CGRect(origin: .zero, size: boardSize).insetBy(dx: -4, dy: -4)
                    if hit.contains(value.location) && travel < 5 && !isDragging {
                        item.action()
                    }
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title)，\(item.subtitle)")
        .accessibilityValue(item.selected ? "已选择" : "未选择")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { item.action() }
    }

    private var boardSize: CGSize {
        compact ? CGSize(width: 42, height: 42) : CGSize(width: 120, height: 42)
    }

    private var connectionIcon: some View {
        ZStack(alignment: .bottomTrailing) {
            BrandIconView(asset: item.asset, size: 32, cornerRadius: 11)
            Image(systemName: item.credential.systemName)
                .font(.system(size: 11, weight: .bold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(item.credential.tint)
                .frame(width: 14, height: 14)
                .offset(x: 2, y: 2)
                .accessibilityHidden(true)
        }
    }
}

extension DashboardConnectionSwitcher {

    private func codexQuotaColor(for connection: CodexAccountConnection) -> Color {
        guard connection.authenticationState == .connected else { return .codexRed }
        guard let usage = connection.usage else { return .codexMuted }
        let remainingPercent = Int((usage.primaryWindow.percent * 100).rounded())

        switch remainingPercent {
        case 50...:
            return .codexGreen
        case 20..<50:
            return .codexAmber
        default:
            return .codexRed
        }
    }

    private func balanceColor(for connection: DeepSeekAPIConnection) -> Color {
        ProviderBalanceIndicator.resolve(
            total: connection.balance?.total,
            authenticationState: connection.authenticationState
        ).color
    }
}

// MARK: - Connection Switcher Items

private struct ConnectionSwitcherItem: Identifiable {
    let key: String
    let asset: BrandAssetID
    let title: String
    let subtitle: String
    let color: Color
    let selected: Bool
    let credential: CredentialBadge
    let action: () -> Void

    var id: String { key }
}

private struct DeepSeekDashboardCard: View {
    let connection: DeepSeekAPIConnection
    /// 当前这个账号是否正在加载（单独请求，单独显示 loading）。
    let isRefreshingConnection: Bool
    /// 是否还有任意供应商连接在加载（全部加载完前按钮不可点击）。
    let isRefreshingAny: Bool
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("DeepSeek").font(.system(size: 20, weight: .bold))
                    Text("\(connection.label) · sk-•••• \(connection.keySuffix)")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.codexMuted)
                }
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(connection.authenticationState == .connected ? Color.codexGreen : Color.codexAmber)
                        .frame(width: 6, height: 6)
                    Text(connection.authenticationState == .connected ? "余额正常" : "需要检查")
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(connection.authenticationState == .connected ? Color.codexGreen : Color.codexAmber)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background((connection.authenticationState == .connected ? Color.codexGreen : Color.codexAmber).opacity(0.10), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 0) {
                Text("可用余额")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.codexMuted)
                    .textCase(.uppercase)
                if let balance = connection.balance {
                    Text(balance.currency == "CNY"
                         ? "¥\(NSDecimalNumber(decimal: balance.total).stringValue)"
                         : "\(balance.currency) \(NSDecimalNumber(decimal: balance.total).stringValue)")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(balanceIndicator.color)
                        .padding(.top, 4)
                    Text("充值 \(NSDecimalNumber(decimal: balance.toppedUp).stringValue) · 赠送 \(NSDecimalNumber(decimal: balance.granted).stringValue)")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.codexMuted)
                        .padding(.top, 2)
                } else {
                    Text("—").font(.system(size: 36, weight: .bold)).foregroundStyle(Color.codexMuted).padding(.top, 4)
                }
                // 官方模型目录来源与新鲜度：型号不落地写死，全部取自 GET /models。
                Text(modelCatalogSummary)
                    .font(.system(size: 9))
                    .foregroundStyle(connection.availableModelIDs.isEmpty ? Color.codexAmber : Color.codexMuted)
                    .padding(.top, 4)
                Button(action: onRefresh) {
                    Group {
                        if isRefreshingConnection {
                            // 本账号仍在加载：反色 loading。
                            CodexButtonLoading()
                        } else if isRefreshingAny {
                            // 本账号已加载完，但还有其它账号在加载：
                            // 数据已直接展示，按钮显示「加载完成」但仍不可点击。
                            HStack(spacing: 5) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("加载完成")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                        } else {
                            Text("查询余额")
                                .font(.system(size: 13, weight: .semibold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44, alignment: .center)
                    .foregroundStyle(Color.codexOnPrimary)
                    .background(Color.codexPrimary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    // 等其它账号时弱化按钮，提示当前不可再次点击。
                    .opacity(isRefreshingAny && !isRefreshingConnection ? 0.55 : 1)
                }
                .buttonStyle(CodexPressableStyle(cornerRadius: 8, ink: .softLight))
                .disabled(isRefreshingAny)
                .padding(.top, 16)
            }
            .padding(20)
            .background(Color.codexCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(Color.codexLine) }
            .padding(.top, 20)

            Label("Key 保存在 macOS Keychain，只用于查询 DeepSeek 官方余额接口；余额属于账户，并非此 Key 独享。", systemImage: "checkmark.shield")
                .font(.system(size: 9))
                .foregroundStyle(Color.codexMuted)
            .padding(.top, 12)
        }
    }

    private var balanceIndicator: ProviderBalanceIndicator {
        ProviderBalanceIndicator.resolve(
            total: connection.balance?.total,
            authenticationState: connection.authenticationState
        )
    }

    /// 官方模型目录摘要：款数 + 最近一次成功抓取时间。
    private var modelCatalogSummary: String {
        guard !connection.availableModelIDs.isEmpty else {
            return "官方模型目录：尚未取到，请点「查询余额」重试"
        }
        guard let lastValidatedAt = connection.lastValidatedAt else {
            return "官方模型目录：\(connection.availableModelIDs.count) 款可用模型"
        }
        let stamp = lastValidatedAt.formatted(date: .numeric, time: .shortened)
        return "官方模型目录：\(connection.availableModelIDs.count) 款可用模型 · 更新于 \(stamp)"
    }
}

private struct OpenCodeDashboardCard: View {
    let connection: OpenCodeAPIConnection
    var onShowModels: (() -> Void)? = nil

    private var isConnected: Bool { connection.authenticationState == .connected }
    private var isGo: Bool { connection.plan == .go }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(connection.plan.displayName).font(.system(size: 20, weight: .bold))
                    Text("\(connection.label) · sk-•••• \(connection.keySuffix)")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.codexMuted)
                }
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(isConnected ? Color.codexGreen : Color.codexAmber)
                        .frame(width: 6, height: 6)
                    Text(isConnected ? "Key 已验证" : "需要检查")
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isConnected ? Color.codexGreen : Color.codexAmber)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background((isConnected ? Color.codexGreen : Color.codexAmber).opacity(0.10), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(isGo ? "订阅额度" : "账户余额")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.codexMuted)
                    .textCase(.uppercase)
                Text(isGo ? "暂不可查询" : "暂不可查询")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.codexMuted)
                    .padding(.top, 6)
                Text(isGo
                     ? "官方 Go 额度为 5 小时 / 周 / 月窗口，暂无公开用量 API。"
                     : "官方暂无面向单个 Zen API Key 的余额查询 API。")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.codexMuted)
                    .padding(.top, 5)
                    .fixedSize(horizontal: false, vertical: true)
                if let count = connection.availableModelCount,
                   !connection.availableModelIDs.isEmpty {
                    Button {
                        onShowModels?()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 9, weight: .semibold))
                            Text("已验证，可访问 \(count) 个模型")
                                .font(.system(size: 9, weight: .medium))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 7, weight: .semibold))
                                .foregroundStyle(Color.codexMuted)
                        }
                        .foregroundStyle(Color.codexGreen)
                    }
                    .buttonStyle(CodexPressableStyle(cornerRadius: 7))
                    .padding(.top, 6)
                } else if let count = connection.availableModelCount {
                    Text("已验证，可访问 \(count) 个模型")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.codexGreen)
                        .padding(.top, 6)
                }

                CodexDivider()
                    .padding(.top, 14)

                HStack {
                    Spacer(minLength: 0)
                    Button {
                        openWorkspacePage()
                    } label: {
                        HStack(spacing: 4) {
                            Text("前往官方页面查看额度")
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 8, weight: .semibold))
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 20)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            .background(Color.codexCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(Color.codexLine) }
            .padding(.top, 20)

            Label("API Key 仅存本机，用于验证 \(connection.plan.displayName) 模型可用性；不会读取或推算账户额度。", systemImage: "checkmark.shield")
                .font(.system(size: 9))
                .foregroundStyle(Color.codexMuted)
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 6)
    }

    private func openWorkspacePage() {
        let url = connection.workspaceURL.flatMap { URL(string: $0) }
            ?? DashboardProviderLinks.openCodeConsole
        NSWorkspace.shared.open(url)
    }
}

private struct QuotaProgressRing: View {
    let fraction: Double
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.codexMuted.opacity(0.2), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(1, fraction))))
                .stroke(
                    fraction < 0.1 ? Color.red : (fraction < 0.25 ? Color.orange : Color.codexGreen),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

private struct GeminiDashboardCard: View {
    let connection: GeminiAPIConnection

    private var fiveHourWindow: UsageWindow? {
        guard let frac = connection.geminiFiveHourRemaining else { return nil }
        let remaining = Int(round(frac * 100))
        return UsageWindow(
            label: "5小时额度",
            remaining: remaining,
            total: 100,
            resetsAt: ""
        )
    }

    private var weeklyWindow: UsageWindow? {
        guard let frac = connection.geminiWeeklyRemaining else { return nil }
        let remaining = Int(round(frac * 100))
        return UsageWindow(
            label: "本周额度",
            remaining: remaining,
            total: 100,
            resetsAt: ""
        )
    }

    private var fiveHourHealthColor: Color {
        guard let frac = connection.geminiFiveHourRemaining else { return Color.codexGreen }
        if frac < 0.15 { return Color.codexRed }
        if frac < 0.30 { return Color.codexAmber }
        return Color.codexGreen
    }

    private var weeklyHealthColor: Color {
        guard let frac = connection.geminiWeeklyRemaining else { return Color.codexBlue }
        if frac < 0.15 { return Color.codexRed }
        if frac < 0.30 { return Color.codexAmber }
        return Color.codexBlue
    }

    private var fiveHourResetText: String? {
        GeminiQuotaResetFormatter.displayText(connection.geminiFiveHourResetDesc)
    }

    private var weeklyResetText: String? {
        GeminiQuotaResetFormatter.displayText(connection.geminiWeeklyResetDesc)
    }

    private var fiveHourResetTooltip: String? {
        GeminiQuotaResetFormatter.absoluteText(connection.geminiFiveHourResetDesc)
    }

    private var weeklyResetTooltip: String? {
        GeminiQuotaResetFormatter.absoluteText(connection.geminiWeeklyResetDesc)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Quota Section Header
            HStack(alignment: .firstTextBaseline) {
                Text("额度")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 6)
                Text("5小时 / 周 双周期配额")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.codexMuted)
                    .lineLimit(1)
            }

            // Quota Ring Cards (Exact Codex style with individual reset times)
            if let short = fiveHourWindow, let weekly = weeklyWindow {
                HStack(spacing: 8) {
                    QuotaRingCard(
                        window: short,
                        tint: fiveHourHealthColor,
                        resetCountdown: fiveHourResetText,
                        resetTooltip: fiveHourResetTooltip
                    )
                    .frame(maxWidth: .infinity)

                    QuotaRingCard(
                        window: weekly,
                        tint: weeklyHealthColor,
                        resetCountdown: weeklyResetText,
                        resetTooltip: weeklyResetTooltip
                    )
                    .frame(maxWidth: .infinity)
                }
                .padding(.top, 6)

                // Claude & GPT sub-quota
                if let cFiveHour = connection.claudeGptFiveHourRemaining,
                   let cWeekly = connection.claudeGptWeeklyRemaining {
                    HStack(spacing: 8) {
                        HStack {
                            Text("Claude / GPT 5h")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.codexMuted)
                            Spacer()
                            Text("\(Int(round(cFiveHour * 100)))%")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.codexInk)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(Color.codexMist.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))

                        HStack {
                            Text("Claude / GPT 周")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.codexMuted)
                            Spacer()
                            Text("\(Int(round(cWeekly * 100)))%")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.codexInk)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(Color.codexMist.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .padding(.top, 6)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        Image(systemName: connection.rateLimitState == "account_validation_required"
                            ? "person.crop.circle.badge.exclamationmark"
                            : (connection.rateLimitState == "unauthorized" ? "person.crop.circle.badge.exclamationmark" : "exclamationmark.circle"))
                        Text(connection.rateLimitState == "account_validation_required"
                            ? "此账号需要先完成 Google 验证"
                            : (connection.rateLimitState == "unauthorized"
                                ? "请重新登录以读取 Antigravity 额度"
                                : "Antigravity 远端额度暂不可用"))
                    }
                    if connection.rateLimitState == "account_validation_required",
                       let message = connection.accountEligibilityMessage, !message.isEmpty {
                        Text(message)
                            .font(.system(size: 9))
                            .foregroundStyle(Color.codexMuted)
                    }
                    if connection.rateLimitState == "account_validation_required",
                       let rawURL = connection.accountValidationURL,
                       let url = URL(string: rawURL) {
                        Button("验证 Google 账号") { NSWorkspace.shared.open(url) }
                            .buttonStyle(CodexPressableStyle(cornerRadius: 6))
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.codexAmber)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
                .background(Color.codexAmber.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .padding(.top, 6)
            }

            // If connection is rate limited, show amber warning
            if connection.rateLimitState == "rate_limited" {
                HStack(spacing: 4) {
                    Circle().fill(Color.codexAmber).frame(width: 6, height: 6)
                    Text("API 限流冷却中")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.codexAmber)
                }
                .padding(.top, 8)
            }

            Label(
                connection.rateLimitState == "normal"
                    ? "通过账号 OAuth 直连同步 Antigravity 额度与套餐状态"
                    : "额度数据仅来自账号 OAuth 远端接口，不读取 Antigravity Desktop",
                systemImage: connection.rateLimitState == "normal" ? "checkmark.shield" : "exclamationmark.shield"
            )
                .font(.system(size: 9))
                .foregroundStyle(Color.codexMuted)
                .padding(.top, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum GeminiQuotaResetFormatter {
    static func displayText(_ raw: String?, now: Date = Date()) -> String? {
        guard let resetDate = resetDate(raw, now: now) else { return raw?.isEmpty == false ? "重置时间待更新" : nil }
        return adaptiveCountdown(resetDate.timeIntervalSince(now))
    }

    static func absoluteText(
        _ raw: String?,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String? {
        guard let resetDate = resetDate(raw, now: now) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy年MM月dd日 HH:mm:ss"
        return formatter.string(from: resetDate)
    }

    private static func resetDate(_ raw: String?, now: Date) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let date = isoDate(raw) { return date }
        guard let duration = duration(in: raw) else { return nil }
        return now.addingTimeInterval(duration)
    }

    private static func duration(in raw: String) -> TimeInterval? {
        let days = component(in: raw, pattern: #"(\d+)\s*(?:days?|天)"#)
        let hours = component(in: raw, pattern: #"(\d+)\s*(?:hours?|小时)"#)
        let minutes = component(in: raw, pattern: #"(\d+)\s*(?:minutes?|分钟|分)"#)
        let seconds = component(in: raw, pattern: #"(\d+)\s*(?:seconds?|秒)"#)
        guard days != nil || hours != nil || minutes != nil || seconds != nil else { return nil }
        return TimeInterval(days ?? 0) * 86_400
            + TimeInterval(hours ?? 0) * 3_600
            + TimeInterval(minutes ?? 0) * 60
            + TimeInterval(seconds ?? 0)
    }

    private static func adaptiveCountdown(_ interval: TimeInterval) -> String {
        guard interval > 0 else { return "即将重置" }
        let totalSeconds = max(1, Int(ceil(interval)))
        let days = totalSeconds / 86_400
        let hours = (totalSeconds % 86_400) / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        let parts = [
            (days, "天"),
            (hours, "小时"),
            (minutes, "分"),
            (seconds, "秒")
        ]
            .filter { $0.0 > 0 }
            .prefix(2)
            .map { "\($0.0)\($0.1)" }
        return parts.joined() + "后重置"
    }

    private static func isoDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw)
    }

    private static func component(in raw: String, pattern: String) -> Int? {
        guard let match = raw.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        return String(raw[match])
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .first(where: { !$0.isEmpty })
            .flatMap(Int.init)
    }
}


enum DashboardMeasuredContentSizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.height > value.height {
            value = next
        }
    }
}

/// 独立窗口底色：侧栏渐变 + 主内容区 card 色，铺满窗口避免底部露白。
struct DashboardWindowChromeBackground: View {
    var accentColor: String? = nil

    var body: some View {
        let top = accentColor.map { Color.codexSidebarTop(for: $0) } ?? Color.codexSidebarTop
        let bottom = accentColor.map { Color.codexSidebarBottom(for: $0) } ?? Color.codexSidebarBottom
        HStack(spacing: 0) {
            LinearGradient(
                colors: [top, bottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(width: DetachedWindowMetrics.sidebarWidth)

            Color.codexCard
        }
    }
}

/// 横向侧栏与竖向头部共用的账号文案，避免两套布局各写一份降级规则。
extension CodexUsageSnapshot {
    var companionAccountName: String {
        if let name = accountName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return accountEmail.split(separator: "@").first.map(String.init) ?? "Codex"
    }

    var companionPlanBadgeText: String {
        planName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum CompanionCopy {
    static func todayDuration(minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes) 分钟" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0
            ? "\(hours) 小时"
            : "\(hours) 小时 \(remainder) 分钟"
    }
}

/// 陪伴胶囊：轮播当前正在工作的 Agent 状态，横竖两版共用。
private struct CompanionStatusCapsule: View {
    let activity: CodexActivitySnapshot
    let quotaHealth: QuotaHealthLevel
    let height: CGFloat
    let waveEnabled: Bool
    let waveColorMode: StatusCapsuleColorMode
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedIndex = 0

    private var statuses: [CompanionAgentStatus] { activity.activeAgentStatuses }

    private var displayedStatus: CompanionAgentStatus? {
        guard !statuses.isEmpty else { return nil }
        return statuses[min(selectedIndex, statuses.count - 1)]
    }

    private var displayedState: CodexActivityState {
        displayedStatus?.state ?? .idle
    }

    private var rotationIdentity: String {
        statuses
            .map { "\($0.id):\($0.state.rawValue):\($0.taskCount)" }
            .joined(separator: "|")
    }

    private var showsActivityFlow: Bool {
        waveEnabled && displayedStatus != nil && displayedState.showsActivityWave
    }

    var body: some View {
        ZStack {
            statusRow
                .id(displayedStatus?.id ?? "idle")
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    )
                )
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 10)
        .frame(height: height)
        .background {
            ZStack {
                Color.codexCard.opacity(0.92)
                ActivityCapsuleWave(
                    isVisible: showsActivityFlow,
                    ink: waveInk,
                    presentation: .rotatingBorder(lineWidth: 2)
                )
            }
            .clipShape(Capsule())
        }
        .clipShape(Capsule())
        .overlay {
            if !showsActivityFlow {
                Capsule()
                    .strokeBorder(Color.white.opacity(0.72), lineWidth: 0.7)
            }
        }
        .clipped()
        .task(id: rotationIdentity) {
            selectedIndex = 0
            guard statuses.count > 1 else { return }

            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled, statuses.count > 1 else { return }
                withAnimation(.easeInOut(duration: 0.32)) {
                    selectedIndex = (selectedIndex + 1) % statuses.count
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var statusRow: some View {
        if let displayedStatus {
            HStack(spacing: 5) {
                Circle()
                    .fill(displayedStatus.state.statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText(for: displayedStatus))
                    .lineLimit(1)
            }
        } else {
            Text("暂无进行中的 Agent")
                .foregroundStyle(Color.codexMuted)
                .lineLimit(1)
        }
    }

    private func statusText(for status: CompanionAgentStatus) -> String {
        let count = status.taskCount > 1 ? " · \(status.taskCount) 个任务" : ""
        return "\(status.agentName) · \(status.state.companionText)\(count)"
    }

    private var accessibilityText: String {
        guard let displayedStatus else { return "暂无进行中的 Agent" }
        let position = statuses.count > 1
            ? "，第 \(selectedIndex + 1) 个，共 \(statuses.count) 个 Agent"
            : ""
        return "\(statusText(for: displayedStatus))\(position)"
    }

    private var waveInk: NSColor {
        waveColorMode.resolvedNSColor(
            activityState: displayedState,
            quotaHealth: quotaHealth
        ) ?? (colorScheme == .dark
            ? NSColor.white.withAlphaComponent(0.18)
            : NSColor.black.withAlphaComponent(0.10))
    }
}

private struct CompanionLocalAgentRow: Identifiable, Equatable {
    let id: AgentID
    let name: String
    let asset: BrandAssetID
    let state: CodexActivityState
    let summary: String
}

/// Preview-aligned Pet-local Agent summary. It intentionally uses integration
/// and Hook activity data, not the selected account, so account switching does
/// not change what the Pet sees on this Mac.
private struct CompanionLocalAgentsControl: View {
    @Environment(\.colorScheme) private var colorScheme
    let activity: CodexActivitySnapshot
    let integrations: [AgentIntegrationStatus]
    var accentColor: Color = Color.codexGreen
    var panelHorizontalOffset: CGFloat = 0
    var opensUpward = false
    /// 点击弹窗中的 agent 任务条时回调选中的任务 id（nil 表示该 agent 当前
    /// 没有可打开的任务卡片，仅收起弹窗）。
    var onSelectTask: (String?) -> Void = { _ in }
    @State private var isExpanded = false
    @State private var interceptedCloseRippleTrigger = 0

    private var rows: [CompanionLocalAgentRow] {
        integrations
            .sorted { $0.priority < $1.priority }
            .compactMap { integration in
                guard let task = latestTask(for: integration), isOngoing(task.state) else {
                    return nil
                }
                return CompanionLocalAgentRow(
                    id: integration.id,
                    name: integration.name,
                    asset: .agent(integration.id),
                    state: task.state,
                    summary: summary(for: task, integration: integration)
                )
            }
    }

    var body: some View {
        CodexMaterialWaveButtonBody(
            action: {
                withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
            },
            cornerRadius: 15,
            usesCapsule: true,
            externalRippleTrigger: interceptedCloseRippleTrigger
        ) {
            HStack(spacing: 8) {
                HStack(spacing: -5) {
                    ForEach(rows.prefix(3)) { row in
                        BrandIconView(asset: row.asset, size: 20, cornerRadius: 7)
                    }
                }
                if rows.isEmpty {
                    Circle()
                        .fill(Color.codexMuted.opacity(0.7))
                        .frame(width: 7, height: 7)
                }
                Text(rows.isEmpty ? "空闲" : "\(rows.count) 进行中")
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .foregroundStyle(rows.isEmpty ? Color.codexMuted : accentColor)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(rows.isEmpty ? Color.codexCard : accentColor.opacity(0.08), in: Capsule())
            .overlay {
                Capsule().strokeBorder(rows.isEmpty ? Color.codexLine.opacity(0.7) : accentColor.opacity(0.42), lineWidth: 1)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(rows.isEmpty ? "本地 Agent 空闲" : "\(rows.count) 个进行中 Agent")
        .accessibilityValue(isExpanded ? "已展开" : "已收起")
        .background {
            CompanionLocalAgentsPanelPresenter(
                isPresented: $isExpanded,
                interceptedCloseRippleTrigger: $interceptedCloseRippleTrigger,
                rows: rows,
                accentColor: accentColor,
                horizontalOffset: panelHorizontalOffset,
                opensUpward: opensUpward,
                colorScheme: colorScheme,
                onSelectTask: { row in
                    handleSelect(row)
                }
            )
        }
        .zIndex(isExpanded ? 30 : 1)
    }

    /// 点击某个 agent 任务条：打开该 agent 的任务卡片并收起下拉弹窗。
    private func handleSelect(_ row: CompanionLocalAgentRow) {
        let taskID = activity.activeTasks
            .filter { $0.agentDisplayName == row.name }
            .max(by: { $0.updatedAt < $1.updatedAt })?
            .id
        onSelectTask(taskID)
        withAnimation(.easeOut(duration: 0.18)) { isExpanded = false }
    }

    private func latestTask(for integration: AgentIntegrationStatus) -> CodexTaskActivity? {
        (activity.localAgentTasks + activity.activeTasks)
            .filter { $0.agentDisplayName == integration.name }
            .max(by: { $0.updatedAt < $1.updatedAt })
    }

    private func isOngoing(_ state: CodexActivityState) -> Bool {
        switch state {
        case .thinking, .executing, .reviewing, .waitingForUser:
            true
        case .unavailable, .idle, .completed, .interrupted:
            false
        }
    }

    private func summary(
        for task: CodexTaskActivity?,
        integration: AgentIntegrationStatus
    ) -> String {
        guard let task else {
            return "会话读取 · 已就绪"
        }
        if task.title == integration.name || task.title.hasPrefix("\(integration.name) ·") {
            return task.detail.replacingOccurrences(of: "\(integration.name) ", with: "")
        }
        return task.title
    }
}

private struct CompanionLocalTasksPanelContent: View {
    let rows: [CompanionLocalAgentRow]
    var accentColor: Color = Color.codexGreen
    /// 点击某个 agent 任务条时回调（由宿主决定打开哪张任务卡片）。
    let onSelect: (CompanionLocalAgentRow) -> Void

    init(
        rows: [CompanionLocalAgentRow],
        accentColor: Color = Color.codexGreen,
        onSelect: @escaping (CompanionLocalAgentRow) -> Void = { _ in }
    ) {
        self.rows = rows
        self.accentColor = accentColor
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pet 看到的本地任务")
                        .font(.system(size: 13, weight: .semibold))
                    Text("仅显示已接入且正在进行中的 Agent")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.codexMuted)
                }
                Spacer(minLength: 4)
                Text(rows.isEmpty ? "空闲" : "\(rows.count) 个进行中")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(rows.isEmpty ? Color.codexMuted : accentColor)
                    .padding(.top, 5)
            }

            VStack(spacing: 12) {
                ForEach(rows) { row in
                    CompanionLocalAgentTaskRowButton(row: row) {
                        onSelect(row)
                    }
                }
                if rows.isEmpty {
                    HStack(spacing: 9) {
                        Circle()
                            .fill(Color.codexMuted.opacity(0.7))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("当前空闲")
                                .font(.system(size: 11, weight: .semibold))
                            Text("已接入的 Agent 开始工作后会在这里显示。")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.codexMuted)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }
            }
            .padding(.top, 15)
        }
        .padding(14)
        .frame(width: 286, alignment: .leading)
        .foregroundStyle(Color.codexInk)
        .background(Color.codexCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.codexLine, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.10), radius: 10, x: 0, y: 5)
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }
}

/// 下拉弹窗里的单个 agent 任务条：点击后打开对应 agent 的任务卡片。
private struct CompanionLocalAgentTaskRowButton: View {
    let row: CompanionLocalAgentRow
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    BrandIconView(asset: row.asset, size: 34, cornerRadius: 10)
                    Circle()
                        .fill(row.state.statusColor)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Color.codexCard, lineWidth: 1.3))
                        .offset(x: 2, y: 2)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name)
                        .font(.system(size: 11, weight: .semibold))
                    Text(row.summary)
                        .font(.system(size: 9))
                        .foregroundStyle(Color.codexMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Text(row.state.activityLabel)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(row.state.statusColor)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.codexMuted.opacity(0.8))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isHovered ? Color.codexMist.opacity(0.55) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.name)，\(row.summary)，\(row.state.activityLabel)，点击打开任务卡片")
    }
}

private struct CompanionLocalAgentsPanelPresenter: NSViewRepresentable {
    @Binding var isPresented: Bool
    @Binding var interceptedCloseRippleTrigger: Int
    let rows: [CompanionLocalAgentRow]
    var accentColor: Color = Color.codexGreen
    let horizontalOffset: CGFloat
    let opensUpward: Bool
    let colorScheme: ColorScheme
    let onSelectTask: (CompanionLocalAgentRow) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isPresented: $isPresented,
            interceptedCloseRippleTrigger: $interceptedCloseRippleTrigger,
            onSelectTask: onSelectTask
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = CompanionHoverTrackingView(frame: .zero)
        view.onMouseEntered = { context.coordinator.anchorMouseEntered() }
        view.onMouseExited = { context.coordinator.anchorMouseExited() }
        context.coordinator.anchorView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isPresented = $isPresented
        context.coordinator.interceptedCloseRippleTrigger = $interceptedCloseRippleTrigger
        context.coordinator.onSelectTask = onSelectTask
        context.coordinator.update(
            rows: rows,
            accentColor: accentColor,
            horizontalOffset: horizontalOffset,
            opensUpward: opensUpward,
            colorScheme: colorScheme
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.dismiss()
    }

    @MainActor
    final class Coordinator {
        weak var anchorView: NSView?
        var isPresented: Binding<Bool>
        var interceptedCloseRippleTrigger: Binding<Int>
        var onSelectTask: (CompanionLocalAgentRow) -> Void
        private let controller = CompanionLocalAgentsPanelController()

        init(
            isPresented: Binding<Bool>,
            interceptedCloseRippleTrigger: Binding<Int>,
            onSelectTask: @escaping (CompanionLocalAgentRow) -> Void
        ) {
            self.isPresented = isPresented
            self.interceptedCloseRippleTrigger = interceptedCloseRippleTrigger
            self.onSelectTask = onSelectTask
            controller.onInterceptedAnchorClick = { [weak self] in
                self?.interceptedCloseRippleTrigger.wrappedValue += 1
            }
            controller.onDismiss = { [weak self] in
                self?.isPresented.wrappedValue = false
            }
            controller.onSelectTask = { [weak self] row in
                self?.onSelectTask(row)
            }
        }

        func update(
            rows: [CompanionLocalAgentRow],
            accentColor: Color,
            horizontalOffset: CGFloat,
            opensUpward: Bool,
            colorScheme: ColorScheme
        ) {
            controller.update(rows: rows, accentColor: accentColor, colorScheme: colorScheme)
            guard isPresented.wrappedValue, let anchorView else {
                controller.dismiss()
                return
            }
            DispatchQueue.main.async { [weak self, weak anchorView] in
                guard let self, let anchorView, self.isPresented.wrappedValue else { return }
                self.controller.show(
                    relativeTo: anchorView,
                    horizontalOffset: horizontalOffset,
                    opensUpward: opensUpward
                )
            }
        }

        func dismiss() {
            controller.dismiss()
        }

        func anchorMouseEntered() {
            controller.anchorMouseEntered()
        }

        func anchorMouseExited() {
            controller.anchorMouseExited()
        }
    }
}

private final class CompanionHoverTrackingView: NSView {
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    var capturedMouseDownRect: NSRect?
    var onCapturedMouseDown: (() -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? {
        if capturedMouseDownRect?.contains(point) == true {
            return self
        }
        return super.hitTest(point)
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if capturedMouseDownRect?.contains(point) == true {
            onCapturedMouseDown?()
            return
        }
        super.mouseDown(with: event)
    }
}

enum CompanionPanelAnchorClickRouting {
    static func captureRect(anchorFrame: NSRect, panelFrame: NSRect) -> NSRect? {
        let overlap = anchorFrame.intersection(panelFrame)
        guard !overlap.isNull, !overlap.isEmpty else { return nil }
        return NSRect(
            x: overlap.minX - panelFrame.minX,
            y: overlap.minY - panelFrame.minY,
            width: overlap.width,
            height: overlap.height
        )
    }
}

@MainActor
private final class CompanionLocalAgentsPanelController {
    private static let contentHorizontalInset: CGFloat = 20
    private static let contentVerticalInset: CGFloat = 6
    private static let attachmentGap: CGFloat = 4
    /// NSHostingView keeps additional fitting-space above the visible card.
    /// Pull the panel toward its trigger so the card, rather than the clear
    /// panel bounds, reads as visually attached to the capsule.
    private static let visibleCardAttachmentCorrection: CGFloat = 20
    private let panel: NSPanel
    private let hostingView: NSHostingView<AnyView>
    private let trackingView = CompanionHoverTrackingView(frame: .zero)
    private var anchorFrame: NSRect?
    private var safeTriangle: HoverSafeTriangle?
    private var safeTriangleTimer: Timer?
    private var safeTriangleDeadline: Date?
    private var lastOpensUpward = false
    private var presentationGeneration = 0
    private var isDismissing = false
    var onInterceptedAnchorClick: (() -> Void)?
    var onDismiss: (() -> Void)?
    /// 点击任务条时回调（由宿主把对应 agent 的任务卡片带到前台并收起弹窗）。
    var onSelectTask: ((CompanionLocalAgentRow) -> Void)?

    init() {
        let rootView = CompanionLocalTasksPanelContent(rows: [])
        hostingView = NSHostingView(rootView: AnyView(rootView))
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 326, height: 180),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.transient, .canJoinAllSpaces, .fullScreenAuxiliary]
        trackingView.addSubview(hostingView)
        trackingView.onMouseEntered = { [weak self] in
            self?.cancelSafeTriangleTracking()
        }
        trackingView.onMouseExited = { [weak self] in
            self?.panelMouseExited()
        }
        trackingView.onCapturedMouseDown = { [weak self] in
            guard let self else { return }
            onInterceptedAnchorClick?()
            dismiss()
            onDismiss?()
        }
        panel.contentView = trackingView
    }

    func update(rows: [CompanionLocalAgentRow], accentColor: Color = Color.codexGreen, colorScheme: ColorScheme) {
        hostingView.rootView = AnyView(
            CompanionLocalTasksPanelContent(rows: rows, accentColor: accentColor) { [weak self] row in
                self?.onSelectTask?(row)
            }
            .preferredColorScheme(colorScheme)
        )
        hostingView.layoutSubtreeIfNeeded()
        let fittingHeight = max(164, hostingView.fittingSize.height)
        panel.setContentSize(NSSize(width: 326, height: fittingHeight))
        trackingView.frame = NSRect(x: 0, y: 0, width: 326, height: fittingHeight)
        hostingView.frame = NSRect(x: 0, y: 0, width: 326, height: fittingHeight)
    }

    func show(relativeTo anchorView: NSView, horizontalOffset: CGFloat, opensUpward: Bool) {
        guard let parentWindow = anchorView.window else { return }
        panel.appearance = parentWindow.appearance
        presentationGeneration += 1
        isDismissing = false
        lastOpensUpward = opensUpward
        panel.alphaValue = 1
        let anchorInWindow = anchorView.convert(anchorView.bounds, to: nil)
        let anchor = parentWindow.convertToScreen(anchorInWindow)
        anchorFrame = anchor
        let size = panel.frame.size
        let attachedY = if opensUpward {
            anchor.maxY
                - Self.contentVerticalInset
                + Self.attachmentGap
                - Self.visibleCardAttachmentCorrection
        } else {
            anchor.minY
                - size.height
                + Self.contentVerticalInset
                - Self.attachmentGap
                + Self.visibleCardAttachmentCorrection
        }
        var origin = NSPoint(
            x: anchor.midX - size.width / 2 + horizontalOffset,
            y: attachedY
        )

        if let visibleFrame = parentWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            origin.x = min(max(origin.x, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8)
            origin.y = min(max(origin.y, visibleFrame.minY + 8), visibleFrame.maxY - size.height - 8)
        }

        panel.setFrameOrigin(origin)
        trackingView.capturedMouseDownRect = CompanionPanelAnchorClickRouting.captureRect(
            anchorFrame: anchor,
            panelFrame: panel.frame
        )
        if panel.parent !== parentWindow {
            panel.parent?.removeChildWindow(panel)
            parentWindow.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func dismiss(animated: Bool = true) {
        cancelSafeTriangleTracking()
        anchorFrame = nil
        trackingView.capturedMouseDownRect = nil
        guard panel.isVisible, !isDismissing else { return }

        let generation = presentationGeneration + 1
        presentationGeneration = generation
        let originalOrigin = panel.frame.origin

        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            finishDismiss(generation: generation, originalOrigin: originalOrigin)
            return
        }

        isDismissing = true
        let targetOrigin = NSPoint(
            x: originalOrigin.x,
            y: originalOrigin.y + (lastOpensUpward ? -4 : 4)
        )
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrameOrigin(targetOrigin)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.finishDismiss(generation: generation, originalOrigin: originalOrigin)
            }
        }
    }

    private func finishDismiss(generation: Int, originalOrigin: NSPoint) {
        guard presentationGeneration == generation else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.alphaValue = 1
        panel.setFrameOrigin(originalOrigin)
        isDismissing = false
    }

    func anchorMouseEntered() {
        cancelSafeTriangleTracking()
    }

    func anchorMouseExited() {
        guard panel.isVisible else { return }
        beginSafeTriangleTracking(
            from: NSEvent.mouseLocation,
            toward: panelInteractionFrame
        )
    }

    private func panelMouseExited() {
        guard panel.isVisible, let anchorFrame else { return }
        beginSafeTriangleTracking(
            from: NSEvent.mouseLocation,
            toward: anchorFrame
        )
    }

    private var panelInteractionFrame: NSRect {
        panel.frame.insetBy(
            dx: Self.contentHorizontalInset,
            dy: Self.contentVerticalInset
        )
    }

    private func beginSafeTriangleTracking(from departurePoint: NSPoint, toward targetFrame: NSRect) {
        cancelSafeTriangleTracking()
        safeTriangle = HoverSafeTriangle(
            origin: departurePoint,
            targetFrame: targetFrame,
            buffer: 8
        )
        safeTriangleDeadline = Date().addingTimeInterval(2)
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluatePointerForDismissal()
            }
        }
        safeTriangleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func evaluatePointerForDismissal() {
        let pointer = NSEvent.mouseLocation
        if panelInteractionFrame.contains(pointer) || anchorFrame?.contains(pointer) == true {
            cancelSafeTriangleTracking()
            return
        }
        if let safeTriangle,
           let safeTriangleDeadline,
           Date() < safeTriangleDeadline,
           safeTriangle.contains(pointer) {
            return
        }
        dismiss()
        onDismiss?()
    }

    private func cancelSafeTriangleTracking() {
        safeTriangleTimer?.invalidate()
        safeTriangleTimer = nil
        safeTriangle = nil
        safeTriangleDeadline = nil
    }
}

/// Pet 承载区的点击交互：涟漪 + 随机动作 + 无障碍，侧栏与顶部形象区共用。
private struct CompanionPetInteraction: ViewModifier {
    let space: String
    let frameStore: PetFrameStore
    @Binding var ripples: [CodexMaterialWaveToken]
    /// 通过辅助功能触发时没有点击位置，用这个点代替。
    let fallbackRippleLocation: CGPoint

    private var isInteractive: Bool { frameStore.canPlayIdleInteraction }

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .coordinateSpace(name: space)
            .gesture(
                codexMaterialTapGesture(in: space) { location in
                    play(rippleAt: location)
                }
            )
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(isInteractive ? .isButton : [])
            .accessibilityHint(isInteractive ? "点击播放随机动作" : "")
            .accessibilityAction(.default) {
                play(rippleAt: fallbackRippleLocation)
            }
    }

    private func play(rippleAt location: CGPoint) {
        guard isInteractive else { return }
        ripples.spawnWave(at: location)
        frameStore.playRandomIdleAction()
    }
}

private extension View {
    func companionPetInteraction(
        space: String,
        frameStore: PetFrameStore,
        ripples: Binding<[CodexMaterialWaveToken]>,
        fallbackRippleLocation: CGPoint
    ) -> some View {
        modifier(
            CompanionPetInteraction(
                space: space,
                frameStore: frameStore,
                ripples: ripples,
                fallbackRippleLocation: fallbackRippleLocation
            )
        )
    }
}

/// 竖向布局的顶部形象区：宠物、状态胶囊与陪伴时长，保留点击涟漪与随机动作。
private struct CompanionPetHeader: View {
    private static let headerSpace = "companionPetHeader"
    /// 让出无标题栏窗口左上角的交通灯与右上角的置顶按钮。
    private static let chromeTopPadding: CGFloat = 34

    let snapshot: CodexUsageSnapshot
    let activity: CodexActivitySnapshot
    let integrations: [AgentIntegrationStatus]
    @Bindable var settings: AppSettingsStore
    @Bindable var frameStore: PetFrameStore
    let todayMinutes: Int
    var fillHeight = false
    @Binding var selectedTaskID: String?
    @State private var ripples: [CodexMaterialWaveToken] = []

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.codexSidebarTop(for: settings.themeConfig.accentColor),
                    Color.codexSidebarBottom(for: settings.themeConfig.accentColor)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Wave sits on the header background, beneath pet and chrome.
            CodexMaterialWaveLayer(ripples: $ripples, ink: .themeAccent(Color(hex: settings.themeConfig.accentColor)))

            VStack(spacing: 0) {
                InteractivePetStage(
                    frameStore: frameStore,
                    settings: settings,
                    activity: activity
                )
                .frame(width: 132, height: 132)
                .allowsHitTesting(false)

                CompanionStatusCapsule(
                    activity: activity,
                    quotaHealth: QuotaHealthLevel.from(
                        window: snapshot.primaryWindow,
                        isLoggedIn: true
                    ),
                    height: 28,
                    waveEnabled: settings.statusBarWaveEnabled,
                    waveColorMode: settings.statusBarWaveColorMode
                )

                GlobalAgentTaskSection(
                    activity: activity,
                    integrations: integrations,
                    selectedTaskID: $selectedTaskID,
                    accentColor: Color(hex: settings.themeConfig.accentColor)
                )
                .padding(.top, 16)

                if fillHeight {
                    Spacer(minLength: 0)
                }

                Text("今天一起工作 \(CompanionCopy.todayDuration(minutes: todayMinutes))")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.codexMuted)
                    .padding(.top, fillHeight ? 0 : 12)
                    .padding(.bottom, fillHeight ? 10 : 4)
            }
            .padding(.top, fillHeight ? 60 : Self.chromeTopPadding)
            .padding(.bottom, 14)
            .padding(.horizontal, 12)
            .zIndex(1)
        }
        .fixedSize(horizontal: false, vertical: !fillHeight)
        .companionPetInteraction(
            space: Self.headerSpace,
            frameStore: frameStore,
            ripples: $ripples,
            fallbackRippleLocation: CGPoint(x: 146, y: 110)
        )
    }
}

/// 横版右侧的账号上下文。左栏代表通用 Pet，不承载任何单账号信息。
private struct CompanionHorizontalAccountHeader: View {
    let context: DashboardProviderContext
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                BrandIconView(asset: context.asset, size: 38, cornerRadius: 10)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(context.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.codexInk)
                            .lineLimit(1)
                        if !context.badge.isEmpty {
                            Text(context.badge)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(context.badgeColor)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(context.badgeColor.opacity(0.10), in: Capsule())
                        }
                    }
                    Text(context.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.codexMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 10)

                HStack(spacing: 5) {
                    Circle()
                        .fill(context.statusColor)
                        .frame(width: 6, height: 6)
                    Text(context.statusText)
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(context.statusColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(context.statusColor.opacity(0.10), in: Capsule())
            }
            .padding(.top, 12)
            .padding(.bottom, 9)

            CodexDivider()

            HStack(spacing: 8) {
                Text(context.summaryText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.codexMuted)
                    .lineLimit(1)
                Spacer(minLength: 8)
                ChatGPTBillingCompactLink(
                    title: context.accountLinkTitle,
                    helpTitle: context.accountLinkTitle,
                    fontSize: 10
                ) {
                    openURL(context.accountLinkURL)
                }
            }
            .frame(height: 32)
        }
        .padding(.horizontal, DetachedWindowMetrics.dashboardContentPadding)
        .background(Color.codexCard.opacity(0.96))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("当前连接 \(context.title)")
    }
}

/// 竖向布局的账号行：把侧栏那块两行账号信息压成一条。
private struct CompanionAccountRow: View {
    let context: DashboardProviderContext
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(context.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.codexInk)
                        .lineLimit(1)
                    if !context.badge.isEmpty {
                        Text(context.badge)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(context.badgeColor)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(context.badgeColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text(context.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.codexMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ChatGPTBillingCompactLink(
                title: context.summaryText,
                helpTitle: context.accountLinkTitle,
                emphasizesExpiry: context.emphasizesAccountLink
            ) {
                openURL(context.accountLinkURL)
            }
        }
        .padding(.horizontal, DetachedWindowMetrics.verticalContentPadding)
        .frame(height: 46)
        .overlay(alignment: .bottom) {
            CodexDivider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("当前连接 \(context.title)")
    }
}

/// 竖向布局的额度：有 5h 时双列横向并排（5h 在前），仅单周期时一行显示。
private struct VerticalQuotaRowsView: View {
    let snapshot: CodexUsageSnapshot
    let isLoggedIn: Bool

    private var primaryHealth: QuotaHealthLevel {
        QuotaHealthLevel.from(window: snapshot.primaryWindow, isLoggedIn: isLoggedIn)
    }

    var body: some View {
        Group {
            if snapshot.hasShortWindow, let short = snapshot.shortWindow, snapshot.hasWeeklyWindow {
                // 有 5h 额度的数据时，显示两个横向布局，5h 在前
                HStack(spacing: 8) {
                    CompactVerticalQuotaPill(window: short, tint: primaryHealth.color)
                    CompactVerticalQuotaPill(window: snapshot.weekly, tint: Color.codexBlue)
                }
            } else if snapshot.hasShortWindow, let short = snapshot.shortWindow {
                VerticalQuotaRow(window: short, tint: primaryHealth.color)
            } else if snapshot.hasWeeklyWindow {
                VerticalQuotaRow(window: snapshot.weekly, tint: primaryHealth.color)
            } else {
                Text("额度暂不可用")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.codexMuted)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.codexMist.opacity(0.55), in: RoundedRectangle(cornerRadius: 11))
            }
        }
    }
}

private struct CompactVerticalQuotaPill: View {
    let window: UsageWindow
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)

            Text(window.label == "周额度" ? "本周" : window.label)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.codexMuted)
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(window.percentText)
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.codexInk)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .background(Color.codexMist.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.codexLine.opacity(0.6), lineWidth: 0.7))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.label) 剩余 \(window.percentText)，\(window.amountText)")
    }
}

private struct VerticalQuotaRow: View {
    private static let trackWidth: CGFloat = 84
    private static let percentWidth: CGFloat = 44

    let window: UsageWindow
    let tint: Color

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)

            Text(window.label == "周额度" ? "本周" : window.label)
                .font(.system(size: 11))
                .foregroundStyle(Color.codexMuted)
                .lineLimit(1)

            Spacer(minLength: 6)

            ZStack(alignment: .leading) {
                Capsule().fill(Color.codexTrack)
                Capsule()
                    .fill(tint)
                    .frame(width: max(Self.trackWidth * window.percent, window.percent > 0 ? 4 : 0))
            }
            .frame(width: Self.trackWidth, height: 5)

            Text(window.percentText)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: Self.percentWidth, alignment: .trailing)
                .layoutPriority(1)
        }
        .padding(.horizontal, 11)
        .frame(height: 38)
        .background(Color.codexCard, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.codexLine, lineWidth: 0.7))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.label) 剩余 \(window.percentText)，\(window.amountText)")
    }
}

private struct SubscriptionExpiryReminderBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.codexAmber)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.codexInk)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.codexAmber.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.codexAmber.opacity(0.28), lineWidth: 0.8)
        )
        .accessibilityLabel(message)
    }
}


private struct CompanionSidebar: View {
    private static let sidebarSpace = "companionSidebar"

    let snapshot: CodexUsageSnapshot
    let activity: CodexActivitySnapshot
    let integrations: [AgentIntegrationStatus]
    @Bindable var settings: AppSettingsStore
    @Bindable var frameStore: PetFrameStore
    let todayMinutes: Int
    /// 在父级 HStack 已确定行高时铺满侧栏（独立横版）。
    var fillColumnHeight = false
    var expandsVertically = true
    @Binding var selectedTaskID: String?
    @State private var ripples: [CodexMaterialWaveToken] = []

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.codexSidebarTop(for: settings.themeConfig.accentColor),
                    Color.codexSidebarBottom(for: settings.themeConfig.accentColor)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Wave sits on the sidebar background, beneath pet and chrome.
            CodexMaterialWaveLayer(ripples: $ripples, ink: .themeAccent(Color(hex: settings.themeConfig.accentColor)))

            VStack(spacing: 0) {
                petView
                    .frame(width: 145, height: 218)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .zIndex(1)
                    .allowsHitTesting(false)

                TaskStackView(
                    snapshot: activity,
                    selectedTaskID: $selectedTaskID
                )
                .padding(.horizontal, 12)
                .padding(.top, 8)

                Spacer(minLength: 0)
            }
        }
        .overlay(alignment: .bottom) {
            sidebarFooter
        }
        .companionPetInteraction(
            space: Self.sidebarSpace,
            frameStore: frameStore,
            ripples: $ripples,
            fallbackRippleLocation: CGPoint(x: 94, y: 220)
        )
        .overlay(alignment: .trailing) {
            CodexDivider(.vertical)
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: (fillColumnHeight || expandsVertically) ? .infinity : nil,
            alignment: .top
        )
        .fixedSize(horizontal: false, vertical: !fillColumnHeight && !expandsVertically)
    }

    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            CompanionStatusCapsule(
                activity: activity,
                quotaHealth: QuotaHealthLevel.from(
                    window: snapshot.primaryWindow,
                    isLoggedIn: true
                ),
                height: 30,
                waveEnabled: settings.statusBarWaveEnabled,
                waveColorMode: settings.statusBarWaveColorMode
            )

            CompanionLocalAgentsControl(
                activity: activity,
                integrations: integrations,
                accentColor: Color(hex: settings.themeConfig.accentColor),
                panelHorizontalOffset: 48,
                opensUpward: true,
                onSelectTask: { taskID in
                    if let taskID { selectedTaskID = taskID }
                }
            )
            .padding(.top, 7)

            Text("今天一起工作 \(CompanionCopy.todayDuration(minutes: todayMinutes))")
                .font(.system(size: 11))
                .foregroundStyle(Color.codexMuted)
                .padding(.top, 9)
                .padding(.bottom, 19)
        }
    }

    private var petView: some View {
        InteractivePetStage(
            frameStore: frameStore,
            settings: settings,
            activity: activity
        )
    }
}

private struct InteractivePetStage: View {
    @Bindable var frameStore: PetFrameStore
    @Bindable var settings: AppSettingsStore
    let activity: CodexActivitySnapshot

    var body: some View {
        petContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var petContent: some View {
        if let frame = frameStore.currentFrame {
            Image(nsImage: frame)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .accessibilityLabel("\(settings.selectedPet?.displayName ?? "Pet") 动画")
        } else if let pet = settings.selectedPet {
            PetStaticFrameView(pet: pet)
                .accessibilityLabel("\(pet.displayName) 静态预览")
        } else {
            VStack(spacing: 9) {
                Circle()
                    .fill(activity.state.statusColor.opacity(0.14))
                    .frame(width: 76, height: 76)
                    .overlay(Circle().fill(activity.state.statusColor).frame(width: 12, height: 12))
                Text("未找到可用 Pet")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.codexMuted)
            }
        }
    }
}

private struct PetStaticFrameView: View {
    let pet: CodexPet
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: pet.id) {
            image = PetSpriteSheet(url: pet.spritesheetURL)?.frame(row: 0, column: 0, displayHeight: 218)
        }
    }
}

private struct ActivityHeading: View {
    let activity: CodexActivitySnapshot
    let usage: CodexUsageSnapshot
    let isLoggedIn: Bool
    var isCompact = false

    var body: some View {
        Text(activity.dashboardTitle)
            .font(.system(size: isCompact ? 17 : 20, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(isCompact ? 0.85 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Account-independent activity area shared by every locally connected Agent.
/// Native Codex tasks and Hook-backed Agent tasks already arrive in the same
/// `activeTasks` collection, so the card stack remains stable while accounts
/// are switched in the dashboard below.
private struct GlobalAgentTaskSection: View {
    let activity: CodexActivitySnapshot
    let integrations: [AgentIntegrationStatus]
    @Binding var selectedTaskID: String?
    var accentColor: Color = Color.codexGreen

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Text(activity.dashboardTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Spacer(minLength: 4)

                CompanionLocalAgentsControl(
                    activity: activity,
                    integrations: integrations,
                    accentColor: accentColor,
                    onSelectTask: { taskID in
                        if let taskID { selectedTaskID = taskID }
                    }
                )
            }

            TaskStackView(
                snapshot: activity,
                selectedTaskID: $selectedTaskID
            )
            .padding(.top, 15)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct QuotaAtAGlanceChip: View {
    let usage: CodexUsageSnapshot
    let isLoggedIn: Bool

    private var window: UsageWindow { usage.primaryWindow }
    private var health: QuotaHealthLevel {
        QuotaHealthLevel.from(window: window, isLoggedIn: isLoggedIn)
    }

    private var isAvailable: Bool {
        isLoggedIn && window.total > 0
    }

    private var title: String {
        guard isAvailable else { return "额度不可用" }
        let name = window.label == "周额度" ? "本周" : window.label
        return "\(name) \(window.percentText)"
    }

    private var helpText: String {
        guard isAvailable else { return "登录并刷新后可查看额度余量" }
        var parts = ["\(window.label) 剩余 \(window.amountText)"]
        if !window.resetsAt.isEmpty {
            parts.append("重置 \(UsageDateFormat.dateAndTime(window.resetsAt))")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(health.color)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(isAvailable ? health.color : Color.codexMuted)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            isAvailable ? health.color.opacity(0.10) : Color.codexMist.opacity(0.72),
            in: Capsule(style: .continuous)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(
                    isAvailable ? health.color.opacity(0.22) : Color.codexLine.opacity(0.75),
                    lineWidth: 0.7
                )
        )
        .help(helpText)
        .accessibilityLabel("\(title)，\(helpText)")
    }
}

private struct TaskStackView: View {
    private static let cardSpace = "taskCard"
    private static let cardHeight: CGFloat = 144
    private static let stackOffset: CGFloat = 9

    let snapshot: CodexActivitySnapshot
    @Binding var selectedTaskID: String?
    @State private var ripples: [CodexMaterialWaveToken] = []
    @State private var isHovering = false
    @State private var carouselDriver: AgentCarouselDriver?
    /// 卡片展示下标：本地状态直接驱动内容与计数，确保轮播时卡片真正切换。
    @State private var displayIndex = 0

    private var tasks: [CodexTaskActivity] { snapshot.activeTasks }

    private var displayedTask: CodexTaskActivity? {
        guard tasks.indices.contains(displayIndex) else { return tasks.first }
        return tasks[displayIndex]
    }

    private var selectedIndex: Int {
        guard let displayedTask else { return 0 }
        return tasks.firstIndex(where: { $0.id == displayedTask.id }) ?? displayIndex
    }

    var body: some View {
        let cardShape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        ZStack(alignment: .topLeading) {
            if tasks.count > 1 {
                cardShape
                    .fill(Color.codexMist)
                    .overlay(cardShape.stroke(Color.codexLine, lineWidth: 0.7))
                    .frame(maxWidth: .infinity, minHeight: Self.cardHeight, maxHeight: Self.cardHeight)
                    .offset(x: 8, y: Self.stackOffset)
                    .allowsHitTesting(false)
            }

            taskCard
                .contentShape(cardShape)
                .overlay {
                    CodexMaterialWaveLayer(ripples: $ripples)
                    .clipShape(cardShape)
                }
                .gesture(
                    codexMaterialTapGesture(in: Self.cardSpace) { location in
                        ripples.spawnWave(at: location)
                        openDisplayedTask()
                    }
                )
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(accessibilityText)

            // Footer 是卡片内部独立的顶层命中区域。它自身必须拥有完整的按钮命中面，
            // 否则文字与透明 Spacer 会盖住底层 taskCard 手势并让点击落到后层视图。
            taskFooter
                .padding(.horizontal, 13)
                .frame(
                    maxWidth: .infinity,
                    minHeight: Self.cardHeight,
                    maxHeight: Self.cardHeight,
                    alignment: .bottom
                )
        }
        .coordinateSpace(name: Self.cardSpace)
        .padding(.trailing, tasks.count > 1 ? 8 : 0)
        .frame(
            height: tasks.count > 1 ? Self.cardHeight + Self.stackOffset : Self.cardHeight,
            alignment: .top
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
            if hovering {
                carouselDriver?.pause()
            } else {
                carouselDriver?.resume()
            }
        }
        // 外部（侧栏/本地 Agent 控件）选中变化时，跟随其任务 id。
        .onChange(of: selectedTaskID) { _, newID in
            guard let newID,
                  let idx = tasks.firstIndex(where: { $0.id == newID }),
                  idx != displayIndex else { return }
            displayIndex = idx
        }
        // 自动轮播：与刘海 agent 轮播一致的共享驱动（AgentCarouselDriver）。
        // 视图出现/任务列表变化时创建并启动，视图消失时停止。
        .task(id: tasks.map(\.id)) {
            if carouselDriver == nil {
                carouselDriver = AgentCarouselDriver {
                    advanceTask()
                }
            }
            // 当前展示的任务已消失时，规整回到显示范围内。
            if let selectedTaskID,
               let selectedIndex = tasks.firstIndex(where: { $0.id == selectedTaskID }) {
                displayIndex = selectedIndex
            } else if !tasks.indices.contains(displayIndex) {
                displayIndex = 0
            }
            carouselDriver?.isEnabled = tasks.count > 1
            if isHovering {
                carouselDriver?.pause()
            } else {
                carouselDriver?.start()
            }
        }
        .onDisappear {
            carouselDriver?.stop()
            carouselDriver = nil
        }
    }

    private var taskCard: some View {
        let cardShape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(alignment: .leading, spacing: 7) {
            // 空闲时没有具体任务，不显示任何 Agent 的 logo 与状态标签。
            if displayedTask != nil {
                HStack {
                    HStack(spacing: 7) {
                        BrandIconView(
                            asset: .agent(displayAgentID),
                            size: 18,
                            cornerRadius: 6
                        )
                        HStack(spacing: 5) {
                            Circle().fill(displayState.statusColor).frame(width: 8, height: 8)
                            Text(displayState.taskLabel)
                                .foregroundStyle(displayState.statusColor)
                                .fontWeight(.semibold)
                        }
                    }
                    Spacer()
                }
                .font(.system(size: 11))
            }

            ActivityShimmerText(
                text: displayTitle,
                font: .system(size: 15, weight: .semibold),
                base: .codexInk,
                highlight: displayState.statusColor,
                isAnimated: displayedTask != nil && displayState.showsActivityWave
            )
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(displayDetail)
                .font(.system(size: 12))
                .foregroundStyle(Color.codexMuted)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !displayMetadata.isEmpty {
                HStack(spacing: 10) {
                    ForEach(displayMetadata, id: \.value) { item in
                        Label(item.value, systemImage: item.icon)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.codexMuted)
            }

            Spacer(minLength: 2)
        }
        .padding(.horizontal, 13)
        .padding(.top, 13)
        .padding(.bottom, 39)
        .frame(
            maxWidth: .infinity,
            minHeight: Self.cardHeight,
            maxHeight: Self.cardHeight,
            alignment: .topLeading
        )
        .background(Color.codexCard, in: cardShape)
        .overlay(cardShape.stroke(Color.codexLine, lineWidth: 0.7))
        .contentShape(cardShape)
    }

    private var taskFooter: some View {
        HStack(spacing: 8) {
            Button(action: openDisplayedTask) {
                HStack(spacing: 8) {
                    Text(displayState.activityLabel)
                    Spacer(minLength: 8)
                    if let task = displayedTask, AgentTaskOpener.canOpen(task) {
                        Text("点击打开 \(task.agentDisplayName)")
                            .lineLimit(1)
                    } else {
                        Text("更新于\(UsageDateFormat.relative(displayUpdatedAt))")
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 39, maxHeight: 39)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                codexMaterialTapGesture(in: Self.cardSpace) { location in
                    ripples.spawnWave(at: location)
                }
            )
            .accessibilityLabel(accessibilityText)

            if tasks.count > 1 {
                taskAdvanceButton
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(Color.codexMuted)
        .frame(maxWidth: .infinity, minHeight: 39, maxHeight: 39, alignment: .center)
        .overlay(alignment: .top) {
            CodexDivider()
        }
    }

    private var taskAdvanceButton: some View {
        Button(action: advanceTask) {
            HStack(spacing: 4) {
                Text("\(selectedIndex + 1)/\(tasks.count)")
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.codexPrimary)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Color.codexPrimary.opacity(0.09), in: Capsule())
            .overlay {
                Capsule().stroke(Color.codexPrimary.opacity(0.18), lineWidth: 0.7)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            codexMaterialTapGesture(in: Self.cardSpace) { location in
                ripples.spawnWave(at: location)
            }
        )
        .help("切换到下一个任务")
        .accessibilityLabel("切换任务，当前第 \(selectedIndex + 1) 个，共 \(tasks.count) 个")
    }

    private var displayState: CodexActivityState { displayedTask?.state ?? snapshot.state }
    private var displayAgentID: AgentID {
        let agentName = displayedTask?.agentDisplayName ?? "Codex"
        return BuiltInAgentCatalog.prioritized
            .first(where: { $0.displayName == agentName })?.id ?? .codex
    }
    private var displayTitle: String {
        if let displayedTask {
            if displayedTask.agentDisplayName == "Deepseek Harness" {
                return "Deepseek Harness"
            }
            return displayedTask.title
        }
        return switch snapshot.state {
        case .idle: "暂时没有待跟进的任务"
        case .unavailable: "暂时无法读取 Codex 活动"
        case .waitingForUser: "需要批准一项操作"
        case .completed: "任务刚刚完成"
        case .interrupted: "任务已停止"
        default: snapshot.threadTitle ?? "Codex 正在处理任务"
        }
    }
    private var displayDetail: String {
        if let displayedTask { return displayedTask.detail }
        // 空闲时不带任何具体 Agent 的信息（不写「某 Agent 空闲中」）。
        if snapshot.state == .idle {
            return "已接入的 Agent 开始工作后会显示在这里"
        }
        return snapshot.detail.isEmpty ? snapshot.state.hoverTitle : snapshot.detail
    }
    private var displayUpdatedAt: Date { displayedTask?.updatedAt ?? snapshot.updatedAt }
    private var displayMetadata: [(icon: String, value: String)] {
        guard let displayedTask else { return [] }
        if displayedTask.agentDisplayName == "Deepseek Harness" {
            return [
                ("cpu", "Deepseek Harness")
            ]
        }
        return [
            displayedTask.workspaceName.map { ("folder", $0) },
            displayedTask.gitBranch.map { ("arrow.triangle.branch", $0) },
            displayedTask.model.map { ("cpu", $0) }
        ].compactMap { $0 }
    }
    private var accessibilityText: String {
        if let task = displayedTask, AgentTaskOpener.canOpen(task) {
            return "\(displayState.taskLabel)：\(displayTitle)。点击打开对应 Agent 应用"
        }
        return tasks.count > 1
            ? "当前显示任务 \(selectedIndex + 1)，共 \(tasks.count) 个任务"
            : "\(displayState.taskLabel)：\(displayTitle)"
    }

    /// 点击任务卡：跳转到任务所属的 Agent 应用（与独立 Pet / 刘海一致的共享路由）。
    private func openDisplayedTask() {
        guard let task = displayedTask else { return }
        AgentTaskOpener.open(task)
    }

    /// 自动轮播推进：切到下一个任务，并同步选中 id 供侧栏等外部控件一致显示。
    private func advanceTask() {
        guard tasks.count > 1 else { return }
        let next = (displayIndex + 1) % tasks.count
        withAnimation(.easeInOut(duration: 0.32)) {
            displayIndex = next
        }
        if tasks.indices.contains(next) {
            selectedTaskID = tasks[next].id
        }
    }
}

struct QuotaCardsView: View {
    let snapshot: CodexUsageSnapshot
    let isLoggedIn: Bool

    var body: some View {
        HStack(spacing: DetachedWindowMetrics.quotaCardSpacing) {
            if snapshot.hasShortWindow, let short = snapshot.shortWindow {
                QuotaRingCard(window: short, tint: primaryHealth.color)
                    .frame(width: cardWidth)
            }
            if snapshot.hasWeeklyWindow {
                QuotaRingCard(
                    window: snapshot.weekly,
                    tint: snapshot.hasShortWindow ? Color.codexBlue : primaryHealth.color
                )
                .frame(width: cardWidth)
            }
            if !snapshot.hasShortWindow, !snapshot.hasWeeklyWindow {
                Text("额度暂不可用")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.codexMuted)
                    .frame(maxWidth: .infinity, minHeight: 61)
                    .background(Color.codexMist.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            }
            if snapshot.hasShortWindow != snapshot.hasWeeklyWindow {
                Spacer(minLength: 0)
            }
        }
    }

    private var cardWidth: CGFloat { DetachedWindowMetrics.quotaCardWidth }

    private var primaryHealth: QuotaHealthLevel {
        QuotaHealthLevel.from(window: snapshot.primaryWindow, isLoggedIn: isLoggedIn)
    }
}

private struct QuotaRingCard: View {
    let window: UsageWindow
    let tint: Color
    var resetCountdown: String? = nil
    var resetTooltip: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().stroke(Color.codexTrack, lineWidth: 4.5)
                    Circle()
                        .trim(from: 0, to: window.percent)
                        .stroke(tint, style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text(window.percentText)
                        .font(.system(size: 18, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.codexInk)
                    Text(window.label == "周额度" ? "本周" : window.label)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.codexMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, resetCountdown != nil ? 8 : 10)

            if let resetCountdown, !resetCountdown.isEmpty {
                CodexDivider()

                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 8.5))
                        .foregroundStyle(Color.codexMuted)
                    Text(resetCountdown)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.codexMuted)
                        .lineLimit(1)
                        .help(resetTooltip ?? "")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Color.codexMist.opacity(0.35))
            }
        }
        .frame(maxWidth: .infinity, minHeight: resetCountdown != nil ? 78 : 61, alignment: .leading)
        .background(Color.codexCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.codexLine, lineWidth: 0.7))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct DashboardProviderContext {
    let asset: BrandAssetID
    let title: String
    let subtitle: String
    let badge: String
    let badgeColor: Color
    let statusText: String
    let statusColor: Color
    let summaryText: String
    let accountLinkTitle: String
    let accountLinkURL: URL
    let officialLinkHelp: String
    let officialLinkURL: URL
    let syncState: String
    let syncedAt: Date
    let isRefreshing: Bool
    let emphasizesAccountLink: Bool
    /// 覆盖 footer 同步文案的文字颜色。为 nil 时按 `hasRefreshError`
    /// 归类（错误红 / 常规 muted）。OpenCode 用它把「已验证」显示为绿色，
    /// 因为额度暂不可查并不代表连接出错。
    var syncColor: Color? = nil
    /// 非 nil 时 footer 直接以图标 + `syncState` 文案展示（例如 OpenCode 的
    /// 「已验证」），不推导为「上次同步：时间」。
    var syncStateSymbol: String? = nil
}

private enum DashboardProviderLinks {
    static let codexUsage = URL(string: "https://chatgpt.com/codex/settings/usage")!
    static let deepSeekUsage = URL(string: "https://platform.deepseek.com/usage")!
    static let openCodeConsole = URL(string: "https://opencode.ai")!
    static let geminiConsole = URL(string: "https://aistudio.google.com")!
    static let geminiUsage = URL(string: "https://console.cloud.google.com/billing")!
}

private struct SyncFooterView: View {
    let context: DashboardProviderContext
    let actions: UsageActions
    let showsDetachedButton: Bool
    var isCompact = false
    let onRefresh: () -> Void
    let onOpenSettings: () -> Void
    /// 非 nil 时在 footer 显示「小眼睛查看 API Key」按钮。
    var onRevealKey: (() -> Void)? = nil

    @State private var showQuitConfirmation = false

    private var hasRefreshError: Bool {
        !["成功", "已验证", "预览数据", "刷新中", "授权中"].contains(context.syncState)
    }

    /// 竖版底部只剩约 90pt，同步文案必须缩写，完整内容留在 tooltip。
    private var syncText: String {
        // 显式要求内联展示 syncState 文案（如 OpenCode 的「已验证」）时，
        // 直接返回该文案，不推导为「上次同步：时间」。
        if context.syncStateSymbol != nil {
            return context.syncState
        }
        let lastSuccess = UsageDateFormat.syncTime(context.syncedAt)
        guard isCompact else {
            if context.isRefreshing { return "正在刷新…" }
            return hasRefreshError
                ? "\(context.syncState) · 上次成功：\(lastSuccess)"
                : "上次同步：\(lastSuccess)"
        }

        if context.isRefreshing { return "刷新中…" }
        if hasRefreshError { return context.syncState }
        let short = lastSuccess.hasPrefix("今天 ") ? String(lastSuccess.dropFirst(3)) : lastSuccess
        return "同步 \(short)"
    }

    private var syncHelpText: String {
        if hasRefreshError {
            return "\(context.syncState) · 上次成功：\(UsageDateFormat.syncTime(context.syncedAt))"
        }
        return "上次同步：\(UsageDateFormat.syncTime(context.syncedAt))"
    }

    var body: some View {
        HStack(spacing: isCompact ? 4 : 6) {
            if let syncStateSymbol = context.syncStateSymbol {
                Image(systemName: syncStateSymbol)
                    .font(.system(size: isCompact ? 11 : 13))
                    .foregroundStyle(context.syncColor ?? Color.codexGreen)
            }
            Text(syncText)
                .font(.system(size: isCompact ? 10 : 11))
                .foregroundStyle(context.syncColor ?? (hasRefreshError ? Color.codexRed : Color.codexMuted))
                .lineLimit(1)
                .help(syncHelpText)
            Spacer(minLength: 3)
            HStack(spacing: isCompact ? 3 : 5) {
                if let onRevealKey {
                    Button(action: onRevealKey) {
                        Image(systemName: "eye")
                            .font(.system(size: isCompact ? 10 : 11))
                    }
                    .buttonStyle(DashboardIconButtonStyle(helpText: "查看 API Key", isCompact: isCompact))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                Button { NSWorkspace.shared.open(context.officialLinkURL) } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                    .buttonStyle(DashboardIconButtonStyle(helpText: context.officialLinkHelp, isCompact: isCompact))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                Button(action: { actions.openGatewayWindow?() ?? GatewayWindowController.shared.show() }) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                }
                .buttonStyle(DashboardIconButtonStyle(helpText: "Gateway", isCompact: isCompact))
                Button(action: onOpenSettings) { Image(systemName: "gearshape") }
                    .buttonStyle(DashboardIconButtonStyle(helpText: "设置", isCompact: isCompact))
                if showsDetachedButton {
                    Button(action: actions.openDetachedWindow) { Image(systemName: "rectangle.on.rectangle.angled") }
                        .buttonStyle(DashboardIconButtonStyle(helpText: "打开分离窗口", isCompact: isCompact))
                }
            }
            Button {
                showQuitConfirmation = true
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(DashboardIconButtonStyle(helpText: "关闭软件", isCompact: isCompact))
            .accessibilityLabel("关闭软件")
            .padding(.leading, isCompact ? 1 : 2)
            Button(action: onRefresh) {
                if context.isRefreshing {
                    CodexButtonLoading(size: 11)
                        .frame(width: isCompact ? 40 : 48)
                } else {
                    Text(isCompact ? "刷新" : "立即刷新")
                }
            }
            .buttonStyle(DashboardRefreshButtonStyle(isCompact: isCompact))
            .disabled(context.isRefreshing)
            .padding(.leading, isCompact ? 2 : 4)
        }
        .padding(.top, isCompact ? 11 : 14)
        .frame(height: isCompact ? 40 : 46, alignment: .bottom)
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .top) { CodexDivider() }
        .alert("确认关闭软件？", isPresented: $showQuitConfirmation) {
            Button("取消", role: .cancel) {}
            Button("关闭软件", role: .destructive, action: actions.quit)
        } message: {
            Text("Tomo 将完全退出，菜单栏图标也会消失。")
        }
    }
}


private struct DashboardIconButtonStyle: PrimitiveButtonStyle {
    var helpText: String = ""
    var isCompact = false

    func makeBody(configuration: Configuration) -> some View {
        CodexMaterialWaveButtonBody(
            action: { configuration.trigger() },
            cornerRadius: 8,
            ink: .adaptiveMint
        ) {
            configuration.label
                .font(.system(size: isCompact ? 12 : 13, weight: .medium))
                .foregroundStyle(Color.codexMuted)
                .frame(width: isCompact ? 28 : 32, height: isCompact ? 28 : 32)
                .background(Color.codexMist.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        }
        .help(helpText)
    }
}

private struct DashboardRefreshButtonStyle: PrimitiveButtonStyle {
    var isCompact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        CodexMaterialWaveButtonBody(
            action: { configuration.trigger() },
            cornerRadius: 8,
            ink: .softLight
        ) {
            configuration.label
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.codexOnPrimary)
                .frame(minWidth: isCompact ? 52 : 65, minHeight: isCompact ? 28 : 31)
                .background(Color.codexPrimary, in: RoundedRectangle(cornerRadius: 8))
                .opacity(isEnabled ? 1 : 0.45)
        }
    }
}

extension CodexActivityState {
    var statusColor: Color { Color(nsColor: statusNSColor) }

    var companionText: String {
        switch self {
        case .unavailable: "状态不可用"
        case .idle: "安静待命"
        case .thinking: "正在思考"
        case .executing: "正在工作"
        case .reviewing: "正在检查"
        case .waitingForUser: "等待确认"
        case .completed: "刚刚完成"
        case .interrupted: "任务中止"
        }
    }

    var taskLabel: String {
        statusBarText ?? (self == .unavailable ? "状态不可用" : "状态正常")
    }

    var footnote: String {
        switch self {
        case .unavailable: "活动数据不可用"
        case .idle: "空闲 · 没有活跃任务"
        case .thinking: "分析任务 · 最近更新于刚刚"
        case .executing: "执行工具 · 最近更新于刚刚"
        case .reviewing: "检查改动 · 最近更新于刚刚"
        case .waitingForUser: "等待用户 · 确认后继续"
        case .completed: "任务完成 · 20 秒后回到空闲"
        case .interrupted: "任务中止 · 20 秒后回到空闲"
        }
    }

    var activityLabel: String {
        switch self {
        case .unavailable: "活动数据不可用"
        case .idle: "空闲"
        case .thinking: "分析任务"
        case .executing: "执行工具"
        case .reviewing: "检查改动"
        case .waitingForUser: "等待用户"
        case .completed: "任务完成"
        case .interrupted: "任务中止"
        }
    }
}

extension CodexActivitySnapshot {
    var dashboardTitle: String {
        if activeTaskCount > 0 { return "正在处理 \(activeTaskCount) 个任务" }
        if state == .idle { return "Agent 当前空闲" }
        return state.hoverTitle
    }

    var dashboardSubtitle: String {
        if let threadTitle, !threadTitle.isEmpty { return threadTitle }
        return detail.isEmpty ? state.hoverTitle : detail
    }
}

extension UsageDateFormat {
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let interval = max(0, now.timeIntervalSince(date))
        if interval < 60 { return "刚刚" }
        if interval < 3_600 { return "\(Int(interval / 60)) 分钟前" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "今天 HH:mm" : "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

extension Color {
    static let deepSeekBrand = Color(red: 0.302, green: 0.420, blue: 0.996)
    static let codexSidebarTop = codexDynamic(
        light: (0.973, 0.984, 0.978),
        dark: (0.145, 0.155, 0.151)
    )
    static let codexSidebarBottom = codexDynamic(
        light: (0.910, 0.941, 0.925),
        dark: (0.105, 0.116, 0.112)
    )
    static let codexGraphite = codexDynamic(
        light: (0.145, 0.169, 0.180),
        dark: (0.840, 0.860, 0.868)
    )
    static let codexOnGraphite = codexDynamic(
        light: (1.000, 1.000, 1.000),
        dark: (0.090, 0.100, 0.105)
    )

    private static func parseRGBComponents(from hex: String) -> (CGFloat, CGFloat, CGFloat) {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&int)
        switch clean.count {
        case 6:
            let r = CGFloat((int >> 16) & 0xFF) / 255.0
            let g = CGFloat((int >> 8) & 0xFF) / 255.0
            let b = CGFloat(int & 0xFF) / 255.0
            return (r, g, b)
        default:
            return (0.035, 0.525, 0.435)
        }
    }

    static func codexSidebarTop(for hex: String) -> Color {
        let (r, g, b) = parseRGBComponents(from: hex)
        let light: (CGFloat, CGFloat, CGFloat) = (0.960 + 0.040 * r, 0.960 + 0.040 * g, 0.960 + 0.040 * b)
        let dark: (CGFloat, CGFloat, CGFloat) = (0.130 + 0.030 * r, 0.130 + 0.030 * g, 0.130 + 0.030 * b)
        return codexDynamic(light: light, dark: dark)
    }

    static func codexSidebarBottom(for hex: String) -> Color {
        let (r, g, b) = parseRGBComponents(from: hex)
        let light: (CGFloat, CGFloat, CGFloat) = (0.870 + 0.130 * r, 0.870 + 0.130 * g, 0.870 + 0.130 * b)
        let dark: (CGFloat, CGFloat, CGFloat) = (0.090 + 0.050 * r, 0.090 + 0.050 * g, 0.090 + 0.050 * b)
        return codexDynamic(light: light, dark: dark)
    }
}

// MARK: - OpenCode 模型列表弹窗

private struct OpenCodeModelsModal: View {
    let models: [String]
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("可访问模型")
                    .font(.system(size: 15, weight: .bold))
                Text("\(models.count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.codexMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.codexMuted.opacity(0.10), in: Capsule())
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.codexMuted)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(models.enumerated()), id: \.element) { index, id in
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.codexMuted)
                                .frame(width: 22, alignment: .leading)
                            Text(id)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.codexInk)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 7)
                        .padding(.horizontal, 4)
                    }
                }
            }
            .frame(maxHeight: 340)
            .scrollIndicators(.never)
        }
        .padding(20)
        .background(Color.codexCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Color.codexLine)
        }
    }
}
