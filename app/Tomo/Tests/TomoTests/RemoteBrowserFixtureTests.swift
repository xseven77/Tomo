import Foundation
import SQLite3
import Testing
@testable import Tomo

/// Synthetic subscribed adapter for the opt-in browser fixture only.
private actor BrowserRuntimeRPC {
    var channel: AgentRPCChannel?
    private let receiptDelay: Int
    init(receiptDelay: Int = 0) {self.receiptDelay = min(2000, max(0, receiptDelay))}
    private var texts: [String: String] = [:]
    private var completed = Set<String>()
    private var interrupted = Set<String>()
    private(set) var interrupts = 0
    private(set) var steers = 0
    private var additions: [String: [AgentJSON]] = [:]
    func configure(_ channel: AgentRPCChannel) { self.channel = channel }
    func stop() async { await channel?.close(); channel = nil }
    func write(_ data: Data) async throws {
        guard case .object(let frame) = try JSONDecoder().decode(AgentJSON.self, from: data), let id = frame["id"], case .string(let method) = frame["method"] else { return }
        let result: AgentJSON
        if method == "initialize" { result = .object(["userAgent": .string("synthetic-browser-fixture")]) }
        else if method == "thread/resume", case .object(let params) = frame["params"], case .string(let thread) = params["threadId"],
                ["fixture-31", "fixture-32"].contains(thread) {
            result = .object(["thread": .object(["id": .string(thread)])])
        }
        else if method == "turn/steer", case .object(let params) = frame["params"], case .string(let thread) = params["threadId"],
                thread == "fixture-31", params["expectedTurnId"] == .string("turn_" + thread), !completed.contains(thread),
                case .string(let client) = params["clientUserMessageId"], case .array(let input) = params["input"] {
            steers += 1
            if receiptDelay > 0 {try await Task.sleep(for: .milliseconds(receiptDelay))}
            let item = AgentJSON.object(["id": .string(client), "type": .string("userMessage"), "content": .array(input)])
            additions[thread, default: []].append(item)
            try await event("item/completed", params: ["threadId": .string(thread), "turnId": .string("turn_" + thread), "item": item])
            result = .object(["turnId": .string("turn_" + thread)])
        }
        else if method == "turn/interrupt", case .object(let params) = frame["params"], case .string(let thread) = params["threadId"],
                params["turnId"] == .string("turn_" + thread), !completed.contains(thread) {
            interrupts += 1; completed.insert(thread); interrupted.insert(thread)
            texts[thread] = "手机中断已确认，测试会话已停止 🐾"
            try await event("turn/completed", params: ["threadId": .string(thread), "turn": turn(thread, done: true)])
            result = .object([:])
        }
        else if method == "thread/read", case .object(let params) = frame["params"], case .string(let thread) = params["threadId"] {
            let done = completed.contains(thread)
            result = .object(["thread": .object(["id": .string(thread), "createdAt": .integer(100), "updatedAt": .integer(200),
                "status": .object(["type": .string(done ? "idle" : "active"), "activeFlags": .array([])]),
                "turns": .array([turn(thread, done: done)])])])
        } else { throw AgentRPCError.invalidFrame }
        var reply = try JSONEncoder().encode(AgentJSON.object(["id": id, "result": result])); reply.append(10)
        try await channel?.receive(reply)
    }
    private func turn(_ thread: String, done: Bool) -> AgentJSON {
        .object(["id": .string("turn_" + thread), "status": .string(interrupted.contains(thread) ? "interrupted" : done ? "completed" : "inProgress"), "itemsView": .string("full"),
            "items": .array([
                .object(["id": .string("user"), "type": .string("userMessage"), "content": .array([.object(["type": .string("text"), "text": .string("验证实时会话 " + thread)])])]),
                .object(["id": .string("answer"), "type": .string("agentMessage"), "text": .string(texts[thread] ?? "初始回复")])] + (additions[thread] ?? []))])
    }
    func delta(_ thread: String) async throws {
        texts[thread] = (texts[thread] ?? "初始回复") + " · 实时追加中文 🐾"
        try await event("item/agentMessage/delta", params: ["threadId": .string(thread), "turnId": .string("turn_" + thread), "itemId": .string("answer"), "delta": .string(" · 实时追加中文 🐾")])
    }
    func complete(_ thread: String) async throws {
        texts[thread] = "完整最终回复，实时同步完成 🐾"; completed.insert(thread)
        try await event("turn/completed", params: ["threadId": .string(thread), "turn": turn(thread, done: true)])
    }
    private func event(_ method: String, params: [String: AgentJSON]) async throws {
        var data = try JSONEncoder().encode(AgentJSON.object(["method": .string(method), "params": .object(params)])); data.append(10)
        try await channel?.receive(data)
    }
}

/// Opt-in manual browser integration fixture. All data is synthetic. It uses
/// the real desktop listener, auth store, SQLite adapter and JSONL reader.
struct RemoteBrowserFixtureTests {
    @Test func serveBrowserFixtureWhenExplicitlyRequested() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TOMO_REMOTE_BROWSER_FIXTURE"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("state_5.sqlite")
        var pointer: OpaquePointer?
        guard sqlite3_open(database.path, &pointer) == SQLITE_OK, let db = pointer else { throw ChatGPTDirectoryError.unavailable }
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "CREATE TABLE threads (id TEXT, rollout_path TEXT, title TEXT, updated_at INTEGER)", nil, nil, nil) == SQLITE_OK)
        for index in 1...32 {
            let file = root.appendingPathComponent("session-\(index).jsonl")
            var data = Data()
            func append(_ object: [String: Any]) throws { data.append(try JSONSerialization.data(withJSONObject: object)); data.append(10) }
            try append(["type": "session_meta", "payload": ["id": "fixture-\(index)"]])
            for message in 1...55 {
                try append(["type": "response_item", "timestamp": "2026-10-03T00:00:00Z", "payload": ["type": "message", "role": message % 2 == 0 ? "assistant" : "user", "content": [["type": "input_text", "text": "测试会话 \(index) · 消息 \(message)"]]]])
            }
            try data.write(to: file)
            let path = file.path.replacingOccurrences(of: "'", with: "''")
            #expect(sqlite3_exec(db, "INSERT INTO threads VALUES ('fixture-\(index)', '\(path)', '联调会话 \(index)', \(index))", nil, nil, nil) == SQLITE_OK)
        }
        let server = MobileSyncServer(port: 59406, token: "browser-fixture-pairing", listenOnLoopbackOnly: true, dataProvider: MobileSyncServerTests.MockDataProvider())
        try await server.remoteReadService.register(ChatGPTReadAdapter(directory: .init(databaseURL: database, storageRoot: root, runtimeId: "rt_fixture"), runtimeLabel: "联调存储域"))
        var liveRuntime: ChatGPTRuntimeCoordinator?
        var liveRPC: BrowserRuntimeRPC?
        var operations: RemoteOperationService?
        var controlRef: RemoteSessionRef?
        let steer = ProcessInfo.processInfo.environment["TOMO_REMOTE_BROWSER_STEER"] == "1"
        let control = ProcessInfo.processInfo.environment["TOMO_REMOTE_BROWSER_CONTROL"] == "1" || steer
        if ProcessInfo.processInfo.environment["TOMO_REMOTE_BROWSER_LIVE"] == "1" || control {
            let rpc = BrowserRuntimeRPC(receiptDelay: Int(ProcessInfo.processInfo.environment["TOMO_REMOTE_BROWSER_RECEIPT_DELAY_MS"] ?? "0") ?? 0), channel = AgentRPCChannel(writer: {try await rpc.write($0)})
            await rpc.configure(channel)
            let journal = try RemoteSessionJournal(databaseURL: root.appendingPathComponent("events.sqlite"))
            let serverId = await server.remoteSessionService.serverId
            let runtime = try ChatGPTRuntimeCoordinator(serverId: serverId, runtimeId: "rt_fixture", channel: channel,
                journal: journal, service: server.remoteSessionService, stopTransport: {await rpc.stop()})
            try await runtime.start()
            let entries = try ChatGPTSessionDirectory(databaseURL: database, storageRoot: root, runtimeId: "rt_fixture").snapshot().entries
            for entry in entries where ["fixture-31", "fixture-32"].contains(entry.vendorSessionId) {
                if control {try await runtime.resumeOwnedSession(sessionId: entry.sessionId, vendorThreadId: entry.vendorSessionId)}
                else {try await runtime.registerSubscription(sessionId: entry.sessionId, vendorThreadId: entry.vendorSessionId)}
                try await runtime.attach(sessionId: entry.sessionId)
                if control && entry.vendorSessionId == "fixture-31" {
                    let store = try RemoteOperationStore(databaseURL: root.appendingPathComponent("operations.sqlite"))
                    let service = RemoteOperationService(serverId: serverId, access: server.remoteAccess, store: store) {
                        .init(userId: "browser-fixture-owner", deviceId: $0.id.uuidString)
                    }
                    try server.installRemoteOperationService(service)
                    controlRef = try await runtime.publishOwnedControl(sessionId: entry.sessionId, operations: service, allowSteer: steer)
                    operations = service
                }
            }
            liveRuntime = runtime; liveRPC = rpc
        }
        await server.remoteAccess.setDevelopmentEnabled(true)
        var scopes: [RemoteAccessStore.Scope] = [.init(agentId: "agent.chatgpt", runtimeId: "rt_fixture", sessionId: nil, actions: [.listSessions, .readHistory])]
        if let controlRef {scopes.append(.init(agentId: controlRef.agentId, runtimeId: controlRef.runtimeId, sessionId: controlRef.sessionId,
            actions: steer ? [.interrupt, .sendMessage] : [.interrupt]))}
        let devOrigin = ProcessInfo.processInfo.environment["TOMO_REMOTE_BROWSER_ORIGIN"] ?? "http://127.0.0.1:5200"
        let issued = try await server.remoteAccess.issueDevelopment(scopes: scopes, origin: devOrigin)
        try server.start()
        defer { server.stop() }
        for _ in 0..<100 {
            if server.status == .ready { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(server.status == .ready)
        let exported = try JSONSerialization.data(withJSONObject: [
            "serverURL": "http://127.0.0.1:59406",
            "token": issued.token,
            "origin": devOrigin,
            "expiresAt": ISO8601DateFormatter().string(from: issued.principal.expiresAt),
            "mode": control ? "development-control" : "development-read-only"
        ])
        let config = root.appendingPathComponent("connection.json")
        try exported.write(to: config)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        print("Browser fixture ready on 59406; synthetic data only")
        let duration = min(1200, max(60, Int(ProcessInfo.processInfo.environment["TOMO_REMOTE_BROWSER_SECONDS"] ?? "240") ?? 240))
        for _ in 0..<duration {
            if let liveRPC {
                for index in [31, 32] {
                    for action in ["delta", "complete"] {
                        let command = root.appendingPathComponent("\(action)-\(index)")
                        if FileManager.default.fileExists(atPath: command.path) {
                            try FileManager.default.removeItem(at: command)
                            if action == "delta" {try await liveRPC.delta("fixture-\(index)")}
                            else {try await liveRPC.complete("fixture-\(index)")}
                        }
                    }
                }
            }
            try JSONSerialization.data(withJSONObject: ["streams": server.remoteStreamCount, "interrupts": await liveRPC?.interrupts ?? 0,
                "steers": await liveRPC?.steers ?? 0]).write(to: root.appendingPathComponent("status.json"), options: .atomic)
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("revoke").path) {
                await server.remoteAccess.revoke(issued.principal)
            }
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("stop").path) { break }
            try await Task.sleep(for: .seconds(1))
        }
        await liveRuntime?.stop()
        await operations?.shutdown()
        server.stop()
        try JSONSerialization.data(withJSONObject: ["streams": server.remoteStreamCount, "stopped": true]).write(to: root.appendingPathComponent("status.json"), options: .atomic)
        try? FileManager.default.removeItem(at: config)
    }
}
