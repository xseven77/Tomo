import AppKit
import SwiftUI

// MARK: - 显示器红边预览

/// 选择显示器时，在目标屏幕边缘闪烁红边提示。
@MainActor
final class ScreenHighlightOverlay {
    private var activePanels: [NSPanel] = []

    func flash(on screen: NSScreen) {
        clearAll()
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: screen.frame.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.contentViewController = NSHostingController(rootView: RedBorderView())
        panel.alphaValue = 0
        panel.setFrame(screen.frame, display: false)
        panel.orderFrontRegardless()
        activePanels.append(panel)

        panel.animator().alphaValue = 1

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            panel.animator().alphaValue = 0
            try? await Task.sleep(nanoseconds: 260_000_000)
            panel.orderOut(nil)
            self?.activePanels.removeAll { $0 === panel }
        }
    }

    func clearAll() {
        for panel in activePanels {
            panel.orderOut(nil)
        }
        activePanels.removeAll()
    }
}

private struct RedBorderView: View {
    var body: some View {
        Rectangle()
            .strokeBorder(Color.red, lineWidth: 6)
    }
}

// MARK: - 降级胶囊面板（非目标屏幕顶部居中悬浮胶囊）

@MainActor
final class LegacyCapsulePanelController {
    private let panel: NSPanel
    private let hosting: NSHostingController<LegacyCapsuleView>
    var onClick: (() -> Void)?

    init() {
        hosting = NSHostingController(rootView: LegacyCapsuleView())
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 30),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .statusBar
    }

    func update(text: String, indicatorColor: NSColor, showsWave: Bool) {
        hosting.rootView = LegacyCapsuleView(
            text: text,
            indicatorColor: indicatorColor,
            showsWave: showsWave,
            onClick: { [weak self] in self?.onClick?() }
        )
        // 固定尺寸，防止 NSHostingController 按空内容 fittingSize 把窗口缩成 38×26。
        panel.setContentSize(NSSize(width: 240, height: 30))
    }

    func show(on screen: NSScreen) {
        let size = NSSize(width: 240, height: 30)
        panel.setFrame(
            NSRect(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.maxY - 38,
                width: size.width,
                height: size.height
            ),
            display: false
        )
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

private struct LegacyCapsuleView: View {
    var text: String = ""
    var indicatorColor: NSColor = .secondaryLabelColor
    var showsWave = false
    var onClick: (() -> Void)?

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color(nsColor: indicatorColor))
                .frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.black.opacity(0.78))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Color.white.opacity(0.92), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.7))
        .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
        .overlay {
            if showsWave {
                Capsule().strokeBorder(Color(nsColor: indicatorColor).opacity(0.6), lineWidth: 1)
            }
        }
        .contentShape(Capsule())
        .onTapGesture { onClick?() }
    }
}

// MARK: - 显示器目标智能决断器

enum NotchDisplayResolver {
    /// 目标屏幕无损决断算法：
    /// 1. .off -> 严格保持关闭，返回空列表。
    /// 2. .allDisplays -> 返回当前所有连接的屏幕。
    /// 3. .specificDisplay(targetID):
    ///    a. 当前连接屏幕中存在 targetID（或历史数字 ID）时，精准匹配返回该屏幕。
    ///    b. targetID 当前离线时，若存在其他外接屏，智能漫游至最近使用或首个外接屏（保持外接使用意图）。
    ///    c. 若无任何外接屏，自动平滑回退至内建屏幕。
    @MainActor
    static func resolveActiveScreens(
        from screens: [NSScreen],
        target: NotchDisplayTarget,
        knownDisplays: [String: KnownDisplayRecord] = [:]
    ) -> [NSScreen] {
        guard !screens.isEmpty else { return [] }
        switch target {
        case .off:
            return []
        case .allDisplays:
            return screens
        case .specificDisplay(let targetID):
            // 1. 精准匹配：首选显示器当前连接中（同时兼容历史数字 ID）
            if let matched = screens.first(where: { $0.persistentID == targetID || String($0.screenNumber) == targetID }) {
                return [matched]
            }
            // 2. 首选外接屏当前未连接：智能漫游到当前连接的其他外接显示器（保持用户在外接屏使用刘海的意图）
            let externalScreens = screens.filter { !$0.isBuiltin }
            if !externalScreens.isEmpty {
                let preferred = externalScreens.max { s1, s2 in
                    let t1 = knownDisplays[s1.persistentID]?.lastSeen ?? .distantPast
                    let t2 = knownDisplays[s2.persistentID]?.lastSeen ?? .distantPast
                    return t1 < t2
                } ?? externalScreens[0]
                return [preferred]
            }
            // 3. 无任何外接显示器连接（如外出使用笔记本）：自动平滑回退至内建显示器
            if let builtin = screens.first(where: \.isBuiltin) {
                return [builtin]
            }
            return screens.first.map { [$0] } ?? []
        }
    }
}

