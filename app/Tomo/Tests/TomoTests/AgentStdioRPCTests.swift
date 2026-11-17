import Foundation
import Testing
@testable import Tomo

struct AgentStdioRPCTests {
    /// Real protocol guard, explicitly opted in and isolated from all accounts.
    /// Creates an empty thread but never starts a turn or contacts a model.
    @Test func installedChatGPTRejectsSteerWithoutActiveTurn() async throws {
        guard let path = ProcessInfo.processInfo.environment["TOMO_RPC_CONTROL_SMOKE_EXECUTABLE"] else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tomo-rpc-control-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = try AgentStdioRPC(executable: URL(fileURLWithPath: path), arguments: ["app-server", "--stdio"],
            environment: ["HOME": root.path, "CODEX_HOME": root.path,
                "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"], directory: root)
        let events = Task { for try await _ in rpc.channel.events {} }
        do {
            _ = try await rpc.channel.request(method: "initialize", params: .object([
                "clientInfo": .object(["name": .string("TomoControlGuardSmoke"), "version": .string("0.1")]),
                "capabilities": .object(["experimentalApi": .bool(false)])]))
            try await rpc.channel.notify(method: "initialized")
            let response = try await rpc.channel.request(method: "thread/start", params: .object([
                "cwd": .string(root.path), "approvalPolicy": .string("never"), "sandbox": .string("read-only")]))
            guard case .object(let fields) = response, case .object(let thread) = fields["thread"],
                  case .string(let id) = thread["id"] else { throw AgentRPCError.invalidFrame }
            do {
                _ = try await rpc.channel.request(method: "turn/steer", params: .object([
                    "threadId": .string(id), "expectedTurnId": .string(UUID().uuidString),
                    "clientUserMessageId": .string("isolated-guard-message"),
                    "input": .array([.object(["type": .string("text"), "text": .string("不应启动新回合"),
                        "text_elements": .array([])])])]))
                Issue.record("Idle thread unexpectedly accepted turn/steer")
            } catch AgentRPCError.vendor(let code, let message) {
                #expect(code == -32600)
                #expect(message.lowercased().contains("active turn"), Comment(rawValue: message))
            }
            let after = try await rpc.channel.request(method: "thread/read", params: .object([
                "threadId": .string(id), "includeTurns": .bool(false)]))
            guard case .object(let result) = after, case .object(let finalThread) = result["thread"],
                  case .array(let turns) = finalThread["turns"], case .object(let status) = finalThread["status"]
                  else { throw AgentRPCError.invalidFrame }
            #expect(turns.isEmpty)
            #expect(status["type"] == .string("idle"))
            await rpc.stop(); events.cancel(); _ = try? await events.value
        } catch {
            await rpc.stop(); events.cancel(); _ = try? await events.value
            throw error
        }
    }

    @Test func actualProcessCarriesIdleEventsRequestsRepliesAndEOF() async throws {
        let script = """
        import json, sys
        print(json.dumps({'method':'ready','params':'你好'}), flush=True)
        print(json.dumps({'id':'approval','method':'approve'}), flush=True)
        for line in sys.stdin:
            value=json.loads(line)
            if value.get('method') == 'exit': break
            if 'method' in value and 'id' in value:
                print(json.dumps({'id':value['id'],'result':value['method']}), flush=True)
            elif 'result' in value:
                print(json.dumps({'method':'approved','params':value['result']}), flush=True)
        """
        let rpc = try AgentStdioRPC(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                                   arguments: ["-u", "-c", script], environment: [:])
        var events = rpc.channel.events.makeAsyncIterator()
        #expect(try await events.next() == .notification(method: "ready", params: .string("你好")))
        #expect(try await events.next() == .request(id: .string("approval"), method: "approve", params: .null))
        #expect(try await rpc.channel.request(method: "echo") == .string("echo"))
        try await rpc.channel.reply(id: .string("approval"), result: .bool(false))
        #expect(try await events.next() == .notification(method: "approved", params: .bool(false)))
        await #expect(throws: AgentRPCError.disconnected) { try await rpc.channel.request(method: "exit") }
        await rpc.stop()
    }

    @Test func shutdownUnblocksNonReadingChildAndQueuedWrite() async throws {
        let rpc = try AgentStdioRPC(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-u", "-c", "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print('{\"method\":\"ready\"}',flush=True); time.sleep(20)"], environment: [:])
        var events = rpc.channel.events.makeAsyncIterator()
        _ = try await events.next()
        let write = Task { try await rpc.channel.notify(method: "large", params: .string(String(repeating: "x", count: 1024 * 1024))) }
        try await Task.sleep(for: .milliseconds(30))
        let clock = ContinuousClock(); let start = clock.now
        await rpc.stop()
        #expect(start.duration(to: clock.now) < .seconds(3))
        await #expect(throws: AgentRPCError.disconnected) { try await write.value }
    }

    /// Explicit opt-in uses the installed vendor executable but sends initialize
    /// only: no thread resume, turn start, user history or account read.
    @Test func installedChatGPTInitializeSmoke() async throws {
        guard let path = ProcessInfo.processInfo.environment["TOMO_RPC_SMOKE_EXECUTABLE"] else { return }
        var environment = ProcessInfo.processInfo.environment
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("tomo-rpc-smoke-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        environment["CODEX_HOME"] = temporary.path
        let rpc = try AgentStdioRPC(executable: URL(fileURLWithPath: path), arguments: ["app-server", "--stdio"], environment: environment)
        let result = try await rpc.channel.request(method: "initialize", params: .object([
            "clientInfo": .object(["name": .string("TomoProtocolSmoke"), "version": .string("0.1")]),
            "capabilities": .object(["experimentalApi": .bool(true)])
        ]))
        guard case .object(let fields) = result else { await rpc.stop(); throw AgentRPCError.invalidFrame }
        #expect(fields["userAgent"] != nil)
        try await rpc.channel.notify(method: "initialized")
        await rpc.stop()
    }
}
