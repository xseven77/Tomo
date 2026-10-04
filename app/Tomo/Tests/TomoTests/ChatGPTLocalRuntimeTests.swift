import Foundation
import CryptoKit
import Testing
@testable import Tomo

struct ChatGPTLocalRuntimeTests {
    /// Real installed CLI, isolated account and empty workspace. This checks
    /// the product coordinator's bootstrap without sending a model turn.
    @Test func installedCLICreatesAndHydratesPrivateEphemeralThread() async throws {
        guard let path = ProcessInfo.processInfo.environment["TOMO_RPC_RESUME_SMOKE_EXECUTABLE"] else {return}
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let home = root.appendingPathComponent("account"), workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let service = RemoteSessionService(serverId: "server")
        let runtime = try await ChatGPTLocalRuntime.launch(configuration: .init(executable: URL(fileURLWithPath: path), home: home,
            journalURL: root.appendingPathComponent("journal.sqlite"), runtimeId: "private-runtime"), service: service,
            environment: ["HOME": root.path, "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                          "XDG_CONFIG_HOME": root.appendingPathComponent("config").path])
        do {
            try await runtime.createOwnedEphemeralSession(sessionId: "private-session", workspace: workspace)
            try await runtime.attach(sessionId: "private-session")
            let access = RemoteAccessStore(); await access.setDevelopmentEnabled(true)
            let ledger = try RemoteOperationStore(databaseURL: root.appendingPathComponent("operations.sqlite"))
            let operations = RemoteOperationService(serverId: "server", access: access, store: ledger) {_ in
                RemoteOperationOwner(userId: "local", deviceId: "test-device")}
            let ref = try await runtime.publishOwnedControl(sessionId: "private-session", operations: operations, allowSteer: false)
            let principal = RemoteAccessStore.Principal(id: UUID(), expiresAt: Date().addingTimeInterval(60),
                scopes: [.init(agentId: "agent.chatgpt", runtimeId: "private-runtime", sessionId: "private-session",
                               actions: [.readHistory, .sendMessage])], origin: nil, generation: 1)
            let state = try JSONDecoder().decode(RemoteSessionControl.self,
                from: try await service.sync(sessionId: ref.sessionId, query: [:], principal: principal))
            #expect(state.state == "idle" && state.allowedActions.contains("message.send"))
            #expect(await runtime.currentState() == .ready)
            await runtime.stop(); await operations.shutdown()
        } catch { await runtime.stop(); throw error }
    }

    /// Explicit opt-in resumes only a synthetic, completed legacy rollout in
    /// an isolated HOME. No account/login/turn/start or user session is used.
    @Test func installedCLIResumesIsolatedSyntheticHistoryAndPublishesItsBaseline() async throws {
        guard let path = ProcessInfo.processInfo.environment["TOMO_RPC_RESUME_SMOKE_EXECUTABLE"] else {return}
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let home = root.appendingPathComponent("account"), workspace = root.appendingPathComponent("workspace")
        let now = Date(), vendorID = UUID().uuidString.lowercased(), turnID = UUID().uuidString.lowercased()
        let digest = SHA256.hash(data: Data("isolated-runtime\u{0}\(vendorID)".utf8)).map {String(format: "%02x", $0)}.joined()
        let sessionId = "ss_" + String(digest.prefix(32))
        let stamp = ISO8601DateFormatter().string(from: now)
        let components = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: now)
        let day = String(format: "%04d/%02d/%02d", components.year!, components.month!, components.day!)
        let folder = home.appendingPathComponent("sessions/" + day)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let rollout = folder.appendingPathComponent("rollout-\(stamp.replacingOccurrences(of: ":", with: "-"))-\(vendorID).jsonl")
        let rows: [(String, [String: Any])] = [
            ("session_meta", ["id": vendorID, "timestamp": stamp, "cwd": workspace.path, "originator": "tomo-isolated-fixture", "cli_version": "0.153.4", "source": "cli", "model_provider": "openai"]),
            ("event_msg", ["type": "task_started", "turn_id": turnID, "model_context_window": NSNull()]),
            ("event_msg", ["type": "user_message", "message": "合成历史用户消息", "images": [], "local_images": [], "text_elements": []]),
            ("response_item", ["type": "message", "role": "user", "content": [["type": "input_text", "text": "合成历史用户消息"]]]),
            ("response_item", ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "合成历史回复"]]]),
            ("event_msg", ["type": "agent_message", "message": "合成历史回复", "phase": "final_answer"]),
            ("event_msg", ["type": "task_complete", "turn_id": turnID, "last_agent_message": "合成历史回复"])
        ]
        var bytes = Data()
        for (type, payload) in rows {
            bytes.append(try JSONSerialization.data(withJSONObject: ["timestamp": stamp, "type": type, "payload": payload])); bytes.append(10)
        }
        try bytes.write(to: rollout)
        let server = MobileSyncServer(port: 59436, token: "isolated-pairing", listenOnLoopbackOnly: true,
            dataProvider: MobileSyncServerTests.MockDataProvider())
        defer {server.stop()}
        let service = server.remoteSessionService
        let runtime = try await ChatGPTLocalRuntime.launch(configuration: .init(executable: URL(fileURLWithPath: path), home: home,
            journalURL: root.appendingPathComponent("journal.sqlite"), runtimeId: "isolated-runtime"), service: service,
            environment: ["HOME": root.path, "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin", "XDG_CONFIG_HOME": root.appendingPathComponent("config").path])
        do {
            try await runtime.resumeOwnedSession(sessionId: sessionId, vendorThreadId: vendorID)
            let directory = ChatGPTSessionDirectory(databaseURL: home.appendingPathComponent("state_5.sqlite"), storageRoot: home, runtimeId: "isolated-runtime")
            var indexed = false
            for _ in 0..<100 {
                if (try? directory.snapshot().entries.contains { $0.sessionId == sessionId && $0.vendorSessionId == vendorID }) == true {indexed = true; break}
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(indexed)
            try await server.remoteReadService.register(ChatGPTReadAdapter(directory: directory, runtimeLabel: "隔离测试账号"))
            try await runtime.attach(sessionId: sessionId)
            let principal = RemoteAccessStore.Principal(id: UUID(), expiresAt: Date().addingTimeInterval(60),
                scopes: [.init(agentId: "agent.chatgpt", runtimeId: "isolated-runtime", sessionId: sessionId, actions: [.readHistory])], origin: nil, generation: 1)
            let data = try await service.sync(sessionId: sessionId, query: [:], principal: principal)
            let result = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let messages = try #require(result["messages"] as? [[String: Any]])
            #expect(messages.count == 2)
            #expect(messages.compactMap { $0["role"] as? String } == ["user", "assistant"])
            let text = String(decoding: data, as: UTF8.self)
            #expect(text.contains("合成历史用户消息") && text.contains("合成历史回复"))
            #expect(!text.contains(vendorID) && !text.contains(workspace.path))
            await server.remoteAccess.setDevelopmentEnabled(true)
            let issued = try await server.remoteAccess.issueDevelopment(scopes: [
                .init(agentId: "agent.chatgpt", runtimeId: "isolated-runtime", sessionId: nil, actions: [.listSessions]),
                .init(agentId: "agent.chatgpt", runtimeId: "isolated-runtime", sessionId: sessionId, actions: [.readHistory])
            ], origin: nil)
            try server.start()
            for _ in 0..<100 {
                if server.status == .ready {break}
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(server.status == .ready)
            let http = URLSession(configuration: .ephemeral)
            defer {http.invalidateAndCancel()}
            var request = URLRequest(url: URL(string: "http://127.0.0.1:59436/api/v1/remote/sessions/\(sessionId)/sync")!)
            request.timeoutInterval = 5; request.setValue("Bearer " + issued.token, forHTTPHeaderField: "Authorization")
            let (wireData, response) = try await http.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            let wireResult = try #require(JSONSerialization.jsonObject(with: wireData) as? [String: Any])
            #expect(NSDictionary(dictionary: wireResult).isEqual(to: result))
            let cursor = try #require(result["eventCursor"] as? String)
            var listingRequest = request
            listingRequest.url = URL(string: "http://127.0.0.1:59436/api/v1/remote/sessions?agent_id=agent.chatgpt&runtime_id=isolated-runtime")!
            let (listingData, listingResponse) = try await http.data(for: listingRequest)
            #expect((listingResponse as? HTTPURLResponse)?.statusCode == 200)
            let listing = try #require(JSONSerialization.jsonObject(with: listingData) as? [String: Any])
            let items = try #require(listing["items"] as? [[String: Any]])
            #expect(items.contains { $0["sessionId"] as? String == sessionId })
            #expect(!String(decoding: listingData, as: UTF8.self).contains(vendorID))
            request.url = URL(string: "http://127.0.0.1:59436/api/v1/remote/sessions/\(sessionId)/events")!
            request.setValue(cursor, forHTTPHeaderField: "Last-Event-ID")
            let (_, streamResponse) = try await http.bytes(for: request)
            #expect((streamResponse as? HTTPURLResponse)?.statusCode == 200)
            #expect(server.remoteStreamCount == 1)
            http.invalidateAndCancel()
            for _ in 0..<100 {
                if server.remoteStreamCount == 0 {break}
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(server.remoteStreamCount == 0)
            // A real resumed, completed thread remains non-sendable even when
            // its local owner explicitly grants steer. A grant is not proof of
            // an active turn or permission to implicitly create one.
            let controlGrant = try await server.remoteAccess.issueDevelopment(scopes: [
                .init(agentId: "agent.chatgpt", runtimeId: "isolated-runtime", sessionId: sessionId,
                    actions: [.readHistory, .sendMessage, .interrupt])], origin: nil)
            let ledger = try RemoteOperationStore(databaseURL: root.appendingPathComponent("operations.sqlite"))
            let operations = RemoteOperationService(serverId: await service.serverId,
                access: server.remoteAccess, store: ledger) {_ in
                    RemoteOperationOwner(userId: "isolated-owner", deviceId: "isolated-phone")
                }
            do {
                _ = try await runtime.publishOwnedControl(sessionId: sessionId, operations: operations, allowSteer: true)
                let control = try JSONDecoder().decode(RemoteSessionControl.self,
                    from: try await service.sync(sessionId: sessionId, query: [:], principal: controlGrant.principal))
                #expect(control.currentTurnId == nil)
                #expect(!control.allowedActions.contains("message.send"))
                #expect(!control.allowedActions.contains("turn.interrupt"))
                await operations.shutdown()
            } catch { await operations.shutdown(); throw error }
            await runtime.stop()
            await #expect(throws: RemoteReadError.notFound) {try await service.sync(sessionId: sessionId, query: [:], principal: principal)}
        } catch {await runtime.stop(); throw error}
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tomo-local-runtime-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func accountScopedProcessPerformsResumeThenPublishesFilteredHistory() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let home = root.appendingPathComponent("account")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("synthetic-agent")
        let script = """
        #!/usr/bin/python3
        import json,os,sys
        assert sys.argv[1:] == ['app-server','--stdio']
        resumed=False
        for line in sys.stdin:
            frame=json.loads(line)
            method=frame.get('method')
            if method=='initialized': continue
            if method=='initialize': result={'userAgent':'synthetic-process'}
            elif method=='thread/resume':
                assert frame['params']=={'threadId':'private-thread','excludeTurns':True}
                resumed=True
                result={'thread':{'id':'private-thread'}}
            elif method=='thread/read':
                assert resumed
                turn={'id':'turn','status':'completed','itemsView':'full','items':[{'id':'answer','type':'agentMessage','text':'独立账号回复'}]}
                result={'thread':{'id':'private-thread','createdAt':100,'updatedAt':200,'status':{'type':'idle'},'turns':[turn] if frame['params']['includeTurns'] else []}}
            else: raise RuntimeError('unexpected method')
            assert os.environ['CODEX_HOME']==\(String(reflecting: home.path))
            print(json.dumps({'id':frame['id'],'result':result}),flush=True)
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let service = RemoteSessionService(serverId: "server")
        let runtime = try await ChatGPTLocalRuntime.launch(configuration: .init(executable: executable, home: home,
            journalURL: root.appendingPathComponent("events.sqlite"), runtimeId: "account-runtime"), service: service)
        try await runtime.resumeOwnedSession(sessionId: "opaque-session", vendorThreadId: "private-thread")
        try await runtime.attach(sessionId: "opaque-session")
        let principal = RemoteAccessStore.Principal(id: UUID(), expiresAt: Date().addingTimeInterval(60),
            scopes: [.init(agentId: "agent.chatgpt", runtimeId: "account-runtime", sessionId: "opaque-session", actions: [.readHistory])], origin: nil, generation: 1)
        let data = try await service.sync(sessionId: "opaque-session", query: [:], principal: principal)
        let wire = String(decoding: data, as: UTF8.self)
        #expect(wire.contains("独立账号回复") && !wire.contains("private-thread") && !wire.contains(home.path))
        await runtime.stop()
        #expect(await runtime.currentState() == .stopped)
        await #expect(throws: RemoteReadError.notFound) {try await service.sync(sessionId: "opaque-session", query: [:], principal: principal)}
    }

    @Test func invalidLocalConfigurationCannotStartOrCreateAJournal() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let journal = root.appendingPathComponent("events.sqlite")
        let service = RemoteSessionService(serverId: "server")
        await #expect(throws: (any Error).self) {
            try await ChatGPTLocalRuntime.launch(configuration: .init(executable: root, home: root,
                journalURL: journal, runtimeId: "runtime"), service: service)
        }
        #expect(!FileManager.default.fileExists(atPath: journal.path))
    }
}
