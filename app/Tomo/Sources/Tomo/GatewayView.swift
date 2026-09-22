import AppKit
import SwiftUI

public struct GatewayView: View {
    @State private var store = GatewayStore.shared
    @State private var supervisor = GatewaySupervisor.shared
    @State private var showsStickyTitle: Bool = false
    @State private var toast: GatewayToast? = nil
    @State private var toastDismissGeneration: Int = 0

    /// Injected by GatewayWindowController; used to route proxy toggles through
    /// MultiAgentSettingsStore so in-memory account state stays consistent.
    var settingsStore: MultiAgentSettingsStore?
    /// The independent AppKit window does not inherit the menu popover's
    /// SwiftUI environment, so its resolved scheme is supplied explicitly.
    var preferredColorScheme: ColorScheme?

    public init() {}

    init(settingsStore: MultiAgentSettingsStore?, preferredColorScheme: ColorScheme? = nil) {
        self.settingsStore = settingsStore
        self.preferredColorScheme = preferredColorScheme
    }

    public var body: some View {
        HStack(spacing: 0) {
            gatewaySidebar
                .frame(width: GatewayLayoutMetrics.sidebarWidth)

            CodexDivider(.vertical)

            GeometryReader { contentGeometry in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        tabHeader

                        switch store.selectedTab {
                        case .connect:
                            GatewayConnectView(
                                store: store,
                                supervisor: supervisor,
                                settingsStore: settingsStore,
                                onToast: showToast
                            )
                        case .automation:
                            GatewayAutomationView(
                                store: store,
                                supervisor: supervisor,
                                settingsStore: settingsStore,
                                availableWindowHeight: contentGeometry.size.height,
                                onToast: showToast
                            )
                        case .agents:
                            GatewayAgentsView(
                                store: store,
                                supervisor: supervisor,
                                settingsStore: settingsStore,
                                onToast: showToast
                            )
                        case .overview:
                            GatewayOverviewView(
                                store: store,
                                supervisor: supervisor
                            )
                        case .analytics:
                            GatewayAnalyticsView(
                                store: store
                            )
                        case .requests:
                            GatewayRequestsView(
                                store: store,
                                supervisor: supervisor
                            )
                        case .doctor:
                            GatewayDoctorView(
                                store: store,
                                supervisor: supervisor
                            )
                        case .logs:
                            GatewayLogsView()
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, GatewayLayoutMetrics.windowTopInset)
                    .padding(.bottom, GatewayLayoutMetrics.windowBottomInset)
                    // A vertical ScrollView otherwise uses its child's ideal
                    // width. Wide model-table rows can then enlarge the entire
                    // page beyond the window instead of being compressed.
                    .frame(width: contentGeometry.size.width, alignment: .topLeading)
                    .background(ScrollIndicatorHider())
                }
                .coordinateSpace(name: GatewayScrollCoordinateSpace.name)
                .onPreferenceChange(GatewayHeaderMinYKey.self) { minY in
                    if showsStickyTitle {
                        if minY > -44 {
                            showsStickyTitle = false
                        }
                    } else if minY < -72 {
                        showsStickyTitle = true
                    }
                }
                .scrollIndicators(.hidden)
                .background {
                    ZStack {
                        Color.codexBackground.opacity(0.50)
                        ScrollIndicatorHider()
                    }
                }
            }
        }
        .frame(minWidth: GatewayLayoutMetrics.minWindowWidth, minHeight: GatewayLayoutMetrics.minWindowHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(Color.codexInk)
        .overlay(alignment: .topLeading) {
            if showsStickyTitle {
                HStack(alignment: .top, spacing: 0) {
                    Color.clear
                        .frame(width: GatewayLayoutMetrics.sidebarWidth + 1, height: 110)
                    stickyGatewayTitle
                }
                .offset(y: -34)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.24), value: showsStickyTitle)
        .preferredColorScheme(preferredColorScheme)
        .overlay(alignment: .bottom) {
            if let toast {
                HStack(spacing: 8) {
                    Image(systemName: toast.systemImage)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(toast.isSuccess ? Color.green : (toast.systemImage.contains("triangle") ? Color.orange : Color.red))
                    Text(toast.message)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(Color.black.opacity(0.88), in: Capsule(style: .continuous))
                .shadow(color: Color.black.opacity(0.20), radius: 10, x: 0, y: 4)
                .padding(.bottom, 22)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityLabel(toast.message)
                .allowsHitTesting(false)
                .zIndex(1000)
            }
        }
        .animation(.easeOut(duration: 0.18), value: toast)
        .sheet(isPresented: Binding(
            get: { store.isColumnSettingsPresented },
            set: { store.isColumnSettingsPresented = $0 }
        )) {
            GatewayColumnSettingsSheet(store: store)
        }
    }

    private func showToast(_ message: String, systemImage: String = "checkmark.circle.fill", isSuccess: Bool = true) {
        toastDismissGeneration += 1
        let generation = toastDismissGeneration
        withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
            toast = GatewayToast(message: message, systemImage: systemImage, isSuccess: isSuccess)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            guard generation == toastDismissGeneration else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                toast = nil
            }
        }
    }


    private var stickyGatewayTitle: some View {
        Text(store.selectedTab.rawValue)
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

    // MARK: - Header
    private var tabHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(store.selectedTab.rawValue)
                    .font(.system(size: 20, weight: .bold))

                if (store.selectedTab == .overview && (store.isTelemetryLoading || store.isSummaryLoading || store.isBreakdownLoading)) ||
                   (store.selectedTab == .analytics && store.isAnalyticsLoading) ||
                   (store.selectedTab == .requests && (store.isRequestsLoading || store.isTelemetryLoading)) {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("正在加载...")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.codexMuted)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.codexMist.opacity(0.8), in: Capsule())
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            Text(store.selectedTab.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(Color.codexMuted)
        }
        .animation(.easeInOut(duration: 0.2), value: store.isTelemetryLoading || store.isRequestsLoading || store.isBreakdownLoading || store.isAnalyticsLoading)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: GatewayHeaderMinYKey.self,
                    value: geometry.frame(in: .named(GatewayScrollCoordinateSpace.name)).minY
                )
            }
        }
    }

    // MARK: - Sidebar
    private var gatewaySidebar: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("GATEWAY")
                .font(.system(size: 9, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(Color.codexMuted)
                .padding(.horizontal, 10)
                .padding(.bottom, 5)

            ForEach(GatewayNavTab.allCases) { tab in
                Button {
                    // Changing tabs can replace a dense provider/model tree.
                    // Animating that entire tree forces SwiftUI to lay out the
                    // old and new pages together, which made navigation feel
                    // stalled as the discovered catalog grew.
                    store.selectedTab = tab
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: tab.symbolName)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 18)
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: store.selectedTab == tab ? .semibold : .medium))
                            .lineLimit(1)
                        Spacer(minLength: 0)

                        if (tab == .overview && (store.isTelemetryLoading || store.isSummaryLoading)) ||
                           (tab == .analytics && store.isAnalyticsLoading) ||
                           (tab == .requests && (store.isRequestsLoading || store.isTelemetryLoading)) ||
                           ((tab == .automation || tab == .connect) && store.isModelCheckRunning) {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                    .foregroundStyle(store.selectedTab == tab ? Color.codexInk : Color.codexMuted)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .contentShape(Rectangle())
                    .background(
                        store.selectedTab == tab ? Color.codexPrimary.opacity(0.10) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                }
                .buttonStyle(CodexPressableStyle(cornerRadius: 8))
                .accessibilityValue(store.selectedTab == tab ? "已选择" : "")
            }

            Spacer(minLength: 12)

            // Status Card at Footer
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(supervisor.isRunning ? (store.isModelCheckRunning ? Color.blue : Color.green) : Color.red)
                        .frame(width: 7, height: 7)
                    Text(supervisor.isRunning ? (store.isModelCheckRunning ? "巡检执行中" : "网关运行中") : "网关已停止")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(supervisor.isRunning ? (store.isModelCheckRunning ? Color.blue : Color.green) : Color.red)
                        .lineLimit(1)

                    if supervisor.isRunning && store.isModelCheckRunning {
                        Spacer()
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.65)
                    }
                }
                Text(verbatim: "端口: \(supervisor.port)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.codexMuted)
                    .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.codexCard)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.8)
            )

            Text("Tomo Gateway")
                .font(.system(size: 9))
                .foregroundStyle(Color.codexMuted.opacity(0.82))
                .padding(.top, 2)
        }
        .padding(.horizontal, 10)
        .padding(.top, GatewayLayoutMetrics.sidebarTopInset)
        .padding(.bottom, 14)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.codexCard.opacity(0.72))
    }


}
