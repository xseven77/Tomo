import Foundation
import Observation
import Network

@MainActor
@Observable
final class MobileSyncManager {
    static let shared = MobileSyncManager()

    private enum Keys {
        static let isEnabled = "tomo.mobileSync.isEnabled"
        static let port = "tomo.mobileSync.port"
        static let token = "tomo.mobileSync.token"
    }

    private(set) var isRunning: Bool = false
    private(set) var serverError: String?
    /// Mirrors `MobileSyncServer.status` so the settings UI can distinguish
    /// "starting" from "failed" from "stopped".
    private(set) var serverStatus: MobileSyncServer.Status = .idle
    /// True while the server is waiting to rebind after a failure.
    private(set) var isAwaitingRetry: Bool = false

    private let defaults = UserDefaults.standard
    private var server: MobileSyncServer?

    // Weak references to stores for snapshot building
    private weak var activityStore: CodexActivityStore?
    private weak var multiAgentSettingsStore: MultiAgentSettingsStore?
    private weak var appSettingsStore: AppSettingsStore?
    private weak var companionStatsStore: CompanionStatsStore?

    var isEnabled: Bool {
        get {
            defaults.object(forKey: Keys.isEnabled) as? Bool ?? true
        }
        set {
            defaults.set(newValue, forKey: Keys.isEnabled)
            if newValue {
                start()
            } else {
                stop()
            }
        }
    }

    var port: UInt16 {
        get {
            let saved = defaults.integer(forKey: Keys.port)
            return saved > 0 && saved <= 65535 ? UInt16(saved) : MobileSyncServer.defaultPort
        }
        set {
            defaults.set(Int(newValue), forKey: Keys.port)
            restart()
        }
    }

    var token: String {
        get {
            if let saved = defaults.string(forKey: Keys.token), !saved.isEmpty {
                return saved
            }
            let generated = Self.generateSecureToken()
            defaults.set(generated, forKey: Keys.token)
            return generated
        }
        set {
            defaults.set(newValue, forKey: Keys.token)
            restart()
        }
    }

    var lanIPv4: String {
        GatewayNetworkInfo.currentLANIPv4() ?? "127.0.0.1"
    }

    var webURLString: String {
        "http://\(lanIPv4):\(port)/?token=\(token)"
    }

    var pairingURLString: String {
        "tomo://pair?ip=\(lanIPv4)&port=\(port)&token=\(token)"
    }

    private init() {}

    // MARK: - Lifecycle

    func bind(
        activityStore: CodexActivityStore,
        multiAgentSettingsStore: MultiAgentSettingsStore,
        appSettingsStore: AppSettingsStore,
        companionStatsStore: CompanionStatsStore? = nil
    ) {
        self.activityStore = activityStore
        self.multiAgentSettingsStore = multiAgentSettingsStore
        self.appSettingsStore = appSettingsStore
        self.companionStatsStore = companionStatsStore
        companionStatsStore?.onMinutesChanged = { [weak self] in
            self?.broadcastSnapshot()
        }
        appSettingsStore.onThemeConfigChanged = { [weak self] config in
            guard let self, self.appSettingsStore?.syncThemeWithMobileEnabled == true else { return }
            self.broadcastThemeConfig(config)
        }
        appSettingsStore.onSyncThemeWithMobileChanged = { [weak self] enabled in
            guard let self else { return }
            self.broadcastThemeConfig()
        }

        if isEnabled {
            start()
        }
    }

    func start() {
        guard !isRunning else { return }

        let activeToken = self.token
        let activePort = self.port
        let provider = BridgeDataProvider(manager: self)
        let newServer = MobileSyncServer(
            port: activePort,
            token: activeToken,
            dataProvider: provider
        )

        // The listener binds asynchronously, so readiness is reported by the
        // server rather than assumed here.
        newServer.onStatusChange = { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self, self.server === newServer else { return }
                // Set the retry flag first: observers of `serverStatus` read
                // both values together and must not see a stale pair.
                self.isAwaitingRetry = newServer.isAwaitingRetry
                self.serverStatus = status
                switch status {
                case .ready:
                    self.isRunning = true
                    self.serverError = nil
                case .failed(let message):
                    self.isRunning = false
                    self.serverError = message
                case .idle, .starting:
                    self.isRunning = false
                }
            }
        }

        do {
            try newServer.start()
            self.server = newServer
            self.serverError = nil
        } catch {
            self.server = nil
            self.isRunning = false
            self.serverError = error.localizedDescription
        }
    }

    func stop() {
        server?.onStatusChange = nil
        server?.stop()
        server = nil
        isRunning = false
        serverStatus = .idle
        isAwaitingRetry = false
    }

    func restart() {
        stop()
        guard isEnabled else { return }
        // `NWListener.cancel()` releases the port asynchronously. Rebinding on
        // the very next line is what raced into EADDRINUSE and left the server
        // permanently down, so give the kernel a moment first.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self?.start()
        }
    }

    func regenerateToken() {
        token = Self.generateSecureToken()
    }

    func broadcastSnapshot() {
        guard isRunning, let server else { return }
        let snapshot = self.buildSnapshot()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snapshot),
           let jsonString = String(data: data, encoding: .utf8) {
            server.broadcast(event: "snapshot", data: jsonString)
        }
    }

    // MARK: - Snapshot Builder

    func buildSnapshot() -> MobileSnapshotPayload {
        let activePetId: String
        if let pet = appSettingsStore?.selectedPet {
            activePetId = pet.id
        } else {
            activePetId = "tomo"
        }

        // 1. Activity
        let activityPayload: MobileActivityPayload = {
            if let activityStore {
                let snap = activityStore.snapshot
                let tasks = snap.activeTasks.map { task in
                    MobileTaskPayload(
                        id: task.id,
                        state: task.state.rawValue,
                        title: task.agentDisplayName == "Deepseek Harness" ? "Deepseek Harness" : task.title,
                        agent: task.agentDisplayName,
                        detail: task.detail,
                        model: task.agentDisplayName == "Deepseek Harness" ? "Deepseek Harness" : task.model,
                        workspaceName: task.agentDisplayName == "Deepseek Harness" ? nil : task.workspaceName,
                        gitBranch: task.gitBranch
                    )
                }
                return MobileActivityPayload(
                    state: snap.state.rawValue,
                    activeTaskCount: snap.activeTaskCount,
                    activeTasks: tasks
                )
            }
            return MobileActivityPayload(state: "idle", activeTaskCount: 0, activeTasks: [])
        }()

        // 2. Connections (按 store.orderedConnectionKeys 顺序输出，与桌面端完全一致)
        var connections: [MobileConnectionPayload] = []
        if let store = multiAgentSettingsStore {
            for key in store.orderedConnectionKeys {
                if let account = store.codexAccounts.first(where: { store.connectionKey(for: $0) == key }), account.isEnabled {
                    let usage = account.usage
                    let hasRealShortWindow = (usage?.hasShortWindow == true) && (usage?.shortWindow?.label != "周额度")
                    let shortRemaining: Double? = hasRealShortWindow ? usage?.shortWindow.map { $0.percent * 100 } : nil
                    let shortResetAt: String? = hasRealShortWindow ? usage?.shortWindow?.resetsAt : nil

                    let weeklyRemaining: Double? = {
                        if let short = usage?.shortWindow, short.label == "周额度" {
                            return short.percent * 100
                        }
                        if let weekly = usage?.weekly, weekly.total > 0 {
                            return weekly.percent * 100
                        }
                        return nil
                    }()

                    let weeklyResetAt: String? = {
                        if let short = usage?.shortWindow, short.label == "周额度", !short.resetsAt.isEmpty && short.resetsAt != "未知" {
                            return UsageDateFormat.dateAndTime(short.resetsAt)
                        }
                        if let weekly = usage?.weekly, weekly.total > 0, !weekly.resetsAt.isEmpty && weekly.resetsAt != "未知" {
                            return UsageDateFormat.dateAndTime(weekly.resetsAt)
                        }
                        return nil
                    }()

                    let coupons: [MobileResetCouponPayload]? = usage?.resetCoupons.map { c in
                        MobileResetCouponPayload(
                            id: c.id.uuidString,
                            title: c.title ?? c.name,
                            description: c.description,
                            source: c.source,
                            grantedAt: c.grantedAt,
                            expiresAt: c.expiresAt,
                            status: c.status,
                            resetType: c.resetType,
                            profileImageURL: c.profileImageURL,
                            profileUserID: c.profileUserID
                        )
                    }

                    connections.append(
                        MobileConnectionPayload(
                            id: account.id.rawValue.uuidString,
                            provider: "codex",
                            label: account.label,
                            isHealthy: account.authenticationState == .connected,
                            shortWindowRemaining: shortRemaining,
                            weeklyRemaining: weeklyRemaining,
                            balance: nil,
                            accountName: usage?.accountName ?? account.label,
                            email: usage?.accountEmail ?? account.label,
                            planName: usage?.planName ?? "",
                            shortWindowLabel: hasRealShortWindow ? (usage?.shortWindow?.label ?? "5 小时") : nil,
                            shortWindowResetAt: shortResetAt,
                            weeklyWindowLabel: "本周",
                            weeklyWindowResetAt: weeklyResetAt,
                            subscriptionActiveUntilISO: usage?.subscriptionActiveUntilISO,
                            subscriptionWillRenew: usage?.subscriptionWillRenew,
                            subscriptionDaysRemaining: usage?.subscriptionDaysRemaining,
                            subscriptionReminderMessage: usage?.subscriptionExpiryReminderMessage,
                            subscriptionRenewalLine: usage?.subscriptionCompactSummaryLine,
                            resetCoupons: coupons,
                            statusColor: "green"
                        )
                    )
                } else if let conn = store.geminiConnections.first(where: { store.connectionKey(for: $0) == key }), conn.isEnabled {
                    let isConnected = conn.authenticationState == .connected
                    connections.append(
                        MobileConnectionPayload(
                            id: conn.id.rawValue.uuidString,
                            provider: "gemini",
                            label: conn.label,
                            isHealthy: isConnected,
                            shortWindowRemaining: conn.geminiFiveHourRemaining,
                            weeklyRemaining: conn.geminiWeeklyRemaining,
                            balance: nil,
                            accountName: conn.displayName ?? conn.label,
                            email: conn.email ?? conn.label,
                            planName: conn.planName ?? conn.tier ?? "Google AI Pro",
                            shortWindowLabel: "5小时额度",
                            shortWindowResetAt: conn.geminiFiveHourResetDesc,
                            weeklyWindowLabel: "本周额度",
                            weeklyWindowResetAt: conn.geminiWeeklyResetDesc,
                            claudeGptFiveHourRemaining: conn.claudeGptFiveHourRemaining,
                            claudeGptWeeklyRemaining: conn.claudeGptWeeklyRemaining,
                            statusColor: isConnected ? "green" : "amber"
                        )
                    )
                } else if let conn = store.deepSeekConnections.first(where: { store.connectionKey(for: $0) == key }), conn.isEnabled {
                    let isConnected = conn.authenticationState == .connected
                    let balanceStr = conn.balance.map { "\($0.total) \($0.currency)" }
                    let toppedUpStr = conn.balance.map { NSDecimalNumber(decimal: $0.toppedUp).stringValue }
                    let grantedStr = conn.balance.map { NSDecimalNumber(decimal: $0.granted).stringValue }
                    let lastValidatedStr: String? = conn.lastValidatedAt.map {
                        $0.formatted(date: .numeric, time: .shortened)
                    }

                    connections.append(
                        MobileConnectionPayload(
                            id: conn.id.rawValue.uuidString,
                            provider: "deepseek",
                            label: conn.label,
                            isHealthy: isConnected,
                            balance: balanceStr,
                            keySuffix: conn.keySuffix,
                            statusColor: isConnected ? "green" : "amber",
                            toppedUp: toppedUpStr,
                            granted: grantedStr,
                            availableModelCount: conn.availableModelIDs.count,
                            availableModelIDs: conn.availableModelIDs,
                            lastValidatedAt: lastValidatedStr
                        )
                    )
                } else if let conn = store.openCodeConnections.first(where: { store.connectionKey(for: $0) == key }), conn.isEnabled {
                    let isConnected = conn.authenticationState == .connected
                    connections.append(
                        MobileConnectionPayload(
                            id: conn.id.rawValue.uuidString,
                            provider: "opencode",
                            label: conn.label,
                            isHealthy: isConnected,
                            planName: conn.plan.displayName,
                            keySuffix: conn.keySuffix,
                            statusColor: isConnected ? "green" : "amber"
                        )
                    )
                }
            }
        }

        let todayMinutes = companionStatsStore?.todayMinutes ?? 0

        return MobileSnapshotPayload(
            schemaVersion: 1,
            generatedAt: Date(),
            activePetId: activePetId,
            todayMinutes: todayMinutes,
            activity: activityPayload,
            connections: connections
        )
    }

    func buildAvailablePets() -> [MobilePetMetadata] {
        guard let appSettingsStore else {
            return [
                MobilePetMetadata(
                    id: "tomo",
                    displayName: "Tomo",
                    description: "Signature spirit"
                )
            ]
        }

        return appSettingsStore.availablePets.map { pet in
            MobilePetMetadata(
                id: pet.id,
                displayName: pet.displayName,
                description: pet.description,
                frameWidth: 192,
                frameHeight: 208,
                totalRows: 11,
                totalColumns: 8
            )
        }
    }

    func exportCredentials() -> MobileCredentialsExportPayload {
        var accounts: [MobileCredentialAccountPayload] = []

        if let store = multiAgentSettingsStore {
            for conn in store.codexAccounts where conn.isEnabled {
                let token: String = {
                    guard let tokenURL = try? CodexAccountRuntimeManager().oauthTokenURL(for: conn),
                          let data = try? Data(contentsOf: tokenURL),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let access = json["accessToken"] as? String else {
                        return ""
                    }
                    return access
                }()
                accounts.append(
                    MobileCredentialAccountPayload(
                        id: conn.id.rawValue.uuidString,
                        provider: "codex",
                        label: conn.label,
                        tokenOrKey: token
                    )
                )
            }
            for conn in store.geminiConnections where conn.isEnabled {
                let token: String = {
                    guard let geminiToken = GeminiOAuthTokenStore().load(handle: conn.id.rawValue.uuidString) else {
                        return ""
                    }
                    return geminiToken.accessToken
                }()
                accounts.append(
                    MobileCredentialAccountPayload(
                        id: conn.id.rawValue.uuidString,
                        provider: "gemini",
                        label: conn.label,
                        tokenOrKey: token
                    )
                )
            }
            for conn in store.deepSeekConnections where conn.isEnabled {
                let key = (try? DeepSeekCredentialStore().read(handle: conn.id.rawValue.uuidString)) ?? ""
                accounts.append(
                    MobileCredentialAccountPayload(
                        id: conn.id.rawValue.uuidString,
                        provider: "deepseek",
                        label: conn.label,
                        tokenOrKey: key
                    )
                )
            }
            for conn in store.openCodeConnections where conn.isEnabled {
                let key = (try? OpenCodeCredentialStore().read(handle: conn.id.rawValue.uuidString)) ?? ""
                accounts.append(
                    MobileCredentialAccountPayload(
                        id: conn.id.rawValue.uuidString,
                        provider: "opencode",
                        label: conn.label,
                        tokenOrKey: key
                    )
                )
            }
        }

        return MobileCredentialsExportPayload(
            exportedAt: Date(),
            accounts: accounts
        )
    }

    func getThemeConfig() -> (config: TomoThemeConfig, syncEnabled: Bool) {
        let cfg = appSettingsStore?.themeConfig ?? .default
        let sync = appSettingsStore?.syncThemeWithMobileEnabled ?? true
        return (cfg, sync)
    }

    func updateThemeConfig(_ config: TomoThemeConfig) -> (success: Bool, synced: Bool, message: String?) {
        guard let appSettingsStore else {
            return (false, false, "AppSettingsStore not ready")
        }
        guard appSettingsStore.syncThemeWithMobileEnabled else {
            return (true, false, "Desktop theme sync is disabled")
        }
        appSettingsStore.themeConfig = config
        broadcastThemeConfig(config)
        return (true, true, nil)
    }

    func broadcastThemeConfig(_ config: TomoThemeConfig? = nil) {
        guard isRunning else { return }
        let current = config ?? (appSettingsStore?.themeConfig ?? .default)
        let sync = appSettingsStore?.syncThemeWithMobileEnabled ?? true
        let encoder = JSONEncoder()
        guard let configData = try? encoder.encode(current),
              let configObj = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            return
        }
        let payload: [String: Any] = [
            "config": configObj,
            "syncEnabled": sync
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let jsonString = String(data: data, encoding: .utf8) {
            server?.broadcast(event: "theme_updated", data: jsonString)
        }
    }

    private static func generateSecureToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Internal Bridge Data Provider

private final class BridgeDataProvider: MobileSyncDataProvider, @unchecked Sendable {
    private weak var manager: MobileSyncManager?

    init(manager: MobileSyncManager) {
        self.manager = manager
    }

    func makeSnapshot() async -> MobileSnapshotPayload {
        await MainActor.run { [weak self] in
            guard let manager = self?.manager else {
                return MobileSnapshotPayload(
                    schemaVersion: 1,
                    generatedAt: Date(),
                    activePetId: "tomo",
                    activity: MobileActivityPayload(state: "idle", activeTaskCount: 0, activeTasks: []),
                    connections: []
                )
            }
            return manager.buildSnapshot()
        }
    }

    func availablePets() -> [MobilePetMetadata] {
        DispatchQueue.main.sync { [weak self] in
            guard let manager = self?.manager else { return [] }
            return manager.buildAvailablePets()
        }
    }

    func exportCredentials() async -> MobileCredentialsExportPayload {
        await MainActor.run { [weak self] in
            guard let manager = self?.manager else {
                return MobileCredentialsExportPayload(accounts: [])
            }
            return manager.exportCredentials()
        }
    }

    func getThemeConfig() -> (config: TomoThemeConfig, syncEnabled: Bool) {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                manager?.getThemeConfig() ?? (.default, true)
            }
        }
        return DispatchQueue.main.sync { [weak self] in
            MainActor.assumeIsolated {
                self?.manager?.getThemeConfig() ?? (.default, true)
            }
        }
    }

    func updateThemeConfig(_ config: TomoThemeConfig) async -> (success: Bool, synced: Bool, message: String?) {
        await MainActor.run { [weak self] in
            guard let manager = self?.manager else {
                return (false, false, "MobileSyncManager unavailable")
            }
            return manager.updateThemeConfig(config)
        }
    }
}
