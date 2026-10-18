import Foundation
import Testing
@testable import Tomo

struct ChatGPTServerRequestMapperTests {
    private let ref = RemoteSessionRef(serverId: "server", agentId: "agent.chatgpt", runtimeId: "runtime", sessionId: "session")
    private var projector: ChatGPTEventProjector { .init(ref: ref, vendorThreadId: "private-thread") }
    private var control: RemoteSessionControl {
        .init(executionEpoch: "execution", controlRevision: 4, state: "running", controlMode: "live",
              currentTurnId: projector.identifier("turn", "private-turn"), allowedActions: ["history.read", "turn.interrupt"])
    }
    private var fields: [String: AgentJSON] {
        ["threadId": .string("private-thread"), "turnId": .string("private-turn"), "itemId": .string("private-item")]
    }
    private func question(_ id: String, options: AgentJSON = .null, other: Bool = false, secret: Bool = false) -> AgentJSON {
        .object(["id": .string(id), "header": .string("问题"), "question": .string("请选择或填写"),
                 "options": options, "isOther": .bool(other), "isSecret": .bool(secret)])
    }
    private var options: AgentJSON {
        .array([.object(["label": .string("保持现状"), "description": .string("不修改现有配置")]),
                .object(["label": .string("迁移"), "description": .string("采用新配置")])])
    }
    private func input(_ questions: [AgentJSON], blocking: Bool = true, id: AgentRPCID = .integer(Int64.max)) throws -> ChatGPTMappedServerRequest {
        var params = fields; params["questions"] = .array(questions); params["isBlocking"] = .bool(blocking)
        return try ChatGPTServerRequestMapper.map(id: id, method: "item/tool/requestUserInput", params: .object(params),
            projector: projector, control: control, now: Date(timeIntervalSince1970: 1000))
    }
    private func command(_ extra: [String: AgentJSON] = [:]) throws -> ChatGPTMappedServerRequest {
        var params = fields
        params.merge(["startedAtMs": .integer(1), "command": .string("swift test --filter Example"),
                      "cwd": .string("/workspace/Tomo"), "reason": .string("验证本次修改")]) { _, new in new }
        params.merge(extra) { _, new in new }
        return try ChatGPTServerRequestMapper.map(id: .string("private-callback"), method: "item/commandExecution/requestApproval",
            params: .object(params), projector: projector, control: control)
    }

    @Test func multipleQuestionsMapChoicesAndTextToTheirExactVendorIdentities() throws {
        let mapped = try input([question("private-choice", options: options), question("private-other", options: options, other: true),
                                question("private-secret", secret: true)], blocking: false)
        let q = mapped.request.questions
        #expect(q.count == 3 && !mapped.request.isBlocking)
        #expect(!q[0].allowsFreeText && q[1].allowsFreeText && q[2].allowsFreeText && q[2].isSecret)
        #expect(mapped.request.expiresAt == "1970-01-01T00:31:40Z")
        let response = try mapped.questionResponse(answers: [
            .init(questionId: q[2].questionId, selectedOptionIds: [], text: "敏感输入"),
            .init(questionId: q[0].questionId, selectedOptionIds: [q[0].options[1].optionId], text: nil),
            .init(questionId: q[1].questionId, selectedOptionIds: [], text: "采用我的方案")])
        #expect(response == .object(["answers": .object([
            "private-choice": .object(["answers": .array([.string("迁移")])]),
            "private-other": .object(["answers": .array([.string("采用我的方案")])]),
            "private-secret": .object(["answers": .array([.string("敏感输入")])])])]))
        let json = String(decoding: try JSONEncoder().encode(mapped.request), as: UTF8.self)
        for privateValue in ["private-thread", "private-turn", "private-item", "private-choice", "private-other", "private-secret", "敏感输入"] {
            #expect(!json.contains(privateValue))
        }
    }

    @Test func noInventedMultiSelectOrFreeTextAndNoPartialDuplicateOrCrossRequestAnswers() throws {
        let mapped = try input([question("q", options: options)])
        let q = mapped.request.questions[0]
        for answer in [
            RemoteQuestionAnswer(questionId: q.questionId, selectedOptionIds: q.options.map(\.optionId), text: nil),
            .init(questionId: q.questionId, selectedOptionIds: [], text: "未被允许的自由输入"),
            .init(questionId: q.questionId, selectedOptionIds: ["unknown"], text: nil),
            .init(questionId: "another-request", selectedOptionIds: [q.options[0].optionId], text: nil),
            .init(questionId: q.questionId, selectedOptionIds: [q.options[0].optionId], text: "同时提交两种答案")
        ] { #expect(throws: ChatGPTServerRequestError.invalidAnswer) { try mapped.questionResponse(answers: [answer]) } }
        #expect(throws: ChatGPTServerRequestError.invalidAnswer) { try mapped.questionResponse(answers: []) }
        let answer = RemoteQuestionAnswer(questionId: q.questionId, selectedOptionIds: [q.options[0].optionId], text: nil)
        #expect(throws: ChatGPTServerRequestError.invalidAnswer) { try mapped.questionResponse(answers: [answer, answer]) }
        let textOnly = try input([question("q")]), free = textOnly.request.questions[0]
        for text in ["   \n", "bad\0value", String(repeating: "a", count: 16_385)] {
            #expect(throws: ChatGPTServerRequestError.invalidAnswer) {
                try textOnly.questionResponse(answers: [.init(questionId: free.questionId, selectedOptionIds: [], text: text)])
            }
        }
    }

    @Test func commandReviewPreservesExactScopeAndOnlyOffersSupportedSingleOperationDecisions() throws {
        let mapped = try command(["availableDecisions": .array([.string("decline"), .string("acceptForSession"), .string("accept"),
            .object(["acceptWithExecpolicyAmendment": .object(["execpolicyAmendment": .array([.string("swift")])])])])])
        #expect(mapped.request.commandApproval == .init(command: "swift test --filter Example", cwd: "/workspace/Tomo", reason: "验证本次修改"))
        #expect(mapped.request.allowedDecisions == ["decline", "accept"])
        #expect(try mapped.approvalResponse(decision: "accept") == .object(["decision": .string("accept")]))
        for decision in ["acceptForSession", "cancel", "allow", ""] {
            #expect(throws: ChatGPTServerRequestError.invalidAnswer) { try mapped.approvalResponse(decision: decision) }
        }
        #expect(throws: ChatGPTServerRequestError.invalidAnswer) { try mapped.questionResponse(answers: []) }
        let defaultDecisions = try command()
        #expect(defaultDecisions.request.allowedDecisions == ["accept", "decline", "cancel"])
    }

    @Test func missingImpactExtendedPermissionsAndUnknownSchemasCannotBecomeGenericApprovals() throws {
        for extra: [String: AgentJSON] in [
            ["additionalPermissions": .object([:])], ["networkApprovalContext": .object([:])],
            ["environmentId": .string("remote-environment")], ["kind": .string("writeStdin")],
            ["availableDecisions": .array([.string("acceptForSession")])]
        ] { #expect(throws: ChatGPTServerRequestError.unsupported) { try command(extra) } }
        for extra: [String: AgentJSON] in [["command": .null], ["cwd": .null], ["startedAtMs": .number(1.5)],
            ["futurePermission": .bool(true)], ["availableDecisions": .array([])]] {
            #expect(throws: ChatGPTServerRequestError.invalidRequest) { try command(extra) }
        }
        #expect(throws: ChatGPTServerRequestError.unsupported) {
            try ChatGPTServerRequestMapper.map(id: .integer(1), method: "item/fileChange/requestApproval", params: .object(fields.merging(["startedAtMs": .integer(100)]) { _, new in new }),
                projector: projector, control: control)
        }
    }

    @Test func fullFileChangesPreserveMovesDeletesDiffAndSessionWriteScope() throws {
        let raw: AgentJSON = .array([
            .object(["path": .string("/workspace/new.ts"), "kind": .object(["type": .string("add")]), "diff": .string("+新增🐾\n")]),
            .object(["path": .string("/workspace/old.ts"), "kind": .object(["type": .string("delete")]), "diff": .string("-删除\n")]),
            .object(["path": .string("/workspace/before.ts"), "kind": .object(["type": .string("update"), "move_path": .string("/workspace/after.ts")]), "diff": .string("-before\n+after\n")])])
        let changes = try ChatGPTServerRequestMapper.fileChanges(raw)
        let params = fields.merging(["startedAtMs": .integer(100), "grantRoot": .string("/workspace"), "reason": .string("修改并移动文件")]) { _, new in new }
        let mapped = try ChatGPTServerRequestMapper.map(id: .string("file-callback"), method: "item/fileChange/requestApproval",
            params: .object(params), projector: projector, control: control, fileChanges: changes)
        #expect(mapped.request.fileApproval?.changes == changes)
        #expect(mapped.request.fileApproval?.changes[2].movePath == "/workspace/after.ts")
        #expect(mapped.request.fileApproval?.grantRoot == "/workspace")
        let updated = try mapped.replacingFileChanges(Array(changes.prefix(2)))
        #expect(updated.request.summary == "修改 2 个文件" && updated.request.requestRevision == 2)
        #expect(updated.request.requestId == mapped.request.requestId && updated.request.expiresAt == mapped.request.expiresAt)
        #expect(updated.request.fileApproval?.changes == Array(changes.prefix(2)))
        #expect(updated.request.fileApproval?.grantRoot == "/workspace" && updated.request.fileApproval?.reason == "修改并移动文件")
        #expect(mapped.request.commandApproval == nil && mapped.request.validContent)
        #expect(try mapped.approvalResponse(decision: "acceptForSession") == .object(["decision": .string("acceptForSession")]))
        #expect(try JSONDecoder().decode(RemotePendingRequest.self, from: JSONEncoder().encode(mapped.request)) == mapped.request)
        for invalid: AgentJSON in [.array([]), .array([.object(["path": .string("a"), "kind": .object(["type": .string("add"), "move_path": .string("b")]), "diff": .string("+")])]),
            .array([.object(["path": .string("a"), "kind": .object(["type": .string("update")]), "diff": .string("+"), "hiddenScope": .bool(true)])])] {
            #expect(throws: ChatGPTServerRequestError.invalidRequest) { try ChatGPTServerRequestMapper.fileChanges(invalid) }
        }
        #expect(!RemoteFileApproval(changes: changes + changes, reason: nil, grantRoot: nil).valid)
        #expect(!RemoteFileApproval(changes: [.init(path: "a", kind: "update", movePath: nil, diff: String(repeating: "🐾", count: 140_000))], reason: nil, grantRoot: nil).valid)
    }

    @Test func repeatedCallbackIDsHaveDistinctPublicIdentitiesAndMalformedQuestionsFailClosed() throws {
        let first = try input([question("same")]), second = try input([question("same")])
        #expect(first.rpcId == second.rpcId && first.request.requestId != second.request.requestId)
        #expect(first.request.questions[0].questionId != second.request.questions[0].questionId)
        for list in [[], [question("duplicate"), question("duplicate")], [.object(["id": .string("missing-fields")])],
                     [question("q", options: .bool(true))], Array(repeating: question("q"), count: 17)] {
            #expect(throws: ChatGPTServerRequestError.invalidRequest) { try input(list) }
        }
    }

    @Test func requestMustMatchLiveThreadAndTurn() throws {
        for key in ["threadId", "turnId", "itemId"] {
            var p = fields; p[key] = .string(key == "itemId" ? "" : "another")
            p["isBlocking"] = .bool(true); p["questions"] = .array([question("q")])
            #expect(throws: ChatGPTServerRequestError.invalidRequest) {
                try ChatGPTServerRequestMapper.map(id: .integer(1), method: "item/tool/requestUserInput", params: .object(p), projector: projector, control: control)
            }
        }
        let readonly = RemoteSessionControl(executionEpoch: control.executionEpoch, controlRevision: 1, state: "running",
            controlMode: "readOnly", currentTurnId: control.currentTurnId, allowedActions: ["history.read"])
        var p = fields; p["isBlocking"] = .bool(true); p["questions"] = .array([question("q")])
        #expect(throws: ChatGPTServerRequestError.invalidRequest) {
            try ChatGPTServerRequestMapper.map(id: .integer(1), method: "item/tool/requestUserInput", params: .object(p), projector: projector, control: readonly)
        }
    }
}
