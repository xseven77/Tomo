import Foundation
import Testing
@testable import Tomo

private actor RuntimeRPCFixture {
    var channel: AgentRPCChannel?
    var stops = 0
    var methods: [String] = []
    var malformedHandshake = false
    var holdRead = false
    var holdResume = false
    var wrongResume = false
    var badEphemeralStart = false
    var ephemeralThread = false
    var startParams: AgentJSON?
    var resumeParams: AgentJSON?
    var interruptParams: AgentJSON?
    func setBadEphemeralStart() { badEphemeralStart = true }
    func configureResume(hold: Bool = false, wrong: Bool = false) { holdResume = hold; wrongResume = wrong }
    func configure(_ channel: AgentRPCChannel, malformed: Bool = false, hold: Bool = false) {
        self.channel = channel; self.malformedHandshake = malformed; self.holdRead = hold
    }
    func stop() async { stops += 1; await channel?.close() }
    func write(_ data: Data) async throws {
        guard case .object(let fields) = try JSONDecoder().decode(AgentJSON.self, from: data), case .string(let method) = fields["method"] else { throw AgentRPCError.invalidFrame }
        methods.append(method)
        guard let id = fields["id"] else { #expect(method == "initialized"); return }
        let result: AgentJSON
        if method == "initialize" { result = malformedHandshake ? .object([:]) : .object(["userAgent": .string("fixture")]) }
        else if method == "thread/resume" {
            resumeParams = fields["params"]
            if holdResume { return }
            guard case .object(let params) = fields["params"], let thread = params["threadId"] else { throw AgentRPCError.invalidFrame }
            result = .object(["thread": .object(["id": wrongResume ? .string("foreign") : thread])])
        }
        else if method == "thread/start" {
            startParams = fields["params"]
            ephemeralThread = true
            guard case .object(let params) = fields["params"], let cwd = params["cwd"] else {throw AgentRPCError.invalidFrame}
            result = .object(["thread": .object([
                "id": .string("private-thread"), "ephemeral": .bool(!badEphemeralStart), "path": .null, "cwd": cwd])])
        }
        else if method == "thread/read" {
            if holdRead { return }
            guard case .object(let params) = fields["params"], let thread = params["threadId"] else { throw AgentRPCError.invalidFrame }
            result = .object(["thread": .object(["id": thread, "createdAt": .integer(1), "updatedAt": .integer(100),
                "ephemeral": .bool(ephemeralThread), "path": .null,
                "status": .object(["type": .string(ephemeralThread ? "idle" : "active"), "activeFlags": .array([])]),
                "turns": ephemeralThread ? .array([]) : .array([.object(["id": .string("turn"), "status": .string("inProgress"), "itemsView": .string("full"),
                    "items": .array([.object(["id": .string("item"), "type": .string("agentMessage"), "text": .string("基线")])])])])])])
        } else if method == "turn/steer" {
            guard case .object(let params) = fields["params"], params["expectedTurnId"] == .string("turn"),
                  params["threadId"] == .string("thread") else {throw AgentRPCError.invalidFrame}
            result = .object(["turnId": .string("turn")])
        } else if method == "turn/interrupt" {
            interruptParams = fields["params"]
            guard case .object(let params) = fields["params"], let thread = params["threadId"], let turn = params["turnId"] else {throw AgentRPCError.invalidFrame}
            var event = try JSONEncoder().encode(AgentJSON.object(["method": .string("turn/completed"), "params": .object([
                "threadId": thread, "turn": .object(["id": turn, "status": .string("interrupted"), "items": .array([
                    .object(["id": .string("item"), "type": .string("agentMessage"), "text": .string("已中断")])])])])]))
            event.append(10); try await channel?.receive(event)
            result = .object([:])
        } else { Issue.record("unexpected vendor command: \(method)"); throw AgentRPCError.invalidFrame }
        var response = try JSONEncoder().encode(AgentJSON.object(["id": id, "result": result])); response.append(10)
        try await channel?.receive(response)
    }
}

struct ChatGPTRuntimeCoordinatorTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    private func wait(_ condition: @escaping @Sendable () async throws -> Bool) async throws {
        for _ in 0..<400 { if try await condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw AgentRPCError.timedOut
    }
    private var principal: RemoteAccessStore.Principal {
        .init(id: UUID(), expiresAt: Date().addingTimeInterval(60), scopes: [.init(agentId: "agent.chatgpt", runtimeId: "runtime", sessionId: nil, actions: [.readHistory])], origin: nil, generation: 1)
    }

    @Test func onlyConfirmedEphemeralThreadPermitsFreshStart() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let fixture = RuntimeRPCFixture(), service = RemoteSessionService(serverId: "server")
        let journal = try RemoteSessionJournal(databaseURL: root.appendingPathComponent("journal.sqlite"))
        let channel = AgentRPCChannel(writer: {try await fixture.write($0)}); await fixture.configure(channel)
        let runtime = try ChatGPTRuntimeCoordinator(serverId: "server", runtimeId: "runtime", channel: channel,
            journal: journal, service: service, stopTransport: {await fixture.stop()})
        try await runtime.start()
        try await runtime.createOwnedEphemeralSession(sessionId: "new-session", workspace: root)
        #expect(await fixture.startParams == .object(["ephemeral": .bool(true), "cwd": .string(root.path)]))
        try await runtime.attach(sessionId: "new-session")
        let access = RemoteAccessStore(); await access.setDevelopmentEnabled(true)
        let ledger = try RemoteOperationStore(databaseURL: root.appendingPathComponent("operations.sqlite"))
        let operations = RemoteOperationService(serverId: "server", access: access, store: ledger) {_ in
            RemoteOperationOwner(userId: "local", deviceId: "phone")}
        let ref = try await runtime.publishOwnedControl(sessionId: "new-session", operations: operations, allowSteer: false)
        let snapshot = try await journal.snapshot(ref: ref)
        #expect(snapshot.projection.control.allowedActions.contains("message.send"))
        let context = try await runtime.ownedCommandAdapter()
        let request = RemoteOperationRequest(ref: ref, executionEpoch: snapshot.projection.control.executionEpoch,
            action: .sendMessage, body: .object([
                "clientMessageId": .string("new-message"), "mode": .string("start"),
                "expectedControlRevision": .integer(Int64(snapshot.projection.control.controlRevision)),
                "input": .array([.object(["type": .string("text"), "text": .string("hello")])])]))
        try await context.validate(request)
        #expect(await fixture.methods.filter {$0 == "turn/start"}.isEmpty)
        await runtime.stop(); await operations.shutdown()
    }

    @Test func malformedEphemeralAcknowledgmentStopsPrivateRuntime() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let fixture = RuntimeRPCFixture(), service = RemoteSessionService(serverId: "server")
        let journal = try RemoteSessionJournal(databaseURL: root.appendingPathComponent("journal.sqlite"))
        let channel = AgentRPCChannel(writer: {try await fixture.write($0)}); await fixture.configure(channel)
        let runtime = try ChatGPTRuntimeCoordinator(serverId: "server", runtimeId: "runtime", channel: channel,
            journal: journal, service: service, stopTransport: {await fixture.stop()})
        try await runtime.start(); await fixture.setBadEphemeralStart()
        await #expect(throws: ChatGPTRuntimeError.invalidResume) {
            try await runtime.createOwnedEphemeralSession(sessionId: "new-session", workspace: root)
        }
        #expect(await runtime.currentState() == .failed)
        #expect(await fixture.stops == 1)
    }

    @Test func explicitSteerGrantPublishesOnlyRunningCapabilityAndPreservesReadonlyScopes() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let fixture = RuntimeRPCFixture(), service = RemoteSessionService(serverId: "server")
        let journal = try RemoteSessionJournal(databaseURL: root.appendingPathComponent("journal.sqlite"))
        let channel = AgentRPCChannel(writer: {try await fixture.write($0)}); await fixture.configure(channel)
        let runtime = try ChatGPTRuntimeCoordinator(serverId: "server", runtimeId: "runtime", channel: channel,
            journal: journal, service: service, stopTransport: {await fixture.stop()})
        let access = RemoteAccessStore(), owner = RemoteOperationOwner(userId: "local", deviceId: "phone")
        await access.setDevelopmentEnabled(true)
        let issued = try await access.issueDevelopment(scopes: [.init(agentId: "agent.chatgpt", runtimeId: "runtime",
            sessionId: "session", actions: [.readHistory, .sendMessage, .interrupt])], origin: nil)
        let ledger = try RemoteOperationStore(databaseURL: root.appendingPathComponent("operations.sqlite"))
        let operations = RemoteOperationService(serverId: "server", access: access, store: ledger) {_ in owner}
        try await runtime.start(); try await runtime.resumeOwnedSession(sessionId: "session", vendorThreadId: "thread")
        try await runtime.attach(sessionId: "session")
        let ref = try await runtime.publishOwnedControl(sessionId: "session", operations: operations, allowSteer: true)
        let publicState = try JSONDecoder().decode(RemoteSessionControl.self,
            from: try await service.sync(sessionId: "session", query: [:], principal: issued.principal))
        #expect(publicState.allowedActions.contains("message.send"))
        let readonly = try JSONDecoder().decode(RemoteSessionControl.self,
            from: try await service.sync(sessionId: "session", query: [:], principal: principal))
        #expect(readonly.allowedActions == ["history.read"] && readonly.controlMode == "readOnly")
        let body = try JSONEncoder().encode(AgentJSON.object([
            "executionEpoch": .string(publicState.executionEpoch), "clientMessageId": .string("client-steer"),
            "mode": .string("steer"), "expectedControlRevision": .integer(Int64(publicState.controlRevision)),
            "expectedTurnId": .string(try #require(publicState.currentTurnId)),
            "input": .array([.object(["type": .string("text"), "text": .string("追加输入")])])]))
        let accepted = try await operations.submit(sessionId: "session", query: [:], action: .sendMessage,
            key: "owned-steer-123456789", body: body, principal: issued.principal)
        try await wait {try await ledger.operation(id: accepted.operationId, owner: owner, ref: ref).state == .applied}
        let adapter = try await runtime.ownedCommandAdapter()
        _ = try await adapter.apply(.init(ref: ref, executionEpoch: publicState.executionEpoch, action: .interrupt,
            body: .object(["turnId": .string(try #require(publicState.currentTurnId))])))
        try await wait {try await journal.snapshot(ref: ref).projection.control.state == "interrupted"}
        let after = try JSONDecoder().decode(RemoteSessionControl.self,
            from: try await service.sync(sessionId: "session", query: [:], principal: issued.principal))
        #expect(!after.allowedActions.contains("message.send") && after.currentTurnId == nil)
        await #expect(throws: RemoteCommandError.self) {
            try await operations.submit(sessionId: "session", query: [:], action: .sendMessage,
                key: "stopped-steer-123456789", body: body, principal: issued.principal)
        }
        #expect(await fixture.methods.filter {$0 == "turn/steer"}.count == 1)
        #expect(await fixture.methods.filter {$0 == "turn/start"}.isEmpty)
        await runtime.stop(); await operations.shutdown()
    }

    @Test func confirmedOwnerInterruptFlowsThroughLedgerRPCAndLiveEvents() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let fixture = RuntimeRPCFixture(), service = RemoteSessionService(serverId: "server")
        let journal = try RemoteSessionJournal(databaseURL: root.appendingPathComponent("journal.sqlite"))
        let channel = AgentRPCChannel(writer: {try await fixture.write($0)}); await fixture.configure(channel)
        let runtime = try ChatGPTRuntimeCoordinator(serverId: "server", runtimeId: "runtime", channel: channel, journal: journal, service: service, stopTransport: {await fixture.stop()})
        try await runtime.start(); try await runtime.resumeOwnedSession(sessionId: "session", vendorThreadId: "thread")
        try await runtime.attach(sessionId: "session"); try await runtime.enableOwnedInterrupt(sessionId: "session")
        let ref = RemoteSessionRef(serverId: "server", agentId: "agent.chatgpt", runtimeId: "runtime", sessionId: "session")
        let before = try await journal.snapshot(ref: ref)
        #expect(before.projection.control.controlMode == "live")
        #expect(before.projection.control.allowedActions == ["history.read", "turn.interrupt"])
        let adapter = try await runtime.ownedCommandAdapter()
        let request = RemoteOperationRequest(ref: ref, executionEpoch: before.projection.control.executionEpoch, action: .interrupt,
            body: .object(["turnId": .string(try #require(before.projection.control.currentTurnId))]))
        let ledger = try RemoteOperationStore(databaseURL: root.appendingPathComponent("operations.sqlite"))
        let dispatcher = RemoteOperationDispatcher(store: ledger, adapter: adapter) {_, _ in}
        let owner = RemoteOperationOwner(userId: "fixture-user", deviceId: "fixture-phone")
        let accepted = try await dispatcher.submit(owner: owner, key: "owner-interrupt-123456", request: request)
        let applied = try await dispatcher.execute(id: accepted.operationId, owner: owner, ref: ref, executionEpoch: request.executionEpoch)
        #expect(applied.state == .applied && applied.turnId == before.projection.control.currentTurnId)
        #expect(await fixture.interruptParams == .object(["threadId": .string("thread"), "turnId": .string("turn")]))
        try await wait {try await journal.snapshot(ref: ref).projection.control.state == "interrupted"}
        let after = try await journal.snapshot(ref: ref)
        #expect(after.projection.control.controlMode == "live" && after.projection.control.allowedActions == ["history.read"])
        #expect(after.projection.messages.first?.content.first?.text == "已中断")
        #expect(try await dispatcher.submit(owner: owner, key: "owner-interrupt-123456", request: request) == applied)
        #expect(try await dispatcher.execute(id: accepted.operationId, owner: owner, ref: ref, executionEpoch: request.executionEpoch) == applied)
        #expect(await fixture.methods.filter {$0 == "turn/interrupt"}.count == 1)
        let publicData = try await service.sync(sessionId: "session", query: [:], principal: principal)
        let publicSync = try #require(try JSONSerialization.jsonObject(with: publicData) as? [String: Any])
        #expect(publicSync["controlMode"] as? String == "readOnly")
        #expect(publicSync["allowedActions"] as? [String] == ["history.read"])
        await runtime.detach(sessionId: "session")
        await #expect(throws: ChatGPTRuntimeError.notSubscribed) {try await adapter.validate(request)}
        await runtime.stop()
    }

    @Test func observedSubscriptionCannotClaimOwnerControl() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let fixture = RuntimeRPCFixture(), service = RemoteSessionService(serverId: "server")
        let journal = try RemoteSessionJournal(databaseURL: root.appendingPathComponent("journal.sqlite"))
        let channel = AgentRPCChannel(writer: {try await fixture.write($0)}); await fixture.configure(channel)
        let runtime = try ChatGPTRuntimeCoordinator(serverId: "server", runtimeId: "runtime", channel: channel, journal: journal, service: service, stopTransport: {await fixture.stop()})
        try await runtime.start(); try await runtime.registerSubscription(sessionId: "session", vendorThreadId: "thread")
        try await runtime.attach(sessionId: "session")
        await #expect(throws: ChatGPTRuntimeError.notSubscribed) {try await runtime.enableOwnedInterrupt(sessionId: "session")}
        #expect(await fixture.methods.filter {$0 == "turn/interrupt"}.isEmpty)
        await runtime.stop()
    }

    @Test func ownerContextTracksCurrentTurnAndUnsupportedRequestsDisableCommands() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let fixture = RuntimeRPCFixture(), service = RemoteSessionService(serverId: "server")
        let journal = try RemoteSessionJournal(databaseURL: root.appendingPathComponent("journal.sqlite"))
        let channel = AgentRPCChannel(writer: {try await fixture.write($0)}); await fixture.configure(channel)
        let runtime = try ChatGPTRuntimeCoordinator(serverId: "server", runtimeId: "runtime", channel: channel, journal: journal, service: service, stopTransport: {await fixture.stop()})
        try await runtime.start(); try await runtime.resumeOwnedSession(sessionId: "session", vendorThreadId: "thread")
        try await runtime.attach(sessionId: "session"); try await runtime.enableOwnedInterrupt(sessionId: "session", allowSteer: true)
        let ref = RemoteSessionRef(serverId: "server", agentId: "agent.chatgpt", runtimeId: "runtime", sessionId: "session")
        let before = try await journal.snapshot(ref: ref)
        #expect(before.projection.control.allowedActions.contains("message.send"))
        let adapter = try await runtime.ownedCommandAdapter()
        let old = RemoteOperationRequest(ref: ref, executionEpoch: before.projection.control.executionEpoch, action: .interrupt,
            body: .object(["turnId": .string(try #require(before.projection.control.currentTurnId))]))
        var next = try JSONEncoder().encode(AgentJSON.object(["method": .string("turn/started"), "params": .object([
            "threadId": .string("thread"), "turn": .object(["id": .string("next-turn"), "status": .string("inProgress"), "items": .array([])])])]))
        next.append(10); try await channel.receive(next)
        let nextTurn = ChatGPTEventProjector(ref: ref, vendorThreadId: "thread").identifier("turn", "next-turn")
        try await wait {try await journal.snapshot(ref: ref).projection.control.currentTurnId == nextTurn}
        await #expect(throws: ChatGPTCommandError.controlChanged) {try await adapter.validate(old)}
        let current = RemoteOperationRequest(ref: ref, executionEpoch: old.executionEpoch, action: .interrupt, body: .object(["turnId": .string(nextTurn)]))
        try await adapter.validate(current)
        var unsupported = try JSONEncoder().encode(AgentJSON.object(["id": .string("private-approval"),
            "method": .string("item/commandExecution/requestApproval"), "params": .object(["threadId": .string("thread")])]))
        unsupported.append(10); try await channel.receive(unsupported)
        try await wait {try await journal.snapshot(ref: ref).projection.control.controlMode == "unavailable"}
        #expect(try await journal.snapshot(ref: ref).projection.control.allowedActions.isEmpty)
        await #expect(throws: ChatGPTEventPumpError.invalidBinding) {try await adapter.validate(current)}
        guard case .rejected = try await adapter.apply(current) else {Issue.record("degraded control executed"); return}
        #expect(await fixture.methods.filter {$0 == "turn/interrupt"}.isEmpty)
        await runtime.stop()
    }

    @Test func actualHTTPInterruptAndOperationQueriesRequireCurrentScopedDeviceIdentity() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let server = MobileSyncServer(port: 59437, token: "legacy-pairing", listenOnLoopbackOnly: true, dataProvider: MobileSyncServerTests.MockDataProvider())
        defer {server.stop()}
        let fixture = RuntimeRPCFixture()
        let journal = try RemoteSessionJournal(databaseURL: root.appendingPathComponent("journal.sqlite"))
        let channel = AgentRPCChannel(writer: {try await fixture.write($0)}); await fixture.configure(channel)
        let serverId = await server.remoteSessionService.serverId
        let runtime = try ChatGPTRuntimeCoordinator(serverId: serverId, runtimeId: "runtime", channel: channel, journal: journal,
            service: server.remoteSessionService, stopTransport: {await fixture.stop()})
        try await runtime.start(); try await runtime.resumeOwnedSession(sessionId: "session", vendorThreadId: "thread")
        try await runtime.attach(sessionId: "session")
        let ref = RemoteSessionRef(serverId: serverId, agentId: "agent.chatgpt", runtimeId: "runtime", sessionId: "session")
        let snapshot = try await journal.snapshot(ref: ref)
        let ledger = try RemoteOperationStore(databaseURL: root.appendingPathComponent("operations.sqlite"))
        // Test-only local verifier. Production must supply TomoServer-verified
        // user/device identity and membership; no such verifier is installed yet.
        let operations = RemoteOperationService(serverId: serverId, access: server.remoteAccess, store: ledger) {
            .init(userId: "fixture-local-owner", deviceId: $0.id.uuidString)
        }
        await server.remoteAccess.setDevelopmentEnabled(true)
        let scope = RemoteAccessStore.Scope(agentId: ref.agentId, runtimeId: ref.runtimeId, sessionId: ref.sessionId, actions: [.readHistory, .interrupt])
        let issued = try await server.remoteAccess.issueDevelopment(scopes: [scope], origin: nil)
        let other = try await server.remoteAccess.issueDevelopment(scopes: [scope], origin: nil)
        let readOnly = try await server.remoteAccess.issueDevelopment(scopes: [.init(agentId: ref.agentId, runtimeId: ref.runtimeId, sessionId: ref.sessionId, actions: [.readHistory])], origin: nil)
        try server.start(); try await wait {server.status == .ready}
        let client = URLSession(configuration: .ephemeral); defer {client.invalidateAndCancel()}
        let body: [String: AgentJSON] = ["executionEpoch": .string(snapshot.projection.control.executionEpoch),
            "turnId": .string(try #require(snapshot.projection.control.currentTurnId))]
        func http(_ path: String, method: String = "GET", token: String, key: String? = nil, input: [String: AgentJSON]? = nil) async throws -> (Int, Data) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:59437/api/v1/remote/" + path)!)
            request.timeoutInterval = 5; request.httpMethod = method
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            if let key {request.setValue(key, forHTTPHeaderField: "Idempotency-Key")}
            if let input {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(AgentJSON.object(input))
            }
            let (data, response) = try await client.data(for: request)
            return (try #require((response as? HTTPURLResponse)?.statusCode), data)
        }
        #expect(try await http("sessions/session/interrupt", method: "POST", token: issued.token, key: "http-interrupt-123456", input: body).0 == 501)
        #expect(try await http("operations/unknown", token: issued.token).0 == 501)
        try server.installRemoteOperationService(operations)
        #expect(try await runtime.publishOwnedInterrupt(sessionId: "session", operations: operations) == ref)
        let controlSync = try await http("sessions/session/sync", token: issued.token)
        let publicControl = try JSONDecoder().decode(RemoteSessionControl.self, from: controlSync.1)
        #expect(controlSync.0 == 200 && publicControl.controlMode == "live" && publicControl.allowedActions.contains("turn.interrupt"))
        let readonlySync = try await http("sessions/session/sync", token: readOnly.token)
        #expect(try JSONDecoder().decode(RemoteSessionControl.self, from: readonlySync.1).controlMode == "readOnly")
        #expect(try await http("sessions/session/interrupt", method: "POST", token: "legacy-pairing", key: "http-interrupt-123456", input: body).0 == 401)
        #expect(try await http("sessions/session/interrupt", method: "POST", token: readOnly.token, key: "http-interrupt-123456", input: body).0 == 403)
        #expect(try await http("sessions/session/interrupt?agent_id=agent.chatgpt&runtime_id=foreign", method: "POST", token: issued.token, key: "http-interrupt-123456", input: body).0 == 403)
        #expect(try await http("sessions/session/interrupt", method: "POST", token: issued.token, key: "short", input: body).0 == 400)
        var foreignEpoch = body; foreignEpoch["executionEpoch"] = .string("foreign")
        #expect(try await http("sessions/session/interrupt", method: "POST", token: issued.token, key: "http-interrupt-123456", input: foreignEpoch).0 == 409)
        var forgedOwner = body; forgedOwner["userId"] = .string("client-owner")
        #expect(try await http("sessions/session/interrupt", method: "POST", token: issued.token, key: "http-interrupt-123456", input: forgedOwner).0 == 400)
        let baseline = try JSONSerialization.jsonObject(with: controlSync.1) as! [String: Any]
        var streamRequest = URLRequest(url: URL(string: "http://127.0.0.1:59437/api/v1/remote/sessions/session/events")!)
        streamRequest.timeoutInterval = 5
        streamRequest.setValue("Bearer " + issued.token, forHTTPHeaderField: "Authorization")
        streamRequest.setValue(try #require(baseline["eventCursor"] as? String), forHTTPHeaderField: "Last-Event-ID")
        let (streamBytes, streamResponse) = try await client.bytes(for: streamRequest)
        #expect((streamResponse as? HTTPURLResponse)?.statusCode == 200)
        let sideband = Task { () throws -> String in
            var operationEvent = false
            for try await line in streamBytes.lines {
                if line.hasPrefix("event:") {operationEvent = line == "event: operation.updated"}
                if operationEvent, line.hasPrefix("data: "),
                   let frame = try JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any],
                   let operation = frame["operation"] as? [String: Any], operation["state"] as? String == "applied" {
                    #expect(frame["sequence"] == nil && frame["streamEpoch"] == nil)
                    #expect(frame["serverId"] as? String == ref.serverId && frame["runtimeId"] as? String == ref.runtimeId)
                    return try #require(operation["operationId"] as? String)
                }
            }
            throw AgentRPCError.disconnected
        }
        defer {sideband.cancel()}
        let (status, receipt) = try await http("sessions/session/interrupt", method: "POST", token: issued.token, key: "http-interrupt-123456", input: body)
        #expect(status == 202)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let accepted = try decoder.decode(RemoteOperation.self, from: receipt)
        let owner = RemoteOperationOwner(userId: "fixture-local-owner", deviceId: issued.principal.id.uuidString)
        try await wait {try await ledger.operation(id: accepted.operationId, owner: owner, ref: ref).state == .applied}
        #expect(try await sideband.value == accepted.operationId)
        let (queryStatus, queryData) = try await http("operations/" + accepted.operationId, token: issued.token)
        #expect(queryStatus == 200)
        let result = try decoder.decode(RemoteOperation.self, from: queryData)
        #expect(result.state == .applied && result.turnId == snapshot.projection.control.currentTurnId)
        let duplicate = try await http("sessions/session/interrupt", method: "POST", token: issued.token, key: "http-interrupt-123456", input: body)
        #expect(duplicate.0 == 202)
        #expect(try decoder.decode(RemoteOperation.self, from: duplicate.1) == result)
        let byKey = try await http("sessions/session/operations/by-key/http-interrupt-123456", token: issued.token)
        #expect(byKey.0 == 200)
        #expect(try decoder.decode(RemoteOperation.self, from: byKey.1) == result)
        var changed = body; changed["turnId"] = .string("changed")
        #expect(try await http("sessions/session/interrupt", method: "POST", token: issued.token, key: "http-interrupt-123456", input: changed).0 == 409)
        #expect(try await http("operations/" + accepted.operationId, token: other.token).0 == 404)
        #expect(try await http("operations/" + accepted.operationId, token: readOnly.token).0 == 404)
        #expect(await fixture.methods.filter {$0 == "turn/interrupt"}.count == 1)
        await server.remoteAccess.revoke(issued.principal)
        #expect(try await http("operations/" + accepted.operationId, token: issued.token).0 == 401)
        await runtime.stop()
        #expect(await operations.publishedActions(ref: ref, executionEpoch: snapshot.projection.control.executionEpoch).isEmpty)
        await operations.shutdown()
    }

    @Test func stoppingPublishedOwnerControlRejectsUndispatchedLedgerAndWithdrawsCapabilities() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let fixture = RuntimeRPCFixture(), service = RemoteSessionService(serverId: "server")
        let journal = try RemoteSessionJournal(databaseURL: root.appendingPathComponent("journal.sqlite"))
        let channel = AgentRPCChannel(writer: {try await fixture.write($0)}); await fixture.configure(channel)
        let runtime = try ChatGPTRuntimeCoordinator(serverId: "server", runtimeId: "runtime", channel: channel,
            journal: journal, service: service, stopTransport: {await fixture.stop()})
        let access = RemoteAccessStore(), owner = RemoteOperationOwner(userId: "local", deviceId: "phone")
        let ledger = try RemoteOperationStore(databaseURL: root.appendingPathComponent("operations.sqlite"))
        let operations = RemoteOperationService(serverId: "server", access: access, store: ledger) {_ in owner}
        try await runtime.start(); try await runtime.resumeOwnedSession(sessionId: "session", vendorThreadId: "thread")
        try await runtime.attach(sessionId: "session")
        let ref = try await runtime.publishOwnedInterrupt(sessionId: "session", operations: operations)
        let snapshot = try await journal.snapshot(ref: ref)
        let request = RemoteOperationRequest(ref: ref, executionEpoch: snapshot.projection.control.executionEpoch,
            action: .interrupt, body: .object(["turnId": .string(try #require(snapshot.projection.control.currentTurnId))]))
        let accepted = try await ledger.accept(owner: owner, key: "undispatched-control-123", request: request) {}
        await runtime.detach(sessionId: "session")
        #expect(await runtime.currentState() == .stopped)
        #expect(await operations.publishedActions(ref: ref, executionEpoch: request.executionEpoch).isEmpty)
        let rejected = try await ledger.operation(id: accepted.operationId, owner: owner, ref: ref)
        #expect(rejected.state == .rejected)
        #expect(await fixture.methods.filter {$0 == "turn/interrupt"}.isEmpty)
        await runtime.stop(); #expect(await fixture.stops == 1)
        await operations.shutdown()
    }

    @Test func explicitResumeAcknowledgesTheThreadBeforeReadOnlyPublication() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let fixture = RuntimeRPCFixture(), service = RemoteSessionService(serverId: "server")
        let journal = try RemoteSessionJournal(databaseURL: root.appendingPathComponent("journal.sqlite"))
        let channel = AgentRPCChannel(writer: {try await fixture.write($0)}); await fixture.configure(channel)
        let runtime = try ChatGPTRuntimeCoordinator(serverId: "server", runtimeId: "runtime", channel: channel, journal: journal, service: service, stopTransport: {await fixture.stop()})
        try await runtime.start()
        try await runtime.resumeOwnedSession(sessionId: "session", vendorThreadId: "thread")
        #expect(await fixture.resumeParams == .object(["threadId": .string("thread"), "excludeTurns": .bool(true)]))
        await #expect(throws: RemoteReadError.notFound) {try await service.sync(sessionId: "session", query: [:], principal: principal)}
        try await runtime.attach(sessionId: "session")
        _ = try await service.sync(sessionId: "session", query: [:], principal: principal)
        await #expect(throws: ChatGPTRuntimeError.duplicateSession) {try await runtime.resumeOwnedSession(sessionId: "session", vendorThreadId: "thread")}
        #expect(await fixture.methods.filter { $0 == "thread/resume" }.count == 1)
        await runtime.stop()
    }

    @Test func ambiguousResumeCancellationAndDetachCloseThePrivateRuntime() async throws {
        for detach in [false, true] {
            let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
            let fixture = RuntimeRPCFixture(), service = RemoteSessionService(serverId: "server")
            let journal = try RemoteSessionJournal(databaseURL: root.appendingPathComponent("journal.sqlite"))
            let channel = AgentRPCChannel(writer: {try await fixture.write($0)}); await fixture.configure(channel); await fixture.configureResume(hold: true)
            let runtime = try ChatGPTRuntimeCoordinator(serverId: "server", runtimeId: "runtime", channel: channel, journal: journal, service: service, stopTransport: {await fixture.stop()})
            try await runtime.start()
            let resume = Task {try await runtime.resumeOwnedSession(sessionId: "session", vendorThreadId: "thread")}
            try await wait {await fixture.methods.contains("thread/resume")}
            await #expect(throws: ChatGPTRuntimeError.duplicateSession) {try await runtime.registerSubscription(sessionId: "other", vendorThreadId: "thread")}
            if detach {await runtime.detach(sessionId: "session")} else {resume.cancel()}
            do {try await resume.value; Issue.record("ambiguous resume accepted")} catch {}
            #expect(await runtime.currentState() == .failed)
            #expect(await fixture.stops == 1)
            await #expect(throws: RemoteReadError.notFound) {try await service.sync(sessionId: "session", query: [:], principal: principal)}
            await runtime.stop()
        }
    }

    @Test func foreignResumeIdentityCannotRegisterASubscription() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let fixture = RuntimeRPCFixture(), service = RemoteSessionService(serverId: "server")
        let journal = try RemoteSessionJournal(databaseURL: root.appendingPathComponent("journal.sqlite"))
        let channel = AgentRPCChannel(writer: {try await fixture.write($0)}); await fixture.configure(channel); await fixture.configureResume(wrong: true)
        let runtime = try ChatGPTRuntimeCoordinator(serverId: "server", runtimeId: "runtime", channel: channel, journal: journal, service: service, stopTransport: {await fixture.stop()})
        try await runtime.start()
        await #expect(throws: ChatGPTRuntimeError.invalidResume) {try await runtime.resumeOwnedSession(sessionId: "session", vendorThreadId: "thread")}
        #expect(await runtime.currentState() == .failed)
        #expect(await fixture.stops == 1)
        #expect(!(await fixture.methods).contains("thread/read"))
    }

    @Test func subscriptionIsRequiredAndOwnedSourcesDisappearOnConcurrentStop() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let fixture = RuntimeRPCFixture(), service = RemoteSessionService(serverId: "server")
        let journal = try RemoteSessionJournal(databaseURL: root.appendingPathComponent("journal.sqlite"))
        let channel = AgentRPCChannel(writer: {try await fixture.write($0)}); await fixture.configure(channel)
        let runtime = try ChatGPTRuntimeCoordinator(serverId: "server", runtimeId: "runtime", channel: channel, journal: journal, service: service, stopTransport: {await fixture.stop()})
        try await runtime.start()
        await #expect(throws: ChatGPTRuntimeError.notSubscribed) {try await runtime.attach(sessionId: "session")}
        try await runtime.registerSubscription(sessionId: "session", vendorThreadId: "thread")
        try await runtime.attach(sessionId: "session")
        let data = try await service.sync(sessionId: "session", query: [:], principal: principal)
        #expect(String(decoding: data, as: UTF8.self).contains("基线"))
        await #expect(throws: ChatGPTRuntimeError.duplicateSession) {try await runtime.attach(sessionId: "session")}
        async let first: Void = runtime.stop(); async let second: Void = runtime.stop(); _ = await (first, second)
        #expect(await runtime.currentState() == .stopped)
        #expect(await fixture.stops == 1)
        await #expect(throws: RemoteReadError.notFound) {try await service.sync(sessionId: "session", query: [:], principal: principal)}
        #expect(await fixture.methods == ["initialize", "initialized", "thread/read", "thread/read"])
    }

    @Test func malformedHandshakeAndEOFReleaseTheTransportExactlyOnce() async throws {
        for malformed in [true, false] {
            let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
            let fixture = RuntimeRPCFixture(), service = RemoteSessionService(serverId: "server")
            let journal = try RemoteSessionJournal(databaseURL: root.appendingPathComponent("journal.sqlite"))
            let channel = AgentRPCChannel(writer: {try await fixture.write($0)}); await fixture.configure(channel, malformed: malformed)
            let runtime = try ChatGPTRuntimeCoordinator(serverId: "server", runtimeId: "runtime", channel: channel, journal: journal, service: service, stopTransport: {await fixture.stop()})
            if malformed { await #expect(throws: ChatGPTRuntimeError.invalidHandshake) {try await runtime.start()} }
            else { try await runtime.start(); await channel.close(); try await wait {await runtime.currentState() == .failed} }
            #expect(await runtime.currentState() == .failed); await runtime.stop(); #expect(await fixture.stops == 1)
        }
    }

    @Test func detachDuringReadCannotPublishALateSource() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let fixture = RuntimeRPCFixture(), service = RemoteSessionService(serverId: "server")
        let journal = try RemoteSessionJournal(databaseURL: root.appendingPathComponent("journal.sqlite"))
        let channel = AgentRPCChannel(writer: {try await fixture.write($0)}); await fixture.configure(channel, hold: true)
        let runtime = try ChatGPTRuntimeCoordinator(serverId: "server", runtimeId: "runtime", channel: channel, journal: journal, service: service, stopTransport: {await fixture.stop()})
        try await runtime.start(); try await runtime.registerSubscription(sessionId: "session", vendorThreadId: "thread")
        let attach = Task {try await runtime.attach(sessionId: "session")}
        try await wait {await fixture.methods.contains("thread/read")}
        await runtime.detach(sessionId: "session"); attach.cancel()
        do {try await attach.value; Issue.record("late attach published")} catch {}
        await #expect(throws: RemoteReadError.notFound) {try await service.sync(sessionId: "session", query: [:], principal: principal)}
        await runtime.stop()
    }

    @Test func mismatchedServerRejectsStartupAndClosesTheOwnedTransport() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let fixture = RuntimeRPCFixture(), service = RemoteSessionService(serverId: "foreign")
        let journal = try RemoteSessionJournal(databaseURL: root.appendingPathComponent("journal.sqlite"))
        let channel = AgentRPCChannel(writer: {try await fixture.write($0)}); await fixture.configure(channel)
        let runtime = try ChatGPTRuntimeCoordinator(serverId: "server", runtimeId: "runtime", channel: channel, journal: journal, service: service, stopTransport: {await fixture.stop()})
        await #expect(throws: ChatGPTRuntimeError.invalidConfiguration) {try await runtime.start()}
        #expect(await runtime.currentState() == .failed)
        #expect(await fixture.methods.isEmpty)
        #expect(await fixture.stops == 1)
        await runtime.stop()
        #expect(await fixture.stops == 1)
    }

    @Test func staleSourceLeaseCannotRemoveAReplacementRegistration() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let fixture = RuntimeRPCFixture(), service = RemoteSessionService(serverId: "server")
        let journal = try RemoteSessionJournal(databaseURL: root.appendingPathComponent("journal.sqlite"))
        let channel = AgentRPCChannel(writer: {try await fixture.write($0)}); await fixture.configure(channel)
        let runtime = try ChatGPTRuntimeCoordinator(serverId: "server", runtimeId: "runtime", channel: channel, journal: journal, service: service, stopTransport: {await fixture.stop()})
        try await runtime.start(); try await runtime.registerSubscription(sessionId: "session", vendorThreadId: "thread"); try await runtime.attach(sessionId: "session")
        let ref = RemoteSessionRef(serverId: "server", agentId: "agent.chatgpt", runtimeId: "runtime", sessionId: "session")
        await service.unregister(sessionId: "session")
        let replacement = try await service.register(ref: ref, journal: journal)
        await runtime.stop() // cleanup of its old lease must not delete replacement
        _ = try await service.sync(sessionId: "session", query: [:], principal: principal)
        await service.unregister(sessionId: "session", lease: replacement)
    }

    @Test func runtimeHydrationAndRPCDeltaAreVisibleThroughActualHTTPSyncAndSSE() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let server = MobileSyncServer(port: 59434, token: "old-pairing", listenOnLoopbackOnly: true, dataProvider: MobileSyncServerTests.MockDataProvider())
        defer {server.stop()}
        let service = server.remoteSessionService, fixture = RuntimeRPCFixture()
        let journal = try RemoteSessionJournal(databaseURL: root.appendingPathComponent("journal.sqlite"))
        let channel = AgentRPCChannel(writer: {try await fixture.write($0)}); await fixture.configure(channel)
        let serverId = await service.serverId
        let runtime = try ChatGPTRuntimeCoordinator(serverId: serverId, runtimeId: "runtime", channel: channel, journal: journal, service: service, stopTransport: {await fixture.stop()})
        do {
            try await runtime.start(); try await runtime.registerSubscription(sessionId: "session", vendorThreadId: "thread"); try await runtime.attach(sessionId: "session")
            await server.remoteAccess.setDevelopmentEnabled(true)
            let grant = try await server.remoteAccess.issueDevelopment(scopes: [.init(agentId: "agent.chatgpt", runtimeId: "runtime", sessionId: "session", actions: [.readHistory])], origin: nil)
            try server.start(); try await wait {server.status == .ready}
            let http = URLSession(configuration: .ephemeral); defer {http.invalidateAndCancel()}
            var request = URLRequest(url: URL(string: "http://127.0.0.1:59434/api/v1/remote/sessions/session/sync?agent_id=agent.chatgpt&runtime_id=runtime")!)
            request.timeoutInterval = 5; request.setValue("Bearer " + grant.token, forHTTPHeaderField: "Authorization")
            let (data, response) = try await http.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            let sync = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect((sync["messages"] as? [[String: Any]])?.count == 1)
            request.url = URL(string: "http://127.0.0.1:59434/api/v1/remote/sessions/session/events")!
            request.setValue(try #require(sync["eventCursor"] as? String), forHTTPHeaderField: "Last-Event-ID")
            let (bytes, eventResponse) = try await http.bytes(for: request)
            #expect((eventResponse as? HTTPURLResponse)?.statusCode == 200)
            var event = try JSONEncoder().encode(AgentJSON.object(["method": .string("item/agentMessage/delta"), "params": .object([
                "threadId": .string("thread"), "turnId": .string("turn"), "itemId": .string("item"), "delta": .string("实时追加")])]))
            event.append(10); try await channel.receive(event)
            var received = false
            for try await line in bytes.lines {
                guard line.hasPrefix("data: ") else {continue}
                let mapped = try JSONDecoder().decode(RemoteJournalEvent.self, from: Data(line.dropFirst(6).utf8))
                #expect(mapped.type == "message.delta" && mapped.sequence == 1)
                #expect(mapped.streamEpoch == sync["streamEpoch"] as? String)
                received = true; break
            }
            #expect(received)
            await runtime.stop()
            try await wait {server.remoteStreamCount == 0}
            #expect(await fixture.stops == 1)
        } catch {await runtime.stop(); throw error}
    }
}
