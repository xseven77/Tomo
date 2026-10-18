import Foundation
import Testing
@testable import Tomo

struct ChatGPTRuntimeEventPumpTests {
    private func ref(_ session: String = "a") -> RemoteSessionRef {
        .init(serverId: "server", agentId: "agent.chatgpt", runtimeId: "runtime", sessionId: session)
    }
    private var baseline: RemoteSessionProjection {
        .init(control: .init(executionEpoch: "executor", controlRevision: 0, state: "idle", controlMode: "readOnly", currentTurnId: nil, allowedActions: ["history.read"]),
              messages: [], pendingRequests: [], olderHistoryCursor: nil, hasOlder: false)
    }
    private func location() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("events.sqlite")
    }
    private func send(_ channel: AgentRPCChannel, _ method: String, fields: [String: AgentJSON] = [:], thread: String = "thread-a", id: AgentJSON? = nil) async throws {
        var params = fields; params["threadId"] = .string(thread)
        var value: [String: AgentJSON] = ["method": .string(method), "params": .object(params)]
        if let id { value["id"] = id }
        var bytes = try JSONEncoder().encode(AgentJSON.object(value)); bytes.append(10)
        try await channel.receive(bytes)
    }
    private var start: [String: AgentJSON] {
        ["turn": .object(["id": .string("turn"), "status": .string("inProgress"), "items": .array([])])]
    }
    private func wait(_ condition: @escaping @Sendable () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw AgentRPCError.timedOut
    }

    private var userInput: [String: AgentJSON] {
        ["turnId": .string("turn"), "itemId": .string("private-item"), "isBlocking": .bool(true),
         "questions": .array([.object(["id": .string("private-question"), "header": .string("环境"),
             "question": .string("请选择目标环境"), "options": .array([.object(["label": .string("开发"), "description": .string("开发环境")])])])])]
    }

    @Test func ownedRequestsPublishTypedQuestionsAndResolveWithoutSendingAutomaticAnswers() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = try RemoteSessionJournal(databaseURL: url)
        let channel = AgentRPCChannel(writer: { _ in Issue.record("Mapping a request must not answer it") })
        let pump = ChatGPTRuntimeEventPump(serverId: "server", runtimeId: "runtime", channel: channel, journal: journal)
        try await pump.bind(ref: ref(), vendorThreadId: "thread-a", baseline: baseline)
        try await pump.bind(ref: ref("b"), vendorThreadId: "thread-b", baseline: baseline)
        try await pump.start()
        try await send(channel, "turn/started", fields: start)
        try await wait { try await journal.snapshot(ref: ref()).projection.control.currentTurnId != nil }
        try await pump.enableOwnedInterrupt(vendorThreadId: "thread-a", allowSteer: true, allowRequests: true)
        try await send(channel, "thread/status/changed", fields: ["status": .object(["type": .string("active"), "activeFlags": .array([.string("waitingOnUserInput")])])])
        try await send(channel, "item/tool/requestUserInput", fields: userInput, id: .integer(12))
        try await wait { try await journal.snapshot(ref: ref()).projection.pendingRequests.count == 1 }
        let pending = try await journal.snapshot(ref: ref())
        let question = try #require(pending.projection.pendingRequests.first)
        #expect(question.type == "question" && question.questions.count == 1)
        #expect(pending.projection.control.state == "waitingForUser")
        #expect(pending.projection.control.allowedActions == ["history.read", "turn.interrupt", "question.answer"])
        #expect(try await journal.snapshot(ref: ref("b")).sequence == 0)
        try await send(channel, "serverRequest/resolved", fields: ["requestId": .integer(12)])
        try await send(channel, "thread/status/changed", fields: ["status": .object(["type": .string("active"), "activeFlags": .array([])])])
        try await wait { try await journal.snapshot(ref: ref()).projection.pendingRequests.isEmpty }
        let resolved = try await journal.snapshot(ref: ref())
        #expect(resolved.projection.control.state == "running")
        #expect(resolved.projection.control.allowedActions == ["history.read", "turn.interrupt", "message.send"])
        let replay = try await journal.replay(ref: ref(), after: pending.eventCursor)
        #expect(replay.map(\.event.type) == ["question.resolved", "session.updated"])
        #expect(replay.first?.event.payload == .object(["requestId": .string(question.requestId), "requestRevision": .integer(2)]))
        await pump.stop()
    }

    @Test func multipleCallbacksForOneItemRemainDistinctAndTurnCompletionWithdrawsAll() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = try RemoteSessionJournal(databaseURL: url), channel = AgentRPCChannel(writer: { _ in Issue.record("unexpected reply") })
        let pump = ChatGPTRuntimeEventPump(serverId: "server", runtimeId: "runtime", channel: channel, journal: journal)
        try await pump.bind(ref: ref(), vendorThreadId: "thread-a", baseline: baseline)
        try await pump.start()
        try await send(channel, "turn/started", fields: start)
        try await wait { try await journal.snapshot(ref: ref()).projection.control.currentTurnId != nil }
        try await pump.enableOwnedInterrupt(vendorThreadId: "thread-a", allowFreshStart: true, allowRequests: true)
        var command: [String: AgentJSON] = ["turnId": .string("turn"), "itemId": .string("same-item"), "startedAtMs": .integer(1),
            "command": .string("swift test"), "cwd": .string("/workspace"), "approvalId": .string("first-callback")]
        try await send(channel, "item/commandExecution/requestApproval", fields: command, id: .integer(1))
        command["approvalId"] = .string("second-callback")
        try await send(channel, "item/commandExecution/requestApproval", fields: command, id: .integer(2))
        try await wait { try await journal.snapshot(ref: ref()).projection.pendingRequests.count == 2 }
        let pending = try await journal.snapshot(ref: ref())
        #expect(Set(pending.projection.pendingRequests.map(\.requestId)).count == 2)
        #expect(pending.projection.control.allowedActions == ["history.read", "turn.interrupt", "approval.respond"])
        try await send(channel, "turn/completed", fields: ["turn": .object(["id": .string("turn"), "status": .string("completed"), "items": .array([])])])
        try await wait { try await journal.snapshot(ref: ref()).projection.control.state == "completed" }
        let complete = try await journal.snapshot(ref: ref())
        #expect(complete.projection.pendingRequests.isEmpty)
        #expect(complete.projection.control.allowedActions == ["history.read", "message.send"])
        try await send(channel, "serverRequest/resolved", fields: ["requestId": .integer(1)])
        try await send(channel, "serverRequest/resolved", fields: ["requestId": .integer(2)])
        _ = try await pump.commandContext(ref: ref()) // Checkpoint drains late resolutions.
        #expect(await pump.status(vendorThreadId: "thread-a") == .active)
        #expect(try await journal.snapshot(ref: ref()).sequence == complete.sequence)
        await pump.stop()
    }

    @Test func disconnectClearsTypedRequestsAndTheirCapabilities() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = try RemoteSessionJournal(databaseURL: url), channel = AgentRPCChannel(writer: { _ in })
        let pump = ChatGPTRuntimeEventPump(serverId: "server", runtimeId: "runtime", channel: channel, journal: journal)
        try await pump.bind(ref: ref(), vendorThreadId: "thread-a", baseline: baseline)
        try await pump.start()
        try await send(channel, "turn/started", fields: start)
        try await wait { try await journal.snapshot(ref: ref()).projection.control.currentTurnId != nil }
        try await pump.enableOwnedInterrupt(vendorThreadId: "thread-a", allowRequests: true)
        try await send(channel, "item/tool/requestUserInput", fields: userInput, id: .string("callback"))
        try await wait { try await journal.snapshot(ref: ref()).projection.pendingRequests.count == 1 }
        await channel.close()
        try await wait { try await journal.snapshot(ref: ref()).projection.control.controlMode == "unavailable" }
        let snapshot = try await journal.snapshot(ref: ref())
        #expect(snapshot.projection.pendingRequests.isEmpty && snapshot.projection.control.allowedActions.isEmpty)
        await pump.stop()
    }

    @Test func multipleSessionsRouteInOrderAndDisconnectPersistsDowngrade() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = try RemoteSessionJournal(databaseURL: url), channel = AgentRPCChannel(writer: { _ in })
        let pump = ChatGPTRuntimeEventPump(serverId: "server", runtimeId: "runtime", channel: channel, journal: journal)
        try await pump.bind(ref: ref(), vendorThreadId: "thread-a", baseline: baseline)
        try await pump.bind(ref: ref("b"), vendorThreadId: "thread-b", baseline: baseline)
        try await pump.start()
        try await send(channel, "turn/started", fields: start)
        try await send(channel, "item/started", fields: ["turnId": .string("turn"), "item": .object(["id": .string("item"), "type": .string("agentMessage"), "text": .string("")])])
        try await send(channel, "item/agentMessage/delta", fields: ["turnId": .string("turn"), "itemId": .string("item"), "delta": .string("实时正文")])
        try await wait { try await journal.snapshot(ref: ref()).sequence == 3 }
        #expect(try await journal.snapshot(ref: ref()).projection.messages.first?.content.first?.text == "实时正文")
        #expect(try await journal.snapshot(ref: ref("b")).sequence == 0)
        await channel.close()
        try await wait { await pump.status(vendorThreadId: "thread-a") == .requiresSync("runtime_disconnected") }
        // Status changes before the durable transaction completes; wait on the
        // authoritative projection separately rather than treating a flag as proof.
        try await wait { try await journal.snapshot(ref: ref()).projection.control.controlMode == "unavailable" }
        let snapshot = try await journal.snapshot(ref: ref())
        #expect(snapshot.projection.messages.first?.content.first?.text == "实时正文")
        #expect(snapshot.projection.control.currentTurnId == nil && snapshot.projection.control.allowedActions.isEmpty)
        let restarted = try RemoteSessionJournal(databaseURL: url)
        #expect(try await restarted.snapshot(ref: ref()).projection.control.state == "unknown")
        await pump.stop()
    }

    @Test func unsupportedRequestDisablesOnlyItsSessionAndNeverReplies() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = try RemoteSessionJournal(databaseURL: url)
        let channel = AgentRPCChannel(writer: { _ in Issue.record("pump must not answer approvals") })
        let pump = ChatGPTRuntimeEventPump(serverId: "server", runtimeId: "runtime", channel: channel, journal: journal)
        try await pump.bind(ref: ref(), vendorThreadId: "thread-a", baseline: baseline)
        try await pump.bind(ref: ref("b"), vendorThreadId: "thread-b", baseline: baseline)
        try await pump.start()
        let before = try await journal.snapshot(ref: ref())
        try await send(channel, "item/commandExecution/requestApproval", id: .integer(1))
        try await wait { try await journal.snapshot(ref: ref()).sequence == 2 }
        #expect(await pump.status(vendorThreadId: "thread-a") == .requiresSync("upstream_sync_required"))
        #expect(await pump.status(vendorThreadId: "thread-b") == .active)
        let records = try await journal.replay(ref: ref(), after: before.eventCursor)
        #expect(records.map(\.event.type) == ["session.updated", "sync.required"])
        try await send(channel, "turn/started", fields: start, thread: "thread-b")
        try await wait { try await journal.snapshot(ref: ref("b")).sequence == 1 }
        await pump.unbind(vendorThreadId: "thread-a")
        #expect(await pump.status(vendorThreadId: "thread-a") == .removed)
        await pump.stop()
    }

    @Test func malformedRuntimeEventStopsAllBindingsAndOldLeasesCannotWrite() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = try RemoteSessionJournal(databaseURL: url), channel = AgentRPCChannel(writer: { _ in })
        let pump = ChatGPTRuntimeEventPump(serverId: "server", runtimeId: "runtime", channel: channel, journal: journal)
        try await pump.bind(ref: ref(), vendorThreadId: "thread-a", baseline: baseline)
        let first = try await journal.snapshot(ref: ref())
        try await pump.start()
        try await channel.receive(Data("{\"method\":\"item/agentMessage/delta\",\"params\":{}}\n".utf8))
        try await wait { try await journal.snapshot(ref: ref()).projection.control.controlMode == "unavailable" }
        await #expect(throws: RemoteJournalError.revisionConflict) {
            try await journal.append(ref: ref(), mutations: [.control(baseline.control)], expectedStreamEpoch: first.streamEpoch, expectedSequence: first.sequence)
        }
        let rebuilt = try await journal.replace(ref: ref(), projection: baseline)
        #expect(rebuilt.streamEpoch != first.streamEpoch)
        await #expect(throws: RemoteJournalError.revisionConflict) {
            try await journal.requireSync(ref: ref(), expectedStreamEpoch: first.streamEpoch, reason: "late_disconnect")
        }
        #expect(try await journal.snapshot(ref: ref()).projection == baseline)
        await pump.stop()
    }

    @Test func bindingAndLifecycleRejectDuplicatesAndForeignSources() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = try RemoteSessionJournal(databaseURL: url), channel = AgentRPCChannel(writer: { _ in })
        let pump = ChatGPTRuntimeEventPump(serverId: "server", runtimeId: "runtime", channel: channel, journal: journal)
        try await pump.bind(ref: ref(), vendorThreadId: "thread-a", baseline: baseline)
        await #expect(throws: ChatGPTEventPumpError.duplicateBinding) { try await pump.bind(ref: ref("b"), vendorThreadId: "thread-a", baseline: baseline) }
        await #expect(throws: ChatGPTEventPumpError.duplicateBinding) { try await pump.bind(ref: ref(), vendorThreadId: "other", baseline: baseline) }
        let foreign = RemoteSessionRef(serverId: "other", agentId: "agent.chatgpt", runtimeId: "runtime", sessionId: "a")
        await #expect(throws: ChatGPTEventPumpError.invalidBinding) { try await pump.bind(ref: foreign, vendorThreadId: "other", baseline: baseline) }
        try await pump.start()
        await #expect(throws: ChatGPTEventPumpError.alreadyStarted) { try await pump.start() }
        await pump.stop()
        await #expect(throws: ChatGPTEventPumpError.stopped) { try await pump.bind(ref: ref("c"), vendorThreadId: "thread-c", baseline: baseline) }
    }

    @Test func actualStdioEventsReachJournalAndEOFDisablesControl() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let script = """
        import json
        def emit(method, **values):
            print(json.dumps({'method':method,'params':dict(threadId='thread-a',**values)}),flush=True)
        emit('turn/started', turn={'id':'turn','status':'inProgress','items':[]})
        emit('item/started', turnId='turn', item={'id':'item','type':'agentMessage','text':''})
        emit('item/agentMessage/delta', turnId='turn',itemId='item',delta='真正经过 stdio 的正文')
        """
        let rpc = try AgentStdioRPC(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", script], environment: [:])
        let journal = try RemoteSessionJournal(databaseURL: url)
        let pump = ChatGPTRuntimeEventPump(serverId: "server", runtimeId: "runtime", channel: rpc.channel, journal: journal)
        try await pump.bind(ref: ref(), vendorThreadId: "thread-a", baseline: baseline)
        try await pump.start()
        try await wait { try await journal.snapshot(ref: ref()).sequence == 5 }
        let snapshot = try await journal.snapshot(ref: ref())
        #expect(snapshot.projection.messages.first?.content.first?.text == "真正经过 stdio 的正文")
        #expect(snapshot.projection.control.controlMode == "unavailable")
        await pump.stop(); await rpc.stop()
    }
}
