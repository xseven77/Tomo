import AppKit
import SwiftUI

private enum SettingsLayoutMetrics {
    static let sectionSpacing: CGFloat = 24
    static let sidebarWidth: CGFloat = 166
    /// Clears the native traffic lights without reserving a separate title row.
    static let windowTopInset: CGFloat = 14
    static let sidebarTopInset: CGFloat = 14
    static let windowBottomInset: CGFloat = 12
}

/// Sidebar order is the declaration order (`CaseIterable`), so `.pet` sits
/// directly under `.general` to keep the signature feature within reach.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case theme
    case appIcon
    case pet
    case accounts
    case agents
    case gateway
    case networkProxy
    case mobile

    var id: String { rawValue }

    /// Titles stay in Chinese. Only genuine domain nouns that have no better
    /// local term are kept in Latin script (Agent / Pet), so the list reads as
    /// one consistent voice instead of switching languages mid-column.
    var title: String {
        switch self {
        case .general: "通用"
        case .theme: "外观与主题"
        case .appIcon: "应用图标"
        case .pet: "状态栏与 Pet"
        case .accounts: "账号与密钥"
        case .agents: "Agent 接入"
        case .gateway: "本地网关"
        case .networkProxy: "网络代理"
        case .mobile: "移动端伴生"
        }
    }

    /// Subtitles carry the detail, so titles can stay short.
    var subtitle: String {
        switch self {
        case .general: "更新、偏好布局与自动刷新"
        case .theme: "现代 UI 主题色、外观模式与色彩方案"
        case .appIcon: "形态家族、材质质感与 Dock 栏图标定制；调节配置所见即所得，点击保存后触发生成"
        case .pet: "状态栏、任务浮窗与伴生宠物"
        case .accounts: "管理本机账号、订阅与 API Key"
        case .agents: "管理本地 Coding Agent 与 Hook 事件"
        case .gateway: "多协议 LLM 代理与实时遥测"
        case .networkProxy: "统一管理 Tomo 的公网出站连接"
        case .mobile: "局域网同步、Web 看板与多端配对"
        }
    }

    var systemImage: String {
        switch self {
        case .accounts: "person.2"
        case .agents: "terminal"
        case .gateway: "point.3.connected.trianglepath.dotted"
        case .general: "slider.horizontal.3"
        case .theme: "paintpalette"
        case .appIcon: "app.badge"
        case .networkProxy: "network"
        case .mobile: "iphone.gen3"
        case .pet: "pawprint"
        }
    }
}

struct SettingsView: View {
    @Bindable var store: UsageSnapshotStore
    @Bindable var settings: AppSettingsStore
    @Bindable var multiAgentSettings: MultiAgentSettingsStore
    @Bindable var updater: AppUpdateController
    let layout: UsagePanelLayout
    var initialTab: SettingsTab? = nil
    var onMeasuredContentHeightChange: (CGFloat) -> Void = { _ in }
    var onTabSelected: (SettingsTab) -> Void = { _ in }
    @State private var showsPetPicker = false
    @State private var showsCodexRestartConfirmation = false
    @State private var isRestartingCodex = false
    @State private var pendingAccountRemoval: PendingAccountRemoval?
    @State private var showsConnectionSheet = false
    @State private var pendingAPIKeyReveal: PendingAPIKeyReveal?
    @State private var revealedKey: RevealedAPIKey?
    @State private var revealedKeyCopyGeneration = 0
    @State private var editingConnectionTarget: AccountConnectionEditTarget?
    @State private var presentingInstallGuide: AgentIntegrationStatus?
    @State private var toast: SettingsToast?
    @State private var toastDismissGeneration = 0
    @State private var selectedTab: SettingsTab
    @State private var showsStickySettingsTitle = false
    @State private var showAppleGrid = false
    @State private var draftLogoConfig: TomoThemeConfig?
    @State private var isNetworkProxyTesting = false
    @State private var isProviderQuickTesting = false
    @State private var proxyTestMessage: String?
    @State private var providerQuickResults: [ProviderQuickConnectivityResult] = []
    @Environment(\.openURL) private var openURL

    init(
        store: UsageSnapshotStore,
        settings: AppSettingsStore,
        multiAgentSettings: MultiAgentSettingsStore,
        updater: AppUpdateController,
        layout: UsagePanelLayout,
        initialTab: SettingsTab? = nil,
        onMeasuredContentHeightChange: @escaping (CGFloat) -> Void = { _ in },
        onTabSelected: @escaping (SettingsTab) -> Void = { _ in }
    ) {
        self._store = Bindable(store)
        self._settings = Bindable(settings)
        self._multiAgentSettings = Bindable(multiAgentSettings)
        self._updater = Bindable(updater)
        self.layout = layout
        self.initialTab = initialTab
        self.onMeasuredContentHeightChange = onMeasuredContentHeightChange
        self.onTabSelected = onTabSelected
        self._selectedTab = State(initialValue: initialTab ?? .general)
    }

    var body: some View {
        lifecycleContent
            .tint(Color(hex: settings.themeConfig.accentColor))
            .background(settingsWindowBackground)
    }

    private var currentWindowBaseColor: Color {
        Color(hex: isDarkModeActive ? currentPreset.darkBase : currentPreset.lightBase)
    }

    private var settingsWindowBackground: some View {
        ZStack {
            currentWindowBaseColor
                .ignoresSafeArea()

            LinearGradient(
                colors: [
                    Color(hex: isDarkModeActive ? currentPreset.darkFg : currentPreset.lightFg).opacity(0.45),
                    currentWindowBaseColor.opacity(0.12),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 260)
            .frame(maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
        }
    }

    private var lifecycleContent: some View {
        alertContent
            .onPreferenceChange(SettingsMeasuredContentHeightKey.self) { height in
                guard layout == .window, height > 1 else { return }
                onMeasuredContentHeightChange(height)
            }
            .onAppear {
                guard layout == .window else { return }
                onMeasuredContentHeightChange(0)
            }
            .task(id: petPreviewIdentity) {
                await PetThumbnailLoader.shared.preload(
                    settings.availablePets.map(\.spritesheetURL)
                )
            }
            .onChange(of: settingsMeasuredContentIdentity) { _, _ in
                guard layout == .window else { return }
                onMeasuredContentHeightChange(-1)
            }
            .overlay {
                if showsConnectionSheet {
                    ZStack {
                        Rectangle()
                            .fill(Color.black.opacity(0.25))
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
            .animation(.easeOut(duration: 0.18), value: showsConnectionSheet)
            .overlay {
                if let revealedKey {
                    GeometryReader { proxy in
                        ZStack {
                            Rectangle()
                                .fill(Color.black.opacity(0.25))
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
            .animation(.easeOut(duration: 0.18), value: revealedKey)
            .overlay {
                if let editingConnectionTarget {
                    ZStack {
                        Rectangle()
                            .fill(Color.black.opacity(0.25))
                            .background(.ultraThinMaterial)
                            .ignoresSafeArea()
                            .onTapGesture { self.editingConnectionTarget = nil }

                        AccountConnectionsModalView(
                            store: multiAgentSettings,
                            editing: editingConnectionTarget
                        ) {
                            self.editingConnectionTarget = nil
                        }
                        .padding(14)
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                    }
                    .zIndex(35)
                }
            }
            .animation(.easeOut(duration: 0.18), value: editingConnectionTarget)
            .overlay {
                if let presentingInstallGuide {
                    ZStack {
                        Rectangle()
                            .fill(Color.black.opacity(0.25))
                            .background(.ultraThinMaterial)
                            .ignoresSafeArea()
                            .onTapGesture { self.presentingInstallGuide = nil }

                        AgentInstallGuideModal(
                            integration: presentingInstallGuide,
                            accentColor: Color(hex: settings.themeConfig.accentColor),
                            onCopyCommand: { command in
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(command, forType: .string)
                                showToast("已复制命令至剪贴板", systemImage: "doc.on.doc")
                            },
                            onRecheck: {
                                multiAgentSettings.refresh()
                                if let updated = multiAgentSettings.integrations.first(where: { $0.id == presentingInstallGuide.id }) {
                                    self.presentingInstallGuide = updated
                                    if updated.isInstalled {
                                        showToast("已检测到 \(updated.name) 安装！", systemImage: "checkmark.circle.fill")
                                    } else {
                                        showToast("未检测到 \(updated.name) 安装，请完成安装后重试", systemImage: "exclamationmark.triangle")
                                    }
                                }
                            },
                            onClose: { self.presentingInstallGuide = nil }
                        )
                        .padding(14)
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                    }
                    .zIndex(38)
                }
            }
            .animation(.easeOut(duration: 0.18), value: presentingInstallGuide)
            // Present notifications at the settings window root so they are
            // above the connection sheet and every tab's local content.
            .overlay(alignment: .bottom) {
                if let toast {
                    Label(toast.message, systemImage: toast.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(.black.opacity(0.84), in: Capsule(style: .continuous))
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .accessibilityLabel(toast.message)
                        .allowsHitTesting(false)
                        .zIndex(1000)
                }
            }
            .animation(.easeOut(duration: 0.18), value: toast)
    }

    private var alertContent: some View {
        toastTrackingContent
            // Keep this separate from the account-deletion Alert below. Two
            // `alert` modifiers on the same view can cause macOS SwiftUI to
            // silently drop one of them.
            .confirmationDialog("重启 Codex 以切换 Pet？", isPresented: $showsCodexRestartConfirmation) {
                Button("取消", role: .cancel) {}
                Button("重启 Codex", role: .destructive) {
                    restartCodex()
                }
            } message: {
                Text("这会退出并重新打开 Codex，正在运行或等待确认的任务可能会被中断。")
            }
            .alert(item: $pendingAccountRemoval) { pending in
                accountRemovalAlert(pending)
            }
            .onChange(of: multiAgentSettings.lastMessage) { _, message in
                guard let message else { return }
                showToast(message, systemImage: message.contains("失败") ? "exclamationmark.triangle.fill" : "link.badge.plus")
                multiAgentSettings.clearLastMessage()
            }
    }

    private var toastTrackingContent: some View {
        baseContent
            .onChange(of: settings.theme) { _, theme in
                showToast("主题：\(theme.title)")
            }
            .onChange(of: settings.autoRefreshInterval) { _, interval in
                showToast("自动刷新：\(interval.title)")
            }
            .onChange(of: settings.accountCarouselInterval) { _, interval in
                showToast("账号自动轮播：\(interval.title)")
            }
            .onChange(of: settings.dashboardOrientation) { _, orientation in
                showToast("主界面布局：\(orientation.title)")
            }
            .onChange(of: settings.launchAtLoginEnabled) { _, enabled in
                showToast("开机自启已\(enabled ? "开启" : "关闭")")
            }
            .onChange(of: settings.silentLaunchEnabled) { _, enabled in
                showToast("静默启动已\(enabled ? "开启" : "关闭")")
            }
            .onChange(of: settings.launchAtLoginErrorMessage) { _, message in
                guard let message else { return }
                showToast(message, systemImage: "exclamationmark.triangle.fill")
                settings.clearLaunchAtLoginError()
            }
            .onChange(of: settings.statusBarWaveEnabled) { _, enabled in
                showToast("活动流光已\(enabled ? "开启" : "关闭")")
            }
            .onChange(of: settings.statusBarIndicatorColorMode) { _, mode in
                showToast("状态圆灯颜色：\(mode.title)")
            }
            .onChange(of: settings.statusBarWaveColorMode) { _, mode in
                showToast("活动流光颜色：\(mode.title)")
            }
            .onChange(of: updater.phase) { oldPhase, phase in
                handleUpdaterPhaseChange(from: oldPhase, to: phase)
            }
    }

    private var baseContent: some View {
        Group {
            if layout == .window {
                settingsSplitView
            } else {
                ScrollView {
                    allSettingsContent
                }
                .scrollIndicators(.hidden)
                .background(ScrollIndicatorHider())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(Color.codexInk)
    }

    private func handleUpdaterPhaseChange(from oldPhase: AppUpdatePhase, to phase: AppUpdatePhase) {
        guard oldPhase != phase else { return }
        switch phase {
        case .upToDate:
            showToast("已是最新版本")
        case .available:
            if let version = updater.latestRelease?.version {
                showToast("发现新版本 \(version)", systemImage: "arrow.down.circle.fill")
            } else {
                showToast("发现新版本", systemImage: "arrow.down.circle.fill")
            }
        case .failed(let message):
            showToast(message, systemImage: "exclamationmark.triangle.fill")
        case .installing:
            showToast("正在安装，完成后将自动重启", systemImage: "arrow.down.circle.fill")
        default:
            break
        }
    }

    private var settingsSplitView: some View {
        HStack(spacing: 0) {
            settingsSidebar
                .frame(width: SettingsLayoutMetrics.sidebarWidth)
                .background(currentWindowBaseColor.opacity(0.45))

            CodexDivider(.vertical)

            if selectedTab == .appIcon {
                appIconPageLayout
            } else {
                ScrollView {
                    ScrollViewReader { scrollProxy in
                        selectedSettingsContent(scrollProxy: scrollProxy)
                            .padding(.horizontal, 20)
                            .padding(.top, SettingsLayoutMetrics.windowTopInset)
                            .padding(.bottom, SettingsLayoutMetrics.windowBottomInset)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .background(ScrollIndicatorHider(id: selectedTab))
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: SettingsMeasuredContentHeightKey.self,
                                        value: geometry.size.height
                                    )
                                }
                            }
                    }
                }
                .coordinateSpace(name: SettingsScrollCoordinateSpace.name)
                .onPreferenceChange(SettingsHeaderMinYKey.self) { minY in
                    if showsStickySettingsTitle {
                        if minY > -44 {
                            showsStickySettingsTitle = false
                        }
                    } else if minY < -72 {
                        showsStickySettingsTitle = true
                    }
                }
                .scrollIndicators(.hidden)
                .background(ScrollIndicatorHider(id: selectedTab))
            }
        }
        .background(settingsWindowBackground)
        .overlay(alignment: .top) {
            if showsStickySettingsTitle && selectedTab != .appIcon {
                HStack(alignment: .top, spacing: 0) {
                    Color.clear
                        .frame(width: SettingsLayoutMetrics.sidebarWidth + 1, height: 110)
                    stickySettingsTitle
                }
                .offset(y: -34)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.24), value: showsStickySettingsTitle)
        .id(settingsMeasuredContentIdentity)
    }

    private var allSettingsContent: some View {
        VStack(alignment: .leading, spacing: SettingsLayoutMetrics.sectionSpacing) {
            accountPoolSection
            agentIntegrationsSection
            updateSection
            networkProxyPageSection
            petSection
            thirdPartyPetResourcesSection
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Latin all-caps tracked well; CJK does not — use a light tracking
            // and a touch more size so the header reads as a label, not noise.
            Text("设置")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Color.codexMuted)
                .padding(.horizontal, 10)
                .padding(.bottom, 7)

            ForEach(SettingsTab.allCases) { tab in
                Button {
                    if selectedTab != tab {
                        selectedTab = tab
                        onTabSelected(tab)
                        if layout == .window {
                            onMeasuredContentHeightChange(-1)
                        }
                    }
                } label: {
                    let isSelected = selectedTab == tab
                    let accent = Color(hex: settings.themeConfig.accentColor)
                    HStack(spacing: 9) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 18)
                            .foregroundStyle(isSelected ? accent : Color.codexMuted)
                        Text(tab.title)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                            .foregroundStyle(isSelected ? Color.codexInk : Color.codexMuted)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .contentShape(Rectangle())
                    .background(
                        isSelected ? accent.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                }
                .buttonStyle(CodexPressableStyle(cornerRadius: 9, ink: .themeAccent(Color(hex: settings.themeConfig.accentColor))))
                .accessibilityValue(selectedTab == tab ? "已选择" : "")
            }

            Spacer(minLength: 12)

            Text("Tomo \(updater.currentVersion)")
                .font(.system(size: 9))
                .foregroundStyle(Color.codexMuted.opacity(0.82))

            Button {
                openURL(URL(string: "https://qiizo.cn")!)
            } label: {
                Text("QintelliZØ.")
                    .font(.custom("Carter One", size: 11))
                    .foregroundStyle(Color.codexMuted.opacity(0.82))
            }
            .buttonStyle(CodexPressableStyle(cornerRadius: 6))
            .padding(.top, 2)
        }
        .padding(.horizontal, 10)
        .padding(.top, SettingsLayoutMetrics.sidebarTopInset)
        .padding(.bottom, 14)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.codexCard.opacity(0.72))
    }

    private func selectedSettingsContent(scrollProxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(selectedTab.title)
                    .font(.system(size: 20, weight: .bold))
                Text(selectedTab.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.codexMuted)
            }
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: SettingsHeaderMinYKey.self,
                        value: geometry.frame(in: .named(SettingsScrollCoordinateSpace.name)).minY
                    )
                }
            }

            switch selectedTab {
            case .accounts:
                accountPoolSection
            case .agents:
                agentIntegrationsSection
            case .gateway:
                gatewaySection
            case .general:
                updateSection
            case .theme:
                appearanceAndThemeSection(scrollProxy: scrollProxy)
            case .appIcon:
                appIconSection
            case .networkProxy:
                networkProxyPageSection
            case .mobile:
                MobileCompanionSettingsView(
                    accentColor: Color(hex: settings.themeConfig.accentColor)
                ) { message, icon in
                    showToast(message, systemImage: icon)
                }
            case .pet:
                petSection
                thirdPartyPetResourcesSection
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var gatewaySection: some View {
        SettingsSection(
            title: "本地 Agent Gateway",
            subtitle: "统一代理本地 Coding Agent 流量，提供模型别名与实时遥测"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 26))
                        .foregroundStyle(gatewayStatusColor)
                        .frame(width: 44, height: 44)
                        .background(gatewayStatusColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("本地多协议 LLM 网关")
                            .font(.system(size: 13.5, weight: .bold))
                        Text("\(GatewaySupervisor.shared.statusText) · \(GatewaySupervisor.shared.endpoint?.absoluteString ?? "http://127.0.0.1:58349") · \(GatewaySupervisor.shared.activeRequests) 个活跃请求")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.codexMuted)
                    }

                    Spacer()

                    Button {
                        GatewayWindowController.shared.show()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "macwindow.on.rectangle")
                            Text("打开 Gateway")
                        }
                        .font(.system(size: 12.5, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .foregroundStyle(Color.codexOnPrimary)
                        .background(Color.codexPrimary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(14)
                .background(Color.codexCard)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.codexMuted)
                    Text("Gateway 在独立窗口中管理；关闭窗口不会停止服务。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.codexMuted)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private var gatewayStatusColor: Color {
        let supervisor = GatewaySupervisor.shared
        if !supervisor.isRunning {
            return Color.codexRed
        }
        if supervisor.lastError != nil {
            return Color.codexAmber
        }
        return Color.codexGreen
    }

    private var stickySettingsTitle: some View {
        Text(selectedTab.title)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(Color.codexInk)
            .padding(.horizontal, 20)
            .padding(.top, 19)
            .frame(height: 110, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background {
                LinearGradient(
                    stops: [
                        .init(color: Color.codexBackground, location: 0),
                        .init(color: Color.codexBackground, location: 0.48),
                        .init(color: Color.codexBackground.opacity(0.72), location: 0.72),
                        .init(color: Color.codexBackground.opacity(0), location: 1),
                    ],
                    startPoint: .topTrailing,
                    endPoint: .bottomTrailing
                )
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var settingsMeasuredContentIdentity: String {
        [
            settings.isTomoPetInstalled ? "1" : "0",
            String(settings.availablePets.count),
            String(multiAgentSettings.codexAccounts.count),
            String(multiAgentSettings.deepSeekConnections.count),
            String(multiAgentSettings.geminiConnections.count),
            String(multiAgentSettings.openCodeConnections.count),
            String(describing: updater.phase),
        ].joined(separator: "-")
    }

    private var petPreviewIdentity: String {
        settings.availablePets.map(\.id).joined(separator: "|")
    }

    private var accountPoolSection: some View {
        SettingsSection(
            title: "已连接",
            subtitle: "按供应商分组，凭据彼此隔离。"
        ) {
            VStack(spacing: 12) {
                // 添加按钮置顶，避免数据多时需滚动到底部
                if !multiAgentSettings.codexAccounts.isEmpty
                    || !multiAgentSettings.deepSeekConnections.isEmpty
                    || !multiAgentSettings.geminiConnections.isEmpty
                    || !multiAgentSettings.openCodeConnections.isEmpty {
                    Button {
                        showsConnectionSheet = true
                    } label: {
                        Label("添加供应商", systemImage: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                    }
                    .buttonStyle(CodexPressableStyle(cornerRadius: 9))
                    .foregroundStyle(Color.accentColor)
                }

                if !multiAgentSettings.codexAccounts.isEmpty {
                    accountProviderGroup(
                        name: "Codex",
                        detail: "账号",
                        count: multiAgentSettings.codexAccounts.count
                    ) {
                        ForEach(multiAgentSettings.codexAccounts) { connection in
                            accountPoolRow(
                                asset: .codex,
                                title: connection.label,
                                subtitle: connection.usage?.accountEmail ?? "Codex 账号",
                                badge: connection.authenticationState == .connected ? "已连接" : "待登录",
                                badgeColor: connection.authenticationState == .connected ? Color.codexGreen : Color.codexAmber,
                                actionTitle: "删除",
                                action: {
                                    pendingAccountRemoval = .codex(connection)
                                },
                                onReauth: connection.authenticationState != .connected ? {
                                    Task {
                                        _ = await multiAgentSettings.authenticateCodexAccount(connection)
                                    }
                                } : nil
                            )
                            if connection.id != multiAgentSettings.codexAccounts.last?.id {
                                CodexDivider()
                            }
                        }
                    }
                }

                if !multiAgentSettings.deepSeekConnections.isEmpty {
                    accountProviderGroup(
                        name: "DeepSeek",
                        detail: "API Key",
                        count: multiAgentSettings.deepSeekConnections.count
                    ) {
                        ForEach(multiAgentSettings.deepSeekConnections) { connection in
                            accountPoolRow(
                                asset: .deepSeek,
                                title: connection.label,
                                subtitle: "sk-•••• \(connection.keySuffix)",
                                badge: deepSeekPoolBadge(connection),
                                badgeColor: deepSeekPoolColor(connection),
                                actionTitle: "删除",
                                action: {
                                    pendingAccountRemoval = .deepSeek(connection)
                                },
                                onReveal: {
                                    presentAPIKeyReveal(for: connection.id)
                                },
                                onEdit: {
                                    presentConnectionEdit(for: connection.id)
                                }
                            )
                            if connection.id != multiAgentSettings.deepSeekConnections.last?.id {
                                CodexDivider()
                            }
                        }
                    }
                }

                if !multiAgentSettings.geminiConnections.isEmpty {
                    accountProviderGroup(
                        name: "Google Gemini",
                        detail: "账号",
                        count: multiAgentSettings.geminiConnections.count
                    ) {
                        ForEach(multiAgentSettings.geminiConnections) { connection in
                            let isThisConnectionAuthorizing =
                                multiAgentSettings.isGeminiOAuthInProgress
                                && multiAgentSettings.activeGeminiOAuthConnectionID == connection.id
                            let isAnotherConnectionAuthorizing =
                                multiAgentSettings.isGeminiOAuthInProgress
                                && !isThisConnectionAuthorizing
                            accountPoolRow(
                                asset: .googleGemini,
                                title: connection.displayName ?? connection.email ?? connection.label,
                                subtitle: geminiSubtitle(connection),
                                badge: geminiPoolBadge(connection),
                                badgeColor: geminiPoolColor(connection),
                                actionTitle: "删除",
                                action: {
                                    pendingAccountRemoval = .gemini(connection)
                                },
                                onReauth: isThisConnectionAuthorizing ? nil : {
                                    Task { _ = await multiAgentSettings.authenticateGeminiAccount(connection) }
                                },
                                isReauthDisabled: isAnotherConnectionAuthorizing,
                                onCancelReauth: isThisConnectionAuthorizing ? {
                                    multiAgentSettings.cancelCurrentGeminiOAuth()
                                } : nil
                            )
                            if connection.id != multiAgentSettings.geminiConnections.last?.id {
                                CodexDivider()
                            }
                        }
                    }
                }

                let openCodeGoConnections = multiAgentSettings.openCodeConnections.filter { $0.plan == .go }
                if !openCodeGoConnections.isEmpty {
                    accountProviderGroup(
                        name: "OpenCode Go",
                        detail: "API Key",
                        count: openCodeGoConnections.count
                    ) {
                        ForEach(openCodeGoConnections) { connection in
                            accountPoolRow(
                                asset: .openCode,
                                title: connection.label,
                                subtitle: "sk-•••• \(connection.keySuffix) · 额度暂不可查",
                                badge: openCodePoolBadge(connection),
                                badgeColor: openCodePoolColor(connection),
                                actionTitle: "删除"
                            ) {
                                pendingAccountRemoval = .openCode(connection)
                            } onReveal: {
                                presentAPIKeyReveal(for: connection.id)
                            } onEdit: {
                                presentConnectionEdit(for: connection.id)
                            }
                            if connection.id != openCodeGoConnections.last?.id { CodexDivider() }
                        }
                    }
                }

                let openCodeZenConnections = multiAgentSettings.openCodeConnections.filter { $0.plan == .zen }
                if !openCodeZenConnections.isEmpty {
                    accountProviderGroup(
                        name: "OpenCode Zen",
                        detail: "API Key",
                        count: openCodeZenConnections.count
                    ) {
                        ForEach(openCodeZenConnections) { connection in
                            accountPoolRow(
                                asset: .openCode,
                                title: connection.label,
                                subtitle: "sk-•••• \(connection.keySuffix) · 余额暂不可查",
                                badge: openCodePoolBadge(connection),
                                badgeColor: openCodePoolColor(connection),
                                actionTitle: "删除"
                            ) {
                                pendingAccountRemoval = .openCode(connection)
                            } onReveal: {
                                presentAPIKeyReveal(for: connection.id)
                            } onEdit: {
                                presentConnectionEdit(for: connection.id)
                            }
                            if connection.id != openCodeZenConnections.last?.id { CodexDivider() }
                        }
                    }
                }

                if multiAgentSettings.codexAccounts.isEmpty,
                   multiAgentSettings.deepSeekConnections.isEmpty,
                   multiAgentSettings.geminiConnections.isEmpty,
                   multiAgentSettings.openCodeConnections.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "person.2.badge.plus")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(Color.codexMuted)
                        Text("账户池为空")
                            .font(.system(size: 12, weight: .semibold))

                        Button {
                            showsConnectionSheet = true
                        } label: {
                            Label("添加供应商", systemImage: "plus")
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 16)
                                .frame(height: 36)
                        }
                        .buttonStyle(CodexPressableStyle(cornerRadius: 8))
                        .foregroundStyle(Color.accentColor)
                    }
                    .frame(maxWidth: .infinity, minHeight: 148)
                    .padding(16)
                    .settingsGroupSurface()
                }
            }
        }
    }

    private func accountProviderGroup<Content: View>(
        name: String,
        detail: String,
        count: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(name)
                    .font(.system(size: 11, weight: .semibold))
                Text(detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.codexMuted)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.codexMuted)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.codexMuted.opacity(0.09), in: Capsule())
            }
            .padding(.horizontal, 14)
            .frame(height: 34)

            CodexDivider()
            content()
        }
        .settingsGroupSurface()
    }

    private func accountPoolRow(
        asset: BrandAssetID,
        title: String,
        subtitle: String,
        badge: String,
        badgeColor: Color,
        actionTitle: String,
        action: @escaping () -> Void,
        onReveal: (() -> Void)? = nil,
        onEdit: (() -> Void)? = nil,
        onReauth: (() -> Void)? = nil,
        isReauthDisabled: Bool = false,
        onCancelReauth: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 12) {
            BrandIconView(asset: asset, size: 38, cornerRadius: 10)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(badge)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(badgeColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(badgeColor.opacity(0.10), in: Capsule())
                }
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.codexMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let onEdit {
                Button("编辑", action: onEdit)
                    .buttonStyle(.plain)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.codexMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.codexMuted.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color.codexMuted.opacity(0.18), lineWidth: 0.7)
                    }
            }
            if let onReveal {
                Button("查看", action: onReveal)
                    .buttonStyle(.plain)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.16), lineWidth: 0.7)
                    }
            }
            if let onReauth {
                Button("重新授权", action: onReauth)
                    .buttonStyle(.plain)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.codexAmber)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.codexAmber.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color.codexAmber.opacity(0.20), lineWidth: 0.7)
                    }
                    .disabled(isReauthDisabled)
                    .opacity(isReauthDisabled ? 0.42 : 1)
            }
            if let onCancelReauth {
                Button("取消授权", action: onCancelReauth)
                    .buttonStyle(.plain)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.codexMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.codexMuted.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color.codexMuted.opacity(0.18), lineWidth: 0.7)
                    }
            }
            Button(actionTitle, action: action)
                .buttonStyle(.plain)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Color.codexRed)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.codexRed.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.codexRed.opacity(0.14), lineWidth: 0.7)
                }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 64)
    }

    private func accountRemovalAlert(_ pending: PendingAccountRemoval) -> Alert {
        Alert(
            title: Text(pending.title),
            message: Text(pending.message),
            primaryButton: .destructive(Text("删除")) {
                switch pending {
                case let .codex(connection):
                    multiAgentSettings.removeCodexAccount(connection)
                case let .deepSeek(connection):
                    multiAgentSettings.removeDeepSeekConnection(connection)
                case let .openCode(connection):
                    multiAgentSettings.removeOpenCodeConnection(connection)
                case let .gemini(connection):
                    multiAgentSettings.removeGeminiConnection(connection)
                }
            },
            secondaryButton: .cancel(Text("取消"))
        )
    }

    /// 点击「查看」：先弹系统认证框，通过后再读取并展示 API Key。
    private func presentAPIKeyReveal(for connectionID: ConnectionID) {
        guard pendingAPIKeyReveal == nil else { return }
        pendingAPIKeyReveal = PendingAPIKeyReveal(connectionID: connectionID)
        Task { @MainActor in
            defer { pendingAPIKeyReveal = nil }
            do {
                try await APIAuthRevealService.authorize()
                let key = try multiAgentSettings.revealedAPIKey(for: connectionID)
                revealedKey = RevealedAPIKey(connectionID: connectionID, value: key)
            } catch {
                showToast(error.localizedDescription, systemImage: "lock.fill")
            }
        }
    }

    private func copyRevealedKey(_ key: RevealedAPIKey) {
        revealedKeyCopyGeneration += 1
        let generation = revealedKeyCopyGeneration
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key.value, forType: .string)
        showToast("已复制 API Key", systemImage: "doc.on.doc")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard generation == revealedKeyCopyGeneration else { return }
            revealedKey = nil
        }
    }

    /// 点击「编辑」：先弹系统认证框，通过后读取明文 Key 并打开复用创建
    /// 连接的 modal（编辑模式），可修改名称 / API Key / 工作间地址。
    private func presentConnectionEdit(for connectionID: ConnectionID) {
        guard editingConnectionTarget == nil else { return }
        Task { @MainActor in
            do {
                try await APIAuthRevealService.authorize()
                let key = try multiAgentSettings.revealedAPIKey(for: connectionID)
                guard let target = makeEditTarget(for: connectionID, apiKey: key) else { return }
                editingConnectionTarget = target
            } catch {
                showToast(error.localizedDescription, systemImage: "lock.fill")
            }
        }
    }

    private func geminiSubtitle(_ connection: GeminiAccountConnection) -> String {
        let base = connection.email ?? connection.label
        return "\(base) · Google OAuth 授权"
    }

    private func makeEditTarget(for connectionID: ConnectionID, apiKey: String) -> AccountConnectionEditTarget? {
        if let deepSeek = multiAgentSettings.deepSeekConnections.first(where: { $0.id == connectionID }) {
            return AccountConnectionEditTarget(
                id: deepSeek.id,
                kind: .deepSeek,
                initialLabel: deepSeek.label,
                initialAPIKey: apiKey,
                initialWorkspaceURL: nil
            )
        }
        if let openCode = multiAgentSettings.openCodeConnections.first(where: { $0.id == connectionID }) {
            return AccountConnectionEditTarget(
                id: openCode.id,
                kind: .openCode(openCode.plan),
                initialLabel: openCode.label,
                initialAPIKey: apiKey,
                initialWorkspaceURL: openCode.workspaceURL
            )
        }
        return nil
    }

    private func deepSeekPoolBadge(_ connection: DeepSeekAPIConnection) -> String {
        guard connection.authenticationState == .connected else { return "异常" }
        guard let total = connection.balance?.total else { return "待查询" }
        return "¥\(total)"
    }

    private func deepSeekPoolColor(_ connection: DeepSeekAPIConnection) -> Color {
        ProviderBalanceIndicator.resolve(
            total: connection.balance?.total,
            authenticationState: connection.authenticationState
        ).color
    }

    private func geminiPoolBadge(_ connection: GeminiAPIConnection) -> String {
        guard connection.authenticationState == .connected else { return "未授权" }
        if connection.rateLimitState == "rate_limited" { return "限流中" }
        return "已连接"
    }

    private func geminiPoolColor(_ connection: GeminiAPIConnection) -> Color {
        guard connection.authenticationState == .connected else { return Color.codexAmber }
        if connection.rateLimitState == "rate_limited" { return Color.codexAmber }
        return Color.codexGreen
    }

    private func openCodePoolBadge(_ connection: OpenCodeAPIConnection) -> String {
        connection.authenticationState == .connected ? "已验证" : "需要检查"
    }

    private func openCodePoolColor(_ connection: OpenCodeAPIConnection) -> Color {
        connection.authenticationState == .connected ? .codexGreen : .codexAmber
    }

    private var agentIntegrationsSection: some View {
        SettingsSection(
            title: "接入状态",
            subtitle: "Tomo 自动检测本地已安装的 Coding Agent 并通过会话读取实时同步任务状态，无需安装 Hook。"
        ) {
            VStack(spacing: 12) {
                HStack {
                    Text("共检测到 \(multiAgentSettings.integrations.filter(\.isInstalled).count) / \(multiAgentSettings.integrations.count) 个 Agent 已安装")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.codexMuted)
                    Spacer()
                    Button {
                        multiAgentSettings.refresh()
                        showToast("已刷新 Agent 安装检测", systemImage: "arrow.clockwise")
                    } label: {
                        Label("重新检测", systemImage: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal, 4)

                VStack(spacing: 0) {
                    ForEach(Array(multiAgentSettings.integrations.enumerated()), id: \.element.id) { index, integration in
                        agentIntegrationRow(integration)
                        if index < multiAgentSettings.integrations.count - 1 {
                            CodexDivider()
                        }
                    }
                }
                .settingsGroupSurface()
            }
        }
    }

    private func agentIntegrationRow(_ integration: AgentIntegrationStatus) -> some View {
        let themeAccent = Color(hex: settings.themeConfig.accentColor)
        return HStack(spacing: 12) {
            BrandIconView(
                asset: .agent(integration.id)
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(integration.name)
                        .font(.system(size: 13, weight: .semibold))

                    if integration.isInstalled {
                        Text("已接入")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(themeAccent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(themeAccent.opacity(0.12), in: Capsule())
                    } else {
                        Text("未安装")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.codexAmber)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.codexAmber.opacity(0.12), in: Capsule())
                    }
                }
                Text(integration.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.codexMuted)
                Text(hookStatusLine(integration))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(
                        integration.isInstalled
                            ? themeAccent
                            : Color.codexAmber
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 8)

            if !integration.isInstalled {
                Button {
                    presentingInstallGuide = integration
                } label: {
                    Label("安装方式", systemImage: "arrow.up.right.square")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(CodexPressableStyle(cornerRadius: 8))
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("查看 \(integration.name) 官方安装方式")
            } else {
                Button {
                    presentingInstallGuide = integration
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.codexMuted)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看 \(integration.name) 接入说明与官方文档")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 68)
        .contentShape(Rectangle())
        .onTapGesture {
            presentingInstallGuide = integration
        }
    }

    private func hookStatusLine(_ integration: AgentIntegrationStatus) -> String {
        if integration.isInstalled {
            return "已接入 · 会话读取"
        }
        return "本地未安装 · 点击查看官方安装方式"
    }

    private var updateSection: some View {
        let themeAccent = Color(hex: settings.themeConfig.accentColor)
        return VStack(alignment: .leading, spacing: 20) {
            SettingsSection(title: "应用更新", subtitle: "通过 GitHub Releases 检查、下载并安装 Tomo 新版本") {
                SettingsUpdateCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            SettingsApplicationIcon(config: settings.themeConfig)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 7) {
                                    Text("Tomo")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Color.codexInk)
                                    Text(verbatim: "v\(updater.currentVersion)")
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .foregroundStyle(themeAccent)
                                        .background(themeAccent.opacity(0.12), in: Capsule())
                                }
                                Text("Build \(updater.currentBuild) · \(updater.settingsStatusLine)")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Color.codexMuted)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 12)
                            if updater.phase == .available || updater.phase == .downloading || updater.phase == .installing {
                                SettingsUpdatePrimaryAction(
                                    title: appUpdateActionTitle,
                                    systemImage: "arrow.up.circle.fill",
                                    isBusy: updater.phase.isBusy,
                                    isEnabled: !updater.phase.isBusy,
                                    action: primaryUpdateAction
                                )
                            } else {
                                SettingsUpdateChip(
                                    title: updater.settingsPrimaryActionTitle,
                                    systemImage: "arrow.triangle.2.circlepath",
                                    isEnabled: !updater.phase.isBusy,
                                    isBusy: updater.phase == .checking,
                                    busyTint: themeAccent,
                                    action: primaryUpdateAction
                                )
                            }
                        }
                        if updater.phase == .downloading {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text("正在下载应用更新…")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(Color.codexInk)
                                    Spacer()
                                    Text(verbatim: "\(Int(updater.downloadProgress * 100))%")
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Color.codexPrimary)
                                }
                                ProgressView(value: updater.downloadProgress > 0 ? updater.downloadProgress : nil)
                                    .progressViewStyle(.linear)
                                    .tint(Color.codexPrimary)
                                    .controlSize(.small)
                            }
                            .padding(.vertical, 2)
                        } else if let feedback = appUpdateFeedback {
                            HStack(spacing: 6) {
                                Image(systemName: appUpdateFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                    .font(.system(size: 11))
                                Text(feedback)
                                    .font(.system(size: 11.5))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .foregroundStyle(appUpdateFailed ? Color.codexRed : themeAccent)
                            .padding(.leading, 2)
                        }
                        Divider().overlay(Color.codexLine.opacity(0.6))
                        HStack(spacing: 8) {
                            SettingsUpdateChip(title: "查看版本发布", systemImage: "arrow.up.right", action: updater.openReleasesPage)
                            SettingsUpdateChip(title: "在访达中打开", systemImage: "folder") {
                                NSWorkspace.shared.selectFile(Bundle.main.bundleURL.path, inFileViewerRootedAtPath: Bundle.main.bundleURL.deletingLastPathComponent().path)
                            }
                            Spacer(minLength: 0)
                            if updater.phase == .available {
                                SettingsUpdateChip(title: "重新检查", systemImage: "arrow.triangle.2.circlepath", action: updater.checkForUpdates)
                            }
                        }
                    }
                }
            }
            SettingsSection(title: "偏好设置") {
                VStack(alignment: .leading, spacing: 0) {
                    launchAtLoginSection
                    CodexDivider()
                    silentLaunchSection
                    CodexDivider()
                    orientationSection
                    CodexDivider()
                    mainWindowProviderCarouselSection
                    CodexDivider()
                    notchProviderCarouselSection
                    CodexDivider()
                    accountCarouselSection
                    CodexDivider()
                    refreshSection
                }
                .settingsGroupSurface()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { settings.refreshLaunchAtLoginStatus() }
    }

    private var appUpdateFailed: Bool {
        if case .failed = updater.phase { return true }
        return false
    }

    private var appUpdateActionTitle: String {
        switch updater.phase {
        case .downloading: return "正在更新…"
        case .installing: return "正在安装…"
        default: return "更新至 v\(updater.latestRelease?.version ?? updater.currentVersion)"
        }
    }

    private var appUpdateFeedback: String? {
        switch updater.phase {
        case .available, .upToDate, .failed, .installing: return updater.settingsStatusLine
        default: return nil
        }
    }

    private func primaryUpdateAction() {
        switch updater.phase {
        case .available:
            updater.downloadAndInstall()
        default:
            updater.checkForUpdates()
        }
    }

    private func appearanceAndThemeSection(scrollProxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: SettingsLayoutMetrics.sectionSpacing) {
            // 1. 现代 UI 主题实时预览卡片
            ChromeThemePreviewCard(
                themeConfig: settings.themeConfig,
                themePreference: settings.theme,
                preset: currentPreset,
                isDark: isDarkModeActive,
                onReset: resetThemeToDefault
            )

            // 2. 外观模式（跟随系统 / 浅色 / 深色）
            SettingsSection(
                title: "外观模式",
                subtitle: "跟随系统设置自动切换，或始终以浅色 / 深色呈现"
            ) {
                ChromeAppearanceModeSwitcher(
                    selection: $settings.theme,
                    accentColor: Color(hex: settings.themeConfig.accentColor)
                )
                .padding(14)
                .settingsGroupSurface()
            }

            // 3. 精选现代 UI 主题色
            SettingsSection(
                title: "色彩主题",
                subtitle: "精选 15 款现代 UI 设计主体色与自定义吸色盘，完美融合顶栏容器、品牌主色与基底表层"
            ) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 14) {
                    ForEach(TomoThemeConstants.chromePresetColors) { preset in
                        let isSel: Bool = {
                            if preset.isCustom {
                                return !TomoThemeConstants.chromePresetColors.contains(where: { !$0.isCustom && $0.seedHex.caseInsensitiveCompare(settings.themeConfig.accentColor) == .orderedSame })
                            } else {
                                return settings.themeConfig.accentColor.caseInsensitiveCompare(preset.seedHex) == .orderedSame
                            }
                        }()
                        ChromeThemeColorSwatchView(
                            preset: preset,
                            isSelected: isSel,
                            isDark: isDarkModeActive,
                            activeAccentColor: Color(hex: settings.themeConfig.accentColor),
                            onSelect: {
                                if !preset.isCustom {
                                    var updated = settings.themeConfig
                                    updated.accentColor = preset.seedHex
                                    updated.accentEndColor = TomoThemeConstants.computeAutoGradient(startHex: preset.seedHex, algo: updated.gradientAlgo)
                                    updated.updatedAt = Date().timeIntervalSince1970 * 1000
                                    settings.themeConfig = updated
                                    if draftLogoConfig != nil {
                                        draftLogoConfig?.accentColor = preset.seedHex
                                        draftLogoConfig?.accentEndColor = TomoThemeConstants.computeAutoGradient(startHex: preset.seedHex, algo: draftLogoConfig?.gradientAlgo ?? updated.gradientAlgo)
                                    }
                                }
                            },
                            onCustomColorPicked: { hex in
                                var updated = settings.themeConfig
                                updated.accentColor = hex
                                updated.accentEndColor = TomoThemeConstants.computeAutoGradient(startHex: hex, algo: updated.gradientAlgo)
                                updated.updatedAt = Date().timeIntervalSince1970 * 1000
                                settings.themeConfig = updated
                                if draftLogoConfig != nil {
                                    draftLogoConfig?.accentColor = hex
                                    draftLogoConfig?.accentEndColor = TomoThemeConstants.computeAutoGradient(startHex: hex, algo: draftLogoConfig?.gradientAlgo ?? updated.gradientAlgo)
                                }
                            }
                        )
                    }
                }
                .padding(14)
                .settingsGroupSurface()
            }
            .id("theme_colors_section")

            // 4. 前往「应用图标」进行专属定制
            SettingsSection(
                title: "应用与程序坞图标",
                subtitle: "定制 macOS 系统 Dock 栏与启动台呈现的品牌 Logo 形态、WWDC25 液态玻璃与立体阴影"
            ) {
                HStack(spacing: 14) {
                    TomoMarkView(
                        config: settings.themeConfig,
                        size: 42,
                        showTile: true,
                        showAppleGrid: false
                    )
                    .frame(width: 48, height: 48)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("前往「应用图标」进行专属定制")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.codexInk)
                        Text("提供 156pt 实时预览舞台、Apple 规范网格参考线、液态玻璃透射折射、形态家族与草稿保护。")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.codexMuted)
                    }

                    Spacer()

                    Button {
                        selectedTab = .appIcon
                        onTabSelected(.appIcon)
                    } label: {
                        HStack(spacing: 5) {
                            Text("前往应用图标")
                            Image(systemName: "arrow.right")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(Color(hex: settings.themeConfig.accentColor).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(Color(hex: settings.themeConfig.accentColor))
                    }
                    .buttonStyle(.plain)
                }
                .padding(14)
                .settingsGroupSurface()
            }

            // 5. 多端同步
            SettingsSection(
                title: "多端同步"
            ) {
                VStack(spacing: 0) {
                    SettingsInlineRow(
                        title: "多端主题与 Logo 实时联动",
                        subtitle: "开启后，手机端与桌面端可相互同步主题色与 Logo 切换；关闭后双方独立配置互不影响"
                    ) {
                        SettingsSwitch(
                            isOn: $settings.syncThemeWithMobileEnabled,
                            accessibilityLabel: "多端主题与 Logo 实时联动"
                        )
                    }
                }
                .settingsGroupSurface()
            }
        }
        .onAppear {
            if draftLogoConfig == nil {
                draftLogoConfig = settings.themeConfig
            }
        }
        .onChange(of: settings.themeConfig) { _, newConfig in
            if !hasUnsavedLogoChanges {
                draftLogoConfig = newConfig
            }
        }
    }

    // MARK: - 应用图标专属页面（左侧固定 Sticky 预览舞台，右侧独立滚动配置区）
    private var appIconPageLayout: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 顶部页面标题与说明
            VStack(alignment: .leading, spacing: 4) {
                Text(SettingsTab.appIcon.title)
                    .font(.system(size: 20, weight: .bold))
                Text(SettingsTab.appIcon.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.codexMuted)
            }
            .padding(.top, SettingsLayoutMetrics.windowTopInset)
            .padding(.horizontal, 20)

            // 两栏结构：左侧大 Logo 预览舞台固定 Sticky，右侧全套配置项独立平滑滚动
            HStack(alignment: .top, spacing: 16) {
                // 左侧：固定 Sticky 大 Logo 预览舞台 + 保存状态与操作
                ScrollView(.vertical, showsIndicators: false) {
                    logoPreviewStageView
                        .frame(width: 220)
                        .background(ScrollIndicatorHider(id: "appIconPreview"))
                }
                .frame(width: 220)
                .scrollIndicators(.hidden)
                .background(ScrollIndicatorHider(id: "appIconPreviewOuter"))

                // 右侧：全套配置项独立平滑滚动
                ScrollView(.vertical, showsIndicators: false) {
                    logoSettingsControlsView
                        .padding(.trailing, 6)
                        .padding(.bottom, SettingsLayoutMetrics.windowBottomInset)
                        .background(ScrollIndicatorHider(id: "appIconControls"))
                }
                .scrollIndicators(.hidden)
                .background(ScrollIndicatorHider(id: "appIconControlsOuter"))
            }
            .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if draftLogoConfig == nil {
                draftLogoConfig = settings.themeConfig
            }
        }
        .onChange(of: settings.themeConfig) { _, newConfig in
            if !hasUnsavedLogoChanges {
                draftLogoConfig = newConfig
            }
        }
    }

    private var appIconSection: some View {
        appIconPageLayout
    }

    // MARK: - Logo 左右分栏：左侧大图标预览舞台
    private var logoPreviewStageView: some View {
        VStack(spacing: 12) {
            // 顶部标题与状态标签
            HStack {
                Text("实时效果预览")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.codexInk)
                Spacer()
                if hasUnsavedLogoChanges {
                    Text("草稿未保存")
                        .font(.system(size: 9.5, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(Color(hex: effectiveDraftConfig.accentColor))
                        .background(Color(hex: effectiveDraftConfig.accentColor).opacity(0.12), in: Capsule())
                } else {
                    Text("已生效")
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(Color.codexMuted)
                        .background(Color.codexMist, in: Capsule())
                }
            }

            // 大 Logo 画布舞台 (156pt 居中大图板)
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.codexMist.opacity(0.35))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.codexLine.opacity(0.4), lineWidth: 0.8)
                    )

                TomoMarkView(
                    config: effectiveDraftConfig,
                    size: 156,
                    showTile: true,
                    showAppleGrid: showAppleGrid
                )
                .frame(width: 164, height: 164)
            }
            .frame(height: 184)

            // 透视 Apple 规范网格开关
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("透视 Apple 规范网格")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.codexInk)
                    Text("仅作构图参考，不参与生成")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.codexMuted)
                }
                Spacer()
                SettingsSwitch(
                    isOn: $showAppleGrid,
                    accessibilityLabel: "透视 Apple 规范网格"
                )
            }
            .padding(.horizontal, 2)

            CodexDivider()

            // 操作区：保存并应用、还原、刷新启动台
            VStack(spacing: 8) {
                Button {
                    saveDraftLogoConfig()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("保存并应用到应用图标")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7.5)
                    .background(
                        hasUnsavedLogoChanges
                            ? Color(hex: effectiveDraftConfig.accentColor)
                            : Color.codexMist.opacity(0.8),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .foregroundStyle(
                        hasUnsavedLogoChanges
                            ? Color.white
                            : Color.codexMuted
                    )
                }
                .buttonStyle(.plain)
                .disabled(!hasUnsavedLogoChanges)

                HStack(spacing: 8) {
                    Button {
                        resetLogoConfigToDefault()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.counterclockwise")
                            Text("还原默认值")
                        }
                        .font(.system(size: 10.5, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(Color.codexMist.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(isDraftDefaultLogoConfig ? Color.codexMuted : Color.codexInk)
                    }
                    .buttonStyle(.plain)
                    .disabled(isDraftDefaultLogoConfig)
                    .help("恢复为官方推荐默认图标形态与质感")

                    Button {
                        TomoMarkSvgRenderer.updateSystemBundleIcon(config: settings.themeConfig, refreshLaunchpad: true)
                        showToast("已向 LaunchServices 发送图标刷新请求", systemImage: "arrow.clockwise")
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.clockwise")
                            Text("刷新启动台")
                        }
                        .font(.system(size: 10.5, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(Color.codexMist.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(Color.codexInk)
                    }
                    .buttonStyle(.plain)
                    .help("重新注册 LaunchServices 并在需要时唤醒系统启动台更新图标缓存")
                }

                if hasUnsavedLogoChanges {
                    Button {
                        revertDraftLogoConfig()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.uturn.backward")
                            Text("放弃未保存修改")
                        }
                        .font(.system(size: 10.5, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3.5)
                        .foregroundStyle(Color.codexMuted)
                    }
                    .buttonStyle(.plain)
                    .help("放弃当前草稿，还原为上次保存的设置")
                }
            }
        }
        .padding(14)
        .settingsGroupSurface()
    }

    // MARK: - Logo 左右分栏：右侧配置项（操作仅写草稿）
    private var logoSettingsControlsView: some View {
        VStack(spacing: 12) {
            // 1. 快捷入口：当前主体色由主题决定
            HStack(spacing: 10) {
                Circle()
                    .fill(Color(hex: effectiveDraftConfig.accentColor))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1.2))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("主体颜色")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.codexInk)
                        Text(currentThemeName)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.codexMuted)
                    }
                    Text("Logo 主体色直接沿用主题色彩方案")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.codexMuted)
                }

                Spacer(minLength: 8)

                Button {
                    selectedTab = .theme
                    onTabSelected(.theme)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "paintpalette")
                            .font(.system(size: 10.5))
                        Text("选择颜色")
                            .lineLimit(1)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8.5))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color(hex: effectiveDraftConfig.accentColor).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(Color(hex: effectiveDraftConfig.accentColor))
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color.codexCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(CodexDivider.color, lineWidth: 1)
            )

            // 2. Logo 形态家族
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Logo 形态家族")
                        .font(.system(size: 12, weight: .semibold))
                    Text("选择桌面端基底形态，移动端将自动配对对应款")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.codexMuted)
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach([
                        ("circle", "圆形"),
                        ("hex", "六边形"),
                        ("squircle", "方圆"),
                        ("cloud7", "7瓣云朵"),
                        ("pure", "纯粹 T"),
                        ("pure_go", "纯粹 T+GO")
                    ], id: \.0) { fam, name in
                        let isSelected = effectiveDraftConfig.logoFamily == fam
                        let accent = Color(hex: effectiveDraftConfig.accentColor)
                        Button {
                            mutateDraftLogoConfig { $0.logoFamily = fam }
                        } label: {
                            var famConfig = effectiveDraftConfig
                            let _ = { famConfig.logoFamily = fam }()
                            VStack(spacing: 5) {
                                TomoMarkView(
                                    config: famConfig,
                                    size: 26,
                                    showTile: true,
                                    showAppleGrid: false
                                )
                                .frame(width: 30, height: 30)

                                Text(name)
                                    .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                                    .foregroundStyle(isSelected ? Color.codexInk : Color.codexMuted)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                isSelected ? accent.opacity(0.08) : Color.codexMist.opacity(0.35),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(
                                        isSelected ? accent : Color.codexLine.opacity(0.5),
                                        lineWidth: isSelected ? 1.5 : 0.8
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(14)
            .settingsGroupSurface()

            // 3. 尺寸与立体阴影
            VStack(spacing: 0) {
                // Logo 尺寸占比
                SettingsInlineRow(
                    title: "Logo 尺寸占比",
                    subtitle: "调整中心徽标相对于底板的大小比例",
                    wrapThreshold: 340
                ) {
                    HStack(spacing: 10) {
                        Slider(
                            value: Binding(
                                get: { effectiveDraftConfig.logoScale },
                                set: { val in mutateDraftLogoConfig { $0.logoScale = val } }
                            ),
                            in: 0.50...1.20,
                            step: 0.01
                        )
                        .frame(width: 130)

                        let pct = Int(round(effectiveDraftConfig.logoScale * 100))
                        Text("\(pct)%")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.codexInk)
                            .frame(width: 42, alignment: .trailing)
                    }
                }

                CodexDivider()

                // 主体流体阴影
                SettingsInlineRow(
                    title: "主体流体阴影",
                    subtitle: effectiveDraftConfig.shadowEnabled
                        ? (effectiveDraftConfig.shadowStyle == "tight" ? "紧凑微距" : "柔和微散")
                        : "已关闭立体彩色漫反射",
                    wrapThreshold: 340
                ) {
                    HStack(spacing: 8) {
                        if effectiveDraftConfig.shadowEnabled {
                            HStack(spacing: 4) {
                                ForEach([
                                    ("tight", "微距"),
                                    ("soft", "柔和")
                                ], id: \.0) { style, label in
                                    let isSel = effectiveDraftConfig.shadowStyle == style
                                    Button {
                                        mutateDraftLogoConfig { $0.shadowStyle = style }
                                    } label: {
                                        Text(label)
                                            .font(.system(size: 10.5, weight: isSel ? .semibold : .regular))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(isSel ? Color.codexCard : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                                            .foregroundStyle(isSel ? Color.codexInk : Color.codexMuted)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(2)
                            .background(Color.codexMist, in: RoundedRectangle(cornerRadius: 6))
                        }

                        SettingsSwitch(
                            isOn: Binding(
                                get: { effectiveDraftConfig.shadowEnabled },
                                set: { val in mutateDraftLogoConfig { $0.shadowEnabled = val } }
                            ),
                            accessibilityLabel: "主体流体阴影"
                        )
                    }
                }

                if effectiveDraftConfig.shadowEnabled {
                    CodexDivider()

                    // 立体阴影方向
                    SettingsInlineRow(
                        title: "立体阴影方向",
                        subtitle: "控制中心徽标光照流体阴影的投射方向",
                        wrapThreshold: 340
                    ) {
                        HStack(spacing: 4) {
                            ForEach([
                                ("down", "向下"),
                                ("bottomRight", "右下"),
                                ("radial", "弥散"),
                                ("up", "向上")
                            ], id: \.0) { dir, label in
                                let isSel = effectiveDraftConfig.shadowDirection == dir
                                Button {
                                    mutateDraftLogoConfig { $0.shadowDirection = dir }
                                } label: {
                                    Text(label)
                                        .font(.system(size: 10.5, weight: isSel ? .semibold : .regular))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 4.5)
                                        .background(isSel ? Color.codexCard : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                                        .foregroundStyle(isSel ? Color.codexInk : Color.codexMuted)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(2)
                        .background(Color.codexMist, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: effectiveDraftConfig.shadowEnabled)
            .settingsGroupSurface()

            // 4. 徽标特征与渲染
            VStack(spacing: 0) {
                // 徽标内容
                SettingsInlineRow(
                    title: "徽标内容",
                    subtitle: "中央呈现经典大写 T，或额度百分比符号 %",
                    wrapThreshold: 340
                ) {
                    HStack(spacing: 4) {
                        ForEach([
                            ("t", "T 字母"),
                            ("percent", "% 百分号")
                        ], id: \.0) { mode, label in
                            let isSel = effectiveDraftConfig.logoContent == mode
                            Button {
                                mutateDraftLogoConfig { $0.logoContent = mode }
                            } label: {
                                Text(label)
                                    .font(.system(size: 11, weight: isSel ? .semibold : .regular))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4.5)
                                    .background(isSel ? Color.codexCard : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                                    .foregroundStyle(isSel ? Color.codexInk : Color.codexMuted)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                    .background(Color.codexMist, in: RoundedRectangle(cornerRadius: 6))
                }

                CodexDivider()

                // 配色模式
                SettingsInlineRow(
                    title: "配色模式",
                    subtitle: "彩色品牌色、沉浸黑白印章、反色高对比",
                    wrapThreshold: 340
                ) {
                    HStack(spacing: 4) {
                        ForEach([
                            ("color", "彩色"),
                            ("mono", "黑白"),
                            ("inverse", "反色")
                        ], id: \.0) { mode, label in
                            let isSel = effectiveDraftConfig.renderMode == mode
                            Button {
                                mutateDraftLogoConfig { $0.renderMode = mode }
                            } label: {
                                Text(label)
                                    .font(.system(size: 11, weight: isSel ? .semibold : .regular))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4.5)
                                    .background(isSel ? Color.codexCard : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                                    .foregroundStyle(isSel ? Color.codexInk : Color.codexMuted)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                    .background(Color.codexMist, in: RoundedRectangle(cornerRadius: 6))
                }

                CodexDivider()

                // 图案模式
                SettingsInlineRow(
                    title: "图案模式",
                    subtitle: "纯白防干扰，或真实镂空透底",
                    wrapThreshold: 340
                ) {
                    HStack(spacing: 4) {
                        ForEach([
                            ("solid", "纯白"),
                            ("cutout", "镂空")
                        ], id: \.0) { mode, label in
                            let isSel = effectiveDraftConfig.glyphMode == mode
                            Button {
                                mutateDraftLogoConfig { $0.glyphMode = mode }
                            } label: {
                                Text(label)
                                    .font(.system(size: 11, weight: isSel ? .semibold : .regular))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4.5)
                                    .background(isSel ? Color.codexCard : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                                    .foregroundStyle(isSel ? Color.codexInk : Color.codexMuted)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                    .background(Color.codexMist, in: RoundedRectangle(cornerRadius: 6))
                }

                CodexDivider()

                // T 字母缺口
                SettingsInlineRow(
                    title: "T 字母缺口",
                    subtitle: effectiveDraftConfig.logoContent == "percent"
                        ? "当前为 % 百分号内容；缺口特征在切换至 T 字母时生效"
                        : "标准完整连贯轮廓，或右翼断开分离增加科技留白",
                    wrapThreshold: 340
                ) {
                    HStack(spacing: 4) {
                        ForEach([
                            ("off", "闭合"),
                            ("on", "缺口分离")
                        ], id: \.0) { mode, label in
                            let isSel = effectiveDraftConfig.notchMode == mode
                            Button {
                                mutateDraftLogoConfig { $0.notchMode = mode }
                            } label: {
                                Text(label)
                                    .font(.system(size: 11, weight: isSel ? .semibold : .regular))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4.5)
                                    .background(isSel ? Color.codexCard : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                                    .foregroundStyle(isSel ? Color.codexInk : Color.codexMuted)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                    .background(Color.codexMist, in: RoundedRectangle(cornerRadius: 6))
                    .opacity(effectiveDraftConfig.logoContent == "percent" ? 0.45 : 1.0)
                    .disabled(effectiveDraftConfig.logoContent == "percent")
                }

                CodexDivider()

                // 色彩填充
                SettingsInlineRow(
                    title: "色彩填充",
                    subtitle: "单色纯平稳重，或谐波渐变流动光影",
                    wrapThreshold: 340
                ) {
                    HStack(spacing: 4) {
                        ForEach([
                            ("solid", "纯色"),
                            ("gradient", "渐变")
                        ], id: \.0) { mode, label in
                            let isSel = effectiveDraftConfig.fillType == mode
                            Button {
                                mutateDraftLogoConfig { $0.fillType = mode }
                            } label: {
                                Text(label)
                                    .font(.system(size: 11, weight: isSel ? .semibold : .regular))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4.5)
                                    .background(isSel ? Color.codexCard : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                                    .foregroundStyle(isSel ? Color.codexInk : Color.codexMuted)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                    .background(Color.codexMist, in: RoundedRectangle(cornerRadius: 6))
                }

                if effectiveDraftConfig.fillType == "gradient" {
                    CodexDivider()

                    // 终止色算法
                    SettingsInlineRow(
                        title: "终止色算法",
                        subtitle: "同频活力微移、质感金属微明暗、深邃极具科技张力",
                        wrapThreshold: 340
                    ) {
                        HStack(spacing: 4) {
                            ForEach([
                                ("vibrant", "活力同频"),
                                ("subtle", "质感微光"),
                                ("deep", "深邃流体")
                            ], id: \.0) { algo, label in
                                let isSel = effectiveDraftConfig.gradientAlgo == algo
                                Button {
                                    mutateDraftLogoConfig {
                                        $0.gradientAlgo = algo
                                        $0.accentEndColor = TomoThemeConstants.computeAutoGradient(startHex: $0.accentColor, algo: algo)
                                    }
                                } label: {
                                    Text(label)
                                        .font(.system(size: 10.5, weight: isSel ? .semibold : .regular))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 4)
                                        .background(isSel ? Color.codexCard : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                                        .foregroundStyle(isSel ? Color.codexInk : Color.codexMuted)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(2)
                        .background(Color.codexMist, in: RoundedRectangle(cornerRadius: 6))
                    }

                    CodexDivider()

                    // 渐变方向与终止色
                    SettingsInlineRow(
                        title: "渐变方向与终止色",
                        subtitle: "自定义终点色或选择四向经典光影流向",
                        wrapThreshold: 340
                    ) {
                        HStack(spacing: 6) {
                            HStack(spacing: 3) {
                                ForEach([
                                    (135, "135°"),
                                    (180, "180°"),
                                    (90, "90°"),
                                    (45, "45°")
                                ], id: \.0) { angle, label in
                                    let isSel = effectiveDraftConfig.gradientAngle == angle
                                    Button {
                                        mutateDraftLogoConfig { $0.gradientAngle = angle }
                                    } label: {
                                        Text(label)
                                            .font(.system(size: 10, weight: isSel ? .semibold : .regular))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3.5)
                                            .background(isSel ? Color.codexCard : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                                            .foregroundStyle(isSel ? Color.codexInk : Color.codexMuted)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(2)
                            .background(Color.codexMist, in: RoundedRectangle(cornerRadius: 5))

                            TomoColorPickerButton(
                                colorHex: effectiveDraftConfig.accentEndColor ?? effectiveDraftConfig.accentColor,
                                tooltip: "手动自定义指定终止色"
                            ) { hex in
                                mutateDraftLogoConfig { $0.accentEndColor = hex }
                            }
                        }
                    }

                    CodexDivider()

                    // 渐变效果预览
                    SettingsInlineRow(
                        title: "渐变效果预览",
                        subtitle: "当前所选算法与角度生成的流动渐变条",
                        wrapThreshold: 340
                    ) {
                        LinearGradient(
                            colors: [
                                Color(hex: effectiveDraftConfig.accentColor),
                                Color(hex: effectiveDraftConfig.accentEndColor ?? effectiveDraftConfig.accentColor)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: 110, height: 14)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color.codexLine.opacity(0.4), lineWidth: 0.5)
                        )
                    }
                }
            }
            .settingsGroupSurface()

            // 5. 材质质感与光影
            VStack(spacing: 0) {
                // 材质质感
                SettingsInlineRow(
                    title: "材质质感",
                    subtitle: "经典扁平稳重，或 WWDC25 液态玻璃透射折射",
                    wrapThreshold: 340
                ) {
                    HStack(spacing: 4) {
                        ForEach([
                            ("flat", "扁平"),
                            ("glass", "液态玻璃")
                        ], id: \.0) { mode, label in
                            let isSel = effectiveDraftConfig.materialTexture == mode
                            Button {
                                mutateDraftLogoConfig { $0.materialTexture = mode }
                            } label: {
                                Text(label)
                                    .font(.system(size: 11, weight: isSel ? .semibold : .regular))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4.5)
                                    .background(isSel ? Color.codexCard : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                                    .foregroundStyle(isSel ? Color.codexInk : Color.codexMuted)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                    .background(Color.codexMist, in: RoundedRectangle(cornerRadius: 6))
                }

                if effectiveDraftConfig.materialTexture == "glass" {
                    CodexDivider()

                    // 玻璃透明度
                    SettingsInlineRow(
                        title: "玻璃透明度",
                        subtitle: "调节玻璃透射折射率，支持高透、黄金标准与浓郁厚玻",
                        wrapThreshold: 480
                    ) {
                        HStack(spacing: 10) {
                            HStack(spacing: 3) {
                                ForEach([
                                    (0.50, "50%"),
                                    (0.72, "72%"),
                                    (0.88, "88%")
                                ], id: \.0) { opVal, opLabel in
                                    let isSel = abs(effectiveDraftConfig.glassOpacity - opVal) < 0.02
                                    Button {
                                        mutateDraftLogoConfig { $0.glassOpacity = opVal }
                                    } label: {
                                        Text(opLabel)
                                            .font(.system(size: 10.5, weight: isSel ? .semibold : .regular))
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3.5)
                                            .background(isSel ? Color.codexCard : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                                            .foregroundStyle(isSel ? Color.codexInk : Color.codexMuted)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(2)
                            .background(Color.codexMist, in: RoundedRectangle(cornerRadius: 5))

                            Slider(
                                value: Binding(
                                    get: { effectiveDraftConfig.glassOpacity },
                                    set: { val in mutateDraftLogoConfig { $0.glassOpacity = val } }
                                ),
                                in: 0.20...0.95,
                                step: 0.01
                            )
                            .frame(minWidth: 100, maxWidth: 160)

                            let pct = Int(round(effectiveDraftConfig.glassOpacity * 100))
                            Text("\(pct)%")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.codexInk)
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                }
            }
            .settingsGroupSurface()

            // 6. 底板背景色
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("底板背景色")
                            .font(.system(size: 12, weight: .semibold))
                        Text("8 款质感底板与自定义色盘")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.codexMuted)
                    }
                    Spacer()
                    Text(currentTileBgLabel)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.codexInk)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Color.codexMist.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                }

                HStack(spacing: 8) {
                    ForEach(TomoThemeConstants.presetTileBgColors) { preset in
                        let isSelected = effectiveDraftConfig.tileBgColor.caseInsensitiveCompare(preset.hex) == .orderedSame
                        Button {
                            mutateDraftLogoConfig { $0.tileBgColor = preset.hex }
                        } label: {
                            Circle()
                                .fill(Color(hex: preset.hex))
                                .frame(width: 24, height: 24)
                                .overlay(
                                    Circle()
                                        .strokeBorder(isSelected ? Color.codexInk : Color.gray.opacity(0.35), lineWidth: isSelected ? 2 : 0.8)
                                )
                                .overlay(
                                    Group {
                                        if isSelected {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundStyle(preset.hex == "#FFFFFF" || preset.hex == "#F2F3F5" || preset.hex == "#F7F5F0" ? Color.black : Color.white)
                                        }
                                    }
                                )
                        }
                        .buttonStyle(.plain)
                        .help("\(preset.name) (\(preset.hex)): \(preset.note)")
                    }

                    // Custom Tile Bg Picker
                    TomoColorPickerButton(
                        colorHex: effectiveDraftConfig.tileBgColor,
                        tooltip: "自定义调色盘指定底板背景色"
                    ) { hex in
                        mutateDraftLogoConfig { $0.tileBgColor = hex }
                    }
                }
            }
            .padding(14)
            .settingsGroupSurface()


        }
    }

    // MARK: - Logo 草稿状态与生成调度方法
    private var effectiveDraftConfig: TomoThemeConfig {
        draftLogoConfig ?? settings.themeConfig
    }

    private var hasUnsavedLogoChanges: Bool {
        guard let draft = draftLogoConfig else { return false }
        return isLogoConfigModified(draft, settings.themeConfig)
    }

    private func isLogoConfigModified(_ lhs: TomoThemeConfig, _ rhs: TomoThemeConfig) -> Bool {
        lhs.logoFamily != rhs.logoFamily ||
        lhs.logoContent != rhs.logoContent ||
        lhs.notchMode != rhs.notchMode ||
        lhs.glyphMode != rhs.glyphMode ||
        lhs.fillType != rhs.fillType ||
        lhs.gradientAlgo != rhs.gradientAlgo ||
        lhs.gradientAngle != rhs.gradientAngle ||
        lhs.accentColor != rhs.accentColor ||
        lhs.accentEndColor != rhs.accentEndColor ||
        lhs.tileBgColor != rhs.tileBgColor ||
        lhs.renderMode != rhs.renderMode ||
        lhs.shadowEnabled != rhs.shadowEnabled ||
        lhs.shadowStyle != rhs.shadowStyle ||
        abs(lhs.logoScale - rhs.logoScale) > 0.001 ||
        lhs.shadowDirection != rhs.shadowDirection ||
        lhs.materialTexture != rhs.materialTexture ||
        abs(lhs.glassOpacity - rhs.glassOpacity) > 0.001
    }

    private func mutateDraftLogoConfig(_ transform: (inout TomoThemeConfig) -> Void) {
        var current = effectiveDraftConfig
        transform(&current)
        draftLogoConfig = current
    }

    private func saveDraftLogoConfig() {
        guard let draft = draftLogoConfig else { return }
        var finalConfig = draft
        finalConfig.updatedAt = Date().timeIntervalSince1970 * 1000
        settings.themeConfig = finalConfig
        draftLogoConfig = finalConfig
        showToast("应用图标已生成并更新", systemImage: "checkmark.circle.fill")
    }

    private func revertDraftLogoConfig() {
        draftLogoConfig = settings.themeConfig
        showToast("已放弃未保存修改", systemImage: "arrow.uturn.backward")
    }

    private var isDraftDefaultLogoConfig: Bool {
        let current = effectiveDraftConfig
        return current.logoFamily == "circle" &&
            current.logoContent == "t" &&
            current.notchMode == "on" &&
            current.glyphMode == "solid" &&
            current.fillType == "gradient" &&
            current.gradientAlgo == "vibrant" &&
            current.gradientAngle == 135 &&
            current.accentColor.caseInsensitiveCompare("#007AFF") == .orderedSame &&
            (current.accentEndColor?.caseInsensitiveCompare("#3529FF") == .orderedSame || current.accentEndColor == nil) &&
            current.tileBgColor.caseInsensitiveCompare("#FFFFFF") == .orderedSame &&
            current.renderMode == "color" &&
            current.shadowEnabled == true &&
            current.shadowStyle == "tight" &&
            current.shadowDirection == "down" &&
            abs(current.logoScale - 1.0) < 0.01 &&
            current.materialTexture == "glass" &&
            abs(current.glassOpacity - 0.88) < 0.01
    }

    private func resetLogoConfigToDefault() {
        draftLogoConfig = TomoThemeConfig.default
        showToast("已恢复默认图标参数，点击保存生效", systemImage: "arrow.counterclockwise")
    }

    private var isDarkModeActive: Bool {
        switch settings.theme {
        case .system:
            return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        case .light:
            return false
        case .dark:
            return true
        }
    }

    private var currentPreset: TomoChromePresetColor {
        let hex = settings.themeConfig.accentColor
        if let found = TomoThemeConstants.chromePresetColors.first(where: { !$0.isCustom && $0.seedHex.caseInsensitiveCompare(hex) == .orderedSame }) {
            return found
        }
        return TomoChromePresetColor(
            id: "custom",
            name: "自定义主题",
            seedHex: hex,
            lightFg: TomoThemeConstants.computeAutoGradient(startHex: hex, algo: "subtle"),
            lightBg: hex,
            lightBase: "#F4F5F7",
            darkFg: "#1E293B",
            darkBg: hex,
            darkBase: "#181D24",
            isCustom: true
        )
    }

    private var currentThemeName: String {
        let hex = settings.themeConfig.accentColor
        if let found = TomoThemeConstants.chromePresetColors.first(where: { !$0.isCustom && $0.seedHex.caseInsensitiveCompare(hex) == .orderedSame }) {
            return found.name
        }
        return "自定义主题 (\(hex.uppercased()))"
    }

    private func resetThemeToDefault() {
        var def = TomoThemeConfig.default
        def.updatedAt = Date().timeIntervalSince1970 * 1000
        settings.themeConfig = def
        draftLogoConfig = def
        settings.theme = .system
        showToast("已重置为默认外观与系统主题", systemImage: "arrow.counterclockwise")
    }

    private var currentTileBgLabel: String {
        let hex = effectiveDraftConfig.tileBgColor
        if let found = TomoThemeConstants.presetTileBgColors.first(where: { $0.hex.caseInsensitiveCompare(hex) == .orderedSame }) {
            return "\(found.name) \(hex.uppercased())"
        }
        return "自定义 \(hex.uppercased())"
    }

    private var launchAtLoginSection: some View {
        SettingsInlineRow(
            title: "开机自启",
            subtitle: "将 Tomo 添加到 macOS 系统登录项"
        ) {
            SettingsSwitch(
                isOn: Binding(
                    get: { settings.launchAtLoginEnabled },
                    set: { settings.setLaunchAtLoginEnabled($0) }
                ),
                accessibilityLabel: "开机自启"
            )
        }
    }

    private var silentLaunchSection: some View {
        SettingsInlineRow(
            title: "静默启动",
            subtitle: "启动时仅驻留菜单栏，不自动打开主窗口"
        ) {
            SettingsSwitch(
                isOn: $settings.silentLaunchEnabled,
                accessibilityLabel: "静默启动"
            )
        }
    }

    private var orientationSection: some View {
        SettingsInlineRow(
            title: "主界面布局",
            subtitle: "横向：宠物在左侧；竖向：宠物移到顶部，窗口收窄到 330pt"
        ) {
            SettingsMenuPicker(
                selection: $settings.dashboardOrientation,
                options: DashboardOrientation.allCases,
                title: \.title
            )
        }
    }

    private var refreshSection: some View {
        SettingsInlineRow(title: "自动刷新", subtitle: "登录后按设定间隔自动拉取额度") {
            SettingsMenuPicker(
                selection: $settings.autoRefreshInterval,
                options: AutoRefreshInterval.allCases,
                title: \.title
            )
        }
    }

    private var networkProxyPageSection: some View {
        SettingsSection(
            title: "代理配置",
            subtitle: "启用后，Tomo 的所有公网出站请求统一走此代理"
        ) {
            VStack(alignment: .leading, spacing: 0) {
                SettingsInlineRow(
                    title: "网络代理",
                    subtitle: "本地 Gateway、OAuth 回调与局域网地址始终直连"
                ) {
                    SettingsSwitch(
                        isOn: $settings.networkProxyEnabled,
                        accessibilityLabel: "网络代理"
                    )
                }

                if settings.networkProxyEnabled {
                    CodexDivider()
                    SettingsInlineRow(title: "代理协议", subtitle: "SOCKS5h 由代理端解析域名，适合 Gemini 等服务") {
                        SettingsMenuPicker(
                            selection: $settings.networkProxyProtocol,
                            options: AppNetworkProxyProtocol.allCases,
                            title: \.title
                        )
                    }
                    CodexDivider()
                    SettingsInlineRow(title: "代理地址", subtitle: "本机代理软件监听地址") {
                        Text("127.0.0.1")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.codexMuted)
                    }
                    CodexDivider()
                    SettingsInlineRow(title: "代理端口", subtitle: "Clash 默认使用 7897；请按代理软件实际端口修改") {
                        TextField("7897", value: Binding(
                            get: { settings.networkProxyPort },
                            set: { value in
                                if (1...65_535).contains(value) {
                                    settings.networkProxyPort = value
                                }
                            }
                        ), format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 88)
                        .help("Clash 默认端口为 7897")
                    }
                    CodexDivider()
                    SettingsInlineRow(
                        title: "连通性测试",
                        subtitle: "测试当前代理，并对每个供应商执行一次轻量认证与模型目录检查"
                    ) {
                        Button {
                            testNetworkProxyConnectivity()
                        } label: {
                            HStack(spacing: 5) {
                                if isNetworkProxyTesting || isProviderQuickTesting {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "stethoscope")
                                }
                                Text(isNetworkProxyTesting || isProviderQuickTesting ? "测试中" : "测试连接")
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .foregroundStyle(Color.codexOnPrimary)
                            .background(Color.codexPrimary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(CodexPressableStyle(cornerRadius: 7))
                        .disabled(isNetworkProxyTesting || isProviderQuickTesting)
                    }
                }
            }
            .settingsGroupSurface()
            .frame(maxWidth: .infinity, alignment: .leading)

            if let proxyTestMessage {
                networkProxyTestResult(message: proxyTestMessage)
            }
            if isProviderQuickTesting || !providerQuickResults.isEmpty {
                networkProviderCheckResult
            }
        }
    }

    private func testNetworkProxyConnectivity() {
        guard !isNetworkProxyTesting, !isProviderQuickTesting else { return }
        isNetworkProxyTesting = true
        proxyTestMessage = nil
        providerQuickResults = []
        let proxy = AppNetworkProxyConfiguration.load()
        Task {
            let result = await AppNetworkProxyConnectivityTester.test(using: proxy)
            await MainActor.run {
                proxyTestMessage = result
                isNetworkProxyTesting = false
            }
            guard result.hasPrefix("代理连通正常") else { return }
            await MainActor.run { isProviderQuickTesting = true }
            let checks = await multiAgentSettings.quickCheckEnabledProviders()
            await MainActor.run {
                providerQuickResults = checks
                isProviderQuickTesting = false
            }
        }
    }

    private func networkProxyTestResult(message: String) -> some View {
        let success = message.hasPrefix("代理连通正常")
        return Label(message, systemImage: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(success ? Color.codexGreen : Color.codexAmber)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((success ? Color.codexGreen : Color.codexAmber).opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var networkProviderCheckResult: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isProviderQuickTesting {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("正在逐个检查供应商的认证与模型目录…")
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.codexMuted)
            }

            ForEach(providerQuickResults) { result in
                    HStack(spacing: 7) {
                        Image(systemName: result.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(result.isAvailable ? Color.codexGreen : Color.codexAmber)
                        Text("\(result.provider) · \(result.accountLabel)")
                        Spacer(minLength: 8)
                        Text(result.detail)
                            .lineLimit(1)
                            .foregroundStyle(Color.codexMuted)
                    }
                    .font(.system(size: 10.5, weight: .medium))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.codexMist.opacity(0.65), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var mainWindowProviderCarouselSection: some View {
        SettingsInlineRow(
            title: "主窗口供应商轮播",
            subtitle: "仅作用于主窗口；开启后主界面按设定间隔自动切换供应商账号"
        ) {
            SettingsSwitch(
                isOn: $settings.mainWindowProviderCarouselEnabled,
                accessibilityLabel: "主窗口供应商轮播"
            )
        }
    }

    private var notchProviderCarouselSection: some View {
        SettingsInlineRow(
            title: "刘海供应商轮播",
            subtitle: "仅作用于刘海面板；开启后状态栏与刘海面板按设定间隔自动切换供应商账号"
        ) {
            SettingsSwitch(
                isOn: $settings.notchProviderCarouselEnabled,
                accessibilityLabel: "刘海供应商轮播"
            )
        }
    }

    private var accountCarouselSection: some View {
        SettingsInlineRow(
            title: "轮播时间间隔",
            subtitle: "主窗口与刘海面板共享的轮播频率；鼠标移入账号信息区域时自动暂停"
        ) {
            SettingsMenuPicker(
                selection: $settings.accountCarouselInterval,
                options: AccountCarouselInterval.allCases,
                title: \.title
            )
        }
    }

    private var petSection: some View {
        VStack(alignment: .leading, spacing: SettingsLayoutMetrics.sectionSpacing) {
            SettingsSection(
                title: "状态显示"
            ) {
                VStack(spacing: 0) {
                SettingsInlineRow(
                    title: "胶囊背景透明度",
                    subtitle: "调整状态栏胶囊白色背景的透明度"
                ) {
                    SettingsPercentageSlider(value: $settings.statusBarOpacityPercent)
                }
                CodexDivider()

                SettingsInlineRow(
                    title: "状态圆灯颜色",
                    subtitle: "选择跟随任务状态、额度状态或固定单色"
                ) {
                    SettingsMenuPicker(
                        selection: $settings.statusBarIndicatorColorMode,
                        options: StatusCapsuleColorMode.allCases,
                        title: \.title,
                        swatchColor: \.swatchColor
                    )
                }
                CodexDivider()

                SettingsInlineRow(
                    title: "活动流光",
                    subtitle: "任务活动时，在状态栏和 Pet 胶囊显示顺时针边缘流光"
                ) {
                    SettingsSwitch(
                        isOn: $settings.statusBarWaveEnabled,
                        accessibilityLabel: "活动流光"
                    )
                }
                CodexDivider()

                SettingsInlineRow(
                    title: "活动流光颜色",
                    subtitle: "选择跟随任务状态或固定单色"
                ) {
                    SettingsMenuPicker(
                        selection: $settings.statusBarWaveColorMode,
                        options: StatusCapsuleColorMode.activityFlowCases,
                        title: \.title,
                        swatchColor: \.swatchColor
                    )
                }
                CodexDivider()

                SettingsInlineRow(
                    title: "刘海面板显示位置",
                    subtitle: "选择显示刘海面板的显示器，其余显示器显示降级胶囊"
                ) {
                    SettingsMenuPicker(
                        selection: $settings.notchDisplayTarget,
                        options: notchDisplayOptions(currentSelection: settings.notchDisplayTarget),
                        title: { notchDisplayTitle($0, settings: settings) }
                    )
                }
                CodexDivider()

                SettingsInlineRow(
                    title: "外接屏刘海拖拽",
                    subtitle: "允许在非内建显示器上按住鼠标左键横向拖动刘海位置"
                ) {
                    SettingsSwitch(
                        isOn: $settings.notchDraggingEnabled,
                        accessibilityLabel: "外接屏刘海拖拽"
                    )
                }

                if !settings.notchDisplayOffsets.isEmpty {
                    CodexDivider()

                    SettingsInlineRow(
                        title: "重置刘海位置",
                        subtitle: "一键将所有外接显示器刘海恢复至屏幕顶部中心位置"
                    ) {
                        Button {
                            settings.resetAllNotchOffsets()
                        } label: {
                            Text("恢复居中")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                }
                .settingsGroupSurface()
            }

            SettingsSection(
                title: "独立 Pet"
            ) {
                VStack(spacing: 0) {
                SettingsInlineRow(
                    title: "独立 Pet 悬浮窗",
                    subtitle: "在屏幕边缘显示独立的 Pet 悬浮窗口，作为任务状态门户"
                ) {
                    SettingsSwitch(
                        isOn: $settings.standalonePetEnabled,
                        accessibilityLabel: "独立 Pet 悬浮窗"
                    )
                }
                CodexDivider()

                SettingsInlineRow(
                    title: "独立 Pet 尺寸",
                    subtitle: "只调整 Pet 本体大小，任务窗口内容尺寸不变"
                ) {
                    HStack(spacing: 9) {
                        Slider(
                            value: $settings.standalonePetScale,
                            in: StandalonePetLayout.scaleRange,
                            step: 0.05
                        )
                        .frame(width: 108)
                        .tint(Color.accentColor)
                        .accessibilityLabel("独立 Pet 尺寸")

                        Text("\(Int((settings.standalonePetScale * 100).rounded()))%")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.codexInk.opacity(0.82))
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                }
                .settingsGroupSurface()
            }

            SettingsSection(
                title: "Pet 选择"
            ) {
                VStack(spacing: 8) {
                if let pet = settings.selectedPet {
                    HStack(spacing: 12) {
                        PetSettingsThumbnail(pet: pet)
                            .frame(width: 58, height: 58)
                            .background(
                                Color.codexMuted.opacity(0.055),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )

                        VStack(alignment: .leading, spacing: 3) {
                            Text(pet.displayName)
                                .font(.system(size: 14, weight: .semibold))
                            Text("\(pet.source.title) · v\(pet.spriteVersionNumber) · \(pet.rowCount) 行动画")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.codexMuted)
                        }

                        Spacer(minLength: 8)
                        petPicker
                    }
                    .padding(16)
                    .settingsGroupSurface()
                } else {
                    Text("没有发现可用 Pet。请安装 Codex，或把自定义 Pet 放入 ~/.codex/pets。")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.codexAmber)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .settingsGroupSurface()
                }

                if settings.codexPetRestartRequired {
                    codexPetRestartNotice
                }

                HStack(spacing: 10) {
                    let builtInCount = settings.availablePets.filter { $0.source == .codexBuiltIn }.count
                    let customCount = settings.availablePets.filter { $0.source == .custom }.count
                    Text("已发现 \(builtInCount) 个内置 Pet，\(customCount) 个自定义 Pet")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.codexMuted)
                    Spacer()
                    Button(action: openCustomPetsFolderInFinder) {
                        SettingsSecondaryActionLabel(
                            title: "打开文件夹",
                            systemImage: "folder"
                        )
                    }
                    .buttonStyle(CodexPressableStyle(cornerRadius: 7))
                    .help("在 Finder 中打开 Tomo Pets 文件夹，支持与 Codex 双向同步")
                    Button {
                        settings.reloadPets()
                        let builtIn = settings.availablePets.filter { $0.source == .codexBuiltIn }.count
                        let custom = settings.availablePets.filter { $0.source == .custom }.count
                        showToast("已扫描：\(builtIn) 个内置，\(custom) 个自定义 Pet")
                    } label: {
                        SettingsSecondaryActionLabel(
                            title: "重新扫描",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(CodexPressableStyle(cornerRadius: 7))
                }
                .padding(.horizontal, 4)
                }
            }
        }
    }

    private var thirdPartyPetResourcesSection: some View {
        SettingsSection(
            title: "Pet 资源",
            subtitle: "下载后放入 Pets 文件夹，再返回上方重新扫描，若已安装 Codex 将自动双向同步。"
        ) {
            VStack(spacing: 0) {
                SettingsExternalLinkRow(
                    icon: .symbol("safari"),
                    title: "codex-pets.net",
                    subtitle: "Pet 资源站",
                    url: URL(string: "https://codex-pets.net/")!
                )
                CodexDivider()
                SettingsExternalLinkRow(
                    icon: .symbol("safari"),
                    title: "Petdex",
                    subtitle: "Coding Agent Pet 图鉴",
                    url: URL(string: "https://petdex.dev/")!
                )
                CodexDivider()
                SettingsExternalLinkRow(
                    icon: .githubMark,
                    title: "Awesome Codex Pet",
                    subtitle: "GitHub 精选合集",
                    url: URL(string: "https://github.com/legeling/awesome-codex-pet")!
                )
            }
            .settingsGroupSurface()
        }
    }

    private var petPicker: some View {
        let builtIns = settings.availablePets.filter { $0.source == .codexBuiltIn }
        let custom = settings.availablePets.filter { $0.source == .custom }

        return Button {
            showsPetPicker.toggle()
        } label: {
            SettingsMenuTriggerLabel(title: "选择", fontSize: 12)
        }
        .buttonStyle(CodexPressableStyle(cornerRadius: 7))
        .popover(isPresented: $showsPetPicker, arrowEdge: .bottom) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if !builtIns.isEmpty {
                        SettingsPopoverSection(title: "官方内置") {
                            LazyVGrid(columns: petPickerColumns, spacing: 6) {
                                ForEach(builtIns) { pet in
                                    petPopoverGridItem(pet)
                                }
                            }
                        }
                    }
                    if !custom.isEmpty {
                        SettingsPopoverSection(title: "自定义") {
                            LazyVGrid(columns: petPickerColumns, spacing: 6) {
                                ForEach(custom) { pet in
                                    petPopoverGridItem(pet)
                                }
                            }
                        }
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.hidden)
            .background(ScrollIndicatorHider())
            .frame(width: 330)
            .frame(maxHeight: 520)
        }
        .fixedSize()
    }

    private var petPickerColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 84), spacing: 6),
            count: 3
        )
    }

    private func petPopoverGridItem(_ pet: CodexPet) -> some View {
        let isSelected = settings.selectedPetID == pet.id

        return Button {
            guard !isSelected else {
                showsPetPicker = false
                return
            }
            settings.selectedPetID = pet.id
            showsPetPicker = false
            if let error = settings.codexPetSyncError {
                showToast("Codex Pet 同步失败：\(error)", systemImage: "exclamationmark.triangle.fill")
            } else {
                showToast("已写入 Codex，重启后切换为 \(pet.displayName)", systemImage: "arrow.clockwise.circle.fill")
            }
        } label: {
            VStack(spacing: 5) {
                ZStack(alignment: .topTrailing) {
                    PetSettingsThumbnail(pet: pet)
                        .frame(width: 58, height: 58)

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.codexPrimary)
                            .background(Color.codexBackground, in: Circle())
                    }
                }
                .frame(maxWidth: .infinity)

                Text(pet.displayName)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
            }
            .padding(6)
            .background(
                isSelected
                    ? Color.codexPrimary.opacity(0.10)
                    : Color.codexMuted.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isSelected
                            ? Color.codexPrimary.opacity(0.50)
                            : Color.codexMuted.opacity(0.10),
                        lineWidth: isSelected ? 1.2 : 0.7
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isSelected
                ? "\(pet.displayName)，当前已选择"
                : pet.displayName
        )
    }

    private var codexPetRestartNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.codexAmber)

            VStack(alignment: .leading, spacing: 2) {
                Text("Codex 重启后生效")
                    .font(.system(size: 12, weight: .semibold))
                Text("当前运行中的 Pet 不会自动刷新。")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.codexMuted)
            }

            Spacer(minLength: 8)

            Button {
                showsCodexRestartConfirmation = true
            } label: {
                if isRestartingCodex {
                    ProgressView()
                        .controlSize(.small)
                        .frame(minWidth: 64)
                } else {
                    Text("重启 Codex")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                }
            }
            .buttonStyle(CodexPressableStyle(cornerRadius: 7))
            .disabled(isRestartingCodex)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.codexAmber.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.codexAmber.opacity(0.24), lineWidth: 0.8)
        }
    }

    private func restartCodex() {
        guard !isRestartingCodex else { return }
        isRestartingCodex = true
        Task { @MainActor in
            do {
                try await CodexApplicationController().restart()
                settings.markCodexPetRestartCompleted()
                showToast("Codex 已重新打开，Pet 已生效", systemImage: "pawprint.fill")
            } catch {
                showToast("无法重启 Codex：\(error.localizedDescription)", systemImage: "exclamationmark.triangle.fill")
            }
            isRestartingCodex = false
        }
    }

    private func openCustomPetsFolderInFinder() {
        let directory = CodexPetCatalog.defaultCustomPetsRoot
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
            showToast("已在 Finder 中打开 Pet 文件夹", systemImage: "folder.fill")
        } catch {
            showToast("无法打开 Pet 文件夹：\(error.localizedDescription)", systemImage: "exclamationmark.triangle.fill")
        }
    }

    private func showToast(_ message: String, systemImage: String = "checkmark.circle.fill") {
        toastDismissGeneration += 1
        let generation = toastDismissGeneration
        withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
            toast = SettingsToast(message: message, systemImage: systemImage)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            guard generation == toastDismissGeneration else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                toast = nil
            }
        }
    }
}

private struct SettingsToast: Equatable {
    let message: String
    let systemImage: String
}

private enum PendingAccountRemoval: Identifiable {
    case codex(CodexAccountConnection)
    case deepSeek(DeepSeekAPIConnection)
    case openCode(OpenCodeAPIConnection)
    case gemini(GeminiAPIConnection)

    var id: ConnectionID {
        switch self {
        case let .codex(connection): connection.id
        case let .deepSeek(connection): connection.id
        case let .openCode(connection): connection.id
        case let .gemini(connection): connection.id
        }
    }

    var title: String {
        switch self {
        case .codex: "删除 Codex 账号？"
        case .deepSeek: "删除 DeepSeek API Key？"
        case let .openCode(connection): "删除 \(connection.plan.displayName) API Key？"
        case .gemini: "删除 Google Gemini 账号？"
        }
    }

    var message: String {
        switch self {
        case let .codex(connection):
            "将删除 \(connection.label) 的本地独立运行目录和连接记录，不会删除供应商侧账号。"
        case let .deepSeek(connection):
            "将从本机 Keychain 删除 \(connection.label) 的 API Key 和连接记录，此操作无法撤销。"
        case let .openCode(connection):
            "将从本机删除 \(connection.label) 的 API Key 和连接记录，此操作无法撤销。"
        case let .gemini(connection):
            "将从本机删除 \(connection.label) 的 Google OAuth 授权和连接记录，不会删除 Google 账号。"
        }
    }
}

/// In-flight reveal request; holds the id while system auth is being evaluated.
private struct PendingAPIKeyReveal {
    let connectionID: ConnectionID
}

/// A successfully revealed API key, shown only after system auth completes.
struct RevealedAPIKey: Equatable {
    let connectionID: ConnectionID
    let value: String
}

final class InvisibleScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override class var isCompatibleWithResponsiveScrolling: Bool { true }
    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { 0 }

    override func draw(_ dirtyRect: NSRect) {}
    override func drawKnob() {}
    override func drawKnobSlot(in rect: NSRect, highlight: Bool) {}
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var isHidden: Bool {
        get { true }
        set { super.isHidden = true }
    }

    override var alphaValue: CGFloat {
        get { 0 }
        set { super.alphaValue = 0 }
    }

    override var frame: NSRect {
        get { .zero }
        set { super.frame = .zero }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.isHidden = true
        self.alphaValue = 0
    }

    override func layout() {
        super.layout()
        self.frame = .zero
        self.isHidden = true
        self.alphaValue = 0
    }
}

struct ScrollIndicatorHider: NSViewRepresentable {
    var id: AnyHashable? = nil

    func makeNSView(context: Context) -> NSView {
        ScrollIndicatorHiderView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ScrollIndicatorHiderView)?.scheduleUpdate()
    }
}

private final class ScrollIndicatorHiderView: NSView {
    private weak var observedScrollView: NSScrollView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        scheduleUpdate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleUpdate()
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(onWindowResized),
                name: NSWindow.didResizeNotification,
                object: window
            )
        }
    }

    override func layout() {
        super.layout()
        hideIndicators()
    }

    func scheduleUpdate() {
        hideIndicators()
        for delay in [0.0, 0.02, 0.05, 0.12, 0.25, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.hideIndicators()
            }
        }
    }

    private func hideIndicators() {
        let targetScrollView = self.enclosingScrollView ?? findTargetScrollView()
        guard let scrollView = targetScrollView else { return }

        if observedScrollView !== scrollView {
            detachFromObservedScrollView()
            observedScrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollView.postsFrameChangedNotifications = true
            scrollView.contentView.postsFrameChangedNotifications = true

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(onBoundsOrLiveScrollChanged),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(onBoundsOrLiveScrollChanged),
                name: NSScrollView.didLiveScrollNotification,
                object: scrollView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(onBoundsOrLiveScrollChanged),
                name: NSScrollView.willStartLiveScrollNotification,
                object: scrollView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(onBoundsOrLiveScrollChanged),
                name: NSScrollView.didEndLiveScrollNotification,
                object: scrollView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(onBoundsOrLiveScrollChanged),
                name: NSView.frameDidChangeNotification,
                object: scrollView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(onBoundsOrLiveScrollChanged),
                name: NSView.frameDidChangeNotification,
                object: scrollView.contentView
            )
        }

        applyHiding(to: scrollView)
    }

    private func applyHiding(to scrollView: NSScrollView) {
        scrollView.scrollerStyle = .overlay
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerInsets = NSEdgeInsetsZero
        scrollView.automaticallyAdjustsContentInsets = false

        if !(scrollView.verticalScroller is InvisibleScroller) {
            scrollView.verticalScroller = InvisibleScroller()
        }
        scrollView.verticalScroller?.isHidden = true
        scrollView.verticalScroller?.alphaValue = 0
        scrollView.verticalScroller?.frame = .zero

        if !(scrollView.horizontalScroller is InvisibleScroller) {
            scrollView.horizontalScroller = InvisibleScroller()
        }
        scrollView.horizontalScroller?.isHidden = true
        scrollView.horizontalScroller?.alphaValue = 0
        scrollView.horizontalScroller?.frame = .zero

        scrollView.tile()
    }

    @objc private func onBoundsOrLiveScrollChanged() {
        if let scrollView = observedScrollView {
            applyHiding(to: scrollView)
        }
    }

    @objc private func onWindowResized() {
        if let scrollView = observedScrollView {
            applyHiding(to: scrollView)
        } else {
            hideIndicators()
        }
    }

    private func detachFromObservedScrollView() {
        if let scrollView = observedScrollView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSScrollView.didLiveScrollNotification,
                object: scrollView
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.frameDidChangeNotification,
                object: scrollView
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.frameDidChangeNotification,
                object: scrollView.contentView
            )
        }
        observedScrollView = nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func findTargetScrollView() -> NSScrollView? {
        if let enclosing = self.enclosingScrollView {
            return enclosing
        }
        var current: NSView? = self.superview
        while let view = current {
            if let scroll = view as? NSScrollView {
                return scroll
            }
            current = view.superview
        }
        guard let rootView = window?.contentView else { return nil }
        var candidates: [NSScrollView] = []
        collectScrollViews(in: rootView, into: &candidates)
        if candidates.count == 1 {
            return candidates.first
        }
        let markerRect = convert(bounds, to: nil)
        if markerRect.width > 0 && markerRect.height > 0 {
            if let matched = candidates.first(where: { $0.convert($0.bounds, to: nil).intersects(markerRect) }) {
                return matched
            }
        }
        return candidates.min(by: { scrollViewArea($0) < scrollViewArea($1) })
    }

    private func collectScrollViews(in view: NSView, into result: inout [NSScrollView]) {
        if let scrollView = view as? NSScrollView {
            result.append(scrollView)
        }
        for subview in view.subviews {
            collectScrollViews(in: subview, into: &result)
        }
    }

    private func scrollViewArea(_ scrollView: NSScrollView) -> CGFloat {
        let rect = scrollView.convert(scrollView.bounds, to: nil)
        return rect.width * rect.height
    }
}

private struct PetSettingsThumbnail: View {
    let pet: CodexPet
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .padding(4)
            } else {
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.codexMuted)
            }
        }
        .task(id: pet.id) {
            guard let frame = await PetThumbnailLoader.shared.frame(
                for: pet.spritesheetURL
            ) else {
                image = nil
                return
            }
            image = NSImage(
                cgImage: frame,
                size: NSSize(
                    width: PetSpriteSheet.cellWidth,
                    height: PetSpriteSheet.cellHeight
                )
            )
        }
        .accessibilityLabel(pet.displayName)
    }
}

private actor PetThumbnailLoader {
    static let shared = PetThumbnailLoader()

    private var frames: [URL: CGImage] = [:]
    private var failedURLs = Set<URL>()

    func preload(_ urls: [URL]) {
        for url in urls {
            _ = frame(for: url)
        }
    }

    func frame(for url: URL) -> CGImage? {
        if let cached = frames[url] {
            return cached
        }
        guard !failedURLs.contains(url),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let spritesheet = CGImageSourceCreateImageAtIndex(source, 0, nil),
              spritesheet.width == PetSpriteSheet.cellWidth * 8,
              spritesheet.height >= PetSpriteSheet.cellHeight,
              let frame = spritesheet.cropping(
                  to: CGRect(
                      x: 0,
                      y: 0,
                      width: PetSpriteSheet.cellWidth,
                      height: PetSpriteSheet.cellHeight
                  )
              ) else {
            failedURLs.insert(url)
            return nil
        }
        frames[url] = frame
        return frame
    }
}

private struct SettingsPrimaryActionButtonStyle: PrimitiveButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let isDark = colorScheme == .dark
        let backgroundColor: Color = if isDark {
            Color.white.opacity(0.11)
        } else {
            Color.codexPrimary
        }
        let foregroundColor: Color = if isDark {
            Color.white.opacity(isEnabled ? 0.96 : 0.42)
        } else {
            Color.white.opacity(isEnabled ? 1 : 0.58)
        }

        CodexMaterialWaveButtonBody(
            action: { configuration.trigger() },
            cornerRadius: 8,
            ink: .softLight
        ) {
            configuration.label
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(foregroundColor)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(backgroundColor.opacity(isEnabled ? 1 : 0.60))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            isDark ? Color.white.opacity(isEnabled ? 0.16 : 0.08) : Color.black.opacity(0.08),
                            lineWidth: 0.8
                        )
                )
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.codexMuted)
                        .lineSpacing(1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsInlineRowContentWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct SettingsInlineRow<Content: View>: View {
    let title: String
    let subtitle: String
    var wrapThreshold: CGFloat? = nil
    @ViewBuilder let content: Content

    @State private var rowWidth: CGFloat = 0
    @State private var measuredContentWidth: CGFloat = 0

    private var shouldWrap: Bool {
        if let wrapThreshold {
            return rowWidth > 0 && rowWidth < wrapThreshold
        }
        // 自动判定：当内容控件测出宽度，且行宽扣除内容后留给标题描述不足以舒适排布（小于 180pt）时，自动换行
        if measuredContentWidth > 0 && rowWidth > 0 {
            return rowWidth < (measuredContentWidth + 180)
        }
        return false
    }

    var body: some View {
        Group {
            if shouldWrap {
                VStack(alignment: .leading, spacing: 9) {
                    headerContent
                    wrappedContent
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    headerContent
                    wrappedContent
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 58)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        rowWidth = proxy.size.width
                    }
                    .onChange(of: proxy.size.width) { _, newWidth in
                        rowWidth = newWidth
                    }
            }
        }
        .onPreferenceChange(SettingsInlineRowContentWidthKey.self) { newWidth in
            if newWidth > 0 && abs(newWidth - measuredContentWidth) > 1 {
                measuredContentWidth = newWidth
            }
        }
        .animation(.easeInOut(duration: 0.16), value: shouldWrap)
    }

    private var wrappedContent: some View {
        content
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: SettingsInlineRowContentWidthKey.self, value: proxy.size.width)
                }
            }
    }

    private var headerContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
            Text(subtitle)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.codexMuted)
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsMenuTriggerLabel: View {
    let title: String
    var fontSize: CGFloat = 13
    var swatchColor: Color? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let swatchColor {
                Circle()
                    .fill(swatchColor)
                    .frame(width: 8, height: 8)
                    .overlay {
                        Circle().stroke(Color.white.opacity(0.72), lineWidth: 0.7)
                    }
            }
            Text(title)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(Color.codexMuted.opacity(0.9))
                .imageScale(.small)
        }
        .font(.system(size: fontSize, weight: .medium))
        .foregroundStyle(Color.codexInk.opacity(0.90))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Color.codexMuted.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.codexLine.opacity(0.66), lineWidth: 0.7)
        }
    }
}

private struct SettingsSecondaryActionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Color.codexInk.opacity(0.84))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                Color.codexCard.opacity(0.72),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.codexLine.opacity(0.72), lineWidth: 0.7)
            }
    }
}

private struct SettingsPopoverSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.codexMuted)
                .padding(.horizontal, 8)
                .padding(.top, 2)
            content
        }
    }
}

private struct SettingsMenuPicker<Option: Hashable & Identifiable>: View {
    @Binding var selection: Option
    let options: [Option]
    let title: (Option) -> String
    var swatchColor: (Option) -> Color? = { _ in nil }
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            SettingsMenuTriggerLabel(
                title: title(selection),
                swatchColor: swatchColor(selection)
            )
        }
        .buttonStyle(CodexPressableStyle(cornerRadius: 7))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(options) { option in
                    Button {
                        selection = option
                        isPresented = false
                    } label: {
                        HStack(spacing: 8) {
                            if let color = swatchColor(option) {
                                Circle()
                                    .fill(color)
                                    .frame(width: 9, height: 9)
                                    .overlay {
                                        Circle().stroke(Color.white.opacity(0.72), lineWidth: 0.7)
                                    }
                            }
                            Text(title(option))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if selection == option {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                        }
                        .font(.system(size: 13))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .frame(minWidth: 140)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct SettingsPercentageSlider: View {
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 9) {
            Slider(value: $value, in: 0...50, step: 1)
                .frame(width: 108)
                .tint(Color.accentColor)
                .accessibilityLabel("胶囊透明度")

            Text("\(Int(value.rounded()))%")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.codexInk.opacity(0.82))
                .frame(width: 34, alignment: .trailing)
        }
    }
}

private struct SettingsSwitch: View {
    @Binding var isOn: Bool
    let accessibilityLabel: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) {
                isOn.toggle()
            }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Color.accentColor : inactiveTrack)
                Circle()
                    .fill(Color.white)
                    .frame(width: 16, height: 16)
                    .padding(3)
                    .shadow(color: Color.black.opacity(0.16), radius: 1.5, y: 1)
            }
            .frame(width: 38, height: 22)
            .contentShape(Capsule())
        }
        .buttonStyle(SettingsSwitchButtonStyle())
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isOn ? "已开启" : "已关闭")
        .accessibilityAddTraits(.isButton)
    }

    private var inactiveTrack: Color {
        colorScheme == .dark
            ? Color(red: 0.30, green: 0.31, blue: 0.32)
            : Color(red: 0.78, green: 0.79, blue: 0.80)
    }
}

private struct SettingsSwitchButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CodexMaterialWaveButtonBody(
            action: { configuration.trigger() },
            cornerRadius: 12,
            usesCapsule: true,
            ink: .adaptiveMint
        ) {
            configuration.label
        }
    }
}

private enum SettingsLinkIcon {
    case symbol(String)
    case githubMark
}

private struct SettingsLinkIconView: View {
    let icon: SettingsLinkIcon
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            switch icon {
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: 13, weight: .semibold))
            case .githubMark:
                GitHubMarkIcon()
            }
        }
        .foregroundStyle(iconForeground)
        .frame(width: 32, height: 32)
        .background(iconBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(iconBorder, lineWidth: 0.7)
        }
    }

    private var iconForeground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.82)
            : Color.codexPrimary.opacity(0.90)
    }

    private var iconBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.07)
            : Color.codexPrimary.opacity(0.06)
    }

    private var iconBorder: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.codexLine.opacity(0.58)
    }
}

private struct GitHubMarkIcon: View {
    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: "github-mark", withExtension: "svg"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 17, height: 17)
            } else {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 13, weight: .semibold))
            }
        }
    }
}

private struct SettingsExternalLinkRow: View {
    let icon: SettingsLinkIcon
    let title: String
    let subtitle: String
    let url: URL
    @Environment(\.openURL) private var openURL

    init(
        icon: SettingsLinkIcon,
        title: String,
        subtitle: String,
        url: URL
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.url = url
    }

    var body: some View {
        Button {
            openURL(url)
        } label: {
            HStack(spacing: 12) {
                SettingsLinkIconView(icon: icon)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.codexInk)
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.codexMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.codexMuted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(CodexPressableStyle(cornerRadius: 12))
        .accessibilityLabel("\(title)，\(subtitle)")
        .accessibilityHint("在浏览器中打开")
    }
}

private enum SettingsMeasuredContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private enum SettingsScrollCoordinateSpace {
    static let name = "settings-content-scroll"
}

private enum SettingsHeaderMinYKey: PreferenceKey {
    static let defaultValue = CGFloat.greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

extension View {
    func settingsGroupSurface() -> some View {
        modifier(SettingsGroupSurfaceModifier())
    }
}

struct SettingsGroupSurfaceModifier: ViewModifier {
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        content
            .background(Color.codexCard.opacity(0.72), in: shape)
            .overlay {
                shape.stroke(
                    CodexDivider.color,
                    lineWidth: CodexDivider.renderedThickness(displayScale: displayScale)
                )
            }
    }
}

// MARK: - 刘海显示器选项（系统 API 动态获取）

@MainActor
private func notchDisplayOptions(currentSelection: NotchDisplayTarget) -> [NotchDisplayTarget] {
    var options: [NotchDisplayTarget] = []
    var seenIDs = Set<String>()
    for screen in NSScreen.screens {
        let id = screen.persistentID
        seenIDs.insert(id)
        options.append(.specificDisplay(id))
    }
    // 若当前持久化的首选显示器暂时离线，将其保留在选项中，避免选中态丢失
    if case .specificDisplay(let targetID) = currentSelection, !seenIDs.contains(targetID) {
        options.append(.specificDisplay(targetID))
    }
    // 特殊选项放到最后。
    options.append(.allDisplays)
    options.append(.off)
    return options
}

@MainActor
private func notchDisplayTitle(_ target: NotchDisplayTarget, settings: AppSettingsStore) -> String {
    switch target {
    case .off:
        return "所有显示器都不开刘海"
    case .allDisplays:
        return "所有显示器"
    case .specificDisplay(let id):
        if let screen = NSScreen.screens.first(where: { $0.persistentID == id || String($0.screenNumber) == id }) {
            return screen.displayName
        }
        let savedName = settings.displayName(for: id) ?? "外接显示器"
        return "\(savedName) (未连接 · 自动漫游)"
    }
}

// MARK: - API Key 明文展示

struct APIKeyRevealModal: View {
    let key: RevealedAPIKey
    var onCopy: () -> Void
    var onClose: () -> Void
    @State private var isCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("API Key")
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.codexMuted)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Text("通过系统认证后展示，请勿泄露给他人。")
                .font(.system(size: 10))
                .foregroundStyle(Color.codexMuted)

            Text(key.value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.codexInk)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .background(Color.codexCard, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.codexLine)
                }

            Button {
                onCopy()
                isCopied = true
            } label: {
                Label(isCopied ? "已复制" : "复制到剪贴板", systemImage: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
            }
            .buttonStyle(CodexPressableStyle(cornerRadius: 8, ink: .softLight))
            .foregroundStyle(Color.codexOnPrimary)
            .background(Color.codexPrimary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(20)
        .background(Color.codexCard, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(Color.codexLine)
        }
    }
}

// MARK: - Agent 官方安装指引弹窗

struct AgentInstallGuideModal: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    let integration: AgentIntegrationStatus
    var accentColor: Color = .themeAccent
    var onCopyCommand: (String) -> Void
    var onRecheck: () -> Void
    var onClose: () -> Void

    @State private var copiedMethodID: String?
    @State private var copyResetTask: Task<Void, Never>?

    private var guide: AgentInstallGuide {
        integration.guide
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerView
                .padding(.horizontal, 18)
                .padding(.top, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    integrationBanner

                    methodsSection

                    disclaimerNotice
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 4)
            }
            .scrollIndicators(.hidden)
            .background(ScrollIndicatorHider())
            .frame(maxHeight: 460)

            footerActions
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: 420)
        .background(modalSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(modalBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.52 : 0.24), radius: 28, y: 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(guide.name) 官方安装指引")
    }

    private var headerView: some View {
        HStack(alignment: .center, spacing: 12) {
            BrandIconView(asset: .agent(integration.id), size: 38, cornerRadius: 10)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(guide.name)
                        .font(.system(size: 16, weight: .bold))

                    if integration.isInstalled {
                        Text("已接入")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(accentColor.opacity(0.12), in: Capsule())
                    } else {
                        Text("未安装")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.codexAmber)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.codexAmber.opacity(0.12), in: Capsule())
                    }
                }

                Text(guide.tagline)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.codexMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.codexMuted)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
                    .background(closeButtonSurface, in: Circle())
            }
            .buttonStyle(CodexPressableCircleStyle())
            .accessibilityLabel("关闭指引")
        }
    }

    private var integrationBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("接入机制")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.codexInk)
            }

            Text(guide.summary)
                .font(.system(size: 11))
                .foregroundStyle(Color.codexInk.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.codexLine, lineWidth: 0.8)
        }
    }

    private var methodsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("官方安装方式")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.codexInk)

            ForEach(guide.methods) { method in
                methodCard(method)
            }
        }
    }

    private func methodCard(_ method: AgentInstallMethod) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text(method.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.codexInk)

                Spacer()

                if let command = method.command {
                    let isCopied = copiedMethodID == method.id
                    Button {
                        onCopyCommand(command)
                        copiedMethodID = method.id
                        copyResetTask?.cancel()
                        copyResetTask = Task { @MainActor in
                            try? await Task.sleep(for: .seconds(2))
                            if copiedMethodID == method.id {
                                copiedMethodID = nil
                            }
                        }
                    } label: {
                        Label(isCopied ? "已复制" : "复制命令", systemImage: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(isCopied ? Color.codexGreen : Color.accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                } else if let urlString = method.urlString, let url = URL(string: urlString) {
                    Button {
                        openURL(url)
                    } label: {
                        Label("前往下载", systemImage: "arrow.up.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            if let command = method.command {
                Text(command)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.codexInk)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.black.opacity(colorScheme == .dark ? 0.35 : 0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            if let note = method.note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.codexMuted)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.codexLine.opacity(0.6), lineWidth: 0.8)
        }
    }

    private var disclaimerNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.codexMuted)
                .padding(.top, 1)

            Text("说明：Tomo 仅提供官方安装指引，不代为执行安装命令或更改系统环境。在终端中完成安装后，点击下方「重新检测」即可自动接入。")
                .font(.system(size: 10))
                .foregroundStyle(Color.codexMuted)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
        .padding(.horizontal, 4)
    }

    private var footerActions: some View {
        HStack(spacing: 8) {
            if let docURLString = guide.documentationURLString, let url = URL(string: docURLString) {
                Button {
                    openURL(url)
                } label: {
                    Label("官网", systemImage: "arrow.up.right")
                        .font(.system(size: 11, weight: .medium))
                        .frame(height: 32)
                        .padding(.horizontal, 10)
                }
                .buttonStyle(CodexPressableStyle(cornerRadius: 8))
                .foregroundStyle(Color.codexInk)
                .background(cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.codexLine, lineWidth: 0.8)
                }
            }

            Spacer()

            Button {
                onRecheck()
            } label: {
                Label("重新检测", systemImage: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(height: 32)
                    .padding(.horizontal, 12)
            }
            .buttonStyle(CodexPressableStyle(cornerRadius: 8))
            .foregroundStyle(Color.accentColor)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Button(action: onClose) {
                Text("完成")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(height: 32)
                    .padding(.horizontal, 14)
            }
            .buttonStyle(CodexPressableStyle(cornerRadius: 8, ink: .softLight))
            .foregroundStyle(Color.codexOnPrimary)
            .background(Color.codexPrimary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(.top, 4)
    }

    private var modalSurface: Color {
        colorScheme == .dark
            ? Color(red: 0.205, green: 0.205, blue: 0.218)
            : Color(red: 0.985, green: 0.985, blue: 0.980)
    }

    private var modalBorder: Color {
        colorScheme == .dark ? Color.white.opacity(0.28) : Color.black.opacity(0.12)
    }

    private var cardBackground: Color {
        colorScheme == .dark ? Color.white.opacity(0.04) : Color.white.opacity(0.7)
    }

    private var closeButtonSurface: Color {
        colorScheme == .dark ? Color.black.opacity(0.12) : Color.black.opacity(0.035)
    }
}

// MARK: - In-App Dropdown Color Picker (Popover)

private struct TomoColorSliderTrack: View {
    let gradient: LinearGradient
    @Binding var value: Double

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let thumbX = max(0, min(width, width * CGFloat(value)))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(gradient)
                    .frame(height: 12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.15), lineWidth: 0.8)
                    )

                Circle()
                    .fill(Color.white)
                    .frame(width: 16, height: 16)
                    .shadow(color: Color.black.opacity(0.25), radius: 2, y: 1)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.black.opacity(0.2), lineWidth: 0.8)
                    )
                    .offset(x: max(0, min(width - 16, thumbX - 8)))
            }
            .frame(height: 16)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let locationX = gesture.location.x
                        let clamped = max(0, min(1, locationX / width))
                        value = Double(clamped)
                    }
            )
        }
        .frame(height: 16)
    }
}

private struct TomoColorPopoverView: View {
    let initialHex: String
    let onColorChanged: (String) -> Void

    @State private var hue: Double
    @State private var saturation: Double
    @State private var brightness: Double
    @State private var hexInputText: String
    @State private var isCopied: Bool = false
    @State private var isInternalUpdate: Bool = false

    private static let quickSwatches: [String] = [
        "#F44336", "#E91E63", "#9C27B0", "#673AB7",
        "#1A73E8", "#0B57D0", "#00ACC1", "#00897B",
        "#43A047", "#7CB342", "#FDD835", "#FB8C00",
        "#F4511E", "#795548", "#212121", "#FFFFFF"
    ]

    init(initialHex: String, onColorChanged: @escaping (String) -> Void) {
        self.initialHex = initialHex
        self.onColorChanged = onColorChanged

        let (h, s, b) = Self.hexToHSB(initialHex)
        _hue = State(initialValue: h)
        _saturation = State(initialValue: s)
        _brightness = State(initialValue: b)
        _hexInputText = State(initialValue: initialHex.uppercased())
    }

    var currentColor: Color {
        Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    var currentHex: String {
        Self.hsbToHex(h: hue, s: saturation, b: brightness)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 1. Header with Eyedropper
            HStack {
                Text("自定义颜色")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.codexInk)

                Spacer()

                Button {
                    if #available(macOS 10.15, *) {
                        NSColorSampler().show { pickedColor in
                            guard let pickedColor, let hex = pickedColor.toHex() else { return }
                            let (h, s, b) = Self.hexToHSB(hex)
                            DispatchQueue.main.async {
                                applyColor(h: h, s: s, b: b, hex: hex)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "eyedropper.halffull")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text("屏幕取色")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(Color.codexMist.opacity(0.8), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .foregroundStyle(Color.codexInk)
                }
                .buttonStyle(.plain)
                .help("吸取屏幕任意像素色彩")
            }

            // 2. Preview Swatch + Hex Input + Copy
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(currentColor)
                    .frame(width: 32, height: 32)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.15), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.08), radius: 2, y: 1)

                TextField("#HEX", text: $hexInputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 8)
                    .frame(height: 32)
                    .background(Color.codexMist.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.codexLine.opacity(0.6), lineWidth: 0.8)
                    )
                    .onChange(of: hexInputText) { _, newText in
                        guard !isInternalUpdate else { return }
                        let clean = newText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let nsColor = NSColor(hex: clean) {
                            let (h, s, b) = Self.hexToHSB(clean)
                            hue = h
                            saturation = s
                            brightness = b
                            if let hex = nsColor.toHex() {
                                onColorChanged(hex)
                            }
                        }
                    }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(currentHex, forType: .string)
                    isCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        isCopied = false
                    }
                } label: {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isCopied ? Color.codexGreen : Color.codexMuted)
                        .frame(width: 28, height: 32)
                        .background(Color.codexMist.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("复制色值至剪贴板")
            }

            // 3. Spectrum Sliders
            VStack(spacing: 8) {
                // Hue (色相)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("色相")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.codexMuted)
                        Spacer()
                        Text("\(Int(hue * 360))°")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(Color.codexMuted)
                    }
                    TomoColorSliderTrack(
                        gradient: LinearGradient(
                            colors: [
                                Color(hue: 0.0, saturation: 1.0, brightness: 1.0),
                                Color(hue: 0.17, saturation: 1.0, brightness: 1.0),
                                Color(hue: 0.33, saturation: 1.0, brightness: 1.0),
                                Color(hue: 0.50, saturation: 1.0, brightness: 1.0),
                                Color(hue: 0.67, saturation: 1.0, brightness: 1.0),
                                Color(hue: 0.83, saturation: 1.0, brightness: 1.0),
                                Color(hue: 1.0, saturation: 1.0, brightness: 1.0)
                            ],
                            startPoint: .leading, endPoint: .trailing
                        ),
                        value: Binding(
                            get: { hue },
                            set: { newHue in
                                hue = newHue
                                updateFromHSB()
                            }
                        )
                    )
                }

                // Saturation (纯度)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("饱和度")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.codexMuted)
                        Spacer()
                        Text("\(Int(saturation * 100))%")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(Color.codexMuted)
                    }
                    TomoColorSliderTrack(
                        gradient: LinearGradient(
                            colors: [
                                Color(hue: hue, saturation: 0.0, brightness: brightness),
                                Color(hue: hue, saturation: 1.0, brightness: brightness)
                            ],
                            startPoint: .leading, endPoint: .trailing
                        ),
                        value: Binding(
                            get: { saturation },
                            set: { newSat in
                                saturation = newSat
                                updateFromHSB()
                            }
                        )
                    )
                }

                // Brightness (明度)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("明度")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.codexMuted)
                        Spacer()
                        Text("\(Int(brightness * 100))%")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(Color.codexMuted)
                    }
                    TomoColorSliderTrack(
                        gradient: LinearGradient(
                            colors: [
                                Color(hue: hue, saturation: saturation, brightness: 0.0),
                                Color(hue: hue, saturation: saturation, brightness: 1.0)
                            ],
                            startPoint: .leading, endPoint: .trailing
                        ),
                        value: Binding(
                            get: { brightness },
                            set: { newBri in
                                brightness = newBri
                                updateFromHSB()
                            }
                        )
                    )
                }
            }

            // 4. Curated Quick Swatches
            VStack(alignment: .leading, spacing: 5) {
                Text("精选推荐色")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.codexMuted)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                    ForEach(Self.quickSwatches, id: \.self) { swatchHex in
                        let isMatched = currentHex.caseInsensitiveCompare(swatchHex) == .orderedSame
                        Button {
                            let (h, s, b) = Self.hexToHSB(swatchHex)
                            applyColor(h: h, s: s, b: b, hex: swatchHex)
                        } label: {
                            Circle()
                                .fill(Color(hex: swatchHex))
                                .frame(width: 20, height: 20)
                                .overlay(
                                    Circle()
                                        .strokeBorder(isMatched ? Color.codexInk : Color.black.opacity(0.15), lineWidth: isMatched ? 1.8 : 0.6)
                                )
                                .overlay(
                                    Group {
                                        if isMatched {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 8, weight: .bold))
                                                .foregroundStyle(Self.isDarkColor(swatchHex) ? Color.white : Color.black)
                                        }
                                    }
                                )
                        }
                        .buttonStyle(.plain)
                        .help(swatchHex)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 246)
    }

    private func applyColor(h: Double, s: Double, b: Double, hex: String) {
        isInternalUpdate = true
        hue = h
        saturation = s
        brightness = b
        hexInputText = hex.uppercased()
        isInternalUpdate = false
        onColorChanged(hex)
    }

    private func updateFromHSB() {
        let hex = currentHex
        isInternalUpdate = true
        hexInputText = hex.uppercased()
        isInternalUpdate = false
        onColorChanged(hex)
    }

    nonisolated static func hexToHSB(_ hex: String) -> (Double, Double, Double) {
        guard let nsColor = NSColor(hex: hex)?.usingColorSpace(.sRGB) else {
            return (0.58, 0.85, 0.85)
        }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        nsColor.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (Double(h), Double(s), Double(b))
    }

    nonisolated static func hsbToHex(h: Double, s: Double, b: Double) -> String {
        let nsColor = NSColor(hue: CGFloat(h), saturation: CGFloat(s), brightness: CGFloat(b), alpha: 1.0)
        return nsColor.toHex() ?? "#0B57D0"
    }

    nonisolated static func isDarkColor(_ hex: String) -> Bool {
        guard let nsColor = NSColor(hex: hex)?.usingColorSpace(.sRGB) else { return true }
        let luminance = 0.299 * nsColor.redComponent + 0.587 * nsColor.greenComponent + 0.114 * nsColor.blueComponent
        return luminance < 0.6
    }
}

private struct TomoColorPickerButton: View {
    let colorHex: String
    var size: CGFloat = 26
    var tooltip: String = "自定义颜色"
    let onColorChanged: (String) -> Void
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(Color(hex: colorHex))
                    .frame(width: size, height: size)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.codexLine.opacity(0.8), lineWidth: 1.2)
                    )

                Image(systemName: "eyedropper.halffull")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(TomoColorPopoverView.isDarkColor(colorHex) ? Color.white : Color.black)
            }
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            TomoColorPopoverView(
                initialHex: colorHex,
                onColorChanged: onColorChanged
            )
        }
    }
}

// MARK: - Chrome-Inspired Appearance Components

private struct ChromeThemeColorSwatchView: View {
    let preset: TomoChromePresetColor
    let isSelected: Bool
    let isDark: Bool
    var activeAccentColor: Color? = nil
    let onSelect: () -> Void
    var onCustomColorPicked: ((String) -> Void)? = nil

    @State private var isCustomPickerPresented = false

    var body: some View {
        let currentAccent = activeAccentColor ?? Color(hex: preset.seedHex)
        Button {
            onSelect()
            if preset.isCustom {
                isCustomPickerPresented.toggle()
            }
        } label: {
            ZStack {
                if preset.isCustom {
                    Circle()
                        .fill(isSelected ? currentAccent.opacity(0.18) : Color.codexMist.opacity(0.8))
                        .frame(width: 44, height: 44)

                    Circle()
                        .strokeBorder(isSelected ? currentAccent : Color.codexLine.opacity(0.8), lineWidth: isSelected ? 1.6 : 1)
                        .frame(width: 44, height: 44)

                    Image(systemName: "eyedropper.halffull")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isSelected ? currentAccent : Color.codexInk)
                } else {
                    let fgColor = Color(hex: isDark ? preset.darkFg : preset.lightFg)
                    let bgColor = Color(hex: isDark ? preset.darkBg : preset.lightBg)
                    let baseColor = Color(hex: isDark ? preset.darkBase : preset.lightBase)

                    GeometryReader { geo in
                        let r = min(geo.size.width, geo.size.height) / 2
                        ZStack {
                            // Top half arc (foreground - 重点色, 最大的色块!)
                            Path { p in
                                p.addArc(center: CGPoint(x: r, y: r), radius: r, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                                p.closeSubpath()
                            }
                            .fill(bgColor)

                            // Bottom left quadrant (top container / light fg)
                            Path { p in
                                p.move(to: CGPoint(x: r, y: r))
                                p.addArc(center: CGPoint(x: r, y: r), radius: r, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
                                p.closeSubpath()
                            }
                            .fill(fgColor)

                            // Bottom right quadrant (base / surface)
                            Path { p in
                                p.move(to: CGPoint(x: r, y: r))
                                p.addArc(center: CGPoint(x: r, y: r), radius: r, startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
                                p.closeSubpath()
                            }
                            .fill(baseColor)

                            // Horizontal divider line between top half and bottom quadrants
                            Path { p in
                                p.move(to: CGPoint(x: 0, y: r))
                                p.addLine(to: CGPoint(x: r * 2, y: r))
                            }
                            .stroke(Color.black.opacity(isDark ? 0.25 : 0.08), lineWidth: 0.75)

                            // Bottom vertical divider line between left container and right base
                            Path { p in
                                p.move(to: CGPoint(x: r, y: r))
                                p.addLine(to: CGPoint(x: r, y: r * 2))
                            }
                            .stroke(Color.black.opacity(isDark ? 0.25 : 0.08), lineWidth: 0.75)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.8)
                    )
                }

                // Selected ring & center checkmark
                if isSelected {
                    Circle()
                        .strokeBorder(currentAccent, lineWidth: 2.5)
                        .frame(width: 52, height: 52)

                    Circle()
                        .fill(currentAccent)
                        .frame(width: 18, height: 18)
                        .overlay(
                            Image(systemName: "checkmark")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(.white)
                        )
                }
            }
            .frame(width: 54, height: 54)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(preset.isCustom ? "自定义调色盘与屏幕吸色" : preset.name)
        .popover(isPresented: $isCustomPickerPresented, arrowEdge: .bottom) {
            if preset.isCustom {
                TomoColorPopoverView(
                    initialHex: activeAccentColor?.toHex() ?? preset.seedHex,
                    onColorChanged: { hex in
                        onCustomColorPicked?(hex)
                    }
                )
            }
        }
    }
}

private struct ChromeThemePreviewCard: View {
    let themeConfig: TomoThemeConfig
    let themePreference: AppThemePreference
    let preset: TomoChromePresetColor
    let isDark: Bool
    let onReset: () -> Void

    var body: some View {
        let accent = Color(hex: isDark ? preset.darkBg : preset.lightBg)
        let fgColor = Color(hex: isDark ? preset.darkFg : preset.lightFg)
        let baseColor = Color(hex: isDark ? preset.darkBase : preset.lightBase)

        VStack(spacing: 12) {
            // Header: Theme Name & Reset Button
            HStack {
                HStack(spacing: 8) {
                    Text(preset.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Color.codexInk)

                    Text(themePreference.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(accent.opacity(0.12), in: Capsule())
                }

                Spacer()

                Button(action: onReset) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10.5, weight: .medium))
                        Text("重置为默认值")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Color.codexMuted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4.5)
                    .background(Color.codexMist.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("重置外观为默认经典主题与系统跟随模式")
            }

            // Window mockup
            VStack(spacing: 0) {
                // Mini Titlebar / Tab Bar (50% 顶栏前景色 lightFg / darkFg)
                HStack(spacing: 6) {
                    // Traffic lights
                    HStack(spacing: 4) {
                        Circle().fill(Color.red.opacity(0.8)).frame(width: 7, height: 7)
                        Circle().fill(Color.yellow.opacity(0.8)).frame(width: 7, height: 7)
                        Circle().fill(Color.green.opacity(0.8)).frame(width: 7, height: 7)
                    }
                    .padding(.leading, 8)

                    // Active Tab
                    HStack(spacing: 6) {
                        TomoMarkView(config: themeConfig, size: 14, showTile: false)
                            .frame(width: 14, height: 14)
                        Text("Tomo Overview")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Color.codexInk)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.codexCard, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(accent.opacity(0.4), lineWidth: 0.8)
                    )

                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(fgColor)

                // Content View Mockup (25% 基底中性表层 lightBase / darkBase)
                HStack(spacing: 12) {
                    // Left Mini Card
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Circle()
                                .fill(accent)
                                .frame(width: 6, height: 6)
                            Text("Claude 3.7 Sonnet")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.codexInk)
                        }

                        // Mini progress bar (25% 主品牌强调色 lightBg / darkBg)
                        Capsule()
                            .fill(accent.opacity(0.2))
                            .frame(height: 4)
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(accent)
                                    .frame(width: 60, height: 4)
                            }
                    }
                    .padding(8)
                    .background(Color.codexCard, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.codexLine.opacity(0.6), lineWidth: 0.6)
                    )

                    // Right Mini Mark
                    TomoMarkView(config: themeConfig, size: 36, showTile: true)
                        .frame(width: 36, height: 36)

                    Spacer()
                }
                .padding(10)
                .background(baseColor)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.codexLine.opacity(0.8), lineWidth: 0.8)
            )
        }
        .padding(14)
        .settingsGroupSurface()
    }
}

private struct ChromeAppearanceModeSwitcher: View {
    @Binding var selection: AppThemePreference
    var accentColor: Color = .themeAccent

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AppThemePreference.allCases) { pref in
                let isSel = selection == pref
                Button {
                    selection = pref
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: pref.symbolName)
                            .font(.system(size: 13, weight: isSel ? .semibold : .regular))
                        Text(pref.title)
                            .font(.system(size: 12.5, weight: isSel ? .semibold : .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        isSel ? accentColor.opacity(0.12) : Color.codexMist.opacity(0.4),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                isSel ? accentColor : Color.codexLine.opacity(0.5),
                                lineWidth: isSel ? 1.5 : 0.8
                            )
                    )
                    .foregroundStyle(isSel ? accentColor : Color.codexInk)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
