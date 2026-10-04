import Foundation
import CryptoKit

enum ChatGPTProjectionResult: Sendable {
    case ignored
    case mutations([RemoteJournalMutation])
    case requiresSync(String)
}

/// Pure mapping for a serialized per-runtime event pump. It does not execute
/// vendor commands or imply execution ownership. It is read-only by default;
/// only the trusted owner runtime can opt into interrupt/active-turn steer.
struct ChatGPTEventProjector: Sendable {
    let ref: RemoteSessionRef
    let vendorThreadId: String
    var allowsOwnedInterrupt = false
    var allowsOwnedSteer = false
    var allowsOwnedFreshStart = false

    func ownedActions(state: String, currentTurnId: String?, hasPendingRequests: Bool) -> [String] {
        ["history.read"]
            + (allowsOwnedInterrupt && currentTurnId != nil ? ["turn.interrupt"] : [])
            + (allowsOwnedSteer && state == "running" && currentTurnId != nil && !hasPendingRequests ? ["message.send"] : [])
            + (allowsOwnedFreshStart && ["idle", "completed", "interrupted", "failed"].contains(state)
                && currentTurnId == nil && !hasPendingRequests ? ["message.send"] : [])
    }

    func project(_ event: AgentRPCEvent, onto projection: RemoteSessionProjection, now: Date = Date()) -> ChatGPTProjectionResult {
        let method: String, params: AgentJSON
        switch event {
        case .checkpoint: return .ignored
        case .notification(let name, let value): method = name; params = value
        case .request(_, let name, let value):
            if case .object(let fields) = value, let thread = string(fields["threadId"]), thread != vendorThreadId { return .ignored }
            // Unimplemented question/approval/auth refresh cannot be auto-approved
            // or exposed as actionable raw RPC. The coordinator must stop writes.
            return .requiresSync("unsupported_server_request:" + name)
        }
        guard case .object(let fields) = params else { return .requiresSync("invalid_event") }
        guard let thread = string(fields["threadId"]) else { return .ignored }
        guard thread == vendorThreadId else { return .ignored }
        switch method {
        case "turn/started", "turn/completed":
            guard case .object(let turn) = fields["turn"], let vendorTurn = string(turn["id"]),
                  let status = string(turn["status"]), ["inProgress", "completed", "interrupted", "failed"].contains(status),
                  case .array(let items) = turn["items"] else { return .requiresSync("invalid_turn") }
            let turnId = identifier("turn", vendorTurn)
            if method == "turn/completed", projection.control.currentTurnId != nil, projection.control.currentTurnId != turnId {
                return .requiresSync("turn_changed")
            }
            var mutations: [RemoteJournalMutation] = []
            for item in items {
                switch itemMutation(item, turnId: turnId, completed: status != "inProgress", projection: projection, now: now) {
                case .ignored: break
                case .mutations(let values): mutations += values
                case .requiresSync(let reason): return .requiresSync(reason)
                }
            }
            let state = status == "inProgress" ? "running" : status
            let current = status == "inProgress" ? turnId : nil
            let previous = projection.control
            let mode = allowsOwnedInterrupt ? "live" : "readOnly"
            let actions = ownedActions(state: state, currentTurnId: current, hasPendingRequests: !projection.pendingRequests.isEmpty)
            if previous.state != state || previous.currentTurnId != current || previous.controlMode != mode || previous.allowedActions != actions {
                mutations.append(.control(.init(executionEpoch: previous.executionEpoch, controlRevision: previous.controlRevision + 1,
                    state: state, controlMode: mode, currentTurnId: current, allowedActions: actions)))
            }
            return .mutations(mutations)
        case "item/started", "item/completed":
            guard let vendorTurn = string(fields["turnId"]), let item = fields["item"] else { return .requiresSync("invalid_item") }
            let turnId = identifier("turn", vendorTurn)
            guard projection.control.currentTurnId == turnId else { return .requiresSync("turn_changed") }
            return itemMutation(item, turnId: turnId, completed: method == "item/completed", projection: projection, now: now)
        case "item/agentMessage/delta":
            guard let vendorTurn = string(fields["turnId"]), let item = string(fields["itemId"]),
                  case .string(let text) = fields["delta"] else { return .requiresSync("invalid_delta") }
            let turnId = identifier("turn", vendorTurn)
            let id = messageID(turnId: turnId, vendorItemId: item)
            guard projection.control.currentTurnId == turnId,
                  let message = projection.messages.first(where: { $0.messageId == id }), message.turnId == turnId,
                  message.role == "assistant", message.status == "streaming" else { return .requiresSync("delta_without_baseline") }
            return .mutations([.delta(messageId: id, partId: "text", revision: message.messageRevision + 1, text: text)])
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta", "item/reasoning/summaryPartAdded",
             "item/commandExecution/outputDelta", "item/commandExecution/terminalInteraction", "item/fileChange/outputDelta",
             "thread/tokenUsage/updated":
            return .ignored
        default: return .requiresSync("unsupported_event:" + method)
        }
    }

    func itemMutation(_ value: AgentJSON, turnId: String, completed: Bool,
                              projection: RemoteSessionProjection, now: Date) -> ChatGPTProjectionResult {
        guard case .object(let item) = value, let type = string(item["type"]), let vendorId = string(item["id"]) else {
            return .requiresSync("invalid_item")
        }
        let role: String, parts: [RemoteHistoryPart]
        switch type {
        case "agentMessage":
            if let phase = item["phase"], phase != .null {
                guard case .string(let value) = phase, ["commentary", "final_answer"].contains(value) else { return .requiresSync("unknown_message_phase") }
            }
            guard case .string(let text) = item["text"] else { return .requiresSync("invalid_message") }
            role = "assistant"; parts = [.init(partId: "text", type: "text", text: text)]
        case "userMessage":
            guard case .array(let content) = item["content"], content.count <= 128 else { return .requiresSync("invalid_message") }
            role = "user"
            var result: [RemoteHistoryPart] = []
            for (index, part) in content.enumerated() {
                guard case .object(let fields) = part, let kind = string(fields["type"]) else { return .requiresSync("invalid_message") }
                if kind == "text" {
                    guard case .string(let text) = fields["text"] else { return .requiresSync("invalid_message") }
                    result.append(.init(partId: "part_\(index)", type: "text", text: text))
                } else {
                    // Paths, URLs, attachment payloads and skill content are not
                    // forwarded until their dedicated authorized resource API exists.
                    result.append(.init(partId: "part_\(index)", type: "unsupported", text: "此内容暂不支持显示"))
                }
            }
            parts = result
        case "commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "collabAgentToolCall",
             "webSearch", "imageView", "imageGeneration":
            let kind: String
            switch type {
            case "commandExecution": kind = "command"
            case "fileChange": kind = "fileChange"
            case "mcpToolCall": kind = "mcpTool"
            case "dynamicToolCall": kind = "dynamicTool"
            case "collabAgentToolCall": kind = "collabTool"
            default: kind = type
            }
            let id = identifier("activity", turnId, vendorId)
            let previous = projection.activities.first { $0.activityId == id }
            let status: String
            if case .string(let raw) = item["status"] {
                switch raw {
                case "inProgress": status = completed ? "unknown" : "running"
                case "completed": status = "completed"
                case "failed": status = "failed"
                default: status = "unknown"
                }
            } else { status = completed ? "completed" : "running" }
            if let previous, previous.status == status || !["running", "unknown"].contains(previous.status) { return .mutations([]) }
            let activity = RemoteToolActivity(activityId: id, turnId: turnId,
                activityRevision: (previous?.activityRevision ?? 0) + 1, kind: kind, status: status,
                createdAt: previous?.createdAt ?? ISO8601DateFormatter().string(from: now))
            return .mutations([.activity(activity)])
        case "reasoning", "hookPrompt", "functionCallOutput", "plan", "contextCompaction":
            return .ignored
        default: return .requiresSync("unsupported_item:" + type)
        }
        // The turn part is already opaque and namespaced; this identity is also
        // used when importing app-server thread/read baselines. Rollout byte-offset
        // message IDs must not be mixed into the same live projection.
        let id = messageID(turnId: turnId, vendorItemId: vendorId)
        let previous = projection.messages.first { $0.messageId == id }
        let status = (completed || role == "user") ? "completed" : "streaming"
        if let previous, previous.content == parts, previous.status == status { return .mutations([]) }
        let message = RemoteHistoryMessage(messageId: id, turnId: turnId, messageRevision: (previous?.messageRevision ?? 0) + 1,
            role: role, createdAt: previous?.createdAt ?? ISO8601DateFormatter().string(from: now), status: status, content: parts)
        return .mutations([.message(message)])
    }
    private func string(_ value: AgentJSON?) -> String? {
        if case .string(let value) = value, !value.isEmpty, value.utf8.count <= 256 { return value }; return nil
    }
    func identifier(_ kind: String, _ values: String...) -> String {
        let bytes = try! JSONEncoder().encode([ref.serverId, ref.agentId, ref.runtimeId, ref.sessionId, vendorThreadId, kind] + values)
        return "remote_" + kind + "_" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private func messageID(turnId: String, vendorItemId: String) -> String { identifier("message", turnId, vendorItemId) }
}
