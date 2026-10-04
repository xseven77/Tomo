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
    typealias Factory = @Sendable (DesktopCloudSession, URL, URL, RemoteTLSIdentity, URL, [any RemoteReadAdapter]) async throws -> any RemoteProductionHosting
    typealias Sources = @Sendable (URL) async throws -> [any RemoteReadAdapter]
    private(set) var status: Status = .stopped
    private(set) var choices: [RemoteTLSChoice] = []
    private(set) var message: String?
    private(set) var endpoint: URL?
    private(set) var ownerState: RemoteProductionService.OwnerState?
    private(set) var ownerBusy = false
    private(set) var ownerMessage: String?
    private let cloud: DesktopCloudManager
    private let catalog: any RemoteTLSIdentityCatalog
    private let directory: URL
    private let factory: Factory
    private let sources: Sources
    @ObservationIgnored private var service: (any RemoteProductionHosting)?
    @ObservationIgnored private var startup: Task<any RemoteProductionHosting, Error>?
    @ObservationIgnored private var observation: Task<Void, Never>?
    private var generation: UInt64 = 0
    init(cloud: DesktopCloudManager, catalog: any RemoteTLSIdentityCatalog = KeychainRemoteTLSIdentityCatalog(),
         directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tomo/RemoteServers"),
         sources: @escaping Sources = RemoteProductionManager.chatGPTSources,
         factory: @escaping Factory = { cloud, issuer, endpoint, tls, directory, adapters in
             try await RemoteProductionService.start(cloudSession: cloud, issuer: issuer, endpoint: endpoint,
                tlsIdentity: tls, signingIdentity: RemoteServerIdentity(), directory: directory, adapters: adapters)
         }) {
        self.cloud = cloud; self.catalog = catalog; self.directory = directory; self.factory = factory; self.sources = sources
        cloud.installRemoteStopHandler { [weak self] in await self?.stop() }
    }
    deinit { startup?.cancel(); observation?.cancel(); if let service { Task { await service.stop() } } }
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
    func start(endpoint text: String, certificateId: String, storageRoot: URL) async {
        guard !isBusy, service == nil else { return }
        generation &+= 1; let lease = generation; status = .starting; message = nil
        do {
            let context = try cloud.remoteContext()
            guard let endpoint = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false), parts.scheme == "https",
                  parts.host?.isEmpty == false, parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
                  parts.path.isEmpty || parts.path == "/", (1...65535).contains(parts.port ?? 443),
                  storageRoot.isFileURL, choices.contains(where: { $0.id == certificateId }) else { throw RemoteAccessError.invalidConfiguration }
            let tls = try await catalog.identity(id: certificateId)
            guard generation == lease else { return }
            try Task.checkCancellation()
            let adapters = try await sources(storageRoot)
            guard generation == lease else { return }
            try Task.checkCancellation()
            let factory = factory, directory = directory.appendingPathComponent(context.server.id.uuidString.lowercased())
            let task = Task { try await factory(context.client, context.issuer, endpoint, tls, directory, adapters) }
            startup = task
            let active = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard generation == lease else { await active.stop(); return }
            if Task.isCancelled { await active.stop(); throw CancellationError() }
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
                message = "安全服务启动失败。请检查云登录/登记、证书域名与有效期、端口和会话目录。"
            }
        }
    }
    func stop() async {
        generation &+= 1; let lease = generation
        ownerState = nil; ownerBusy = false; ownerMessage = nil
        startup?.cancel(); startup = nil; observation?.cancel(); observation = nil
        let previous = service; service = nil; status = .stopping; endpoint = nil
        await previous?.stop()
        if lease == generation { status = .stopped }
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
    nonisolated private static func chatGPTSources(_ root: URL) async throws -> [any RemoteReadAdapter] {
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
