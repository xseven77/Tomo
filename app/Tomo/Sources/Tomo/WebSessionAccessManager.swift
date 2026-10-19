import AppKit
import Foundation
import Observation

/// The owner's switch for web sessions, and the only place a web page's request
/// is approved: a confirmation window that shows the page's origin and a code
/// the page shows too.
@MainActor @Observable final class WebSessionAccessManager {
    static let shared = WebSessionAccessManager()
    private(set) var isEnabled: Bool
    /// Pages that currently hold an approved window.
    private(set) var windows: [WebSessionAccess.WindowInfo] = []
    private let defaults: UserDefaults
    /// The window length the owner picked, or nil for a refusal.
    private let confirm: @MainActor (WebSessionAccess.PendingRequest) async -> TimeInterval?
    private let sourceRoot: URL
    private static let key = "tomo.webSessions.enabled"
    @ObservationIgnored private var access: WebSessionAccess?
    @ObservationIgnored private var server: MobileSyncServer?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var asked = Set<UUID>()

    init(defaults: UserDefaults = .standard,
         confirm: @escaping @MainActor (WebSessionAccess.PendingRequest) async -> TimeInterval? = { await WebSessionConfirmation.ask($0) },
         sourceRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) {
        self.defaults = defaults; self.confirm = confirm; self.sourceRoot = sourceRoot
        isEnabled = defaults.bool(forKey: Self.key)
    }
    deinit { monitor?.cancel() }

    /// The desktop server owns the session sources a page may read. A restarted
    /// server gets a fresh authorization; nothing carries over.
    func attach(to server: MobileSyncServer) {
        detach()
        let sources = WebSessionSources(reads: server.remoteReadService,
            load: { [root = sourceRoot] in try await RemoteProductionManager.chatGPTSources(root) })
        let access = WebSessionAccess(access: server.remoteAccess,
            scopes: { await sources.scopes() },
            prepare: { try await sources.prepare() },
            teardown: { await sources.teardown() })
        self.server = server; self.access = access
        server.installWebSessionAccess(access)
        guard isEnabled else { return }
        Task { [weak self] in
            await access.setEnabled(true)
            self?.startMonitor()
        }
    }

    func detach() {
        monitor?.cancel(); monitor = nil
        server?.installWebSessionAccess(nil)
        let old = access
        access = nil; server = nil; windows = []; asked = []
        if let old { Task { await old.setEnabled(false) } }
    }

    func setEnabled(_ value: Bool) {
        isEnabled = value
        defaults.set(value, forKey: Self.key)
        guard let access else { return }
        Task { [weak self] in
            await access.setEnabled(value)
            if value { self?.startMonitor() } else { self?.stopMonitor() }
        }
    }

    func extend(_ id: UUID, duration: TimeInterval) {
        guard let access else { return }
        Task { [weak self] in
            await access.extend(windowId: id, duration: duration)
            await self?.refresh()
        }
    }

    func disconnect(_ id: UUID) {
        guard let access else { return }
        Task { [weak self] in
            await access.disconnect(windowId: id)
            await self?.refresh()
        }
    }

    /// Runs only while the switch is on, so an idle desktop does no polling.
    private func startMonitor() {
        guard monitor == nil, isEnabled, access != nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopMonitor() {
        monitor?.cancel(); monitor = nil
        windows = []; asked = []
    }

    func refresh() async {
        guard let access else { return }
        await access.tick()
        if let next = await access.pendingRequests().first(where: { !asked.contains($0.id) }) {
            asked.insert(next.id)
            let duration = await confirm(next)
            await access.decide(id: next.id, allow: duration != nil, duration: duration)
        }
        let current = await access.activeWindows()
        if current != windows { windows = current }
    }
}

@MainActor enum WebSessionConfirmation {
    /// Refusal is the default button, so a stray Return never approves a request.
    static func ask(_ request: WebSessionAccess.PendingRequest) async -> TimeInterval? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "网页请求使用会话"
        alert.informativeText = """
        来源：\(request.origin)
        核对码：\(request.code)

        请确认网页上显示的核对码与这里一致。允许后，该网页在你选的时长内可以只读查看这台 Mac 上的会话，不能处理审批；随时可以在设置里断开。

        如果不是你刚刚发起的，请拒绝。
        """
        alert.addButton(withTitle: "拒绝")
        alert.addButton(withTitle: "允许")
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26), pullsDown: false)
        for option in WebSessionDuration.all { picker.addItem(withTitle: option.title) }
        picker.selectItem(at: WebSessionDuration.defaultIndex)
        alert.accessoryView = picker
        // The page stops waiting when the request lapses; a window that outlives it
        // would only invite a click that does nothing, so it closes as a refusal.
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(1, request.expiresAt.timeIntervalSinceNow)))
            if !Task.isCancelled { NSApp.abortModal() }
        }
        defer { watchdog.cancel() }
        guard alert.runModal() == .alertSecondButtonReturn else { return nil }
        return WebSessionDuration.all[max(0, picker.indexOfSelectedItem)].seconds
    }
}

enum WebSessionDuration {
    static let all: [(title: String, seconds: TimeInterval)] = [
        ("15 分钟", 900), ("1 小时", 3600), ("8 小时", 28800), ("永久（到关闭开关或退出 Tomo）", WebSessionAccess.permanent),
    ]
    static let defaultIndex = 1
}
