import Foundation
import Network

/// All business routes use the same local registries and operation authority.
struct RemoteProductionBusinessRouter: Sendable {
    let reads: RemoteReadService
    let operations: RemoteOperationService
    func handle(_ request: RemoteProductionAccessRouter.Request, principal: RemoteAccessStore.Principal) async throws -> RemoteProductionAccessRouter.Response {
        let segments = request.path.split(separator: "/")
        let data: Data
        if request.method == "GET" {
            guard request.body.isEmpty else { throw RemoteReadError.invalidRequest }
            if segments.count == 5, segments[3] == "operations" {
                data = try await operations.operation(id: String(segments[4]), query: request.query, principal: principal)
            } else if segments.count == 8, segments[3] == "sessions", segments[5] == "operations", segments[6] == "by-key" {
                data = try await operations.byKey(sessionId: String(segments[4]), key: String(segments[7]), query: request.query, principal: principal)
            } else { data = try await reads.response(path: request.path, query: request.query, principal: principal) }
            return .init(status: 200, headers: ["Content-Type": "application/json", "Cache-Control": "no-store"], body: data)
        }
        guard request.method == "POST", segments.count == 6, segments[3] == "sessions",
              let action = ["messages": RemoteAction.sendMessage, "interrupt": .interrupt,
                            "approvals": .approve, "answers": .answer,
                            "approve": .approve, "answer": .answer][String(segments[5])] else { throw RemoteReadError.notImplemented }
        let types = request.headers.filter { $0.0.lowercased() == "content-type" }
        let keys = request.headers.filter { $0.0.lowercased() == "idempotency-key" }
        guard types.count == 1, keys.count == 1,
              types[0].1.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else { throw RemoteReadError.invalidRequest }
        let operation = try await operations.submit(sessionId: String(segments[4]), query: request.query,
            action: action, key: keys[0].1.trimmingCharacters(in: CharacterSet(charactersIn: " \t")), body: request.body, principal: principal)
        return .init(status: 202, headers: ["Content-Type": "application/json", "Cache-Control": "no-store"], body: try operation.responseData())
    }
}

/// Native-owned service lifetime. No identity comes from HTTP parameters.
actor RemoteProductionService {
    struct Server: Sendable {
        let id: UUID
        let name: String, keyThumbprint: String
    }
    nonisolated let server: Server
    nonisolated let localIdentity: RemoteLocalGrantAuthority.Identity?
    nonisolated let ledger: RemoteAuthorizationLedger
    nonisolated let approval: RemoteBindingApproval
    nonisolated let reads: RemoteReadService
    nonisolated let sessions: RemoteSessionService
    nonisolated let operations: RemoteOperationService
    nonisolated let registry: RemoteRuntimeScopeRegistry
    nonisolated let exchange: RemoteGrantExchange
    nonisolated let ownedChatGPT: RemoteOwnedChatGPTService
    private let listener: RemoteHTTPSListener
    private let trust: RemoteCloudTrust?
    private let localAuthority: RemoteLocalGrantAuthority?
    private var stopped = false
    private var pairingRequests = Set<UUID>()
    private var pairedRequests: [UUID: (user: String, device: String, version: Int)] = [:]
    nonisolated let ownerLease = UUID()
    struct OwnerState: Sendable {
        let lease: UUID
        let pending: [RemoteBindingApproval.Pending]
        let bindings: [RemoteAuthorizationLedger.Binding]
        let runtimes: [RemoteRuntimeScopeRegistry.OwnerRuntime]
        let ownedChoices: [RemoteOwnedChatGPTService.Choice]
        let ownedAccounts: [RemoteOwnedChatGPTService.Account]
        let ownedRuntimes: [RemoteOwnedChatGPTService.Owned]
    }
    func ownerState() async throws -> OwnerState {
        guard !stopped else { throw RemoteAccessError.unavailable }
        let pending = await approval.pendingItems(), bindings = try await ledger.ownerBindings()
        let ownedRuntimes = await ownedChatGPT.owned(), ownedChoices = try await ownedChatGPT.choices()
        let ownedAccounts = try await ownedChatGPT.accounts()
        let runtimes = try await registry.ownerRuntimes()
        guard !stopped else { throw RemoteAccessError.unavailable }
        return .init(lease: ownerLease, pending: pending, bindings: bindings, runtimes: runtimes,
                     ownedChoices: ownedChoices, ownedAccounts: ownedAccounts, ownedRuntimes: ownedRuntimes)
    }
    func ownerAttachChatGPT(sourceRuntimeId: String, sessionId: String, executable: URL, allowSteer: Bool) async throws {
        guard !stopped else { throw RemoteAccessError.unavailable }
        _ = try await ownedChatGPT.attach(sourceRuntimeId: sourceRuntimeId, sessionId: sessionId, executable: executable, allowSteer: allowSteer)
        guard !stopped else { throw RemoteAccessError.unavailable }
    }
    func ownerCreateChatGPT(sourceRuntimeId: String, workspace: URL, executable: URL) async throws {
        guard !stopped else { throw RemoteAccessError.unavailable }
        _ = try await ownedChatGPT.create(sourceRuntimeId: sourceRuntimeId, workspace: workspace, executable: executable)
        guard !stopped else { throw RemoteAccessError.unavailable }
    }
    func ownerDetachChatGPT(id: String) async throws {
        guard !stopped else { throw RemoteAccessError.unavailable }
        await ownedChatGPT.detach(id: id)
    }
    static func ownerScopes(_ runtimes: [RemoteRuntimeScopeRegistry.OwnerRuntime]) -> Set<String> {
        let actions = runtimes.reduce(into: Set<RemoteAction>()) { $0.formUnion($1.actions) }
        var scopes = Set<String>()
        if actions.contains(.listSessions) { scopes.insert("discovery") }
        if actions.contains(.readHistory) { scopes.insert("session.read") }
        if !actions.isDisjoint(with: [.sendMessage, .interrupt]) { scopes.insert("session.write") }
        if !actions.isDisjoint(with: [.approve, .answer]) { scopes.insert("session.approve") }
        return scopes
    }
    /// Only called from native owner Settings. Receipt stays inside the pairing protocol.
    func ownerApprove(id: UUID, scopes: [String], runtimeIds: Set<String>, expectedVersion: Int) async throws {
        guard !stopped, !runtimeIds.isEmpty, runtimeIds.count <= 128 else { throw RemoteAccessError.invalidConfiguration }
        let available = try await registry.ownerRuntimes()
        let selected = available.filter { runtimeIds.contains($0.id) }
        guard !stopped, selected.count == runtimeIds.count, !scopes.isEmpty,
              Set(scopes).count == scopes.count, Set(scopes).isSubset(of: Self.ownerScopes(selected)) else { throw RemoteAccessError.forbidden }
        _ = try await approval.approve(id: id, scopes: scopes, resources: selected.map { try $0.resource() }, expectedLocalVersion: expectedVersion)
        guard !stopped else { throw RemoteAccessError.unavailable }
    }
    func ownerReject(id: UUID) async throws {
        guard !stopped else { throw RemoteAccessError.unavailable }
        try await approval.reject(id: id)
    }
    /// Invoked only through the snapshot-pairing gateway while the desktop phone switch is on.
    /// The native binding router has already verified the device key and DPoP request.
    func pairPhoneDevice(requestId: UUID) async throws {
        guard !stopped, localIdentity != nil, !pairingRequests.contains(requestId) else {throw RemoteAccessError.forbidden}
        if let previous = pairedRequests[requestId] {
            guard let binding = try await ledger.ownerBinding(userId: previous.user, deviceId: previous.device),
                  !binding.revoked, binding.localVersion == previous.version else {throw RemoteAccessError.forbidden}
            return
        }
        guard pairedRequests.count < 128 else {throw RemoteAccessError.unavailable}
        pairingRequests.insert(requestId); defer {pairingRequests.remove(requestId)}
        guard let pending = await approval.pendingItems().first(where: {$0.id == requestId}) else {throw RemoteAccessError.forbidden}
        let available = try await registry.ownerRuntimes()
        let selected = available.filter { $0.actions.contains(.listSessions) || $0.actions.contains(.readHistory) }
        let existing = try await ledger.ownerBinding(userId: pending.userId, deviceId: pending.deviceId)
        guard existing?.revoked != true else {throw PhoneSessionPairingError.revoked}
        let version = existing?.localVersion ?? 0
        guard !stopped, !selected.isEmpty else {throw RemoteAccessError.unavailable}
        try await ownerApprove(id: requestId, scopes: Self.ownerScopes(selected).sorted(), runtimeIds: Set(selected.map(\.id)), expectedVersion: version)
        guard !stopped else {throw RemoteAccessError.unavailable}
        pairedRequests[requestId] = (pending.userId, pending.deviceId, version + 1)
    }
    func ownerRevoke(userId: String, deviceId: String, expectedVersion: Int) async throws {
        guard !stopped else { throw RemoteAccessError.unavailable }
        _ = try await ledger.revoke(userId: userId, deviceId: deviceId, expectedLocalVersion: expectedVersion)
    }
    deinit {
        operations.stopAccepting()
        Task { [exchange, listener, trust, localAuthority, operations, ownedChatGPT] in
            await exchange.shutdown(); await listener.stop(); await ownedChatGPT.stop(); await trust?.stop(); await localAuthority?.shutdown(); await operations.shutdown()
        }
    }
    private init(server: Server, ledger: RemoteAuthorizationLedger, approval: RemoteBindingApproval,
                 reads: RemoteReadService, sessions: RemoteSessionService, operations: RemoteOperationService,
                 registry: RemoteRuntimeScopeRegistry, exchange: RemoteGrantExchange, listener: RemoteHTTPSListener, trust: RemoteCloudTrust?,
                 localAuthority: RemoteLocalGrantAuthority? = nil,
                 ownedChatGPT: RemoteOwnedChatGPTService) {
        self.server = server; self.ledger = ledger; self.approval = approval; self.reads = reads; self.sessions = sessions
        self.operations = operations; self.registry = registry; self.exchange = exchange; self.listener = listener; self.trust = trust
        self.ownedChatGPT = ownedChatGPT
        self.localAuthority = localAuthority; self.localIdentity = localAuthority?.identity
    }
    static func start(cloudSession: DesktopCloudSession, issuer: URL, endpoint: URL, tlsIdentity: RemoteTLSIdentity?,
                      signingIdentity: RemoteServerIdentity, directory: URL, adapters: [any RemoteReadAdapter],
                      cloudHTTP: any DesktopCloudHTTP = DesktopCloudURLSession(), bindHost: NWEndpoint.Host? = nil) async throws -> RemoteProductionService {
        guard let server = await cloudSession.registeredServer(), !adapters.isEmpty, adapters.count <= 128,
              directory.isFileURL, await cloudSession.trustedIssuer() == issuer else { throw RemoteAccessError.invalidConfiguration }
        let id = server.id.uuidString.lowercased()
        let trust = try RemoteCloudTrust(issuer: issuer, serverId: id, http: cloudHTTP)
        var listener: RemoteHTTPSListener?
        var operations: RemoteOperationService?
        do {
            let cloud = try await trust.start()
            let ledger = try RemoteAuthorizationLedger(databaseURL: directory.appendingPathComponent("acl.sqlite"), serverId: id)
            let registry = RemoteRuntimeScopeRegistry()
            let sessions = RemoteSessionService(serverId: id), proof = RemoteDPoPVerifier()
            let reads = RemoteReadService(serverId: id, authorizationRegistry: registry, sessionService: sessions)
            for adapter in adapters { try await reads.register(adapter) }
            let exchange = try RemoteGrantExchange(cloud: cloud, ledger: ledger, proof: proof, endpoint: endpoint, resources: registry)
            let store = try RemoteOperationStore(databaseURL: directory.appendingPathComponent("operations.sqlite"))
            let commands = RemoteOperationService(serverId: id, access: exchange, store: store,
                identity: { principal in try await exchange.owner(principal) })
            operations = commands
            let approval = try await signingIdentity.bindingApproval(cloud: cloud, ledger: ledger,
                serverId: id, issuer: issuer.absoluteString, registeredThumbprint: server.keyThumbprint)
            let binding = try RemoteBindingRouter(endpoint: endpoint, cloud: cloud, proof: proof, approval: approval)
            let business = RemoteProductionBusinessRouter(reads: reads, operations: commands)
            let transport = try RemoteHTTPSListener(identity: tlsIdentity, router: .cloudVerified(exchange: exchange, cloud: cloud),
                bindHost: bindHost, bindingRouter: binding, sessionService: sessions,
                handler: { request, principal in try await business.handle(request, principal: principal) })
            listener = transport
            let service = Self(server: .init(id: server.id, name: server.name, keyThumbprint: server.keyThumbprint), ledger: ledger, approval: approval, reads: reads, sessions: sessions,
                operations: commands, registry: registry, exchange: exchange, listener: transport, trust: trust,
                ownedChatGPT: RemoteOwnedChatGPTService(sources: adapters.compactMap { $0 as? ChatGPTReadAdapter }, directory: directory.appendingPathComponent("owned-journals"),
                    reads: reads, sessions: sessions, operations: commands))
            try await transport.installTerminationHandler { [weak service] in await service?.stop() }
            try Task.checkCancellation()
            guard await cloudSession.registeredServer() == server else { throw RemoteAccessError.unauthorized }
            try await transport.start()
            try Task.checkCancellation()
            guard await cloudSession.registeredServer() == server else { throw RemoteAccessError.unauthorized }
            return service
        } catch {
            operations?.stopAccepting(); await listener?.stop(); await trust.stop(); await operations?.shutdown(); throw error
        }
    }
    static func startLocal(endpoint: URL, tlsIdentity: RemoteTLSIdentity?, signingIdentity: RemoteServerIdentity,
                           directory: URL, adapters: [any RemoteReadAdapter], name: String,
                           ownedConversationDirectory: RemoteOwnedChatGPTService.PhoneDirectory? = nil,
                           bindHost: NWEndpoint.Host? = nil) async throws -> RemoteProductionService {
        guard RemoteEndpoint.valid(endpoint), directory.isFileURL, !adapters.isEmpty, adapters.count <= 128,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw RemoteAccessError.invalidConfiguration
        }
        let identity = try await signingIdentity.localIdentity(), id = identity.serverId.uuidString.lowercased()
        let ledger = try RemoteAuthorizationLedger(databaseURL: directory.appendingPathComponent("acl.sqlite"), serverId: id)
        let authority = try await signingIdentity.localGrantAuthority(ledger: ledger)
        var listener: RemoteHTTPSListener?, operations: RemoteOperationService?
        do {
            let registry = RemoteRuntimeScopeRegistry(), sessions = RemoteSessionService(serverId: id), proof = RemoteDPoPVerifier()
            let reads = RemoteReadService(serverId: id, authorizationRegistry: registry, sessionService: sessions)
            for adapter in adapters { try await reads.register(adapter) }
            let exchange = try RemoteGrantExchange(cloud: authority, ledger: ledger, proof: proof, endpoint: endpoint, resources: registry)
            let store = try RemoteOperationStore(databaseURL: directory.appendingPathComponent("operations.sqlite"))
            let commands = RemoteOperationService(serverId: id, access: exchange, store: store,
                identity: { principal in try await exchange.owner(principal) })
            operations = commands
            let approval = try await signingIdentity.localBindingApproval(authority: authority, ledger: ledger)
            let binding = try RemoteBindingRouter(endpoint: endpoint, cloud: authority, proof: proof, approval: approval)
            let business = RemoteProductionBusinessRouter(reads: reads, operations: commands)
            let transport = try RemoteHTTPSListener(identity: tlsIdentity,
                router: .localApproved(exchange: exchange, authority: authority), bindHost: bindHost,
                bindingRouter: binding, sessionService: sessions,
                handler: { request, principal in try await business.handle(request, principal: principal) })
            listener = transport
            let service = Self(server: .init(id: identity.serverId, name: name, keyThumbprint: identity.thumbprint),
                ledger: ledger, approval: approval, reads: reads, sessions: sessions, operations: commands,
                registry: registry, exchange: exchange, listener: transport, trust: nil, localAuthority: authority,
                ownedChatGPT: RemoteOwnedChatGPTService(sources: adapters.compactMap { $0 as? ChatGPTReadAdapter },
                    directory: directory.appendingPathComponent("owned-journals"), reads: reads, sessions: sessions, operations: commands,
                    phoneDirectory: ownedConversationDirectory))
            try await transport.installTerminationHandler { [weak service] in await service?.stop() }
            try Task.checkCancellation(); try await transport.start(); try Task.checkCancellation()
            return service
        } catch {
            operations?.stopAccepting(); await listener?.stop(); await authority.shutdown(); await operations?.shutdown(); throw error
        }
    }
    func stop() async {
        guard !stopped else { return }; stopped = true
        operations.stopAccepting(); await exchange.shutdown(); await listener.stop(); await ownedChatGPT.stop(); await trust?.stop(); await localAuthority?.shutdown(); await operations.shutdown()
    }
    nonisolated var states: AsyncStream<RemoteHTTPSListener.State> { listener.states }
}
