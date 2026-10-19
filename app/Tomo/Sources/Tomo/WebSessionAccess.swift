import Foundation
import CryptoKit

/// Owner-approved, origin-bound web access to this Mac's sessions.
///
/// A page on this Mac asks to connect, the owner compares a short code on the
/// desktop and approves it, and the page receives development credentials that
/// last five minutes. It renews them with a secret only it holds, for at most
/// one hour. Nothing is reachable while the owner's switch is off, and every
/// credential dies with its window, an owner disconnect or the switch.
actor WebSessionAccess {
    struct Limits: Sendable {
        var requestLifetime: TimeInterval = 120
        var windowLifetime: TimeInterval = 3600
        var credentialLifetime: TimeInterval = 300
        var maxWaitingRequests = 3
        var maxWindows = 4
        var maxRequestsPerMinute = 10
    }
    enum AccessError: Error, Equatable {
        case disabled, originNotAllowed, tooManyRequests, notFound, unauthorized, unavailable, invalidRequest
    }

    struct PendingRequest: Sendable, Equatable {
        let id: UUID
        let origin: String
        let code: String
        let expiresAt: Date
    }
    struct WindowInfo: Sendable, Equatable {
        let id: UUID
        let origin: String
        let expiresAt: Date
    }
    struct Credential: Sendable, Equatable {
        let token: String
        let expiresAt: Date
        let windowExpiresAt: Date
        /// False when the granted scopes only list and read sessions.
        let controls: Bool
    }
    enum Poll: Sendable, Equatable {
        case pending, denied, expired
        case approved(Credential, renewal: String)
    }

    private enum Outcome {
        case waiting, denied, failed
        /// `renewal` is delivered once, with the first credential.
        case approved(window: UUID, renewal: String?)
    }
    private struct Request {
        let id: UUID
        let origin: String
        let code: String
        let createdAt: Date
        let expiresAt: Date
        var outcome: Outcome = .waiting
    }
    private struct Window {
        let id: UUID
        let origin: String
        var expiresAt: Date
        let renewalDigest: String
        var principals: [RemoteAccessStore.Principal] = []
    }

    private let access: RemoteAccessStore
    private let scopes: @Sendable () async throws -> [RemoteAccessStore.Scope]
    private let prepare: @Sendable () async throws -> Void
    private let teardown: @Sendable () async -> Void
    private let now: @Sendable () -> Date
    private let limits: Limits
    private var changed: (@Sendable () -> Void)?
    private var enabled = false
    private var requests: [UUID: Request] = [:]
    private var windows: [UUID: Window] = [:]
    private var requestTimes: [Date] = []
    private var developmentOn = false
    private var starting: Task<Void, Error>?

    init(access: RemoteAccessStore,
         scopes: @escaping @Sendable () async throws -> [RemoteAccessStore.Scope],
         prepare: @escaping @Sendable () async throws -> Void = {},
         teardown: @escaping @Sendable () async -> Void = {},
         now: @escaping @Sendable () -> Date = { Date() },
         limits: Limits = Limits()) {
        self.access = access; self.scopes = scopes; self.prepare = prepare; self.teardown = teardown
        self.now = now; self.limits = limits
    }

    /// Called after any change a window or request list shows.
    func setChangeHandler(_ handler: (@Sendable () -> Void)?) { changed = handler }
    var isEnabled: Bool { enabled }

    /// Only the local owner's switch calls this. Turning it off revokes everything.
    func setEnabled(_ value: Bool) async {
        guard enabled != value else { return }
        enabled = value
        if !value { await endEverything() }
        changed?()
    }

    /// Only loopback pages are ever offered to the owner: a site on the internet
    /// cannot have one of these origins, so it cannot even make the desktop ask.
    static func isAllowedOrigin(_ value: String) -> Bool {
        guard let parts = URLComponents(string: value), parts.scheme == "http",
              let host = parts.host?.lowercased(), ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty, parts.url?.absoluteString == value else { return false }
        if let port = parts.port, !(1...65535).contains(port) { return false }
        return true
    }

    // MARK: Page side

    /// A page asking again while its earlier request is still unanswered gets the
    /// same request back, so the code stays the one the owner is looking at.
    func request(origin: String) async throws -> PendingRequest {
        guard enabled else { throw AccessError.disabled }
        guard Self.isAllowedOrigin(origin) else { throw AccessError.originNotAllowed }
        let current = now()
        await sweep(current)
        if let existing = requests.values.first(where: { $0.origin == origin && $0.expiresAt > current && isWaiting($0) }) {
            return Self.pending(existing)
        }
        requestTimes = requestTimes.filter { current.timeIntervalSince($0) < 60 }
        guard requestTimes.count < limits.maxRequestsPerMinute,
              requests.values.filter({ $0.expiresAt > current && isWaiting($0) }).count < limits.maxWaitingRequests else {
            throw AccessError.tooManyRequests
        }
        let item = Request(id: UUID(), origin: origin, code: Self.randomCode(), createdAt: current,
                           expiresAt: current.addingTimeInterval(limits.requestLifetime))
        requests[item.id] = item
        requestTimes.append(current)
        changed?()
        return Self.pending(item)
    }

    func poll(id: UUID, origin: String) async throws -> Poll {
        guard enabled else { throw AccessError.disabled }
        let current = now()
        await sweep(current)
        guard let item = requests[id], item.origin == origin else { throw AccessError.notFound }
        switch item.outcome {
        case .waiting: return item.expiresAt > current ? .pending : .expired
        case .denied: return .denied
        case .failed: throw AccessError.unavailable
        case .approved(let windowId, let renewal):
            guard let renewal, windows[windowId] != nil else { throw AccessError.notFound }
            // Mark delivered before any suspension, so only one poll gets the secret.
            requests[id]?.outcome = .approved(window: windowId, renewal: nil)
            do { return .approved(try await issue(windowId: windowId), renewal: renewal) }
            catch {
                await endWindow(windowId)
                throw error
            }
        }
    }

    func renew(renewal: String, origin: String) async throws -> Credential {
        guard enabled else { throw AccessError.disabled }
        await sweep(now())
        let digest = Self.digest(renewal)
        guard let window = windows.values.first(where: { $0.renewalDigest == digest && $0.origin == origin }) else {
            throw AccessError.unauthorized
        }
        return try await issue(windowId: window.id)
    }

    /// The page's own disconnect.
    func revoke(renewal: String, origin: String) async throws {
        guard enabled else { throw AccessError.disabled }
        let digest = Self.digest(renewal)
        guard let window = windows.values.first(where: { $0.renewalDigest == digest && $0.origin == origin }) else {
            throw AccessError.unauthorized
        }
        await endWindow(window.id)
    }

    // MARK: Owner side

    func pendingRequests() async -> [PendingRequest] {
        let current = now()
        await sweep(current)
        return requests.values.filter { $0.expiresAt > current && isWaiting($0) }
            .sorted { $0.createdAt < $1.createdAt }.map(Self.pending)
    }

    func activeWindows() async -> [WindowInfo] {
        await sweep(now())
        return windows.values.sorted { $0.expiresAt < $1.expiresAt }
            .map { WindowInfo(id: $0.id, origin: $0.origin, expiresAt: $0.expiresAt) }
    }

    /// A window the owner leaves open without an end ends only when the owner, the switch or a restart ends it.
    static let permanent = TimeInterval.infinity

    /// Moves a window's end from now, e.g. to renew it or make it permanent.
    func extend(windowId: UUID, duration: TimeInterval) async {
        guard enabled, var window = windows[windowId], window.expiresAt > now(), duration > 0 else { return }
        window.expiresAt = Self.end(from: now(), duration)
        windows[windowId] = window
        changed?()
    }

    private static func end(from start: Date, _ duration: TimeInterval) -> Date {
        duration.isFinite ? start.addingTimeInterval(duration) : .distantFuture
    }

    func decide(id: UUID, allow: Bool, duration: TimeInterval? = nil) async {
        let current = now()
        await sweep(current)
        guard enabled, let item = requests[id], isWaiting(item), item.expiresAt > current else { return }
        guard allow else {
            requests[id]?.outcome = .denied
            changed?()
            return
        }
        do {
            guard windows.count < limits.maxWindows else { throw AccessError.tooManyRequests }
            try await beginDevelopmentIfNeeded()
            // The switch can flip, or the request lapse, while preparing.
            guard enabled, let latest = requests[id], isWaiting(latest), latest.expiresAt > now() else {
                await endDevelopmentIfIdle()
                return
            }
            let renewal = Self.randomSecret(prefix: "tomo_web_renew_")
            let window = Window(id: UUID(), origin: item.origin, expiresAt: Self.end(from: now(), duration ?? limits.windowLifetime),
                                renewalDigest: Self.digest(renewal))
            windows[window.id] = window
            requests[id]?.outcome = .approved(window: window.id, renewal: renewal)
        } catch {
            requests[id]?.outcome = .failed
            await endDevelopmentIfIdle()
        }
        changed?()
    }

    func disconnect(windowId: UUID) async { await endWindow(windowId) }

    /// Ends what is due; the owner-side timer calls this.
    func tick() async { await sweep(now()) }

    // MARK: Internals

    private func isWaiting(_ request: Request) -> Bool {
        if case .waiting = request.outcome { return true }
        return false
    }

    private func issue(windowId: UUID) async throws -> Credential {
        let current = now()
        guard let window = windows[windowId], window.expiresAt > current, developmentOn else { throw AccessError.unauthorized }
        let granted = try await scopes()
        guard !granted.isEmpty else { throw AccessError.unavailable }
        guard windows[windowId] != nil, developmentOn else { throw AccessError.unauthorized }
        let lifetime = min(limits.credentialLifetime, window.expiresAt.timeIntervalSince(current))
        guard lifetime >= 1 else { throw AccessError.unauthorized }
        let issued: RemoteAccessStore.Issued
        do { issued = try await access.issueDevelopment(scopes: granted, origin: window.origin, lifetime: lifetime, now: current) }
        catch { throw AccessError.unavailable }
        guard var latest = windows[windowId] else {
            await access.revoke(issued.principal)
            throw AccessError.unauthorized
        }
        latest.principals = Array((latest.principals + [issued.principal]).suffix(4))
        windows[windowId] = latest
        let controls = granted.contains { !$0.actions.isDisjoint(with: [.sendMessage, .interrupt]) }
        return Credential(token: issued.token, expiresAt: issued.principal.expiresAt, windowExpiresAt: latest.expiresAt,
                          controls: controls)
    }

    private func beginDevelopmentIfNeeded() async throws {
        if developmentOn { return }
        if let starting { return try await starting.value }
        let task = Task { [prepare, access] in
            try await prepare()
            await access.setDevelopmentEnabled(true)
        }
        starting = task
        do { try await task.value } catch { starting = nil; throw error }
        starting = nil
        developmentOn = true
    }

    private func endDevelopmentIfIdle() async {
        guard developmentOn, windows.isEmpty, starting == nil else { return }
        developmentOn = false
        // Also discards every credential still held by a page.
        await access.setDevelopmentEnabled(false)
        await teardown()
    }

    private func endWindow(_ id: UUID) async {
        guard let window = windows.removeValue(forKey: id) else { return }
        for principal in window.principals { await access.revoke(principal) }
        await endDevelopmentIfIdle()
        changed?()
    }

    private func endEverything() async {
        for id in Array(windows.keys) {
            guard let window = windows.removeValue(forKey: id) else { continue }
            for principal in window.principals { await access.revoke(principal) }
        }
        for id in Array(requests.keys) {
            if let item = requests[id], isWaiting(item) { requests[id]?.outcome = .denied }
        }
        await endDevelopmentIfIdle()
    }

    private func sweep(_ current: Date) async {
        let due = windows.values.filter { $0.expiresAt <= current }.map(\.id)
        for id in due { await endWindow(id) }
        // An answered or lapsed request is kept briefly so a late poll gets a clear answer.
        requests = requests.filter { current.timeIntervalSince($0.value.expiresAt) < 300 }
    }

    private static func pending(_ request: Request) -> PendingRequest {
        .init(id: request.id, origin: request.origin, code: request.code, expiresAt: request.expiresAt)
    }
    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    /// A four-digit code both screens show; it only has to tell requests apart.
    static func randomCode() -> String {
        String(format: "%04d", Int.random(in: 0...9999))
    }
    private static func randomSecret(prefix: String) -> String {
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        return prefix + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The real session sources a web page may read, registered only while some
/// window is open and removed with the last one.
actor WebSessionSources {
    /// Approving and answering requests stays on the desktop.
    static let allowedActions: Set<RemoteAction> = [.listSessions, .readHistory, .sendMessage, .interrupt]

    private struct Registered { let agentId: String; let runtimeId: String; let actions: Set<RemoteAction> }
    private let reads: RemoteReadService
    private let load: @Sendable () async throws -> [any RemoteReadAdapter]
    private var registered: [Registered] = []

    init(reads: RemoteReadService, load: @escaping @Sendable () async throws -> [any RemoteReadAdapter]) {
        self.reads = reads; self.load = load
    }

    func prepare() async throws {
        guard registered.isEmpty else { return }
        let adapters = try await load()
        guard !adapters.isEmpty else { throw RemoteAccessError.unavailable }
        var done: [Registered] = []
        do {
            for adapter in adapters {
                try await reads.register(adapter)
                done.append(.init(agentId: adapter.descriptor.agentId, runtimeId: adapter.runtimeId, actions: adapter.runtimeActions))
            }
        } catch {
            for item in done { await reads.unregister(agentId: item.agentId, runtimeId: item.runtimeId) }
            throw error
        }
        registered = done
    }

    func scopes() -> [RemoteAccessStore.Scope] {
        registered.compactMap { item in
            let actions = item.actions.intersection(Self.allowedActions)
            return actions.isEmpty ? nil : .init(agentId: item.agentId, runtimeId: item.runtimeId, sessionId: nil, actions: actions)
        }
    }

    func teardown() async {
        let items = registered
        registered = []
        for item in items { await reads.unregister(agentId: item.agentId, runtimeId: item.runtimeId) }
    }
}
