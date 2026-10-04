import Foundation

/// Native lifetime for the verifier shared by HTTPS exchange and pairing.
/// Transport uses system TLS and refuses redirects; no cached disk trust or tokens.
actor RemoteCloudTrust {
    private let issuer: URL, serverId: String, http: any DesktopCloudHTTP
    private let lifetime: TimeInterval
    private let clock: @Sendable () -> Date
    private var verifier: RemoteCloudGrantVerifier?
    private var generation: UInt64 = 0
    private var loading = false
    private var maintenance: Task<Void, Never>?
    private(set) var expiresAt: Date?
    private(set) var lastRefreshFailed = false

    init(issuer: URL, serverId: String, http: any DesktopCloudHTTP = DesktopCloudURLSession(),
         lifetime: TimeInterval = 120, clock: @escaping @Sendable () -> Date = { Date() }) throws {
        guard let c = URLComponents(url: issuer, resolvingAgainstBaseURL: false), c.scheme == "https",
              c.host?.isEmpty == false, c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.path.isEmpty || c.path == "/", (1...65535).contains(c.port ?? 443),
              UUID(uuidString: serverId) != nil, lifetime.isFinite, (30...300).contains(lifetime) else { throw RemoteAccessError.invalidConfiguration }
        self.issuer = issuer; self.serverId = serverId; self.http = http; self.lifetime = lifetime; self.clock = clock
    }
    deinit { maintenance?.cancel() }

    func start() async throws -> RemoteCloudGrantVerifier {
        guard maintenance == nil, verifier == nil else { throw RemoteAccessError.invalidConfiguration }
        let lease = generation
        let loaded = try await refresh()
        guard lease == generation, verifier === loaded, !Task.isCancelled else {
            await loaded.invalidateTrust(); throw DesktopCloudError.staleResponse
        }
        maintenance = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = await self?.refreshDelay() else { return }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard !Task.isCancelled, let self else { return }
                do { _ = try await self.refresh() } catch { /* Existing deadline remains bounded; never extend on failure. */ }
            }
        }
        return loaded
    }
    /// Explicit refresh also supports lifecycle tests without waiting for timers.
    @discardableResult func refresh() async throws -> RemoteCloudGrantVerifier {
        try Task.checkCancellation()
        guard !loading else { throw DesktopCloudError.busy }
        loading = true; let lease = generation
        defer { loading = false }
        do {
            let requestedAt = clock()
            var request = URLRequest(url: issuer.appendingPathComponent(".well-known/jwks.json"), timeoutInterval: 30)
            request.httpMethod = "GET"; request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let reply = try await http.send(request)
            try Task.checkCancellation()
            guard lease == generation else { throw DesktopCloudError.staleResponse }
            guard reply.status == 200, reply.body.count <= 65536,
                  reply.contentType.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else { throw DesktopCloudError.invalidResponse }
            let now = clock(), deadline = requestedAt.addingTimeInterval(try cacheLifetime(reply))
            let next: RemoteCloudGrantVerifier
            if let verifier {
                try await verifier.replaceTrust(jwks: reply.body, trustedUntil: deadline, now: now); next = verifier
            } else {
                next = try await RemoteCloudGrantVerifier.configured(jwks: reply.body, issuer: issuer.absoluteString,
                    serverId: serverId, trustedUntil: deadline, now: now)
            }
            guard lease == generation, deadline > clock(), !Task.isCancelled else {
                await next.invalidateTrust(); throw DesktopCloudError.staleResponse
            }
            verifier = next; expiresAt = deadline; lastRefreshFailed = false; return next
        } catch {
            if lease == generation { lastRefreshFailed = true }
            throw error
        }
    }
    func stop() async {
        generation &+= 1; maintenance?.cancel(); maintenance = nil
        let previous = verifier; verifier = nil; expiresAt = nil; lastRefreshFailed = false
        await previous?.invalidateTrust()
    }
    private func refreshDelay() -> TimeInterval {
        if lastRefreshFailed { return 15 }
        return max(1, min(lifetime / 2, (expiresAt?.timeIntervalSince(clock()) ?? 30) / 2))
    }
    private func cacheLifetime(_ reply: DesktopCloudReply) throws -> TimeInterval {
        let headers = Dictionary(reply.headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, _ in "invalid" })
        let ageText = headers["age"] ?? "0"
        guard ageText.range(of: "^[0-9]{1,8}$", options: .regularExpression) != nil,
              let age = TimeInterval(ageText) else { throw DesktopCloudError.invalidResponse }
        let directives = (headers["cache-control"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let maximums = directives.filter { $0.hasPrefix("max-age=") }
        guard maximums.count <= 1 else { throw DesktopCloudError.invalidResponse }
        var ttl = lifetime
        if let maximum = maximums.first {
            let value = String(maximum.dropFirst(8))
            guard value.range(of: "^[0-9]{1,8}$", options: .regularExpression) != nil,
                  let duration = TimeInterval(value) else { throw DesktopCloudError.invalidResponse }
            ttl = min(ttl, duration)
        }
        guard ttl > age else { throw DesktopCloudError.invalidResponse }; return ttl - age
    }
}
