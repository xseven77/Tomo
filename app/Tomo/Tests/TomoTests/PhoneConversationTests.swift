import XCTest
@testable import Tomo

private actor PhoneConversationRuntimeProbe {
    private var values: [ChatGPTRuntimeCoordinator] = []
    private var pauseNext = false, held = false
    private var waiter: CheckedContinuation<Void, Never>?, observer: CheckedContinuation<Void, Never>?
    func holdNext() {pauseNext = true}
    func waitForHeld() async {if !held {await withCheckedContinuation {observer = $0}}}
    func release() {waiter?.resume(); waiter = nil; held = false}
    func record(_ value: ChatGPTRuntimeCoordinator) async {
        values.append(value)
        if pauseNext {
            pauseNext = false
            await withCheckedContinuation {waiter = $0; held = true; observer?.resume(); observer = nil}
        }
    }
    func snapshot() -> [ChatGPTRuntimeCoordinator] { values }
}

@MainActor final class PhoneConversationTests: XCTestCase {
    func testPairingCodeRotationKeepsTheOriginalConversationLocation() throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let serverId = UUID().uuidString.lowercased(), first = String(repeating: "a", count: 64), next = String(repeating: "b", count: 64)
        let original = root.resolvingSymlinksInPath().appendingPathComponent("phone/" + first + "/" + serverId + "/owned-journals")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let canary = original.appendingPathComponent("existing-history")
        try Data("original owner history".utf8).write(to: canary)
        XCTAssertEqual(try PhoneConversationLocation.directory(root: root, serverId: serverId, namespace: first).path, original.path)
        XCTAssertEqual(try PhoneConversationLocation.directory(root: root, serverId: serverId, namespace: next).path, original.path)
        XCTAssertEqual(try Data(contentsOf: canary), Data("original owner history".utf8))
        let record = root.appendingPathComponent("phone/" + serverId + "/conversation-namespace")
        XCTAssertEqual(try String(contentsOf: record, encoding: .utf8), first)
        let mode = try FileManager.default.attributesOfItem(atPath: record.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }
    func testConversationLocationRejectsMalformedOrLinkedMetadataWithoutResettingIt() throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let serverId = UUID().uuidString.lowercased(), namespace = String(repeating: "a", count: 64)
        _ = try PhoneConversationLocation.directory(root: root, serverId: serverId, namespace: namespace)
        let record = root.appendingPathComponent("phone/" + serverId + "/conversation-namespace")
        for value in ["../" + String(repeating: "b", count: 61), String(repeating: "A", count: 64), "", String(repeating: "a", count: 65)] {
            let data = Data(value.utf8); try data.write(to: record)
            XCTAssertThrowsError(try PhoneConversationLocation.directory(root: root, serverId: serverId, namespace: namespace))
            XCTAssertEqual(try Data(contentsOf: record), data)
        }
        try FileManager.default.removeItem(at: record)
        let target = root.appendingPathComponent("untrusted-location")
        try Data(namespace.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: record, withDestinationURL: target)
        XCTAssertThrowsError(try PhoneConversationLocation.directory(root: root, serverId: serverId, namespace: namespace))
        XCTAssertEqual(try Data(contentsOf: target), Data(namespace.utf8))
    }
    func testAutomaticExecutablePrefersBundledRuntimeOverNodeWrapperAndKeepsCLIFallback() throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let home = root.appendingPathComponent("home"), applications = root.appendingPathComponent("Applications")
        let bundle = applications.appendingPathComponent("ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
        let wrapper = home.appendingPathComponent(".local/bin/codex")
        for path in [bundle, wrapper] {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/usr/bin/env node\n".utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        }
        XCTAssertEqual(try PhoneConversationExecutable.locate(home: home, applications: applications, bins: [wrapper]), bundle.resolvingSymlinksInPath())
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bundle.path)
        XCTAssertEqual(try PhoneConversationExecutable.locate(home: home, applications: applications, bins: [wrapper]), wrapper.resolvingSymlinksInPath())
    }
    func testCommandFailuresPreserveTheClientRecoveryContract() {
        for failure: Error in [RemoteCommandError.controlChanged, RemoteCommandError.executionChanged,
                              RemoteCommandError.sessionBusy, RemoteCommandError.unsafeStart, RemoteOperationError.keyConflict] {
            XCTAssertEqual(RemoteHTTPSListener.failure(failure).status, 409)
        }
        XCTAssertEqual(RemoteHTTPSListener.failure(RemoteOperationError.invalidRequest).status, 400)
        XCTAssertEqual(RemoteHTTPSListener.failure(RemoteOperationError.limitExceeded).status, 429)
        XCTAssertEqual(RemoteHTTPSListener.failure(RemoteCommandError.unsupportedAction).status, 501)
    }
    private struct Graph {
        let owned: RemoteOwnedChatGPTService
        let reads: RemoteReadService
        let sessions: RemoteSessionService
        let operations: RemoteOperationService
        let access: RemoteAccessStore
    }
    private func graph(_ root: URL, probe: PhoneConversationRuntimeProbe? = nil) throws -> Graph {
        let serverId = "synthetic-phone-server", sessions = RemoteSessionService(serverId: "synthetic-phone-server")
        let reads = RemoteReadService(serverId: serverId, sessionService: sessions)
        let access = RemoteAccessStore()
        let store = try RemoteOperationStore(databaseURL: root.appendingPathComponent(UUID().uuidString + ".sqlite"))
        let operations = RemoteOperationService(serverId: serverId, access: access, store: store) {_ in
            .init(userId: "synthetic-owner", deviceId: "synthetic-phone")}
        let source = ChatGPTReadAdapter(directory: .init(databaseURL: root.appendingPathComponent("account/state.sqlite"),
            storageRoot: root.appendingPathComponent("account"), runtimeId: "rt_account"), runtimeLabel: "Synthetic account")
        return .init(owned: RemoteOwnedChatGPTService(sources: [source], directory: root.appendingPathComponent("journals"),
            reads: reads, sessions: sessions, operations: operations, launch: {configuration, service in
                let runtime = try await ChatGPTLocalRuntime.launch(configuration: configuration, service: service,
                    environment: ["HOME": root.path, "PATH": "/usr/bin:/bin", "XDG_CONFIG_HOME": root.appendingPathComponent("config").path])
                await probe?.record(runtime)
                return runtime
            }), reads: reads, sessions: sessions, operations: operations, access: access)
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("phone-conversation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("account"), withIntermediateDirectories: true)
        return root
    }
    func testApprovalAndAnswerPathsReachTheOperationAuthority() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let graph = try graph(root), owned = RemoteOwnedChatGPTService.Owned(id: "rt_missing", sessionId: "ss_missing", title: "Synthetic")
        let principal = try await principal(graph, owned)
        let router = RemoteProductionBusinessRouter(reads: graph.reads, operations: graph.operations)
        for path in ["approvals", "answers", "approve", "answer"] {
            do {
                _ = try await router.handle(.init(method: "POST", path: "/api/v1/remote/sessions/ss_missing/" + path,
                    query: [:], headers: [("Content-Type", " application/json"), ("Idempotency-Key", " " + UUID().uuidString)], body: Data("{}".utf8)), principal: principal)
                XCTFail("Unknown synthetic session was accepted")
            } catch {XCTAssertEqual(error as? RemoteReadError, .notFound)}
        }
        await graph.owned.stop(); await graph.operations.shutdown()
    }
    private func principal(_ graph: Graph, _ owned: RemoteOwnedChatGPTService.Owned) async throws -> RemoteAccessStore.Principal {
        await graph.access.setDevelopmentEnabled(true)
        return try await graph.access.issueDevelopment(scopes: [.init(agentId: "agent.chatgpt", runtimeId: owned.id,
            sessionId: nil, actions: [.listSessions, .readHistory, .sendMessage, .interrupt, .approve, .answer])], origin: nil).principal
    }
    private func history(_ graph: Graph, _ owned: RemoteOwnedChatGPTService.Owned) async throws -> [RemoteHistoryMessage] {
        try await graph.reads.history(principal: principal(graph, owned), agentId: "agent.chatgpt", runtimeId: owned.id, sessionId: owned.sessionId).messages
    }
    private func send(_ text: String, _ graph: Graph, _ owned: RemoteOwnedChatGPTService.Owned) async throws {
        let principal = try await principal(graph, owned), query = ["agent_id": "agent.chatgpt", "runtime_id": owned.id]
        let control = try JSONDecoder().decode(RemoteSessionControl.self,
            from: try await graph.sessions.sync(sessionId: owned.sessionId, query: query, principal: principal))
        XCTAssertTrue(control.allowedActions.contains("message.send"))
        let body = try JSONEncoder().encode(AgentJSON.object(["executionEpoch": .string(control.executionEpoch),
            "clientMessageId": .string(UUID().uuidString), "mode": .string("start"), "expectedControlRevision": .integer(Int64(control.controlRevision)),
            "input": .array([.object(["type": .string("text"), "text": .string(text)])])]))
        // URLSession's HTTP/1 headers include OWS after ':'. Exercise the real
        // production router instead of bypassing its wire-header handling.
        let response = try await RemoteProductionBusinessRouter(reads: graph.reads, operations: graph.operations).handle(.init(
            method: "POST", path: "/api/v1/remote/sessions/\(owned.sessionId)/messages", query: query,
            headers: [("Content-Type", " application/json"), ("Idempotency-Key", " \t" + UUID().uuidString + "\t ")], body: body), principal: principal)
        XCTAssertEqual(response.status, 202)
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let operationId = try XCTUnwrap(receipt["operationId"] as? String)
        for _ in 0..<200 {
            let data = try await graph.operations.operation(id: operationId,
                query: query.merging(["session_id": owned.sessionId]) {_, new in new}, principal: principal)
            let state = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["state"] as? String
            if state == "applied" {return}
            if ["rejected", "failed", "unknown"].contains(state) {XCTFail("Synthetic send failed: " + (state ?? "invalid")); return}
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Synthetic send did not settle")
    }
    static func syntheticExecutable(root: URL) throws -> URL {
        let executable = root.appendingPathComponent("synthetic-agent")
        let script = """
        #!/usr/bin/python3
        import json,os,sys
        assert sys.argv[1:]==['app-server','--stdio']
        path=os.path.join(os.environ['CODEX_HOME'],'synthetic-state.json')
        state=json.load(open(path)) if os.path.exists(path) else {'starts':0,'resumes':0,'turns':[]}
        def save():
            state['pid']=os.getpid()
            with open(path,'w') as f: json.dump(state,f)
        def thread(): return {'id':'private-phone-thread','ephemeral':False,'path':os.path.join(os.environ['CODEX_HOME'],'sessions','synthetic.jsonl'),'cwd':state['cwd'],'createdAt':1,'updatedAt':100,'status':{'type':'active' if state['turns'] and state['turns'][-1]['status']=='inProgress' else 'idle'},'turns':state['turns']}
        def emit(value): print(json.dumps(value),flush=True)
        def event(method,params): return {'method':method,'params':{'threadId':'private-phone-thread',**params}}
        def complete(turn,status='completed'):
            turn['status']=status; save(); return event('turn/completed',{'turn':turn})
        for line in sys.stdin:
            frame=json.loads(line); method=frame.get('method'); events=[]
            if method is None:
                rid=frame['id']; result=frame['result']; turn=state['turns'][-1]
                if rid.startswith('phone-question-'):
                    assert result=={'answers':{'phone-choice':{'answers':['继续']}}}
                    state['questionReplies']=state.get('questionReplies',0)+1
                elif rid.startswith('phone-approval-'):
                    assert result=={'decision':'decline'}
                    state['approvalReplies']=state.get('approvalReplies',0)+1
                else: raise RuntimeError('unexpected synthetic callback')
                emit(event('serverRequest/resolved',{'requestId':rid})); emit(complete(turn)); continue
            if method=='initialized': continue
            if method=='initialize': result={'userAgent':'synthetic-phone'}
            elif method=='account/read':
                assert frame['params']=={'refreshToken':False}
                account_path=os.path.join(os.environ['CODEX_HOME'],'phone-account.json')
                result=json.load(open(account_path)) if os.path.exists(account_path) else {'account':None,'requiresOpenaiAuth':False}
            elif method=='thread/start':
                assert frame['params']['ephemeral']==False and state['starts']==0
                state['starts']+=1; state['cwd']=frame['params']['cwd']; save(); result={'thread':thread()}
            elif method=='thread/resume':
                assert frame['params']=={'threadId':'private-phone-thread','excludeTurns':True}
                state['resumes']+=1; save(); result={'thread':thread()}
            elif method=='thread/read': result={'thread':thread()}
            elif method=='turn/start':
                assert frame['params']['threadId']=='private-phone-thread'
                text=frame['params']['input'][0]['text']; n=len(state['turns'])+1
                pending=text in ['native synthetic hold','native synthetic question','native synthetic approval']
                turn={'id':'turn-'+str(n),'status':'inProgress' if pending else 'completed','itemsView':'full','items':[
                    {'id':'user-'+str(n),'type':'userMessage','content':[{'type':'text','text':text}]},
                    {'id':'answer-'+str(n),'type':'agentMessage','text':'echo: '+text}]}
                state['turns'].append(turn); save(); result={'turn':turn}
                os.makedirs(os.path.join(os.environ['CODEX_HOME'],'sessions'),exist_ok=True)
                with open(thread()['path'],'w') as f: f.write('synthetic materialized marker')
                events.append(event('turn/started',{'turn':{**turn,'status':'inProgress','items':[]}}))
                events.append(event('thread/settings/updated',{'threadSettings':{'model':'synthetic','cwd':state['cwd']}}))
                if pending:
                    if text=='native synthetic question': events.append({'id':'phone-question-'+str(n),'method':'item/tool/requestUserInput','params':{
                        'threadId':'private-phone-thread','turnId':turn['id'],'itemId':'phone-question-item-'+str(n),'isBlocking':True,
                        'questions':[{'id':'phone-choice','header':'合成验证','question':'是否继续合成验证？','isOther':True,
                            'options':[{'label':'继续','description':'只验证回传，不执行工具'}]}]}})
                    elif text=='native synthetic approval': events.append({'id':'phone-approval-'+str(n),'method':'item/commandExecution/requestApproval','params':{
                        'threadId':'private-phone-thread','turnId':turn['id'],'itemId':'phone-command-'+str(n),'startedAtMs':100,
                        'command':'synthetic command (never executed)','cwd':'/synthetic/workspace','reason':'仅验证拒绝审批回传',
                        'availableDecisions':['accept','decline']}})
                else: events.append(event('turn/completed',{'turn':turn}))
            elif method=='turn/steer':
                turn=state['turns'][-1]; assert turn['status']=='inProgress' and frame['params']['expectedTurnId']==turn['id']
                text=frame['params']['input'][0]['text']; assert text=='native synthetic steer'
                items=[{'id':'steer-user','type':'userMessage','content':[{'type':'text','text':text}]},
                    {'id':'steer-answer','type':'agentMessage','text':'echo: '+text}]
                turn['items'].extend(items); state['steers']=state.get('steers',0)+1; save(); result={'turnId':turn['id']}
                events.extend(event('item/completed',{'turnId':turn['id'],'item':item}) for item in items)
            elif method=='turn/interrupt':
                turn=state['turns'][-1]; assert turn['status']=='inProgress' and frame['params']['turnId']==turn['id']
                state['interrupts']=state.get('interrupts',0)+1; result={}; events.append(complete(turn,'interrupted'))
            else: raise RuntimeError('unexpected synthetic method')
            emit({'id':frame['id'],'result':result})
            for value in events: emit(value)
        """
        try Data(script.utf8).write(to: executable); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }
    func testDurableDefaultConversationRestoresHistoryAndCanSendAfterRestart() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let executable = try Self.syntheticExecutable(root: root)
        let first = try graph(root)
        let created: RemoteOwnedChatGPTService.Owned
        do {
            let value = try await first.owned.preparePhoneConversation(executable: executable)
            created = try XCTUnwrap(value)
            let repeated = try await first.owned.preparePhoneConversation(executable: executable)
            XCTAssertEqual(repeated?.id, created.id)
            try await send("first", first, created)
            for _ in 0..<100 {if try await history(first, created).count == 2 {break}; try await Task.sleep(for: .milliseconds(10))}
            let messages = try await history(first, created); XCTAssertEqual(messages.count, 2)
            await first.owned.stop(); await first.operations.shutdown()
        } catch {await first.owned.stop(); await first.operations.shutdown(); throw error}
        let second = try graph(root)
        do {
            let value = try await second.owned.preparePhoneConversation(executable: executable), restored = try XCTUnwrap(value)
            XCTAssertEqual(restored.id, created.id); XCTAssertEqual(restored.sessionId, created.sessionId)
            let messages = try await history(second, restored); XCTAssertEqual(messages.count, 2)
            XCTAssertEqual(messages.last?.content.first?.text, "echo: first")
            try await send("second", second, restored)
            let state = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("account/synthetic-state.json"))) as? [String: Any]
            XCTAssertEqual(state?["starts"] as? Int, 1); XCTAssertEqual(state?["resumes"] as? Int, 1)
            XCTAssertEqual((state?["turns"] as? [Any])?.count, 2)
            await second.owned.stop(); await second.operations.shutdown()
        } catch {await second.owned.stop(); await second.operations.shutdown(); throw error}
        let manifest = root.appendingPathComponent("journals/phone-conversation.json"), before = try Data(contentsOf: manifest)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: before) as? [String: Any])
        let rollout = try XCTUnwrap(record["rolloutPath"] as? String)
        try FileManager.default.removeItem(atPath: rollout)
        let missing = try graph(root)
        do {_ = try await missing.owned.preparePhoneConversation(executable: executable); XCTFail("Missing existing history was replaced")}
        catch {XCTAssertEqual(error as? PhoneConversationError, .historyMissing)}
        XCTAssertEqual(try Data(contentsOf: manifest), before)
        await missing.owned.stop(); await missing.operations.shutdown()
    }
    func testDefaultConversationReplacesStoppedRuntimeWithoutReplacingItsHistory() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let executable = try Self.syntheticExecutable(root: root), probe = PhoneConversationRuntimeProbe()
        let graph = try graph(root, probe: probe)
        do {
            let value = try await graph.owned.preparePhoneConversation(executable: executable)
            let created = try XCTUnwrap(value)
            try await send("before runtime exit", graph, created)
            let existingAccess = try await principal(graph, created)
            let launched = await probe.snapshot(), original = try XCTUnwrap(launched.first)
            await original.stop()
            let replacement = try await graph.owned.preparePhoneConversation(executable: executable)
            XCTAssertEqual(replacement?.id, created.id)
            XCTAssertEqual(replacement?.sessionId, created.sessionId)
            let runtimes = await probe.snapshot()
            XCTAssertEqual(runtimes.count, 2, "A stopped runtime must not be advertised as ready")
            if runtimes.count == 2 {
                let runtimeState = await runtimes[1].currentState(); XCTAssertEqual(runtimeState, .ready)
                let prior = try await history(graph, created)
                XCTAssertEqual(prior.count, 2)
                XCTAssertEqual(prior.last?.content.first?.text, "echo: before runtime exit")
                let resumed = try JSONDecoder().decode(RemoteSessionControl.self, from: try await graph.sessions.sync(
                    sessionId: created.sessionId, query: ["agent_id": "agent.chatgpt", "runtime_id": created.id], principal: existingAccess))
                XCTAssertTrue(resumed.allowedActions.contains("message.send"), "Recovery must retain an unexpired existing grant")
                try await send("after runtime exit", graph, created)
                let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("account/synthetic-state.json"))) as? [String: Any])
                XCTAssertEqual(state["starts"] as? Int, 1); XCTAssertEqual(state["resumes"] as? Int, 1)
                XCTAssertEqual((state["turns"] as? [Any])?.count, 2)
            }
            await graph.owned.stop(); await graph.operations.shutdown()
        } catch {await graph.owned.stop(); await graph.operations.shutdown(); throw error}
    }
    func testOwnerDetachSuppressesDefaultRecoveryUntilServiceIsReopened() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let executable = try Self.syntheticExecutable(root: root), probe = PhoneConversationRuntimeProbe()
        let graph = try graph(root, probe: probe)
        do {
            let value = try await graph.owned.preparePhoneConversation(executable: executable)
            let created = try XCTUnwrap(value)
            await graph.owned.detach(id: created.id)
            let restored = try await graph.owned.preparePhoneConversation(executable: executable)
            XCTAssertNil(restored)
            let launches = await probe.snapshot(), owned = await graph.owned.owned()
            XCTAssertEqual(launches.count, 1); XCTAssertTrue(owned.isEmpty)
            await graph.owned.stop(); await graph.operations.shutdown()
        } catch {await graph.owned.stop(); await graph.operations.shutdown(); throw error}
    }
    func testDeadRuntimeCatalogCleanupStillAllowsDefaultRecovery() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let executable = try Self.syntheticExecutable(root: root), probe = PhoneConversationRuntimeProbe()
        let graph = try graph(root, probe: probe)
        do {
            let value = try await graph.owned.preparePhoneConversation(executable: executable)
            let created = try XCTUnwrap(value)
            try await send("before catalog cleanup", graph, created)
            let launched = await probe.snapshot(), original = try XCTUnwrap(launched.first)
            await original.stop()
            let dead = await graph.owned.owned(); XCTAssertTrue(dead.isEmpty)
            let restored = try await graph.owned.preparePhoneConversation(executable: executable)
            XCTAssertEqual(restored?.sessionId, created.sessionId)
            let replacements = await probe.snapshot(); XCTAssertEqual(replacements.count, 2)
            let messages = try await history(graph, created); XCTAssertEqual(messages.count, 2)
            await graph.owned.stop(); await graph.operations.shutdown()
        } catch {await graph.owned.stop(); await graph.operations.shutdown(); throw error}
    }
    func testOwnerDetachDuringRecoveryStopsTheLateRuntime() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let executable = try Self.syntheticExecutable(root: root), probe = PhoneConversationRuntimeProbe()
        let graph = try graph(root, probe: probe)
        do {
            let value = try await graph.owned.preparePhoneConversation(executable: executable)
            let created = try XCTUnwrap(value)
            try await send("before owner stops recovery", graph, created)
            let launched = await probe.snapshot(), original = try XCTUnwrap(launched.first)
            await original.stop(); await probe.holdNext()
            let recovery = Task {try await graph.owned.preparePhoneConversation(executable: executable)}
            await probe.waitForHeld()
            await graph.owned.detach(id: created.id); await probe.release()
            do {let value = try await recovery.value; XCTAssertNil(value)}
            catch {XCTAssertTrue(error is CancellationError || error as? RemoteAccessError == .unavailable)}
            let runtimes = await probe.snapshot(), owned = await graph.owned.owned()
            XCTAssertEqual(runtimes.count, 2); XCTAssertTrue(owned.isEmpty)
            let late = try XCTUnwrap(runtimes.last), state = await late.currentState()
            XCTAssertTrue(state == .stopped || state == .failed)
            let repeated = try await graph.owned.preparePhoneConversation(executable: executable); XCTAssertNil(repeated)
            await graph.owned.stop(); await graph.operations.shutdown()
        } catch {await probe.release(); await graph.owned.stop(); await graph.operations.shutdown(); throw error}
    }
    func testRuntimeRecoveryRejectsReplacedWorkspaceDirectory() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let executable = try Self.syntheticExecutable(root: root), probe = PhoneConversationRuntimeProbe()
        let graph = try graph(root, probe: probe)
        do {
            let value = try await graph.owned.preparePhoneConversation(executable: executable)
            let created = try XCTUnwrap(value)
            try await send("before workspace replacement", graph, created)
            let runtimes = await probe.snapshot(), original = try XCTUnwrap(runtimes.first)
            await original.stop()
            let workspace = root.appendingPathComponent("journals/手机会话")
            try FileManager.default.moveItem(at: workspace, to: root.appendingPathComponent("original-workspace"))
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            do {_ = try await graph.owned.preparePhoneConversation(executable: executable); XCTFail("Replaced workspace was accepted")}
            catch {XCTAssertEqual(error as? RemoteAccessError, .forbidden)}
            let owned = await graph.owned.owned(); XCTAssertTrue(owned.isEmpty)
            await graph.owned.stop(); await graph.operations.shutdown()
        } catch {await graph.owned.stop(); await graph.operations.shutdown(); throw error}
    }
    func testPhoneAuthenticationFailureDoesNotPublishAndRetryUsesTheSameService() async throws {
        for response: [String: Any] in [
            ["account": NSNull(), "requiresOpenaiAuth": true],
            ["account": NSNull()],
            ["account": "malformed", "requiresOpenaiAuth": false]
        ] {
            let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
            let executable = try Self.syntheticExecutable(root: root), graph = try graph(root)
            let accountFile = root.appendingPathComponent("account/phone-account.json")
            try JSONSerialization.data(withJSONObject: response).write(to: accountFile)
            do {
                _ = try await graph.owned.preparePhoneConversation(executable: executable)
                XCTFail("Unusable auth was published as writable")
            } catch {
                let expected: ChatGPTRuntimeError = response["requiresOpenaiAuth"] as? Bool == true ? .authenticationRequired : .invalidAccountState
                XCTAssertEqual(error as? ChatGPTRuntimeError, expected)
            }
            let owned = await graph.owned.owned(); XCTAssertTrue(owned.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("journals/phone-conversation.json").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("account/synthetic-state.json").path))
            // Existing credentials, without requesting login or a model turn.
            try JSONSerialization.data(withJSONObject: ["account": ["type": "apiKey"], "requiresOpenaiAuth": true]).write(to: accountFile)
            let value = try await graph.owned.preparePhoneConversation(executable: executable), ready = try XCTUnwrap(value)
            try await send("synthetic authenticated retry", graph, ready)
            var count = 0
            for _ in 0..<200 {
                count = try await history(graph, ready).count
                if count == 2 {break}
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(count, 2)
            await graph.owned.stop(); await graph.operations.shutdown()
        }
    }
    func testAuthenticationLossPreservesTheExistingPrivateManifest() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let executable = try Self.syntheticExecutable(root: root), first = try graph(root)
        _ = try await first.owned.preparePhoneConversation(executable: executable)
        await first.owned.stop(); await first.operations.shutdown()
        let manifest = root.appendingPathComponent("journals/phone-conversation.json"), original = try Data(contentsOf: manifest)
        try JSONSerialization.data(withJSONObject: ["account": NSNull(), "requiresOpenaiAuth": true])
            .write(to: root.appendingPathComponent("account/phone-account.json"))
        let second = try graph(root)
        do {_ = try await second.owned.preparePhoneConversation(executable: executable); XCTFail("Logged-out account was accepted")}
        catch {XCTAssertEqual(error as? ChatGPTRuntimeError, .authenticationRequired)}
        XCTAssertEqual(try Data(contentsOf: manifest), original)
        await second.owned.stop(); await second.operations.shutdown()
    }
    func testInstalledAppServerWithoutLoginCannotPublishPhoneConversation() async throws {
        guard ProcessInfo.processInfo.environment["TOMO_PHONE_APP_SERVER_SMOKE"] == "1" else {throw XCTSkip("Opt-in installed CLI; no credentials or inference")}
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let executable = try PhoneConversationExecutable.locate(), first = try graph(root)
        do {
            _ = try await first.owned.preparePhoneConversation(executable: executable)
            XCTFail("Isolated empty account was accepted")
        } catch {
            if case AgentRPCError.vendor(let code, _) = error {XCTFail("Isolated account RPC failed with vendor code \(code)")}
            else {XCTAssertEqual(error as? ChatGPTRuntimeError, .authenticationRequired, String(reflecting: type(of: error)))}
        }
        let owned = await first.owned.owned(); XCTAssertTrue(owned.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("journals/phone-conversation.json").path))
        await first.owned.stop(); await first.operations.shutdown()
    }

    func testAuthorizedSavedRealConversationResumesWithoutAnotherModelTurn() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let saved = env["TOMO_PHONE_REAL_MODEL_RESUME_ROOT"],
              let auth = env["TOMO_PHONE_REAL_MODEL_AUTH_FILE"] else {
            throw XCTSkip("Opt-in reading of the isolated acceptance conversation; no inference")
        }
        let root = URL(fileURLWithPath: saved).resolvingSymlinksInPath(), fm = FileManager.default
        let temporary = fm.temporaryDirectory.resolvingSymlinksInPath().path + "/"
        guard root.path.hasPrefix(temporary), root.lastPathComponent.hasPrefix("phone-conversation-") else {
            throw RemoteOperationError.invalidRequest
        }
        defer {try? fm.removeItem(at: root)}
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: root.appendingPathComponent("journals/phone-conversation.json"))) as? [String: Any])
        let authCopy = root.appendingPathComponent("account/auth.json")
        try Data(contentsOf: URL(fileURLWithPath: auth)).write(to: authCopy, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authCopy.path)
        let executable = try PhoneConversationExecutable.locate()
        let literalEncoder = JSONEncoder()
        literalEncoder.outputFormatting = [.withoutEscapingSlashes]
        let executableLiteral = String(decoding: try literalEncoder.encode(executable.path), as: UTF8.self)
        let methods = root.appendingPathComponent("read-only-rpc-methods.jsonl")
        defer {
            if let recorded = try? String(contentsOf: methods, encoding: .utf8) {
                print("TOMO_READONLY_RPC_METHODS: " + recorded.replacingOccurrences(of: "\n", with: " "))
            }
        }
        let methodsLiteral = String(decoding: try literalEncoder.encode(methods.path), as: UTF8.self)
        let wrapper = root.appendingPathComponent("read-only-runtime")
        try Data("""
        #!/usr/bin/python3
        import subprocess,sys,threading,json,os
        assert sys.argv[1:]==['app-server','--stdio']
        child=subprocess.Popen([\(executableLiteral),'app-server','--stdio'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
        def forward():
            for line in sys.stdin.buffer:
                frame=json.loads(line); method=frame.get('method')
                if method:
                    with open(\(methodsLiteral),'a') as f:f.write(json.dumps(method)+'\\n')
                if method not in ['initialize','initialized','account/read','thread/resume','thread/read','thread/turns/list']:
                    child.terminate();os._exit(71)
                child.stdin.write(line);child.stdin.flush()
            child.stdin.close()
        threading.Thread(target=forward,daemon=True).start()
        try:
            for line in child.stdout:sys.stdout.buffer.write(line);sys.stdout.buffer.flush()
        finally:
            child.terminate();child.wait()
        """.utf8).write(to: wrapper)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let graph = try graph(root)
        do {
            let value = try await graph.owned.preparePhoneConversation(executable: wrapper)
            let restored = try XCTUnwrap(value)
            XCTAssertEqual(restored.id, record["runtimeId"] as? String)
            XCTAssertEqual(restored.sessionId, record["sessionId"] as? String)
            let messages = try await history(graph, restored)
            XCTAssertEqual(messages.count, 2)
            XCTAssertEqual(messages.last?.role, "assistant")
            XCTAssertEqual(messages.last?.content.map(\.text).joined(), "TOMOGO_ECHO_ONE")
            let data = try await graph.sessions.sync(sessionId: restored.sessionId,
                query: ["agent_id": "agent.chatgpt", "runtime_id": restored.id], principal: principal(graph, restored))
            let control = try JSONDecoder().decode(RemoteSessionControl.self, from: data)
            XCTAssertEqual(control.state, "completed")
            XCTAssertTrue(control.allowedActions.contains("message.send"))
        } catch {
            await graph.owned.stop(); await graph.operations.shutdown(); throw error
        }
        await graph.owned.stop(); await graph.operations.shutdown()
        let observed = try String(contentsOf: methods, encoding: .utf8).split(separator: "\n")
            .map {try JSONDecoder().decode(String.self, from: Data($0.utf8))}
        XCTAssertEqual(observed.filter {$0 == "thread/resume"}.count, 1)
        XCTAssertFalse(observed.contains("thread/start")); XCTAssertFalse(observed.contains("turn/start"))
        print("TOMO_REAL_MODEL_READONLY_RESUME: exact reply restored; same public session; completed and writable; zero model starts")
    }

    /// Explicitly opted in by a human. Never run as part of the normal suite.
    /// The external budget survives this test's temporary-account cleanup, so
    /// rerunning a failed test cannot silently spend another two model turns.
    func testAuthorizedRealModelRoundTripAndPersistentResume() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["TOMO_PHONE_REAL_MODEL_AUTHORIZED"] == "2" else {
            throw XCTSkip("Requires explicit permission for at most two real model turns")
        }
        let auth = try XCTUnwrap(env["TOMO_PHONE_REAL_MODEL_AUTH_FILE"])
        let budgetPath = try XCTUnwrap(env["TOMO_PHONE_REAL_MODEL_BUDGET_FILE"])
        let model = try XCTUnwrap(env["TOMO_PHONE_REAL_MODEL"])
        guard model.range(of: "^[a-zA-Z0-9._-]{1,100}$", options: .regularExpression) != nil else {
            throw RemoteOperationError.invalidRequest
        }
        let root = try root(), fm = FileManager.default
        defer {try? fm.removeItem(at: root)}
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let account = root.appendingPathComponent("account")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: account.path)
        let privateAuth = account.appendingPathComponent("auth.json")
        try Data(contentsOf: URL(fileURLWithPath: auth)).write(to: privateAuth, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateAuth.path)
        let config = """
        model = "\(model)"
        model_provider = "openai"
        model_reasoning_effort = "low"
        sandbox_mode = "read-only"
        approval_policy = "never"
        web_search = "disabled"
        developer_instructions = "This is an isolated text echo acceptance test. Reply with exactly the requested literal. Never call any tool, inspect files, or perform any action."
        [features]
        shell_tool = false
        unified_exec = false
        plugins = false
        apps = false
        multi_agent = false
        goals = false
        hooks = false
        browser_use = false
        computer_use = false
        image_generation = false
        view_image = false
        skill_search = false
        shell_snapshot = false
        """
        try Data(config.utf8).write(to: account.appendingPathComponent("config.toml"))
        let budget = URL(fileURLWithPath: budgetPath)
        let previouslyUsed = fm.fileExists(atPath: budget.path)
            ? try XCTUnwrap(Int(String(contentsOf: budget, encoding: .utf8))) : 0
        guard previouslyUsed < 2 else {throw RemoteOperationError.limitExceeded}
        func spendOneTurn() throws {
            let used: Int
            if fm.fileExists(atPath: budget.path) {
                used = try XCTUnwrap(Int(String(contentsOf: budget, encoding: .utf8)))
            } else {used = 0}
            guard used < 2 else {throw RemoteOperationError.limitExceeded}
            try Data(String(used + 1).utf8).write(to: budget, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: budget.path)
        }
        func waitForReply(_ graph: Graph, _ owned: RemoteOwnedChatGPTService.Owned,
                          literal: String, expectedUsers: Int) async throws {
            for _ in 0..<480 {
                let data = try await graph.sessions.sync(sessionId: owned.sessionId,
                    query: ["agent_id": "agent.chatgpt", "runtime_id": owned.id], principal: principal(graph, owned))
                struct Snapshot: Decodable {
                    let state: String
                    let activities: [RemoteToolActivity]
                    let pendingRequests: [RemotePendingRequest]
                }
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
                guard snapshot.activities.isEmpty, snapshot.pendingRequests.isEmpty else {
                    throw RemoteOperationError.invalidRequest
                }
                if snapshot.state == "completed" {
                    let messages = try await history(graph, owned)
                    XCTAssertEqual(messages.filter {$0.role == "user"}.count, expectedUsers)
                    XCTAssertEqual(messages.filter {$0.role == "assistant"}.last?.content.map(\.text).joined(), literal)
                    XCTAssertEqual(messages.filter {$0.role == "assistant"}.count, expectedUsers)
                    return
                }
                if ["failed", "interrupted"].contains(snapshot.state) {
                    throw RemoteOperationError.invalidRequest
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            throw RemoteOperationError.limitExceeded
        }
        let executable = try PhoneConversationExecutable.locate()
        let first = try graph(root)
        let original: RemoteOwnedChatGPTService.Owned
        do {
            let prepared = try await first.owned.preparePhoneConversation(executable: executable)
            original = try XCTUnwrap(prepared)
            try spendOneTurn()
            try await send("Reply with exactly TOMOGO_ECHO_ONE. Do not use tools or access files.", first, original)
            try await waitForReply(first, original, literal: "TOMOGO_ECHO_ONE", expectedUsers: 1)
        } catch {
            await first.owned.stop(); await first.operations.shutdown(); throw error
        }
        await first.owned.stop(); await first.operations.shutdown()
        let second = try graph(root)
        do {
            let prepared = try await second.owned.preparePhoneConversation(executable: executable)
            let resumed = try XCTUnwrap(prepared)
            XCTAssertEqual(resumed.id, original.id); XCTAssertEqual(resumed.sessionId, original.sessionId)
            let restored = try await history(second, resumed)
            XCTAssertEqual(restored.count, 2)
            XCTAssertEqual(restored.last?.content.map(\.text).joined(), "TOMOGO_ECHO_ONE")
            if previouslyUsed == 0 {
                try spendOneTurn()
                try await send("Reply with exactly TOMOGO_ECHO_TWO. Do not use tools or access files.", second, resumed)
                try await waitForReply(second, resumed, literal: "TOMOGO_ECHO_TWO", expectedUsers: 2)
            }
        } catch {
            await second.owned.stop(); await second.operations.shutdown(); throw error
        }
        await second.owned.stop(); await second.operations.shutdown()
        print("TOMO_REAL_MODEL_ACCEPTANCE: \(previouslyUsed == 0 ? 2 : 1) exact replies; same session after restart; zero tool activities; private account removed on exit")
    }
}
