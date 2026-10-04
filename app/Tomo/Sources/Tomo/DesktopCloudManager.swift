import Foundation
import Observation

/// Native Settings owns configuration and safe projections. Never publishes credentials.
@MainActor @Observable
final class DesktopCloudManager {
    static let shared = DesktopCloudManager()
    enum Operation: Equatable { case idle, restoring, sendingCode, signingIn, registering, signingOut }
    private(set) var operation: Operation = .idle
    private(set) var summary: DesktopCloudSession.Summary?
    private(set) var server: DesktopCloudSession.RegisteredServer?
    private(set) var codeSent = false
    private(set) var message: String?
    private(set) var configuredURL: String
    private var client: DesktopCloudSession?
    private var generation: UInt64 = 0
    private let defaults: UserDefaults
    private let factory: (URL) throws -> DesktopCloudSession
    private let key = "tomo.cloud.owner.issuer"
    private var remoteStop: (@MainActor () async -> Void)?
    struct RemoteContext: Sendable { let client: DesktopCloudSession; let issuer: URL; let server: DesktopCloudSession.RegisteredServer }
    func installRemoteStopHandler(_ handler: @escaping @MainActor () async -> Void) { remoteStop = handler }
    func remoteContext() throws -> RemoteContext {
        guard !isBusy, let client, let server, let issuer = URL(string: configuredURL) else { throw DesktopCloudError.signedOut }
        return .init(client: client, issuer: issuer, server: server)
    }

    init(defaults: UserDefaults = .standard, factory: @escaping (URL) throws -> DesktopCloudSession = { try DesktopCloudSession(endpoint: $0) }) {
        self.defaults = defaults; self.factory = factory
        configuredURL = defaults.string(forKey: key) ?? ""
    }
    var isBusy: Bool { operation != .idle }
    var isConfigured: Bool { client != nil }

    func restore() async {
        if client != nil { await refresh(); return }
        guard client == nil, !configuredURL.isEmpty, !isBusy else { return }
        await configure(configuredURL)
    }
    func configure(_ text: String) async {
        guard !isBusy, client == nil else { return }
        do {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: text) else { throw DesktopCloudError.invalidConfiguration }
            let next = try factory(url)
            client = next; configuredURL = url.absoluteString; defaults.set(configuredURL, forKey: key)
            await perform(.restoring) { _ = try await $0.currentSession() }
        } catch { message = Self.display(error) }
    }
    func sendCode(email: String) async {
        guard !isBusy else { return }; codeSent = false
        let expected = generation &+ 1
        await perform(.sendingCode) { try await $0.beginLogin(email: email) }
        if generation == expected, message == nil, isConfigured, operation == .idle { codeSent = true }
    }
    func signIn(code: String) async {
        guard !isBusy, codeSent else { return }; codeSent = false
        await perform(.signingIn) { _ = try await $0.completeLogin(code: code) }
    }
    func register(name: String) async {
        guard !isBusy, summary != nil else { return }
        await perform(.registering) { _ = try await $0.registerServer(name: name) }
    }
    func refresh() async { await perform(.restoring) { _ = try await $0.currentSession() } }
    func logout(clearConfiguration: Bool = false) async {
        guard let client else {
            if clearConfiguration { configuredURL = ""; defaults.removeObject(forKey: key) }
            return
        }
        generation &+= 1; let lease = generation
        operation = .signingOut; summary = nil; server = nil; codeSent = false; message = nil
        await remoteStop?()
        guard lease == generation else { return }
        do { try await client.logout() }
        catch {
            guard lease == generation else { return }
            if error as? DesktopCloudError == .storageUnavailable {
                message = "无法清除 Keychain 中的登录，请解锁后再次退出。"; operation = .idle; return
            }
            message = "本机已退出，云端退出请求未完成。"
        }
        guard lease == generation else { return }
        if clearConfiguration {
            self.client = nil; configuredURL = ""; defaults.removeObject(forKey: key)
        }
        operation = .idle
    }
    private func perform(_ next: Operation, action: (DesktopCloudSession) async throws -> Void) async {
        guard !isBusy, let client else { return }
        generation &+= 1; let lease = generation; operation = next; message = nil
        if next == .signingIn || next == .registering { await remoteStop?() }
        guard lease == generation else { return }
        do { try await action(client) }
        catch { if lease == generation { message = Self.display(error) } }
        guard lease == generation else { return }
        let summary = await client.summary(), server = await client.registeredServer()
        guard lease == generation else { return }
        if server != self.server { await remoteStop?() }
        guard lease == generation else { return }
        self.summary = summary; self.server = server; operation = .idle
    }
    private static func display(_ error: Error) -> String {
        if let value = error as? DesktopCloudError {
            switch value {
            case .invalidConfiguration: return "请填写受信任的 HTTPS 云服务地址，不包含路径、账号或查询参数。"
            case .invalidRequest: return "请检查邮箱、六位验证码或服务器名称。"
            case .invalidResponse: return "云服务响应未通过校验，请检查服务版本与配置。"
            case .storageUnavailable: return "无法访问本机 Keychain，请解锁后重试。"
            case .signedOut: return "登录已过期，请重新登录。"
            case .busy: return "另一个请求仍在处理中，请稍后重试。"
            case .staleResponse: return "登录状态已改变，请重新操作。"
            case .rejected(let code):
                switch code {
                case "session_revoked", "auth_required", "access_expired": return "云端会话已失效，请重新登录。"
                case "rate_limited": return "请求过于频繁，请稍后重试。"
                case "invalid_code", "invalid_challenge": return "验证码无效或过期，请重新获取。"
                case "server_key_unavailable": return "此服务器密钥已登记到其他账号或已撤销。"
                case "server_limit": return "账号登记的服务器数量已达到上限。"
                default: return "云服务拒绝了请求，请检查账号与配置。"
                }
            }
        }
        if let value = error as? RemoteServerIdentityError {
            switch value {
            case .storageUnavailable: return "无法访问服务器身份 Keychain，请解锁后重试。"
            case .corruptIdentity: return "服务器签名身份损坏，需要处理原有登记；系统未自动更换密钥。"
            case .invalidChallenge: return "服务器登记挑战未通过会话与有效期校验。"
            }
        }
        return "连接云服务失败，请检查网络和 HTTPS 配置。"
    }
}
