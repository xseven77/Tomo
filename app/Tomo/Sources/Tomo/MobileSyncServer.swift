import Foundation
import Network

// MARK: - Mobile Sync Data Models

public struct MobileTaskPayload: Codable, Equatable, Sendable {
    public let id: String
    public let state: String
    public let title: String
    public let agent: String
    public let detail: String?
    public let model: String?
    public let workspaceName: String?
    public let gitBranch: String?

    public init(
        id: String,
        state: String,
        title: String,
        agent: String,
        detail: String? = nil,
        model: String? = nil,
        workspaceName: String? = nil,
        gitBranch: String? = nil
    ) {
        self.id = id
        self.state = state
        self.title = title
        self.agent = agent
        self.detail = detail
        self.model = model
        self.workspaceName = workspaceName
        self.gitBranch = gitBranch
    }
}

public struct MobileActivityPayload: Codable, Equatable, Sendable {
    public let state: String
    public let activeTaskCount: Int
    public let activeTasks: [MobileTaskPayload]

    public init(state: String, activeTaskCount: Int, activeTasks: [MobileTaskPayload]) {
        self.state = state
        self.activeTaskCount = activeTaskCount
        self.activeTasks = activeTasks
    }
}

public struct MobileResetCouponPayload: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let description: String?
    public let source: String?
    public let grantedAt: String?
    public let expiresAt: String
    public let status: String?
    public let resetType: String?
    /// Avatar of the account that granted the coupon. Without this the client
    /// can only draw a generic placeholder, which is what the mobile web used to
    /// do while the desktop showed the real Codex avatar.
    public let profileImageURL: String?
    /// Preferred display name (`Codex Team`); `source` is only the fallback.
    public let profileUserID: String?

    public init(
        id: String,
        title: String,
        description: String? = nil,
        source: String? = nil,
        grantedAt: String? = nil,
        expiresAt: String,
        status: String? = nil,
        resetType: String? = nil,
        profileImageURL: String? = nil,
        profileUserID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.source = source
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.status = status
        self.resetType = resetType
        self.profileImageURL = profileImageURL
        self.profileUserID = profileUserID
    }
}

public struct MobileConnectionPayload: Codable, Equatable, Sendable {
    public let id: String
    public let provider: String
    public let label: String
    public let isHealthy: Bool
    public let shortWindowRemaining: Double?
    public let weeklyRemaining: Double?
    public let balance: String?
    public let accountName: String?
    public let email: String?
    public let planName: String?
    public let shortWindowLabel: String?
    public let shortWindowResetAt: String?
    public let weeklyWindowLabel: String?
    public let weeklyWindowResetAt: String?
    public let claudeGptFiveHourRemaining: Double?
    public let claudeGptWeeklyRemaining: Double?
    public let subscriptionActiveUntilISO: String?
    public let subscriptionWillRenew: Bool?
    public let subscriptionDaysRemaining: Int?
    public let subscriptionReminderMessage: String?
    public let subscriptionRenewalLine: String?
    public let resetCoupons: [MobileResetCouponPayload]?
    public let keySuffix: String?
    public let statusColor: String?
    public let toppedUp: String?
    public let granted: String?
    public let availableModelCount: Int?
    public let availableModelIDs: [String]?
    public let lastValidatedAt: String?

    public init(
        id: String,
        provider: String,
        label: String,
        isHealthy: Bool,
        shortWindowRemaining: Double? = nil,
        weeklyRemaining: Double? = nil,
        balance: String? = nil,
        accountName: String? = nil,
        email: String? = nil,
        planName: String? = nil,
        shortWindowLabel: String? = nil,
        shortWindowResetAt: String? = nil,
        weeklyWindowLabel: String? = nil,
        weeklyWindowResetAt: String? = nil,
        claudeGptFiveHourRemaining: Double? = nil,
        claudeGptWeeklyRemaining: Double? = nil,
        subscriptionActiveUntilISO: String? = nil,
        subscriptionWillRenew: Bool? = nil,
        subscriptionDaysRemaining: Int? = nil,
        subscriptionReminderMessage: String? = nil,
        subscriptionRenewalLine: String? = nil,
        resetCoupons: [MobileResetCouponPayload]? = nil,
        keySuffix: String? = nil,
        statusColor: String? = nil,
        toppedUp: String? = nil,
        granted: String? = nil,
        availableModelCount: Int? = nil,
        availableModelIDs: [String]? = nil,
        lastValidatedAt: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.isHealthy = isHealthy
        self.shortWindowRemaining = shortWindowRemaining
        self.weeklyRemaining = weeklyRemaining
        self.balance = balance
        self.accountName = accountName
        self.email = email
        self.planName = planName
        self.shortWindowLabel = shortWindowLabel
        self.shortWindowResetAt = shortWindowResetAt
        self.weeklyWindowLabel = weeklyWindowLabel
        self.weeklyWindowResetAt = weeklyWindowResetAt
        self.claudeGptFiveHourRemaining = claudeGptFiveHourRemaining
        self.claudeGptWeeklyRemaining = claudeGptWeeklyRemaining
        self.subscriptionActiveUntilISO = subscriptionActiveUntilISO
        self.subscriptionWillRenew = subscriptionWillRenew
        self.subscriptionDaysRemaining = subscriptionDaysRemaining
        self.subscriptionReminderMessage = subscriptionReminderMessage
        self.subscriptionRenewalLine = subscriptionRenewalLine
        self.resetCoupons = resetCoupons
        self.keySuffix = keySuffix
        self.statusColor = statusColor
        self.toppedUp = toppedUp
        self.granted = granted
        self.availableModelCount = availableModelCount
        self.availableModelIDs = availableModelIDs
        self.lastValidatedAt = lastValidatedAt
    }
}

public struct MobileSnapshotPayload: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let activePetId: String
    public let todayMinutes: Int
    public let activity: MobileActivityPayload
    public let connections: [MobileConnectionPayload]

    public init(
        schemaVersion: Int = 1,
        generatedAt: Date = Date(),
        activePetId: String,
        todayMinutes: Int = 0,
        activity: MobileActivityPayload,
        connections: [MobileConnectionPayload]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.activePetId = activePetId
        self.todayMinutes = todayMinutes
        self.activity = activity
        self.connections = connections
    }
}

public struct MobilePetMetadata: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let description: String
    public let frameWidth: Int
    public let frameHeight: Int
    public let totalRows: Int
    public let totalColumns: Int
    public let actionRowMap: [String: Int]

    public init(
        id: String,
        displayName: String,
        description: String,
        frameWidth: Int = 192,
        frameHeight: Int = 208,
        totalRows: Int = 11,
        totalColumns: Int = 8,
        actionRowMap: [String: Int] = [
            "idle": 0,
            "waving": 3,
            "jumping": 4,
            "failed": 5,
            "waiting": 6,
            "running": 7,
            "review": 8
        ]
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.totalRows = totalRows
        self.totalColumns = totalColumns
        self.actionRowMap = actionRowMap
    }
}

// MARK: - Mobile Credentials Export Payload

public struct MobileCredentialAccountPayload: Codable, Equatable, Sendable {
    public let id: String
    public let provider: String
    public let label: String
    public let tokenOrKey: String

    public init(id: String, provider: String, label: String, tokenOrKey: String) {
        self.id = id
        self.provider = provider
        self.label = label
        self.tokenOrKey = tokenOrKey
    }
}

public struct MobileCredentialsExportPayload: Codable, Equatable, Sendable {
    public let exportedAt: Date
    public let accounts: [MobileCredentialAccountPayload]

    public init(exportedAt: Date = Date(), accounts: [MobileCredentialAccountPayload]) {
        self.exportedAt = exportedAt
        self.accounts = accounts
    }
}

// MARK: - Mobile Sync Data Provider

public protocol MobileSyncDataProvider: AnyObject, Sendable {
    func makeSnapshot() async -> MobileSnapshotPayload
    func availablePets() -> [MobilePetMetadata]
    func exportCredentials() async -> MobileCredentialsExportPayload
}

// MARK: - Mobile Sync Server

public final class MobileSyncServer: @unchecked Sendable {
    public static let defaultPort: UInt16 = 58350

    public static var defaultPluginDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tomo/Plugins/mobile-web")
    }

    public let port: NWEndpoint.Port
    public let token: String
    public let pluginDirectoryURL: URL
    private let dataProvider: any MobileSyncDataProvider
    private let queue = DispatchQueue(label: "com.qiizo.tomo.mobile-sync", qos: .userInitiated)

    private var listener: NWListener?
    private var isRunning = false
    private let lock = NSLock()
    private var sseClients: [UUID: NWConnection] = [:]
    private var sseRelays: [UUID: Task<Void, Never>] = [:]
    private var heartbeatTimer: DispatchSourceTimer?
    /// Set by an intentional `stop()` so a scheduled rebind cannot resurrect a
    /// server the app asked to shut down.
    private var isShuttingDown = false
    private var rebindAttempt = 0
    private static let maxRebindAttempts = 6

    public init(
        port: UInt16 = MobileSyncServer.defaultPort,
        token: String,
        pluginDirectoryURL: URL = MobileSyncServer.defaultPluginDirectoryURL,
        dataProvider: any MobileSyncDataProvider
    ) {
        self.port = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(rawValue: 58350)!
        self.token = token
        self.pluginDirectoryURL = pluginDirectoryURL
        self.dataProvider = dataProvider
    }

    public enum Status: Equatable, Sendable {
        case idle
        case starting
        case ready
        case failed(String)
    }

    /// Observed by the manager so the UI reflects reality instead of an assumption.
    public var onStatusChange: (@Sendable (Status) -> Void)?

    public private(set) var status: Status = .idle {
        didSet { onStatusChange?(status) }
    }

    /// True while a backoff rebind is pending, so the UI can say "retrying"
    /// instead of just "failed".
    public private(set) var isAwaitingRetry = false

    /// Starts the listener.
    ///
    /// Note that `NWListener` binds **asynchronously**: `start(queue:)` only
    /// schedules the bind, and a busy port is reported later through
    /// `stateUpdateHandler` as `.failed` — not as a thrown error. Treating a
    /// non-throwing return as success is what previously let the server die
    /// silently (no status, no error, no retry) after a `restart()` raced with
    /// the cancellation of the previous listener.
    public func start() throws {
        lock.lock()
        isShuttingDown = false
        guard listener == nil else {
            lock.unlock()
            return
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: port)
        self.listener = listener
        status = .starting
        lock.unlock()

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        // `weak listener` keeps a stale listener's late state transitions from
        // clobbering the state of the one that replaced it.
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            self.lock.lock()
            let isCurrent = self.listener === listener
            self.lock.unlock()
            guard isCurrent else { return }
            self.handleListenerState(state)
        }

        listener.start(queue: queue)
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            lock.lock()
            isRunning = true
            rebindAttempt = 0
            isAwaitingRetry = false
            status = .ready
            lock.unlock()

        case .failed(let error):
            lock.lock()
            listener?.cancel()
            listener = nil
            isRunning = false
            let attempt = rebindAttempt
            rebindAttempt += 1
            status = .failed(Self.describe(error))
            isAwaitingRetry = attempt < Self.maxRebindAttempts
            lock.unlock()
            scheduleRebind(afterAttempt: attempt)

        case .cancelled:
            lock.lock()
            isRunning = false
            if case .ready = status { status = .idle }
            lock.unlock()

        default:
            break
        }
    }

    /// Bounded exponential backoff so a transient port conflict self-heals.
    private func scheduleRebind(afterAttempt attempt: Int) {
        guard attempt < Self.maxRebindAttempts else { return }
        let delay = min(pow(2.0, Double(attempt)), 8.0)

        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let shuttingDown = self.isShuttingDown
            let alreadyListening = self.listener != nil
            self.lock.unlock()
            guard !shuttingDown, !alreadyListening else { return }
            try? self.start()
        }
    }

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            if code == .EADDRINUSE { return "端口 \(code) 已被占用" }
            return "网络错误 \(code.rawValue)"
        default:
            return "\(error)"
        }
    }

    public func stop() {
        lock.lock()
        isShuttingDown = true
        isRunning = false
        rebindAttempt = 0
        isAwaitingRetry = false

        let clients = Array(sseClients.values)
        sseClients.removeAll()
        let relays = Array(sseRelays.values)
        sseRelays.removeAll()
        heartbeatTimer?.cancel()
        heartbeatTimer = nil

        listener?.cancel()
        listener = nil
        status = .idle
        lock.unlock()

        for connection in clients {
            connection.cancel()
        }
        for relay in relays { relay.cancel() }
    }

    public func broadcast(event: String, data: String) {
        lock.lock()
        let clients = Array(sseClients.values)
        lock.unlock()

        guard !clients.isEmpty else { return }
        let payload = "event: \(event)\ndata: \(data)\n\n"
        guard let rawData = payload.data(using: .utf8) else { return }

        for client in clients {
            client.send(content: rawData, completion: .contentProcessed({ _ in }))
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection)
    }

    private func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }
            guard let data, let requestText = String(data: data, encoding: .utf8) else {
                if isComplete { connection.cancel() }
                return
            }

            self.processRequest(requestText, on: connection)
        }
    }

    /// Optional, untrusted attribution for future request statistics. Never an auth identity.
    public static func normalizedAppName(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(128))
    }

    public struct APIRequestMetadata: Sendable {
        public let method: String
        public let path: String
        public let appName: String?
    }

    /// Called after authentication. Metadata excludes query strings, tokens and bodies.
    public var onAPIRequest: (@Sendable (APIRequestMetadata) -> Void)?

    private func processRequest(_ requestText: String, on connection: NWConnection) {
        let lines = requestText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            sendResponse(status: 400, headers: [:], body: "Bad Request", on: connection)
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendResponse(status: 400, headers: [:], body: "Bad Request", on: connection)
            return
        }

        let method = String(parts[0])
        let rawPath = String(parts[1])

        // Parse path and query parameters
        let pathComponents = rawPath.components(separatedBy: "?")
        let requestPath = pathComponents[0]
        let queryParams = parseQuery(pathComponents.count > 1 ? pathComponents[1] : nil)

        var headers: [String: String] = [:]
        var bodyStartIndex = lines.count
        for (idx, line) in lines.enumerated().dropFirst() {
            if line.isEmpty {
                bodyStartIndex = idx + 1
                break
            }
            let headerParts = line.split(separator: ":", maxSplits: 1)
            if headerParts.count == 2 {
                let name = headerParts[0].trimmingCharacters(in: .whitespaces).lowercased()
                let value = headerParts[1].trimmingCharacters(in: .whitespaces)
                headers[name] = value
            }
        }
        let requestBody = lines.dropFirst(bodyStartIndex).joined(separator: "\r\n")

        // 0. Handle CORS preflight
        if method == "OPTIONS" {
            sendResponse(status: 204, headers: [
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Headers": "Authorization, Content-Type, Accept, X-Tomo-App-Name, X-Target-Authorization, ChatGPT-Account-Id",
                "Access-Control-Allow-Methods": "GET, POST, OPTIONS"
            ], body: "", on: connection)
            return
        }

        // 1. Public health check
        if requestPath == "/health" {
            let deviceName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
            sendJSONResponse(status: 200, object: [
                "status": "ok",
                "service": "tomo",
                "name": deviceName,
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.8.9"
            ], on: connection)
            return
        }

        // Removed API namespace: no alias, redirect or static-file fallback.
        if requestPath == "/mobile" || requestPath.hasPrefix("/mobile/") {
            sendJSONResponse(status: 410, object: ["error": "api_removed", "message": "旧版 Web Mobile 已失效，请更新客户端并使用 /api/v1/"] , on: connection)
            return
        }

        // 2. Public desktop API endpoints (Bearer Token or Query Token)
        if requestPath.hasPrefix("/api/v1/") {
            guard validateAuth(headers: headers, queryParams: queryParams) else {
                sendJSONResponse(status: 401, object: ["error": "unauthorized"], on: connection)
                return
            }

            // Dynamic serving of pet spritesheets
            let appName = Self.normalizedAppName(headers["x-tomo-app-name"] ?? queryParams["app_name"])
            onAPIRequest?(APIRequestMetadata(method: method, path: requestPath, appName: appName))

            if requestPath.hasPrefix("/api/v1/pets/") && requestPath.hasSuffix("/spritesheet.webp") {
                let petSub = String(requestPath.dropFirst("/api/v1/pets/".count).dropLast("/spritesheet.webp".count))
                let cleanSub = (petSub.removingPercentEncoding ?? petSub)
                    .replacingOccurrences(of: "^(custom|builtin):", with: "", options: .regularExpression)
                // Look in Application Support/Tomo/Pets/<cleanSub>/spritesheet.webp
                let customURL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/Tomo/Pets")
                    .appendingPathComponent(cleanSub)
                    .appendingPathComponent("spritesheet.webp")
                if FileManager.default.fileExists(atPath: customURL.path),
                   let data = try? Data(contentsOf: customURL) {
                    sendRawResponse(
                        status: 200,
                        headers: [
                            "Content-Type": "image/webp",
                            "Cache-Control": "public, max-age=604800, immutable"
                        ],
                        data: data,
                        on: connection
                    )
                    return
                }
                // Fallback to plugin pets
                let pluginURL = pluginDirectoryURL.appendingPathComponent("pets").appendingPathComponent(cleanSub).appendingPathComponent("spritesheet.webp")
                if FileManager.default.fileExists(atPath: pluginURL.path),
                   let data = try? Data(contentsOf: pluginURL) {
                    sendRawResponse(
                        status: 200,
                        headers: [
                            "Content-Type": "image/webp",
                            "Cache-Control": "public, max-age=604800, immutable"
                        ],
                        data: data,
                        on: connection
                    )
                    return
                }
            }

            switch (method, requestPath) {
            case ("GET", "/api/v1/agents/discover"):
                Task {
                    let discovered = await self.discoverLANAgents(subnetOverride: queryParams["subnet"])
                    self.sendJSONResponse(status: 200, object: ["devices": discovered], on: connection)
                }
            case ("GET", "/api/v1/agents/pet"):
                guard let target = queryParams["target"], let targetURL = URL(string: target),
                      ["http", "https"].contains(targetURL.scheme?.lowercased() ?? ""),
                      targetURL.host != nil, targetURL.user == nil, targetURL.password == nil,
                      targetURL.path.hasPrefix("/api/v1/pets/") && targetURL.path.hasSuffix("/spritesheet.webp") else {
                    sendJSONResponse(status: 400, object: ["error": "invalid_agent_pet_target"], on: connection)
                    return
                }
                let targetToken = queryParams["target_token"] ?? (headers["x-target-authorization"]?.hasPrefix("Bearer ") == true ? String(headers["x-target-authorization"]!.dropFirst("Bearer ".count)) : nil)
                guard let targetToken, !targetToken.isEmpty else {
                    sendJSONResponse(status: 400, object: ["error": "missing_target_token"], on: connection)
                    return
                }
                Task {
                    var req = URLRequest(url: targetURL)
                    req.httpMethod = "GET"
                    req.timeoutInterval = 15
                    req.setValue("Bearer \(targetToken)", forHTTPHeaderField: "Authorization")
                    if let appName { req.setValue(appName, forHTTPHeaderField: "X-Tomo-App-Name") }
                    do {
                        let session = URLSession.tomoRelay(for: targetURL)
                        let (data, response) = try await session.data(for: req)
                        let httpResponse = response as? HTTPURLResponse
                        let statusCode = httpResponse?.statusCode ?? 200
                        if statusCode == 200 {
                            let contentType = httpResponse?.value(forHTTPHeaderField: "Content-Type") ?? "image/webp"
                            self.sendRawResponse(
                                status: 200,
                                headers: [
                                    "Content-Type": contentType,
                                    "Cache-Control": "public, max-age=604800, immutable"
                                ],
                                data: data,
                                on: connection
                            )
                        } else {
                            self.sendResponse(status: statusCode, headers: [:], body: "Upstream returned \(statusCode)", on: connection)
                        }
                    } catch {
                        self.sendJSONResponse(status: 502, object: ["error": "upstream_unavailable", "message": error.localizedDescription], on: connection)
                    }
                }
            case ("GET", "/api/v1/agents/events"):
                guard let target = queryParams["target"], let targetURL = URL(string: target),
                      ["http", "https"].contains(targetURL.scheme?.lowercased() ?? ""),
                      targetURL.host != nil, targetURL.user == nil, targetURL.password == nil,
                      targetURL.query == nil, targetURL.fragment == nil,
                      targetURL.path.hasSuffix("/api/v1/events"),
                      let targetToken = queryParams["target_token"], !targetToken.isEmpty else {
                    sendJSONResponse(status: 400, object: ["error": "invalid_agent_stream"], on: connection)
                    return
                }
                startSSERelay(target: targetURL, token: targetToken, appName: appName, on: connection)
            case ("GET", "/api/v1/agents/snapshot"), ("GET", "/api/v1/proxy"), ("POST", "/api/v1/proxy"):
                guard let targetStr = queryParams["target"], let targetURL = URL(string: targetStr) else {
                    sendResponse(status: 400, headers: [:], body: "Missing target parameter", on: connection)
                    return
                }
                if requestPath == "/api/v1/agents/snapshot" {
                    guard ["http", "https"].contains(targetURL.scheme?.lowercased() ?? ""),
                          targetURL.host != nil, targetURL.user == nil, targetURL.password == nil,
                          targetURL.query == nil, targetURL.fragment == nil,
                          targetURL.path.hasSuffix("/api/v1/snapshot"),
                          headers["x-target-authorization"]?.hasPrefix("Bearer ") == true else {
                        sendJSONResponse(status: 400, object: ["error": "invalid_agent_snapshot"], on: connection)
                        return
                    }
                } else {
                    guard ProviderProxyPolicy.allows(targetURL, method: method) else {
                        sendJSONResponse(status: 400, object: ["error": "unsupported_provider_request"], on: connection)
                        return
                    }
                    guard let authorization = headers["x-target-authorization"], !authorization.isEmpty else {
                        sendJSONResponse(status: 400, object: ["error": "missing_provider_authorization"], on: connection)
                        return
                    }
                }
                Task {
                    var req = URLRequest(url: targetURL)
                    req.httpMethod = method
                    req.timeoutInterval = 30
                    if !requestBody.isEmpty, let bodyData = requestBody.data(using: .utf8) {
                        req.httpBody = bodyData
                    }
                    if let auth = headers["x-target-authorization"] {
                        req.setValue(auth, forHTTPHeaderField: "Authorization")
                    }
                    if let ct = headers["content-type"] {
                        req.setValue(ct, forHTTPHeaderField: "Content-Type")
                    } else if method == "POST" {
                        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    }
                    req.setValue("application/json", forHTTPHeaderField: "Accept")
                    if let appName { req.setValue(appName, forHTTPHeaderField: "X-Tomo-App-Name") }

                    // Domain-specific headers for OpenAI and Google Cloud Code
                    let host = targetURL.host?.lowercased() ?? ""
                    if host.contains("chatgpt.com") {
                        req.setValue("Tomo/0.1", forHTTPHeaderField: "User-Agent")
                        req.setValue("https://chatgpt.com/", forHTTPHeaderField: "Origin")
                        req.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
                        if targetURL.path.contains("/wham/") {
                            req.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
                            req.setValue("Codex Desktop", forHTTPHeaderField: "originator")
                        }
                        if let accountID = headers["chatgpt-account-id"] ?? queryParams["account_id"] {
                            req.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
                        }
                    } else if host.contains("googleapis.com") {
                        req.setValue("antigravity", forHTTPHeaderField: "User-Agent")
                        req.setValue(#"{"ideType":"ANTIGRAVITY"}"#, forHTTPHeaderField: "Client-Metadata")
                    } else {
                        req.setValue("TomoGo/1.0", forHTTPHeaderField: "User-Agent")
                    }

                    do {
                        let isAgent = requestPath == "/api/v1/agents/snapshot"
                        let providerSession = isAgent ? nil : URLSession(
                            configuration: URLSession.tomoExternal.configuration,
                            delegate: ProviderProxyRedirectDelegate(), delegateQueue: nil)
                        defer { providerSession?.finishTasksAndInvalidate() }
                        let session = providerSession ?? URLSession.tomoRelay(for: targetURL)
                        let (data, response) = try await session.data(for: req)
                        let httpResponse = response as? HTTPURLResponse
                        let statusCode = httpResponse?.statusCode ?? 200
                        let responseText = String(data: data, encoding: .utf8) ?? "{}"
                        self.sendResponse(status: statusCode, headers: ["Content-Type": "application/json"], body: responseText, on: connection)
                    } catch {
                        let code = (error as NSError).code
                        self.sendJSONResponse(status: 502, object: ["error": "upstream_unavailable", "code": code, "message": error.localizedDescription], on: connection)
                    }
                }
            case ("GET", "/api/v1/snapshot"):
                Task {
                    let snapshot = await self.dataProvider.makeSnapshot()
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    if let data = try? encoder.encode(snapshot),
                       let jsonString = String(data: data, encoding: .utf8) {
                        self.sendResponse(status: 200, headers: ["Content-Type": "application/json"], body: jsonString, on: connection)
                    } else {
                        self.sendResponse(status: 500, headers: [:], body: "Internal Server Error", on: connection)
                    }
                }

            case ("GET", "/api/v1/pets"):
                let pets = self.dataProvider.availablePets()
                let encoder = JSONEncoder()
                if let data = try? encoder.encode(pets),
                   let jsonString = String(data: data, encoding: .utf8) {
                    self.sendResponse(status: 200, headers: ["Content-Type": "application/json"], body: jsonString, on: connection)
                } else {
                    self.sendResponse(status: 500, headers: [:], body: "Internal Server Error", on: connection)
                }

            case ("GET", "/api/v1/credentials"):
                Task {
                    let credentials = await self.dataProvider.exportCredentials()
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    if let data = try? encoder.encode(credentials),
                       let jsonString = String(data: data, encoding: .utf8) {
                        self.sendResponse(status: 200, headers: ["Content-Type": "application/json"], body: jsonString, on: connection)
                    } else {
                        self.sendResponse(status: 500, headers: [:], body: "Internal Server Error", on: connection)
                    }
                }

            case ("GET", "/api/v1/events"):
                startSSEStream(on: connection)

            default:
                sendResponse(status: 404, headers: [:], body: "Not Found", on: connection)
            }
            return
        }

        // 3. Desktop Plugin Static Web Hosting (GET / HEAD / or static files)
        if method == "GET" || method == "HEAD" {
            servePluginStaticContent(path: requestPath, on: connection)
            return
        }

        sendResponse(status: 404, headers: [:], body: "Not Found", on: connection)
    }

    private func servePluginStaticContent(path: String, on connection: NWConnection) {
        let manifestURL = pluginDirectoryURL.appendingPathComponent("plugin-manifest.json")
        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONDecoder().decode(WebPluginManifest.self, from: data),
           manifest.isRetiredMobileVersion {
            sendResponse(status: 410, headers: ["Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store"],
                body: "<!doctype html><meta charset=utf-8><title>版本已失效</title><h1>旧版 Web Mobile 已失效</h1><p>请更新至 0.0.9 或更新版本，并更新桌面端。旧 API 地址已停用。</p>", on: connection)
            return
        }

        let relativePath = (path == "/" || path.isEmpty) ? "index.html" : String(path.dropFirst())
        let fileURL = pluginDirectoryURL.appendingPathComponent(relativePath)

        // The manifest is public. PWA launches restore their pairing from client
        // storage, or ask to pair again when the installed app has separate storage.
        // Override even older plugin manifests so they cannot expose a launch token.
        if relativePath == "manifest.json" {
            if let data = try? Data(contentsOf: fileURL),
               var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                json["start_url"] = "./"
                if let patched = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) {
                    sendRawResponse(
                        status: 200,
                        headers: [
                            "Content-Type": "application/manifest+json; charset=utf-8",
                            "Cache-Control": "no-cache, no-store, must-revalidate",
                        ],
                        data: patched,
                        on: connection
                    )
                    return
                }
            }
        }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let fileData = try? Data(contentsOf: fileURL) {
                let mime = mimeType(for: fileURL.pathExtension)
                // Hashed bundles are content-addressed and safe to cache forever;
                // the entry document must always be revalidated, otherwise a phone
                // keeps booting the previous build after a plugin update.
                let isHashedAsset = relativePath.hasPrefix("assets/")
                let cacheControl = isHashedAsset
                    ? "public, max-age=31536000, immutable"
                    : "no-cache, no-store, must-revalidate"
                sendRawResponse(
                    status: 200,
                    headers: ["Content-Type": mime, "Cache-Control": cacheControl],
                    data: fileData,
                    on: connection
                )
                return
            }
        }


        // Fallback: If root is requested but plugin not installed, serve friendly status page
        if path == "/" || path == "/index.html" {
            let serverPort = self.port
            let hasToken = !token.isEmpty
            let fallbackHTML = """
            <!DOCTYPE html>
            <html lang="zh-CN">
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
              <title>Web 伴生插件未就绪 · Tomo</title>
              <style>
                :root {
                  --bg: #121316;
                  --card: #1c1d22;
                  --card-inner: #24262c;
                  --border: rgba(255, 255, 255, 0.08);
                  --border-strong: rgba(255, 255, 255, 0.14);
                  --text-title: #f4f4f5;
                  --text-sub: #a1a1aa;
                  --text-muted: #71717a;
                  --primary: #28c04e;
                  --amber: #f59e0b;
                  --blue: #3b82f6;
                }
                * { box-sizing: border-box; margin: 0; padding: 0; -webkit-tap-highlight-color: transparent; }
                body {
                  background: var(--bg);
                  color: var(--text-title);
                  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif;
                  min-height: 100vh;
                  display: flex;
                  align-items: center;
                  justify-content: center;
                  padding: 24px 16px;
                  background-image: radial-gradient(circle at 50% 0%, rgba(40, 192, 78, 0.08) 0%, transparent 60%);
                }
                .container {
                  width: 100%;
                  max-width: 480px;
                  background: var(--card);
                  border: 1px solid var(--border);
                  border-radius: 20px;
                  padding: 28px 20px;
                  box-shadow: 0 20px 40px -15px rgba(0, 0, 0, 0.6);
                  position: relative;
                }
                .badge-row {
                  display: flex;
                  justify-content: center;
                  margin-bottom: 16px;
                }
                .status-capsule {
                  display: inline-flex;
                  align-items: center;
                  gap: 6px;
                  background: rgba(16, 185, 129, 0.12);
                  border: 1px solid rgba(16, 185, 129, 0.28);
                  color: #34d399;
                  padding: 4px 12px;
                  border-radius: 9999px;
                  font-size: 11.5px;
                  font-weight: 500;
                  letter-spacing: 0.2px;
                }
                .pulse-dot {
                  width: 7px;
                  height: 7px;
                  background: #10b981;
                  border-radius: 50%;
                  animation: pulse 2s infinite ease-in-out;
                }
                @keyframes pulse {
                  0%, 100% { opacity: 1; transform: scale(1); }
                  50% { opacity: 0.4; transform: scale(0.85); }
                }
                .icon-hero {
                  width: 56px;
                  height: 56px;
                  margin: 0 auto 16px;
                  background: rgba(245, 158, 11, 0.12);
                  border: 1px solid rgba(245, 158, 11, 0.25);
                  border-radius: 16px;
                  display: flex;
                  align-items: center;
                  justify-content: center;
                  color: var(--amber);
                }
                .title {
                  text-align: center;
                  font-size: 18px;
                  font-weight: 600;
                  color: var(--text-title);
                  margin-bottom: 8px;
                  letter-spacing: -0.01em;
                }
                .subtitle {
                  text-align: center;
                  font-size: 13px;
                  color: var(--text-sub);
                  line-height: 1.55;
                  margin-bottom: 24px;
                }
                .section-title {
                  font-size: 12px;
                  font-weight: 600;
                  color: var(--text-muted);
                  text-transform: uppercase;
                  letter-spacing: 0.5px;
                  margin-bottom: 10px;
                  padding-left: 2px;
                }
                .plan-card {
                  background: var(--card-inner);
                  border: 1px solid var(--border);
                  border-radius: 14px;
                  padding: 14px;
                  margin-bottom: 12px;
                  transition: border-color 0.2s;
                }
                .plan-card.recommend {
                  border-color: rgba(40, 192, 78, 0.35);
                  background: linear-gradient(180deg, rgba(40, 192, 78, 0.05) 0%, var(--card-inner) 100%);
                }
                .plan-header {
                  display: flex;
                  align-items: center;
                  justify-content: space-between;
                  margin-bottom: 8px;
                }
                .plan-title {
                  font-size: 13.5px;
                  font-weight: 600;
                  color: var(--text-title);
                  display: flex;
                  align-items: center;
                  gap: 6px;
                }
                .tag {
                  font-size: 10px;
                  font-weight: 600;
                  padding: 2px 6px;
                  border-radius: 4px;
                  background: rgba(40, 192, 78, 0.18);
                  color: #4ade80;
                }
                .step-list {
                  list-style: none;
                  font-size: 12px;
                  color: var(--text-sub);
                  line-height: 1.65;
                }
                .step-list li {
                  position: relative;
                  padding-left: 18px;
                  margin-bottom: 4px;
                }
                .step-list li::before {
                  content: "•";
                  position: absolute;
                  left: 6px;
                  color: var(--text-muted);
                }
                .highlight-text {
                  color: var(--text-title);
                  font-weight: 500;
                }
                .action-row {
                  margin-top: 24px;
                  display: flex;
                  flex-direction: column;
                  gap: 10px;
                }
                .btn {
                  width: 100%;
                  border: none;
                  border-radius: 12px;
                  padding: 13px;
                  font-size: 13.5px;
                  font-weight: 600;
                  cursor: pointer;
                  display: flex;
                  align-items: center;
                  justify-content: center;
                  gap: 6px;
                  transition: opacity 0.15s, transform 0.1s;
                }
                .btn:active { transform: scale(0.98); }
                .btn-primary {
                  background: var(--primary);
                  color: #0b2f13;
                }
                .btn-secondary {
                  background: rgba(255, 255, 255, 0.06);
                  color: var(--text-sub);
                  border: 1px solid var(--border);
                }
                .footer-meta {
                  margin-top: 20px;
                  padding-top: 14px;
                  border-top: 1px solid var(--border);
                  display: flex;
                  justify-content: space-between;
                  font-size: 11px;
                  color: var(--text-muted);
                  font-family: ui-monospace, monospace;
                }
                .detect-tip {
                  text-align: center;
                  font-size: 11px;
                  color: var(--text-muted);
                  margin-top: 8px;
                }
              </style>
            </head>
            <body>
              <div class="container">
                <div class="badge-row">
                  <div class="status-capsule">
                    <span class="pulse-dot"></span>
                    <span>局域网同步正常 · 端口 \(serverPort)</span>
                  </div>
                </div>

                <div class="icon-hero">
                  <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                    <path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"></path>
                    <polyline points="3.27 6.96 12 12.01 20.73 6.96"></polyline>
                    <line x1="12" y1="22.08" x2="12" y2="12"></line>
                  </svg>
                </div>

                <h1 class="title">Web 伴生前端未就绪</h1>
                <p class="subtitle">Mac 端同步服务已连通，但尚未安装或启用移动看板 Web Core 静态资源包。</p>

                <div class="section-title">安装与就绪方案</div>

                <!-- 方案一：推荐在线安装 -->
                <div class="plan-card recommend">
                  <div class="plan-header">
                    <div class="plan-title">
                      <span>方案 1：Mac 端一键在线安装</span>
                    </div>
                    <span class="tag">推荐</span>
                  </div>
                  <ul class="step-list">
                    <li>打开 Mac 屏幕顶部的 <span class="highlight-text">Tomo</span> 并进入「偏好设置」</li>
                    <li>切换至侧边栏 <span class="highlight-text">「移动端伴生」</span> 标签页</li>
                    <li>在 Web 伴生前端插件卡片中，点击 <span class="highlight-text">「一键安装」</span></li>
                    <li>安装完成后，本页面会自动感应并载入看板界面</li>
                  </ul>
                </div>

                <!-- 方案二：本地导入或开发构建 -->
                <div class="plan-card">
                  <div class="plan-header">
                    <div class="plan-title">
                      <span>方案 2：从本地 .zip 导入 / 自建插件</span>
                    </div>
                  </div>
                  <ul class="step-list">
                    <li>若已有离线包，在 Mac 设置页点击 <span class="highlight-text">「从本地 .zip 导入…」</span></li>
                    <li><a href="https://github.com/xseven77/TomoGoWeb-release/releases/latest/download/mobile-web-plugin.zip" target="_blank" style="color: #60a5fa; text-decoration: none; display: inline-flex; align-items: center; gap: 4px; margin: 3px 0; font-weight: 500;"><span>📥 点击直接下载最新官方插件包 (mobile-web-plugin.zip)</span> ↗</a></li>
                    <li>开发者可在 <span class="highlight-text">TomoGo</span> 目录运行发布脚本自建</li>
                  </ul>
                </div>

                <div class="action-row">
                  <button class="btn btn-primary" id="refreshBtn" onclick="checkAndReload()">
                    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
                      <path d="M21.5 2v6h-6M21.34 15.57a10 10 0 1 1-.57-8.38l5.67-5.19"/>
                    </svg>
                    <span>重新检测并载入看板</span>
                  </button>
                </div>
                <div class="detect-tip" id="pollStatus">正在后台静默探测插件就绪状态 (每 3 秒)...</div>

                <div class="footer-meta">
                  <span>TOKEN: \(hasToken ? "已就绪 (TOKEN OK)" : "未携带")</span>
                  <span>API: /api/v1/snapshot</span>
                </div>
              </div>

              <script>
                var isChecking = false;
                function checkAndReload() {
                  if (isChecking) return;
                  isChecking = true;
                  var btn = document.getElementById('refreshBtn');
                  var origText = btn.innerHTML;
                  btn.innerHTML = '<span>正在检测...</span>';
                  
                  // 请求一个必定由正式 Web 插件提供的资源特征
                  fetch('./index.html?t=' + Date.now(), { method: 'GET', cache: 'no-cache' })
                    .then(function(res) {
                      return res.text();
                    })
                    .then(function(html) {
                      // 若已不再是 fallback 页面（即正式插件已部署，包含 tomo-app-shell 或 vite 入口）
                      if (html && (html.indexOf('tomo-app-shell') !== -1 || html.indexOf('/assets/index') !== -1 || html.indexOf('__DSH_BOOT__') !== -1)) {
                        window.location.reload();
                      } else {
                        btn.innerHTML = '<span>暂未检测到插件，请在 Mac 完成安装</span>';
                        setTimeout(function() {
                          btn.innerHTML = origText;
                          isChecking = false;
                        }, 1800);
                      }
                    })
                    .catch(function() {
                      btn.innerHTML = origText;
                      isChecking = false;
                    });
                }

                // 自动后台轮询：Mac 端点完安装，手机端无需任何操作自动跳转！
                var pollInterval = setInterval(function() {
                  fetch('./index.html?probe=' + Date.now(), { method: 'GET', cache: 'no-cache' })
                    .then(function(res) { return res.text(); })
                    .then(function(html) {
                      if (html && (html.indexOf('tomo-app-shell') !== -1 || html.indexOf('/assets/index') !== -1)) {
                        clearInterval(pollInterval);
                        var status = document.getElementById('pollStatus');
                        if (status) status.innerText = '检测到插件已安装，正在载入看板...';
                        setTimeout(function() { window.location.reload(); }, 600);
                      }
                    })
                    .catch(function() {});
                }, 3000);
              </script>
            </body>
            </html>
            """
            sendResponse(status: 200, headers: ["Content-Type": "text/html; charset=utf-8"], body: fallbackHTML, on: connection)
            return
        }

        sendResponse(status: 404, headers: [:], body: "Not Found", on: connection)
    }

    private func parseQuery(_ query: String?) -> [String: String] {
        guard let query else { return [:] }
        var dict: [String: String] = [:]
        for item in query.components(separatedBy: "&") {
            let pair = item.components(separatedBy: "=")
            if pair.count == 2 {
                dict[pair[0]] = pair[1].removingPercentEncoding ?? pair[1]
            }
        }
        return dict
    }

    private func validateAuth(headers: [String: String], queryParams: [String: String]) -> Bool {
        if let auth = headers["authorization"] {
            let expected = "Bearer \(token)"
            if auth == expected { return true }
        }
        if let queryToken = queryParams["token"], queryToken == token {
            return true
        }
        return false
    }

    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": "text/html; charset=utf-8"
        case "js", "mjs": "application/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json": "application/json; charset=utf-8"
        case "webp": "image/webp"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "svg": "image/svg+xml"
        case "ico": "image/x-icon"
        case "woff2": "font/woff2"
        default: "application/octet-stream"
        }
    }

    private func sendResponse(
        status: Int,
        headers: [String: String],
        body: String,
        on connection: NWConnection
    ) {
        let bodyData = body.data(using: .utf8) ?? Data()
        sendRawResponse(status: status, headers: headers, data: bodyData, on: connection)
    }

    private func sendRawResponse(
        status: Int,
        headers: [String: String],
        data: Data,
        on connection: NWConnection
    ) {
        var response = "HTTP/1.1 \(status) \(statusMessage(for: status))\r\n"
        var finalHeaders = headers
        finalHeaders["Access-Control-Allow-Origin"] = "*"
        finalHeaders["Access-Control-Allow-Headers"] = "Authorization, Content-Type, Accept, X-Tomo-App-Name, X-Target-Authorization, ChatGPT-Account-Id"
        finalHeaders["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
        finalHeaders["Content-Length"] = "\(data.count)"
        finalHeaders["Connection"] = "close"

        for (k, v) in finalHeaders {
            response += "\(k): \(v)\r\n"
        }
        response += "\r\n"

        var fullData = response.data(using: .utf8) ?? Data()
        fullData.append(data)

        connection.send(content: fullData, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }

    private func sendJSONResponse(status: Int, object: Any, on connection: NWConnection) {
        if let data = try? JSONSerialization.data(withJSONObject: object),
           let string = String(data: data, encoding: .utf8) {
            sendResponse(status: status, headers: ["Content-Type": "application/json"], body: string, on: connection)
        } else {
            sendResponse(status: 500, headers: [:], body: "Internal Error", on: connection)
        }
    }

    private func startSSERelay(target: URL, token: String, appName: String?, on connection: NWConnection) {
        let relayID = UUID()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed: self?.removeSSERelay(id: relayID)
            default: break
            }
        }
        let task = Task { [weak self] in
            guard let self else { return }
            var started = false
            defer {
                let closeStream = started || Task.isCancelled
                self.removeSSERelay(id: relayID)
                if closeStream { connection.cancel() }
            }
            do {
                var request = URLRequest(url: target)
                request.timeoutInterval = 3600
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                if let appName { request.setValue(appName, forHTTPHeaderField: "X-Tomo-App-Name") }
                let (bytes, response) = try await URLSession.tomoRelay(for: target).bytes(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                guard http.statusCode == 200 else {
                    self.sendJSONResponse(status: http.statusCode, object: ["error": "agent_stream_failed"], on: connection)
                    return
                }
                guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else {
                    throw URLError(.badServerResponse)
                }
                let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache, no-transform\r\nAccess-Control-Allow-Origin: *\r\nX-Accel-Buffering: no\r\nConnection: keep-alive\r\n\r\n: relay ready\n\n"
                try await self.sendStreamData(Data(headers.utf8), on: connection)
                started = true
                var buffer = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    buffer.append(byte)
                    if buffer.count > 1_048_576 { throw URLError(.dataLengthExceedsMaximum) }
                    if byte == 10 {
                        try await self.sendStreamData(buffer, on: connection)
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
            } catch {
                if !started && !Task.isCancelled {
                    self.sendJSONResponse(status: 502, object: ["error": "agent_stream_unavailable"], on: connection)
                }
            }
        }
        lock.lock()
        sseRelays[relayID] = task
        lock.unlock()
    }

    private func sendStreamData(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private func removeSSERelay(id: UUID) {
        lock.lock()
        let task = sseRelays.removeValue(forKey: id)
        lock.unlock()
        task?.cancel()
    }

    private func startSSEStream(on connection: NWConnection) {
        let clientID = UUID()
        lock.lock()
        sseClients[clientID] = connection
        if heartbeatTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 15, repeating: 15)
            timer.setEventHandler { [weak self] in
                self?.broadcast(event: "heartbeat", data: "{\"heartbeat\":true}")
            }
            heartbeatTimer = timer
            timer.resume()
        }
        lock.unlock()

        let initialResponse = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/event-stream\r\n"
            + "Cache-Control: no-cache, no-transform\r\n"
            + "Access-Control-Allow-Origin: *\r\n"
            + "X-Accel-Buffering: no\r\n"
            + "Connection: keep-alive\r\n\r\n"
            + ": keepalive\n\n"

        guard let initialData = initialResponse.data(using: .utf8) else {
            connection.cancel()
            return
        }

        connection.send(content: initialData, completion: .contentProcessed({ [weak self] error in
            if error != nil {
                self?.removeSSEClient(id: clientID)
                connection.cancel()
            } else if let self {
                Task {
                    let snapshot = await self.dataProvider.makeSnapshot()
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    do {
                        let data = try encoder.encode(snapshot)
                        let frame = "event: snapshot\ndata: \(String(decoding: data, as: UTF8.self))\n\n"
                        try await self.sendStreamData(Data(frame.utf8), on: connection)
                    } catch {
                        self.removeSSEClient(id: clientID)
                        connection.cancel()
                    }
                }
            }
        }))
    }

    private func removeSSEClient(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        sseClients.removeValue(forKey: id)
    }

    private struct DiscoveredDevice: Sendable {
        let ip: String
        let port: Int
        let baseUrl: String
        let name: String
        let isPlugin: Bool
        let isLocal: Bool
        let version: String?

        func toDictionary() -> [String: Any] {
            var dict: [String: Any] = [
                "ip": ip,
                "port": port,
                "baseUrl": baseUrl,
                "name": name,
                "isPlugin": isPlugin,
                "isLocal": isLocal
            ]
            if let version { dict["version"] = version }
            return dict
        }
    }

    private func discoverLANAgents(subnetOverride: String?) async -> [[String: Any]] {
        let localIP = GatewayNetworkInfo.currentLANIPv4() ?? "127.0.0.1"
        let prefix: String
        if let custom = subnetOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            let parts = custom.split(separator: ".")
            if parts.count >= 3 {
                prefix = "\(parts[0]).\(parts[1]).\(parts[2])"
            } else {
                prefix = custom
            }
        } else {
            let parts = localIP.split(separator: ".")
            if parts.count == 4 {
                prefix = "\(parts[0]).\(parts[1]).\(parts[2])"
            } else {
                prefix = "192.168.1"
            }
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.6
        config.timeoutIntervalForResource = 0.8
        let probeSession = URLSession(configuration: config)
        defer { probeSession.invalidateAndCancel() }

        var discovered: [DiscoveredDevice] = []

        await withTaskGroup(of: DiscoveredDevice?.self) { group in
            for i in 1...254 {
                let host = "\(prefix).\(i)"
                group.addTask {
                    guard let url = URL(string: "http://\(host):58350/health") else { return nil }
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 0.5
                    req.setValue("Tomo Go Mobile Discovery", forHTTPHeaderField: "X-Tomo-App-Name")
                    do {
                        let (data, response) = try await probeSession.data(for: req)
                        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              obj["status"] as? String == "ok" else { return nil }

                        var name = (obj["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        if name == nil || name?.isEmpty == true {
                            name = "Tomo (\(host))"
                        }
                        var isPlugin = true
                        var version: String? = obj["version"] as? String

                        if let manifestURL = URL(string: "http://\(host):58350/plugin-manifest.json") {
                            var mReq = URLRequest(url: manifestURL)
                            mReq.timeoutInterval = 0.5
                            if let (mData, mResp) = try? await probeSession.data(for: mReq),
                               (mResp as? HTTPURLResponse)?.statusCode == 200,
                               let mObj = try? JSONSerialization.jsonObject(with: mData) as? [String: Any] {
                                if let mVer = mObj["version"] as? String, !mVer.isEmpty {
                                    version = mVer
                                }
                                isPlugin = (mObj["name"] as? String) == "tomo-mobile-web"
                            }
                        }

                        return DiscoveredDevice(
                            ip: host,
                            port: 58350,
                            baseUrl: "http://\(host):58350",
                            name: name ?? "Tomo (\(host))",
                            isPlugin: isPlugin,
                            isLocal: (host == localIP),
                            version: version
                        )
                    } catch {
                        return nil
                    }
                }
            }

            for await result in group {
                if let result {
                    discovered.append(result)
                }
            }
        }

        discovered.sort {
            let last1 = $0.ip.split(separator: ".").last.flatMap { Int($0) } ?? 0
            let last2 = $1.ip.split(separator: ".").last.flatMap { Int($0) } ?? 0
            return last1 < last2
        }

        return discovered.map { $0.toDictionary() }
    }

    private func statusMessage(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 410: "Gone"
        case 500: "Internal Server Error"
        default: "Status \(status)"
        }
    }
}
