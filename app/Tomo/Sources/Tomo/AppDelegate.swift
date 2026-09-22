import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusBarController?
    private var windowController: DetachedWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var standalonePetWindowController: StandalonePetWindowController?
    private let snapshotStore = UsageSnapshotStore()
    private let settingsStore = AppSettingsStore()
    private let multiAgentSettingsStore = MultiAgentSettingsStore()
    private let activityStore = CodexActivityStore()
    private let agentEventSocketService = AgentEventSocketService()
    private let frameStore = PetFrameStore()
    private let companionStatsStore = CompanionStatsStore()
    private let updateController = AppUpdateController()
    private var actions: UsageActions?
    private var autoRefreshTimer: Timer?
    private var accountCarouselTimer: Timer?
    /// Invalidates callbacks that were already queued when the previous
    /// one-shot timer was cancelled (for example, immediately after a logo
    /// click).
    private var accountCarouselTimerGeneration = 0
    private var notchRefreshStateGeneration = 0
    private var codexPetSelectionMonitor: CodexPetSelectionMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // The Gateway is a background service for Pi/Hermes as well as the
        // Gateway window.  Start its supervisor at app launch rather than
        // waiting for a SwiftUI Gateway view to be instantiated.
        GatewaySupervisor.shared.start()
        settingsStore.applyAppearance()
        settingsStore.onAutoRefreshIntervalChanged = { [weak self] _ in
            self?.startAutoRefreshTimer()
        }
        settingsStore.onNetworkProxyChanged = {
            URLSession.reloadTomoExternalProxy()
            GatewaySupervisor.shared.restart()
        }
        settingsStore.onAccountCarouselIntervalChanged = { [weak self] _ in
            self?.startAccountCarouselTimer()
            self?.statusController?.refreshProviderCarouselTimer()
        }
        settingsStore.onMainWindowProviderCarouselEnabledChanged = { [weak self] _ in
            self?.startAccountCarouselTimer()
        }
        settingsStore.onNotchProviderCarouselEnabledChanged = { [weak self] _ in
            self?.startAccountCarouselTimer()
        }
        multiAgentSettingsStore.onSelectedConnectionChanged = { [weak self] in
            self?.syncSelectedCodexProjection()
            self?.startAccountCarouselTimer()
            self?.statusController?.refreshStatusTitle()
            MobileSyncManager.shared.broadcastSnapshot()
        }
        multiAgentSettingsStore.onAccountCarouselPauseChanged = { [weak self] _ in
            self?.startAccountCarouselTimer()
        }
        settingsStore.onThemeChanged = { [weak self] _ in
            self?.statusController?.refreshThemeAppearance()
            self?.windowController?.refreshThemeAppearance()
            self?.settingsWindowController?.refreshThemeAppearance()
            GatewayWindowController.shared.refreshThemeAppearance()
        }
        settingsStore.onWindowAlwaysOnTopChanged = { [weak self] _ in
            self?.windowController?.refreshAlwaysOnTop()
        }
        settingsStore.onNotchDisplayTargetChanged = { [weak self] target in
            self?.statusController?.refreshNotchDisplay()
            // 选择具体显示器后，在该屏幕边缘闪红边提示。
            if case .specificDisplay(let id) = target,
               let screen = NSScreen.screens.first(where: { $0.persistentID == id || String($0.screenNumber) == id }) {
                self?.statusController?.highlightScreen(screen)
            }
        }
        settingsStore.onNotchDraggingEnabledChanged = { [weak self] _ in
            self?.statusController?.refreshNotchDragConfiguration()
        }
        settingsStore.onNotchDisplayOffsetsChanged = { [weak self] in
            self?.statusController?.refreshNotchDragConfiguration()
        }
        settingsStore.onPetSettingsChanged = { [weak self] in
            self?.syncCompanionState()
            self?.statusController?.refreshStatusTitle()
            MobileSyncManager.shared.broadcastSnapshot()
        }
        settingsStore.onStandalonePetEnabledChanged = { [weak self] _ in
            self?.applyStandalonePetVisibility()
        }
        activityStore.onSnapshotChanged = { [weak self] snapshot in
            self?.frameStore.update(
                pet: self?.settingsStore.selectedPet,
                activityState: snapshot.state
            )
            let activeAgent: String? = {
                if let task = snapshot.activeTasks.first(where: { $0.state.showsActivityWave }) {
                    if task.id.hasPrefix("antigravity:") { return "antigravity" }
                    if task.id.hasPrefix("dsh:") { return "dsh" }
                    if task.id.hasPrefix("hermes:") { return "hermes" }
                    if task.id.hasPrefix("pi:") { return "pi" }
                    return "codex"
                }
                return nil
            }()
            self?.companionStatsStore.setActivityState(snapshot.state, agentID: activeAgent)
            self?.statusController?.refreshStatusTitle()
            MobileSyncManager.shared.broadcastSnapshot()
        }

        GatewayStore.shared.bind(
            activityStore: activityStore,
            companionStatsStore: companionStatsStore
        )
        GatewayWindowController.shared.multiAgentSettingsStore = multiAgentSettingsStore
        GatewayWindowController.shared.appSettings = settingsStore

        MobileSyncManager.shared.bind(
            activityStore: activityStore,
            multiAgentSettingsStore: multiAgentSettingsStore,
            appSettingsStore: settingsStore,
            companionStatsStore: companionStatsStore
        )

        let actions = UsageActions(
            refresh: { [weak self] in
                guard let self else { return }
                if self.hasAnyConnection {
                    self.manualRefreshUsage()
                } else {
                    self.loginAndFetchUsage()
                }
            },
            openUsagePage: {
                if let url = URL(string: "https://chatgpt.com/codex/settings/usage") {
                    NSWorkspace.shared.open(url)
                }
            },
            loginAndFetch: { [weak self] in
                self?.loginAndFetchUsage()
            },
            disconnect: { [weak self] in
                self?.disconnect()
            },
            openDetachedWindow: { [weak self] in
                self?.openDetachedWindow()
            },
            openGatewayWindow: {
                GatewayWindowController.shared.show()
            },
            quit: {
                NSApp.terminate(nil)
            }
        )

        self.actions = actions
        statusController = StatusBarController(
            store: snapshotStore,
            settings: settingsStore,
            activityStore: activityStore,
            multiAgentSettings: multiAgentSettingsStore,
            frameStore: frameStore,
            companionStatsStore: companionStatsStore,
            actions: actions,
            openDetachedWindowFromStatusItem: { [weak self] screen in
                self?.openDetachedWindow(on: screen)
            }
        )
        statusController?.onProviderSelection = { [weak self] in
            // Restart even when the user clicks the already-selected logo;
            // selectedConnectionKey does not change in that case.
            self?.startAccountCarouselTimer()
        }
        statusController?.onRefreshProvider = { [weak self] in
            guard let self else { return }
            if self.hasAnyConnection {
                self.manualRefreshUsage(showsToast: false)
            } else {
                self.loginAndFetchUsage()
            }
        }
        statusController?.onOpenSettings = { [weak self] in
            self?.openSettingsWindow()
        }
        startAutoRefreshTimer()
        startAccountCarouselTimer()
        activityStore.start()
        do {
            try agentEventSocketService.start { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.activityStore.ingest(event)
                }
            }
        } catch {
            NSLog("Tomo Agent event listener unavailable: %@", error.localizedDescription)
        }
        companionStatsStore.start()
        let petSelectionMonitor = CodexPetSelectionMonitor { [weak self] in
            self?.settingsStore.refreshPetsAndSyncSelectionFromCodex()
        }
        petSelectionMonitor.start()
        codexPetSelectionMonitor = petSelectionMonitor
        // AppSettings is constructed while the delegate itself is being
        // initialized, which can be too early for bundle-backed pet discovery.
        // Refresh once the application has finished launching so the first
        // click is interactive without requiring the user to re-select a pet.
        settingsStore.reloadPets(notify: false)
        settingsStore.syncPetSelectionFromCodex()
        syncCompanionState()
        applyStandalonePetVisibility()
        syncSelectedCodexProjection()
        if settingsStore.shouldOpenMainWindowAtLaunch {
            openDetachedWindow()
        }
        // WindowServer may still be rebuilding nonactivating panels after the
        // launch/activation sequence. Re-assert the persisted independent-Pet
        // preference once startup has settled, regardless of whether the main
        // window opened or an activation-policy branch was needed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.applyStandalonePetVisibility()
        }
        autoRefreshUsage()
    }

    func applicationWillTerminate(_ notification: Notification) {
        MobileSyncManager.shared.stop()
        GatewaySupervisor.shared.stop()
        multiAgentSettingsStore.stopCodexAppServers()
        agentEventSocketService.stop()
        activityStore.stop()
        companionStatsStore.stop()
        frameStore.stop()
        codexPetSelectionMonitor?.stop()
    }

    func applicationDidUpdate(_ notification: Notification) {
        settingsStore.refreshSystemAppearanceIfNeeded()
    }

    private func autoRefreshUsage() {
        // 启动和定时刷新不改变刘海面板按钮的结果状态；只有用户主动
        // 点击刷新时，按钮才显示 loading / success / warning。
        performUnifiedRefresh(showsToast: false, updatesNotchIndicator: false)
    }

    /// 是否已有任一可刷新的供应商连接。
    /// 只有完全没有连接时才把「刷新」升级成「登录」。
    private var hasAnyConnection: Bool {
        !multiAgentSettingsStore.codexAccounts.isEmpty
            || !multiAgentSettingsStore.deepSeekConnections.isEmpty
            || !multiAgentSettingsStore.openCodeConnections.isEmpty
    }

    private func manualRefreshUsage(showsToast: Bool = true) {
        // 手动刷新：先重置自动刷新倒计时，等本次刷新全部加载结束后再重新计时。
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil
        performUnifiedRefresh(showsToast: showsToast)
    }

    /// OAuth 登录流程：创建一个新的 Codex 连接并刷新额度。
    private func loginAndFetchUsage() {
        Task { [weak self] in
            guard let self else { return }
            _ = await self.multiAgentSettingsStore.addCodexAccount()
            self.syncSelectedCodexProjection()
            self.statusController?.refreshStatusTitle()
        }
    }

    private func performUnifiedRefresh(
        showsToast: Bool,
        updatesNotchIndicator: Bool = true
    ) {
        guard !snapshotStore.isUnifiedRefreshing else {
            if showsToast {
                snapshotStore.showManualRefreshToast(for: RefreshOutcome(failures: ["正在刷新，请稍候"]))
            }
            return
        }

        snapshotStore.setUnifiedRefreshing(true)
        if updatesNotchIndicator {
            statusController?.updateNotchProviderRefreshState(.loading)
        }
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.multiAgentSettingsStore.refreshAllConnections()
            // Account refresh is also the dynamic model-catalog refresh. If
            // Hermes/Pi are already connected, update their allowlists only
            // when this official catalog actually changed.
            await GatewayStore.shared.syncConfiguredAgentCatalogsIfNeeded()
            self.syncSelectedCodexProjection()
            self.statusController?.refreshStatusTitle()
            self.snapshotStore.setUnifiedRefreshing(false)
            if updatesNotchIndicator {
                self.finishNotchRefresh(outcome)
            }
            // 本次刷新（手动或自动）全部结束后，重新开始自动刷新倒计时。
            self.startAutoRefreshTimer()
            if showsToast {
                self.snapshotStore.showManualRefreshToast(for: outcome)
            }
        }
    }

    private func finishNotchRefresh(_ outcome: RefreshOutcome) {
        notchRefreshStateGeneration &+= 1
        let generation = notchRefreshStateGeneration
        if outcome.failures.isEmpty {
            statusController?.updateNotchProviderRefreshState(.success)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.notchRefreshStateGeneration == generation else { return }
                self.statusController?.updateNotchProviderRefreshState(.idle)
            }
        } else {
            // A warning is intentionally sticky until the next refresh.
            statusController?.updateNotchProviderRefreshState(.warning)
        }
    }

    private func disconnect() {
        multiAgentSettingsStore.disconnectSelectedConnection()
        syncSelectedCodexProjection()
        statusController?.refreshStatusTitle()
    }

    /// The legacy snapshot store is now only a view projection of the selected
    /// Codex connection; it is no longer an independent account/auth store.
    private func syncSelectedCodexProjection() {
        guard let account = multiAgentSettingsStore.selectedCodexAccount else {
            snapshotStore.markDisconnected()
            return
        }
        snapshotStore.isLoggedIn = account.authenticationState == .connected
        if let usage = account.usage {
            snapshotStore.apply(usage)
        } else if snapshotStore.snapshot.sourceURL == "preview" {
            snapshotStore.snapshot = .empty(refreshState: "等待刷新")
        }
    }

    private func openDetachedWindow(on screen: NSScreen? = nil) {
        guard let actions else { return }
        settingsStore.syncPetSelectionFromCodex()

        if windowController == nil {
            windowController = DetachedWindowController(
                store: snapshotStore,
                settings: settingsStore,
                multiAgentSettings: multiAgentSettingsStore,
                activityStore: activityStore,
                frameStore: frameStore,
                companionStatsStore: companionStatsStore,
                updater: updateController,
                actions: actions,
                onOpenSettings: { [weak self] in
                    self?.openSettingsWindow()
                },
                onClose: { [weak self] in
                    self?.handleDetachedWindowClosed()
                }
            )
        }

        // Present first. Changing activation policy can synchronously ask Dock
        // and WindowServer to re-register the app, which made a capsule click
        // feel delayed when the app was in menu-bar-only mode.
        windowController?.show(on: screen)
        NSApp.activate(ignoringOtherApps: true)

        guard NSApp.activationPolicy() != .regular else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.windowController != nil else { return }
            NSApp.setActivationPolicy(.regular)
            self.windowController?.show(on: screen)
            // Switching from the menu-bar accessory policy to a regular app
            // makes WindowServer re-register the app's panels. The detached
            // window is presented again above; restore the independent Pet for
            // the same reason so launch does not require toggling its setting.
            self.applyStandalonePetVisibility()
            NSApp.activate(ignoringOtherApps: true)
            // setActivationPolicy returns before WindowServer has necessarily
            // finished rebuilding every nonactivating panel. Re-order the Pet
            // once more on the next main-loop turn, after that registration.
            DispatchQueue.main.async { [weak self] in
                self?.applyStandalonePetVisibility()
            }
        }
    }

    private func syncCompanionState() {
        frameStore.update(
            pet: settingsStore.selectedPet,
            activityState: activityStore.snapshot.state
        )
    }

    private func applyStandalonePetVisibility() {
        guard settingsStore.standalonePetEnabled else {
            standalonePetWindowController?.hide()
            return
        }
        if standalonePetWindowController == nil {
            standalonePetWindowController = StandalonePetWindowController(
                activityStore: activityStore,
                frameStore: frameStore,
                settings: settingsStore
            )
        }
        standalonePetWindowController?.show()
    }

    private func openSettingsWindow(tab: SettingsTab? = nil) {
        guard let actions else { return }
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                store: snapshotStore,
                settings: settingsStore,
                multiAgentSettings: multiAgentSettingsStore,
                updater: updateController,
                actions: actions,
                initialTab: tab,
                onClose: { [weak self] in
                    self?.handleSettingsWindowClosed()
                }
            )
        } else if let tab {
            settingsWindowController?.selectTab(tab)
        }

        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        let targetScreen = windowController?.currentScreen
        settingsWindowController?.show(tab: tab, on: targetScreen)
        DispatchQueue.main.async { [weak self] in
            self?.settingsWindowController?.show(tab: tab, on: targetScreen)
        }
    }

    private func handleDetachedWindowClosed() {
        windowController = nil
        if settingsWindowController == nil {
            // Return to menu-bar-only mode only after both independent windows close.
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func handleSettingsWindowClosed() {
        settingsWindowController = nil
        if windowController == nil {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openDetachedWindow()
        }
        return true
    }

    /// 自动刷新调度：one-shot timer，每次刷新全部结束后重新计时，
    /// 保证倒计时从「上次刷新完成」开始算，而不是固定时钟。
    /// 手动刷新会先重置倒计时（见 `manualRefreshUsage`），
    /// 等手动刷新全部加载完后再由 `performUnifiedRefresh` 的收尾重新启动。
    private func startAutoRefreshTimer() {
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil

        guard let interval = settingsStore.autoRefreshInterval.timeInterval else { return }

        autoRefreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.autoRefreshUsage()
            }
        }
    }

    /// 唯一的账号轮播调度源。one-shot timer 会在手动或自动选择后重新完整计时，
    /// 避免 SwiftUI 为布局测量创建视图副本时产生重复轮播任务。
    ///
    /// 供应商自动轮播支持主窗口与刘海面板分别配置独立开关：
    /// - 主窗口开启：推进全局选中账号；若刘海开启则同步推进，若刘海关闭则刘海保持当前显示不被带偏；
    /// - 仅刘海开启：主窗口保持不变，仅推进刘海面板自身的账号轮播；
    /// - 两者均关闭：停止调度。
    private func startAccountCarouselTimer() {
        accountCarouselTimerGeneration &+= 1
        let generation = accountCarouselTimerGeneration
        accountCarouselTimer?.invalidate()
        accountCarouselTimer = nil

        guard (settingsStore.mainWindowProviderCarouselEnabled || settingsStore.notchProviderCarouselEnabled),
              let interval = settingsStore.accountCarouselInterval.timeInterval,
              !multiAgentSettingsStore.isAccountCarouselPaused
        else { return }

        accountCarouselTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      generation == self.accountCarouselTimerGeneration
                else { return }
                self.accountCarouselTimer = nil
                self.advanceAccountCarousel()
            }
        }
    }

    private func advanceAccountCarousel() {
        let mainEnabled = settingsStore.mainWindowProviderCarouselEnabled
        let notchEnabled = settingsStore.notchProviderCarouselEnabled

        guard mainEnabled || notchEnabled else { return }

        if mainEnabled {
            // 主窗口开启自动轮播：推进全局选中账号。
            // 若刘海面板关闭自动轮播，通知 statusController 忽略本次自动推进对刘海显示的影响。
            if !notchEnabled {
                statusController?.isAutoCarouselAdvancing = true
            }
            multiAgentSettingsStore.selectNextConnection()
            statusController?.isAutoCarouselAdvancing = false
        } else if notchEnabled {
            // 仅刘海面板开启轮播：主窗口选中保持不变，仅推进刘海面板自身的账号轮播。
            let advanced = statusController?.advanceNotchProviderCarousel() ?? false
            if advanced {
                startAccountCarouselTimer()
            }
        }
    }
}
