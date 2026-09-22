import AppKit
import SwiftUI
import Observation

/// 刘海面板轮廓：顶部横边完整贴住屏幕顶边，左上/右上使用「反向外耳圆角」，
/// 底部为普通圆角。当靠紧屏幕左右边缘时，贴边侧圆角与外耳自动平滑收缩为直角贴边。
private struct NotchShape: Shape {
    var topLeftRadius: CGFloat
    var topRightRadius: CGFloat
    var bottomLeftRadius: CGFloat
    var bottomRightRadius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get {
            .init(.init(topLeftRadius, topRightRadius), .init(bottomLeftRadius, bottomRightRadius))
        }
        set {
            topLeftRadius = newValue.first.first
            topRightRadius = newValue.first.second
            bottomLeftRadius = newValue.second.first
            bottomRightRadius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let topL = min(topLeftRadius, rect.width / 2)
        let topR = min(topRightRadius, rect.width / 2)
        let botL = min(bottomLeftRadius, rect.height / 2)
        let botR = min(bottomRightRadius, rect.height / 2)

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // 左上反向外耳
        if topL > 0.1 {
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + topL, y: rect.minY + topL),
                control: CGPoint(x: rect.minX + topL, y: rect.minY)
            )
        }

        // 左边缘垂直下行
        let leftX = rect.minX + topL
        path.addLine(to: CGPoint(x: leftX, y: rect.maxY - botL))

        // 左下圆角
        if botL > 0.1 {
            path.addQuadCurve(
                to: CGPoint(x: leftX + botL, y: rect.maxY),
                control: CGPoint(x: leftX, y: rect.maxY)
            )
        } else {
            path.addLine(to: CGPoint(x: leftX, y: rect.maxY))
        }

        // 底部横线
        let rightX = rect.maxX - topR
        path.addLine(to: CGPoint(x: rightX - botR, y: rect.maxY))

        // 右下圆角
        if botR > 0.1 {
            path.addQuadCurve(
                to: CGPoint(x: rightX, y: rect.maxY - botR),
                control: CGPoint(x: rightX, y: rect.maxY)
            )
        } else {
            path.addLine(to: CGPoint(x: rightX, y: rect.maxY))
        }

        // 右边缘垂直上行
        path.addLine(to: CGPoint(x: rightX, y: rect.minY + topR))

        // 右上反向外耳
        if topR > 0.1 {
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY),
                control: CGPoint(x: rightX, y: rect.minY)
            )
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }

        // 顶部封闭
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// 刘海面板的稳定数据模型：rootView 只创建一次，数据变化由观察驱动。
@Observable
final class NotchCapsuleViewModel {
    enum ProviderRefreshState: Equatable {
        case idle
        case loading
        case success
        case warning
    }

    var agentTicks: [StatusBarAgentTick] = []
    var providerTicks: [StatusBarProviderTick] = []
    var agentIndex = 0
    var providerIndex = 0
    var providerRefreshState: ProviderRefreshState = .idle
    var activeAgentCount = 0
    var waitingCount = 0
    var isExpanded = false
    /// 收起态胶囊高度（= 状态栏/刘海高度，动态计算）
    var closedHeight: CGFloat = 32
    /// 收起态胶囊宽度（= 刘海宽度 + 左右翼，动态计算）
    var closedWidth: CGFloat = 360
    /// 中央摄像头避让区宽度（= 物理刘海宽度）
    var notchWidth: CGFloat = 104
    /// 当前所在显示器名称
    var screenName: String = ""
    /// 是否为内建屏（MacBook 物理刘海屏不可移动）
    var isBuiltin: Bool = true
    /// 是否允许拖拽移动（仅外接屏且开启拖拽时有效）
    var isDraggable: Bool = false
    /// 当前 X 轴相对屏幕中心偏移量
    var xOffset: CGFloat = 0
    /// 收起态胶囊在 700pt 展开窗口内的水平偏移（靠左为负，靠右为正，居中为 0；展开时归零）
    var capsuleHorizontalOffsetInWindow: CGFloat = 0
    /// 左侧边缘平直贴合比例（0 = 正常圆角与反向外耳，1 = 完全直角贴合无圆角）
    var leftEdgeFlatRatio: CGFloat = 0
    /// 右侧边缘平直贴合比例（0 = 正常圆角与反向外耳，1 = 完全直角贴合无圆角）
    var rightEdgeFlatRatio: CGFloat = 0

    // 交互回调（由 Controller 注入）
    var onClick: (() -> Void)?
    var onSelectAgent: ((Int) -> Void)?
    var onSelectProvider: ((String) -> Void)?
    var onRefreshProvider: (() -> Void)?
    var onOpenCurrentTask: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenGateway: (() -> Void)?
    var onQuit: (() -> Void)?
    var onOpenAgentTask: ((StatusBarAgentTick) -> Void)?
    var onAgentHover: ((Bool) -> Void)?
    var onProviderHover: ((Bool) -> Void)?
    /// 供应商「工作区跳转」按钮回调（携带该供应商的跳转地址）。
    var onOpenWorkspace: ((StatusBarProviderTick) -> Void)?
    /// 切换外接显示器刘海拖拽锁定状态。
    var onToggleDragLock: (() -> Void)?
    /// 一键恢复到屏幕顶部居中。
    var onResetCenter: (() -> Void)?
}

/// 自定义命中视图：限制 SwiftUI 宿主内部的响应区域。
/// 跨窗口的点击穿透由 NSPanel.ignoresMouseEvents 控制。
final class NotchHitTestView: NSView {
    /// 命中判定（点坐标为视图 bounds 坐标，原点在左下角）。
    var shouldHit: (NSPoint) -> Bool = { _ in true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        shouldHit(point) ? super.hitTest(point) : nil
    }
}

/// A notch is intentionally attached to the physical top edge, inside the area
/// AppKit normally reserves for the menu bar. Plain NSPanel silently constrains
/// `setFrame` to `visibleFrame`, which pushes the surface down by one menu-bar
/// height and leaves it looking like a detached, clipped capsule.
final class NotchOverlayPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// 刘海屏伴侣面板：固定尺寸透明 NSPanel 顶部贴主屏顶边，内容在窗口内顶部居中。
/// 收起态只拦截顶部胶囊的点击（点击展开），展开态拦截整个面板；鼠标移出或 Esc 收起。
@MainActor
final class NotchCapsulePanelController {
    private static let openedSize = NSSize(width: 700, height: 330)
    private static let windowSize = NSSize(width: 700, height: 330)

    private let panel: NSPanel
    /// 收起态专用的透明点击层，尺寸严格等于可见胶囊，避免固定大窗口制造点击死区。
    private let collapsedHitPanel: NSPanel
    let viewModel = NotchCapsuleViewModel()
    private let hosting: NSHostingController<NotchCapsuleView>
    private let hitTestView = NotchHitTestView()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var screen: NSScreen?
    private var collapseWorkItem: DispatchWorkItem?
    private var interactionWorkItem: DispatchWorkItem?

    private(set) var isBuiltin: Bool = true
    var isDraggingEnabled: Bool = false
    private(set) var currentXOffset: CGFloat = 0
    private var isMouseDownOnCapsule = false
    private var hasDragged = false
    private var dragStartMouseLocation: NSPoint = .zero
    private var dragStartOffset: CGFloat = 0
    private var wasHoveringCapsule = false

    var onClick: (() -> Void)?
    var onSelectAgent: ((Int) -> Void)?
    var onSelectProvider: ((String) -> Void)?
    var onRefreshProvider: (() -> Void)?
    var onOpenCurrentTask: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenGateway: (() -> Void)?
    var onQuit: (() -> Void)?
    var onOpenAgentTask: ((StatusBarAgentTick) -> Void)?
    var onAgentHover: ((Bool) -> Void)?
    var onProviderHover: ((Bool) -> Void)?
    var onOpenWorkspace: ((StatusBarProviderTick) -> Void)?
    var onOffsetChanged: ((CGFloat) -> Void)?
    var onToggleDragLock: (() -> Void)?
    var onResetCenter: (() -> Void)?

    init() {
        hosting = NSHostingController(rootView: NotchCapsuleView(viewModel: viewModel))
        panel = NotchOverlayPanel(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        collapsedHitPanel = NotchOverlayPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // 用自定义命中视图包裹 SwiftUI 内容；窗口级穿透不能依赖 NSView.hitTest。
        panel.contentView = hitTestView
        hosting.view.frame = NSRect(origin: .zero, size: Self.windowSize)
        hosting.view.autoresizingMask = [.width, .height]
        hitTestView.addSubview(hosting.view)

        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        // macOS 26 can place menu-bar/status-item windows above `.mainMenu + n`.
        // The notch is a screen-edge surface and must remain above that system
        // chrome on every display, including when another app is active.
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        panel.isMovableByWindowBackground = false
        // 固定 700×330 主窗口在收起态必须整体穿透；小点击层只覆盖可见胶囊。
        panel.ignoresMouseEvents = true
        updateHitTestPolicy()

        collapsedHitPanel.isFloatingPanel = true
        collapsedHitPanel.becomesKeyOnlyIfNeeded = true
        collapsedHitPanel.level = .screenSaver + 1
        collapsedHitPanel.isOpaque = false
        collapsedHitPanel.backgroundColor = .clear
        collapsedHitPanel.hasShadow = false
        collapsedHitPanel.titleVisibility = .hidden
        collapsedHitPanel.titlebarAppearsTransparent = true
        collapsedHitPanel.hidesOnDeactivate = false
        collapsedHitPanel.collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        collapsedHitPanel.isMovableByWindowBackground = false
        collapsedHitPanel.ignoresMouseEvents = false
        let collapsedHitView = NSView(frame: .zero)
        collapsedHitView.wantsLayer = true
        // 极低 alpha 保证 Window Server 保留命中层；它叠在黑色胶囊上，不产生可见变化。
        collapsedHitView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.001).cgColor
        collapsedHitView.setAccessibilityElement(true)
        collapsedHitView.setAccessibilityRole(.button)
        collapsedHitView.setAccessibilityLabel("Tomo 灵动顶栏")
        collapsedHitView.setAccessibilityHelp("点击展开 Tomo 灵动顶栏")
        collapsedHitPanel.contentView = collapsedHitView

        // self 完全初始化后再注入回调，转发到公开属性。
        viewModel.onSelectAgent = { [weak self] index in self?.onSelectAgent?(index) }
        viewModel.onSelectProvider = { [weak self] connectionID in self?.onSelectProvider?(connectionID) }
        viewModel.onRefreshProvider = { [weak self] in self?.onRefreshProvider?() }
        viewModel.onOpenCurrentTask = { [weak self] in self?.onOpenCurrentTask?() }
        viewModel.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        viewModel.onOpenGateway = { [weak self] in self?.onOpenGateway?() }
        viewModel.onQuit = { [weak self] in self?.onQuit?() }
        viewModel.onOpenAgentTask = { [weak self] tick in self?.onOpenAgentTask?(tick) }
        viewModel.onAgentHover = { [weak self] hovering in self?.onAgentHover?(hovering) }
        viewModel.onProviderHover = { [weak self] hovering in self?.onProviderHover?(hovering) }
        viewModel.onOpenWorkspace = { [weak self] tick in self?.onOpenWorkspace?(tick) }
        viewModel.onToggleDragLock = { [weak self] in self?.onToggleDragLock?() }
        viewModel.onResetCenter = { [weak self] in self?.onResetCenter?() }
    }

    func update(
        agentTicks: [StatusBarAgentTick],
        providerTicks: [StatusBarProviderTick],
        agentIndex: Int,
        providerIndex: Int,
        activeAgentCount: Int,
        waitingCount: Int
    ) {
        viewModel.agentTicks = agentTicks
        viewModel.providerTicks = providerTicks
        viewModel.agentIndex = agentIndex
        // 供应商选中项变化时显式包裹动画，确保 logo 行滚动和选中高亮在同一个动画事务里同步过渡，
        // 不依赖 `.animation(value:)` 在 NSHostingController 里的隐式触发。
        if viewModel.providerIndex != providerIndex {
            withAnimation(ConnectionLogoRowMotion.selectionAnimation) {
                viewModel.providerIndex = providerIndex
            }
        } else {
            viewModel.providerIndex = providerIndex
        }
        viewModel.activeAgentCount = activeAgentCount
        viewModel.waitingCount = waitingCount
    }

    func updateProviderRefreshState(_ state: NotchCapsuleViewModel.ProviderRefreshState) {
        viewModel.providerRefreshState = state
    }

    /// 设置拖拽配置（内建/外接屏状态、拖拽开关与记忆偏移量）
    func setDragConfiguration(isBuiltin: Bool, isDraggingEnabled: Bool, xOffset: CGFloat) {
        self.isBuiltin = isBuiltin
        self.isDraggingEnabled = isDraggingEnabled
        viewModel.isBuiltin = isBuiltin
        viewModel.isDraggable = !isBuiltin && isDraggingEnabled
        if let screen {
            self.currentXOffset = clampedOffset(for: screen, offset: xOffset)
        } else {
            self.currentXOffset = isBuiltin ? 0 : xOffset
        }
        viewModel.xOffset = self.currentXOffset
        if isVisible {
            positionPanel()
        }
    }

    /// 一键平滑恢复到屏幕顶部正中心
    func resetToCenter(animated: Bool = true) {
        guard currentXOffset != 0 else { return }
        currentXOffset = 0
        viewModel.xOffset = 0
        positionPanel(animated: animated)
        onOffsetChanged?(0)
    }

    func clampedOffset(for screen: NSScreen, offset: CGFloat) -> CGFloat {
        guard !isBuiltin else { return 0 }
        let capsuleWidth = viewModel.closedWidth > 0 ? viewModel.closedWidth : 434
        // 允许收起态胶囊完全拖拽贴合至屏幕最左或最右边缘（零边距贴合）
        let maxOffset = max(0, (screen.frame.width - capsuleWidth) / 2)
        return min(max(offset, -maxOffset), maxOffset)
    }

    func show(on screen: NSScreen? = nil) {
        guard let resolvedScreen = screen ?? NSScreen.main ?? NSScreen.screens.first else {
            hide()
            return
        }
        self.screen = resolvedScreen
        self.isBuiltin = resolvedScreen.isBuiltin
        viewModel.isBuiltin = resolvedScreen.isBuiltin
        viewModel.isDraggable = !resolvedScreen.isBuiltin && isDraggingEnabled
        // 动态计算：收起态高度 = 刘海/状态栏高度，宽度 = 刘海宽度 + 左右翼。
        let notchWidth = self.screen?.notchWidth ?? 104
        let safeTop = self.screen?.notchHeight ?? NSStatusBar.system.thickness
        viewModel.notchWidth = notchWidth
        viewModel.closedWidth = notchWidth + 330
        viewModel.closedHeight = safeTop
        self.currentXOffset = clampedOffset(for: resolvedScreen, offset: currentXOffset)
        viewModel.xOffset = currentXOffset
        viewModel.screenName = self.screen?.displayName ?? "显示器"
        viewModel.isExpanded = false
        cancelInteractionTransition()
        panel.ignoresMouseEvents = true
        updateHitTestPolicy()
        positionPanel()
        panel.orderFrontRegardless()
        collapsedHitPanel.orderFrontRegardless()
        installMonitors()
    }

    /// 数据刷新可能在显示器重建之后先于 `applyMode` 创建一个新控制器。
    /// 如果窗口尚未真正进入 WindowServer，就立即用目标屏幕恢复，而不是留下
    /// 初始化时的默认坐标/零尺寸点击层。
    func ensureVisible(on screen: NSScreen) {
        guard !panel.isVisible else { return }
        show(on: screen)
    }

    func hide() {
        removeMonitors()
        cancelCollapse()
        cancelInteractionTransition()
        isMouseDownOnCapsule = false
        hasDragged = false
        if wasHoveringCapsule {
            wasHoveringCapsule = false
            NSCursor.arrow.set()
        }
        onAgentHover?(false)
        onProviderHover?(false)
        viewModel.isExpanded = false
        panel.ignoresMouseEvents = true
        collapsedHitPanel.orderOut(nil)
        panel.orderOut(nil)
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: - 展开 / 收起

    private func setExpanded(_ expanded: Bool) {
        guard expanded != viewModel.isExpanded else { return }
        cancelInteractionTransition()
        if !expanded {
            onAgentHover?(false)
            onProviderHover?(false)
        } else {
            if wasHoveringCapsule {
                wasHoveringCapsule = false
                NSCursor.arrow.set()
            }
            // 先移除小点击层并让完整面板接管，再开始展开动画。
            collapsedHitPanel.orderOut(nil)
            panel.ignoresMouseEvents = false
        }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
            viewModel.isExpanded = expanded
            positionPanel(animated: false)
        }
        updateHitTestPolicy()
        if !expanded {
            // 收拢动画期间完整面板仍拦截可见区域；动画结束后切换为胶囊大小的点击层。
            scheduleCollapsedInteraction()
        }
    }

    private func closePanel() {
        cancelCollapse()
        setExpanded(false)
    }

    /// 工作区跳转打开系统浏览器后调用：把展开态刘海面板收起。
    func setExpandedFromWorkspaceJump() {
        cancelCollapse()
        setExpanded(false)
    }

    /// 更新主窗口内部命中区域；收起态的跨窗口穿透由独立小点击层负责。
    private func updateHitTestPolicy() {
        let closedWidth = viewModel.closedWidth
        let closedHeight = viewModel.closedHeight
        let offsetInWindow = viewModel.capsuleHorizontalOffsetInWindow
        hitTestView.shouldHit = { [weak self] point in
            guard let self else { return false }
            if self.viewModel.isExpanded { return true }
            let bounds = self.hitTestView.bounds
            let capsuleRect = NSRect(
                x: (bounds.width - closedWidth) / 2 + offsetInWindow,
                y: bounds.height - closedHeight,
                width: closedWidth,
                height: closedHeight
            )
            return capsuleRect.contains(point)
        }
    }

    private func currentCenterX() -> CGFloat {
        guard let screen else { return 0 }
        return screen.frame.midX + clampedOffset(for: screen, offset: currentXOffset)
    }

    /// 展开态大窗口的实际屏幕中心 X：保证 700pt 面板始终完整位于屏幕可视区内
    private func expandedPanelCenterX() -> CGFloat {
        guard let screen else { return 0 }
        let rawCenterX = currentCenterX()
        let halfWidth = Self.windowSize.width / 2
        let minCenterX = screen.frame.minX + halfWidth
        let maxCenterX = screen.frame.maxX - halfWidth
        return min(max(rawCenterX, minCenterX), maxCenterX)
    }

    private func positionPanel(animated: Bool = false) {
        guard let screen else { return }
        let size = Self.windowSize
        let windowCenterX = expandedPanelCenterX()
        let capsuleCenterX = currentCenterX()
        let panelOriginX = windowCenterX - size.width / 2
        let targetCenterInWindow = capsuleCenterX - panelOriginX
        viewModel.capsuleHorizontalOffsetInWindow = targetCenterInWindow - size.width / 2

        // 计算当前胶囊在屏幕上的实际物理位置
        let halfWidth = (viewModel.isExpanded ? size.width : viewModel.closedWidth) / 2
        let currentScreenCenter = viewModel.isExpanded ? windowCenterX : capsuleCenterX
        let capsuleLeft = currentScreenCenter - halfWidth
        let capsuleRight = currentScreenCenter + halfWidth

        // 计算靠边程度：小于 14pt 时平滑过渡为直角贴边（0 = 正常圆角，1 = 完全直角贴边无圆角）
        let threshold: CGFloat = 14
        let distToLeft = max(0, capsuleLeft - screen.frame.minX)
        let distToRight = max(0, screen.frame.maxX - capsuleRight)
        viewModel.leftEdgeFlatRatio = distToLeft < threshold ? (1 - distToLeft / threshold) : 0
        viewModel.rightEdgeFlatRatio = distToRight < threshold ? (1 - distToRight / threshold) : 0

        let panelFrame = NSRect(
            x: windowCenterX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        let closedFrame = closedScreenRect()
        if animated {
            if panel.frame != panelFrame {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.32
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    panel.animator().setFrame(panelFrame, display: true)
                }
            }
            if !viewModel.isExpanded, collapsedHitPanel.frame != closedFrame {
                collapsedHitPanel.animator().setFrame(closedFrame, display: true)
            }
        } else {
            if panel.frame != panelFrame {
                panel.setFrame(panelFrame, display: true)
            }
            if collapsedHitPanel.frame != closedFrame {
                collapsedHitPanel.setFrame(closedFrame, display: true)
            }
        }
        updateHitTestPolicy()
    }

    private func scheduleCollapsedInteraction() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.panel.isVisible, !self.viewModel.isExpanded else { return }
            self.interactionWorkItem = nil
            self.panel.ignoresMouseEvents = true
            self.collapsedHitPanel.setFrame(self.closedScreenRect(), display: true)
            self.collapsedHitPanel.orderFrontRegardless()
        }
        interactionWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func cancelInteractionTransition() {
        interactionWorkItem?.cancel()
        interactionWorkItem = nil
    }

    // MARK: - 鼠标 / 键盘监控

    private func installMonitors() {
        removeMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]
        ) { [weak self] event in
            DispatchQueue.main.async { self?.handleEvent(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .mouseMoved, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            if event.type == .keyDown, event.keyCode == 53 { // Esc
                DispatchQueue.main.async { self?.closePanel() }
                return nil
            }
            DispatchQueue.main.async { self?.handleEvent(event) }
            return event
        }
    }

    private func removeMonitors() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func handleEvent(_ event: NSEvent) {
        guard screen != nil else { return }
        switch event.type {
        case .leftMouseDown:
            handleMouseDown(event)
        case .leftMouseDragged:
            handleMouseDragged(event)
        case .leftMouseUp:
            handleMouseUp(event)
        case .mouseMoved:
            handleMouseMove(event)
        default:
            break
        }
    }

    /// 收起态按住拖拽/点击判定；展开态点击面板外部收起（展开态禁止拖动）。
    private func handleMouseDown(_ event: NSEvent) {
        if viewModel.isExpanded {
            if !isPointerInsideOpenedRect() {
                cancelCollapse()
                setExpanded(false)
            }
            return
        }
        if isPointerInsideClosedRect() {
            if viewModel.isDraggable {
                isMouseDownOnCapsule = true
                hasDragged = false
                dragStartMouseLocation = NSEvent.mouseLocation
                dragStartOffset = currentXOffset
            } else {
                setExpanded(true)
            }
        }
    }

    /// 外接屏允许拖拽时实时更新位置（展开态完全不响应拖拽）。
    private func handleMouseDragged(_ event: NSEvent) {
        guard !viewModel.isExpanded, viewModel.isDraggable, isMouseDownOnCapsule, let screen else { return }
        let currentLoc = NSEvent.mouseLocation
        let deltaX = currentLoc.x - dragStartMouseLocation.x
        if abs(deltaX) > 2 || hasDragged {
            hasDragged = true
            NSCursor.closedHand.set()
            let rawOffset = dragStartOffset + deltaX
            currentXOffset = clampedOffset(for: screen, offset: rawOffset)
            viewModel.xOffset = currentXOffset
            positionPanel()
        }
    }

    /// 鼠标抬起：若发生拖动则持久化偏移，不展开；若未拖动则视为轻点展开。
    private func handleMouseUp(_ event: NSEvent) {
        guard isMouseDownOnCapsule else { return }
        isMouseDownOnCapsule = false
        if hasDragged {
            hasDragged = false
            onOffsetChanged?(currentXOffset)
            if isPointerInsideClosedRect() {
                NSCursor.openHand.set()
            } else {
                NSCursor.arrow.set()
            }
        } else {
            setExpanded(true)
        }
    }

    /// 展开态下鼠标移出面板后自动收起；收起态下支持拖拽时展示手型光标。
    private func handleMouseMove(_ event: NSEvent) {
        if viewModel.isExpanded {
            if !isPointerInsideOpenedRect() {
                scheduleCollapse()
            } else {
                cancelCollapse()
            }
        } else if viewModel.isDraggable {
            let inside = isPointerInsideClosedRect()
            if inside && !wasHoveringCapsule {
                wasHoveringCapsule = true
                NSCursor.openHand.set()
            } else if !inside && wasHoveringCapsule {
                wasHoveringCapsule = false
                NSCursor.arrow.set()
            }
        }
    }

    /// 收起前短暂延迟，消除「一出现马上缩小又展开」的抖动。
    private func scheduleCollapse() {
        guard collapseWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.collapseWorkItem = nil
            self.setExpanded(false)
        }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func cancelCollapse() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
    }

    private func isPointerInsideClosedRect() -> Bool {
        closedScreenRect().contains(NSEvent.mouseLocation)
    }

    private func isPointerInsideOpenedRect() -> Bool {
        openedScreenRect().contains(NSEvent.mouseLocation)
    }

    private func closedScreenRect() -> NSRect {
        guard let screen else { return .zero }
        let size = NSSize(width: viewModel.closedWidth, height: viewModel.closedHeight)
        let centerX = currentCenterX()
        return NSRect(
            x: centerX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    private func openedScreenRect() -> NSRect {
        guard let screen else { return .zero }
        let size = Self.openedSize
        let centerX = expandedPanelCenterX()
        return NSRect(
            x: centerX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }
}

// MARK: - SwiftUI 视图

private struct NotchCapsuleView: View {
    let viewModel: NotchCapsuleViewModel
    @State private var showQuitConfirmation = false
    @State private var hoveredFooterAction: FooterAction?

    private enum FooterAction: Equatable {
        case settings
        case gateway
        case quit
        case dragLock
        case resetCenter
    }

    private var agent: StatusBarAgentTick? {
        viewModel.agentTicks.indices.contains(viewModel.agentIndex)
            ? viewModel.agentTicks[viewModel.agentIndex] : nil
    }
    private var provider: StatusBarProviderTick? {
        viewModel.providerTicks.indices.contains(viewModel.providerIndex)
            ? viewModel.providerTicks[viewModel.providerIndex] : nil
    }
    private var baseTopRadius: CGFloat { viewModel.isExpanded ? 19 : 6 }
    private var baseBottomRadius: CGFloat { viewModel.isExpanded ? 24 : 14 }
    private var panelWidth: CGFloat { viewModel.isExpanded ? 700 : viewModel.closedWidth }
    private var panelHeight: CGFloat { viewModel.isExpanded ? 330 : viewModel.closedHeight }
    private var contentHorizontalOffset: CGFloat {
        viewModel.isExpanded ? 0 : viewModel.capsuleHorizontalOffsetInWindow
    }

    private var topLeftRadius: CGFloat {
        baseTopRadius * (1 - viewModel.leftEdgeFlatRatio)
    }
    private var bottomLeftRadius: CGFloat {
        baseBottomRadius * (1 - viewModel.leftEdgeFlatRatio)
    }
    private var topRightRadius: CGFloat {
        baseTopRadius * (1 - viewModel.rightEdgeFlatRatio)
    }
    private var bottomRightRadius: CGFloat {
        baseBottomRadius * (1 - viewModel.rightEdgeFlatRatio)
    }

    var body: some View {
        ZStack {
            // 同一容器：尺寸与圆角随展开态连续插值（形变动画，而非视图切换渐变）
            NotchShape(
                topLeftRadius: topLeftRadius,
                topRightRadius: topRightRadius,
                bottomLeftRadius: bottomLeftRadius,
                bottomRightRadius: bottomRightRadius
            )
            .fill(Color.black.opacity(0.97))
            if viewModel.isExpanded {
                expandedContent
                    .transition(.opacity)
            } else {
                collapsedContent
                    .transition(.opacity)
            }
            if viewModel.isExpanded, showQuitConfirmation {
                quitConfirmation
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .frame(width: panelWidth, height: panelHeight)
        .clipShape(
            NotchShape(
                topLeftRadius: topLeftRadius,
                topRightRadius: topRightRadius,
                bottomLeftRadius: bottomLeftRadius,
                bottomRightRadius: bottomRightRadius
            )
        )
        .offset(x: contentHorizontalOffset)
        // 只水平居中、垂直贴顶，保证形变始终以屏幕顶部为锚点向下展开，不产生顶部空隙。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.42, dampingFraction: 0.84), value: viewModel.isExpanded)
    }

    // MARK: 收起态

    private var collapsedContent: some View {
        HStack(spacing: 0) {
            // 左翼：Agent logo + 状态圆点 + 状态文字，贴左
            HStack(spacing: 6) {
                if let agent {
                    StatusBarBrandBadge(asset: agent.asset, size: 14)
                    Circle().fill(Color(nsColor: agent.state.statusNSColor)).frame(width: 6, height: 6)
                    ActivityShimmerText(
                        text: agent.statusText,
                        font: .system(size: 12, weight: .semibold),
                        base: .white.opacity(0.72),
                        highlight: Color(nsColor: agent.state.statusNSColor),
                        isAnimated: agent.state.showsActivityWave
                    )
                    .lineLimit(1)
                } else {
                    Circle().fill(Color.gray.opacity(0.8)).frame(width: 6, height: 6)
                    Text("空闲")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 中央：摄像头避让（= 物理刘海宽度）
            Color.clear.frame(width: viewModel.notchWidth)

            // 右翼：供应商 logo + 额度，贴右
            HStack(spacing: 6) {
                if let provider {
                    ProviderQuotaTextView(
                        provider: provider,
                        font: .system(size: 11, weight: .semibold, design: .rounded),
                        separatorColor: .white.opacity(0.4)
                    )
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                    StatusBarBrandBadge(asset: provider.asset, size: 14)
                } else {
                    Text("未登录")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.leading, collapsedLeadingPadding)
        .padding(.trailing, collapsedTrailingPadding)
    }

    private var collapsedLeadingPadding: CGFloat {
        14 - 4 * viewModel.leftEdgeFlatRatio
    }

    private var collapsedTrailingPadding: CGFloat {
        14 - 4 * viewModel.rightEdgeFlatRatio
    }

    private var expandedLeadingPadding: CGFloat {
        let basePadding: CGFloat = 36
        let flatPadding: CGFloat = 20
        return basePadding - (basePadding - flatPadding) * viewModel.leftEdgeFlatRatio
    }

    private var expandedTrailingPadding: CGFloat {
        let basePadding: CGFloat = 36
        let flatPadding: CGFloat = 20
        return basePadding - (basePadding - flatPadding) * viewModel.rightEdgeFlatRatio
    }

    // MARK: 展开态

    private var expandedContent: some View {
        VStack(spacing: 0) {
            header
                .frame(height: 26)

            bodyColumns
                .padding(.top, 18)
                .frame(maxHeight: .infinity, alignment: .top)

            footer
                .padding(.top, 16)
                .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5) }
                .padding(.top, 16)
        }
        .padding(.leading, expandedLeadingPadding)
        .padding(.trailing, expandedTrailingPadding)
        .padding(.top, 18)
        .padding(.bottom, 26)
    }

    private var codexlingLogoImage: Image {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("logo.svg"),
           let nsImage = NSImage(contentsOf: url) {
            return Image(nsImage: nsImage)
        }
        return Image(systemName: "sparkles")
    }

    private var header: some View {
        HStack {
            HStack(spacing: 7) {
                codexlingLogoImage
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                Text("CODEXLING · \(viewModel.screenName)")
            }
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(Color.green).frame(width: 7, height: 7)
                Text("\(viewModel.providerTicks.count) 个数据源在线")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.45))
    }

    private var bodyColumns: some View {
        HStack(alignment: .top, spacing: 24) {
            agentColumn
            providerColumn
        }
    }

    private var agentColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let agent {
                HStack(spacing: 7) {
                    StatusBarBrandBadge(asset: agent.asset, size: 22)
                    Text(agent.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Circle().fill(Color(nsColor: agent.state.statusNSColor)).frame(width: 7, height: 7)
                    Text(agent.statusText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(nsColor: agent.state.statusNSColor))
                        .lineLimit(1)
                }
                ActivityShimmerText(
                    text: agent.taskTitle.isEmpty ? "当前没有运行任务" : agent.taskTitle,
                    font: .system(size: 17, weight: .bold),
                    base: .white.opacity(0.72),
                    highlight: Color(nsColor: agent.state.statusNSColor),
                    isAnimated: !agent.taskTitle.isEmpty && agent.state.showsActivityWave
                )
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
                if !agent.taskDetail.isEmpty {
                    Text(agent.taskDetail)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                        .padding(.top, 6)
                }
                if !agent.metadataItems.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(agent.metadataItems, id: \.value) { item in
                            Label(item.value, systemImage: item.icon)
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 8)
                }
                // 「更新于…」只在相对时间有含义时展示，避免无意义的「更新于刚刚」。
                if let updatedAt = agent.updatedAt, Date().timeIntervalSince(updatedAt) >= 60 {
                    HStack(spacing: 5) {
                        Text(agent.state.activityLabel)
                        Text("·")
                        Text("更新于\(UsageDateFormat.relative(updatedAt))")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 8)
                }
            } else {
                // 空态：暂无进行中的 Agent
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.white.opacity(0.32))
                    Text("暂无进行中的 Agent")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.72))
                    Text("Agent 开始工作后，任务状态会显示在这里")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            if !viewModel.agentTicks.isEmpty {
                HStack {
                    Button(action: {
                        viewModel.onSelectAgent?((viewModel.agentIndex - 1 + max(viewModel.agentTicks.count, 1)) % max(viewModel.agentTicks.count, 1))
                    }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .background(Color.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("\(viewModel.agentIndex + 1) / \(viewModel.agentTicks.count)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.40))
                    Spacer()
                    Button(action: {
                        viewModel.onSelectAgent?((viewModel.agentIndex + 1) % viewModel.agentTicks.count)
                    }) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .background(Color.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(.white.opacity(0.60))
                .padding(.top, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 24)
        .contentShape(Rectangle())
        .overlay(alignment: .trailing) { Rectangle().fill(Color.white.opacity(0.10)).frame(width: 0.5) }
        .onHover { hovering in
            // 悬停时暂停 Agent 轮播；移开后由宿主重新进入轮播流程。
            viewModel.onAgentHover?(hovering)
            guard let agent, AgentTaskOpener.canOpen(agentDisplayName: agent.name) else {
                if !hovering { NSCursor.arrow.set() }
                return
            }
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .onTapGesture {
            // 整块 Agent 任务信息区支持点击进入对应 agent 应用（仅 Codex）；
            // 按下态反馈由上方手型光标与悬停表现承担，不再扩散全刘海 wave。
            if let agent, AgentTaskOpener.canOpen(agentDisplayName: agent.name) {
                viewModel.onOpenAgentTask?(agent)
            }
        }
    }

    private var providerColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let provider {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(provider.providerName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(provider.accountName)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    StatusBarBrandBadge(asset: provider.asset, size: 26)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("可用额度")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                    if let resetTime = provider.resetTimeText, !resetTime.isEmpty {
                        Spacer(minLength: 4)
                        HStack(spacing: 3) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 8.5))
                            Text(resetTime)
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(.white.opacity(0.40))
                        .lineLimit(1)
                    }
                }
                .padding(.top, 12)
                ProviderQuotaTextView(
                    provider: provider,
                    font: .system(size: 17, weight: .bold, design: .rounded),
                    separatorColor: .white.opacity(0.4)
                )
                .lineLimit(1)
                .padding(.top, 8)
                if !provider.detailText.isEmpty {
                    HStack(spacing: 8) {
                        Text(provider.detailText)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                        if let workspaceURL = provider.workspaceURL {
                            Button {
                                viewModel.onOpenWorkspace?(provider)
                            } label: {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.82))
                                    .frame(width: 24, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .help("打开 \(workspaceURL)")
                        }
                    }
                    .padding(.top, 4)
                }
            } else {
                // 空态：暂无额度数据
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "creditcard")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.white.opacity(0.32))
                    Text("暂无额度数据")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.72))
                    Text("登录账号或配置 API Key 后显示")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            if !viewModel.providerTicks.isEmpty {
                HStack(alignment: .bottom, spacing: 8) {
                    GeometryReader { geometry in
                        let rowOffset = providerRowOffset(viewportWidth: geometry.size.width)
                        HStack(alignment: .center, spacing: 8) {
                            ForEach(Array(viewModel.providerTicks.enumerated()), id: \.element.id) { index, tick in
                                Button {
                                    // Update the expanded panel immediately. The
                                    // controller callback also changes the global
                                    // selected connection, but that refresh can
                                    // arrive one run-loop later.
                                    withAnimation(ConnectionLogoRowMotion.selectionAnimation) {
                                        viewModel.providerIndex = index
                                    }
                                    viewModel.onSelectProvider?(tick.id)
                                } label: {
                                    StatusBarBrandBadge(asset: tick.asset, size: 24)
                                        .padding(4)
                                        .background(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(index == viewModel.providerIndex ? Color.white.opacity(0.15) : Color.white.opacity(0.04))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .strokeBorder(index == viewModel.providerIndex ? Color.white.opacity(0.25) : .clear, lineWidth: 1)
                                        )
                                        .overlay(alignment: .bottom) {
                                            Circle().fill(.white)
                                                .frame(width: 5, height: 5)
                                                .offset(y: -2)
                                                .opacity(index == viewModel.providerIndex ? 1 : 0)
                                        }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(height: 32)
                        .offset(x: rowOffset)
                        .animation(ConnectionLogoRowMotion.selectionAnimation, value: viewModel.providerIndex)
                    }
                    .frame(height: 32)
                    .clipped()

                    Button(action: { viewModel.onRefreshProvider?() }) {
                        Group {
                            switch viewModel.providerRefreshState {
                            case .idle:
                                Image(systemName: "arrow.triangle.2.circlepath")
                            case .loading:
                                CodexButtonLoading(tint: .white, size: 12)
                            case .success:
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.codexGreen)
                            case .warning:
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(.yellow)
                            }
                        }
                        .id(viewModel.providerRefreshState)
                        .transition(.opacity.combined(with: .scale(scale: 0.78)))
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.72))
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.20), style: StrokeStyle(lineWidth: 1, dash: [3]))
                    }
                    .animation(.easeInOut(duration: 0.22), value: viewModel.providerRefreshState)
                    .disabled(viewModel.providerRefreshState == .loading)
                    .help("刷新所有供应商额度")
                }
                .frame(height: 32)
                .padding(.top, 16)
            }
        }
        .frame(width: 200)
        .onHover { hovering in viewModel.onProviderHover?(hovering) }
        .onDisappear { viewModel.onProviderHover?(false) }
    }

    private func providerRowOffset(viewportWidth: CGFloat) -> CGFloat {
        let count = viewModel.providerTicks.count
        return ConnectionLogoRowMotion.offset(
            viewportWidth: viewportWidth,
            itemWidth: 32,
            spacing: 8,
            edgeMargin: 0,
            itemCount: count,
            selectedIndex: viewModel.providerIndex
        )
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 12) {
                footerActionButton(
                    action: .quit,
                    icon: "power",
                    tooltip: "关闭软件"
                ) {
                    showQuitConfirmation = true
                }

                footerActionButton(
                    action: .settings,
                    icon: "gearshape",
                    tooltip: "打开设置"
                ) {
                    viewModel.onOpenSettings?()
                }

                footerActionButton(
                    action: .gateway,
                    icon: "point.3.connected.trianglepath.dotted",
                    tooltip: "打开 Gateway"
                ) {
                    viewModel.onOpenGateway?()
                }

                if !viewModel.isBuiltin {
                    footerActionButton(
                        action: .dragLock,
                        icon: viewModel.isDraggable ? "lock.open" : "lock",
                        tooltip: viewModel.isDraggable ? "锁定刘海位置" : "解锁刘海拖拽",
                        isActive: viewModel.isDraggable
                    ) {
                        viewModel.onToggleDragLock?()
                    }

                    if viewModel.xOffset != 0 {
                        footerActionButton(
                            action: .resetCenter,
                            icon: "arrow.counterclockwise",
                            tooltip: "一键恢复刘海居中"
                        ) {
                            viewModel.onResetCenter?()
                        }
                    }
                }
            }
            Spacer()
            HStack(spacing: 10) {
                Button(action: { viewModel.onOpenCurrentTask?() }) {
                    HStack(spacing: 4) {
                        Text("打开窗口")
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)
                HStack(spacing: 4) {
                    Image(systemName: "cursorarrow.motionlines").font(.system(size: 10))
                    Text("移开自动收起")
                }
                .foregroundStyle(.white.opacity(0.45))
                .opacity(0.7)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.45))
        .onDisappear {
            hoveredFooterAction = nil
        }
    }

    @ViewBuilder
    private func footerActionButton(
        action: FooterAction,
        icon: String,
        tooltip: String,
        isActive: Bool = false,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                .foregroundStyle(isActive ? Color.accentColor : (hoveredFooterAction == action ? .white : .white.opacity(0.78)))
                .background(
                    hoveredFooterAction == action
                        ? Color.white.opacity(0.18)
                        : Color.white.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tooltip)
        .help(tooltip)
        .overlay(alignment: .top) {
            if hoveredFooterAction == action {
                Text(tooltip)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(Color(white: 0.16).opacity(0.96), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
                    .fixedSize()
                    .offset(y: -26)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    .zIndex(100)
                    .allowsHitTesting(false)
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                if hovering {
                    hoveredFooterAction = action
                    NSCursor.pointingHand.set()
                } else if hoveredFooterAction == action {
                    hoveredFooterAction = nil
                    NSCursor.arrow.set()
                }
            }
        }
    }

    /// 刘海内嵌确认卡片：不使用系统 alert，因此不会给整个屏幕添加背景 mask。
    private var quitConfirmation: some View {
        VStack(spacing: 12) {
            Image(systemName: "power")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
            Text("确认关闭软件？")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Text("Tomo 将完全退出，菜单栏图标也会消失。")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.52))
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button("取消") {
                    showQuitConfirmation = false
                }
                .buttonStyle(NotchConfirmationButtonStyle(isDestructive: false))

                Button("关闭软件") {
                    viewModel.onQuit?()
                }
                .buttonStyle(NotchConfirmationButtonStyle(isDestructive: true))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(Color.black.opacity(0.98), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }
}

private struct NotchConfirmationButtonStyle: ButtonStyle {
    let isDestructive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isDestructive ? Color.white : Color.white.opacity(0.72))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                (isDestructive ? Color.red.opacity(0.76) : Color.white.opacity(0.10)),
                in: Capsule()
            )
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

/// 小尺寸品牌徽标。
private struct StatusBarBrandBadge: View {
    let asset: BrandAssetID
    let size: CGFloat

    var body: some View {
        Group {
            if let image = BrandAssetCatalog.image(for: asset) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.08)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: size * 0.45, weight: .medium))
                    .foregroundStyle(Color.codexMuted)
            }
        }
        .frame(width: size, height: size)
        .background(Color.white, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

/// 供应商额度文本（支持分段按各自余量彩色渲染，如 周 81% 绿 · 5h 90% 绿 / 5h 3% 红）。
private struct ProviderQuotaTextView: View {
    let provider: StatusBarProviderTick
    let font: Font
    var separatorColor: Color = .white.opacity(0.4)

    var body: some View {
        if provider.quotaSegments.count > 1 {
            HStack(spacing: 5) {
                ForEach(Array(provider.quotaSegments.enumerated()), id: \.offset) { index, segment in
                    if index > 0 {
                        Text("·")
                            .font(font)
                            .foregroundStyle(separatorColor)
                    }
                    Text(segment.text)
                        .font(font)
                        .foregroundStyle(segment.health.color)
                }
            }
        } else if let single = provider.quotaSegments.first {
            Text(single.text)
                .font(font)
                .foregroundStyle(
                    single.text.contains("暂不可查") ? Color.gray : single.health.color
                )
        } else {
            Text(provider.quotaText)
                .font(font)
                .foregroundStyle(
                    provider.quotaText.contains("暂不可查") ? Color.gray : provider.quotaHealth.color
                )
        }
    }
}
