import Foundation
import CryptoKit
import Security

/// Production credential chain. HTTP adapters supply a trusted HTTPS endpoint
/// and reject duplicate headers before calling this authority. This authority
/// is deliberately separate from the owner-issued development credential store.
actor RemoteGrantExchange: RemotePrincipalValidator {
    typealias ResourceResolver = @Sendable ([RemoteCloudGrantVerifier.Resource], Set<RemoteAction>, RemoteClientCapabilities) async throws -> [RemoteAccessStore.Scope]
    struct Issued: Sendable {
        let token: String
        let tokenType = "DPoP"
        let principal: RemoteAccessStore.Principal
    }
    private struct Credential {
        let token: String // Memory only, to return the same successful exchange on retry.
        let digest: String
        let receipt: RemoteAuthorizationLedger.Receipt
        let thumbprint: String
        let principal: RemoteAccessStore.Principal
    }
    private let cloud: RemoteCloudGrantVerifier
    nonisolated let serverId: String
    private let ledger: RemoteAuthorizationLedger
    private let proof: RemoteDPoPVerifier
    nonisolated let endpoint: URL
    private let resolve: ResourceResolver
    private let maximumCredentials: Int
    private var credentials: [String: Credential] = [:]
    private var stopped = false
    func shutdown() { stopped = true; credentials.removeAll() }

    init(cloud: RemoteCloudGrantVerifier, ledger: RemoteAuthorizationLedger, proof: RemoteDPoPVerifier,
         endpoint: URL, maximumCredentials: Int = 128, resolve: @escaping ResourceResolver) throws {
        guard let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host != nil, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/",
              (1...128).contains(maximumCredentials) else { throw RemoteAccessError.invalidConfiguration }
        self.cloud = cloud; self.ledger = ledger; self.proof = proof; self.endpoint = endpoint; self.serverId = ledger.serverId
        self.maximumCredentials = maximumCredentials; self.resolve = resolve
    }
    init(cloud: RemoteCloudGrantVerifier, ledger: RemoteAuthorizationLedger, proof: RemoteDPoPVerifier,
         endpoint: URL, maximumCredentials: Int = 128, resources: RemoteRuntimeScopeRegistry) throws {
        try self.init(cloud: cloud, ledger: ledger, proof: proof, endpoint: endpoint, maximumCredentials: maximumCredentials,
            resolve: { granted, actions, client in try await resources.resolve(granted, actions: actions, client: client) })
    }
    func exchangeNonce(grant: String, now: Date = Date()) async throws -> String {
        guard !stopped else { throw RemoteAccessError.unavailable }
        let claims = try await cloud.verify(grant, now: now)
        guard !stopped else { throw RemoteAccessError.unavailable }
        return try await proof.challenge(thumbprint: claims.cnf.jkt,
            expiresAt: Date(timeIntervalSince1970: Double(claims.exp)), now: now)
    }
    func exchange(grant: String, dpop: String, client: RemoteClientCapabilities, origin: String? = nil, now: Date = Date()) async throws -> Issued {
        guard !stopped else { throw RemoteAccessError.unavailable }
        guard origin == nil else { throw RemoteAccessError.forbidden }
        let client = try client.normalized()
        _ = try client.negotiatedProtocol()
        let started = ContinuousClock.now
        let claims = try await cloud.verify(grant, now: now)
        try await proof.verify(dpop, thumbprint: claims.cnf.jkt, token: grant, method: "POST",
            url: target("/api/v1/remote/access/exchange"), now: current(now, since: started))
        let receipt = try await ledger.consume(claims, now: current(now, since: started))
        let scopes = try await resolved(receipt, client: client)
        try await ledger.validate(receipt, now: current(now, since: started))
        guard !stopped, receipt.expiresAt > current(now, since: started) else { throw RemoteAccessError.unauthorized }
        prune(current(now, since: started))
        if let previous = credentials[receipt.accessId] {
            guard previous.receipt == receipt, previous.principal.scopes == scopes,
                  previous.principal.clientCapabilities == client else { throw RemoteAccessError.unauthorized }
            return .init(token: previous.token, principal: previous.principal)
        }
        guard credentials.count < maximumCredentials, let id = UUID(uuidString: receipt.accessId) else { throw RemoteAccessError.unavailable }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw RemoteAccessError.unavailable }
        let token = "tomo_remote_" + Self.encoded(Data(bytes))
        let principal = RemoteAccessStore.Principal(id: id, expiresAt: receipt.expiresAt, scopes: scopes, origin: nil, generation: 0, clientCapabilities: client)
        credentials[receipt.accessId] = .init(token: token, digest: Self.digest(token), receipt: receipt,
            thumbprint: claims.cnf.jkt, principal: principal)
        return .init(token: token, principal: principal)
    }
    /// Challenge issuance does not authenticate a request or grant any scope.
    func accessNonce(authorization: String?, origin: String? = nil, now: Date = Date()) async throws -> String {
        let credential = try lookup(authorization, origin: origin, now: now)
        try await ledger.validate(credential.receipt, now: now)
        guard credentials[credential.receipt.accessId]?.digest == credential.digest else { throw RemoteAccessError.unauthorized }
        return try await proof.challenge(thumbprint: credential.thumbprint, expiresAt: credential.receipt.expiresAt, now: now)
    }
    func authenticate(authorization: String?, dpop: String, method: String, path: String,
                      origin: String? = nil, now: Date = Date()) async throws -> RemoteAccessStore.Principal {
        let started = ContinuousClock.now
        let credential = try lookup(authorization, origin: origin, now: now)
        try await ledger.validate(credential.receipt, now: now)
        try await proof.verify(dpop, thumbprint: credential.thumbprint, token: credential.token,
            method: method, url: target(path), now: current(now, since: started))
        try await validate(credential.principal, now: current(now, since: started))
        return credential.principal
    }
    /// Existing streams call this before each frame. No proof is reused per frame;
    /// the initial HTTP request proves possession, while ACL/expiry remain live.
    func validate(_ principal: RemoteAccessStore.Principal, now: Date = Date()) async throws {
        let started = ContinuousClock.now
        let key = principal.id.uuidString
        guard !stopped, let credential = credentials[key], credential.principal.scopes == principal.scopes,
              principal.origin == nil, principal.generation == 0, principal.expiresAt == credential.receipt.expiresAt,
              let client = principal.clientCapabilities, client == credential.principal.clientCapabilities else {
            throw RemoteAccessError.unauthorized
        }
        try await ledger.validate(credential.receipt, now: current(now, since: started))
        let currentScopes = try await resolved(credential.receipt, client: client)
        guard credentials[key]?.digest == credential.digest,
              currentScopes == principal.scopes else { throw RemoteAccessError.unauthorized }
        // The resolver may suspend; recheck persistent revocation after it returns.
        try await ledger.validate(credential.receipt, now: current(now, since: started))
        guard credentials[key]?.digest == credential.digest,
              credential.receipt.expiresAt > current(now, since: started) else { throw RemoteAccessError.unauthorized }
    }
    func revoke(_ principal: RemoteAccessStore.Principal) async throws {
        guard let credential = credentials[principal.id.uuidString] else { throw RemoteAccessError.unauthorized }
        try await ledger.revokeReceipt(credential.receipt)
        credentials.removeValue(forKey: principal.id.uuidString)
    }
    /// Original cloud identity only; never infer an owner from an access UUID.
    func owner(_ principal: RemoteAccessStore.Principal) async throws -> RemoteOperationOwner {
        try await validate(principal)
        guard let credential = credentials[principal.id.uuidString] else { throw RemoteAccessError.unauthorized }
        return .init(userId: credential.receipt.userId, deviceId: credential.receipt.deviceId)
    }

    private func resolved(_ receipt: RemoteAuthorizationLedger.Receipt, client: RemoteClientCapabilities) async throws -> [RemoteAccessStore.Scope] {
        let actions = Self.actions(receipt.scopes)
        let scopes = try await resolve(receipt.resources, actions, client)
        guard scopes.count <= 128, scopes.allSatisfy({ scope in !scope.agentId.isEmpty && !scope.runtimeId.isEmpty && scope.sessionId == nil &&
            scope.actions.isSubset(of: actions) && receipt.resources.contains(where: { resource in
                (resource.kind == "runtime" && resource.agentId == scope.agentId && resource.runtimeId == scope.runtimeId) || resource.kind == "workspace"
            }) }) else { throw RemoteAccessError.invalidConfiguration }
        // Stable ordering makes repeat exchange and live authorization comparisons deterministic.
        return scopes.sorted { ($0.agentId, $0.runtimeId) < ($1.agentId, $1.runtimeId) }
    }
    private func lookup(_ authorization: String?, origin: String?, now: Date) throws -> Credential {
        guard !stopped else { throw RemoteAccessError.unauthorized }
        guard origin == nil else { throw RemoteAccessError.forbidden }
        guard now.timeIntervalSince1970.isFinite, let authorization, authorization.hasPrefix("DPoP ") else {
            throw RemoteAccessError.unauthorized
        }
        let token = String(authorization.dropFirst(5))
        guard token.utf8.count <= 128, token.hasPrefix("tomo_remote_"), !token.contains(where: { $0.isWhitespace }) else {
            throw RemoteAccessError.unauthorized
        }
        prune(now)
        guard let value = credentials.values.first(where: { $0.digest == Self.digest(token) }) else { throw RemoteAccessError.unauthorized }
        return value
    }
    private func target(_ path: String) throws -> URL {
        guard path.hasPrefix("/api/v1/remote/"), !path.contains("#"), !path.contains("\\"),
              !path.contains(where: { $0.isWhitespace }), path.utf8.count <= 2048,
              let result = URL(string: path, relativeTo: endpoint)?.absoluteURL,
              result.host == endpoint.host, result.scheme == endpoint.scheme, result.port == endpoint.port else {
            throw RemoteAccessError.unauthorized
        }
        return result
    }
    private func prune(_ now: Date) { credentials = credentials.filter { $0.value.receipt.expiresAt > now } }
    private func current(_ date: Date, since start: ContinuousClock.Instant) -> Date {
        let elapsed = start.duration(to: .now).components
        return date.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    }
    private static func actions(_ scopes: [String]) -> Set<RemoteAction> {
        var result = Set<RemoteAction>()
        if scopes.contains("discovery") { result.insert(.listSessions) }
        if scopes.contains("session.read") { result.formUnion([.listSessions, .readHistory]) }
        if scopes.contains("session.write") { result.formUnion([.sendMessage, .interrupt, .resume, .create, .fork]) }
        if scopes.contains("session.approve") { result.formUnion([.approve, .answer]) }
        return result
    }
    private static func digest(_ text: String) -> String { Self.encoded(Data(SHA256.hash(data: Data(text.utf8)))) }
    private static func encoded(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
