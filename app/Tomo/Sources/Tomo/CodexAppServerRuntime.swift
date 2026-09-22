import Darwin
import Foundation

enum CodexAppServerError: LocalizedError {
    case unsupported([String])
    case launchFailed
    case timeout
    case disconnected
    case invalidResponse
    case rpc(String)

    var errorDescription: String? {
        switch self {
        case let .unsupported(methods): "当前 Codex App Server 缺少能力：\(methods.joined(separator: ", "))"
        case .launchFailed: "Codex App Server 启动失败"
        case .timeout: "Codex App Server 响应超时"
        case .disconnected: "Codex App Server 已断开"
        case .invalidResponse: "Codex App Server 返回了无法识别的数据"
        case let .rpc(message): "Codex App Server：\(message)"
        }
    }
}

struct CodexAppServerCapabilityResult: Equatable, Sendable {
    let supported: Bool
    let missingMethods: [String]
}

struct CodexAppServerCapabilityProbe: Sendable {
    static let requiredMethods = ["initialize", "account/read", "account/rateLimits/read", "thread/list"]

    func probe(executableURL: URL) -> CodexAppServerCapabilityResult {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexling-app-server-schema-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["app-server", "generate-json-schema", "--experimental", "--out", output.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return CodexAppServerCapabilityResult(supported: false, missingMethods: Self.requiredMethods)
            }
            let schema = try Data(contentsOf: output.appendingPathComponent("ClientRequest.json"))
            return inspect(schemaData: schema)
        } catch {
            return CodexAppServerCapabilityResult(supported: false, missingMethods: Self.requiredMethods)
        }
    }

    func inspect(schemaData: Data) -> CodexAppServerCapabilityResult {
        let missing = Self.requiredMethods.filter { method in
            schemaData.range(of: Data("\"\(method)\"".utf8)) == nil
        }
        return CodexAppServerCapabilityResult(supported: missing.isEmpty, missingMethods: missing)
    }
}

struct CodexAppServerSnapshotParser: Sendable {
    func parse(accountResponse: [String: Any], rateLimitResponse: [String: Any]) throws -> CodexAccountUsageSnapshot {
        guard let accountResult = accountResponse["result"] as? [String: Any],
              let rateResult = rateLimitResponse["result"] as? [String: Any] else {
            throw CodexAppServerError.invalidResponse
        }
        let account = accountResult["account"] as? [String: Any]
        let buckets = rateResult["rateLimitsByLimitId"] as? [String: Any]
        let rateLimits = (buckets?["codex"] as? [String: Any])
            ?? (rateResult["rateLimits"] as? [String: Any])
            ?? [:]
        return CodexAccountUsageSnapshot(
            email: account?["email"] as? String,
            planType: account?["planType"] as? String,
            primary: window(from: rateLimits["primary"]),
            secondary: window(from: rateLimits["secondary"]),
            fetchedAt: Date()
        )
    }

    private func window(from value: Any?) -> CodexAccountRateLimitWindow? {
        guard let object = value as? [String: Any],
              let used = object["usedPercent"] as? NSNumber else { return nil }
        let reset = (object["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return CodexAccountRateLimitWindow(
            usedPercent: min(100, max(0, used.intValue)),
            resetsAt: reset,
            windowDurationMinutes: (object["windowDurationMins"] as? NSNumber)?.intValue
        )
    }
}

/// A persistent stdio JSON-RPC process bound to exactly one CODEX_HOME.
/// Requests are serialized on a private queue; notifications are skipped until
/// the matching response arrives.
final class CodexAppServerRuntime: @unchecked Sendable {
    let connectionID: ConnectionID
    let homeURL: URL

    private let executableURL: URL
    private let queue: DispatchQueue
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var nextRequestID: Int64 = 1

    init(connectionID: ConnectionID, homeURL: URL, executableURL: URL) {
        self.connectionID = connectionID
        self.homeURL = homeURL
        self.executableURL = executableURL
        queue = DispatchQueue(label: "com.qiizo.tomo.app-server.\(connectionID.rawValue.uuidString)")
    }

    func fetchSnapshot() throws -> CodexAccountUsageSnapshot {
        try queue.sync {
            try ensureStarted()
            let account = try request(method: "account/read", params: ["refreshToken": false])
            let limits = try request(method: "account/rateLimits/read", params: NSNull())
            return try CodexAppServerSnapshotParser().parse(accountResponse: account, rateLimitResponse: limits)
        }
    }

    func stop() {
        queue.sync {
            input?.closeFile()
            output?.closeFile()
            if process?.isRunning == true { process?.terminate() }
            process = nil
            input = nil
            output = nil
        }
    }

    private func ensureStarted() throws {
        if process?.isRunning == true { return }
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = homeURL.path
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        do { try process.run() } catch { throw CodexAppServerError.launchFailed }
        self.process = process
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading

        _ = try request(method: "initialize", params: [
            "clientInfo": ["name": "Tomo", "title": "Tomo", "version": "0.3.16"],
            "capabilities": ["experimentalApi": true],
        ])
        try writeJSON(["method": "initialized"])
    }

    private func request(method: String, params: Any) throws -> [String: Any] {
        let id = nextRequestID
        nextRequestID += 1
        try writeJSON(["id": id, "method": method, "params": params])
        while true {
            let response = try readJSONLine()
            guard let responseID = response["id"] as? NSNumber,
                  responseID.int64Value == id else { continue }
            if let error = response["error"] as? [String: Any] {
                throw CodexAppServerError.rpc(error["message"] as? String ?? "未知错误")
            }
            guard response["result"] != nil else { throw CodexAppServerError.invalidResponse }
            return response
        }
    }

    private func writeJSON(_ object: [String: Any]) throws {
        guard let input else { throw CodexAppServerError.disconnected }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        do { try input.write(contentsOf: data) } catch { throw CodexAppServerError.disconnected }
    }

    private func readJSONLine() throws -> [String: Any] {
        guard let output else { throw CodexAppServerError.disconnected }
        var data = Data()
        while data.count < 1_048_576 {
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 5_000)
            guard ready > 0 else { throw ready == 0 ? CodexAppServerError.timeout : CodexAppServerError.disconnected }
            var byte: UInt8 = 0
            let count = Darwin.read(output.fileDescriptor, &byte, 1)
            guard count == 1 else { throw CodexAppServerError.disconnected }
            if byte == 0x0A {
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw CodexAppServerError.invalidResponse
                }
                return object
            }
            data.append(byte)
        }
        throw CodexAppServerError.invalidResponse
    }

    deinit {
        if process?.isRunning == true { process?.terminate() }
    }
}

final class CodexAppServerSupervisor: @unchecked Sendable {
    private let lock = NSLock()
    private var runtimes: [ConnectionID: CodexAppServerRuntime] = [:]
    private var capabilityResult: CodexAppServerCapabilityResult?
    private let capabilityProbe: CodexAppServerCapabilityProbe

    init(capabilityProbe: CodexAppServerCapabilityProbe = CodexAppServerCapabilityProbe()) {
        self.capabilityProbe = capabilityProbe
    }

    func snapshot(for connection: CodexAccountConnection, homeURL: URL, executableURL: URL) throws -> CodexAccountUsageSnapshot {
        lock.lock()
        let capabilities = capabilityResult ?? capabilityProbe.probe(executableURL: executableURL)
        capabilityResult = capabilities
        let runtime: CodexAppServerRuntime
        if let existing = runtimes[connection.id] {
            runtime = existing
        } else {
            runtime = CodexAppServerRuntime(connectionID: connection.id, homeURL: homeURL, executableURL: executableURL)
            runtimes[connection.id] = runtime
        }
        lock.unlock()
        guard capabilities.supported else { throw CodexAppServerError.unsupported(capabilities.missingMethods) }
        return try runtime.fetchSnapshot()
    }

    func remove(connectionID: ConnectionID) {
        lock.lock()
        let runtime = runtimes.removeValue(forKey: connectionID)
        lock.unlock()
        runtime?.stop()
    }

    func stopAll() {
        lock.lock()
        let values = Array(runtimes.values)
        runtimes.removeAll()
        lock.unlock()
        values.forEach { $0.stop() }
    }
}
