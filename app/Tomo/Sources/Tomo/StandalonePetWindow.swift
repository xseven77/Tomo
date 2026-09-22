import AppKit
import SwiftUI
import Observation
import Combine

/// 独立 Pet 吸附的屏幕边缘（含四角）。
enum StandalonePetEdge: String, CaseIterable, Identifiable, Sendable {
    case top
    case right
    case bottom
    case left
    case topRight
    case bottomRight
    case topLeft
    case bottomLeft

    var id: String { rawValue }

    var title: String {
        switch self {
        case .top: "靠上"
        case .right: "靠右"
        case .bottom: "靠下"
        case .left: "靠左"
        case .topRight: "右上"
        case .bottomRight: "右下"
        case .topLeft: "左上"
        case .bottomLeft: "左下"
        }
    }

    var symbolName: String {
        switch self {
        case .top: "arrow.up.to.line"
        case .right: "arrow.right.to.line"
        case .bottom: "arrow.down.to.line"
        case .left: "arrow.left.to.line"
        case .topRight: "arrow.up.right"
        case .bottomRight: "arrow.down.right"
        case .topLeft: "arrow.up.left"
        case .bottomLeft: "arrow.down.left"
        }
    }

    var isVertical: Bool {
        switch self {
        case .top, .bottom, .topLeft, .topRight, .bottomLeft, .bottomRight: true
        case .left, .right: false
        }
    }
}

/// 独立 Pet 窗口的尺寸契约。`scale` 只缩放 Pet 本身，任务栈与窗口留白保持固定。
enum StandalonePetLayout {
    static let basePetHeight: CGFloat = 120
    static let edgeGap: CGFloat = 14
    /// 缩放区间（设置里的 slider 与这里保持一致）。
    static let scaleRange: ClosedRange<Double> = 0.8...1.8

    /// 任务栈几何（固定，不随 scale 变化）。
    static let taskRowHeight: CGFloat = 60
    static let taskRowSpacing: CGFloat = 12
    static let taskStackPadding: CGFloat = 12
    static let maxVisibleTaskRows = 4
    static let stackToPetSpacing: CGFloat = 6
    /// Pet 与窗口边缘、任务栈与窗口边缘的统一留白（固定）。
    static let outerPadding: CGFloat = 10
    /// 收起态顶部给角标预留的高度（固定）。
    static let badgeClearance: CGFloat = 12
    /// 任务弹窗的固定宽度。
    static let taskPanelWidth: CGFloat = 316

    static func petDisplayHeight(scale: Double) -> CGFloat {
        basePetHeight * scale
    }

    static func petDisplayWidth(scale: Double) -> CGFloat {
        petDisplayHeight(scale: scale) * CGFloat(PetSpriteSheet.cellWidth) / CGFloat(PetSpriteSheet.cellHeight)
    }

    /// 收起态窗口：只装 Pet，随 Pet 一起缩放。
    static func collapsedSize(scale: Double) -> NSSize {
        NSSize(
            width: petDisplayWidth(scale: scale) + outerPadding * 2,
            height: petDisplayHeight(scale: scale) + outerPadding + badgeClearance
        )
    }

    /// 任务弹窗内容高度：空态用固定高度，否则按「最多 4 条」的行数计算，超出的内部滚动。
    static func stackHeight(taskCount: Int) -> CGFloat {
        if taskCount <= 0 { return 84 }
        let rows = min(taskCount, maxVisibleTaskRows)
        return CGFloat(rows) * (taskRowHeight + taskRowSpacing)
            - taskRowSpacing
            + taskStackPadding * 2
    }

    /// 任务弹窗尺寸（独立窗口，只有任务栈，不随 scale 变化）。
    static func taskPanelSize(taskCount: Int) -> NSSize {
        NSSize(width: taskPanelWidth, height: stackHeight(taskCount: taskCount))
    }
}

/// 独立 Pet 的交互状态。任务数据与 Pet 帧来自 CodexActivityStore / PetFrameStore，
/// 这里只保存「位置、缩放、展开」等 UI 状态。
@MainActor
@Observable
final class StandalonePetViewModel {
    var edge: StandalonePetEdge = .bottom
    var freeOrigin: NSPoint?
    var scale: Double = 1.0
    var isExpanded = false
    var taskCount = 0

    /// 自由拖拽时固定按「靠下」布局展开（任务弹窗在 Pet 上方），吸附时跟随所选边。
    var effectiveEdge: StandalonePetEdge {
        freeOrigin != nil ? .bottom : edge
    }

    @ObservationIgnored var onLayoutChange: (() -> Void)?
    @ObservationIgnored var onEdgeChange: ((StandalonePetEdge) -> Void)?
    @ObservationIgnored var onHide: (() -> Void)?
    @ObservationIgnored var onBeginDrag: (() -> Void)?
    @ObservationIgnored var onDragChange: (() -> Void)?
    @ObservationIgnored var onEndDrag: (() -> Void)?
    @ObservationIgnored var onOpenTask: ((CodexTaskActivity) -> Void)?
    @ObservationIgnored var onTaskCountChanged: ((Int) -> Void)?

    func toggleExpanded() {
        withAnimation(.easeOut(duration: 0.18)) {
            isExpanded.toggle()
        }
        onLayoutChange?()
    }

    func setEdge(_ newEdge: StandalonePetEdge) {
        guard edge != newEdge || freeOrigin != nil else { return }
        edge = newEdge
        freeOrigin = nil
        onEdgeChange?(newEdge)
        onLayoutChange?()
    }

    func openTask(_ task: CodexTaskActivity) {
        onOpenTask?(task)
    }

    func taskCountDidChange(_ count: Int) {
        guard taskCount != count else { return }
        taskCount = count
        onTaskCountChanged?(count)
    }

    // MARK: 拖拽

    func beginDrag() {
        onBeginDrag?()
    }

    func updateDrag() {
        onDragChange?()
    }

    func endDrag() {
        onEndDrag?()
    }
}


/// 独立 Pet 窗口：两个透明置顶的 NSPanel —— 一个是固定尺寸的 Pet，另一个是
/// 独立定位的任务弹窗。任务弹窗的开关/移动都不会改变 Pet 窗口的位置。
@MainActor
final class StandalonePetWindowController {
    private let petPanel: NSPanel
    private let taskPanel: NSPanel
    private let model: StandalonePetViewModel
    private let settings: AppSettingsStore
    private let activityStore: CodexActivityStore
    private var mouseDownScreenLocation: NSPoint?
    private var petOriginAtDragStart: NSPoint?
    private var taskOriginAtDragStart: NSPoint?

    init(
        activityStore: CodexActivityStore,
        frameStore: PetFrameStore,
        settings: AppSettingsStore
    ) {
        self.settings = settings
        self.activityStore = activityStore
        model = StandalonePetViewModel()
        model.edge = settings.standalonePetEdge
        model.freeOrigin = settings.standalonePetFreeOrigin
        model.scale = settings.standalonePetScale

        petPanel = Self.makePanel(size: StandalonePetLayout.collapsedSize(scale: model.scale))
        taskPanel = Self.makePanel(size: StandalonePetLayout.taskPanelSize(taskCount: 0))

        let petView = StandalonePetView(
            frameStore: frameStore,
            model: model
        )
        let petHosting = NSHostingController(rootView: petView)
        petHosting.view.wantsLayer = true
        petHosting.view.layer?.backgroundColor = NSColor.clear.cgColor
        petPanel.contentViewController = petHosting

        let taskView = StandaloneTaskPanelView(
            activityStore: activityStore,
            model: model
        )
        let taskHosting = NSHostingController(rootView: taskView)
        taskHosting.view.wantsLayer = true
        taskHosting.view.layer?.backgroundColor = NSColor.clear.cgColor
        taskPanel.contentViewController = taskHosting

        model.onLayoutChange = { [weak self] in
            self?.applyLayout()
        }
        model.onEdgeChange = { [weak self] edge in
            self?.settings.standalonePetEdge = edge
            self?.settings.standalonePetFreeOrigin = nil
        }
        model.onHide = { [weak self] in
            self?.settings.standalonePetEnabled = false
        }
        model.onBeginDrag = { [weak self] in
            self?.mouseDownScreenLocation = NSEvent.mouseLocation
            self?.petOriginAtDragStart = self?.petPanel.frame.origin
            self?.taskOriginAtDragStart = self?.taskPanel.frame.origin
        }
        model.onDragChange = { [weak self] in
            self?.applyDrag()
        }
        model.onEndDrag = { [weak self] in
            self?.finishDrag()
        }
        model.onOpenTask = { task in
            _ = AgentTaskOpener.open(task)
        }
        model.onTaskCountChanged = { [weak self] _ in
            self?.relayoutTaskPanel()
        }

        settings.onStandalonePetSettingsChanged = { [weak self] in
            self?.settingsDidChange()
        }
    }

    var isVisible: Bool { petPanel.isVisible }

    func show() {
        syncModelFromSettings()
        syncTaskCount()
        relayoutPet()
        petPanel.orderFrontRegardless()
        if model.isExpanded {
            relayoutTaskPanel()
            taskPanel.orderFrontRegardless()
        }
    }

    func hide() {
        petPanel.orderOut(nil)
        taskPanel.orderOut(nil)
    }

    private static func makePanel(size: NSSize) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces]
        panel.animationBehavior = .none
        return panel
    }

    private var taskCount: Int {
        activityStore.snapshot.activeTasks.count
    }

    private var visibleFrame: NSRect {
        (petPanel.screen ?? NSScreen.main)?.visibleFrame ?? .zero
    }

    private func syncModelFromSettings() {
        model.edge = settings.standalonePetEdge
        model.freeOrigin = settings.standalonePetFreeOrigin
        model.scale = settings.standalonePetScale
    }

    private func syncTaskCount() {
        model.taskCount = activityStore.snapshot.activeTasks.count
    }

    private func settingsDidChange() {
        syncModelFromSettings()
        syncTaskCount()
        applyLayout()
    }

    private func applyLayout() {
        syncTaskCount()
        relayoutPet()
        if model.isExpanded {
            relayoutTaskPanel()
            taskPanel.orderFrontRegardless()
        } else {
            taskPanel.orderOut(nil)
        }
    }

    // MARK: - 布局

    private func relayoutPet() {
        let size = StandalonePetLayout.collapsedSize(scale: model.scale)
        let visible = visibleFrame
        let frame: NSRect
        if let freeOrigin = model.freeOrigin {
            var origin = freeOrigin
            origin.x = min(max(origin.x, visible.minX + StandalonePetLayout.edgeGap), visible.maxX - size.width - StandalonePetLayout.edgeGap)
            origin.y = min(max(origin.y, visible.minY + StandalonePetLayout.edgeGap), visible.maxY - size.height - StandalonePetLayout.edgeGap)
            frame = NSRect(origin: origin, size: size)
        } else {
            frame = Self.edgeFrame(size: size, edge: model.edge, in: visible)
        }
        petPanel.setFrame(frame, display: true)
    }

    private func relayoutTaskPanel() {
        let size = StandalonePetLayout.taskPanelSize(taskCount: taskCount)
        let frame = Self.taskPanelFrame(
            relativeTo: petPanel.frame,
            size: size,
            in: visibleFrame
        )
        taskPanel.setFrame(frame, display: true)
    }

    /// 吸附定位：贴边居中，四角贴住对应角。internal 供测试验证四角布局。
    static func edgeFrame(size: NSSize, edge: StandalonePetEdge, in visible: NSRect) -> NSRect {
        let gap = StandalonePetLayout.edgeGap
        switch edge {
        case .bottom:
            return NSRect(
                x: round(visible.midX - size.width / 2),
                y: visible.minY + gap,
                width: size.width,
                height: size.height
            )
        case .top:
            return NSRect(
                x: round(visible.midX - size.width / 2),
                y: visible.maxY - size.height - gap,
                width: size.width,
                height: size.height
            )
        case .left:
            return NSRect(
                x: visible.minX + gap,
                y: round(visible.midY - size.height / 2),
                width: size.width,
                height: size.height
            )
        case .right:
            return NSRect(
                x: visible.maxX - size.width - gap,
                y: round(visible.midY - size.height / 2),
                width: size.width,
                height: size.height
            )
        case .topLeft:
            return NSRect(
                x: visible.minX + gap,
                y: visible.maxY - size.height - gap,
                width: size.width,
                height: size.height
            )
        case .topRight:
            return NSRect(
                x: visible.maxX - size.width - gap,
                y: visible.maxY - size.height - gap,
                width: size.width,
                height: size.height
            )
        case .bottomLeft:
            return NSRect(
                x: visible.minX + gap,
                y: visible.minY + gap,
                width: size.width,
                height: size.height
            )
        case .bottomRight:
            return NSRect(
                x: visible.maxX - size.width - gap,
                y: visible.minY + gap,
                width: size.width,
                height: size.height
            )
        }
    }

    /// 任务弹窗相对 Pet 定位：无论吸附在哪条边 / 哪个角，都保持与拖拽时一致的
    /// 原始布局——水平居中于 Pet 上方展开，最后夹在屏幕可见区域内。
    private static func taskPanelFrame(
        relativeTo petFrame: NSRect,
        size: NSSize,
        in visible: NSRect
    ) -> NSRect {
        let spacing = StandalonePetLayout.stackToPetSpacing
        let gap = StandalonePetLayout.edgeGap
        var origin = NSPoint(
            x: petFrame.midX - size.width / 2,
            y: petFrame.maxY + spacing
        )
        origin.x = min(max(origin.x, visible.minX + gap), visible.maxX - size.width - gap)
        origin.y = min(max(origin.y, visible.minY + gap), visible.maxY - size.height - gap)
        return NSRect(origin: origin, size: size)
    }

    // MARK: - 拖拽

    private func applyDrag() {
        guard let mouseDown = mouseDownScreenLocation,
              let petStart = petOriginAtDragStart else { return }
        let current = NSEvent.mouseLocation
        let deltaX = current.x - mouseDown.x
        let deltaY = current.y - mouseDown.y
        petPanel.setFrameOrigin(NSPoint(x: petStart.x + deltaX, y: petStart.y + deltaY))
        if taskPanel.isVisible, let taskStart = taskOriginAtDragStart {
            taskPanel.setFrameOrigin(NSPoint(x: taskStart.x + deltaX, y: taskStart.y + deltaY))
        }
    }

    private func finishDrag() {
        defer {
            mouseDownScreenLocation = nil
            petOriginAtDragStart = nil
            taskOriginAtDragStart = nil
        }
        settings.standalonePetFreeOrigin = petPanel.frame.origin
    }
}

/// 独立 Pet 窗口内容：只装 Pet + 角标，负责拖拽 / 点击切换 / 右键菜单。
private struct StandalonePetView: View {
    @Bindable var frameStore: PetFrameStore
    @Bindable var model: StandalonePetViewModel

    @State private var isHoveringPet = false
    @State private var isDragging = false

    var body: some View {
        petControl
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(petInsets)
    }

    private var petInsets: EdgeInsets {
        let outer = StandalonePetLayout.outerPadding
        switch model.effectiveEdge {
        case .bottom:
            return EdgeInsets(top: 0, leading: 0, bottom: outer, trailing: 0)
        case .top:
            return EdgeInsets(top: outer, leading: 0, bottom: 0, trailing: 0)
        case .left:
            return EdgeInsets(top: 0, leading: outer, bottom: 0, trailing: 0)
        case .right:
            return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: outer)
        case .topLeft:
            return EdgeInsets(top: outer, leading: outer, bottom: 0, trailing: 0)
        case .topRight:
            return EdgeInsets(top: outer, leading: 0, bottom: 0, trailing: outer)
        case .bottomLeft:
            return EdgeInsets(top: 0, leading: outer, bottom: outer, trailing: 0)
        case .bottomRight:
            return EdgeInsets(top: 0, leading: 0, bottom: outer, trailing: outer)
        }
    }

    private var petControl: some View {
        ZStack(alignment: .topTrailing) {
            petImage
                .scaleEffect(isHoveringPet && !isDragging ? 1.05 : 1)
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.14)) { isHoveringPet = hovering }
                    if hovering {
                        // 悬停进入时随机播放一个 Pet 动作。
                        frameStore.playRandomIdleAction()
                        if !isDragging { NSCursor.pointingHand.set() }
                    } else if !isDragging {
                        NSCursor.arrow.set()
                    }
                }
                .gesture(petDragGesture)
                .contextMenu { petContextMenu }

            if !model.isExpanded && model.taskCount > 0 {
                taskCountBadge
            }
        }
        .frame(
            width: StandalonePetLayout.petDisplayWidth(scale: model.scale),
            height: StandalonePetLayout.petDisplayHeight(scale: model.scale),
            alignment: .center
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tomo Pet · \(model.taskCount) 个任务")
        .accessibilityAddTraits(.isButton)
    }

    private var petDragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let distance = hypot(value.translation.width, value.translation.height)
                if !isDragging && distance > 6 {
                    isDragging = true
                    NSCursor.closedHand.set()
                    model.beginDrag()
                }
                if isDragging {
                    model.updateDrag()
                }
            }
            .onEnded { _ in
                if isDragging {
                    model.endDrag()
                    NSCursor.arrow.set()
                } else {
                    model.toggleExpanded()
                }
                isDragging = false
            }
    }

    @ViewBuilder
    private var petImage: some View {
        if let frame = frameStore.currentFrame {
            Image(nsImage: frame)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
        } else {
            Image(systemName: "sparkles")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Color.codexPrimary)
        }
    }

    private var taskCountBadge: some View {
        Text("\(model.taskCount)")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 22)
            .background(Color.accentColor, in: Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1))
            .offset(x: 6, y: -6)
    }

    @ViewBuilder
    private var petContextMenu: some View {
        ForEach(StandalonePetEdge.allCases) { edge in
            Button {
                model.setEdge(edge)
            } label: {
                Label(edge.title, systemImage: edge.symbolName)
            }
        }
        Divider()
        Button {
            model.onHide?()
        } label: {
            Label("隐藏独立 Pet", systemImage: "eye.slash")
        }
    }
}

/// 任务弹窗内容：独立的流体玻璃任务栈，只负责展示任务列表，不包含 Pet。
private struct StandaloneTaskPanelView: View {
    @Bindable var activityStore: CodexActivityStore
    @Bindable var model: StandalonePetViewModel

    private var tasks: [CodexTaskActivity] {
        activityStore.snapshot.activeTasks
    }

    var body: some View {
        taskStack
            .opacity(model.isExpanded ? 1 : 0)
            .scaleEffect(model.isExpanded ? 1 : 0.94, anchor: .bottom)
            .animation(.easeOut(duration: 0.18), value: model.isExpanded)
            .onChange(of: tasks.count) { _, newCount in
                model.taskCountDidChange(newCount)
            }
    }

    private var taskStack: some View {
        ScrollView {
            LazyVStack(spacing: StandalonePetLayout.taskRowSpacing) {
                if tasks.isEmpty {
                    emptyState
                } else {
                    ForEach(tasks) { task in
                        taskRow(task)
                            .frame(height: StandalonePetLayout.taskRowHeight)
                    }
                }
            }
            .padding(.vertical, StandalonePetLayout.taskStackPadding)
            .padding(.horizontal, 8)
        }
        .scrollIndicators(.never)
    }

    private var emptyState: some View {
        fluidGlass(
            HStack(spacing: 8) {
                Spacer()
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.codexMuted)
                Text("暂无进行中的任务")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.codexMuted)
                Spacer()
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 60)
        )
    }

    @ViewBuilder
    private func taskRow(_ task: CodexTaskActivity) -> some View {
        let row = taskRowContent(task)
        if AgentTaskOpener.canOpen(task) {
            Button {
                model.openTask(task)
            } label: {
                row
            }
            .buttonStyle(CodexPressableCardStyle(cornerRadius: 14, ink: .custom(task.state.statusColor)))
            .shadow(color: Color.black.opacity(0.06), radius: 3, x: 0, y: 1)
        } else {
            row
                .shadow(color: Color.black.opacity(0.06), radius: 3, x: 0, y: 1)
        }
    }

    private func taskRowContent(_ task: CodexTaskActivity) -> some View {
        let content = HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                BrandIconView(
                    asset: BrandAssetID.forAgentDisplayName(task.agentDisplayName),
                    size: 30,
                    cornerRadius: 9
                )
                Circle()
                    .fill(task.state.statusColor)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1))
                    .offset(x: 2, y: 2)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    ShimmerText(
                        text: task.title,
                        font: .system(size: 10.5, weight: .semibold),
                        base: .codexInk,
                        highlight: task.state.statusColor
                    )
                    .lineLimit(1)
                    Text(task.agentDisplayName)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(Color.codexMuted)
                        .lineLimit(1)
                }
                Text("\(task.state.taskLabel) · \(task.detail)")
                    .font(.system(size: 8.5))
                    .foregroundStyle(Color.codexMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if AgentTaskOpener.canOpen(task) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.codexMuted.opacity(0.7))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)

        return fluidGlass(content, cornerRadius: 14)
    }

    @ViewBuilder
    private func fluidGlass<Content: View>(_ content: Content, cornerRadius: CGFloat = 14) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            content.glassEffect(in: .rect(cornerRadius: cornerRadius))
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

/// 文字流光：用 Canvas 直接绘制「底色文字 + 高光文字（clip 到移动亮带）」，
/// 绕过 SwiftUI 叠层 / mask 在这个非激活面板里可能不渲染的问题。
private struct ShimmerText: View {
    let text: String
    var font: Font = .system(size: 8.5)
    var base: Color = .codexMuted
    var highlight: Color = .white

    @State private var offset: CGFloat = 0
    @State private var measuredWidth: CGFloat = 0
    private let timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        // 隐藏文字仅用于测量尺寸。
        Text(text)
            .font(font)
            .lineLimit(1)
            .foregroundStyle(Color.clear)
            .overlay {
                GeometryReader { geo in
                    shimmerCanvas
                        .onAppear { measuredWidth = geo.size.width }
                }
            }
            .onReceive(timer) { _ in
                advance()
            }
    }

    private var band: CGFloat { max(24, measuredWidth * 0.5) }

    private var shimmerCanvas: some View {
        Canvas { context, size in
            let bandWidth = max(24, size.width * 0.5)
            let origin = CGPoint.zero

            // 1. 底色文字
            context.draw(
                Text(text).font(font).foregroundStyle(base),
                at: origin,
                anchor: .topLeading
            )

            // 2. clip 到移动的亮带
            context.clipToLayer { layer in
                let bandRect = CGRect(
                    x: offset,
                    y: 0,
                    width: bandWidth,
                    height: size.height
                )
                layer.fill(
                    Path(bandRect),
                    with: .linearGradient(
                        Gradient(colors: [.clear, .white, .white, .clear]),
                        startPoint: CGPoint(x: offset, y: 0),
                        endPoint: CGPoint(x: offset + bandWidth, y: 0)
                    )
                )
            }

            // 3. 高光文字（只显示在亮带内）
            context.draw(
                Text(text).font(font).foregroundStyle(highlight),
                at: origin,
                anchor: .topLeading
            )
        }
    }

    private func advance() {
        guard measuredWidth > 0 else { return }
        let travel = measuredWidth + 2 * band
        offset += travel / 72.0
        if offset > measuredWidth + band { offset = -band }
    }
}
