import Foundation
import Testing
@testable import Tomo

private actor RequestResponseWire {
    var channel: AgentRPCChannel?
    var responses: [[String: AgentJSON]] = []
    var resolves = true
    var fails = false
    func configure(_ channel: AgentRPCChannel, resolves: Bool = true, fails: Bool = false) {
        self.channel = channel; self.resolves = resolves; self.fails = fails
    }
    func write(_ data: Data) async throws {
        guard case .object(let fields) = try JSONDecoder().decode(AgentJSON.self, from: data),
              let id = fields["id"], fields["result"] != nil, fields["method"] == nil else { throw AgentRPCError.invalidFrame }
        responses.append(fields)
        if fails { throw AgentRPCError.disconnected }
        if resolves {
            var bytes = try JSONEncoder().encode(AgentJSON.object(["method": .string("serverRequest/resolved"),
                "params": .object(["threadId": .string("thread"), "requestId": id])]))
            bytes.append(10); try await channel?.receive(bytes)
        }
    }
}

private actor ResponsePermission {
    var revoked = false
    func revoke() { revoked = true }
    func validate() throws { if revoked { throw RemoteAccessError.unauthorized } }
}
private actor RevokeBeforeResponseAdapter: RemoteGuardedCommandAdapter {
    let base: ChatGPTInteractiveCommandAdapter
    let permission: ResponsePermission
    init(base: ChatGPTInteractiveCommandAdapter, permission: ResponsePermission) { self.base = base; self.permission = permission }
    func validate(_ request: RemoteOperationRequest) async throws { try await base.validate(request) }
    func apply(_ request: RemoteOperationRequest) async throws -> RemoteCommandOutcome { try await base.apply(request) }
    func apply(_ request: RemoteOperationRequest, authorizeBeforeCommit: @escaping @Sendable () async throws -> Void) async throws -> RemoteCommandOutcome {
        await permission.revoke()
        return try await base.apply(request, authorizeBeforeCommit: authorizeBeforeCommit)
    }
}

struct ChatGPTRequestResponseTests {
    private let ref = RemoteSessionRef(serverId: "server", agentId: "agent.chatgpt", runtimeId: "runtime", sessionId: "session")
    private struct Harness: Sendable {
        let root: URL
        let channel: AgentRPCChannel
        let pump: ChatGPTRuntimeEventPump
        let journal: RemoteSessionJournal
        let wire: RequestResponseWire
    }
    private func send(_ channel: AgentRPCChannel, _ method: String, fields: [String: AgentJSON], id: AgentJSON? = nil) async throws {
        var params = fields; params["threadId"] = .string("thread")
        var envelope: [String: AgentJSON] = ["method": .string(method), "params": .object(params)]
        if let id { envelope["id"] = id }
        var data = try JSONEncoder().encode(AgentJSON.object(envelope)); data.append(10)
        try await channel.receive(data)
    }
    private func wait(_ condition: @escaping @Sendable () async throws -> Bool) async throws {
        for _ in 0..<600 { if try await condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw AgentRPCError.timedOut
    }
    private func withHarness(resolves: Bool = true, fails: Bool = false, timeout: Duration = .seconds(2),
                             reviewLifetime: TimeInterval = 900, _ body: @Sendable (Harness) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("request-reply-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try RemoteSessionJournal(databaseURL: root.appendingPathComponent("events.sqlite")), wire = RequestResponseWire()
        let channel = AgentRPCChannel(writer: { try await wire.write($0) })
        await wire.configure(channel, resolves: resolves, fails: fails)
        let pump = ChatGPTRuntimeEventPump(serverId: ref.serverId, runtimeId: ref.runtimeId, channel: channel, journal: journal,
                                          responseTimeout: timeout, requestReviewLifetime: reviewLifetime)
        try await pump.bind(ref: ref, vendorThreadId: "thread", baseline: .init(control: .init(executionEpoch: "execution", controlRevision: 0,
            state: "idle", controlMode: "readOnly", currentTurnId: nil, allowedActions: ["history.read"]),
            messages: [], pendingRequests: [], olderHistoryCursor: nil, hasOlder: false))
        try await pump.start()
        do {
            try await send(channel, "turn/started", fields: ["turn": .object(["id": .string("turn"), "status": .string("inProgress"), "items": .array([])])])
            try await wait { try await journal.snapshot(ref: ref).projection.control.currentTurnId != nil }
            try await pump.enableOwnedInterrupt(vendorThreadId: "thread", allowSteer: true, allowRequests: true)
            try await body(.init(root: root, channel: channel, pump: pump, journal: journal, wire: wire))
            await pump.stop()
        } catch { await pump.stop(); throw error }
    }
    private func ask(_ h: Harness, id: AgentJSON = .integer(42), approval: Bool = false) async throws -> RemotePendingRequest {
        let previousCount = try await h.journal.snapshot(ref: ref).projection.pendingRequests.count
        var fields: [String: AgentJSON] = ["turnId": .string("turn"), "itemId": .string("private-item")]
        if approval {
            fields.merge(["startedAtMs": .integer(100), "command": .string("swift test"), "cwd": .string("/workspace")]) { _, new in new }
        } else {
            fields["isBlocking"] = .bool(true)
            fields["questions"] = .array([.object(["id": .string("private-question"), "header": .string("环境"), "question": .string("选择环境"),
                "options": .array([.object(["label": .string("开发"), "description": .string("开发环境")])])])])
        }
        try await send(h.channel, approval ? "item/commandExecution/requestApproval" : "item/tool/requestUserInput", fields: fields, id: id)
        try await wait { try await h.journal.snapshot(ref: ref).projection.pendingRequests.count == previousCount + 1 }
        return try #require(await h.journal.snapshot(ref: ref).projection.pendingRequests.last)
    }
    private func operation(_ request: RemotePendingRequest, decision: String = "accept") -> RemoteOperationRequest {
        var body: [String: AgentJSON] = ["requestId": .string(request.requestId), "expectedRequestRevision": .integer(Int64(request.requestRevision)),
                                       "expectedTurnId": .string(request.turnId)]
        if request.type == "approval" { body["decision"] = .string(decision) }
        else {
            let q = request.questions[0]
            body["answers"] = .array([.object(["questionId": .string(q.questionId), "selectedOptionIds": .array([.string(q.options[0].optionId)])])])
        }
        return .init(ref: ref, executionEpoch: request.executionEpoch, action: request.type == "approval" ? .approve : .answer, body: .object(body))
    }

    private func fileChanges(_ diff: String) -> AgentJSON {
        .array([.object(["path": .string("/workspace/old.ts"), "kind": .object(["type": .string("update"),
            "move_path": .string("/workspace/new.ts")]), "diff": .string(diff)]),
            .object(["path": .string("/workspace/removed.ts"), "kind": .object(["type": .string("delete")]), "diff": .string("-removed\n")])])
    }

    private var permissionProfile: AgentJSON {
        .object(["fileSystem": .object(["entries": .array([
            .object(["access": .string("write"), "path": .object(["type": .string("glob_pattern"), "pattern": .string("/workspace/**/*.ts")])]),
            .object(["access": .string("deny"), "path": .object(["type": .string("path"), "path": .string("/workspace/secrets")])])
        ]), "globScanMaxDepth": .integer(4)]), "network": .object(["enabled": .bool(false)])])
    }
    private func askPermission(_ h: Harness) async throws -> RemotePendingRequest {
        try await send(h.channel, "item/permissions/requestApproval", fields: ["turnId": .string("turn"), "itemId": .string("permissions-item"),
            "startedAtMs": .integer(1), "cwd": .string("/workspace"), "permissions": permissionProfile], id: .string("permission-callback"))
        try await wait { try await h.journal.snapshot(ref: ref).projection.pendingRequests.first?.permissionApproval != nil }
        return try #require(await h.journal.snapshot(ref: ref).projection.pendingRequests.first)
    }
    @Test func permissionRepliesUseOriginalCallbackAndExactTurnSessionOrEmptyGrantAtMostOnce() async throws {
        for decision in ["accept", "acceptForSession", "decline"] {
            try await withHarness { h in
                let pending = try await askPermission(h), request = operation(pending, decision: decision)
                #expect(await h.pump.respond(operation(pending, decision: "cancel"), authorizeBeforeCommit: {}) == .rejected)
                #expect(await h.wire.responses.isEmpty)
                #expect(await h.pump.respond(request, authorizeBeforeCommit: {}) == .applied(turnId: nil))
                #expect(await h.wire.responses.last?["id"] == .string("permission-callback"))
                #expect(await h.wire.responses.last?["result"] == .object(["permissions": decision == "decline" ? .object([:]) : permissionProfile,
                    "scope": .string(decision == "acceptForSession" ? "session" : "turn")]))
                #expect(await h.pump.respond(request, authorizeBeforeCommit: {}) == .rejected)
                #expect(await h.wire.responses.count == 1)
            }
        }
    }
    @Test func permissionsResolvedOrRevokedDuringCommitNeverWriteAGrant() async throws {
        for revoke in [false, true] {
            try await withHarness { h in
                let pending = try await askPermission(h)
                let result = await h.pump.respond(operation(pending, decision: "acceptForSession"), authorizeBeforeCommit: {
                    if revoke { throw RemoteAccessError.unauthorized }
                    try await send(h.channel, "serverRequest/resolved", fields: ["requestId": .string("permission-callback")])
                    try await wait { try await h.journal.snapshot(ref: ref).projection.pendingRequests.isEmpty }
                })
                let responses = await h.wire.responses
                #expect(result == .rejected && responses.isEmpty)
            }
        }
    }
    private func proposeFile(_ h: Harness) async throws -> RemotePendingRequest {
        try await send(h.channel, "item/started", fields: ["turnId": .string("turn"), "item": .object([
            "id": .string("file-item"), "type": .string("fileChange"), "status": .string("inProgress"), "changes": fileChanges("-old\n+first🐾\n")])])
        try await send(h.channel, "item/fileChange/requestApproval", fields: ["turnId": .string("turn"), "itemId": .string("file-item"),
            "startedAtMs": .integer(100), "grantRoot": .string("/workspace")], id: .string("file-callback"))
        try await wait { try await h.journal.snapshot(ref: ref).projection.pendingRequests.first?.fileApproval != nil }
        return try #require(await h.journal.snapshot(ref: ref).projection.pendingRequests.first)
    }
    private func reviseFile(_ h: Harness) async throws {
        try await send(h.channel, "item/fileChange/patchUpdated", fields: ["turnId": .string("turn"), "itemId": .string("file-item"),
            "changes": fileChanges("-old\n+revised🐾\n")])
        try await wait { try await h.journal.snapshot(ref: ref).projection.pendingRequests.first?.requestRevision == 2 }
    }

    @Test func fileApprovalUsesExactItemAndRevisionAndReturnsSessionDecisionToOriginalCallback() async throws {
        try await withHarness { h in
            let first = try await proposeFile(h)
            #expect(first.fileApproval?.changes.count == 2 && first.fileApproval?.grantRoot == "/workspace")
            #expect(first.fileApproval?.changes[0].movePath == "/workspace/new.ts")
            try await reviseFile(h)
            let revised = try #require(await h.journal.snapshot(ref: ref).projection.pendingRequests.first)
            #expect(revised.requestId == first.requestId && revised.requestRevision == 2)
            #expect(revised.fileApproval?.changes[0].diff == "-old\n+revised🐾\n")
            #expect(await h.pump.respond(operation(first), authorizeBeforeCommit: {}) == .rejected)
            #expect(await h.wire.responses.isEmpty)
            #expect(await h.pump.respond(operation(revised, decision: "acceptForSession"), authorizeBeforeCommit: {}) == .applied(turnId: nil))
            #expect(await h.wire.responses.last?["id"] == .string("file-callback"))
            #expect(await h.wire.responses.last?["result"] == .object(["decision": .string("acceptForSession")]))
            #expect(try await h.journal.snapshot(ref: ref).projection.pendingRequests.isEmpty)
        }
    }

    @Test func diffChangedDuringFinalAuthorizationCannotApproveTheOldProposal() async throws {
        try await withHarness { h in
            let first = try await proposeFile(h)
            let outcome = await h.pump.respond(operation(first), authorizeBeforeCommit: {try await reviseFile(h)})
            let responses = await h.wire.responses
            #expect(outcome == .rejected && responses.isEmpty)
            let revised = try #require(await h.journal.snapshot(ref: ref).projection.pendingRequests.first)
            #expect(await h.pump.respond(operation(revised, decision: "decline"), authorizeBeforeCommit: {}) == .applied(turnId: nil))
        }
    }

    @Test func completedFileItemWithdrawsItsUnansweredReviewWithoutReplying() async throws {
        try await withHarness { h in
            let first = try await proposeFile(h)
            try await send(h.channel, "item/completed", fields: ["turnId": .string("turn"), "item": .object([
                "id": .string("file-item"), "type": .string("fileChange"), "status": .string("declined"), "changes": fileChanges("-old\n+first🐾\n")])])
            try await wait { try await h.journal.snapshot(ref: ref).projection.control.controlMode == "unavailable" }
            #expect(await h.pump.respond(operation(first), authorizeBeforeCommit: {}) == .rejected)
            #expect(await h.wire.responses.isEmpty)
        }
    }

    @Test func malformedPatchUpdatesCannotLeaveThePreviouslyReviewedDiffActionable() async throws {
        for invalid in ["missingThread", "foreignTurn", "invalidChanges", "unknownFields"] {
            try await withHarness { h in
                let first = try await proposeFile(h)
                var fields: [String: AgentJSON] = ["threadId": .string("thread"), "turnId": .string("turn"),
                    "itemId": .string("file-item"), "changes": fileChanges("+updated\n")]
                switch invalid {
                case "missingThread": fields.removeValue(forKey: "threadId")
                case "foreignTurn": fields["turnId"] = .string("wrong-turn")
                case "invalidChanges": fields["changes"] = .array([])
                default: fields["hiddenImpact"] = .string("unsupported")
                }
                var data = try JSONEncoder().encode(AgentJSON.object(["method": .string("item/fileChange/patchUpdated"), "params": .object(fields)]))
                data.append(10); try await h.channel.receive(data)
                try await wait { try await h.journal.snapshot(ref: ref).projection.control.controlMode == "unavailable" }
                #expect(await h.pump.respond(operation(first), authorizeBeforeCommit: {}) == .rejected)
                #expect(try await h.journal.snapshot(ref: ref).projection.pendingRequests.isEmpty)
                #expect(await h.wire.responses.isEmpty)
            }
        }
    }

    @Test func fileCallbackCannotBorrowAnotherItemsDiffOrACompletedTurnsCache() async throws {
        for newTurn in [false, true] {
            try await withHarness { h in
                try await send(h.channel, "item/started", fields: ["turnId": .string("turn"), "item": .object([
                    "id": .string("file-item"), "type": .string("fileChange"), "status": .string("inProgress"), "changes": fileChanges("+first\n")])])
                if newTurn {
                    try await send(h.channel, "turn/completed", fields: ["turn": .object(["id": .string("turn"), "status": .string("completed"), "items": .array([])])])
                    try await send(h.channel, "turn/started", fields: ["turn": .object(["id": .string("next-turn"), "status": .string("inProgress"), "items": .array([])])])
                }
                try await send(h.channel, "item/fileChange/requestApproval", fields: ["turnId": .string(newTurn ? "next-turn" : "turn"),
                    "itemId": .string(newTurn ? "file-item" : "different-item"), "startedAtMs": .integer(100)], id: .string("file-callback"))
                try await wait { try await h.journal.snapshot(ref: ref).projection.control.controlMode == "unavailable" }
                #expect(try await h.journal.snapshot(ref: ref).projection.pendingRequests.isEmpty)
                #expect(await h.wire.responses.isEmpty)
            }
        }
    }

    @Test func questionAndApprovalRepliesUseTheExactCallbackAndResolveBeforeSuccess() async throws {
        try await withHarness { h in
            for approval in [false, true] {
                let pending = try await ask(h, approval: approval), input = operation(pending, decision: "decline")
                try await h.pump.validateResponse(input)
                #expect(await h.pump.respond(input, authorizeBeforeCommit: {}) == .applied(turnId: nil))
                #expect(try await h.journal.snapshot(ref: ref).projection.pendingRequests.isEmpty)
                let frame = try #require(await h.wire.responses.last)
                #expect(frame["id"] == .integer(42))
                let expected: AgentJSON = approval ? .object(["decision": .string("decline")])
                    : .object(["answers": .object(["private-question": .object(["answers": .array([.string("开发")])])])])
                #expect(frame["result"] == expected)
            }
            #expect(await h.wire.responses.count == 2)
        }
    }

    @Test func concurrentDevicesCanOnlyClaimOneResponse() async throws {
        try await withHarness { h in
            let request = operation(try await ask(h))
            async let a = h.pump.respond(request, authorizeBeforeCommit: {})
            async let b = h.pump.respond(request, authorizeBeforeCommit: {})
            let outcomes = await [a, b]
            #expect(outcomes.filter { $0 == .applied(turnId: nil) }.count == 1)
            #expect(outcomes.filter { $0 == .rejected }.count == 1)
            #expect(await h.wire.responses.count == 1)
        }
    }

    @Test func revisionsExecutionTurnResourceAndAnswerMustAllMatch() async throws {
        try await withHarness { h in
            let original = operation(try await ask(h))
            var cases: [RemoteOperationRequest] = [
                .init(ref: ref, executionEpoch: "replacement", action: original.action, body: original.body),
                .init(ref: .init(serverId: ref.serverId, agentId: ref.agentId, runtimeId: "another", sessionId: ref.sessionId),
                      executionEpoch: original.executionEpoch, action: original.action, body: original.body)]
            for (key, value) in [("expectedRequestRevision", AgentJSON.integer(2)), ("expectedTurnId", .string("other-turn")),
                                 ("requestId", .string("other-request")), ("vendorRpcId", .integer(42))] {
                guard case .object(var fields) = original.body else { throw AgentRPCError.invalidFrame }
                fields[key] = value
                cases.append(.init(ref: ref, executionEpoch: original.executionEpoch, action: original.action, body: .object(fields)))
            }
            for request in cases { #expect(await h.pump.respond(request, authorizeBeforeCommit: {}) == .rejected) }
            #expect(await h.wire.responses.isEmpty)
            #expect(await h.pump.respond(original, authorizeBeforeCommit: {}) == .applied(turnId: nil))
        }
    }

    @Test func permissionRevocationOrUpstreamResolutionDuringFinalAuthorizationPreventsReply() async throws {
        try await withHarness { h in
            let request = operation(try await ask(h))
            #expect(await h.pump.respond(request, authorizeBeforeCommit: { throw RemoteAccessError.unauthorized }) == .rejected)
            #expect(await h.pump.respond(request, authorizeBeforeCommit: {
                try await send(h.channel, "serverRequest/resolved", fields: ["requestId": .integer(42)])
                try await wait { try await h.journal.snapshot(ref: ref).projection.pendingRequests.isEmpty }
            }) == .rejected)
            #expect(await h.wire.responses.isEmpty)
        }
    }

    @Test func newUpstreamRequestAfterPreflightInvalidatesReplyEvenWhenTheOriginalStillExists() async throws {
        try await withHarness { h in
            let request = operation(try await ask(h))
            #expect(await h.pump.respond(request, authorizeBeforeCommit: { _ = try await ask(h, id: .integer(43)) }) == .rejected)
            #expect(await h.wire.responses.isEmpty)
            #expect(try await h.journal.snapshot(ref: ref).projection.pendingRequests.count == 2)
            #expect(await h.pump.respond(request, authorizeBeforeCommit: {}) == .applied(turnId: nil))
        }
    }

    @Test func lostResolutionAndWriteFailureStayUncertainAndAreNeverRetried() async throws {
        for fails in [false, true] {
            try await withHarness(resolves: false, fails: fails, timeout: .milliseconds(40)) { h in
                let request = operation(try await ask(h))
                #expect(await h.pump.respond(request, authorizeBeforeCommit: {}) == .uncertain)
                try await wait { try await h.journal.snapshot(ref: ref).projection.control.controlMode == "unavailable" }
                #expect(await h.pump.respond(request, authorizeBeforeCommit: {}) == .rejected)
                #expect(await h.wire.responses.count == 1)
                #expect(try await h.journal.snapshot(ref: ref).projection.pendingRequests.isEmpty)
            }
        }
    }

    @Test func expiredReviewLeaseWithdrawsControlWithoutAnsweringTheAgent() async throws {
        try await withHarness(reviewLifetime: 2) { h in
            let request = operation(try await ask(h))
            try await wait { try await h.journal.snapshot(ref: ref).projection.control.controlMode == "unavailable" }
            #expect(await h.pump.respond(request, authorizeBeforeCommit: {}) == .rejected)
            #expect(await h.wire.responses.isEmpty)
            let snapshot = try await h.journal.snapshot(ref: ref)
            #expect(snapshot.projection.pendingRequests.isEmpty)
        }
    }

    @Test func turnEndDuringFinalAuthorizationRejectsTheOldResponse() async throws {
        try await withHarness { h in
            let request = operation(try await ask(h))
            #expect(await h.pump.respond(request, authorizeBeforeCommit: {
                try await send(h.channel, "turn/completed", fields: ["turn": .object(["id": .string("turn"), "status": .string("interrupted"), "items": .array([])])])
                try await wait { try await h.journal.snapshot(ref: ref).projection.control.currentTurnId == nil }
            }) == .rejected)
            #expect(await h.wire.responses.isEmpty)
        }
    }

    private func adapter(_ h: Harness) -> ChatGPTInteractiveCommandAdapter {
        .init(messages: ChatGPTCommandAdapter(channel: h.channel, context: { _ in throw RemoteCommandError.unsupportedAction }), pump: h.pump)
    }

    @Test func dispatcherRechecksPermissionInsideTheRequestCommitAndPersistsDefiniteRejection() async throws {
        try await withHarness { h in
            let request = operation(try await ask(h)), permission = ResponsePermission()
            let store = try RemoteOperationStore(databaseURL: h.root.appendingPathComponent("operations.sqlite"))
            let dispatcher = RemoteOperationDispatcher(store: store,
                adapter: RevokeBeforeResponseAdapter(base: adapter(h), permission: permission)) { _, _ in try await permission.validate() }
            let owner = RemoteOperationOwner(userId: "owner", deviceId: "phone")
            let accepted = try await dispatcher.submit(owner: owner, key: "permission-recheck-key", request: request)
            let result = try await dispatcher.execute(id: accepted.operationId, owner: owner, ref: ref, executionEpoch: request.executionEpoch)
            #expect(result.state == .rejected)
            #expect(await h.wire.responses.isEmpty)
            #expect(try await store.byKey(owner: owner, ref: ref, key: "permission-recheck-key").state == .rejected)
        }
    }

    @Test func lostAgentResolutionPersistsUnknownAndIdempotentRecoveryCannotDispatchAgain() async throws {
        try await withHarness(resolves: false, timeout: .milliseconds(40)) { h in
            let request = operation(try await ask(h))
            let store = try RemoteOperationStore(databaseURL: h.root.appendingPathComponent("operations.sqlite"))
            let dispatcher = RemoteOperationDispatcher(store: store, adapter: adapter(h)) { _, _ in }
            let owner = RemoteOperationOwner(userId: "owner", deviceId: "phone"), key = "uncertain-response-key"
            let accepted = try await dispatcher.submit(owner: owner, key: key, request: request)
            let result = try await dispatcher.execute(id: accepted.operationId, owner: owner, ref: ref, executionEpoch: request.executionEpoch)
            #expect(result.state == .unknown && result.errorCode == "dispatch_uncertain")
            let recovered = try await dispatcher.submit(owner: owner, key: key, request: request)
            #expect(recovered == result)
            #expect(try await dispatcher.execute(id: accepted.operationId, owner: owner, ref: ref, executionEpoch: request.executionEpoch) == result)
            #expect(await h.wire.responses.count == 1)
            let publicReceipt = String(decoding: try result.responseData(), as: UTF8.self)
            #expect(!publicReceipt.contains("private-question") && !publicReceipt.contains("开发") && !publicReceipt.contains("answers"))
        }
    }

    @Test func executionStoppedDuringFinalAuthorizationCannotWriteTheResponse() async throws {
        try await withHarness { h in
            let request = operation(try await ask(h)), marker = ResponsePermission()
            let store = try RemoteOperationStore(databaseURL: h.root.appendingPathComponent("operations.sqlite"))
            let dispatcher = RemoteOperationDispatcher(store: store,
                adapter: RevokeBeforeResponseAdapter(base: adapter(h), permission: marker)) { _, _ in
                if await marker.revoked { try await store.executionStopped(ref: ref, executionEpoch: request.executionEpoch) }
            }
            let owner = RemoteOperationOwner(userId: "owner", deviceId: "phone"), key = "stopped-at-commit-key"
            let accepted = try await dispatcher.submit(owner: owner, key: key, request: request)
            // Lifecycle already finalized the ledger's lease as unknown. An old
            // executor cannot finish that stale dispatch or send a new reply.
            await #expect(throws: RemoteOperationError.staleDispatch) {
                try await dispatcher.execute(id: accepted.operationId, owner: owner, ref: ref, executionEpoch: request.executionEpoch)
            }
            #expect(try await store.byKey(owner: owner, ref: ref, key: key).state == .unknown)
            #expect(await h.wire.responses.isEmpty)
        }
    }
}
