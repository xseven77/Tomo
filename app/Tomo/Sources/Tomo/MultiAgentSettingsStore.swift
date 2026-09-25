import Foundation
import Observation

enum ConnectionCarousel {
    static func nextKey(after selectedKey: String, availableKeys: [String]) -> String? {
        guard availableKeys.count > 1 else { return nil }
        guard let selectedIndex = availableKeys.firstIndex(of: selectedKey) else {
            return availableKeys.first
        }
        return availableKeys[(selectedIndex + 1) % availableKeys.count]
    }
}

enum AccountCarouselPauseSource: Hashable {
    case dashboard
    case dashboardInfo
    case notch(screenNumber: UInt32)
}

struct ProviderQuickConnectivityResult: Identifiable, Sendable {
    let provider: String
    let accountLabel: String
    let isAvailable: Bool
    let detail: String

    var id: String { "\(provider):\(accountLabel)" }
}

@MainActor
@Observable
final class MultiAgentSettingsStore {
    private static let selectedConnectionDefaultsKey = "dashboard.selectedConnection"
    private let hookManager: AgentHookManager
    private let registryStorage: ConnectionRegistryStorage
    private let codexRuntimeManager: CodexAccountRuntimeManager
    private let codexAppServerSupervisor: CodexAppServerSupervisor
    private let credentialStore: any DeepSeekCredentialStoring
    private let deepSeekBalanceService: any DeepSeekBalanceFetching
    private let deepSeekModelsService: any DeepSeekModelsFetching
    private let openCodeCredentialStore: any OpenCodeCredentialStoring
    private let openCodeModelsService: any OpenCodeModelsFetching
    private let geminiOAuthTokenStore: any GeminiOAuthTokenStoring
    private let geminiOAuthService: any GeminiOAuthServicing

    private(set) var integrations: [AgentIntegrationStatus] = []
    private(set) var codexAccounts: [CodexAccountConnection] = []
    private(set) var deepSeekConnections: [DeepSeekAPIConnection] = []
    private(set) var openCodeConnections: [OpenCodeAPIConnection] = []
    private(set) var geminiConnections: [GeminiAccountConnection] = []
    private(set) var connectionOrder: [String] = []
    private(set) var isMutatingConnections = false
    private(set) var isRefreshingConnections = false
    /// 正在单独请求中的连接 id（按账号分开加载：完成一个移除一个）。
    private(set) var refreshingConnectionIDs: Set<ConnectionID> = []
    private(set) var isCodexOAuthInProgress = false
    private(set) var isGeminiOAuthInProgress = false
    /// Existing-account OAuth is single-flight; this identifies the row that
    /// owns the active browser authorization.
    private(set) var activeGeminiOAuthConnectionID: ConnectionID?
    private(set) var lastMessage: String?
    private(set) var isAccountCarouselPaused = false
    private var accountCarouselPauseSources: Set<AccountCarouselPauseSource> = []
    var onSelectedConnectionChanged: (() -> Void)?
    var onAccountCarouselPauseChanged: ((Bool) -> Void)?
    private var activeCodexOAuthService: CodexUsageService?
    private var activeGeminiOAuthService: (any GeminiOAuthServicing)?
    @ObservationIgnored nonisolated(unsafe) private var agentStatusObserver: (any NSObjectProtocol)?
    var selectedConnectionKey: String {
        didSet {
            guard selectedConnectionKey != oldValue else { return }
            UserDefaults.standard.set(selectedConnectionKey, forKey: Self.selectedConnectionDefaultsKey)
            onSelectedConnectionChanged?()
        }
    }

    deinit {
        if let observer = agentStatusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    init(
        hookManager: AgentHookManager = AgentHookManager(),
        registryStorage: ConnectionRegistryStorage = ConnectionRegistryStorage(),
        codexRuntimeManager: CodexAccountRuntimeManager = CodexAccountRuntimeManager(),
        codexAppServerSupervisor: CodexAppServerSupervisor = CodexAppServerSupervisor(),
        credentialStore: any DeepSeekCredentialStoring = DeepSeekCredentialStore(),
        deepSeekBalanceService: any DeepSeekBalanceFetching = DeepSeekBalanceService(),
        deepSeekModelsService: any DeepSeekModelsFetching = DeepSeekModelsService(),
        openCodeCredentialStore: any OpenCodeCredentialStoring = OpenCodeCredentialStore(),
        openCodeModelsService: any OpenCodeModelsFetching = OpenCodeModelsService(),
        geminiOAuthTokenStore: any GeminiOAuthTokenStoring = GeminiOAuthTokenStore(),
        geminiOAuthService: any GeminiOAuthServicing = GeminiOAuthService(),
        startsAutomaticRefresh: Bool = true,
        migratesLegacyAccount: Bool = true
    ) {
        self.hookManager = hookManager
        self.registryStorage = registryStorage
        self.codexRuntimeManager = codexRuntimeManager
        self.codexAppServerSupervisor = codexAppServerSupervisor
        self.credentialStore = credentialStore
        self.deepSeekBalanceService = deepSeekBalanceService
        self.deepSeekModelsService = deepSeekModelsService
        self.openCodeCredentialStore = openCodeCredentialStore
        self.openCodeModelsService = openCodeModelsService
        self.geminiOAuthTokenStore = geminiOAuthTokenStore
        self.geminiOAuthService = geminiOAuthService
        selectedConnectionKey = UserDefaults.standard.string(forKey: Self.selectedConnectionDefaultsKey)
            ?? ""
        let registry = registryStorage.load()
        codexAccounts = registry.codexAccounts
        deepSeekConnections = registry.deepSeekConnections
        openCodeConnections = registry.openCodeConnections
        geminiConnections = registry.geminiConnections
        if migratesLegacyAccount {
            migrateLegacyCodexAccountIfNeeded()
        }
        connectionOrder = registry.connectionOrder
        purgeLegacyGeminiCredentials()
        refresh()
        validateSelectedConnection()
        agentStatusObserver = NotificationCenter.default.addObserver(
            forName: .agentIntegrationStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, (note.object as? AnyObject) !== self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.integrations = self.hookManager.integrationStatuses()
            }
        }
        if startsAutomaticRefresh {
            Task { await refreshAllConnections() }
        }
    }

    func refresh() {
        integrations = hookManager.integrationStatuses()
        NotificationCenter.default.post(name: .agentIntegrationStatusDidChange, object: self)
    }

    func reloadConnections() {
        let registry = registryStorage.load()
        codexAccounts = registry.codexAccounts
        deepSeekConnections = registry.deepSeekConnections
        openCodeConnections = registry.openCodeConnections
        geminiConnections = registry.geminiConnections
        connectionOrder = registry.connectionOrder
        selectedConnectionKey = UserDefaults.standard.string(forKey: Self.selectedConnectionDefaultsKey) ?? ""
        refresh()
        validateSelectedConnection()
        onSelectedConnectionChanged?()
        Task { await refreshAllConnections() }
    }

    func clearLastMessage() {
        lastMessage = nil
    }

    func selectCodexConnection(_ connection: CodexAccountConnection) {
        selectedConnectionKey = "codex.\(connection.id.rawValue.uuidString.lowercased())"
    }

    func selectDeepSeekConnection(_ connection: DeepSeekAPIConnection) {
        selectedConnectionKey = "deepseek.\(connection.id.rawValue.uuidString.lowercased())"
    }

    func selectOpenCodeConnection(_ connection: OpenCodeAPIConnection) {
        selectedConnectionKey = connectionKey(for: connection)
    }

    func setAccountCarouselPaused(
        _ isPaused: Bool,
        source: AccountCarouselPauseSource = .dashboard
    ) {
        if isPaused {
            accountCarouselPauseSources.insert(source)
        } else {
            accountCarouselPauseSources.remove(source)
        }

        let shouldPause = !accountCarouselPauseSources.isEmpty
        guard isAccountCarouselPaused != shouldPause else { return }
        isAccountCarouselPaused = shouldPause
        onAccountCarouselPauseChanged?(shouldPause)
    }

    func selectNextConnection() {
        let keys = orderedConnectionKeys
        guard let nextKey = ConnectionCarousel.nextKey(
            after: selectedConnectionKey,
            availableKeys: keys
        ) else { return }

        if let account = codexAccounts.first(where: { connectionKey(for: $0) == nextKey }) {
            selectCodexConnection(account)
        } else if let connection = deepSeekConnections.first(where: { connectionKey(for: $0) == nextKey }) {
            selectDeepSeekConnection(connection)
        } else if let connection = openCodeConnections.first(where: { connectionKey(for: $0) == nextKey }) {
            selectOpenCodeConnection(connection)
        } else if let connection = geminiConnections.first(where: { connectionKey(for: $0) == nextKey }) {
            selectGeminiConnection(connection)
        }
    }

    func isSelected(_ connection: CodexAccountConnection) -> Bool {
        selectedConnectionKey == "codex.\(connection.id.rawValue.uuidString.lowercased())"
    }

    func isSelected(_ connection: DeepSeekAPIConnection) -> Bool {
        selectedConnectionKey == "deepseek.\(connection.id.rawValue.uuidString.lowercased())"
    }

    func isSelected(_ connection: OpenCodeAPIConnection) -> Bool {
        selectedConnectionKey == connectionKey(for: connection)
    }

    func isSelected(_ connection: GeminiAPIConnection) -> Bool {
        selectedConnectionKey == connectionKey(for: connection)
    }

    var selectedCodexAccount: CodexAccountConnection? {
        codexAccounts.first(where: isSelected)
    }

    var selectedDeepSeekConnection: DeepSeekAPIConnection? {
        deepSeekConnections.first(where: isSelected)
    }

    var selectedOpenCodeConnection: OpenCodeAPIConnection? {
        openCodeConnections.first(where: isSelected)
    }

    var selectedGeminiConnection: GeminiAPIConnection? {
        geminiConnections.first(where: isSelected)
    }

    func selectGeminiConnection(_ connection: GeminiAPIConnection) {
        selectedConnectionKey = connectionKey(for: connection)
    }

    @discardableResult
    func refreshCodexAccounts() async -> RefreshOutcome {
        guard !isRefreshingConnections else {
            return RefreshOutcome(failures: ["连接正在刷新"])
        }
        isRefreshingConnections = true
        defer { isRefreshingConnections = false }

        refreshingConnectionIDs.formUnion(codexAccounts.map(\.id))
        var outcome = RefreshOutcome()
        for connection in codexAccounts {
            outcome.merge(await refreshCodexAccountWithoutLock(connection))
            refreshingConnectionIDs.remove(connection.id)
        }
        return outcome
    }

    /// Shared refresh entry point for the timer and every manual refresh
    /// surface. New connection types should be added here so there is only one
    /// scheduling policy for all accounts and API keys.
    ///
    /// 每个供应商独立并发请求、各自完成后立即生效（互不等待），最后合并成统一结果。
    @discardableResult
    func refreshAllConnections() async -> RefreshOutcome {
        guard !isRefreshingConnections, !isMutatingConnections else {
            return RefreshOutcome(failures: ["连接正在刷新"])
        }
        isRefreshingConnections = true
        defer { isRefreshingConnections = false }

        let codexAccounts = self.codexAccounts
        let deepSeekConnections = self.deepSeekConnections
        let openCodeConnections = self.openCodeConnections
        let geminiConnections = self.geminiConnections
        // 先登记全部账号为「加载中」，各自完成后逐个移除，
        // 让界面可以按账号单独展示加载 / 完成状态。
        refreshingConnectionIDs.formUnion(codexAccounts.map(\.id))
        refreshingConnectionIDs.formUnion(deepSeekConnections.map(\.id))
        refreshingConnectionIDs.formUnion(openCodeConnections.map(\.id))
        refreshingConnectionIDs.formUnion(geminiConnections.map(\.id))

        var tasks: [Task<RefreshOutcome, Never>] = []
        for connection in codexAccounts {
            tasks.append(Task { @MainActor [weak self] in
                let outcome = await self?.refreshCodexAccountWithoutLock(connection) ?? RefreshOutcome()
                self?.refreshingConnectionIDs.remove(connection.id)
                return outcome
            })
        }
        for connection in deepSeekConnections {
            tasks.append(Task { @MainActor [weak self] in
                let outcome = await self?.refreshDeepSeekConnectionWithoutLock(connection, publishesMessage: false)
                    ?? RefreshOutcome()
                self?.refreshingConnectionIDs.remove(connection.id)
                return outcome
            })
        }
        for connection in openCodeConnections {
            tasks.append(Task { @MainActor [weak self] in
                let outcome = await self?.refreshOpenCodeConnectionWithoutLock(connection, publishesMessage: false)
                    ?? RefreshOutcome()
                self?.refreshingConnectionIDs.remove(connection.id)
                return outcome
            })
        }
        for connection in geminiConnections {
            tasks.append(Task { @MainActor [weak self] in
                let outcome = await self?.refreshGeminiConnectionWithoutLock(connection, publishesMessage: false)
                    ?? RefreshOutcome()
                self?.refreshingConnectionIDs.remove(connection.id)
                return outcome
            })
        }

        var outcome = RefreshOutcome()
        for task in tasks {
            outcome.merge(await task.value)
        }
        return outcome
    }

    /// Runs one lightweight, authenticated request for each configured
    /// provider. This is intentionally separate from the per-model Gateway
    /// health check: it validates the proxy route and account credentials
    /// without sending inference requests for every model.
    func quickCheckEnabledProviders() async -> [ProviderQuickConnectivityResult] {
        var results: [ProviderQuickConnectivityResult] = []

        if let connection = codexAccounts.first(where: \.isEnabled) {
            do {
                let tokenURL = try codexRuntimeManager.oauthTokenURL(for: connection)
                let service = CodexUsageService(tokenStore: CodexOAuthTokenStore(fileURL: tokenURL))
                let models = try await service.fetchAvailableModels()
                results.append(.init(provider: "Codex", accountLabel: connection.label, isAvailable: true, detail: "OAuth 与模型目录可达（\(models.count) 个模型）"))
            } catch {
                results.append(.init(provider: "Codex", accountLabel: connection.label, isAvailable: false, detail: error.localizedDescription))
            }
        }

        if let connection = geminiConnections.first(where: \.isEnabled) {
            if let token = geminiOAuthTokenStore.load(handle: connection.credentialHandle) {
                do {
                    let models = try await geminiOAuthService.validateModels(accessToken: token.accessToken)
                    results.append(.init(provider: "Gemini", accountLabel: connection.label, isAvailable: true, detail: "OAuth 与 Cloud Code 模型目录可达（\(models.count) 个模型）"))
                } catch {
                    results.append(.init(provider: "Gemini", accountLabel: connection.label, isAvailable: false, detail: error.localizedDescription))
                }
            } else {
                results.append(.init(provider: "Gemini", accountLabel: connection.label, isAvailable: false, detail: "本地 OAuth Token 缺失，请重新登录"))
            }
        }

        if let connection = deepSeekConnections.first(where: \.isEnabled) {
            do {
                let key = try credentialStore.read(handle: connection.credentialHandle)
                let models = try await deepSeekModelsService.validate(apiKey: key)
                results.append(.init(provider: "DeepSeek", accountLabel: connection.label, isAvailable: true, detail: "API Key 与模型目录可达（\(models.count) 个模型）"))
            } catch {
                results.append(.init(provider: "DeepSeek", accountLabel: connection.label, isAvailable: false, detail: error.localizedDescription))
            }
        }

        if let connection = openCodeConnections.first(where: \.isEnabled) {
            do {
                let key = try openCodeCredentialStore.read(handle: connection.credentialHandle)
                let models = try await openCodeModelsService.validate(apiKey: key, plan: connection.plan)
                results.append(.init(provider: "OpenCode", accountLabel: connection.label, isAvailable: true, detail: "API Key 与模型目录可达（\(models.count) 个模型）"))
            } catch {
                results.append(.init(provider: "OpenCode", accountLabel: connection.label, isAvailable: false, detail: error.localizedDescription))
            }
        }

        return results
    }

    /// 抓取单个 Codex 账号的额度结果（纯抓取，不修改状态）。
    private func fetchCodexAccountResult(_ connection: CodexAccountConnection) async -> CodexAccountRefreshResult {
        let manager = codexRuntimeManager
        let supervisor = codexAppServerSupervisor

        guard connection.isEnabled else {
            // Proxy is disabled → the account is not routing, but that is not a
            // login problem. Returning `.needsLogin` here would overwrite the
            // account's real authentication state on the next periodic refresh,
            // and re-enabling the proxy would then stay stuck ("connected" no
            // longer holds). Preserve the current state so a disabled account
            // keeps its true login status.
            return CodexAccountRefreshResult(
                id: connection.id,
                state: connection.authenticationState,
                usage: connection.usage,
                availableModels: connection.availableModelIDs
            )
        }
        let tokenStore: CodexOAuthTokenStore
        do {
            tokenStore = CodexOAuthTokenStore(fileURL: try manager.oauthTokenURL(for: connection))
        } catch {
            return CodexAccountRefreshResult(id: connection.id, state: .needsLogin, usage: nil)
        }

        if tokenStore.hasStoredToken() {
            do {
                let service = CodexUsageService(tokenStore: tokenStore)
                let snapshot = try await service.fetchWithStoredToken()
                let models = try await service.fetchAvailableModels()
                return CodexAccountRefreshResult(
                    id: connection.id,
                    state: .connected,
                    usage: snapshot,
                    availableModels: models,
                    didFetchAvailableModels: true
                )
            } catch let codexError as CodexUsageError where codexError == .noStoredToken || codexError == .invalidTokenResponse {
                // 令牌缺失或已失效 → 需要重新登录。
                return CodexAccountRefreshResult(id: connection.id, state: .needsLogin, usage: nil)
            } catch CodexUsageError.quotaUnavailable {
                // 令牌有效但额度接口暂不可用 → 保持「已连接」，仅保留旧额度。
                let service = CodexUsageService(tokenStore: tokenStore)
                guard let models = try? await service.fetchAvailableModels() else {
                    return CodexAccountRefreshResult(
                        id: connection.id,
                        state: .connected,
                        usage: connection.usage,
                        availableModels: connection.availableModelIDs
                    )
                }
                return CodexAccountRefreshResult(
                    id: connection.id,
                    state: .connected,
                    usage: connection.usage,
                    availableModels: models,
                    didFetchAvailableModels: true
                )
            } catch {
                // 网络抖动等瞬时错误 → 不降级，保留原状态。
                return CodexAccountRefreshResult(id: connection.id, state: connection.authenticationState, usage: connection.usage, availableModels: connection.availableModelIDs)
            }
        }

        // 没有本地 OAuth token → 回退到 CLI `codex login` 状态。
        let state = manager.authenticationState(for: connection)
        guard state == .connected else {
            return CodexAccountRefreshResult(id: connection.id, state: state, usage: nil)
        }
        do {
            let usage = try supervisor.snapshot(
                for: connection,
                homeURL: manager.homeURL(for: connection),
                executableURL: manager.locateCodexExecutable()
            )
            return CodexAccountRefreshResult(id: connection.id, state: .connected, usage: codexUsage(from: usage))
        } catch {
            return CodexAccountRefreshResult(id: connection.id, state: state, usage: nil)
        }
    }

    /// 应用单个账号的刷新结果（立即生效）并返回其刷新结果。
    private func applyCodexAccountResult(
        _ result: CodexAccountRefreshResult,
        for connection: CodexAccountConnection
    ) -> RefreshOutcome {
        var changed = false
        if let index = codexAccounts.firstIndex(where: { $0.id == result.id }) {
            if codexAccounts[index].authenticationState != result.state {
                codexAccounts[index].authenticationState = result.state
                changed = true
            }
            if let usage = result.usage, codexAccounts[index].usage != usage {
                codexAccounts[index].usage = usage
                changed = true
            }
            if result.didFetchAvailableModels && codexAccounts[index].availableModelIDs != result.availableModels {
                codexAccounts[index].availableModelIDs = result.availableModels
                changed = true
            }
        }
        if changed { try? saveRegistry() }

        guard connection.isEnabled else { return RefreshOutcome() }
        if result.state == .connected, result.usage != nil {
            return RefreshOutcome(successCount: 1)
        } else {
            return RefreshOutcome(failures: ["\(connection.label) 未能刷新"])
        }
    }

    private func refreshCodexAccountWithoutLock(_ connection: CodexAccountConnection) async -> RefreshOutcome {
        let result = await fetchCodexAccountResult(connection)
        return applyCodexAccountResult(result, for: connection)
    }

    func stopCodexAppServers() {
        codexAppServerSupervisor.stopAll()
    }

    func cancelCurrentCodexOAuth() {
        guard isCodexOAuthInProgress, let service = activeCodexOAuthService else { return }
        lastMessage = "正在取消 Codex 登录…"
        Task { await service.cancelOAuthAuthorization() }
    }

    func addCodexAccount() async -> Bool {
        guard !isMutatingConnections else { return false }
        isMutatingConnections = true
        defer { isMutatingConnections = false }
        var pendingConnection: CodexAccountConnection?
        var pendingTokenStore: CodexOAuthTokenStore?
        do {
            let fallback = "Codex 账号 \(codexAccounts.count + 1)"
            var connection = try codexRuntimeManager.createAccount(label: fallback)
            pendingConnection = connection
            let tokenStore = CodexOAuthTokenStore(
                fileURL: try codexRuntimeManager.oauthTokenURL(for: connection)
            )
            pendingTokenStore = tokenStore
            let service = CodexUsageService(tokenStore: tokenStore)
            activeCodexOAuthService = service
            isCodexOAuthInProgress = true
            defer {
                activeCodexOAuthService = nil
                isCodexOAuthInProgress = false
            }
            let snapshot = try await service.connectAndFetch(forceLogin: true)
            let models = (try? await service.fetchAvailableModels()) ?? []
            connection.label = normalizedLabel(
                snapshot.accountName ?? snapshot.accountEmail,
                fallback: fallback
            )
            connection.authenticationState = .connected
            connection.isEnabled = true
            connection.usage = snapshot
            connection.availableModelIDs = models
            codexAccounts.append(connection)
            try saveRegistry()
            selectCodexConnection(connection)
            lastMessage = "已登录并保存 \(connection.label)"
            return true
        } catch {
            // OAuth 已成功落盘 token，只是额度抓取失败（如请求超时）→ 仍视为已登录。
            if let pendingConnection,
               let tokenStore = pendingTokenStore,
               tokenStore.hasStoredToken() {
                var connection = pendingConnection
                connection.authenticationState = .connected
                connection.isEnabled = true
                connection.usage = nil
                codexAccounts.append(connection)
                try? saveRegistry()
                selectCodexConnection(connection)
                lastMessage = "已登录，额度获取失败：\(error.localizedDescription)"
                return true
            }
            if let pendingConnection {
                try? codexRuntimeManager.removeRuntime(for: pendingConnection)
            }
            if error as? CodexUsageError == .oauthCancelled || error is CancellationError {
                lastMessage = "已取消 Codex 登录"
            } else {
                lastMessage = "Codex 登录失败：\(error.localizedDescription)"
            }
            return false
        }
    }

    func authenticateCodexAccount(_ connection: CodexAccountConnection) async -> Bool {
        guard !isMutatingConnections else { return false }
        isMutatingConnections = true
        defer { isMutatingConnections = false }
        do {
            let tokenStore = CodexOAuthTokenStore(
                fileURL: try codexRuntimeManager.oauthTokenURL(for: connection)
            )
            let service = CodexUsageService(tokenStore: tokenStore)
            activeCodexOAuthService = service
            isCodexOAuthInProgress = true
            defer {
                activeCodexOAuthService = nil
                isCodexOAuthInProgress = false
            }
            let snapshot = try await service.connectAndFetch(forceLogin: true)
            let models = (try? await service.fetchAvailableModels()) ?? []
            guard let index = codexAccounts.firstIndex(where: { $0.id == connection.id }) else {
                return false
            }
            codexAccounts[index].label = normalizedLabel(
                snapshot.accountName ?? snapshot.accountEmail,
                fallback: connection.label
            )
            codexAccounts[index].authenticationState = .connected
            codexAccounts[index].isEnabled = true
            codexAccounts[index].usage = snapshot
            codexAccounts[index].availableModelIDs = models
            try saveRegistry()
            lastMessage = "已登录并更新 \(codexAccounts[index].label)"
            return true
        } catch {
            if error as? CodexUsageError == .oauthCancelled || error is CancellationError {
                lastMessage = "已取消 Codex 登录"
            } else {
                lastMessage = "Codex 登录失败：\(error.localizedDescription)"
            }
            return false
        }
    }

    func removeCodexAccount(_ connection: CodexAccountConnection) {
        guard !isMutatingConnections else { return }
        isMutatingConnections = true
        defer { isMutatingConnections = false }
        do {
            try codexRuntimeManager.removeRuntime(for: connection)
            codexAppServerSupervisor.remove(connectionID: connection.id)
            codexAccounts.removeAll { $0.id == connection.id }
            connectionOrder.removeAll { $0 == connectionKey(for: connection) }
            validateSelectedConnection()
            try saveRegistry()
            lastMessage = "已移除 \(connection.label) 的独立运行目录"
        } catch {
            lastMessage = "移除失败：\(error.localizedDescription)"
        }
    }

    /// Disconnect the selected connection without privileging any provider.
    /// Codex credentials are cleared while the connection record remains so it
    /// can be authenticated again; API-key connections are removed entirely.
    func disconnectSelectedConnection() {
        if let account = selectedCodexAccount {
            do {
                let tokenStore = CodexOAuthTokenStore(
                    fileURL: try codexRuntimeManager.oauthTokenURL(for: account)
                )
                tokenStore.clear()
                if let index = codexAccounts.firstIndex(where: { $0.id == account.id }) {
                    codexAccounts[index].authenticationState = .needsLogin
                    codexAccounts[index].usage = nil
                }
                try saveRegistry()
                lastMessage = "已退出 (account.label)"
            } catch {
                lastMessage = "退出失败：\(error.localizedDescription)"
            }
        } else if let connection = selectedDeepSeekConnection {
            removeDeepSeekConnection(connection)
        } else if let connection = selectedOpenCodeConnection {
            removeOpenCodeConnection(connection)
        }
    }

    func toggleConnectionProxyEnabled(id: ConnectionID) {
        if let idx = codexAccounts.firstIndex(where: { $0.id == id }) {
            codexAccounts[idx].isEnabled.toggle()
            try? saveRegistry()
            return
        }
        if let idx = geminiConnections.firstIndex(where: { $0.id == id }) {
            geminiConnections[idx].isEnabled.toggle()
            try? saveRegistry()
            return
        }
        if let idx = deepSeekConnections.firstIndex(where: { $0.id == id }) {
            deepSeekConnections[idx].isEnabled.toggle()
            try? saveRegistry()
            return
        }
        if let idx = openCodeConnections.firstIndex(where: { $0.id == id }) {
            openCodeConnections[idx].isEnabled.toggle()
            try? saveRegistry()
            return
        }
    }

    func setConnectionProxyEnabled(id: ConnectionID, enabled: Bool) {
        if let idx = geminiConnections.firstIndex(where: { $0.id == id }) {
            geminiConnections[idx].isEnabled = enabled
            try? saveRegistry()
            return
        }
        if let idx = codexAccounts.firstIndex(where: { $0.id == id }) {
            codexAccounts[idx].isEnabled = enabled
            try? saveRegistry()
            return
        }
        if let idx = deepSeekConnections.firstIndex(where: { $0.id == id }) {
            deepSeekConnections[idx].isEnabled = enabled
            try? saveRegistry()
            return
        }
        if let idx = openCodeConnections.firstIndex(where: { $0.id == id }) {
            openCodeConnections[idx].isEnabled = enabled
            try? saveRegistry()
            return
        }
    }

    enum ConnectionSyncResult: Sendable {
        case success(modelCount: Int, message: String)
        case warning(message: String)
        case failure(message: String)
    }

    /// Validates authorization and refreshes models/quota for an account.
    /// Used when enabling proxy in Gateway to guarantee fresh routing catalog.
    func syncConnectionModels(id: ConnectionID) async -> ConnectionSyncResult {
        if let conn = geminiConnections.first(where: { $0.id == id }) {
            let outcome = await refreshGeminiConnectionWithoutLock(conn, publishesMessage: false)
            if let updated = geminiConnections.first(where: { $0.id == id }) {
                if updated.authenticationState != .connected {
                    let errMsg = outcome.failures.first ?? "Google OAuth 凭证已失效，请重新登录"
                    return .failure(message: errMsg)
                }
                let count = updated.availableModelIDs.count
                if count > 0 {
                    return .success(modelCount: count, message: "已同步到 \(count) 款可用模型")
                } else {
                    return .warning(message: "OAuth 授权有效，但该 Google 账号未返回可用模型配额")
                }
            }
            return .failure(message: "未找到对应 Google 账号")
        }
        if let conn = deepSeekConnections.first(where: { $0.id == id }) {
            let outcome = await refreshDeepSeekConnectionWithoutLock(conn, publishesMessage: false)
            if let updated = deepSeekConnections.first(where: { $0.id == id }) {
                if !outcome.failures.isEmpty && updated.authenticationState != .connected {
                    return .failure(message: outcome.failures.first ?? "DeepSeek 连接验证失败")
                }
                let count = updated.availableModelIDs.count
                return .success(modelCount: count, message: "已同步到 \(count) 款可用模型")
            }
            return .failure(message: "未找到对应 DeepSeek 账号")
        }
        if let conn = openCodeConnections.first(where: { $0.id == id }) {
            let outcome = await refreshOpenCodeConnectionWithoutLock(conn, publishesMessage: false)
            if let updated = openCodeConnections.first(where: { $0.id == id }) {
                if !outcome.failures.isEmpty && updated.authenticationState != .connected {
                    return .failure(message: outcome.failures.first ?? "OpenCode 连接验证失败")
                }
                let count = updated.availableModelIDs.count
                return .success(modelCount: count, message: "已同步到 \(count) 款可用模型")
            }
            return .failure(message: "未找到对应 OpenCode 账号")
        }
        if let conn = codexAccounts.first(where: { $0.id == id }) {
            let outcome = await refreshCodexAccountWithoutLock(conn)
            if let updated = codexAccounts.first(where: { $0.id == id }) {
                if !outcome.failures.isEmpty && updated.authenticationState != .connected {
                    return .failure(message: outcome.failures.first ?? "Codex 连接验证失败")
                }
                let count = max(1, updated.availableModelIDs.count)
                return .success(modelCount: count, message: "Codex 会话已就绪")
            }
            return .failure(message: "未找到对应 Codex 账号")
        }
        return .failure(message: "未找到指定账号连接")
    }

    /// 拉取 DeepSeek 官方模型目录（`GET https://api.deepseek.com/models`）。
    ///
    /// 只在官方返回了非空列表时返回结果，其余情况一律返回 nil：调用方应保留
    /// 上一次的官方结果或提示失败，**绝不能**回退到本地写死的模型清单，否则界面
    /// 会显示官方并不存在的型号。
    private func fetchDeepSeekModelIDs(apiKey: String) async -> [String]? {
        guard let models = try? await deepSeekModelsService.validate(apiKey: apiKey) else { return nil }
        var seen = Set<String>()
        let cleaned = models
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return cleaned.isEmpty ? nil : cleaned
    }

    func addDeepSeekConnection(label: String, apiKey: String) async -> Bool {
        guard !isMutatingConnections else { return false }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedKey.count >= 12 else {
            lastMessage = "DeepSeek API Key 格式不正确"
            return false
        }

        isMutatingConnections = true
        defer { isMutatingConnections = false }
        let id = ConnectionID(rawValue: UUID())
        let handle = id.rawValue.uuidString.lowercased()
        do {
            try credentialStore.save(apiKey: trimmedKey, handle: handle)
            let balance = try await deepSeekBalanceService.fetch(apiKey: trimmedKey, connectionID: id)
            let models = await fetchDeepSeekModelIDs(apiKey: trimmedKey)
            let connection = DeepSeekAPIConnection(
                id: id,
                label: normalizedLabel(label, fallback: "DeepSeek Key \(deepSeekConnections.count + 1)"),
                credentialHandle: handle,
                keySuffix: String(trimmedKey.suffix(4)),
                authenticationState: .connected,
                balance: balance,
                availableModelIDs: models ?? [],
                lastValidatedAt: models == nil ? nil : Date(),
                createdAt: Date()
            )
            deepSeekConnections.append(connection)
            selectDeepSeekConnection(connection)
            try saveRegistry()
            lastMessage = models == nil
                ? "DeepSeek Key 已验证并保存，但未取到官方模型目录，可稍后刷新重试"
                : "DeepSeek Key 已验证并安全保存"
            return true
        } catch {
            try? credentialStore.delete(handle: handle)
            lastMessage = "DeepSeek Key 验证失败：\(error.localizedDescription)"
            return false
        }
    }

    /// 更新某个 DeepSeek 连接的名称 / API Key：复用原 handle 覆盖保存，
    /// 重新验证余额并同步 Keychain 与注册表。
    func updateDeepSeekConnection(
        connectionID: ConnectionID,
        label: String,
        apiKey: String
    ) async -> Bool {
        guard !isMutatingConnections else { return false }
        guard let connection = deepSeekConnections.first(where: { $0.id == connectionID }) else {
            lastMessage = "连接不存在，无法编辑"
            return false
        }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedKey.count >= 12 else {
            lastMessage = "DeepSeek API Key 格式不正确"
            return false
        }

        isMutatingConnections = true
        defer { isMutatingConnections = false }
        do {
            let oldKey = try credentialStore.read(handle: connection.credentialHandle)
            try credentialStore.save(apiKey: trimmedKey, handle: connection.credentialHandle)
            do {
                let balance = try await deepSeekBalanceService.fetch(apiKey: trimmedKey, connectionID: connection.id)
                let models = await fetchDeepSeekModelIDs(apiKey: trimmedKey)
                guard let index = deepSeekConnections.firstIndex(where: { $0.id == connectionID }) else {
                    return false
                }
                deepSeekConnections[index].label = normalizedLabel(label, fallback: connection.label)
                deepSeekConnections[index].keySuffix = String(trimmedKey.suffix(4))
                deepSeekConnections[index].authenticationState = .connected
                deepSeekConnections[index].balance = balance
                // 官方目录取不到时保留该连接上一次的官方结果，不用本地清单顶替。
                if let models {
                    deepSeekConnections[index].availableModelIDs = models
                    deepSeekConnections[index].lastValidatedAt = Date()
                }
                try saveRegistry()
                lastMessage = "DeepSeek Key 已更新并验证"
                return true
            } catch {
                // 验证失败（含网络错误）时回滚旧 Key，避免破坏原本可用的凭据。
                try? credentialStore.save(apiKey: oldKey, handle: connection.credentialHandle)
                throw error
            }
        } catch {
            lastMessage = "DeepSeek Key 更新失败：\(error.localizedDescription)"
            return false
        }
    }

    func refreshDeepSeekConnection(_ connection: DeepSeekAPIConnection) async {
        guard !isRefreshingConnections, !isMutatingConnections else { return }
        isRefreshingConnections = true
        defer { isRefreshingConnections = false }
        refreshingConnectionIDs.insert(connection.id)
        _ = await refreshDeepSeekConnectionWithoutLock(connection, publishesMessage: true)
        refreshingConnectionIDs.remove(connection.id)
    }

    private func refreshDeepSeekConnectionWithoutLock(
        _ connection: DeepSeekAPIConnection,
        publishesMessage: Bool
    ) async -> RefreshOutcome {
        do {
            let key = try credentialStore.read(handle: connection.credentialHandle)

            // 官方模型目录与余额是两个独立接口：先各自更新，余额失败也不影响目录刷新。
            if let models = await fetchDeepSeekModelIDs(apiKey: key),
               let index = deepSeekConnections.firstIndex(where: { $0.id == connection.id }) {
                deepSeekConnections[index].availableModelIDs = models
                deepSeekConnections[index].lastValidatedAt = Date()
                try? saveRegistry()
            }

            let balance = try await deepSeekBalanceService.fetch(apiKey: key, connectionID: connection.id)
            guard let index = deepSeekConnections.firstIndex(where: { $0.id == connection.id }) else {
                return RefreshOutcome(failures: ["\(connection.label)：连接已不存在"])
            }
            deepSeekConnections[index].balance = balance
            deepSeekConnections[index].authenticationState = .connected
            try saveRegistry()
            if publishesMessage { lastMessage = "\(connection.label) 余额已刷新" }
            return RefreshOutcome(successCount: 1)
        } catch DeepSeekCredentialError.interactionRequired {
            // Never let a scheduled refresh summon a system password dialog.
            // Keep the last successful balance visible until the user replaces
            // the credential under the current stable application signature.
            let message = "\(connection.label)：此 Key 需要重新保存，已保留上次余额"
            if publishesMessage { lastMessage = message }
            return RefreshOutcome(failures: [message])
        } catch {
            if let index = deepSeekConnections.firstIndex(where: { $0.id == connection.id }) {
                deepSeekConnections[index].authenticationState = .invalid
                try? saveRegistry()
            }
            let message = "\(connection.label)：\(error.localizedDescription)"
            if publishesMessage { lastMessage = "刷新失败：\(error.localizedDescription)" }
            return RefreshOutcome(failures: [message])
        }
    }

    func removeDeepSeekConnection(_ connection: DeepSeekAPIConnection) {
        guard !isMutatingConnections else { return }
        isMutatingConnections = true
        defer { isMutatingConnections = false }
        do {
            try credentialStore.delete(handle: connection.credentialHandle)
            deepSeekConnections.removeAll { $0.id == connection.id }
            connectionOrder.removeAll { $0 == connectionKey(for: connection) }
            validateSelectedConnection()
            try saveRegistry()
            lastMessage = "已从 Keychain 移除 \(connection.label)"
        } catch {
            lastMessage = "移除失败：\(error.localizedDescription)"
        }
    }

    // MARK: - OpenCode Go / Zen

    func addOpenCodeConnection(
        plan: OpenCodePlan,
        label: String,
        apiKey: String,
        workspaceURL: String? = nil
    ) async -> Bool {
        guard !isMutatingConnections else { return false }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedKey.count >= 12 else {
            lastMessage = "\(plan.displayName) API Key 格式不正确"
            return false
        }

        isMutatingConnections = true
        defer { isMutatingConnections = false }
        let id = ConnectionID(rawValue: UUID())
        let handle = id.rawValue.uuidString.lowercased()
        do {
            try openCodeCredentialStore.save(apiKey: trimmedKey, handle: handle)
            let modelIDs = try await openCodeModelsService.validate(apiKey: trimmedKey, plan: plan)
            let connection = OpenCodeAPIConnection(
                id: id,
                label: normalizedLabel(
                    label,
                    fallback: "\(plan.displayName) Key \(openCodeConnections.filter { $0.plan == plan }.count + 1)"
                ),
                plan: plan,
                credentialHandle: handle,
                keySuffix: String(trimmedKey.suffix(4)),
                authenticationState: .connected,
                availableModelCount: modelIDs.count,
                availableModelIDs: modelIDs,
                lastValidatedAt: Date(),
                workspaceURL: Self.normalizedWorkspaceURL(workspaceURL),
                createdAt: Date()
            )
            openCodeConnections.append(connection)
            selectOpenCodeConnection(connection)
            try saveRegistry()
            lastMessage = "\(plan.displayName) Key 已验证并安全保存"
            return true
        } catch {
            try? openCodeCredentialStore.delete(handle: handle)
            lastMessage = "\(plan.displayName) Key 验证失败：\(error.localizedDescription)"
            return false
        }
    }

    /// 更新某个 OpenCode 连接的名称 / API Key / 工作间地址：复用原 handle
    /// 覆盖保存，并重新验证模型目录；失败时回滚旧 Key。
    func updateOpenCodeConnection(
        connectionID: ConnectionID,
        label: String,
        apiKey: String,
        workspaceURL: String?
    ) async -> Bool {
        guard !isMutatingConnections else { return false }
        guard let connection = openCodeConnections.first(where: { $0.id == connectionID }) else {
            lastMessage = "连接不存在，无法编辑"
            return false
        }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedKey.count >= 12 else {
            lastMessage = "\(connection.plan.displayName) API Key 格式不正确"
            return false
        }

        isMutatingConnections = true
        defer { isMutatingConnections = false }
        do {
            let oldKey = try openCodeCredentialStore.read(handle: connection.credentialHandle)
            try openCodeCredentialStore.save(apiKey: trimmedKey, handle: connection.credentialHandle)
            do {
                let modelIDs = try await openCodeModelsService.validate(apiKey: trimmedKey, plan: connection.plan)
                guard let index = openCodeConnections.firstIndex(where: { $0.id == connectionID }) else {
                    return false
                }
                openCodeConnections[index].label = normalizedLabel(label, fallback: connection.label)
                openCodeConnections[index].keySuffix = String(trimmedKey.suffix(4))
                openCodeConnections[index].authenticationState = .connected
                openCodeConnections[index].availableModelCount = modelIDs.count
                openCodeConnections[index].availableModelIDs = modelIDs
                openCodeConnections[index].lastValidatedAt = Date()
                openCodeConnections[index].workspaceURL = Self.normalizedWorkspaceURL(workspaceURL)
                try saveRegistry()
                lastMessage = "\(connection.plan.displayName) Key 已更新并验证"
                return true
            } catch {
                // 验证失败（含网络错误）时回滚旧 Key，避免破坏原本可用的凭据。
                try? openCodeCredentialStore.save(apiKey: oldKey, handle: connection.credentialHandle)
                throw error
            }
        } catch {
            lastMessage = "\(connection.plan.displayName) Key 更新失败：\(error.localizedDescription)"
            return false
        }
    }

    /// 规范化：去掉前后空白并按需补 http 前缀，空串归一为 nil。
    private static func normalizedWorkspaceURL(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.lowercased().hasPrefix("http://"), !value.lowercased().hasPrefix("https://") {
            value = "https://\(value)"
        }
        return value
    }

    func refreshOpenCodeConnection(_ connection: OpenCodeAPIConnection) async {
        guard !isRefreshingConnections, !isMutatingConnections else { return }
        isRefreshingConnections = true
        defer { isRefreshingConnections = false }
        refreshingConnectionIDs.insert(connection.id)
        _ = await refreshOpenCodeConnectionWithoutLock(connection, publishesMessage: true)
        refreshingConnectionIDs.remove(connection.id)
    }

    private func refreshOpenCodeConnectionWithoutLock(
        _ connection: OpenCodeAPIConnection,
        publishesMessage: Bool
    ) async -> RefreshOutcome {
        do {
            let key = try openCodeCredentialStore.read(handle: connection.credentialHandle)
            let modelIDs = try await openCodeModelsService.validate(apiKey: key, plan: connection.plan)
            guard let index = openCodeConnections.firstIndex(where: { $0.id == connection.id }) else {
                return RefreshOutcome(failures: ["\(connection.label)：连接已不存在"])
            }
            openCodeConnections[index].availableModelCount = modelIDs.count
            openCodeConnections[index].availableModelIDs = modelIDs
            openCodeConnections[index].lastValidatedAt = Date()
            openCodeConnections[index].authenticationState = .connected
            try saveRegistry()
            if publishesMessage { lastMessage = "\(connection.label) 连接已验证" }
            return RefreshOutcome(successCount: 1)
        } catch OpenCodeValidationError.unauthorized {
            if let index = openCodeConnections.firstIndex(where: { $0.id == connection.id }) {
                openCodeConnections[index].authenticationState = .invalid
                try? saveRegistry()
            }
            let message = "\(connection.label)：OpenCode API Key 无效、已失效或不属于此计划"
            if publishesMessage { lastMessage = "刷新失败：OpenCode API Key 无效、已失效或不属于此计划" }
            return RefreshOutcome(failures: [message])
        } catch {
            // 网络、429 和服务端错误不应把一个此前有效的 Key 标记为失效。
            let message = "\(connection.label)：\(error.localizedDescription)"
            if publishesMessage { lastMessage = "刷新失败：\(error.localizedDescription)" }
            return RefreshOutcome(failures: [message])
        }
    }

    func removeOpenCodeConnection(_ connection: OpenCodeAPIConnection) {
        guard !isMutatingConnections else { return }
        isMutatingConnections = true
        defer { isMutatingConnections = false }
        do {
            try openCodeCredentialStore.delete(handle: connection.credentialHandle)
            openCodeConnections.removeAll { $0.id == connection.id }
            connectionOrder.removeAll { $0 == connectionKey(for: connection) }
            validateSelectedConnection()
            try saveRegistry()
            lastMessage = "已从本机移除 \(connection.label) 的 API Key"
        } catch {
            lastMessage = "移除失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Google Gemini

    func cancelCurrentGeminiOAuth() {
        guard isGeminiOAuthInProgress, let service = activeGeminiOAuthService else { return }
        lastMessage = "正在取消 Google 账号登录…"
        service.cancelOAuthAuthorization()
    }

    func addGeminiAccount() async -> Bool {
        guard !isMutatingConnections else { return false }
        isMutatingConnections = true
        defer { isMutatingConnections = false }
        let id = ConnectionID(rawValue: UUID())
        let handle = id.rawValue.uuidString.lowercased()
        do {
            activeGeminiOAuthService = geminiOAuthService
            isGeminiOAuthInProgress = true
            defer {
                activeGeminiOAuthService = nil
                isGeminiOAuthInProgress = false
            }
            let token = try await geminiOAuthService.startOAuth(forceLogin: true)
            try geminiOAuthTokenStore.save(token, handle: handle)
            let snapshot = await geminiOAuthService.fetchQuotaSnapshot(accessToken: token.accessToken)
            let label = token.email ?? token.displayName ?? "Google 账号 \(geminiConnections.count + 1)"
            let connection = GeminiAccountConnection(
                id: id,
                label: label,
                email: token.email,
                displayName: token.displayName,
                avatarURL: token.avatarURL,
                credentialHandle: handle,
                authenticationState: .connected,
                availableModelCount: snapshot.availableModelCount,
                availableModelIDs: snapshot.availableModels,
                projectId: snapshot.projectId,
                projectName: snapshot.projectName,
                tier: snapshot.tier,
                isBillingEnabled: snapshot.isBillingEnabled,
                dailyRequestsLimit: snapshot.dailyRequestsLimit,
                minuteRequestsLimit: snapshot.minuteRequestsLimit,
                minuteTokensLimit: snapshot.minuteTokensLimit,
                planName: snapshot.planName,
                geminiWeeklyRemaining: snapshot.geminiWeeklyRemaining,
                geminiWeeklyResetDesc: snapshot.geminiWeeklyResetDesc,
                geminiFiveHourRemaining: snapshot.geminiFiveHourRemaining,
                geminiFiveHourResetDesc: snapshot.geminiFiveHourResetDesc,
                claudeGptWeeklyRemaining: snapshot.claudeGptWeeklyRemaining,
                claudeGptFiveHourRemaining: snapshot.claudeGptFiveHourRemaining,
                accountEligibilityMessage: snapshot.accountEligibilityMessage,
                accountValidationURL: snapshot.accountValidationURL,
                lastValidatedAt: Date(),
                rateLimitState: snapshot.quotaFetchState,
                createdAt: Date()
            )
            geminiConnections.append(connection)
            selectGeminiConnection(connection)
            try saveRegistry()
            lastMessage = snapshot.quotaFetchState == "account_validation_required"
                ? "已连接 \(label)，请完成 Google 账号验证"
                : "已通过 Google 账号登录 \(label)"
            return true
        } catch {
            try? geminiOAuthTokenStore.delete(handle: handle)
            if case GeminiOAuthError.oauthCancelled = error {
                lastMessage = "已取消 Google 账号登录"
            } else {
                lastMessage = "Google 账号登录失败：\(error.localizedDescription)"
            }
            return false
        }
    }

    func authenticateGeminiAccount(_ connection: GeminiAccountConnection) async -> Bool {
        guard !isMutatingConnections else { return false }
        isMutatingConnections = true
        activeGeminiOAuthConnectionID = connection.id
        defer { isMutatingConnections = false }
        do {
            lastMessage = "正在打开 Google 重新授权页面…"
            activeGeminiOAuthService = geminiOAuthService
            isGeminiOAuthInProgress = true
            defer {
                activeGeminiOAuthService = nil
                isGeminiOAuthInProgress = false
                activeGeminiOAuthConnectionID = nil
            }
            let token = try await geminiOAuthService.startOAuth(forceLogin: true)
            try geminiOAuthTokenStore.save(token, handle: connection.credentialHandle)
            let snapshot = await geminiOAuthService.fetchQuotaSnapshot(accessToken: token.accessToken)
            guard let index = geminiConnections.firstIndex(where: { $0.id == connection.id }) else {
                return false
            }
            let label = token.email ?? token.displayName ?? connection.label
            geminiConnections[index].label = label
            geminiConnections[index].email = token.email
            geminiConnections[index].displayName = token.displayName
            geminiConnections[index].avatarURL = token.avatarURL
            geminiConnections[index].authenticationState = .connected
            geminiConnections[index].availableModelCount = snapshot.availableModelCount
            geminiConnections[index].availableModelIDs = snapshot.availableModels
            geminiConnections[index].projectId = snapshot.projectId
            geminiConnections[index].projectName = snapshot.projectName
            geminiConnections[index].tier = snapshot.tier
            geminiConnections[index].isBillingEnabled = snapshot.isBillingEnabled
            geminiConnections[index].planName = snapshot.planName
            geminiConnections[index].geminiWeeklyRemaining = snapshot.geminiWeeklyRemaining
            geminiConnections[index].geminiWeeklyResetDesc = snapshot.geminiWeeklyResetDesc
            geminiConnections[index].geminiFiveHourRemaining = snapshot.geminiFiveHourRemaining
            geminiConnections[index].geminiFiveHourResetDesc = snapshot.geminiFiveHourResetDesc
            geminiConnections[index].claudeGptWeeklyRemaining = snapshot.claudeGptWeeklyRemaining
            geminiConnections[index].claudeGptFiveHourRemaining = snapshot.claudeGptFiveHourRemaining
            geminiConnections[index].accountEligibilityMessage = snapshot.accountEligibilityMessage
            geminiConnections[index].accountValidationURL = snapshot.accountValidationURL
            geminiConnections[index].lastValidatedAt = Date()
            geminiConnections[index].rateLimitState = snapshot.quotaFetchState
            try saveRegistry()
            lastMessage = snapshot.quotaFetchState == "account_validation_required"
                ? "已重新连接 \(label)，请完成 Google 账号验证"
                : "已重新连接 Google 账号 \(label)"
            return true
        } catch {
            if case GeminiOAuthError.oauthCancelled = error {
                lastMessage = "已取消 Google 账号重新登录"
            } else {
                lastMessage = "Google 账号重新连接失败：\(error.localizedDescription)"
            }
            return false
        }
    }

    func refreshGeminiConnection(_ connection: GeminiAccountConnection) async {
        guard !isRefreshingConnections, !isMutatingConnections else { return }
        isRefreshingConnections = true
        defer { isRefreshingConnections = false }
        refreshingConnectionIDs.insert(connection.id)
        _ = await refreshGeminiConnectionWithoutLock(connection, publishesMessage: true)
        refreshingConnectionIDs.remove(connection.id)
    }

    private func refreshGeminiConnectionWithoutLock(
        _ connection: GeminiAccountConnection,
        publishesMessage: Bool
    ) async -> RefreshOutcome {
        guard var token = geminiOAuthTokenStore.load(handle: connection.credentialHandle) else {
            if let index = geminiConnections.firstIndex(where: { $0.id == connection.id }) {
                geminiConnections[index].authenticationState = .invalid
                try? saveRegistry()
            }
            let message = "\(connection.label)：本地 Google OAuth Token 缺失，请重新登录"
            if publishesMessage { lastMessage = message }
            return RefreshOutcome(failures: [message])
        }

        guard token.usesCurrentAuthorization else {
            if let index = geminiConnections.firstIndex(where: { $0.id == connection.id }) {
                geminiConnections[index].authenticationState = .needsLogin
                geminiConnections[index].rateLimitState = "unauthorized"
                geminiConnections[index].geminiWeeklyRemaining = nil
                geminiConnections[index].geminiFiveHourRemaining = nil
                geminiConnections[index].claudeGptWeeklyRemaining = nil
                geminiConnections[index].claudeGptFiveHourRemaining = nil
                try? saveRegistry()
            }
            let message = "\(connection.label)：OAuth 客户端已升级，请重新登录 Google 账号"
            if publishesMessage { lastMessage = message }
            return RefreshOutcome(failures: [message])
        }

        if token.isExpired, let _ = token.refreshToken {
            do {
                token = try await geminiOAuthService.refreshToken(token)
                try geminiOAuthTokenStore.save(token, handle: connection.credentialHandle)
            } catch {
                // An expired access token is expected: Google normally issues
                // one-hour access tokens and Tomo owns a refresh token
                // for the long-lived session.  Do not persist a transient
                // network/proxy/configuration error as "unauthorized" — that
                // made every account look logged out after a short outage and
                // hid otherwise usable Gateway routes.  Only an explicit
                // OAuth credential rejection requires user interaction.
                let requiresReauthentication = Self.geminiRefreshRequiresReauthentication(error)
                if let index = geminiConnections.firstIndex(where: { $0.id == connection.id }) {
                    geminiConnections[index].authenticationState = requiresReauthentication ? .invalid : .connected
                    geminiConnections[index].rateLimitState = requiresReauthentication
                        ? "unauthorized"
                        : "refresh_pending"
                    try? saveRegistry()
                }
                let message: String
                if requiresReauthentication {
                    message = "\(connection.label)：Google 已拒绝该 OAuth 凭证，请重新登录"
                } else {
                    message = "\(connection.label)：OAuth 自动续期暂时不可达，已保留连接；Gateway 会在下次请求时继续自动续期"
                }
                if publishesMessage { lastMessage = message }
                return RefreshOutcome(failures: [message])
            }
        }

        let snapshot = await geminiOAuthService.fetchQuotaSnapshot(accessToken: token.accessToken)
        guard let index = geminiConnections.firstIndex(where: { $0.id == connection.id }) else {
            return RefreshOutcome(failures: ["\(connection.label)：连接已不存在"])
        }
        if let name = snapshot.userName, !name.isEmpty {
            geminiConnections[index].displayName = name
        }
        if let email = snapshot.userEmail, !email.isEmpty {
            geminiConnections[index].email = email
        }
        // This snapshot is a successful official Cloud Code response.  Its
        // catalog (including an explicitly empty one) is authoritative; do
        // not keep stale models after upstream has removed access.
        geminiConnections[index].availableModelCount = snapshot.availableModelCount
        geminiConnections[index].availableModelIDs = snapshot.availableModels
        if let projectID = snapshot.projectId, !projectID.isEmpty {
            geminiConnections[index].projectId = projectID
        }
        if let projectName = snapshot.projectName, !projectName.isEmpty {
            geminiConnections[index].projectName = projectName
        }
        geminiConnections[index].tier = snapshot.tier
        geminiConnections[index].isBillingEnabled = snapshot.isBillingEnabled
        geminiConnections[index].dailyRequestsLimit = snapshot.dailyRequestsLimit
        geminiConnections[index].minuteRequestsLimit = snapshot.minuteRequestsLimit
        geminiConnections[index].minuteTokensLimit = snapshot.minuteTokensLimit
        geminiConnections[index].planName = snapshot.planName
        geminiConnections[index].geminiWeeklyRemaining = snapshot.geminiWeeklyRemaining
        geminiConnections[index].geminiWeeklyResetDesc = snapshot.geminiWeeklyResetDesc
        geminiConnections[index].geminiFiveHourRemaining = snapshot.geminiFiveHourRemaining
        geminiConnections[index].geminiFiveHourResetDesc = snapshot.geminiFiveHourResetDesc
        geminiConnections[index].claudeGptWeeklyRemaining = snapshot.claudeGptWeeklyRemaining
        geminiConnections[index].claudeGptFiveHourRemaining = snapshot.claudeGptFiveHourRemaining
        geminiConnections[index].accountEligibilityMessage = snapshot.accountEligibilityMessage
        geminiConnections[index].accountValidationURL = snapshot.accountValidationURL
        geminiConnections[index].lastValidatedAt = Date()
        geminiConnections[index].authenticationState = snapshot.quotaFetchState == "unauthorized" ? .needsLogin : .connected
        geminiConnections[index].rateLimitState = snapshot.quotaFetchState
        try? saveRegistry()
        if snapshot.quotaFetchState == "unauthorized" {
            let message = "\(connection.label)：需要重新登录以启用 Antigravity 直连额度"
            if publishesMessage { lastMessage = message }
            return RefreshOutcome(failures: [message])
        }
        if publishesMessage {
            if snapshot.quotaFetchState == "normal" {
                lastMessage = "\(connection.label) 额度与模型信息已更新"
            } else if snapshot.quotaFetchState == "account_validation_required" {
                lastMessage = "\(connection.label) 需要先完成 Google 账号验证"
            } else {
                lastMessage = "\(connection.label) 已连接，但远端暂未返回额度"
            }
        }
        return RefreshOutcome(successCount: 1)
    }

    /// Google only requires a fresh browser login when it explicitly rejects
    /// the refresh grant.  Transport errors (including a temporarily stale
    /// system proxy) must stay recoverable and never change the saved account
    /// into the visually equivalent "未授权" state.
    private static func geminiRefreshRequiresReauthentication(_ error: Error) -> Bool {
        guard let oauthError = error as? GeminiOAuthError else { return false }
        switch oauthError {
        case .unauthorized:
            return true
        case .tokenRefreshFailed(let response):
            let normalized = response.lowercased()
            return normalized.contains("invalid_grant")
                || normalized.contains("token has been expired or revoked")
                || normalized.contains("token has been revoked")
        default:
            return false
        }
    }

    func removeGeminiConnection(_ connection: GeminiAccountConnection) {
        guard !isMutatingConnections else { return }
        isMutatingConnections = true
        defer { isMutatingConnections = false }
        do {
            try geminiOAuthTokenStore.delete(handle: connection.credentialHandle)
            geminiConnections.removeAll { $0.id == connection.id }
            connectionOrder.removeAll { $0 == connectionKey(for: connection) }
            validateSelectedConnection()
            try saveRegistry()
            lastMessage = "已从本机移除 \(connection.label) 的 Google 账号连接"
        } catch {
            lastMessage = "移除失败：\(error.localizedDescription)"
        }
    }

    // MARK: - API Key Reveal

    /// 读取某个连接保存的 API Key 明文。调用方必须在调用前完成系统认证；
    /// 此方法本身不弹认证框，只负责从本机存储解密读取。
    func revealedAPIKey(for connectionID: ConnectionID) throws -> String {
        if let connection = deepSeekConnections.first(where: { $0.id == connectionID }) {
            return try credentialStore.read(handle: connection.credentialHandle)
        }
        if let connection = openCodeConnections.first(where: { $0.id == connectionID }) {
            return try openCodeCredentialStore.read(handle: connection.credentialHandle)
        }
        throw APIKeyRevealError.connectionNotFound
    }

    // MARK: - Connection Ordering and Selection

    func connectionKey(for account: CodexAccountConnection) -> String {
        "codex.\(account.id.rawValue.uuidString.lowercased())"
    }

    func connectionKey(for connection: DeepSeekAPIConnection) -> String {
        "deepseek.\(connection.id.rawValue.uuidString.lowercased())"
    }

    func connectionKey(for connection: OpenCodeAPIConnection) -> String {
        let prefix = connection.plan == .go ? "opencode-go" : "opencode-zen"
        return "\(prefix).\(connection.id.rawValue.uuidString.lowercased())"
    }

    func connectionKey(for connection: GeminiAPIConnection) -> String {
        "gemini.\(connection.id.rawValue.uuidString.lowercased())"
    }

    /// 已保存的顺序优先；新连接追加到末尾，已删除或重复的 key 会被忽略。
    var orderedConnectionKeys: [String] {
        var seen: Set<String> = []
        var result = connectionOrder.filter { key in
            connectionExists(key) && seen.insert(key).inserted
        }

        func appendIfNeeded(_ key: String) {
            guard connectionExists(key), seen.insert(key).inserted else { return }
            result.append(key)
        }

        codexAccounts.forEach { appendIfNeeded(connectionKey(for: $0)) }
        deepSeekConnections.forEach { appendIfNeeded(connectionKey(for: $0)) }
        openCodeConnections.forEach { appendIfNeeded(connectionKey(for: $0)) }
        geminiConnections.forEach { appendIfNeeded(connectionKey(for: $0)) }
        return result
    }

    func moveConnection(fromOffsets source: IndexSet, toOffset destination: Int) {
        var keys = orderedConnectionKeys
        keys.move(fromOffsets: source, toOffset: destination)
        connectionOrder = keys
        persistConnectionOrder()
    }

    /// 只重排当前界面可见的连接，同时保持隐藏连接在完整顺序中的相对位置。
    func moveConnection(key: String, to targetIndex: Int, among visibleKeys: [String]) {
        var reorderedVisibleKeys = visibleKeys.filter(connectionExists)
        guard let sourceIndex = reorderedVisibleKeys.firstIndex(of: key),
              reorderedVisibleKeys.indices.contains(targetIndex),
              sourceIndex != targetIndex
        else { return }

        let movedKey = reorderedVisibleKeys.remove(at: sourceIndex)
        reorderedVisibleKeys.insert(movedKey, at: targetIndex)
        let visibleKeySet = Set(reorderedVisibleKeys)
        var iterator = reorderedVisibleKeys.makeIterator()
        connectionOrder = orderedConnectionKeys.map { existingKey in
            visibleKeySet.contains(existingKey) ? (iterator.next() ?? existingKey) : existingKey
        }
        persistConnectionOrder()
    }

    private func persistConnectionOrder() {
        do {
            try saveRegistry()
        } catch {
            NSLog("Tomo persist connection order failed: %@", error.localizedDescription)
        }
    }

    func selectConnection(key: String) {
        guard connectionExists(key) else { return }
        selectedConnectionKey = key
    }

    // MARK: - 单账号加载状态

    func isRefreshingConnection(_ connection: DeepSeekAPIConnection) -> Bool {
        refreshingConnectionIDs.contains(connection.id)
    }

    func isRefreshingConnection(_ connection: CodexAccountConnection) -> Bool {
        refreshingConnectionIDs.contains(connection.id)
    }

    func isRefreshingConnection(_ connection: OpenCodeAPIConnection) -> Bool {
        refreshingConnectionIDs.contains(connection.id)
    }

    func isRefreshingConnection(_ connection: GeminiAPIConnection) -> Bool {
        refreshingConnectionIDs.contains(connection.id)
    }

    private func connectionExists(_ key: String) -> Bool {
        if key.hasPrefix("codex."),
           let uuid = UUID(uuidString: String(key.dropFirst("codex.".count))) {
            return codexAccounts.contains { $0.id.rawValue == uuid }
        }
        if key.hasPrefix("deepseek."),
           let uuid = UUID(uuidString: String(key.dropFirst("deepseek.".count))) {
            return deepSeekConnections.contains { $0.id.rawValue == uuid }
        }
        if key.hasPrefix("gemini."),
           let uuid = UUID(uuidString: String(key.dropFirst("gemini.".count))) {
            return geminiConnections.contains { $0.id.rawValue == uuid }
        }
        for prefix in ["opencode-go.", "opencode-zen."] {
            if key.hasPrefix(prefix),
               let uuid = UUID(uuidString: String(key.dropFirst(prefix.count))) {
                return openCodeConnections.contains { $0.id.rawValue == uuid }
            }
        }
        return false
    }

    // MARK: - Helpers

    private func displayName(for agentID: AgentID) -> String {
        BuiltInAgentCatalog.prioritized.first(where: { $0.id == agentID })?.displayName ?? "Agent"
    }

    private func saveRegistry() throws {
        try registryStorage.save(ConnectionRegistrySnapshot(
            codexAccounts: codexAccounts,
            deepSeekConnections: deepSeekConnections,
            openCodeConnections: openCodeConnections,
            geminiConnections: geminiConnections,
            connectionOrder: orderedConnectionKeys
        ))
    }

    /// Gemini proxy traffic is OAuth-only. Remove pre-OAuth credential files
    /// and rewrite the registry so obsolete fields disappear.
    private func purgeLegacyGeminiCredentials() {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tomo/gemini_credentials", isDirectory: true)
        for connection in geminiConnections {
            for extensionName in ["key", "json"] {
                let legacyCredential = root.appendingPathComponent("\(connection.credentialHandle).\(extensionName)")
                try? FileManager.default.removeItem(at: legacyCredential)
            }
        }
        try? saveRegistry()
    }

    private func normalizedLabel(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : String(trimmed.prefix(60))
    }

    /// 把 CLI 回退路径返回的精简快照转成与主流程一致的全量快照。
    private func codexUsage(from usage: CodexAccountUsageSnapshot) -> CodexUsageSnapshot {
        CodexUsageSnapshot(
            accountName: nil,
            accountEmail: usage.email ?? "",
            workspaceName: "",
            planName: usage.planType ?? "",
            shortWindow: usage.primary.map { usageWindow(from: $0, fallbackLabel: "5 小时") },
            weekly: usage.secondary.map { usageWindow(from: $0, fallbackLabel: "周额度") }
                ?? UsageWindow(label: "周额度", remaining: 0, total: 0, resetsAt: "未知"),
            credits: CreditBalance(balance: 0, expiresAt: "未知"),
            resetCoupons: usage.resetCoupons,
            fetchedAt: usage.fetchedAt,
            refreshState: "成功",
            sourceURL: "",
            subscriptionActiveUntilISO: usage.subscriptionActiveUntilISO,
            subscriptionWillRenew: usage.subscriptionWillRenew
        )
    }

    private func usageWindow(from window: CodexAccountRateLimitWindow, fallbackLabel: String) -> UsageWindow {
        let label: String
        if let minutes = window.windowDurationMinutes {
            if minutes >= 24 * 60 { label = "周额度" }
            else if minutes >= 60 { label = "\(minutes / 60) 小时" }
            else { label = "\(minutes) 分钟" }
        } else {
            label = fallbackLabel
        }
        return UsageWindow(
            label: label,
            remaining: window.remainingPercent,
            total: 100,
            resetsAt: window.resetsAt.map { UsageDateFormat.display($0) } ?? "未知"
        )
    }

    private func validateSelectedConnection() {
        let valid = codexAccounts.contains(where: isSelected)
            || deepSeekConnections.contains(where: isSelected)
            || openCodeConnections.contains(where: isSelected)
            || geminiConnections.contains(where: isSelected)
        if !valid { selectedConnectionKey = orderedConnectionKeys.first ?? "" }
    }

    /// Migrate the legacy single-account token into the same per-connection
    /// directory used by every other Codex account. The old global token is
    /// never treated as a special runtime after this point.
    private func migrateLegacyCodexAccountIfNeeded() {
        guard let token = CodexOAuthTokenStore().load() else { return }
        do {
            let fallback = normalizedLabel(
                token.displayName ?? token.email ?? "Codex 账号",
                fallback: "Codex 账号 1"
            )
            let connection = try codexRuntimeManager.createAccount(label: fallback)
            let scopedStore = CodexOAuthTokenStore(
                fileURL: try codexRuntimeManager.oauthTokenURL(for: connection)
            )
            scopedStore.save(token)
            var migrated = connection
            migrated.authenticationState = .connected
            migrated.usage = UsageSnapshotCache().load()
            codexAccounts.append(migrated)
            CodexOAuthTokenStore().clear()
            try? saveRegistry()
            selectedConnectionKey = connectionKey(for: migrated)
        } catch {
            NSLog("Tomo legacy Codex account migration failed: %@", error.localizedDescription)
        }
    }
}

private struct CodexAccountRefreshResult: Sendable {
    let id: ConnectionID
    let state: ConnectionAuthenticationState
    let usage: CodexUsageSnapshot?
    var availableModels: [String] = []
    var didFetchAvailableModels = false
}
