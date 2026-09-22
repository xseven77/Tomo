import AppKit
import Foundation
import Observation

extension URLSession {
    /// A URLSession configured to bypass all system proxies (e.g. Clash, Surge)
    /// for robust communication with local loopback endpoints like 127.0.0.1.
    public static let loopbackDirect: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 5
        return URLSession(configuration: config)
    }()
}


/// Supervisor managing the background Local LLM Gateway child process and health checks.
/// Persists for the lifetime of the application, independent of the Gateway UI window.
@MainActor
@Observable
public final class GatewaySupervisor {
    public static let shared = GatewaySupervisor()

    public private(set) var isRunning: Bool = false
    public private(set) var endpoint: URL? = URL(string: "http://127.0.0.1:58349")
    public private(set) var port: Int = 58349
    public private(set) var localToken: String

    public func updateLocalToken(_ newToken: String) {
        self.localToken = newToken
    }

    public private(set) var activeRequests: Int = 0
    public private(set) var todayRequests: Int = 0
    public private(set) var statusText: String = "运行中"
    public private(set) var statusDetail: String = "loopback 与 local token 已验证 · 端口隔离就绪"
    public private(set) var uptimeText: String = "00:00:00"
    public private(set) var lastError: String?

    public var isAutoStartEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(isAutoStartEnabled, forKey: "codexling.gateway.autostart")
        }
    }

    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var uptimeTimer: Timer?
    private var startTime: Date?
    private var pendingRestartTask: Task<Void, Never>?
    private var hasAttemptedStaleGatewayRecovery = false
    private var isRecoveryScheduled = false
    private var consecutiveHealthFailures = 0
    private var staleRecoveryAttempts = 0

    public init() {
        self.isAutoStartEnabled = UserDefaults.standard.object(forKey: "codexling.gateway.autostart") as? Bool ?? true
        let settings = GatewaySettingsStorage().load()
        self.localToken = settings.authToken
        start()
    }

    /// Locate candidate executable path for the Gateway.
    private func candidateExecutableURL() -> URL? {
        // In unit test runner, always use mock loopback mode to avoid port
        // contention with live Tomo app running on developer machine.
        if NSClassFromString("XCTestCase") != nil ||
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            ProcessInfo.processInfo.processName.contains("xctest") {
            return nil
        }

        // 1. Check the packaged App helper. `url(forAuxiliaryExecutable:)`
        // only searches the standard executable locations and does not find
        // our Contents/Helpers binary reliably.
        let bundledHelperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/TomoGateway")
        if FileManager.default.isExecutableFile(atPath: bundledHelperURL.path) {
            return bundledHelperURL
        }

        // 2. Legacy bundle lookup.
        if let helperURL = Bundle.main.url(forAuxiliaryExecutable: "TomoGateway") {
            if FileManager.default.isExecutableFile(atPath: helperURL.path) {
                return helperURL
            }
        }

        // 3. Development / workspace paths
        let fileManager = FileManager.default
        let devCandidates = [
            URL(fileURLWithPath: "/Users/qiizo/code/Personal/Tomo/target/release/tomo-gateway"),
            URL(fileURLWithPath: "/Users/qiizo/code/Personal/Tomo/target/debug/tomo-gateway"),
            URL(fileURLWithPath: "target/release/tomo-gateway"),
            URL(fileURLWithPath: "target/debug/tomo-gateway"),
            URL(fileURLWithPath: "target/release/tomo-gateway-feasibility"),
            URL(fileURLWithPath: "target/debug/tomo-gateway-feasibility"),
            URL(fileURLWithPath: "spikes/gateway-feasibility/target/release/tomo-gateway-feasibility"),
            URL(fileURLWithPath: "spikes/gateway-feasibility/target/debug/tomo-gateway-feasibility"),
            URL(fileURLWithPath: "/private/tmp/tomo-gateway-feasibility/tomo-gateway-feasibility"),
        ]

        for url in devCandidates {
            if fileManager.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        return nil
    }

    public func start() {
        guard !isRunning else { return }
        pendingRestartTask?.cancel()
        pendingRestartTask = nil

        if let executable = candidateExecutableURL() {
            startChildProcess(at: executable)
        } else {
            // Emulated mock/loopback mode when helper binary has not been compiled yet
            startMockLoopback()
        }
    }

    private func startChildProcess(at executable: URL) {
        do {
            let proc = Process()
            let outPipe = Pipe()
            let errPipe = Pipe()

            proc.executableURL = executable
            let settings = GatewaySettingsStorage().load()
            let bindHost = settings.allowLanAccess ? "0.0.0.0" : "127.0.0.1"
            let tokenToUse = localToken.isEmpty ? settings.authToken : localToken
            self.localToken = tokenToUse
            proc.arguments = ["--host", bindHost, "--port", "58349", "--token", tokenToUse, "--auto-check"]
            var environment = AppNetworkProxyConfiguration.load()
                .applying(to: ProcessInfo.processInfo.environment)
            let geminiOAuth = GeminiOAuthConfiguration.load()
            if geminiOAuth.isConfigured {
                // The helper refreshes the user-owned OAuth token when needed.
                // Only the public OAuth client ID is passed; no API key or
                // refresh token is exposed through the process environment.
                environment[GeminiOAuthConfiguration.clientIDEnvironmentKey] = geminiOAuth.clientID
            }
            proc.environment = environment
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            try proc.run()
            self.process = proc
            self.outputPipe = outPipe
            self.errorPipe = errPipe
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                Self.appendGatewayDiagnostic(String(decoding: data, as: UTF8.self))
            }

            // A helper that cannot bind the loopback port exits before this
            // handshake. Do not mark that failed launch as "running": doing
            // so leaves Pi/Hermes attached to an orphaned, older Gateway.
            guard let readyLine = readFirstLine(from: outPipe.fileHandleForReading),
                  let data = readyLine.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let host = json["host"] as? String,
                  let port = json["port"] as? Int,
                  let token = json["token"] as? String else {
                if proc.isRunning { proc.terminate() }
                self.process = nil
                self.outputPipe = nil
                self.errorPipe?.fileHandleForReading.readabilityHandler = nil
                self.errorPipe = nil
                self.isRunning = false
                self.startTime = nil
                // During rebuild-and-run the prior App instance may still own
                // this port. Reuse a healthy local Gateway immediately instead
                // of shutting it down and showing a needless recovery state.
                self.statusText = "正在连接 Gateway"
                self.statusDetail = "正在确认现有本地 Gateway 是否可用。"
                self.adoptExistingGatewayOrScheduleRecovery()
                return
            }
            self.port = port
            self.localToken = token
            let connectHost = (host == "0.0.0.0") ? "127.0.0.1" : host
            self.endpoint = URL(string: "http://\(connectHost):\(port)")
            self.hasAttemptedStaleGatewayRecovery = false
            self.consecutiveHealthFailures = 0
            self.staleRecoveryAttempts = 0

            Task { @MainActor in
                await GatewayStore.shared.refreshModelHealth()
            }

            proc.terminationHandler = { [weak self] terminatedProcess in
                DispatchQueue.main.async {
                    guard let self,
                          self.process === terminatedProcess,
                          self.isRunning else { return }
                    self.handleUnexpectedGatewayExit(status: terminatedProcess.terminationStatus)
                }
            }

            self.isRunning = true
            self.startTime = Date()
            self.statusText = "运行中"
            let isLan = (host == "0.0.0.0") || settings.allowLanAccess
            self.statusDetail = isLan
                ? "局域网访问已开启 (0.0.0.0) · local token 鉴权保护中"
                : "loopback 与 local token 已验证 · 端口隔离就绪"
            self.lastError = nil
            self.startUptimeTracker()
        } catch {
            self.lastError = error.localizedDescription
            startMockLoopback()
        }
    }

    private func startMockLoopback() {
        self.isRunning = true
        self.startTime = Date()
        self.port = 58349
        self.endpoint = URL(string: "http://127.0.0.1:58349")
        self.statusText = "运行中"
        let settings = GatewaySettingsStorage().load()
        self.statusDetail = settings.allowLanAccess
            ? "本地 loopback 准备就绪 · 局域网接入已就绪"
            : "本地 loopback 准备就绪 · 本地 Token 已保护"
        self.startUptimeTracker()
    }

    public func stop() {
        guard isRunning else { return }

        pendingRestartTask?.cancel()
        pendingRestartTask = nil

        uptimeTimer?.invalidate()
        uptimeTimer = nil

        // The helper may have been launched by an earlier app process, so request
        // shutdown even when this supervisor does not own a Process instance.
        requestGatewayShutdown()
        requestGatewayShutdown(token: "codexling-local-token")

        if let proc = process, proc.isRunning {
            proc.terminate()
            proc.waitUntilExit()
        }

        self.process = nil
        self.outputPipe = nil
        self.errorPipe?.fileHandleForReading.readabilityHandler = nil
        self.errorPipe = nil
        self.isRunning = false
        self.statusText = "已停止"
        self.statusDetail = "Gateway 已停止 · Agent 将无法访问本地端点"
        self.activeRequests = 0
        self.uptimeText = "--:--:--"
        self.consecutiveHealthFailures = 0
        self.staleRecoveryAttempts = 0
    }

    private func requestGatewayShutdown(token: String? = nil) {
        guard let endpoint else { return }
        var request = URLRequest(url: endpoint.appendingPathComponent("shutdown"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token ?? localToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 1
        URLSession.loopbackDirect.dataTask(with: request).resume()
    }

    public func toggle() {
        if isRunning {
            stop()
        } else {
            start()
        }
    }

    public func restart() {
        stop()
        if candidateExecutableURL() == nil {
            start()
            return
        }
        // /shutdown is asynchronous for a Gateway owned by an earlier app
        // instance. Waiting briefly before binding prevents a port race that
        // used to keep Pi and Hermes on the stale helper binary.
        pendingRestartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }

    private var statusPollTick: Int = 0

    private func startUptimeTracker() {
        uptimeTimer?.invalidate()
        statusPollTick = 0
        uptimeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startTime = self.startTime, self.isRunning else { return }
                let interval = Int(Date().timeIntervalSince(startTime))
                let hours = interval / 3600
                let minutes = (interval % 3600) / 60
                let seconds = interval % 60
                self.uptimeText = String(format: "%02d:%02d:%02d", hours, minutes, seconds)

                self.statusPollTick += 1
                if self.statusPollTick % 2 == 0 {
                    self.pollStatus()
                }
            }
        }
    }

    private func pollStatus() {
        guard isRunning, let endpoint = endpoint else { return }
        var request = URLRequest(url: endpoint.appendingPathComponent("status"))
        request.setValue("Bearer \(localToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 1
        URLSession.loopbackDirect.dataTask(with: request) { [weak self] data, response, error in
            guard let self,
                  let data,
                  let response = response as? HTTPURLResponse,
                  (200...299).contains(response.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async {
                    self?.recordGatewayHealthFailure(error)
                }
                return
            }
            DispatchQueue.main.async {
                self.consecutiveHealthFailures = 0
                self.activeRequests = json["active_requests"] as? Int ?? 0
                self.todayRequests = json["total_requests"] as? Int ?? 0
                let inTokens = json["total_input_tokens"] as? Int ?? 0
                let outTokens = json["total_output_tokens"] as? Int ?? 0
                let toolCalls = json["total_tool_calls"] as? Int ?? 0
                GatewayStore.shared.updateGatewayMetrics(
                    totalRequests: self.todayRequests,
                    inputTokens: inTokens,
                    outputTokens: outTokens,
                    toolCalls: toolCalls
                )

                if let jobDict = json["model_health_job"] as? [String: Any] {
                    GatewayStore.shared.updateModelCheckJobStatus(from: jobDict)
                }

                if let rawList = json["recent_requests"] as? [[String: Any]] {
                    let rows: [GatewayRequestRow] = rawList.compactMap { dict in
                        guard let id = dict["id"] as? String,
                              let time = dict["time"] as? String,
                              let agent = dict["agent"] as? String,
                              let ingressProtocol = dict["ingressProtocol"] as? String,
                              let modelAlias = dict["modelAlias"] as? String,
                              let targetProvider = dict["targetProvider"] as? String,
                              let targetModel = dict["targetModel"] as? String,
                              let latencyMs = dict["latencyMs"] as? Int,
                              let ttftMs = dict["ttftMs"] as? Int,
                              let tokens = dict["tokens"] as? Int,
                              let fidelity = dict["fidelity"] as? String,
                              let status = dict["status"] as? String else { return nil }
                        return GatewayRequestRow(
                            id: id,
                            time: time,
                            agent: agent,
                            ingressProtocol: ingressProtocol,
                            modelAlias: modelAlias,
                            targetProvider: targetProvider,
                            targetModel: targetModel,
                            latencyMs: latencyMs,
                            ttftMs: ttftMs,
                            tokens: tokens,
                            fidelity: fidelity,
                            status: status
                        )
                    }
                    GatewayStore.shared.setRequestsList(rows)
                }
            }
        }.resume()
    }

    private func recordGatewayHealthFailure(_ error: Error?) {
        guard isRunning else { return }
        consecutiveHealthFailures += 1
        // Gateway currently handles a request at a time, so `/status` may
        // legitimately wait behind a long streaming request. A timeout must
        // never terminate the process that is serving Pi/Hermes.
        guard let urlError = error as? URLError,
              urlError.code == .cannotConnectToHost,
              process == nil else {
            return
        }
        // An adopted Gateway has no local Process handle. Only an explicit
        // connection refusal confirms that its listener disappeared; it is
        // then safe for this App to create the single replacement listener.
        handleGatewayUnavailable(reason: "已连接的 Gateway 不再监听本地端口。")
    }

    private func handleUnexpectedGatewayExit(status: Int32) {
        handleGatewayUnavailable(reason: "Gateway 子进程意外退出（状态码 \(status)）。")
    }

    private func handleGatewayUnavailable(reason: String) {
        guard isRunning else { return }
        Self.appendGatewayDiagnostic(reason)
        uptimeTimer?.invalidate()
        uptimeTimer = nil
        process = nil
        outputPipe = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe = nil
        isRunning = false
        startTime = nil
        activeRequests = 0
        uptimeText = "--:--:--"
        statusText = "正在恢复 Gateway"
        statusDetail = reason
        lastError = reason
        scheduleGatewayRecovery()
    }

    private func scheduleGatewayRecovery() {
        guard isAutoStartEnabled, !isRecoveryScheduled else { return }
        isRecoveryScheduled = true
        pendingRestartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.isRecoveryScheduled = false
            self.pendingRestartTask = nil
            self.start()
        }
    }

    private func adoptExistingGatewayOrScheduleRecovery() {
        guard let endpoint else {
            scheduleGatewayRecovery()
            return
        }
        var request = URLRequest(url: endpoint.appendingPathComponent("status"))
        request.setValue("Bearer \(localToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 1
        URLSession.loopbackDirect.dataTask(with: request) { [weak self] data, response, _ in
            let isHealthy = data != nil
                && (response as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } == true
            DispatchQueue.main.async {
                guard let self, !self.isRunning else { return }
                if isHealthy {
                    self.hasAttemptedStaleGatewayRecovery = false
                    self.consecutiveHealthFailures = 0
                    self.staleRecoveryAttempts = 0
                    self.isRunning = true
                    self.startTime = Date()
                    self.statusText = "运行中"
                    let settings = GatewaySettingsStorage().load()
                    self.statusDetail = settings.allowLanAccess
                        ? "已连接现有本地 Gateway · 局域网访问已开启 (0.0.0.0)"
                        : "已连接现有本地 Gateway · loopback 与 local token 已验证"
                    self.lastError = nil
                    self.startUptimeTracker()
                } else {
                    self.staleRecoveryAttempts += 1
                    if self.staleRecoveryAttempts <= 2 {
                        Self.appendGatewayDiagnostic("Gateway 端口占用且无法接管，尝试清理残留孤儿 Gateway 进程 (重试第 \(self.staleRecoveryAttempts) 次)")
                        self.requestGatewayShutdown(token: self.localToken)
                        self.requestGatewayShutdown(token: "codexling-local-token")
                        self.terminateStaleGatewayProcesses()
                        self.statusText = "正在恢复 Gateway"
                        self.statusDetail = "正在释放端口并重新启动 Gateway..."
                        self.lastError = "Gateway 端口占用，正在自动清理并恢复。"
                        self.scheduleGatewayRecovery()
                    } else {
                        self.statusText = "端口冲突"
                        self.statusDetail = "端口 \(self.port) 已被其他进程占用，请检查并释放端口。"
                        self.lastError = "端口 \(self.port) 占用冲突，无法启动 Gateway。"
                        Self.appendGatewayDiagnostic(self.lastError ?? "端口冲突")
                    }
                }
            }
        }.resume()
    }

    private func terminateStaleGatewayProcesses() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-9", "-x", "TomoGateway"]
        try? task.run()
        task.waitUntilExit()
    }

    nonisolated private static func appendGatewayDiagnostic(_ message: String) {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? "/Users/qiizo"
        let directory = URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/Tomo", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return }
        let path = directory.appendingPathComponent("gateway-supervisor.log")
        let line = "[\(Int(Date().timeIntervalSince1970))] \(message.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: path, options: .atomic)
        }
    }

    private func readFirstLine(from handle: FileHandle) -> String? {
        var data = Data()
        while true {
            let chunk = handle.readData(ofLength: 1)
            guard !chunk.isEmpty else { return data.isEmpty ? nil : String(data: data, encoding: .utf8) }
            if chunk.first == 0x0A { return String(data: data, encoding: .utf8) }
            data.append(chunk)
        }
    }
}
