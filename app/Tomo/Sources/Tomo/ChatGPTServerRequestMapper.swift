import Foundation

enum ChatGPTServerRequestError: Error, Equatable {
    case unsupported, invalidRequest, invalidAnswer
}

struct RemoteQuestionAnswer: Codable, Equatable, Sendable {
    let questionId: String
    let selectedOptionIds: [String]
    let text: String?
}

/// Desktop-private routing. None of these vendor identities is Codable or sent
/// to a mobile client. A new callback always receives a new public identity,
/// including callbacks for the same item and reused JSON-RPC IDs.
struct ChatGPTMappedServerRequest: Sendable {
    let rpcId: AgentRPCID
    let vendorThreadId: String
    let vendorTurnId: String
    let vendorItemId: String
    let request: RemotePendingRequest
    let vendorQuestionIds: [String: String]

    func approvalResponse(decision: String) throws -> AgentJSON {
        guard request.type == "approval", request.allowedDecisions.contains(decision) else {
            throw ChatGPTServerRequestError.invalidAnswer
        }
        if let impact = request.permissionApproval {
            // The mobile reply selects only a finite decision. The complete
            // profile comes from this exact private callback's reviewed impact.
            let permissions: AgentJSON
            switch decision {
            case "decline": permissions = .object([:])
            case "accept", "acceptForSession":
                guard !impact.permissions.hasUnknownRange else { throw ChatGPTServerRequestError.invalidAnswer }
                permissions = try JSONDecoder().decode(AgentJSON.self, from: JSONEncoder().encode(impact.permissions))
            default: throw ChatGPTServerRequestError.invalidAnswer
            }
            return .object(["permissions": permissions, "scope": .string(decision == "acceptForSession" ? "session" : "turn")])
        }
        return .object(["decision": .string(decision)])
    }

    func replacingFileChanges(_ changes: [RemoteFileChange]) throws -> Self {
        guard let old = request.fileApproval else { throw ChatGPTServerRequestError.invalidRequest }
        let impact = RemoteFileApproval(changes: changes, reason: old.reason, grantRoot: old.grantRoot)
        guard impact.valid, request.requestRevision < 9_007_199_254_740_990 else { throw ChatGPTServerRequestError.invalidRequest }
        let updated = RemotePendingRequest(requestId: request.requestId, requestRevision: request.requestRevision + 1,
            type: request.type, executionEpoch: request.executionEpoch, turnId: request.turnId, summary: "修改 \(changes.count) 个文件",
            allowedDecisions: request.allowedDecisions, expiresAt: request.expiresAt, fileApproval: impact)
        return .init(rpcId: rpcId, vendorThreadId: vendorThreadId, vendorTurnId: vendorTurnId, vendorItemId: vendorItemId,
            request: updated, vendorQuestionIds: vendorQuestionIds)
    }

    func questionResponse(answers: [RemoteQuestionAnswer]) throws -> AgentJSON {
        guard request.type == "question", answers.count == request.questions.count,
              Set(answers.map(\.questionId)).count == answers.count else { throw ChatGPTServerRequestError.invalidAnswer }
        var result: [String: AgentJSON] = [:]
        var bytes = 0
        for question in request.questions {
            guard let answer = answers.first(where: { $0.questionId == question.questionId }),
                  let vendorId = vendorQuestionIds[question.questionId] else { throw ChatGPTServerRequestError.invalidAnswer }
            let value: String
            if let text = answer.text {
                guard question.allowsFreeText, answer.selectedOptionIds.isEmpty,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !text.contains("\0"), text.utf8.count <= 16_384 else { throw ChatGPTServerRequestError.invalidAnswer }
                value = text
            } else {
                // The installed protocol has no multiple-choice flag. An array
                // in its response schema does not imply multi-select UI support.
                guard answer.selectedOptionIds.count == 1,
                      let option = question.options.first(where: { $0.optionId == answer.selectedOptionIds[0] }) else {
                    throw ChatGPTServerRequestError.invalidAnswer
                }
                value = option.label
            }
            bytes += value.utf8.count
            guard bytes <= 65_536 else { throw ChatGPTServerRequestError.invalidAnswer }
            result[vendorId] = .object(["answers": .array([.string(value)])])
        }
        return .object(["answers": .object(result)])
    }
}

/// Audited against codex-cli 0.162.0-alpha.17.2 app-server JSON schema.
/// Mapping alone grants no execution capability. Only the owning runtime may
/// retain the route and, after operation/ACL checks, reply to a live callback.
enum ChatGPTServerRequestMapper {
    static func map(id: AgentRPCID, method: String, params: AgentJSON,
                    projector: ChatGPTEventProjector, control: RemoteSessionControl,
                    now: Date = Date(), identity: UUID = UUID(), reviewLifetime: TimeInterval = 15 * 60,
                    fileChanges: [RemoteFileChange]? = nil) throws -> ChatGPTMappedServerRequest {
        guard case .object(let fields) = params,
              let thread = identifier(fields["threadId"]), thread == projector.vendorThreadId,
              let turn = identifier(fields["turnId"]), let item = identifier(fields["itemId"]),
              projector.identifier("turn", turn) == control.currentTurnId,
              control.controlMode == "live", now.timeIntervalSince1970.isFinite,
              reviewLifetime.isFinite, reviewLifetime > 0, reviewLifetime <= 15 * 60 else {
            throw ChatGPTServerRequestError.invalidRequest
        }
        let publicId = "request_" + identity.uuidString.lowercased()
        // A local remote-review lease, not an upstream timeout. Expiry must only
        // withdraw remote controls; it must never fabricate an Agent answer.
        let expiry = ISO8601DateFormatter().string(from: now.addingTimeInterval(reviewLifetime))
        let request: RemotePendingRequest
        var vendorQuestions: [String: String] = [:]
        switch method {
        case "item/tool/requestUserInput":
            guard Set(fields.keys).isSubset(of: ["threadId", "turnId", "itemId", "questions", "isBlocking", "autoResolutionMs"]),
                  case .bool(let blocking) = fields["isBlocking"],
                  case .array(let values) = fields["questions"], (1...16).contains(values.count) else {
                throw ChatGPTServerRequestError.invalidRequest
            }
            if let duration = fields["autoResolutionMs"], duration != .null {
                guard case .integer(let ms) = duration, ms >= 0 else { throw ChatGPTServerRequestError.invalidRequest }
            }
            var questions: [RemoteRequestQuestion] = []
            var seen: Set<String> = []
            for (index, value) in values.enumerated() {
                guard case .object(let q) = value,
                      Set(q.keys).isSubset(of: ["header", "id", "question", "isOther", "isSecret", "options"]),
                      let vendorId = identifier(q["id"]), seen.insert(vendorId).inserted,
                      let header = text(q["header"], limit: 1024, empty: true),
                      let prompt = text(q["question"], limit: 16_384) else { throw ChatGPTServerRequestError.invalidRequest }
                let other = try flag(q["isOther"]), secret = try flag(q["isSecret"])
                let questionId = publicId + "_q\(index)"
                var options: [RemoteQuestionOption] = []
                if let raw = q["options"], raw != .null {
                    guard case .array(let choices) = raw, choices.count <= 32 else { throw ChatGPTServerRequestError.invalidRequest }
                    for (optionIndex, choice) in choices.enumerated() {
                        guard case .object(let option) = choice, Set(option.keys) == ["label", "description"],
                              let label = text(option["label"], limit: 4096),
                              let description = text(option["description"], limit: 8192, empty: true) else {
                            throw ChatGPTServerRequestError.invalidRequest
                        }
                        options.append(.init(optionId: "option_\(optionIndex)", label: label, description: description))
                    }
                }
                guard Set(options.map(\.label)).count == options.count else { throw ChatGPTServerRequestError.invalidRequest }
                questions.append(.init(questionId: questionId, header: header, prompt: prompt, options: options,
                    allowsFreeText: options.isEmpty || other, isSecret: secret))
                vendorQuestions[questionId] = vendorId
            }
            request = .init(requestId: publicId, requestRevision: 1, type: "question", executionEpoch: control.executionEpoch,
                turnId: projector.identifier("turn", turn), summary: String(questions[0].prompt.prefix(240)), expiresAt: expiry,
                questions: questions, isBlocking: blocking)
        case "item/commandExecution/requestApproval":
            let known: Set<String> = ["threadId", "turnId", "itemId", "startedAtMs", "approvalId", "availableDecisions",
                "command", "commandActions", "cwd", "environmentId", "kind", "reason", "additionalPermissions",
                "networkApprovalContext", "proposedExecpolicyAmendment", "proposedNetworkPolicyAmendments"]
            guard Set(fields.keys).isSubset(of: known),
                  case .integer(let startedAt) = fields["startedAtMs"], startedAt >= 0,
                  let command = text(fields["command"], limit: 32_768), let cwd = text(fields["cwd"], limit: 4096) else {
                throw ChatGPTServerRequestError.invalidRequest
            }
            // These require additional reviewable scope or different response
            // models. Never reduce them to an ordinary "allow command" prompt.
            guard fields["kind"] == nil || fields["kind"] == .string("command"),
                  ["additionalPermissions", "networkApprovalContext", "environmentId"].allSatisfy({ fields[$0] == nil || fields[$0] == .null }) else {
                throw ChatGPTServerRequestError.unsupported
            }
            let reason: String?
            if let raw = fields["reason"], raw != .null {
                guard let value = text(raw, limit: 16_384, empty: true) else { throw ChatGPTServerRequestError.invalidRequest }
                reason = value
            } else { reason = nil }
            var decisions = ["accept", "decline", "cancel"]
            if let raw = fields["availableDecisions"], raw != .null {
                guard case .array(let available) = raw, !available.isEmpty, available.count <= 32 else {
                    throw ChatGPTServerRequestError.invalidRequest
                }
                decisions = available.compactMap { value in
                    if case .string(let decision) = value, ["accept", "decline", "cancel"].contains(decision) { return decision }
                    return nil
                }
                guard !decisions.isEmpty, Set(decisions).count == decisions.count else { throw ChatGPTServerRequestError.unsupported }
            }
            request = .init(requestId: publicId, requestRevision: 1, type: "approval", executionEpoch: control.executionEpoch,
                turnId: projector.identifier("turn", turn), summary: "执行命令", allowedDecisions: decisions, expiresAt: expiry,
                commandApproval: .init(command: command, cwd: cwd, reason: reason))
        case "item/fileChange/requestApproval":
            guard Set(fields.keys).isSubset(of: ["threadId", "turnId", "itemId", "startedAtMs", "reason", "grantRoot"]),
                  case .integer(let startedAt) = fields["startedAtMs"], startedAt >= 0 else {
                throw ChatGPTServerRequestError.invalidRequest
            }
            guard let fileChanges else { throw ChatGPTServerRequestError.unsupported }
            let impact = RemoteFileApproval(changes: fileChanges, reason: try optionalText(fields["reason"], limit: 16_384, empty: true),
                grantRoot: try optionalText(fields["grantRoot"], limit: 4096))
            guard impact.valid else { throw ChatGPTServerRequestError.invalidRequest }
            request = .init(requestId: publicId, requestRevision: 1, type: "approval", executionEpoch: control.executionEpoch,
                turnId: projector.identifier("turn", turn), summary: "修改 \(fileChanges.count) 个文件",
                allowedDecisions: ["accept", "acceptForSession", "decline", "cancel"], expiresAt: expiry, fileApproval: impact)
        case "item/permissions/requestApproval":
            guard Set(fields.keys).isSubset(of: ["threadId", "turnId", "itemId", "startedAtMs", "cwd", "environmentId", "reason", "permissions"]),
                  case .integer(let startedAt) = fields["startedAtMs"], startedAt >= 0,
                  let cwd = text(fields["cwd"], limit: 4096), let permissions = fields["permissions"] else {
                throw ChatGPTServerRequestError.invalidRequest
            }
            let profile = try RemotePermissionApproval.profile(permissions)
            let impact = RemotePermissionApproval(cwd: cwd, environmentId: try optionalText(fields["environmentId"], limit: 256),
                reason: try optionalText(fields["reason"], limit: 16_384, empty: true), permissions: profile)
            guard impact.valid else { throw ChatGPTServerRequestError.invalidRequest }
            request = .init(requestId: publicId, requestRevision: 1, type: "approval", executionEpoch: control.executionEpoch,
                turnId: projector.identifier("turn", turn), summary: "申请额外权限",
                allowedDecisions: profile.hasUnknownRange ? ["decline"] : ["accept", "acceptForSession", "decline"],
                expiresAt: expiry, permissionApproval: impact)
        default: throw ChatGPTServerRequestError.unsupported
        }
        guard request.validContent else { throw ChatGPTServerRequestError.invalidRequest }
        return .init(rpcId: id, vendorThreadId: thread, vendorTurnId: turn, vendorItemId: item,
                     request: request, vendorQuestionIds: vendorQuestions)
    }

    private static func identifier(_ value: AgentJSON?) -> String? { text(value, limit: 256) }
    static func fileChanges(_ raw: AgentJSON) throws -> [RemoteFileChange] {
        guard case .array(let values) = raw, (1...128).contains(values.count) else { throw ChatGPTServerRequestError.invalidRequest }
        let changes = try values.map { value -> RemoteFileChange in
            guard case .object(let fields) = value, Set(fields.keys) == ["path", "kind", "diff"],
                  let path = text(fields["path"], limit: 4096), let diff = text(fields["diff"], limit: 512 * 1024, empty: true),
                  case .object(let kind) = fields["kind"], case .string(let type) = kind["type"],
                  ["add", "delete", "update"].contains(type),
                  Set(kind.keys).isSubset(of: type == "update" ? ["type", "move_path"] : ["type"]) else {
                throw ChatGPTServerRequestError.invalidRequest
            }
            return .init(path: path, kind: type, movePath: try optionalText(kind["move_path"], limit: 4096), diff: diff)
        }
        guard RemoteFileApproval(changes: changes, reason: nil, grantRoot: nil).valid else { throw ChatGPTServerRequestError.invalidRequest }
        return changes
    }
    private static func optionalText(_ raw: AgentJSON?, limit: Int, empty: Bool = false) throws -> String? {
        guard let raw, raw != .null else { return nil }
        guard let value = text(raw, limit: limit, empty: empty) else { throw ChatGPTServerRequestError.invalidRequest }
        return value
    }
    private static func text(_ value: AgentJSON?, limit: Int, empty: Bool = false) -> String? {
        guard case .string(let s) = value, (empty || !s.isEmpty), s.utf8.count <= limit, !s.contains("\0") else { return nil }
        return s
    }
    private static func flag(_ value: AgentJSON?) throws -> Bool {
        guard let value else { return false }
        guard case .bool(let flag) = value else { throw ChatGPTServerRequestError.invalidRequest }
        return flag
    }
}
