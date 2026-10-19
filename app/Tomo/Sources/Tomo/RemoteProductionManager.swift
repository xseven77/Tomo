import Foundation
import CryptoKit
import Observation

protocol RemoteProductionHosting: Sendable {
    var states: AsyncStream<RemoteHTTPSListener.State> { get }
    func stop() async
}
extension RemoteProductionService: RemoteProductionHosting {}

@MainActor @Observable final class RemoteProductionManager {
    static let shared = RemoteProductionManager(cloud: .shared)
    enum Status: Equatable { case stopped, loadingCertificates, starting, running, stopping, failed }
    enum AuthorizationMode: String, CaseIterable { case local, cloud }
    typealias Factory = @Sendable (DesktopCloudSession, URL, URL, RemoteTLSIdentity?, URL, [any RemoteReadAdapter]) async throws -> any RemoteProductionHosting
    typealias Sources = @Sendable (URL) async throws -> [any RemoteReadAdapter]
    typealias LocalFactory = @Sendable (URL, RemoteTLSIdentity?, RemoteServerIdentity, URL, RemoteOwnedChatGPTService.PhoneDirectory?, [any RemoteReadAdapter]) async throws -> any RemoteProductionHosting
    typealias PhoneConversation = @Sendable (RemoteProductionService) async throws -> Void
    private(set) var authorizationMode: AuthorizationMode = .cloud
    private(set) var status: Status = .stopped
    private(set) var choices: [RemoteTLSChoice] = []
    private(set) var message: String?
    private(set) var endpoint: URL?
    private(set) var phonePairingEnabled = false
    private var ownsPhoneService = false
    private(set) var ownerState: RemoteProductionService.OwnerState?
    private(set) var ownerBusy = false
    private(set) var ownerMessage: String?
    private let cloud: DesktopCloudManager
    private let catalog: any RemoteTLSIdentityCatalog
    private let directory: URL
    private let factory: Factory
    private let sources: Sources
    private let signingIdentity: RemoteServerIdentity
    private let localFactory: LocalFactory
    private let preparePhoneConversation: PhoneConversation
    private let phoneClock: @Sendable () -> Date
    @ObservationIgnored private var phoneMaintenance: Task<Void, Never>?
    @ObservationIgnored private var phoneRetryAfter: Date?
    @ObservationIgnored private var service: (any RemoteProductionHosting)?
    @ObservationIgnored private var startup: Task<any RemoteProductionHosting, Error>?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var registeredMobileSource: MobileTaskSessionResolver.Source?
    var mobileTaskSource: MobileTaskSessionResolver.Source? {
        guard status == .running, service != nil else { return nil }
        return registeredMobileSource
    }
    private var generation: UInt64 = 0
    init(cloud: DesktopCloudManager, catalog: any RemoteTLSIdentityCatalog = KeychainRemoteTLSIdentityCatalog(),
         directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tomo/RemoteServers"),
         sources: @escaping Sources = RemoteProductionManager.chatGPTSources,
         signingIdentity: RemoteServerIdentity = RemoteServerIdentity(),
         preparePhoneConversation: @escaping PhoneConversation = {service in
             _ = try await service.ownedChatGPT.preparePhoneConversation(executable: PhoneConversationExecutable.locate())
         },
         phoneClock: @escaping @Sendable () -> Date = Date.init,
         localFactory: @escaping LocalFactory = { endpoint, tls, identity, directory, conversationDirectory, adapters in
             try await RemoteProductionService.startLocal(endpoint: endpoint, tlsIdentity: tls,
                 signingIdentity: identity, directory: directory, adapters: adapters,
                 name: Host.current().localizedName ?? "我的 Mac", ownedConversationDirectory: conversationDirectory)
         },
         factory: @escaping Factory = { cloud, issuer, endpoint, tls, directory, adapters in
             try await RemoteProductionService.start(cloudSession: cloud, issuer: issuer, endpoint: endpoint,
                tlsIdentity: tls, signingIdentity: RemoteServerIdentity(), directory: directory, adapters: adapters)
         }) {
        self.cloud = cloud; self.catalog = catalog; self.directory = directory; self.factory = factory; self.sources = sources
        self.signingIdentity = signingIdentity; self.localFactory = localFactory
        self.preparePhoneConversation = preparePhoneConversation
        self.phoneClock = phoneClock
        cloud.installRemoteStopHandler { [weak self] in
            guard let self, self.authorizationMode == .cloud else { return }; await self.stop()
        }
    }
    deinit { startup?.cancel(); observation?.cancel(); phoneMaintenance?.cancel(); if let service { Task { await service.stop() } } }
    var isBusy: Bool { [.loadingCertificates, .starting, .stopping].contains(status) }
    func loadCertificates() async {
        guard !isBusy, service == nil else { return }
        generation &+= 1; let lease = generation; status = .loadingCertificates; message = nil
        do {
            let loaded = try await catalog.choices()
            guard lease == generation else { return }; choices = loaded; status = .stopped
            if loaded.isEmpty { message = "Keychain 中没有可用的 TLS 身份，请先配置对应域名的服务器证书与私钥。" }
        } catch { if lease == generation { status = .failed; message = "无法读取 TLS 身份，请解锁 Keychain 后重试。" } }
    }
    func start(endpoint text: String, certificateId: String, storageRoot: URL, mode: AuthorizationMode = .cloud,
               phoneNamespace: String? = nil) async {
        guard !isBusy, service == nil else { return }
        generation &+= 1; let lease = generation; status = .starting; message = nil
        phoneMaintenance?.cancel(); phoneMaintenance = nil; phoneRetryAfter = nil
        authorizationMode = mode
        do {
            guard phoneNamespace == nil || (mode == .local && phoneNamespace?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil) else {throw RemoteAccessError.invalidConfiguration}
            guard let endpoint = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  RemoteEndpoint.valid(endpoint), storageRoot.isFileURL,
                  endpoint.scheme == "http" || choices.contains(where: { $0.id == certificateId }) else { throw RemoteAccessError.invalidConfiguration }
            let tls = endpoint.scheme == "https" ? try await catalog.identity(id: certificateId) : nil
            guard generation == lease else { return }
            try Task.checkCancellation()
            let adapters = try await sources(storageRoot)
            guard generation == lease else { return }
            try Task.checkCancellation()
            let task: Task<any RemoteProductionHosting, Error>
            let serverId: String
            if mode == .cloud {
                let context = try cloud.remoteContext(), factory = factory
                serverId = context.server.id.uuidString.lowercased()
                let directory = directory.appendingPathComponent(serverId)
                task = Task { try await factory(context.client, context.issuer, endpoint, tls, directory, adapters) }
            } else {
                let identity = signingIdentity, local = try await identity.localIdentity()
                guard generation == lease else { return }; try Task.checkCancellation()
                serverId = local.serverId.uuidString.lowercased()
                let base = phoneNamespace.map {directory.appendingPathComponent("phone").appendingPathComponent($0)} ?? directory.appendingPathComponent("local")
                let conversationDirectory = phoneNamespace.map { namespace -> RemoteOwnedChatGPTService.PhoneDirectory in
                    let root = self.directory
                    return {try PhoneConversationLocation.directory(root: root, serverId: serverId, namespace: namespace)}
                }
                let directory = base.appendingPathComponent(serverId), factory = localFactory
                task = Task { try await factory(endpoint, tls, identity, directory, conversationDirectory, adapters) }
            }
            startup = task
            let active = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard generation == lease else { await active.stop(); return }
            if Task.isCancelled { await active.stop(); throw CancellationError() }
            if phoneNamespace != nil, let local = active as? RemoteProductionService {
                do {try await preparePhoneConversation(local)}
                catch {
                    if Task.isCancelled || generation != lease {await active.stop(); return}
                    phoneRetryAfter = phoneClock().addingTimeInterval(30)
                    message = phoneConversationMessage(error)
                }
                guard generation == lease, !Task.isCancelled else {await active.stop(); return}
            }
            registeredMobileSource = .init(id: UUID().uuidString,
                serverId: serverId,
                directories: adapters.compactMap { ($0 as? ChatGPTReadAdapter)?.directory })
            startup = nil; service = active; self.endpoint = endpoint; status = .running
            observation = Task { [weak self] in
                for await state in active.states {
                    guard let self, self.generation == lease else { return }
                    switch state {
                    case .starting: self.status = .starting
                    case .running: self.status = .running
                    case .failed:
                        self.service = nil; self.endpoint = nil; self.ownerState = nil; self.status = .failed; self.message = "安全监听失败，服务已停止。请检查端口和证书配置。"
                        await active.stop(); return
                    case .stopped:
                        self.service = nil; self.status = .stopped; self.endpoint = nil; self.ownerState = nil; await active.stop(); return
                    }
                }
                guard let self, self.generation == lease, !Task.isCancelled else { return }
                self.service = nil; self.endpoint = nil; self.ownerState = nil; self.status = .failed
                self.message = "安全监听状态已中断，服务已停止。"
                await active.stop()
            }
        } catch {
            guard generation == lease else { return }
            startup = nil; endpoint = nil
            if error is CancellationError { status = .stopped; message = nil }
            else {
                status = .failed
                message = mode == .cloud ? "会话服务启动失败。请检查云登录/登记、证书域名与有效期、端口和会话目录。"
                    : "本地会话服务启动失败。请检查本机 Keychain、证书、端口和会话目录。"
            }
        }
    }
    func stop() async {
        phonePairingEnabled = false; ownsPhoneService = false
        phoneMaintenance?.cancel(); phoneMaintenance = nil; phoneRetryAfter = nil
        generation &+= 1; let lease = generation
        registeredMobileSource = nil
        ownerState = nil; ownerBusy = false; ownerMessage = nil
        startup?.cancel(); startup = nil; observation?.cancel(); observation = nil
        let previous = service; service = nil; status = .stopping; endpoint = nil
        await previous?.stop()
        if lease == generation { status = .stopped }
    }
    func invalidatePhonePairing() {
        phonePairingEnabled = false
        phoneMaintenance?.cancel(); phoneMaintenance = nil
    }
    func startPhoneSessions(host: String, preferredPort: UInt16, pairingToken: String, storageRoot: URL) async {
        guard service == nil, !isBusy else {message = "请先停止高级会话服务，再开启手机会话。"; return}
        guard !pairingToken.isEmpty, pairingToken.utf8.count <= 4096 else {message = "配对信息不可用，请重新生成配对码。"; return}
        do {
            let endpoint = try PhoneSessionEndpoint.make(host: host, preferredPort: preferredPort)
            let namespace = SHA256.hash(data: Data(pairingToken.utf8)).map {String(format: "%02x", $0)}.joined()
            ownsPhoneService = true
            await start(endpoint: endpoint.absoluteString, certificateId: "", storageRoot: storageRoot, mode: .local, phoneNamespace: namespace)
            guard status == .running, !Task.isCancelled else {await stopPhoneSessions(); return}
            phonePairingEnabled = true
        } catch {message = "无法启动手机会话，请检查桌面连接后重试。"; ownsPhoneService = false}
    }
    func stopPhoneSessions() async {
        phonePairingEnabled = false
        if ownsPhoneService {await stop()}
    }
    func pairPhoneDevice(serverId: String, requestId: UUID) async throws {
        guard phonePairingEnabled, authorizationMode == .local, status == .running,
              let current = service as? RemoteProductionService, current.server.id.uuidString.lowercased() == serverId.lowercased() else {throw RemoteAccessError.forbidden}
        let lease = generation
        try await current.pairPhoneDevice(requestId: requestId)
        guard lease == generation, phonePairingEnabled, status == .running else {throw RemoteAccessError.forbidden}
    }
    private func phoneConversationMessage(_ error: Error) -> String {
        switch error {
        case ChatGPTRuntimeError.authenticationRequired:
            return "历史会话可查看。请先在桌面登录当前 ChatGPT/Codex 账号，手机会话将自动重试。"
        case ChatGPTRuntimeError.invalidAccountState:
            return "历史会话可查看，暂时无法确认模型账号状态。请更新 ChatGPT/Codex 后重试手机会话。"
        case PhoneConversationError.accountUnavailable:
            return "历史会话可查看，未找到可用的 ChatGPT 账号目录。请检查桌面账号设置后重试手机会话。"
        case PhoneConversationError.invalidManifest, PhoneConversationError.historyMissing:
            return "历史会话可查看，手机会话的本地恢复记录不可用。请在桌面检查原会话数据后重试。"
        case PhoneConversationError.workspaceChanged, PhoneConversationError.rolloutOutsideAccount:
            return "历史会话可查看，手机会话的工作目录或账号目录已变更。请在桌面确认后重试。"
        default:
            return "历史会话可查看，可写会话暂未就绪。请确认已安装并登录 ChatGPT/Codex，手机会话将自动重试。"
        }
    }
    private func maintainPhoneConversation(_ current: RemoteProductionService, lease: UInt64) async {
        guard ownsPhoneService, phonePairingEnabled, authorizationMode == .local else {return}
        if let phoneMaintenance {await phoneMaintenance.value; return}
        if let phoneRetryAfter, phoneRetryAfter > phoneClock() {return}
        let prepare = preparePhoneConversation
        let task = Task { [weak self] in
            do {
                try await prepare(current)
                guard let self, self.generation == lease, self.status == .running, self.phonePairingEnabled, !Task.isCancelled else {return}
                self.phoneRetryAfter = nil; self.message = nil
            } catch {
                guard let self, self.generation == lease, self.status == .running, self.phonePairingEnabled, !Task.isCancelled else {return}
                self.phoneRetryAfter = self.phoneClock().addingTimeInterval(30)
                self.message = self.phoneConversationMessage(error)
            }
        }
        phoneMaintenance = task
        await task.value
        if generation == lease {phoneMaintenance = nil}
    }
    /// Maintain only the switch-owned default conversation before returning
    /// its current scope. No grant is approved and no message is replayed here.
    func mobileHostConfiguration(includeInteraction: Bool) async throws -> String {
        guard status == .running, let current = service as? RemoteProductionService, let endpoint else {
            throw RemoteAccessError.unavailable
        }
        let lease = generation
        await maintainPhoneConversation(current, lease: lease)
        guard generation == lease, status == .running else {throw RemoteAccessError.unavailable}
        let runtimes = try await current.registry.ownerRuntimes()
        let available = runtimes.filter { $0.actions.contains(.listSessions) || $0.actions.contains(.readHistory) }
        var scopes = RemoteProductionService.ownerScopes(available)
        if !includeInteraction { scopes.formIntersection(["discovery", "session.read"]) }
        let value = try RemoteHostConfiguration.encode(serverId: current.server.id, name: current.server.name,
            endpoint: endpoint, scopes: scopes.sorted(),
            runtimes: available.map { .init(agentId: $0.agentId, runtimeId: $0.runtimeId) }, localIdentity: current.localIdentity)
        guard generation == lease, status == .running else { throw RemoteAccessError.unavailable }
        return value
    }
    func refreshOwnerState() async { await ownerOperation { _ in } }
    func attachOwnedChatGPT(sourceRuntimeId: String, sessionId: String, executable: URL, allowSteer: Bool, lease: UUID) async {
        await ownerOperation(expectedLease: lease) { try await $0.ownerAttachChatGPT(sourceRuntimeId: sourceRuntimeId, sessionId: sessionId, executable: executable, allowSteer: allowSteer) }
    }
    func createOwnedChatGPT(sourceRuntimeId: String, workspace: URL, executable: URL, lease: UUID) async {
        await ownerOperation(expectedLease: lease) {
            try await $0.ownerCreateChatGPT(sourceRuntimeId: sourceRuntimeId, workspace: workspace, executable: executable)
        }
    }
    func detachOwnedChatGPT(id: String, lease: UUID) async {
        await ownerOperation(expectedLease: lease) { try await $0.ownerDetachChatGPT(id: id) }
    }
    func approveDevice(id: UUID, scopes: [String], runtimeIds: Set<String>, expectedVersion: Int, lease: UUID) async {
        await ownerOperation(expectedLease: lease) { try await $0.ownerApprove(id: id, scopes: scopes, runtimeIds: runtimeIds, expectedVersion: expectedVersion) }
    }
    func rejectDevice(id: UUID, lease: UUID) async { await ownerOperation(expectedLease: lease) { try await $0.ownerReject(id: id) } }
    func revokeDevice(userId: String, deviceId: String, expectedVersion: Int, lease: UUID) async {
        await ownerOperation(expectedLease: lease) { try await $0.ownerRevoke(userId: userId, deviceId: deviceId, expectedVersion: expectedVersion) }
    }
    private func ownerOperation(expectedLease: UUID? = nil, _ action: (RemoteProductionService) async throws -> Void) async {
        guard !ownerBusy, status == .running, let current = service as? RemoteProductionService else { return }
        guard expectedLease == nil || expectedLease == current.ownerLease else { return }
        let lease = generation; ownerBusy = true; ownerMessage = nil
        defer { if generation == lease { ownerBusy = false } }
        do {
            try await action(current)
            let state = try await current.ownerState()
            guard generation == lease, status == .running else { return }
            ownerState = state
        } catch {
            guard generation == lease else { return }
            ownerState = nil
            ownerMessage = "设备授权操作未完成，请刷新后检查设备、权限与本机版本。"
        }
    }
    nonisolated static func chatGPTSources(_ root: URL) async throws -> [any RemoteReadAdapter] {
        try await Task.detached {
            let root = root.resolvingSymlinksInPath().standardizedFileURL
            let candidates = [root.appendingPathComponent("state_5.sqlite"), root.appendingPathComponent("sqlite/state_5.sqlite")]
            guard let database = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { throw ChatGPTDirectoryError.unavailable }
            let digest = SHA256.hash(data: Data(root.path.utf8)).map { String(format: "%02x", $0) }.joined()
            let directory = ChatGPTSessionDirectory(databaseURL: database, storageRoot: root, runtimeId: "rt_chatgpt_" + String(digest.prefix(24)))
            _ = try directory.snapshot(maximumRows: 1)
            return [ChatGPTReadAdapter(directory: directory, runtimeLabel: root.lastPathComponent)] as [any RemoteReadAdapter]
        }.value
    }
}
