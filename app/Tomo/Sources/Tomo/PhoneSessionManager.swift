import Foundation
import Observation
import Darwin

enum PhoneSessionPairingError: Error {case revoked}

/// The desktop switch owns this local service. Pairing-token rotation selects a
/// separate ledger, so phones paired with an older code cannot silently renew.
@MainActor @Observable final class PhoneSessionManager {
    static let shared = PhoneSessionManager()
    enum Status: Equatable { case disabled, waiting, starting, ready, failed }
    private(set) var isEnabled: Bool
    private(set) var status: Status
    private(set) var message: String?
    var needsIdentityAuthorization: Bool { remote.needsIdentityAuthorization }
    private let defaults: UserDefaults
    private let remote: RemoteProductionManager
    private let root: URL
    private static let key = "tomo.mobileSync.phoneSessionsEnabled"
    private struct Connection: Equatable { let host: String; let port: UInt16; let token: String }
    @ObservationIgnored private var connection: Connection?
    @ObservationIgnored private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(defaults: UserDefaults = .standard, remote: RemoteProductionManager = .shared,
         storageRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) {
        self.defaults = defaults; self.remote = remote; root = storageRoot
        let enabled = defaults.bool(forKey: Self.key); isEnabled = enabled; status = enabled ? .waiting : .disabled
    }
    deinit { task?.cancel() }
    func setEnabled(_ value: Bool) {
        isEnabled = value; defaults.set(value, forKey: Self.key); reconcile(allowIdentityInteraction: value)
    }
    func updateConnection(host: String, preferredPort: UInt16, pairingToken: String) {
        let next = Connection(host: host, port: preferredPort, token: pairingToken)
        guard next != connection else { return }; connection = next; reconcile()
    }
    func suspend() {connection = nil; reconcile()}
    func retry() {reconcile(allowIdentityInteraction: true)}
    private func reconcile(allowIdentityInteraction: Bool = false) {
        generation &+= 1; let lease = generation, previous = task, context = connection
        remote.invalidatePhonePairing(); previous?.cancel(); message = nil
        status = isEnabled ? (context == nil ? .waiting : .starting) : .disabled
        task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.remote.stopPhoneSessions()
            guard lease == self.generation, self.isEnabled, let context, !Task.isCancelled else { return }
            await self.remote.startPhoneSessions(host: context.host, preferredPort: context.port,
                pairingToken: context.token, storageRoot: self.root, allowIdentityInteraction: allowIdentityInteraction)
            guard lease == self.generation, !Task.isCancelled else {await self.remote.stopPhoneSessions(); return}
            self.status = self.remote.phonePairingEnabled ? .ready : .failed
            self.message = self.remote.message
        }
    }
    func configuration() async -> String? {
        guard isEnabled, status == .ready, connection != nil else { return nil }
        let lease = generation
        let result = try? await remote.mobileHostConfiguration(includeInteraction: true)
        guard lease == generation, isEnabled, status == .ready, remote.phonePairingEnabled else { return nil }
        message = remote.message
        return result
    }
    func pair(serverId: String, requestId: UUID) async throws {
        guard isEnabled, status == .ready, connection != nil else {throw RemoteAccessError.forbidden}
        let lease = generation
        try await remote.pairPhoneDevice(serverId: serverId, requestId: requestId)
        guard lease == generation, isEnabled, status == .ready else {throw RemoteAccessError.forbidden}
    }
    /// Tests and shutdown can wait for the currently requested switch state.
    func settled() async {await task?.value}
}

enum PhoneSessionEndpoint {
    static func make(host: String, preferredPort: UInt16) throws -> URL {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {throw RemoteAccessError.unavailable}
        defer {Darwin.close(descriptor)}
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = preferredPort.bigEndian
        func bindAddress() -> Int32 {withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))}
        }}
        if bindAddress() != 0 {address.sin_port = 0; guard bindAddress() == 0 else {throw RemoteAccessError.unavailable}}
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {getsockname(descriptor, $0, &size)}
        }
        guard result == 0 else {throw RemoteAccessError.unavailable}
        var value = URLComponents(); value.scheme = "http"; value.host = host; value.port = Int(UInt16(bigEndian: address.sin_port))
        guard let endpoint = value.url, RemoteEndpoint.valid(endpoint) else {throw RemoteAccessError.invalidConfiguration}
        return endpoint
    }
}
