import Foundation
import SQLite3
import Testing
@testable import Tomo

/// Opt-in RN integration peer. Uses the production owner, HTTP listener and
/// stdio transport, with a synthetic agent that never executes a command/model.
@MainActor struct RemoteRequestBrowserFixtureTests {
    @Test func serveOwnedRequestFixtureWhenExplicitlyRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["TOMO_REMOTE_REQUEST_FIXTURE"] else { return }
        let root = URL(fileURLWithPath: path), home = root.appendingPathComponent("account")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let rollout = home.appendingPathComponent("rollout.jsonl")
        try Data("{}\n".utf8).write(to: rollout)
        let databaseURL = home.appendingPathComponent("state_5.sqlite")
        var pointer: OpaquePointer?
        try #require(sqlite3_open(databaseURL.path, &pointer) == SQLITE_OK)
        let database = try #require(pointer)
        defer { sqlite3_close(database) }
        let escaped = rollout.path.replacingOccurrences(of: "'", with: "''")
        try #require(sqlite3_exec(database, "CREATE TABLE threads(id TEXT,rollout_path TEXT,title TEXT,updated_at INTEGER); INSERT INTO threads VALUES('private-fixture-thread','\(escaped)','RN 请求联调',100)", nil, nil, nil) == SQLITE_OK)
        let executable = root.appendingPathComponent("synthetic-request-agent")
        let script = """
        #!/usr/bin/python3
        import json,os,signal,sys,threading,time
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
        assert sys.argv[1:]==['app-server','--stdio']
        assert os.path.samefile(os.environ['CODEX_HOME'],\(String(reflecting: home.path)))
        root=\(String(reflecting: root.path))
        counts={'questionReplies':0,'approvalReplies':0,'fileReplies':0,'fileRevision':0,'permissionReplies':0,'stopped':False}
        lock=threading.RLock()
        def status():
            with lock:
                with open(root+'/peer-status.tmp','w') as f: json.dump(counts,f)
                os.replace(root+'/peer-status.tmp',root+'/peer-status.json')
        def emit(frame):
            with lock: print(json.dumps(frame),flush=True)
        def resolved(rid): emit({'method':'serverRequest/resolved','params':{'threadId':'private-fixture-thread','requestId':rid}})
        def permissions(index):
            if index==1: return {'network':{'enabled':True},'fileSystem':{'entries':[
                {'access':'read','path':{'type':'special','value':{'kind':'root'}}},
                {'access':'write','path':{'type':'glob_pattern','pattern':'/synthetic/workspace/**/*.ts'}},
                {'access':'deny','path':{'type':'path','path':'/synthetic/workspace/secrets'}},
                *[{'access':'read','path':{'type':'special','value':{'kind':kind}}} for kind in ['minimal','project_roots','tmpdir','slash_tmp']]
                ],'globScanMaxDepth':4,'read':['/compat/read'],'write':['/compat/write']}}
            if index==2: return {'network':{'enabled':False},'fileSystem':{'read':['/synthetic/workspace/docs'],'write':[]}}
            return {'fileSystem':{'entries':[{'access':'write','path':{'type':'special','value':{'kind':'unknown','path':':future-scope','subpath':'config'}}}]}}
        def request_permissions(index): emit({'id':'private-permissions-'+str(index),'method':'item/permissions/requestApproval','params':{
            'threadId':'private-fixture-thread','turnId':'private-turn','itemId':'private-permissions-item-'+str(index),'startedAtMs':102+index,
            'cwd':'/synthetic/workspace','environmentId':'synthetic_environment','reason':'仅验证权限回复，不授予真实权限','permissions':permissions(index)}})
        def changes(revision): return [
            {'path':'/synthetic/workspace/new.ts','kind':{'type':'add'},'diff':'+added🐾'+chr(10)},
            {'path':'/synthetic/workspace/removed.ts','kind':{'type':'delete'},'diff':'-removed'+chr(10)},
            {'path':'/synthetic/workspace/old.ts','kind':{'type':'update','move_path':'/synthetic/workspace/moved.ts'},
                'diff':'-before'+chr(10)+'+revision '+str(revision)+chr(10)}]
        def patch_update():
            while not counts['stopped']:
                if os.path.exists(root+'/patch-update'):
                    counts['fileRevision']=2; status()
                    emit({'method':'item/fileChange/patchUpdated','params':{'threadId':'private-fixture-thread',
                        'turnId':'private-turn','itemId':'private-file','changes':changes(2)}})
                    return
                time.sleep(0.02)
        status()
        try:
            for line in sys.stdin:
                frame=json.loads(line); method=frame.get('method')
                if method is None:
                    if frame['id']=='private-question-callback':
                        assert counts['questionReplies']==0
                        assert frame['result']=={'answers':{
                            'private-theme':{'answers':['浅色']},'private-secret':{'answers':['仅供合成联调']}}}
                        counts['questionReplies']+=1; status(); resolved(frame['id'])
                        emit({'id':'private-approval-callback','method':'item/commandExecution/requestApproval','params':{
                            'threadId':'private-fixture-thread','turnId':'private-turn','itemId':'private-command','startedAtMs':100,
                            'command':'git status --short','cwd':'/synthetic/workspace','reason':'仅测试审批回复，不执行命令',
                            'availableDecisions':['accept','decline']}})
                    elif frame['id']=='private-approval-callback':
                        assert counts['approvalReplies']==0
                        assert frame['result']=={'decision':'decline'}
                        counts['approvalReplies']+=1; status(); resolved(frame['id'])
                        counts['fileRevision']=1; status()
                        emit({'method':'item/started','params':{'threadId':'private-fixture-thread','turnId':'private-turn',
                            'item':{'id':'private-file','type':'fileChange','status':'inProgress','changes':changes(1)}}})
                        emit({'id':'private-file-callback','method':'item/fileChange/requestApproval','params':{
                            'threadId':'private-fixture-thread','turnId':'private-turn','itemId':'private-file','startedAtMs':101,
                            'reason':'仅验证完整 diff 和审批版本，不写入文件','grantRoot':'/synthetic/workspace'}})
                        threading.Thread(target=patch_update,daemon=True).start()
                    elif frame['id']=='private-file-callback':
                        assert counts['fileReplies']==0 and counts['fileRevision']==2
                        assert frame['result']=={'decision':'acceptForSession'}
                        counts['fileReplies']+=1; status(); resolved(frame['id'])
                        emit({'method':'item/completed','params':{'threadId':'private-fixture-thread','turnId':'private-turn',
                            'item':{'id':'private-file','type':'fileChange','status':'completed','changes':changes(2)}}})
                        request_permissions(1)
                    elif frame['id'].startswith('private-permissions-'):
                        index=int(frame['id'].split('-')[-1]); assert counts['permissionReplies']==index-1
                        assert frame['result']=={'permissions':{} if index==3 else permissions(index),'scope':'session' if index==1 else 'turn'}
                        counts['permissionReplies']+=1; status(); resolved(frame['id'])
                        if index<3: request_permissions(index+1)
                        else:
                            emit({'method':'item/started','params':{'threadId':'private-fixture-thread','turnId':'private-turn',
                                'item':{'id':'private-streamed-command','type':'commandExecution','status':'inProgress',
                                    'command':'synthetic-check','cwd':'/synthetic/tool-workspace','aggregatedOutput':None,
                                    'processId':'private-synthetic-process','arguments':{'private':'not-visible'}}}})
                            for text in ['实时输出 🐙\\n','<script>仅文本</script>\\n']:
                                emit({'method':'item/commandExecution/outputDelta','params':{'threadId':'private-fixture-thread',
                                    'turnId':'private-turn','itemId':'private-streamed-command','delta':text}})
                            emit({'method':'item/completed','params':{'threadId':'private-fixture-thread','turnId':'private-turn',
                                'item':{'id':'private-streamed-command','type':'commandExecution','status':'completed',
                                    'command':'synthetic-check','cwd':'/synthetic/tool-workspace','aggregatedOutput':'最终结果已校正 🐙\\n'+('分页正文 🐙<script>仅文本</script>\\n'*6000),
                                    'exitCode':0,'durationMs':17,'processId':'private-synthetic-process'}}})
                            emit({'method':'item/agentMessage/delta','params':{'threadId':'private-fixture-thread',
                                'turnId':'private-turn','itemId':'answer','delta':' · 原请求回复已确认'}})
                    else: raise RuntimeError('unexpected callback')
                    continue
                if method=='initialized': continue
                if method=='initialize': result={'userAgent':'synthetic-request-fixture'}
                elif method=='thread/resume':
                    assert frame['params']=={'threadId':'private-fixture-thread','excludeTurns':True}
                    result={'thread':{'id':'private-fixture-thread'}}
                elif method=='thread/read':
                    result={'thread':{'id':'private-fixture-thread','createdAt':1,'updatedAt':100,
                        'status':{'type':'active','activeFlags':[]},'turns':[{'id':'private-turn','status':'inProgress',
                        'itemsView':'full','items':[{'id':'answer','type':'agentMessage','text':'合成基线'}]}]}}
                elif method=='turn/steer':
                    assert frame['params']['threadId']=='private-fixture-thread'
                    assert frame['params']['expectedTurnId']=='private-turn'
                    assert frame['params']['input']==[{'type':'text','text':'触发合成请求','text_elements':[]}]
                    result={'turnId':'private-turn'}
                else: raise RuntimeError('unexpected method')
                emit({'id':frame['id'],'result':result})
                if method=='turn/steer':
                    emit({'id':'private-question-callback','method':'item/tool/requestUserInput','params':{
                        'threadId':'private-fixture-thread','turnId':'private-turn','itemId':'private-question-item','isBlocking':True,
                        'questions':[{'id':'private-theme','header':'外观','question':'选择外观？','isOther':True,'options':[
                            {'label':'浅色','description':'浅色主题'},{'label':'深色','description':'深色主题'}]},
                            {'id':'private-secret','header':'保密输入','question':'输入合成测试文本','isSecret':True,'options':None}]}})
        finally:
            counts['stopped']=True; status()
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let server = MobileSyncServer(port: 59407, token: "synthetic-request-pairing", listenOnLoopbackOnly: true,
            dataProvider: MobileSyncServerTests.MockDataProvider())
        let store = try RemoteOperationStore(databaseURL: root.appendingPathComponent("operations.sqlite"))
        let serverId = await server.remoteSessionService.serverId
        let operations = RemoteOperationService(serverId: serverId, access: server.remoteAccess, store: store) {
            .init(userId: "synthetic-owner", deviceId: $0.id.uuidString)
        }
        try server.installRemoteOperationService(operations)
        let adapter = ChatGPTReadAdapter(directory: .init(databaseURL: databaseURL, storageRoot: home, runtimeId: "rt_directory"), runtimeLabel: "合成历史目录")
        try await server.remoteReadService.register(adapter)
        let owned = RemoteOwnedChatGPTService(sources: [adapter], directory: root.appendingPathComponent("journals"),
            reads: server.remoteReadService, sessions: server.remoteSessionService, operations: operations)
        do {
            let choices = try await owned.choices(), choice = try #require(choices.first)
            let runtime = try await owned.attach(sourceRuntimeId: choice.sourceRuntimeId, sessionId: choice.sessionId,
                executable: executable, allowSteer: true)
            await server.remoteAccess.setDevelopmentEnabled(true)
            let origin = "http://127.0.0.1:5200"
            let actions: Set<RemoteAction> = [.listSessions, .readHistory, .sendMessage, .interrupt, .approve, .answer]
            let writable = try await server.remoteAccess.issueDevelopment(scopes: [
                .init(agentId: "agent.chatgpt", runtimeId: runtime.id, sessionId: nil, actions: actions),
                .init(agentId: "agent.chatgpt", runtimeId: "rt_directory", sessionId: nil, actions: actions)], origin: origin)
            let readonly = try await server.remoteAccess.issueDevelopment(scopes: [
                .init(agentId: "agent.chatgpt", runtimeId: runtime.id, sessionId: nil, actions: [.listSessions, .readHistory])], origin: origin)
            try server.start()
            for _ in 0..<100 {
                if server.status == .ready { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try #require(server.status == .ready)
            let config = root.appendingPathComponent("connection.json")
            try JSONSerialization.data(withJSONObject: ["serverURL": "http://127.0.0.1:59407", "serverId": serverId,
                "runtimeId": runtime.id, "sessionId": runtime.sessionId, "origin": origin,
                "token": writable.token, "readonlyToken": readonly.token,
                "expiresAt": ISO8601DateFormatter().string(from: writable.principal.expiresAt)]).write(to: config, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
            FileHandle.standardOutput.write(Data("Owned request fixture ready; synthetic stdio only\n".utf8))
            // Visual reviews take longer than the headless integration run.
            // This changes only the fixture lifetime, never grant expiry.
            let lifetime = min(600, max(1, Int(ProcessInfo.processInfo.environment["TOMO_REMOTE_REQUEST_FIXTURE_SECONDS"] ?? "180") ?? 180))
            for _ in 0..<lifetime {
                if FileManager.default.fileExists(atPath: root.appendingPathComponent("stop").path) { break }
                try await Task.sleep(for: .seconds(1))
            }
            await owned.stop()
            await operations.shutdown()
            server.stop()
            try? FileManager.default.removeItem(at: config)
        } catch {
            await owned.stop(); await operations.shutdown(); server.stop(); throw error
        }
    }
}
