import Foundation

/// Finite business input. The public request identity is resolved by the owned
/// runtime; remote callers never supply vendor RPC, thread, item or question IDs.
struct ChatGPTRequestResponse: Sendable {
    enum Value: Sendable {
        case approval(String)
        case answers([RemoteQuestionAnswer])
    }
    let requestId: String
    let requestRevision: Int
    let turnId: String
    let value: Value

    init(_ operation: RemoteOperationRequest) throws {
        guard operation.ref.agentId == "agent.chatgpt", case .object(let fields) = operation.body,
              let id = Self.id(fields["requestId"]), let turn = Self.id(fields["expectedTurnId"]),
              case .integer(let revision) = fields["expectedRequestRevision"], (1..<9_007_199_254_740_991).contains(revision) else {
            throw RemoteCommandError.invalidInput
        }
        requestId = id; requestRevision = Int(revision); turnId = turn
        let common: Set<String> = ["requestId", "expectedRequestRevision", "expectedTurnId"]
        switch operation.action {
        case .approve:
            guard Set(fields.keys) == common.union(["decision"]),
                  case .string(let decision) = fields["decision"], ["accept", "acceptForSession", "decline", "cancel"].contains(decision) else {
                throw RemoteCommandError.invalidInput
            }
            value = .approval(decision)
        case .answer:
            guard Set(fields.keys) == common.union(["answers"]), case .array(let raw) = fields["answers"], (1...16).contains(raw.count) else {
                throw RemoteCommandError.invalidInput
            }
            var answers: [RemoteQuestionAnswer] = []
            for entry in raw {
                guard case .object(let answer) = entry, Set(answer.keys).isSubset(of: ["questionId", "selectedOptionIds", "text"]),
                      let questionId = Self.id(answer["questionId"]), case .array(let choices) = answer["selectedOptionIds"],
                      choices.count <= 1 else { throw RemoteCommandError.invalidInput }
                var ids: [String] = []
                for choice in choices {
                    guard let id = Self.id(choice) else { throw RemoteCommandError.invalidInput }
                    ids.append(id)
                }
                let text: String?
                if let raw = answer["text"], raw != .null {
                    guard case .string(let string) = raw, string.utf8.count <= 16_384, !string.contains("\0") else {
                        throw RemoteCommandError.invalidInput
                    }
                    text = string
                } else { text = nil }
                answers.append(.init(questionId: questionId, selectedOptionIds: ids, text: text))
            }
            guard Set(answers.map(\.questionId)).count == answers.count else { throw RemoteCommandError.invalidInput }
            value = .answers(answers)
        default: throw RemoteCommandError.unsupportedAction
        }
    }

    func encode(for mapped: ChatGPTMappedServerRequest) throws -> AgentJSON {
        do {
            switch value {
            case .approval(let decision): return try mapped.approvalResponse(decision: decision)
            case .answers(let answers): return try mapped.questionResponse(answers: answers)
            }
        } catch { throw RemoteCommandError.invalidInput }
    }
    private static func id(_ raw: AgentJSON?) -> String? {
        guard case .string(let s) = raw, !s.isEmpty, s.utf8.count <= 256, !s.contains("\0") else { return nil }
        return s
    }
}

/// Composes the existing send/interrupt adapter with the private request owner.
/// Only the dispatcher supplies the final authorization check; directly calling
/// apply without it cannot answer an Agent request.
actor ChatGPTInteractiveCommandAdapter: RemoteGuardedCommandAdapter {
    let messages: ChatGPTCommandAdapter
    let pump: ChatGPTRuntimeEventPump
    init(messages: ChatGPTCommandAdapter, pump: ChatGPTRuntimeEventPump) {
        self.messages = messages; self.pump = pump
    }
    func validate(_ request: RemoteOperationRequest) async throws {
        if request.action == .approve || request.action == .answer { try await pump.validateResponse(request) }
        else { try await messages.validate(request) }
    }
    func apply(_ request: RemoteOperationRequest) async throws -> RemoteCommandOutcome {
        guard request.action != .approve && request.action != .answer else { return .rejected }
        return try await messages.apply(request)
    }
    func apply(_ request: RemoteOperationRequest, authorizeBeforeCommit: @escaping @Sendable () async throws -> Void) async throws -> RemoteCommandOutcome {
        if request.action == .approve || request.action == .answer {
            return await pump.respond(request, authorizeBeforeCommit: authorizeBeforeCommit)
        }
        try await authorizeBeforeCommit()
        return try await messages.apply(request)
    }
}
