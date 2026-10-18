import XCTest
import SQLite3
@testable import Tomo

private actor OwnedLaunchGate {
    private var release: CheckedContinuation<Void, Never>?, observer: CheckedContinuation<Void, Never>?
    private(set) var runtime: ChatGPTRuntimeCoordinator?
    func hold(_ value: ChatGPTRuntimeCoordinator) async {
        runtime = value
        await withCheckedContinuation { release = $0; observer?.resume(); observer = nil }
    }
    func wait() async { if runtime != nil { return }; await withCheckedContinuation { observer = $0 } }
    func resume() { release?.resume(); release = nil }
}

@MainActor final class RemoteOwnedChatGPTServiceTests: XCTestCase {
    func testNewPrivateSessionUsesJournalHistoryAndExactWorkspaceAuthorization() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("owned-new-" + UUID().uuidString)
        let home = root.appendingPathComponent("account"), workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer {try? FileManager.default.removeItem(at: root)}
        let executable = root.appendingPathComponent("synthetic-agent")
        let script = """
        #!/usr/bin/python3
        import json,os,sys
        assert sys.argv[1:]==['app-server','--stdio']
        assert os.environ['CODEX_HOME']==\(String(reflecting: home.path))
        for line in sys.stdin:
            frame=json.loads(line); method=frame.get('method')
            if method=='initialized': continue
            if method=='initialize': result={'userAgent':'private-synthetic'}
            elif method=='thread/start':
                assert frame['params']=={'ephemeral':True,'cwd':\(String(reflecting: workspace.path))}
                result={'thread':{'id':'private-thread','ephemeral':True,'path':None,'cwd':\(String(reflecting: workspace.path))}}
            elif method=='thread/read':
                assert frame['params']['includeTurns']==False
                result={'thread':{'id':'private-thread','ephemeral':True,'path':None,'createdAt':1,'updatedAt':100,'status':{'type':'idle'},'turns':[]}}
            elif method=='turn/start':
                assert frame['params']['threadId']=='private-thread'
                result={'turn':{'id':'turn','status':'completed','items':[]}}
                event={'method':'turn/completed','params':{'threadId':'private-thread','turn':{
                    'id':'turn','status':'completed','items':[
                        {'id':'user','type':'userMessage','content':[{'type':'text','text':'hello'}]},
                        {'id':'answer','type':'agentMessage','text':'合成回答'}]}}}
            else: raise RuntimeError('unexpected method: '+str(method))
            print(json.dumps({'id':frame['id'],'result':result}),flush=True)
            if method=='turn/start': print(json.dumps(event),flush=True)
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let registry = RemoteRuntimeScopeRegistry(), sessions = RemoteSessionService(serverId: "server")
        let reads = RemoteReadService(serverId: "server", authorizationRegistry: registry), access = RemoteAccessStore()
        await access.setDevelopmentEnabled(true)
        let store = try RemoteOperationStore(databaseURL: root.appendingPathComponent("operations.sqlite"))
        let operations = RemoteOperationService(serverId: "server", access: access, store: store) {_ in
            RemoteOperationOwner(userId: "local", deviceId: "phone")}
        let adapter = ChatGPTReadAdapter(directory: .init(databaseURL: home.appendingPathComponent("absent.sqlite"),
            storageRoot: home, runtimeId: "account"), runtimeLabel: "隔离账号")
        let owned = RemoteOwnedChatGPTService(sources: [adapter], directory: root.appendingPathComponent("journals"),
            reads: reads, sessions: sessions, operations: operations)
        do {
            let accounts = try await owned.accounts()
            XCTAssertEqual(accounts.map(\.id), ["account"])
            let created = try await owned.create(sourceRuntimeId: "account", workspace: workspace, executable: executable)
            let available = try await registry.ownerRuntimes()
            XCTAssertEqual(available.count, 1)
            XCTAssertEqual(available.first?.runtimeId, created.id)
            XCTAssertTrue(available.first?.actions.contains(.sendMessage) == true)
            XCTAssertTrue(available.first?.actions.contains(.approve) == true)
            XCTAssertTrue(available.first?.actions.contains(.answer) == true)
            XCTAssertTrue(RemoteProductionService.ownerScopes(available).contains("session.approve"))
            let principal = try await access.issueDevelopment(scopes: [
                .init(agentId: "agent.chatgpt", runtimeId: created.id, sessionId: nil, actions: [.listSessions]),
                .init(agentId: "agent.chatgpt", runtimeId: created.id, sessionId: created.sessionId,
                    actions: [.readHistory, .sendMessage])], origin: nil).principal
            let listing = try await reads.sessions(principal: principal, agentId: "agent.chatgpt", runtimeId: created.id)
            XCTAssertEqual(listing.items.map(\.sessionId), [created.sessionId])
            let history = try await reads.history(principal: principal, agentId: "agent.chatgpt", runtimeId: created.id,
                sessionId: created.sessionId)
            XCTAssertTrue(history.messages.isEmpty)
            let query = ["agent_id": "agent.chatgpt", "runtime_id": created.id]
            let control = try JSONDecoder().decode(RemoteSessionControl.self,
                from: try await sessions.sync(sessionId: created.sessionId, query: query, principal: principal))
            XCTAssertTrue(control.allowedActions.contains("message.send"))
            let body = try JSONEncoder().encode(AgentJSON.object([
                "executionEpoch": .string(control.executionEpoch), "clientMessageId": .string("hello-1"),
                "mode": .string("start"), "expectedControlRevision": .integer(Int64(control.controlRevision)),
                "input": .array([.object(["type": .string("text"), "text": .string("hello")])])]))
            let accepted = try await operations.submit(sessionId: created.sessionId, query: query, action: .sendMessage,
                key: UUID().uuidString, body: body, principal: principal)
            let ref = RemoteSessionRef(serverId: "server", agentId: "agent.chatgpt", runtimeId: created.id,
                                       sessionId: created.sessionId)
            var applied = false
            for _ in 0..<100 {
                applied = try await store.operation(id: accepted.operationId,
                    owner: .init(userId: "local", deviceId: "phone"), ref: ref).state == .applied
                if applied {break}
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(applied)
            var visible: [RemoteHistoryMessage] = []
            for _ in 0..<100 {
                visible = try await reads.history(principal: principal, agentId: "agent.chatgpt", runtimeId: created.id,
                    sessionId: created.sessionId).messages
                if visible.count == 2 {break}
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(visible.map(\.role), ["user", "assistant"])
            XCTAssertEqual(visible.last?.content.first?.text, "合成回答")
            await owned.stop()
            let remaining = try await registry.ownerRuntimes()
            XCTAssertTrue(remaining.isEmpty)
            await operations.shutdown()
        } catch {await owned.stop(); await operations.shutdown(); throw error}
    }

    func testDedicatedStdioRuntimeSteersAndPublishesReplyWithoutBroadeningDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("owned-runtime-" + UUID().uuidString)
        let home = root.appendingPathComponent("account")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rollout = home.appendingPathComponent("rollout.jsonl")
        try Data("{}\n".utf8).write(to: rollout)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        let database = try XCTUnwrap(db); defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE threads(id TEXT,rollout_path TEXT,title TEXT,updated_at INTEGER); INSERT INTO threads VALUES('private-thread','\(rollout.path)','本机选定会话',100)", nil, nil, nil), SQLITE_OK)
        let executable = root.appendingPathComponent("synthetic-agent")
        let script = """
        #!/usr/bin/python3
        import json,os,sys
        assert sys.argv[1:]==['app-server','--stdio']
        assert os.environ['CODEX_HOME']==\(String(reflecting: home.path))
        resumed=False
        for line in sys.stdin:
            frame=json.loads(line); method=frame.get('method'); event=None
            if method is None:
                if frame['id']=='private-question-callback':
                    assert frame['result']=={'answers':{'private-question':{'answers':['保持现状']}}}
                    print(json.dumps({'method':'serverRequest/resolved','params':{'threadId':'private-thread','requestId':frame['id']}}),flush=True)
                    print(json.dumps({'id':'private-approval-callback','method':'item/commandExecution/requestApproval','params':{
                        'threadId':'private-thread','turnId':'turn','itemId':'private-command','startedAtMs':100,
                        'command':'git status --short','cwd':'/synthetic/workspace','availableDecisions':['accept','decline']}}),flush=True)
                elif frame['id']=='private-approval-callback':
                    assert frame['result']=={'decision':'decline'}
                    print(json.dumps({'method':'serverRequest/resolved','params':{'threadId':'private-thread','requestId':frame['id']}}),flush=True)
                    print(json.dumps({'method':'item/agentMessage/delta','params':{'threadId':'private-thread','turnId':'turn',
                        'itemId':'answer','delta':'合成请求已答复'}}),flush=True)
                else: raise RuntimeError('unexpected callback: '+str(frame))
                continue
            if method=='initialized': continue
            if method=='initialize': result={'userAgent':'owned-synthetic'}
            elif method=='thread/resume':
                assert frame['params']=={'threadId':'private-thread','excludeTurns':True}
                resumed=True; result={'thread':{'id':'private-thread'}}
            elif method=='thread/read':
                assert resumed
                turn={'id':'turn','status':'inProgress','itemsView':'full','items':[{'id':'answer','type':'agentMessage','text':'合成基线'}]}
                result={'thread':{'id':'private-thread','createdAt':1,'updatedAt':100,'status':{'type':'active','activeFlags':[]},'turns':[turn]}}
            elif method=='turn/steer':
                assert frame['params']['threadId']=='private-thread'
                assert frame['params']['expectedTurnId']=='turn'
                assert frame['params']['input'][0]['text']=='继续这个活动回合'
                result={'turnId':'turn'}
                event={'method':'item/agentMessage/delta','params':{'threadId':'private-thread','turnId':'turn','itemId':'answer','delta':'合成进程回复'}}
            else: raise RuntimeError('unexpected method: '+str(method))
            print(json.dumps({'id':frame['id'],'result':result}),flush=True)
            if event: print(json.dumps(event),flush=True)
            if method=='turn/steer':
                print(json.dumps({'id':'private-question-callback','method':'item/tool/requestUserInput','params':{
                    'threadId':'private-thread','turnId':'turn','itemId':'private-question-item','isBlocking':True,
                    'questions':[{'id':'private-question','header':'方案','question':'请选择方案','options':[
                        {'label':'保持现状','description':'不修改当前配置'},{'label':'迁移','description':'改用新配置'}]}]}}),flush=True)
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let serverId = "server", registry = RemoteRuntimeScopeRegistry(), sessions = RemoteSessionService(serverId: "server")
        let reads = RemoteReadService(serverId: serverId, authorizationRegistry: registry), access = RemoteAccessStore()
        await access.setDevelopmentEnabled(true)
        let owner = RemoteOperationOwner(userId: "test-user", deviceId: "test-device")
        let store = try RemoteOperationStore(databaseURL: root.appendingPathComponent("operations.sqlite"))
        let operations = RemoteOperationService(serverId: serverId, access: access, store: store, identity: { _ in owner })
        let adapter = ChatGPTReadAdapter(directory: .init(databaseURL: home.appendingPathComponent("state_5.sqlite"), storageRoot: home, runtimeId: "directory"), runtimeLabel: "Account")
        try await reads.register(adapter)
        let owned = RemoteOwnedChatGPTService(sources: [adapter], directory: root.appendingPathComponent("journals"), reads: reads, sessions: sessions, operations: operations)
        do {
            let choices = try await owned.choices()
            let choice = try XCTUnwrap(choices.first)
            let live = try await owned.attach(sourceRuntimeId: choice.sourceRuntimeId, sessionId: choice.sessionId, executable: executable, allowSteer: true)
            do { _ = try await owned.attach(sourceRuntimeId: choice.sourceRuntimeId, sessionId: choice.sessionId, executable: executable, allowSteer: true); XCTFail("Duplicate vendor thread accepted") }
            catch { XCTAssertEqual(error as? ChatGPTRuntimeError, .duplicateSession) }
            let runtimes = try await registry.ownerRuntimes()
            XCTAssertEqual(runtimes.first { $0.runtimeId == "directory" }?.actions, [.listSessions, .readHistory])
            XCTAssertFalse(RemoteProductionService.ownerScopes(runtimes.filter { $0.runtimeId == "directory" }).contains("session.approve"))
            XCTAssertTrue(RemoteProductionService.ownerScopes(runtimes.filter { $0.runtimeId == live.id }).contains("session.approve"))
            XCTAssertTrue(try XCTUnwrap(runtimes.first { $0.runtimeId == live.id }).actions.contains(.sendMessage))
            // Even an overbroad client scope cannot turn the host history index
            // into an owned executor just because the shared descriptor lists
            // the agent's send/interrupt capabilities.
            let directoryPrincipal = try await access.issueDevelopment(scopes: [.init(agentId: "agent.chatgpt", runtimeId: "directory",
                sessionId: nil, actions: [.listSessions, .readHistory, .sendMessage, .interrupt, .approve, .answer])], origin: nil).principal
            let directoryCatalog = await reads.catalog(principal: directoryPrincipal, client: .v1)
            XCTAssertEqual(directoryCatalog.runtimes.first?.controlMode, "readOnly")
            XCTAssertEqual(Set(directoryCatalog.runtimes.first?.allowedActions ?? []), ["sessions.list", "history.read"])
            let directorySessions = try await reads.sessions(principal: directoryPrincipal, agentId: "agent.chatgpt", runtimeId: "directory")
            XCTAssertTrue(directorySessions.items.allSatisfy { $0.controlMode == "readOnly" && $0.allowedActions == ["history.read"] })
            let principal = try await access.issueDevelopment(scopes: [.init(agentId: "agent.chatgpt", runtimeId: live.id, sessionId: live.sessionId,
                actions: [.readHistory, .sendMessage, .interrupt, .approve, .answer])], origin: nil).principal
            let noApproval = try await access.issueDevelopment(scopes: [.init(agentId: "agent.chatgpt", runtimeId: live.id, sessionId: live.sessionId,
                actions: [.readHistory, .sendMessage, .interrupt])], origin: nil).principal
            let query = ["agent_id": "agent.chatgpt", "runtime_id": live.id]
            let before = try JSONDecoder().decode(RemoteSessionControl.self, from: try await sessions.sync(sessionId: live.sessionId, query: query, principal: principal))
            XCTAssertTrue(before.allowedActions.contains("message.send"))
            let body = try JSONEncoder().encode(AgentJSON.object(["executionEpoch": .string(before.executionEpoch), "clientMessageId": .string("client-1"),
                "mode": .string("steer"), "expectedControlRevision": .integer(Int64(before.controlRevision)), "expectedTurnId": .string(try XCTUnwrap(before.currentTurnId)),
                "input": .array([.object(["type": .string("text"), "text": .string("继续这个活动回合")])])]))
            let accepted = try await operations.submit(sessionId: live.sessionId, query: query, action: .sendMessage, key: UUID().uuidString, body: body, principal: principal)
            var reply = false, applied = false
            let ref = RemoteSessionRef(serverId: serverId, agentId: "agent.chatgpt", runtimeId: live.id, sessionId: live.sessionId)
            for _ in 0..<100 {
                let wire = try await sessions.sync(sessionId: live.sessionId, query: query, principal: principal)
                let text = String(decoding: wire, as: UTF8.self)
                reply = text.contains("合成进程回复")
                XCTAssertFalse(text.contains("private-thread")); XCTAssertFalse(text.contains(home.path))
                applied = try await store.operation(id: accepted.operationId, owner: owner, ref: ref).state == .applied
                if reply && applied { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(reply); XCTAssertTrue(applied)
            // Exercise the production owner entry, not an opt-in coordinator
            // assembled by the test. The synthetic stdio peer verifies exact replies.
            for approval in [false, true] {
                var request: RemotePendingRequest?
                for _ in 0..<100 {
                    let data = try await sessions.sync(sessionId: live.sessionId, query: query, principal: principal)
                    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                    let pending = try XCTUnwrap(object["pendingRequests"] as? [[String: Any]])
                    if let first = pending.first {
                        let decoded = try JSONDecoder().decode(RemotePendingRequest.self, from: JSONSerialization.data(withJSONObject: first))
                        if decoded.type == (approval ? "approval" : "question") { request = decoded; break }
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                let current = try XCTUnwrap(request)
                let hidden = try await sessions.sync(sessionId: live.sessionId, query: query, principal: noApproval)
                let hiddenObject = try XCTUnwrap(JSONSerialization.jsonObject(with: hidden) as? [String: Any])
                XCTAssertTrue((hiddenObject["pendingRequests"] as? [Any])?.isEmpty == true)
                XCTAssertFalse(String(decoding: hidden, as: UTF8.self).contains(current.requestId))
                var response: [String: AgentJSON] = ["executionEpoch": .string(current.executionEpoch), "requestId": .string(current.requestId),
                    "expectedRequestRevision": .integer(Int64(current.requestRevision)), "expectedTurnId": .string(current.turnId)]
                if approval { response["decision"] = .string("decline") }
                else {
                    let question = try XCTUnwrap(current.questions.first)
                    response["answers"] = .array([.object(["questionId": .string(question.questionId),
                        "selectedOptionIds": .array([.string(try XCTUnwrap(question.options.first?.optionId))])])])
                }
                let replyBody = try JSONEncoder().encode(AgentJSON.object(response))
                let action: RemoteAction = approval ? .approve : .answer
                do {
                    _ = try await operations.submit(sessionId: live.sessionId, query: query, action: action,
                        key: UUID().uuidString, body: replyBody, principal: noApproval)
                    XCTFail("Request accepted without explicit approval scope")
                } catch { XCTAssertEqual(error as? RemoteAccessError, .forbidden) }
                let acceptedReply = try await operations.submit(sessionId: live.sessionId, query: query, action: action,
                    key: UUID().uuidString, body: replyBody, principal: principal)
                var delivered = false
                for _ in 0..<100 {
                    delivered = try await store.operation(id: acceptedReply.operationId, owner: owner, ref: ref).state == .applied
                    if delivered { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertTrue(delivered)
            }
            await owned.stop()
            let remaining = try await registry.ownerRuntimes(); XCTAssertEqual(remaining.map(\.runtimeId), ["directory"])
            do { _ = try await sessions.sync(sessionId: live.sessionId, query: query, principal: principal); XCTFail("Stopped source remains available") }
            catch { XCTAssertEqual(error as? RemoteReadError, .notFound) }
            let gate = OwnedLaunchGate()
            let late = RemoteOwnedChatGPTService(sources: [adapter], directory: root.appendingPathComponent("late-journals"), reads: reads, sessions: sessions, operations: operations,
                launch: { config, service in
                    let runtime = try await ChatGPTLocalRuntime.launch(configuration: config, service: service)
                    await gate.hold(runtime); return runtime
                })
            let starting = Task { try await late.attach(sourceRuntimeId: choice.sourceRuntimeId, sessionId: choice.sessionId, executable: executable, allowSteer: true) }
            await gate.wait(); await late.stop(); await gate.resume()
            do { _ = try await starting.value; XCTFail("Late startup survived service stop") } catch {}
            let lateRuntime = await gate.runtime
            let lateState = await lateRuntime?.currentState(); XCTAssertEqual(lateState, .stopped)
            let afterLate = try await registry.ownerRuntimes(); XCTAssertEqual(afterLate.map(\.runtimeId), ["directory"])
            await operations.shutdown()
        } catch { await owned.stop(); await operations.shutdown(); throw error }
    }
}
