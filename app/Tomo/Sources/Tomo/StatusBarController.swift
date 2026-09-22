import AppKit
import CoreText
import SwiftUI

enum ActivityWaveTiming {
    static let duration: TimeInterval = 3.6
    static let capsuleDuration: TimeInterval = duration / 2
    static let rotatingBorderDuration: TimeInterval = 2.4

    static func progress(at time: TimeInterval) -> CGFloat {
        CGFloat(time.truncatingRemainder(dividingBy: duration) / duration)
    }

    static func capsuleProgress(at time: TimeInterval) -> CGFloat {
        CGFloat(
            time.truncatingRemainder(dividingBy: capsuleDuration)
                / capsuleDuration
        )
    }

    static func rotatingBorderProgress(at time: TimeInterval) -> CGFloat {
        CGFloat(
            time.truncatingRemainder(dividingBy: rotatingBorderDuration)
                / rotatingBorderDuration
        )
    }
}

enum ActivityCapsuleWavePresentation: Equatable {
    case fill
    case border(lineWidth: CGFloat)
    case rotatingBorder(lineWidth: CGFloat)

    func progress(at time: TimeInterval) -> CGFloat {
        switch self {
        case .rotatingBorder:
            ActivityWaveTiming.rotatingBorderProgress(at: time)
        case .fill, .border:
            ActivityWaveTiming.capsuleProgress(at: time)
        }
    }
}

enum ActivityCapsuleWaveRenderer {
    static func draw(
        in context: CGContext,
        containerBounds: CGRect,
        capsuleRect: CGRect,
        cornerRatio: CGFloat,
        ink: NSColor,
        progress: CGFloat,
        presentation: ActivityCapsuleWavePresentation = .fill,
        rotationDirection: CGFloat = 1
    ) {
        guard !containerBounds.isEmpty, !capsuleRect.isEmpty else { return }

        let clampedCornerRatio = min(max(cornerRatio, 0.2), 0.5)
        let clampedProgress = min(max(progress, 0), 1)
        let waveWidth = max(72, containerBounds.width * 1.08)
        let travelWidth = containerBounds.width + waveWidth * 2
        let centerX = containerBounds.minX - waveWidth + travelWidth * clampedProgress
        let waveRect = CGRect(
            x: centerX - waveWidth / 2,
            y: capsuleRect.minY,
            width: waveWidth,
            height: capsuleRect.height
        )

        context.saveGState()
        let borderWidth: CGFloat = switch presentation {
        case .fill: 0
        case .border(let lineWidth), .rotatingBorder(let lineWidth):
            max(0.5, lineWidth)
        }
        let pathRect = borderWidth > 0
            ? capsuleRect.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)
            : capsuleRect
        let capsulePath = CGPath(
            roundedRect: pathRect,
            cornerWidth: pathRect.height * clampedCornerRatio,
            cornerHeight: pathRect.height * clampedCornerRatio,
            transform: nil
        )
        context.addPath(capsulePath)
        if borderWidth > 0 {
            context.setLineWidth(borderWidth)
            context.replacePathWithStrokedPath()
        }
        context.clip()
        switch presentation {
        case .fill, .border:
            context.addPath(
                CGPath(
                    roundedRect: waveRect,
                    cornerWidth: waveRect.height * clampedCornerRatio,
                    cornerHeight: waveRect.height * clampedCornerRatio,
                    transform: nil
                )
            )
            context.clip()

            let colors = [
                ink.withAlphaComponent(0).cgColor,
                ink.withAlphaComponent(ink.alphaComponent * 0.18).cgColor,
                ink.withAlphaComponent(ink.alphaComponent * 0.52).cgColor,
                ink.cgColor,
            ] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 0.44, 0.74, 1]
            ) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: waveRect.minX, y: waveRect.midY),
                    end: CGPoint(x: waveRect.maxX, y: waveRect.midY),
                    options: []
                )
            }
        case .rotatingBorder:
            let colors: CFArray
            let locations: [CGFloat]
            if rotationDirection < 0 {
                // AppKit's upward-positive Y axis needs a negative angle for
                // clockwise motion. Reverse the comet at the same time so the
                // bright head still leads and the translucent tail follows.
                colors = [
                    ink.withAlphaComponent(0).cgColor,
                    ink.cgColor,
                    ink.withAlphaComponent(ink.alphaComponent * 0.72).cgColor,
                    ink.withAlphaComponent(ink.alphaComponent * 0.38).cgColor,
                    ink.withAlphaComponent(ink.alphaComponent * 0.14).cgColor,
                    ink.withAlphaComponent(0).cgColor,
                    ink.withAlphaComponent(0).cgColor,
                ] as CFArray
                locations = [0, 0.04, 0.11, 0.20, 0.30, 0.40, 1]
            } else {
                colors = [
                    ink.withAlphaComponent(0).cgColor,
                    ink.withAlphaComponent(0).cgColor,
                    ink.withAlphaComponent(ink.alphaComponent * 0.14).cgColor,
                    ink.withAlphaComponent(ink.alphaComponent * 0.38).cgColor,
                    ink.withAlphaComponent(ink.alphaComponent * 0.72).cgColor,
                    ink.cgColor,
                    ink.withAlphaComponent(0).cgColor,
                ] as CFArray
                locations = [0, 0.60, 0.70, 0.80, 0.89, 0.96, 1]
            }
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: locations
            ) {
                CGContextDrawConicGradient(
                    context,
                    gradient,
                    CGPoint(x: capsuleRect.midX, y: capsuleRect.midY),
                    clampedProgress * .pi * 2 * rotationDirection
                )
            }
        }
        context.restoreGState()
    }
}

struct ActivityCapsuleWave: View {
    let isVisible: Bool
    let ink: NSColor
    var cornerRatio: CGFloat = 0.5
    var presentation: ActivityCapsuleWavePresentation = .fill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if isVisible {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
                Canvas { context, size in
                    let progress = reduceMotion
                        ? CGFloat(0.5)
                        : presentation.progress(
                            at: timeline.date.timeIntervalSinceReferenceDate
                        )
                    context.withCGContext { cgContext in
                        let bounds = CGRect(origin: .zero, size: size)
                        ActivityCapsuleWaveRenderer.draw(
                            in: cgContext,
                            containerBounds: bounds,
                            capsuleRect: bounds,
                            cornerRatio: cornerRatio,
                            ink: ink,
                            progress: progress,
                            presentation: presentation
                        )
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let store: UsageSnapshotStore
    private let settings: AppSettingsStore
    private let activityStore: CodexActivityStore
    private let multiAgentSettings: MultiAgentSettingsStore
    private let frameStore: PetFrameStore
    private let companionStatsStore: CompanionStatsStore
    private let actions: UsageActions
    private let openDetachedWindowFromStatusItem: (NSScreen?) -> Void
    private let hoverPanel = PetHoverPanelController()
    private var capsuleView: StatusCapsuleView?
    private let notchDetector: MenuBarNotchDetector
    private let highlightOverlay = ScreenHighlightOverlay()
    private var notchPanels: [String: NotchCapsulePanelController] = [:]
    /// `NSScreen.screens` can still be empty for a short time while an accessory
    /// app is launching. Keep screen discovery separate from the user's mode so
    /// that this transient state cannot switch the UI to the status-item fallback.
    private var notchScreenDiscoveryRetry: DispatchWorkItem?
    private var notchScreenDiscoveryAttempt = 0
    private var ticker = StatusBarTicker()
    /// 共享驱动：负责统一的 agent 轮播计时与悬停暂停/续播语义。
    private lazy var agentCarouselDriver = AgentCarouselDriver { [weak self] in
        self?.advanceAgentTick()
    }
    private var pendingHoverWorkItem: DispatchWorkItem?
    private var pendingHoverHideWorkItem: DispatchWorkItem?
    private var hoverSafeTriangle: HoverSafeTriangle?
    private var hoverSafeTriangleTimer: Timer?
    private var hoverSafeTriangleDeadline: Date?
    private var taskHoverPresentation = TaskHoverPresentationState()
    private var isKeepingTaskHoverVisible = false
    private var lastStatusItemOpenTimestamp: TimeInterval = -.infinity
    /// 最近一次把刘海面板供应商索引同步到全局选中账号的选中键。
    /// 只有选中账号真正变化时才回写索引；否则刘海面板自身的显示轮播
    /// （「供应商自动轮播」关闭时）不会被数据刷新拉回选中项。
    private var lastSyncedProviderSelectionKey: String?
    /// 当主窗口开启自动轮播但刘海面板关闭自动轮播时，主窗口定时推进全局选中账号，
    /// 此标记为 true，防止刘海面板显示被自动轮播的选中改变带偏（保持自身显示不变）。
    var isAutoCarouselAdvancing = false
    /// 用户在刘海展开面板手动点击供应商后，通知 AppDelegate 重置轮播倒计时。
    var onProviderSelection: (() -> Void)?
    /// 刘海面板专用刷新入口；由 AppDelegate 执行统一刷新但不显示 toast。
    var onRefreshProvider: (() -> Void)?
    /// 刘海面板「打开设置」按钮的回调；由 AppDelegate 打开设置窗口。
    var onOpenSettings: (() -> Void)?

    init(
        store: UsageSnapshotStore,
        settings: AppSettingsStore,
        activityStore: CodexActivityStore,
        multiAgentSettings: MultiAgentSettingsStore,
        frameStore: PetFrameStore,
        companionStatsStore: CompanionStatsStore,
        actions: UsageActions,
        openDetachedWindowFromStatusItem: @escaping (NSScreen?) -> Void
    ) {
        self.store = store
        self.settings = settings
        self.activityStore = activityStore
        self.multiAgentSettings = multiAgentSettings
        self.frameStore = frameStore
        self.companionStatsStore = companionStatsStore
        self.actions = actions
        self.openDetachedWindowFromStatusItem = openDetachedWindowFromStatusItem
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        notchDetector = MenuBarNotchDetector()
        super.init()

        notchDetector.onChange = { [weak self] in
            self?.applyMode()
        }

        hoverPanel.onMouseEntered = { [weak self] in
            self?.cancelHoverPanelHide()
        }
        hoverPanel.onMouseExited = { [weak self] in
            guard let self else { return }
            guard let statusFrame = self.statusCapsuleScreenFrame else {
                self.scheduleHoverPanelHide()
                return
            }
            self.scheduleHoverPanelHide(
                from: NSEvent.mouseLocation,
                toward: statusFrame
            )
        }
        hoverPanel.onClick = { [weak self] in
            guard let self else { return }
            self.hideHoverPanelUnlessTaskIsActive()
            self.openDetachedWindowFromStatusItem(self.statusItem.button?.window?.screen)
        }
        hoverPanel.onClose = { [weak self] in
            guard let self else { return }
            self.taskHoverPresentation.dismiss()
            self.isKeepingTaskHoverVisible = false
            self.hideHoverPanel()
        }

        statusItem.isVisible = true
        frameStore.onFrameChanged = { [weak self] in
            self?.refreshPetFrame()
        }
        configureStatusButton()
        refreshStatusTitle()
        applyMode()

        // 启动初期 NSScreen.screens 可能尚未枚举完全部显示器（尤其外接屏），
        // 只显示内建屏刘海。稍后再执行一次，确保所有目标屏的刘海都出现。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.applyMode()
        }
    }

    func refreshThemeAppearance() {
        refreshStatusTitle()
    }

    /// 刘海显示位置设置变化后重新选择屏幕并切换模式。
    func refreshNotchDisplay() {
        applyMode()
    }

    /// 刷新各屏幕刘海的拖拽配置与偏移位置。
    func refreshNotchDragConfiguration() {
        for (id, panel) in notchPanels {
            let isBuiltin = NSScreen.screens.first(where: { $0.persistentID == id })?.isBuiltin ?? true
            let offset = settings.notchOffset(for: id)
            panel.setDragConfiguration(
                isBuiltin: isBuiltin,
                isDraggingEnabled: settings.notchDraggingEnabled,
                xOffset: offset
            )
        }
    }

    /// 一键将所有外接显示器刘海恢复到顶部中心。
    func resetAllNotchPositionsToCenter() {
        settings.resetAllNotchOffsets()
        for (_, panel) in notchPanels {
            if !panel.isBuiltin {
                panel.resetToCenter(animated: true)
            }
        }
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else {
            DispatchQueue.main.async { [weak self] in
                self?.configureStatusButton()
                self?.refreshStatusTitle()
            }
            return
        }

        button.target = self
        button.action = #selector(handleStatusItemAction(_:))
        button.sendAction(on: .leftMouseUp)
        button.image = nil
        button.attributedTitle = NSAttributedString(string: "")
        button.isBordered = false
        button.showsBorderOnlyWhileMouseInside = false
        button.focusRingType = .none
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.clear.cgColor
        if let cell = button.cell as? NSButtonCell {
            cell.highlightsBy = []
            cell.showsStateBy = []
            cell.focusRingType = .none
        }

        if capsuleView == nil {
            let view = StatusCapsuleView(frame: button.bounds)
            view.autoresizingMask = [.width, .height]
            view.onClick = { [weak self] in
                self?.openFromStatusItem()
            }
            view.onMouseEntered = { [weak self] in self?.scheduleHoverPanel() }
            view.onMouseExited = { [weak self] in
                guard let self, self.hoverPanel.isVisible else {
                    self?.scheduleHoverPanelHide()
                    return
                }
                self.scheduleHoverPanelHide(
                    from: NSEvent.mouseLocation,
                    toward: self.hoverPanel.interactionFrame
                )
            }
            button.addSubview(view)
            capsuleView = view
        }
    }

    @objc
    private func handleStatusItemAction(_ sender: Any?) {
        openFromStatusItem()
    }

    private func openFromStatusItem() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastStatusItemOpenTimestamp > 0.12 else { return }
        lastStatusItemOpenTimestamp = now
        hideHoverPanelUnlessTaskIsActive()
        openDetachedWindowFromStatusItem(statusItem.button?.window?.screen)
    }

    /// 刘海模式：状态栏胶囊已隐藏，打开主窗口时用主屏作为落点。
    private func openFromNotchPanel() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastStatusItemOpenTimestamp > 0.12 else { return }
        lastStatusItemOpenTimestamp = now
        hideHoverPanelUnlessTaskIsActive()
        openDetachedWindowFromStatusItem(NSScreen.main)
    }

    func refreshStatusTitle() {
        let snapshot = store.snapshot
        let activity = activityStore.snapshot
        let activityState = activity.state

        // 双维度数据：左区 Agent 状态、右区供应商额度（独立轮播）
        let agentTicks = currentAgentTicks()
        let providerTicks = currentProviderTicks()
        ticker.clampAgent(to: agentTicks.count)
        syncProviderIndexToSelectionIfNeeded(providerTicks: providerTicks)
        let agentStatuses = activity.activeAgentStatuses
        let activeAgentCount = agentStatuses.count
        let waitingCount = agentStatuses.filter { $0.state == .waitingForUser }.count

        // 共享：降级胶囊/状态栏文本与颜色
        let health = QuotaHealthLevel.from(
            window: snapshot.primaryWindow,
            isLoggedIn: store.isLoggedIn
        )
        let showsWave = settings.statusBarWaveEnabled && activityState.showsActivityWave
        let agentText = agentTicks.indices.contains(ticker.agentIndex)
            ? agentTicks[ticker.agentIndex].statusText : ""
        let providerText = providerTicks.indices.contains(ticker.providerIndex)
            ? providerTicks[ticker.providerIndex].quotaText
            : (store.isLoggedIn ? "无额度" : "未登录")
        let compactText = agentText.isEmpty ? providerText : "\(agentText)·\(providerText)"
        let indicatorColor = settings.statusBarIndicatorColorMode.resolvedNSColor(
            activityState: activityState,
            quotaHealth: health
        ) ?? NSColor.secondaryLabelColor
        let waveColor = settings.statusBarWaveColorMode.resolvedNSColor(
            activityState: activityState,
            quotaHealth: health
        )

        // 刘海面板：目标屏幕
        for screen in targetScreens {
            let panel = notchPanel(for: screen)
            panel.update(
                agentTicks: agentTicks,
                providerTicks: providerTicks,
                agentIndex: ticker.agentIndex,
                providerIndex: ticker.providerIndex,
                activeAgentCount: activeAgentCount,
                waitingCount: waitingCount
            )
            // 数据刷新也可能是显示器枚举竞态后第一个重新创建面板的路径。
            // 仅 update 会留下一个从未 orderFront 的默认坐标窗口；在这里自愈。
            panel.ensureVisible(on: screen)
        }

        // 系统状态栏胶囊：刘海关闭时显示（降级胶囊）
        if statusItem.isVisible, let button = statusItem.button {
            let cornerRatio = CGFloat(settings.statusBarCornerPercent / 100)
            let reservedText = statusCapsuleReservedText(
                snapshot: snapshot,
                isLoggedIn: store.isLoggedIn,
                showsActivity: !agentTicks.isEmpty || activityState.statusBarText != nil
            )

            capsuleView?.petImage = nil
            let agentLogo = agentTicks.indices.contains(ticker.agentIndex)
                ? BrandAssetCatalog.image(for: agentTicks[ticker.agentIndex].asset)
                : nil
            let providerLogo = providerTicks.indices.contains(ticker.providerIndex)
                ? BrandAssetCatalog.image(for: providerTicks[ticker.providerIndex].asset)
                : nil
            let hasAgentPrefix = !agentText.isEmpty
            capsuleView?.update(
                background: .neutral,
                text: compactText,
                reservedText: reservedText,
                backgroundOpacity: CGFloat(settings.statusBarOpacityPercent / 100),
                colorScheme: settings.resolvedColorScheme,
                foregroundColor: nil,
                showsPet: false,
                indicatorColor: indicatorColor,
                waveColor: waveColor,
                showsWave: showsWave,
                cornerRatio: cornerRatio,
                providerLogo: providerLogo,
                agentLogo: agentLogo,
                hasAgentPrefix: hasAgentPrefix
            )
            if let capsuleView {
                statusItem.length = capsuleView.preferredWidth
            }

            updateHoverContent(
                button: button,
                activity: activity,
                showsWave: showsWave
            )
            synchronizeHoverPanelVisibility(for: activity, relativeTo: button)
        }

        ensureRotationTimers()
    }

    // MARK: - 刘海模式与降级模式切换

    /// 目标屏幕（显示刘海面板，无论刘海屏 / 非刘海屏）。
    /// 目标屏幕计算（无损决断：首选精准匹配 -> 外接屏智能漫游 -> 内建屏自动兜底；若首选项为 off 则严格关闭）。
    var targetScreens: [NSScreen] {
        resolveActiveScreens(from: NSScreen.screens, target: settings.notchDisplayTarget)
    }

    func resolveActiveScreens(from screens: [NSScreen], target: NotchDisplayTarget) -> [NSScreen] {
        NotchDisplayResolver.resolveActiveScreens(
            from: screens,
            target: target,
            knownDisplays: settings.knownDisplays
        )
    }

    private var isNotchDisplayEnabled: Bool {
        if case .off = settings.notchDisplayTarget { return false }
        return true
    }

    private func notchPanel(for screen: NSScreen) -> NotchCapsulePanelController {
        let panel: NotchCapsulePanelController
        if let existing = notchPanels[screen.persistentID] {
            panel = existing
        } else {
            let newPanel = NotchCapsulePanelController()
            newPanel.onClick = { [weak self] in self?.openFromNotchPanel() }
            newPanel.onOpenCurrentTask = { [weak self] in self?.openFromNotchPanel() }
            newPanel.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
            newPanel.onOpenGateway = actions.openGatewayWindow
            newPanel.onQuit = actions.quit
            newPanel.onSelectAgent = { [weak self] index in
                self?.ticker.agentIndex = index
                self?.refreshStatusTitle()
            }
            newPanel.onSelectProvider = { [weak self] connectionID in
                guard let self else { return }
                self.multiAgentSettings.selectConnection(key: connectionID)
                self.onProviderSelection?()
            }
            newPanel.onRefreshProvider = { [weak self] in
                self?.onRefreshProvider?()
            }
            newPanel.onOpenAgentTask = { tick in
                AgentTaskOpener.open(agentDisplayName: tick.name, taskID: tick.taskID)
            }
            newPanel.onAgentHover = { [weak self] hovering in
                guard let self else { return }
                if hovering {
                    self.agentCarouselDriver.pause()
                } else {
                    self.agentCarouselDriver.resume()
                }
            }
            newPanel.onProviderHover = { [weak self] hovering in
                self?.multiAgentSettings.setAccountCarouselPaused(
                    hovering,
                    source: .notch(screenNumber: screen.screenNumber)
                )
            }
            newPanel.onOpenWorkspace = { tick in
                guard let workspaceURL = tick.workspaceURL,
                      let url = URL(string: workspaceURL) else { return }
                NSLog("[StatusBarController] 打开供应商工作区: %@", url.absoluteString)
                NSWorkspace.shared.open(url)
                // 打开系统浏览器后收起刘海面板，避免面板悬停在别的应用上方。
                newPanel.setExpandedFromWorkspaceJump()
            }
            newPanel.onOffsetChanged = { [weak self] newOffset in
                self?.settings.setNotchOffset(newOffset, for: screen.persistentID)
            }
            newPanel.onToggleDragLock = { [weak self] in
                guard let self else { return }
                self.settings.notchDraggingEnabled.toggle()
            }
            newPanel.onResetCenter = { [weak self] in
                guard let self else { return }
                self.settings.resetNotchOffset(for: screen.persistentID)
                newPanel.resetToCenter(animated: true)
            }
            notchPanels[screen.persistentID] = newPanel
            panel = newPanel
        }

        let offset = settings.notchOffset(for: screen.persistentID)
        panel.setDragConfiguration(
            isBuiltin: screen.isBuiltin,
            isDraggingEnabled: settings.notchDraggingEnabled,
            xOffset: offset
        )
        return panel
    }

    private func applyMode() {
        for screen in NSScreen.screens {
            settings.recordDisplay(id: screen.persistentID, name: screen.displayName, isBuiltin: screen.isBuiltin)
        }

        let resolvedTargetScreens = targetScreens
        let targetIDs = Set(resolvedTargetScreens.map(\.persistentID))

        // 刘海面板：目标屏幕（悬停屏幕顶部中央）。
        for screen in resolvedTargetScreens {
            notchPanel(for: screen).show(on: screen)
        }
        // 清理非目标屏幕的刘海面板。
        for (id, panel) in notchPanels where !targetIDs.contains(id) {
            panel.hide()
            notchPanels.removeValue(forKey: id)
        }

        // 菜单栏胶囊：刘海开启时全局隐藏（由刘海面板取代），关闭时显示。
        // macOS 的 NSStatusItem 会复制到每块屏且预留宽度是全局共享的，无法只从刘海屏移除空隙，
        // 因此开启刘海时选择全局隐藏菜单栏胶囊。
        // Whether the user enabled the notch is a preference, not a consequence
        // of whether AppKit has finished enumerating screens. Treating an empty
        // startup snapshot as "off" leaves a clipped NSStatusItem capsule behind.
        let notchEnabled = isNotchDisplayEnabled
        statusItem.isVisible = !notchEnabled
        statusItem.button?.isHidden = notchEnabled
        if notchEnabled {
            // 胶囊已隐藏，立即收起可能残留的任务浮窗，避免悬停弹窗继续出现。
            hideHoverPanel()
        }

        scheduleNotchScreenDiscoveryRetryIfNeeded(
            notchEnabled: notchEnabled,
            resolvedTargetScreens: resolvedTargetScreens
        )

        refreshStatusTitle()
    }

    private func scheduleNotchScreenDiscoveryRetryIfNeeded(
        notchEnabled: Bool,
        resolvedTargetScreens: [NSScreen]
    ) {
        notchScreenDiscoveryRetry?.cancel()
        notchScreenDiscoveryRetry = nil

        guard notchEnabled, resolvedTargetScreens.isEmpty else {
            notchScreenDiscoveryAttempt = 0
            return
        }
        guard notchScreenDiscoveryAttempt < 12 else { return }

        notchScreenDiscoveryAttempt += 1
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.notchScreenDiscoveryRetry = nil
            self.applyMode()
        }
        notchScreenDiscoveryRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// 供设置面板在选择显示器后触发红边预览。
    func highlightScreen(_ screen: NSScreen) {
        highlightOverlay.flash(on: screen)
    }

    // MARK: - 双维度数据提取

    private func currentAgentTicks() -> [StatusBarAgentTick] {
        activityStore.snapshot.statusBarTaskTicks
    }

    private func currentProviderTicks() -> [StatusBarProviderTick] {
        var ticksByKey: [String: StatusBarProviderTick] = [:]
        for account in multiAgentSettings.codexAccounts {
            let friendlyName = GatewayStore.friendlyAccountName(
                displayName: account.usage?.accountName,
                email: account.usage?.accountEmail,
                fallbackLabel: account.label
            )
            if let tick = StatusBarProviderTickFactory.codexTick(
                id: "codex.\(account.id.rawValue.uuidString.lowercased())",
                label: account.label,
                accountName: friendlyName,
                usage: account.usage,
                isConnected: account.authenticationState == .connected
            ) {
                ticksByKey[tick.id] = tick
            }
        }
        for connection in multiAgentSettings.deepSeekConnections {
            if let tick = StatusBarProviderTickFactory.deepSeekTick(connection) {
                ticksByKey[tick.id] = tick
            }
        }
        for connection in multiAgentSettings.openCodeConnections {
            let tick = StatusBarProviderTickFactory.openCodeTick(connection)
            ticksByKey[tick.id] = tick
        }
        for connection in multiAgentSettings.geminiConnections {
            let tick = StatusBarProviderTickFactory.geminiTick(connection)
            ticksByKey[tick.id] = tick
        }
        return multiAgentSettings.orderedConnectionKeys.compactMap { ticksByKey[$0] }
    }

    // MARK: - 独立轮播

    private func ensureRotationTimers() {
        // 仅负责确保 agent 轮播驱动器已启动（幂等）。
        agentCarouselDriver.start()
    }

    func refreshProviderCarouselTimer() {
        refreshStatusTitle()
    }

    func updateNotchProviderRefreshState(_ state: NotchCapsuleViewModel.ProviderRefreshState) {
        for panel in notchPanels.values {
            panel.updateProviderRefreshState(state)
        }
    }

    /// 只有全局选中账号发生变化时，才把刘海面板的供应商显示索引同步回选中项
    /// （例如用户点击 logo，或「供应商自动轮播」开启时定时推进选中）。
    /// 「供应商自动轮播」关闭后，刘海面板的显示索引由自身轮播独立推进，
    /// 不能在被数据刷新时因选中项未变化而拉回。
    private func syncProviderIndexToSelectionIfNeeded(providerTicks: [StatusBarProviderTick]) {
        let selectedKey = multiAgentSettings.selectedConnectionKey
        guard selectedKey != lastSyncedProviderSelectionKey else {
            ticker.clampProvider(to: providerTicks.count)
            return
        }
        lastSyncedProviderSelectionKey = selectedKey

        // 当本次选中变更由自动轮播触发且刘海未开启轮播时，仅更新上次同步键，不改变刘海当前的显示索引。
        if isAutoCarouselAdvancing && !settings.notchProviderCarouselEnabled {
            ticker.clampProvider(to: providerTicks.count)
            return
        }

        if let selectedIndex = providerTicks.firstIndex(where: { $0.id == selectedKey }) {
            ticker.providerIndex = selectedIndex
        } else {
            ticker.clampProvider(to: providerTicks.count)
        }
    }

    /// 推进刘海面板自身的供应商账号轮播（仅显示轮播，不改变全局选中账号）。
    /// 连接数不足 2 个或未开启刘海轮播时返回 false，调用方无需重新计时。
    @discardableResult
    func advanceNotchProviderCarousel() -> Bool {
        guard settings.notchProviderCarouselEnabled else { return false }
        let count = currentProviderTicks().count
        guard count > 1 else { return false }
        ticker.advanceProvider(count: count)
        refreshStatusTitle()
        return true
    }

    private func advanceAgentTick() {
        // 悬停暂停已由 AgentCarouselDriver 的 pause/resume 处理，这里只需推进任务页。
        let count = currentAgentTicks().count
        guard count > 1 else { return }
        ticker.advanceAgent(count: count)
        refreshStatusTitle()
    }

    private func refreshPetFrame() {
        // Hover always shows the selected Pet. The retired visibility toggle
        // must not leave existing users with the placeholder icon.
        let image = frameStore.currentFrame
        image?.isTemplate = false
        hoverPanel.updatePetFrame(image)
    }

    private func updateHoverContent(
        button: NSStatusBarButton,
        activity: CodexActivitySnapshot,
        showsWave: Bool
    ) {
        guard store.isLoggedIn || activity.keepsHoverPanelVisible else {
            let connectedLabels = multiAgentSettings.deepSeekConnections.map(\.label)
                + multiAgentSettings.codexAccounts.map(\.label)
                + multiAgentSettings.openCodeConnections.map(\.label)
                + multiAgentSettings.geminiConnections.map(\.label)
            if connectedLabels.isEmpty {
                hoverPanel.update(
                    title: "尚未连接账号",
                    detail: "登录 Codex 或添加 API Key 后，即可查看用量",
                    meta: "点击打开窗口",
                    showsWave: false
                )
            } else {
                let providerText = connectedLabels.count == 1
                    ? connectedLabels[0]
                    : "\(connectedLabels.count) 个供应商"
                hoverPanel.update(
                    title: "已连接 \(providerText)",
                    detail: "可查看余额与用量",
                    meta: "点击打开窗口查看详情",
                    showsWave: false
                )
            }
            button.toolTip = nil
            return
        }

        let countText = activity.activeTaskCount > 0
            ? "\(activity.activeTaskCount) 个活跃任务"
            : "没有活跃任务"
        let stateText = activity.state.statusBarText ?? "空闲"
        hoverPanel.update(
            title: activity.hoverDisplayTitle,
            detail: activity.hoverSubtitle,
            meta: "\(stateText) · \(countText)",
            showsWave: showsWave
        )
        button.toolTip = nil
    }

    private func synchronizeHoverPanelVisibility(
        for activity: CodexActivitySnapshot,
        relativeTo button: NSStatusBarButton
    ) {
        taskHoverPresentation.update(hasActiveTasks: activity.keepsHoverPanelVisible)
        hoverPanel.setTaskActive(taskHoverPresentation.hasActiveTasks)
        // 任务浮窗固定策略：不自动展开，仅悬停胶囊时显示，位置跟随当前高亮显示器。
        let shouldKeepVisible = taskHoverPresentation.shouldAutoPresent(isEnabled: false)

        if shouldKeepVisible {
            pendingHoverWorkItem?.cancel()
            pendingHoverWorkItem = nil
            cancelHoverPanelHide()
            let preferredScreen = button.window?.screen
            hoverPanel.show(
                relativeTo: button,
                preferredScreen: preferredScreen,
                alignsToScreenTopTrailing: false
            )
        } else if isKeepingTaskHoverVisible {
            hideHoverPanel()
        }
        isKeepingTaskHoverVisible = shouldKeepVisible
    }

    private func scheduleHoverPanel() {
        // 刘海开启时状态栏胶囊已隐藏，悬停不应再弹出任务浮窗。
        guard statusItem.isVisible else { return }
        pendingHoverWorkItem?.cancel()
        cancelHoverPanelHide()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let button = self.statusItem.button else { return }
            self.hoverPanel.show(relativeTo: button)
        }
        pendingHoverWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    private func hideHoverPanel() {
        pendingHoverWorkItem?.cancel()
        pendingHoverWorkItem = nil
        cancelHoverPanelHide()
        hoverPanel.hide()
    }

    private func hideHoverPanelUnlessTaskIsActive() {
        guard !isKeepingTaskHoverVisible else { return }
        hideHoverPanel()
    }

    private func scheduleHoverPanelHide(
        from departurePoint: NSPoint? = nil,
        toward targetFrame: NSRect? = nil
    ) {
        guard !isKeepingTaskHoverVisible else { return }

        if let departurePoint, let targetFrame, hoverPanel.isVisible {
            beginSafeTriangleTracking(from: departurePoint, toward: targetFrame)
            return
        }

        pendingHoverWorkItem?.cancel()
        pendingHoverWorkItem = nil
        pendingHoverHideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingHoverHideWorkItem = nil
            guard !self.pointerIsInsidePersistentHoverRegion() else { return }
            self.hoverPanel.hide()
        }
        pendingHoverHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }

    private func cancelHoverPanelHide() {
        pendingHoverHideWorkItem?.cancel()
        pendingHoverHideWorkItem = nil
        hoverSafeTriangleTimer?.invalidate()
        hoverSafeTriangleTimer = nil
        hoverSafeTriangle = nil
        hoverSafeTriangleDeadline = nil
    }

    private func beginSafeTriangleTracking(from departurePoint: NSPoint, toward targetFrame: NSRect) {
        cancelHoverPanelHide()
        hoverSafeTriangle = HoverSafeTriangle(
            origin: departurePoint,
            targetFrame: targetFrame,
            buffer: 8
        )
        // Avoid keeping the card alive forever if the pointer stops in the gap.
        hoverSafeTriangleDeadline = Date().addingTimeInterval(2)
        let timer = Timer(
            timeInterval: 1.0 / 60.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateSafeTrianglePointer()
            }
        }
        hoverSafeTriangleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func evaluateSafeTrianglePointer() {
        guard !isKeepingTaskHoverVisible else { return }

        let pointer = NSEvent.mouseLocation
        if pointerIsInsidePersistentHoverRegion(pointer) {
            return
        }

        if let hoverSafeTriangle,
           let hoverSafeTriangleDeadline,
           Date() < hoverSafeTriangleDeadline,
           hoverSafeTriangle.contains(pointer) {
            return
        }

        hideHoverPanel()
    }

    private func pointerIsInsidePersistentHoverRegion(
        _ pointer: NSPoint = NSEvent.mouseLocation
    ) -> Bool {
        if hoverPanel.isVisible, hoverPanel.interactionFrame.contains(pointer) {
            return true
        }

        return statusCapsuleScreenFrame?.contains(pointer) == true
    }

    private var statusCapsuleScreenFrame: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        let rectInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(rectInWindow)
    }

}

func statusBarQuotaText(snapshot: CodexUsageSnapshot, isLoggedIn: Bool) -> String {
    guard isLoggedIn else { return "未登录" }

    guard snapshot.hasShortWindow || snapshot.hasWeeklyWindow else { return "无额度" }

    if snapshot.hasShortWindow {
        let primaryText = "\(statusBarWindowLabel(snapshot.primaryWindow.label)) \(snapshot.primaryWindow.percentText)"
        return snapshot.hasWeeklyWindow
            ? "\(primaryText)·\(statusBarWindowLabel(snapshot.weekly.label)) \(snapshot.weekly.percentText)"
            : primaryText
    }

    return "\(statusBarWindowLabel(snapshot.weekly.label)) \(snapshot.weekly.percentText)"
}

func statusCapsuleReservedText(
    snapshot: CodexUsageSnapshot,
    isLoggedIn: Bool,
    showsActivity: Bool
) -> String {
    let quotaText: String
    if !isLoggedIn {
        quotaText = "未登录"
    } else if !snapshot.hasShortWindow && !snapshot.hasWeeklyWindow {
        quotaText = "无额度"
    } else if snapshot.hasShortWindow {
        let primaryText = "\(statusBarWindowLabel(snapshot.primaryWindow.label)) 99%"
        quotaText = snapshot.hasWeeklyWindow
            ? "\(primaryText)·\(statusBarWindowLabel(snapshot.weekly.label)) 99%"
            : primaryText
    } else {
        quotaText = "\(statusBarWindowLabel(snapshot.weekly.label)) 99%"
    }

    // Active labels use a compact three-CJK-character vocabulary. Reserving a
    // representative label keeps state transitions stable without leaving a
    // conspicuous empty tail.
    return showsActivity ? "思考中·\(quotaText)" : quotaText
}

func statusBarWindowLabel(_ label: String) -> String {
    switch label {
    case "5 小时":
        "5h"
    case "周额度":
        "周"
    default:
        label.replacingOccurrences(of: " ", with: "")
    }
}

struct HoverSafeTriangle {
    private let corners: [CGPoint]
    private let expandedTarget: CGRect

    init(origin: CGPoint, targetFrame: CGRect, buffer: CGFloat = 0) {
        let expandedTarget = targetFrame.insetBy(dx: -buffer, dy: -buffer)
        self.expandedTarget = expandedTarget

        if targetFrame.midY < origin.y {
            // Target is below: create a buffered trapezoid to its upper edge.
            corners = [
                CGPoint(x: origin.x - buffer, y: origin.y + buffer),
                CGPoint(x: origin.x + buffer, y: origin.y + buffer),
                CGPoint(x: expandedTarget.maxX, y: expandedTarget.maxY),
                CGPoint(x: expandedTarget.minX, y: expandedTarget.maxY)
            ]
        } else {
            // Target is above: mirror the same buffered corridor upward.
            corners = [
                CGPoint(x: origin.x - buffer, y: origin.y - buffer),
                CGPoint(x: expandedTarget.minX, y: expandedTarget.minY),
                CGPoint(x: expandedTarget.maxX, y: expandedTarget.minY),
                CGPoint(x: origin.x + buffer, y: origin.y - buffer)
            ]
        }
    }

    func contains(_ point: CGPoint) -> Bool {
        if expandedTarget.contains(point) { return true }

        var hasNegative = false
        var hasPositive = false
        for index in corners.indices {
            let first = corners[index]
            let second = corners[(index + 1) % corners.count]
            let area = signedArea(point, first, second)
            hasNegative = hasNegative || area < 0
            hasPositive = hasPositive || area > 0
            if hasNegative && hasPositive { return false }
        }
        return true
    }

    private func signedArea(_ point: CGPoint, _ first: CGPoint, _ second: CGPoint) -> CGFloat {
        (point.x - second.x) * (first.y - second.y)
            - (first.x - second.x) * (point.y - second.y)
    }
}

struct TaskHoverPresentationState {
    private(set) var hasActiveTasks = false
    private(set) var isDismissed = false

    mutating func update(hasActiveTasks: Bool) {
        if !hasActiveTasks {
            isDismissed = false
        } else if !self.hasActiveTasks {
            isDismissed = false
        }
        self.hasActiveTasks = hasActiveTasks
    }

    mutating func dismiss() {
        guard hasActiveTasks else { return }
        isDismissed = true
    }

    func shouldAutoPresent(isEnabled: Bool) -> Bool {
        hasActiveTasks && isEnabled && !isDismissed
    }
}

enum PetHoverCloseButtonLayout {
    static let size: CGFloat = 26
    static let edgeInset: CGFloat = 10
    static let activeContentTrailingPadding = size + edgeInset * 2

    static func frame(in cardSize: NSSize) -> NSRect {
        NSRect(
            x: cardSize.width - edgeInset - size,
            y: cardSize.height - edgeInset - size,
            width: size,
            height: size
        )
    }
}

enum StatusPetBadgeRenderer {
    // Match the 22pt macOS status bar for a zero-inset comparison.
    static let size = NSSize(width: 22, height: 22)

    static func render(_ petImage: NSImage, cornerRatio: CGFloat = 0.5) -> NSImage {
        let result = NSImage(size: size)
        result.lockFocus()
        defer { result.unlockFocus() }

        let resolvedCornerRatio = min(max(cornerRatio, 0.2), 0.5)
        let badgeRect = NSRect(origin: .zero, size: size).insetBy(dx: 0.25, dy: 0.25)
        let badgePath = NSBezierPath(
            roundedRect: badgeRect,
            xRadius: badgeRect.height * resolvedCornerRatio,
            yRadius: badgeRect.height * resolvedCornerRatio
        )
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.08)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        NSColor.white.withAlphaComponent(0.72).setFill()
        badgePath.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.48).setStroke()
        badgePath.lineWidth = 0.6
        badgePath.stroke()

        NSGraphicsContext.current?.imageInterpolation = .none
        let maxPetSize = NSSize(width: 16, height: 15)
        let scale = min(
            maxPetSize.width / max(petImage.size.width, 1),
            maxPetSize.height / max(petImage.size.height, 1)
        )
        let petSize = NSSize(
            width: petImage.size.width * scale,
            height: petImage.size.height * scale
        )
        // Center the complete source frame without compensating for transparent
        // pixels inside an individual Pet asset.
        let petRect = centeredRect(
            contentSize: petSize,
            in: NSRect(origin: .zero, size: size)
        )
        NSBezierPath(
            roundedRect: petRect,
            xRadius: min(petRect.width, petRect.height) * resolvedCornerRatio,
            yRadius: min(petRect.width, petRect.height) * resolvedCornerRatio
        ).addClip()
        petImage.draw(in: petRect, from: .zero, operation: .sourceOver, fraction: 1)
        result.isTemplate = false
        return result
    }

    static func centeredRect(contentSize: NSSize, in container: NSRect) -> NSRect {
        NSRect(
            x: container.midX - contentSize.width / 2,
            y: container.midY - contentSize.height / 2,
            width: contentSize.width,
            height: contentSize.height
        )
    }
}

private let statusCapsuleProviderLogoPlaceholderWidth: CGFloat = 13 + 4

private func statusCapsuleLogoRunDelegateDealloc(pointer: UnsafeMutableRawPointer) {}
private func statusCapsuleLogoRunDelegateGetAscent(pointer: UnsafeMutableRawPointer) -> CGFloat { 0 }
private func statusCapsuleLogoRunDelegateGetDescent(pointer: UnsafeMutableRawPointer) -> CGFloat { 0 }
private func statusCapsuleLogoRunDelegateGetWidth(pointer: UnsafeMutableRawPointer) -> CGFloat {
    statusCapsuleProviderLogoPlaceholderWidth
}

final class StatusCapsuleView: NSView {
    private static let leadingPadding: CGFloat = 7.5
    private static let indicatorTextGap: CGFloat = 8
    private static let trailingPadding: CGFloat = 10
    private static let inlineContentGap: CGFloat = 4
    private static let dotSize: CGFloat = 8
    private static let capsuleHeight: CGFloat = 24
    private static let providerLogoSize: CGFloat = 13
    private static let agentLogoSize: CGFloat = 14
    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    private static let activityFlowPresentation =
        ActivityCapsuleWavePresentation.rotatingBorder(lineWidth: 2)

    var onClick: (() -> Void)?
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    var petImage: NSImage? {
        didSet { invalidateCapsuleDisplay() }
    }
    /// 当前 agent 的品牌 logo（降级胶囊左侧指示位，替代状态圆点）。
    var agentLogo: NSImage? {
        didSet { invalidateCapsuleDisplay() }
    }

    private var background = StatusBarPetBackgroundColor.neutral
    private var colorScheme = ColorScheme.light
    private var text = ""
    private var reservedText = ""
    private var backgroundOpacity: CGFloat = 0.20
    private var foregroundColor: NSColor?
    private var showsPet = true
    private var indicatorColor: NSColor?
    private var waveColor: NSColor?
    private var showsWave = false
    private var cornerRatio: CGFloat = 0.5
    /// 额度前展示的供应商 logo（降级胶囊用）。
    private var providerLogo: NSImage?
    private var hasAgentPrefix = false
    private var isTrackingPress = false
    private var lastClickTimestamp: TimeInterval = -.infinity
    private var trackingAreaReference: NSTrackingArea?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var pointerWasInsideCapsule = false
    private var waveTimer: Timer?
    var activityWaveProgressForTesting: CGFloat?
    private var materialRipples: [CapsuleMaterialRipple] = []
    private var materialRippleTimer: Timer?

    var preferredWidth: CGFloat {
        let textWidth = ceil(max(attributedText.size().width, attributedReservedText.size().width))
        return textLeadingOffset
            + textWidth
            + Self.trailingPadding
    }

    /// 从胶囊左边缘到文本起点的总偏移（指示器 + 指示器与文本的间距）。
    private var textLeadingOffset: CGFloat {
        if agentLogo != nil {
            // [圆灯 8] [4] [logo 14] [4] → 文本，logo 左右 margin 与供应商 logo 一致（4pt）。
            return indicatorPadding
                + Self.dotSize
                + Self.inlineContentGap
                + Self.agentLogoSize
                + Self.inlineContentGap
        }
        if showsPet, petImage != nil {
            return indicatorPadding + StatusPetBadgeRenderer.size.width + Self.indicatorTextGap
        }
        return indicatorPadding + Self.dotSize + Self.indicatorTextGap
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Status-bar buttons do not reliably forward hover and press events to
        // a click-through subview. Keep the capsule as the event target so its
        // tracking area and mouse handlers work even while the app is inactive.
        bounds.contains(point) ? self : nil
    }

    var usesThemeLockedNeutralSurfaceForTesting: Bool {
        true
    }

    var activeMaterialRippleCountForTesting: Int {
        materialRipples.count
    }

    var activityFlowPresentationForTesting: ActivityCapsuleWavePresentation {
        Self.activityFlowPresentation
    }

    func update(
        background: StatusBarPetBackgroundColor,
        text: String,
        reservedText: String,
        backgroundOpacity: CGFloat = 0.20,
        colorScheme: ColorScheme = .light,
        foregroundColor: NSColor?,
        showsPet: Bool,
        indicatorColor: NSColor?,
        waveColor: NSColor? = nil,
        showsWave: Bool,
        cornerRatio: CGFloat,
        providerLogo: NSImage? = nil,
        agentLogo: NSImage? = nil,
        hasAgentPrefix: Bool = false
    ) {
        self.background = background
        self.colorScheme = colorScheme
        self.text = text
        self.reservedText = reservedText
        self.backgroundOpacity = min(max(backgroundOpacity, 0), 1)
        self.foregroundColor = foregroundColor
        self.showsPet = showsPet
        self.indicatorColor = indicatorColor
        self.waveColor = waveColor
        self.providerLogo = providerLogo
        self.agentLogo = agentLogo
        self.hasAgentPrefix = hasAgentPrefix
        let waveVisibilityChanged = self.showsWave != showsWave
        self.showsWave = showsWave
        self.cornerRatio = min(max(cornerRatio, 0.2), 0.5)
        if waveVisibilityChanged {
            updateWaveAnimation()
        }
        setAccessibilityLabel("Codex \(text)")
        invalidateCapsuleDisplay()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let outerRect = NSRect(
            x: 0.25,
            y: bounds.midY - Self.capsuleHeight / 2 + 0.25,
            width: max(0, bounds.width - 0.5),
            height: Self.capsuleHeight - 0.5
        )
        let outerPath = NSBezierPath(
            roundedRect: outerRect,
            xRadius: outerRect.height * cornerRatio,
            yRadius: outerRect.height * cornerRatio
        )
        drawNeutralSurface(in: outerPath)
        drawMaterialRipples(clippedTo: outerPath)
        drawWave()

        if let agentLogo {
            // 圆灯保持原位置与尺寸，logo 插在圆灯右侧和文本之间，左右 margin 与供应商 logo 一致。
            drawStatusDot(centerX: indicatorPadding + Self.dotSize / 2, size: Self.dotSize)
            let logoX = indicatorPadding + Self.dotSize + Self.inlineContentGap
            let logoRect = NSRect(
                x: logoX,
                y: (bounds.height - Self.agentLogoSize) / 2,
                width: Self.agentLogoSize,
                height: Self.agentLogoSize
            )
            agentLogo.draw(in: logoRect, from: .zero, operation: .sourceOver, fraction: 1)
        } else if showsPet, let petImage {
            let imageRect = NSRect(
                x: indicatorPadding,
                y: bounds.midY - StatusPetBadgeRenderer.size.height / 2,
                width: StatusPetBadgeRenderer.size.width,
                height: StatusPetBadgeRenderer.size.height
            )
            petImage.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            drawStatusDot(centerX: indicatorPadding + Self.dotSize / 2, size: Self.dotSize)
        }

        let title = attributedText
        let line = CTLineCreateWithAttributedString(title)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        if let context = NSGraphicsContext.current?.cgContext {
            let imageBounds = CTLineGetImageBounds(line, context)
            let visualMidY = imageBounds.isNull || imageBounds.height <= 0
                ? (ascent - descent) / 2
                : imageBounds.midY
            let unsnappedBaselineY = bounds.midY - visualMidY
            let backingScale = window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 2
            let baselineY = (unsnappedBaselineY * backingScale).rounded() / backingScale

            context.saveGState()
            context.textMatrix = .identity
            context.textPosition = CGPoint(
                x: textLeadingOffset,
                y: baselineY
            )
            CTLineDraw(line, context)
            context.restoreGState()

            // CTLineDraw 不会渲染 NSTextAttachment 的图片，这里手动画供应商 logo（垂直居中）。
            if let logo = providerLogo {
                let textStartX = textLeadingOffset
                let insertIndex = providerLogoInsertIndex(in: text, hasPrefix: hasAgentPrefix)
                let safeIndex = max(0, min(insertIndex, (text as NSString).length))
                let offset = CTLineGetOffsetForStringIndex(line, safeIndex, nil)
                let logoRect = NSRect(
                    x: textStartX + offset,
                    y: (bounds.height - Self.providerLogoSize) / 2,
                    width: Self.providerLogoSize,
                    height: Self.providerLogoSize
                )
                logo.draw(in: logoRect, from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
    }

    /// 画状态圆灯（不同颜色表达不同状态），带一圈淡白 halo 保证在透明胶囊上可见。
    private func drawStatusDot(centerX: CGFloat, size: CGFloat) {
        let dotRect = NSRect(
            x: centerX - size / 2,
            y: (bounds.height - size) / 2,
            width: size,
            height: size
        )
        let haloPath = NSBezierPath(ovalIn: dotRect.insetBy(dx: -1.2, dy: -1.2))
        NSColor.white.withAlphaComponent(0.58).setFill()
        haloPath.fill()

        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = NSColor.white.withAlphaComponent(0.72)
        glow.shadowBlurRadius = 2.2
        glow.shadowOffset = .zero
        glow.set()
        (indicatorColor ?? NSColor.secondaryLabelColor).setFill()
        let dotPath = NSBezierPath(ovalIn: dotRect)
        dotPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.88).setStroke()
        dotPath.lineWidth = 0.7
        dotPath.stroke()
    }

    private func invalidateCapsuleDisplay() {
        needsDisplay = true
    }

    private func drawNeutralSurface(in outerPath: NSBezierPath) {
        // A single translucent neutral fill keeps the wallpaper visible
        // without introducing a gradient, reflection, or glass-like shading.
        NSColor.white.withAlphaComponent(backgroundOpacity).setFill()
        outerPath.fill()
    }

    private var attributedText: NSAttributedString {
        attributedText(for: text, hasPrefix: hasAgentPrefix)
    }

    private var attributedReservedText: NSAttributedString {
        let hasReservedPrefix = reservedText.hasPrefix("思考中·")
        return attributedText(for: reservedText, hasPrefix: hasReservedPrefix)
    }

    /// 供应商 logo 在文本中的插入位置：有 agent 前缀时在「·」之后，否则在开头。
    private func providerLogoInsertIndex(in targetText: String, hasPrefix: Bool) -> Int {
        guard hasPrefix else { return 0 }
        let source = targetText as NSString
        let separator = source.range(of: "·")
        guard separator.location != NSNotFound else { return 0 }
        return separator.location + 1
    }

    private func attributedText(for text: String, hasPrefix: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: text,
            attributes: [
                .foregroundColor: foregroundColor ?? automaticForegroundColor,
                .font: Self.font
            ]
        )
        let source = text as NSString
        var searchRange = NSRange(location: 0, length: source.length)
        while searchRange.length > 0 {
            let separator = source.range(of: "·", options: [], range: searchRange)
            guard separator.location != NSNotFound else { break }

            if separator.location > 0 {
                let precedingCharacter = source.rangeOfComposedCharacterSequence(
                    at: separator.location - 1
                )
                result.addAttribute(.kern, value: Self.inlineContentGap, range: precedingCharacter)
            }
            result.addAttribute(.kern, value: Self.inlineContentGap, range: separator)

            let nextLocation = NSMaxRange(separator)
            searchRange = NSRange(location: nextLocation, length: source.length - nextLocation)
        }

        // 在额度文本前插入对应供应商 logo：有 agent 前缀时插在「·」之后，否则插在开头。
        // 用 CTRunDelegate 精确预留「logo 宽度 + 右侧间距」，保证左右 margin 对称。
        if providerLogo != nil {
            let insertIndex = providerLogoInsertIndex(in: text, hasPrefix: hasPrefix)
            let safeIndex = max(0, min(insertIndex, result.length))
            result.insert(Self.logoPlaceholderString(), at: safeIndex)
        }
        return result
    }

    private var automaticForegroundColor: NSColor {
        Self.automaticMenuBarForegroundColor(appearance: effectiveAppearance)
    }

    static func automaticMenuBarForegroundColor(appearance: NSAppearance) -> NSColor {
        // The menu bar exposes vibrant appearances that already account for
        // wallpaper and full-screen content. Resolve only the foreground from
        // that appearance; opting the entire custom view into vibrancy would
        // also re-composite the translucent capsule surface on every redraw.
        switch appearance.bestMatch(
            from: [.vibrantDark, .darkAqua, .vibrantLight, .aqua]
        ) {
        case .vibrantDark, .darkAqua:
            return .white
        default:
            return .black
        }
    }

    private var indicatorPadding: CGFloat {
        if showsPet, petImage != nil {
            // Match the leading inset to the centered top and bottom insets.
            return max(0, (bounds.height - StatusPetBadgeRenderer.size.height) / 2)
        }
        return Self.leadingPadding
    }

    /// 用 CTRunDelegate 预留 logo 占位宽度（logo 宽 + 右侧 `inlineContentGap`）。
    /// CTLine 不识别 NSTextAttachment 的宽度，必须用 run delegate 才能精确排版。
    static let providerLogoPlaceholderWidth: CGFloat = providerLogoSize + inlineContentGap

    private static let logoPlaceholderAttributedString: NSAttributedString = {
        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateVersion1,
            dealloc: statusCapsuleLogoRunDelegateDealloc,
            getAscent: statusCapsuleLogoRunDelegateGetAscent,
            getDescent: statusCapsuleLogoRunDelegateGetDescent,
            getWidth: statusCapsuleLogoRunDelegateGetWidth
        )
        guard let runDelegate = CTRunDelegateCreate(&callbacks, nil) else {
            return NSAttributedString(string: "")
        }
        return NSAttributedString(
            string: "\u{FFFC}",
            attributes: [
                NSAttributedString.Key(kCTRunDelegateAttributeName as String): runDelegate
            ]
        )
    }()

    private static func logoPlaceholderString() -> NSAttributedString {
        logoPlaceholderAttributedString
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopMaterialRippleTimer()
            materialRipples.removeAll()
            removeMouseMonitors()
        } else {
            installMouseMonitors()
            updateMonitoredHoverState()
        }
        updateWaveAnimation()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidateCapsuleDisplay()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    private func updateWaveAnimation() {
        waveTimer?.invalidate()
        waveTimer = nil

        guard showsWave, window != nil else {
            invalidateCapsuleDisplay()
            return
        }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            invalidateCapsuleDisplay()
            return
        }

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.invalidateCapsuleDisplay()
            }
        }
        waveTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func drawWave() {
        guard showsWave else { return }

        let presentation = Self.activityFlowPresentation
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let progress: CGFloat
        if reducedMotion {
            progress = 0.5
        } else if let activityWaveProgressForTesting {
            progress = min(1, max(0, activityWaveProgressForTesting))
        } else {
            progress = presentation.progress(
                at: Date.timeIntervalSinceReferenceDate
            )
        }

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        ActivityCapsuleWaveRenderer.draw(
            in: context,
            containerBounds: bounds,
            capsuleRect: NSRect(
                x: 0.25,
                y: bounds.midY - Self.capsuleHeight / 2 + 0.25,
                width: max(0, bounds.width - 0.5),
                height: Self.capsuleHeight - 0.5
            ),
            cornerRatio: cornerRatio,
            ink: waveColor ?? materialInkColor,
            progress: progress,
            presentation: presentation,
            // AppKit uses an upward-positive Y axis; negate the conic angle so
            // the visible motion matches SwiftUI's clockwise border flow.
            rotationDirection: -1
        )
    }

    private func drawMaterialRipples(clippedTo outerPath: NSBezierPath) {
        guard !materialRipples.isEmpty else { return }

        let now = ProcessInfo.processInfo.systemUptime
        materialRipples.removeAll { now - $0.startTime >= CapsuleMaterialRipple.lifetime }
        guard !materialRipples.isEmpty else {
            stopMaterialRippleTimer()
            return
        }

        let diameter = hypot(bounds.width, bounds.height) * 2.05

        NSGraphicsContext.saveGraphicsState()
        outerPath.addClip()

        for ripple in materialRipples {
            let elapsed = now - ripple.startTime
            let expandLinear = min(1, max(0, elapsed / CapsuleMaterialRipple.expandDuration))
            let fadeLinear = min(
                1,
                max(0, (elapsed - CapsuleMaterialRipple.fadeDelay) / CapsuleMaterialRipple.fadeDuration)
            )
            let fadeEased = fadeLinear * fadeLinear
            let opacity = 1.0 - fadeEased

            drawMaterialRipple(
                at: ripple.origin,
                expandProgress: CGFloat(expandLinear),
                opacity: CGFloat(opacity),
                diameter: diameter
            )
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawMaterialRipple(
        at origin: NSPoint,
        expandProgress: CGFloat,
        opacity: CGFloat,
        diameter: CGFloat
    ) {
        let clampedProgress = min(1, max(0, expandProgress))
        let expandEased = 1 - pow(1 - clampedProgress, 3)
        let scale = 0.04 + 0.96 * expandEased
        let size = diameter * scale
        let rect = NSRect(
            x: origin.x - size / 2,
            y: origin.y - size / 2,
            width: size,
            height: size
        )
        let ink = materialInkColor
        ink.withAlphaComponent(
            ink.alphaComponent * min(1, max(0, opacity))
        ).setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    private var materialInkColor: NSColor {
        colorScheme == .dark
            ? NSColor.white.withAlphaComponent(0.18)
            : NSColor.black.withAlphaComponent(0.10)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseEntered(with event: NSEvent) {
        setMonitoredHoverState(isInside: true)
    }

    override func mouseExited(with event: NSEvent) {
        setMonitoredHoverState(isInside: false)
    }

    override func mouseDown(with event: NSEvent) {
        beginPress(at: locationInView(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        finishPress(shouldClick: isPointerInside(for: event), timestamp: event.timestamp)
    }

    override func accessibilityPerformPress() -> Bool {
        beginPress(at: NSPoint(x: bounds.midX, y: bounds.midY))
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.finishPress(
                shouldClick: true,
                timestamp: ProcessInfo.processInfo.systemUptime
            )
        }
        return true
    }

    /// NSStatusBarButton often swallows subview mouseDown. A local monitor still
    /// sees the press so the material wave can start on click.
    private func installMouseMonitors() {
        guard localMouseMonitor == nil else { return }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .mouseMoved, .leftMouseDragged]
        ) { [weak self] event in
            self?.handleLocalMouseEvent(event)
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateMonitoredHoverState()
            }
        }
    }

    private func removeMouseMonitors() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        pointerWasInsideCapsule = false
    }

    private func handleLocalMouseEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            guard isPointerInside(for: event) else { return }
            beginPress(at: locationInView(for: event))
        case .leftMouseUp:
            guard isTrackingPress else { return }
            finishPress(
                shouldClick: isPointerInside(for: event),
                timestamp: event.timestamp
            )
        case .mouseMoved, .leftMouseDragged:
            updateMonitoredHoverState()
        default:
            break
        }
    }

    private func updateMonitoredHoverState() {
        guard let window else { return }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let localPoint = convert(windowPoint, from: nil)
        setMonitoredHoverState(isInside: bounds.contains(localPoint))
    }

    private func setMonitoredHoverState(isInside: Bool) {
        guard pointerWasInsideCapsule != isInside else { return }
        pointerWasInsideCapsule = isInside
        if isInside {
            onMouseEntered?()
        } else {
            onMouseExited?()
        }
    }

    private func isPointerInside(for event: NSEvent) -> Bool {
        bounds.contains(locationInView(for: event))
    }

    private func locationInView(for event: NSEvent) -> NSPoint {
        let screenPoint: NSPoint
        if let eventWindow = event.window {
            screenPoint = eventWindow.convertPoint(toScreen: event.locationInWindow)
        } else {
            screenPoint = NSEvent.mouseLocation
        }
        guard let window else { return .zero }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        return convert(windowPoint, from: nil)
    }

    private func beginPress(at location: NSPoint) {
        guard !isTrackingPress else { return }
        isTrackingPress = true
        spawnMaterialRipple(at: location)
    }

    private func finishPress(shouldClick: Bool, timestamp: TimeInterval) {
        guard isTrackingPress else { return }
        isTrackingPress = false
        if shouldClick {
            performClick(timestamp: timestamp)
        }
    }

    private func performClick(timestamp: TimeInterval) {
        // mouseUp override and the local monitor can both observe one click.
        guard timestamp - lastClickTimestamp > 0.08 else { return }
        lastClickTimestamp = timestamp
        onClick?()
    }

    private func spawnMaterialRipple(at location: NSPoint) {
        materialRipples.append(
            CapsuleMaterialRipple(
                origin: location,
                startTime: ProcessInfo.processInfo.systemUptime
            )
        )
        startMaterialRippleTimer()
        display()
        CATransaction.flush()
    }

    private func startMaterialRippleTimer() {
        guard materialRippleTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickMaterialRipples()
            }
        }
        materialRippleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tickMaterialRipples() {
        let now = ProcessInfo.processInfo.systemUptime
        materialRipples.removeAll { now - $0.startTime >= CapsuleMaterialRipple.lifetime }
        invalidateCapsuleDisplay()
        if materialRipples.isEmpty {
            stopMaterialRippleTimer()
            display()
        }
    }

    private func stopMaterialRippleTimer() {
        materialRippleTimer?.invalidate()
        materialRippleTimer = nil
    }
}

private struct CapsuleMaterialRipple {
    static let expandDuration: TimeInterval = 0.68
    static let fadeDelay: TimeInterval = 0.18
    static let fadeDuration: TimeInterval = 0.50
    static let lifetime: TimeInterval = 0.74

    let origin: NSPoint
    let startTime: TimeInterval
}

private final class PetHoverPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // AppKit normally keeps the complete panel inside visibleFrame. This
        // panel includes a transparent shadow canvas. Constraining that canvas
        // would add a shadowInset-sized visual gap at the top and right edges,
        // so the controller constrains the visible card instead.
        frameRect
    }
}

@MainActor
private final class PetHoverPanelController {
    private static let cardSize = NSSize(width: 340, height: 112)
    private static let shadowInset: CGFloat = 20
    private static let cardEdgeGap: CGFloat = 4
    private static let anchoredPanelEdgeGap: CGFloat = 8
    private let panel: NSPanel
    private let model = PetHoverViewModel()

    var onMouseEntered: (() -> Void)? {
        get { model.onMouseEntered }
        set { model.onMouseEntered = newValue }
    }

    var onMouseExited: (() -> Void)? {
        get { model.onMouseExited }
        set { model.onMouseExited = newValue }
    }

    var onClick: (() -> Void)? {
        get { model.onClick }
        set { model.onClick = newValue }
    }

    var onClose: (() -> Void)? {
        get { model.onClose }
        set { model.onClose = newValue }
    }

    var isVisible: Bool { panel.isVisible }

    var interactionFrame: NSRect {
        panel.frame.insetBy(dx: Self.shadowInset, dy: Self.shadowInset)
    }

    init() {
        let panelSize = NSSize(
            width: Self.cardSize.width + Self.shadowInset * 2,
            height: Self.cardSize.height + Self.shadowInset * 2
        )
        panel = PetHoverPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        // Keep the hover card above normal windows but below the menu bar.
        // Its transparent shadow region can overlap the status item; using the
        // status-bar level would intermittently intercept capsule clicks.
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The system shadow follows the rectangular panel bounds and leaves dark,
        // square corners around a rounded visual-effect view. Draw one controlled
        // shadow around the rounded card instead.
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.transient, .canJoinAllSpaces, .fullScreenAuxiliary]

        let hoverView = PetHoverContentView(
            model: model,
            cardSize: Self.cardSize,
            shadowInset: Self.shadowInset
        )
        let hostingView = NSHostingView(rootView: hoverView)
        hostingView.frame = NSRect(origin: .zero, size: panelSize)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
    }

    func update(title: String, detail: String, meta: String, showsWave: Bool) {
        model.title = title
        model.detail = detail
        model.meta = meta
        model.showsWave = showsWave
    }

    func updatePetFrame(_ image: NSImage?) {
        model.petFrame = image
    }

    func setTaskActive(_ isActive: Bool) {
        model.isTaskActive = isActive
    }

    func show(
        relativeTo button: NSStatusBarButton,
        preferredScreen: NSScreen? = nil,
        alignsToScreenTopTrailing: Bool = false
    ) {
        guard let window = button.window else { return }
        let rectInWindow = button.convert(button.bounds, to: nil)
        let anchor = window.convertToScreen(rectInWindow)
        let size = panel.frame.size
        let sourceScreen = window.screen
        let targetScreen = preferredScreen ?? sourceScreen ?? NSScreen.main
        let screenFrame = targetScreen?.visibleFrame ?? .zero
        let usesAnchor = !alignsToScreenTopTrailing && targetScreen === sourceScreen
        let x: CGFloat
        if usesAnchor {
            let proposedX = anchor.midX - size.width / 2
            x = min(
                max(proposedX, screenFrame.minX + Self.anchoredPanelEdgeGap),
                screenFrame.maxX - size.width - Self.anchoredPanelEdgeGap
            )
        } else {
            // Position the visible card, not its transparent shadow canvas, so
            // its right gap matches the top gap exactly.
            x = screenFrame.maxX
                - Self.cardEdgeGap
                - Self.cardSize.width
                - Self.shadowInset
        }
        // Anchor the visible card—not its transparent shadow canvas—to the
        // actual menu-bar edge. The status button's local vertical bounds can
        // vary by OS version and previously produced a much larger visual gap.
        let menuBarBottom = usesAnchor
            ? window.frame.minY
            : screenFrame.maxY
        let y = menuBarBottom
            - Self.cardEdgeGap
            - Self.cardSize.height
            - Self.shadowInset
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
    }

    func hide() {
        NSCursor.arrow.set()
        panel.orderOut(nil)
    }
}

@MainActor
@Observable
private final class PetHoverViewModel {
    var title = ""
    var detail = ""
    var meta = ""
    var petFrame: NSImage?
    var showsWave = false
    var isTaskActive = false
    @ObservationIgnored var onMouseEntered: (() -> Void)?
    @ObservationIgnored var onMouseExited: (() -> Void)?
    @ObservationIgnored var onClick: (() -> Void)?
    @ObservationIgnored var onClose: (() -> Void)?
}

private struct PetHoverContentView: View {
    @Bindable var model: PetHoverViewModel
    let cardSize: NSSize
    let shadowInset: CGFloat
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                model.onClick?()
            } label: {
                glassSurface
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(CodexPressableCardStyle(cornerRadius: 16))

            if model.isTaskActive && isHovered {
                Button {
                    model.onClose?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Color.codexInk.opacity(0.72))
                        .frame(
                            width: PetHoverCloseButtonLayout.size,
                            height: PetHoverCloseButtonLayout.size
                        )
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay {
                            Circle()
                                .stroke(Color.primary.opacity(0.08), lineWidth: 0.7)
                        }
                }
                .buttonStyle(.plain)
                .help("关闭本次任务浮窗")
                .accessibilityLabel("关闭任务浮窗")
                .padding(.top, PetHoverCloseButtonLayout.edgeInset)
                .padding(.trailing, PetHoverCloseButtonLayout.edgeInset)
                .transition(.opacity.combined(with: .scale(scale: 0.88)))
                .zIndex(1)
            }
        }
        .onHover { isHovered in
            withAnimation(.easeOut(duration: 0.14)) {
                self.isHovered = isHovered
            }
            if isHovered {
                NSCursor.pointingHand.set()
                model.onMouseEntered?()
            } else {
                NSCursor.arrow.set()
                model.onMouseExited?()
            }
        }
        .shadow(color: Color.black.opacity(0.12), radius: 12, x: 0, y: 0)
        .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 0)
        .padding(shadowInset)
        .frame(
            width: cardSize.width + shadowInset * 2,
            height: cardSize.height + shadowInset * 2
        )
        .background(Color.clear)
    }

    @ViewBuilder
    private var glassSurface: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        Group {
            if #available(macOS 26.0, *) {
                animatedCardContent
                    .glassEffect(in: .rect(cornerRadius: 16))
            } else {
                animatedCardContent
                    .background(.ultraThinMaterial, in: shape)
                    .overlay {
                        shape.stroke(Color.white.opacity(0.42), lineWidth: 0.8)
                    }
            }
        }
        .clipShape(shape)
    }

    private var animatedCardContent: some View {
        ZStack {
            HoverActivityWave(isVisible: model.showsWave)
            cardContent
        }
    }

    private var cardContent: some View {
        HStack(spacing: 13) {
            if let petFrame = model.petFrame {
                Image(nsImage: petFrame)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 58, height: 68)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.codexPrimary)
                    .frame(width: 58, height: 68)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(model.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.codexInk)
                    .lineLimit(1)
                Text(model.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.codexMuted)
                    .lineLimit(2)
                Text(model.meta)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.codexMuted.opacity(0.72))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 13)
        .padding(
            .trailing,
            model.isTaskActive
                ? PetHoverCloseButtonLayout.activeContentTrailingPadding
                : 13
        )
        .frame(width: cardSize.width, height: cardSize.height)
    }
}

private struct HoverActivityWave: View {
    let isVisible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if isVisible {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
                GeometryReader { proxy in
                    let progress = reduceMotion
                        ? CGFloat(0.5)
                        : ActivityWaveTiming.progress(
                            at: timeline.date.timeIntervalSinceReferenceDate
                        )
                    let waveWidth = max(330, proxy.size.width * 1.08)
                    let travelWidth = proxy.size.width + waveWidth * 2
                    let centerX = -waveWidth + travelWidth * progress
                    let inverseSurfaceColor = Color.primary
                    let trailGradient = LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: inverseSurfaceColor.opacity(0.002), location: 0.12),
                            .init(color: inverseSurfaceColor.opacity(0.005), location: 0.28),
                            .init(color: inverseSurfaceColor.opacity(0.010), location: 0.44),
                            .init(color: inverseSurfaceColor.opacity(0.018), location: 0.60),
                            .init(color: inverseSurfaceColor.opacity(0.028), location: 0.74),
                            .init(color: inverseSurfaceColor.opacity(0.040), location: 0.86),
                            .init(color: inverseSurfaceColor.opacity(0.052), location: 0.95),
                            .init(color: inverseSurfaceColor.opacity(0.058), location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    let waveShape = UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 16,
                        topTrailingRadius: 16,
                        style: .continuous
                    )

                    ZStack {
                        Rectangle()
                            .fill(trailGradient)
                            .blur(radius: 9)

                        Rectangle()
                            .fill(trailGradient)
                            .opacity(0.42)
                            .blur(radius: 2.5)
                    }
                    .frame(width: waveWidth, height: proxy.size.height)
                    .compositingGroup()
                    .clipShape(waveShape)
                    .position(x: centerX, y: proxy.size.height / 2)
                }
                .allowsHitTesting(false)
            }
        }
    }
}

extension NSColor {
    static let codexPopoverChrome = NSColor.codexDynamic(
        light: (0.902, 0.906, 0.910, 1),
        dark: (0.118, 0.118, 0.122, 1)
    )

    static let codexWindowBackground = NSColor.codexDynamic(
        light: (0.957, 0.957, 0.957, 1),
        dark: (0.118, 0.118, 0.122, 1)
    )

    static let codexDashboardChrome = NSColor.codexDynamic(
        light: (1.000, 1.000, 0.998, 1),
        dark: (0.165, 0.165, 0.172, 1)
    )
}
