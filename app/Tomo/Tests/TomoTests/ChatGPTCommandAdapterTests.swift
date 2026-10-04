import Foundation
import Testing
@testable import Tomo

private actor CommandWire {
    var frames: [[String: AgentJSON]] = []
    func write(_ data: Data) throws {
        guard case .object(let value) = try JSONDecoder().decode(AgentJSON.self, from: data) else {throw AgentRPCError.invalidFrame}
        frames.append(value)
    }
    func next(_ count: Int = 1) async throws -> [String: AgentJSON] {
        for _ in 0..<1000 {
            if frames.count >= count {return frames[count - 1]}
            try await Task.sleep(for: .milliseconds(1))
        }
        throw AgentRPCError.timedOut
    }
}
private actor CommandContextStore {
    var value: ChatGPTCommandContext
    init(_ value: ChatGPTCommandContext) {self.value = value}
    func get() -> ChatGPTCommandContext {value}
    func set(_ value: ChatGPTCommandContext) {self.value = value}
}

struct ChatGPTCommandAdapterTests {
    private let ref = RemoteSessionRef(serverId: "server", agentId: "agent.chatgpt", runtimeId: "runtime", sessionId: "opaque-session")
    private func context(state: String = "idle", mode: String = "live", revision: Int = 4, epoch: String = "execution", permit: Bool = true,
                         vendorTurn: String? = nil, pending: Bool = false) -> ChatGPTCommandContext {
        let publicTurn = vendorTurn.map {ChatGPTEventProjector(ref: ref, vendorThreadId: "private-thread").identifier("turn", $0)}
        return .init(ref: ref, vendorThreadId: "private-thread", vendorCurrentTurnId: vendorTurn,
            control: .init(executionEpoch: epoch, controlRevision: revision, state: state, controlMode: mode,
                currentTurnId: publicTurn, allowedActions: ["message.send", "turn.interrupt"]),
            hasPendingRequests: pending, permitsFreshStart: permit)
    }
    private func start(body: [String: AgentJSON]? = nil) -> RemoteOperationRequest {
        .init(ref: ref, executionEpoch: "execution", action: .sendMessage, body: .object(body ?? [
            "clientMessageId": .string("client-message"), "expectedControlRevision": .integer(4), "mode": .string("start"),
            "input": .array([.object(["type": .string("text"), "text": .string("你好 🌿")])])]))
    }
    private func steer(_ value: ChatGPTCommandContext, turn: String? = nil) -> RemoteOperationRequest {
        start(body: ["clientMessageId": .string("steer-message"),
            "expectedControlRevision": .integer(Int64(value.control.controlRevision)), "mode": .string("steer"),
            "expectedTurnId": .string(turn ?? value.control.currentTurnId ?? "missing-turn"),
            "input": .array([.object(["type": .string("text"), "text": .string("追加中文 🐾")])])])
    }

    @Test func steerUsesAtomicVendorTurnPreconditionAndPreservesMessageIdentity() async throws {
        let wire = CommandWire(), value = context(state: "running", permit: false, vendorTurn: "private-active-turn")
        let channel = AgentRPCChannel(writer: {try await wire.write($0)})
        let adapter = ChatGPTCommandAdapter(channel: channel) {_ in value}
        try await adapter.validate(steer(value))
        let pending = Task {try await adapter.apply(steer(value))}
        let frame = try await wire.next()
        #expect(frame["method"] == .string("turn/steer"))
        #expect(frame["params"] == .object(["threadId": .string("private-thread"),
            "expectedTurnId": .string("private-active-turn"), "clientUserMessageId": .string("steer-message"),
            "input": .array([.object(["type": .string("text"), "text": .string("追加中文 🐾"), "text_elements": .array([])])])]))
        try await reply(channel, frame, result: .object(["turnId": .string("private-active-turn")]))
        guard case .applied(let turn) = try await pending.value else {Issue.record("steer not applied"); return}
        #expect(turn == value.control.currentTurnId)
        #expect(await wire.frames.count == 1)
        await channel.close()
    }

    @Test func staleForeignIdleAndPendingSteersNeverDispatchOrFallBackToStart() async throws {
        let wire = CommandWire(), value = context(state: "running", vendorTurn: "active")
        let current = CommandContextStore(value)
        let channel = AgentRPCChannel(writer: {try await wire.write($0)})
        let adapter = ChatGPTCommandAdapter(channel: channel) {_ in await current.get()}
        await #expect(throws: ChatGPTCommandError.controlChanged) {try await adapter.validate(steer(value, turn: "active"))}
        try await adapter.validate(steer(value))
        for changed in [context(), context(state: "completed"), context(state: "waitingForUser", vendorTurn: "active"),
                        context(state: "running", vendorTurn: "active", pending: true),
                        context(state: "running", revision: 5, vendorTurn: "active"),
                        context(state: "running", vendorTurn: "replacement"),
                        context(state: "running", mode: "readOnly", vendorTurn: "active")] {
            await current.set(changed)
            await #expect(throws: ChatGPTCommandError.self) {try await adapter.validate(steer(value))}
            guard case .rejected = try await adapter.apply(steer(value)) else {Issue.record("stale steer accepted"); continue}
        }
        #expect(await wire.frames.isEmpty)
        await channel.close()
    }

    @Test func steerMismatchedAckAndVendorFailureRemainUncertainWithoutRetry() async throws {
        for result in [AgentJSON.object(["turnId": .string("other-turn")]), .object([:]), .null] {
            let wire = CommandWire(), value = context(state: "running", vendorTurn: "active")
            let channel = AgentRPCChannel(writer: {try await wire.write($0)})
            let adapter = ChatGPTCommandAdapter(channel: channel) {_ in value}
            let pending = Task {try await adapter.apply(steer(value))}
            let frame = try await wire.next()
            try await reply(channel, frame, result: result)
            guard case .uncertain = try await pending.value else {Issue.record("unverified steer acknowledged"); continue}
            #expect(await wire.frames.count == 1)
            await channel.close()
        }
        let wire = CommandWire(), value = context(state: "running", vendorTurn: "active")
        let channel = AgentRPCChannel(writer: {try await wire.write($0)})
        let adapter = ChatGPTCommandAdapter(channel: channel) {_ in value}
        let pending = Task {try await adapter.apply(steer(value))}
        let frame = try await wire.next()
        try await reply(channel, frame, error: .object(["code": .integer(-32000), "message": .string("private vendor detail")]))
        guard case .uncertain = try await pending.value else {Issue.record("vendor failure must remain uncertain"); return}
        #expect(await wire.frames.count == 1)
        await channel.close()
    }

    @Test func durableSteerReceiptRetainsClientIdentityAndNeverRepeatsRPCForSameKey() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tomo-steer-ledger-" + UUID().uuidString)
        defer {try? FileManager.default.removeItem(at: directory)}
        let store = try RemoteOperationStore(databaseURL: directory.appendingPathComponent("operations.sqlite"))
        let wire = CommandWire(), value = context(state: "running", permit: false, vendorTurn: "active")
        let channel = AgentRPCChannel(writer: {try await wire.write($0)})
        let adapter = ChatGPTCommandAdapter(channel: channel) {_ in value}
        let dispatcher = RemoteOperationDispatcher(store: store, adapter: adapter) {_, _ in}
        let owner = RemoteOperationOwner(userId: "verified-user", deviceId: "verified-phone")
        let request = steer(value), key = "steer-key-123456789"
        let accepted = try await dispatcher.submit(owner: owner, key: key, request: request)
        #expect(accepted.clientMessageId == "steer-message")
        let executing = Task {try await dispatcher.execute(id: accepted.operationId, owner: owner, ref: ref, executionEpoch: "execution")}
        let frame = try await wire.next()
        try await reply(channel, frame, result: .object(["turnId": .string("active")]))
        let applied = try await executing.value
        #expect(applied.state == .applied)
        #expect(applied.clientMessageId == "steer-message")
        #expect(applied.turnId == value.control.currentTurnId)
        #expect(try await dispatcher.submit(owner: owner, key: key, request: request) == applied)
        #expect(try await dispatcher.execute(id: applied.operationId, owner: owner, ref: ref, executionEpoch: "execution") == applied)
        #expect(await wire.frames.count == 1)
        await channel.close()
    }
    private func reply(_ channel: AgentRPCChannel, _ request: [String: AgentJSON], result: AgentJSON? = nil, error: AgentJSON? = nil) async throws {
        var fields = ["id": request["id"]!]
        if let error {fields["error"] = error} else {fields["result"] = result ?? .object([:])}
        var data = try JSONEncoder().encode(AgentJSON.object(fields)); data.append(10)
        try await channel.receive(data)
    }

    @Test func startUsesTextOnlyMinimalRPCAndReturnsNamespacedTurn() async throws {
        let wire = CommandWire(), current = CommandContextStore(context())
        let channel = AgentRPCChannel(writer: {try await wire.write($0)})
        let adapter = ChatGPTCommandAdapter(channel: channel) {_ in await current.get()}
        try await adapter.validate(start())
        let pending = Task {try await adapter.apply(start())}
        let frame = try await wire.next()
        #expect(frame["method"] == .string("turn/start"))
        #expect(frame["params"] == .object(["threadId": .string("private-thread"), "clientUserMessageId": .string("client-message"),
            "input": .array([.object(["type": .string("text"), "text": .string("你好 🌿"), "text_elements": .array([])])])]))
        try await reply(channel, frame, result: .object(["turn": .object(["id": .string("private-turn"), "status": .string("inProgress"), "items": .array([])])]))
        guard case .applied(let turn) = try await pending.value else {Issue.record("expected applied"); return}
        #expect(turn == ChatGPTEventProjector(ref: ref, vendorThreadId: "private-thread").identifier("turn", "private-turn"))
        await channel.close()
    }

    @Test func interruptResolvesOpaqueIdentityAndIgnoresUnrelatedControlRevision() async throws {
        let wire = CommandWire(), value = context(state: "running", revision: 99, vendorTurn: "private-turn")
        let channel = AgentRPCChannel(writer: {try await wire.write($0)})
        let adapter = ChatGPTCommandAdapter(channel: channel) {_ in value}
        let request = RemoteOperationRequest(ref: ref, executionEpoch: "execution", action: .interrupt,
            body: .object(["turnId": .string(value.control.currentTurnId!)]))
        try await adapter.validate(request)
        let pending = Task {try await adapter.apply(request)}
        let frame = try await wire.next()
        #expect(frame["method"] == .string("turn/interrupt"))
        #expect(frame["params"] == .object(["threadId": .string("private-thread"), "turnId": .string("private-turn")]))
        try await reply(channel, frame)
        guard case .applied(let turn) = try await pending.value else {Issue.record("expected applied"); return}
        #expect(turn == value.control.currentTurnId)
        let foreign = RemoteOperationRequest(ref: ref, executionEpoch: "execution", action: .interrupt, body: .object(["turnId": .string("private-turn")]))
        await #expect(throws: ChatGPTCommandError.controlChanged) {try await adapter.validate(foreign)}
        await channel.close()
    }

    @Test func unsafeStaleReadOnlyAndBusyContextsNeverWriteRPC() async throws {
        let wire = CommandWire(), current = CommandContextStore(context())
        let channel = AgentRPCChannel(writer: {try await wire.write($0)})
        let adapter = ChatGPTCommandAdapter(channel: channel) {_ in await current.get()}
        for value in [context(permit: false), context(mode: "readOnly"), context(revision: 5), context(epoch: "changed"),
                      context(state: "running", vendorTurn: "turn"), context(pending: true)] {
            await current.set(value)
            await #expect(throws: ChatGPTCommandError.self) {try await adapter.validate(start())}
            guard case .rejected = try await adapter.apply(start()) else {Issue.record("must reject before RPC"); continue}
        }
        #expect(await wire.frames.isEmpty)
        await channel.close()
    }

    @Test func remoteOverridesAttachmentsAndUnsupportedActionsAreRejected() async throws {
        let wire = CommandWire(), value = context()
        let channel = AgentRPCChannel(writer: {try await wire.write($0)})
        let adapter = ChatGPTCommandAdapter(channel: channel) {_ in value}
        guard case .object(let body) = start().body else {return}
        for field in ["threadId", "cwd", "sandboxPolicy", "model", "approvalPolicy"] {
            var bad = body; bad[field] = .string("override")
            await #expect(throws: ChatGPTCommandError.invalidInput) {try await adapter.validate(start(body: bad))}
        }
        var attachment = body; attachment["input"] = .array([.object(["type": .string("image"), "url": .string("private")])])
        await #expect(throws: ChatGPTCommandError.invalidInput) {try await adapter.validate(start(body: attachment))}
        let approval = RemoteOperationRequest(ref: ref, executionEpoch: "execution", action: .approve, body: .object([:]))
        await #expect(throws: ChatGPTCommandError.unsupportedAction) {try await adapter.validate(approval)}
        #expect(await wire.frames.isEmpty)
        await channel.close()
    }

    @Test func oneThreadCannotDispatchConcurrentStartsAndContextIsRechecked() async throws {
        let wire = CommandWire(), current = CommandContextStore(context())
        let channel = AgentRPCChannel(writer: {try await wire.write($0)})
        let adapter = ChatGPTCommandAdapter(channel: channel) {_ in await current.get()}
        let first = Task {try await adapter.apply(start())}
        let frame = try await wire.next()
        guard case .rejected = try await adapter.apply(start()) else {Issue.record("concurrent start accepted"); return}
        await #expect(throws: ChatGPTCommandError.sessionBusy) {try await adapter.validate(start())}
        try await reply(channel, frame, result: .object(["turn": .object(["id": .string("turn"), "status": .string("inProgress"), "items": .array([])])]))
        _ = try await first.value
        // The response can beat the event pump. The same idle snapshot must not
        // permit a second start even after the first RPC has finished.
        guard case .rejected = try await adapter.apply(start()) else {Issue.record("stale idle snapshot accepted"); return}
        await current.set(context(state: "running", vendorTurn: "turn"))
        guard case .rejected = try await adapter.apply(start()) else {Issue.record("stale preflight accepted"); return}
        #expect(await wire.frames.count == 1)
        await channel.close()
    }

    @Test func malformedAckDisconnectAndInternalVendorErrorRemainUncertain() async throws {
        for code in [Int64(-32602), -32000, 0, 1] {
            let wire = CommandWire(), value = context()
            let channel = AgentRPCChannel(writer: {try await wire.write($0)})
            let adapter = ChatGPTCommandAdapter(channel: channel) {_ in value}
            let pending = Task {try await adapter.apply(start())}
            let frame = try await wire.next()
            if code == 1 {await channel.close()}
            else if code == 0 {try await reply(channel, frame, result: .object(["turn": .object(["id": .string("bad")])]))}
            else {try await reply(channel, frame, error: .object(["code": .integer(code), "message": .string("private vendor detail")]))}
            switch try await pending.value {
            case .rejected: #expect(code == -32602)
            case .uncertain: #expect(code != -32602)
            default: Issue.record("unverified ack must not be applied")
            }
            await channel.close()
        }
    }

    @Test func durableDispatcherUsesActualChannelAndRetriesReturnSameMappedOperation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tomo-command-ledger-" + UUID().uuidString)
        defer {try? FileManager.default.removeItem(at: directory)}
        let store = try RemoteOperationStore(databaseURL: directory.appendingPathComponent("operations.sqlite"))
        let wire = CommandWire(), value = context()
        let channel = AgentRPCChannel(writer: {try await wire.write($0)})
        let adapter = ChatGPTCommandAdapter(channel: channel) {_ in value}
        let service = RemoteOperationDispatcher(store: store, adapter: adapter) {_, _ in}
        let owner = RemoteOperationOwner(userId: "verified-user", deviceId: "verified-phone")
        let accepted = try await service.submit(owner: owner, key: "command-key-123456", request: start())
        #expect(await wire.frames.isEmpty)
        let pending = Task {try await service.execute(id: accepted.operationId, owner: owner, ref: ref, executionEpoch: "execution")}
        let frame = try await wire.next()
        #expect(try await store.operation(id: accepted.operationId, owner: owner, ref: ref).state == .dispatching)
        try await reply(channel, frame, result: .object(["turn": .object(["id": .string("private-result-turn"), "status": .string("inProgress"), "items": .array([])])]))
        let applied = try await pending.value
        #expect(applied.state == .applied)
        #expect(applied.turnId == ChatGPTEventProjector(ref: ref, vendorThreadId: "private-thread").identifier("turn", "private-result-turn"))
        #expect(try await service.submit(owner: owner, key: "command-key-123456", request: start()) == applied)
        #expect(try await service.execute(id: accepted.operationId, owner: owner, ref: ref, executionEpoch: "execution") == applied)
        #expect(await wire.frames.count == 1)
        #expect(!String(decoding: try JSONEncoder().encode(applied), as: UTF8.self).contains("private-result-turn"))
        await channel.close()
    }
}
