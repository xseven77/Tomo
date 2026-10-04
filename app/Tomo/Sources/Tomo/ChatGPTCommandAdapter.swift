import Foundation

typealias ChatGPTCommandError = RemoteCommandError

/// Supplied by the locally owned runtime, never decoded from a remote body.
/// permitsFreshStart is a runtime guarantee that turn/start cannot silently
/// steer an autonomous/external turn. A read-only subscription is insufficient.
struct ChatGPTCommandContext: Sendable {
    let ref: RemoteSessionRef
    let vendorThreadId: String
    let vendorCurrentTurnId: String?
    let control: RemoteSessionControl
    let hasPendingRequests: Bool
    let permitsFreshStart: Bool
}

/// Narrow app-server mapping. It does not launch/resume a process, select an
/// account, change permissions/model/cwd, or auto-answer server requests.
actor ChatGPTCommandAdapter: RemoteCommandAdapter {
    typealias Context = @Sendable (RemoteSessionRef) async throws -> ChatGPTCommandContext
    private enum Input {
        case start(client: String, revision: Int, text: [String])
        case steer(client: String, revision: Int, turn: String, text: [String])
        case interrupt(turn: String)
    }
    private let channel: AgentRPCChannel
    private let context: Context
    private var inFlight = Set<RemoteSessionRef>()
    private var started: [RemoteSessionRef: (epoch: String, revision: Int)] = [:]

    init(channel: AgentRPCChannel, context: @escaping Context) {
        self.channel = channel; self.context = context
    }

    func validate(_ request: RemoteOperationRequest) async throws {
        let input = try parse(request)
        try check(request, input, context: try await context(request.ref))
        guard !inFlight.contains(request.ref) else {throw ChatGPTCommandError.sessionBusy}
    }

    func apply(_ request: RemoteOperationRequest) async throws -> RemoteCommandOutcome {
        // Reserve before awaiting context so commands on one thread cannot race
        // within this adapter. The owner must also enforce exclusive execution
        // across all transports/controllers; this local gate cannot do that.
        guard !inFlight.contains(request.ref) else {return .rejected}
        inFlight.insert(request.ref); defer {inFlight.remove(request.ref)}
        let input: Input, current: ChatGPTCommandContext
        do {
            input = try parse(request)
            current = try await context(request.ref)
            try check(request, input, context: current)
            try Task.checkCancellation()
        } catch {return .rejected}
        let projector = ChatGPTEventProjector(ref: request.ref, vendorThreadId: current.vendorThreadId)
        let response: AgentJSON
        do {
            switch input {
            case .start(let client, let revision, let texts):
                guard started[request.ref] != nil || started.count < 128 else {return .rejected}
                // An ack can arrive before the event pump updates control. Keep
                // starts blocked at this revision until trusted state advances.
                started[request.ref] = (request.executionEpoch, revision)
                response = try await channel.request(method: "turn/start", params: .object([
                    "threadId": .string(current.vendorThreadId), "clientUserMessageId": .string(client),
                    "input": .array(texts.map {.object(["type": .string("text"), "text": .string($0), "text_elements": .array([])])})]))
            case .interrupt:
                response = try await channel.request(method: "turn/interrupt", params: .object([
                    "threadId": .string(current.vendorThreadId), "turnId": .string(current.vendorCurrentTurnId!)]))
            case .steer(let client, _, _, let texts):
                // The vendor performs the active-turn comparison atomically.
                // Never replace a failed steer with turn/start or another turn.
                response = try await channel.request(method: "turn/steer", params: .object([
                    "threadId": .string(current.vendorThreadId), "expectedTurnId": .string(current.vendorCurrentTurnId!),
                    "clientUserMessageId": .string(client),
                    "input": .array(texts.map {.object(["type": .string("text"), "text": .string($0), "text_elements": .array([])])})]))
            }
        } catch AgentRPCError.vendor(let code, _) where code == -32602 || code == -32601 {
            // Explicit invalid-params/method rejection, without forwarding
            // private vendor error strings. Other failures may follow mutation.
            if case .start = input {started.removeValue(forKey: request.ref)}
            return .rejected
        } catch {return .uncertain}
        switch input {
        case .start:
            guard case .object(let result) = response, case .object(let turn) = result["turn"],
                  let id = identifier(turn["id"]),
                  case .string(let status) = turn["status"], ["inProgress", "completed", "interrupted", "failed"].contains(status),
                  case .array = turn["items"] else {return .uncertain}
            return .applied(turnId: projector.identifier("turn", id))
        case .interrupt(let turn):
            guard case .object(let result) = response, result.isEmpty else {return .uncertain}
            return .applied(turnId: turn)
        case .steer(_, _, let turn, _):
            guard case .object(let result) = response, let vendorTurn = identifier(result["turnId"]),
                  vendorTurn == current.vendorCurrentTurnId,
                  projector.identifier("turn", vendorTurn) == turn else {return .uncertain}
            return .applied(turnId: turn)
        }
    }

    private func parse(_ request: RemoteOperationRequest) throws -> Input {
        guard request.ref.agentId == "agent.chatgpt", identifier(.string(request.executionEpoch)) != nil,
              case .object(let body) = request.body else {throw ChatGPTCommandError.invalidInput}
        switch request.action {
        case .sendMessage:
            let steering = body["mode"] == .string("steer")
            let keys: Set<String> = steering
                ? ["clientMessageId", "expectedControlRevision", "input", "mode", "expectedTurnId"]
                : ["clientMessageId", "expectedControlRevision", "input", "mode"]
            guard Set(body.keys) == keys,
                  let client = identifier(body["clientMessageId"]),
                  case .integer(let revision) = body["expectedControlRevision"], revision >= 0, revision <= Int64(Int.max),
                  (steering || body["mode"] == .string("start")), case .array(let parts) = body["input"],
                  (1...32).contains(parts.count) else {throw ChatGPTCommandError.invalidInput}
            var texts: [String] = [], bytes = 0
            for part in parts {
                guard case .object(let value) = part, Set(value.keys) == ["type", "text"], value["type"] == .string("text"),
                      case .string(let text) = value["text"], !text.contains("\0") else {throw ChatGPTCommandError.invalidInput}
                bytes += text.utf8.count
                guard bytes <= 48 * 1024 else {throw ChatGPTCommandError.invalidInput}
                texts.append(text)
            }
            guard texts.contains(where: {!$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty}) else {throw ChatGPTCommandError.invalidInput}
            if steering {
                guard let turn = identifier(body["expectedTurnId"]) else {throw ChatGPTCommandError.invalidInput}
                return .steer(client: client, revision: Int(revision), turn: turn, text: texts)
            }
            return .start(client: client, revision: Int(revision), text: texts)
        case .interrupt:
            guard Set(body.keys) == ["turnId"], let turn = identifier(body["turnId"]) else {throw ChatGPTCommandError.invalidInput}
            return .interrupt(turn: turn)
        default: throw ChatGPTCommandError.unsupportedAction
        }
    }

    private func check(_ request: RemoteOperationRequest, _ input: Input, context current: ChatGPTCommandContext) throws {
        guard current.ref == request.ref, identifier(.string(current.vendorThreadId)) != nil,
              current.control.executionEpoch == request.executionEpoch,
              current.control.controlMode == "live", current.control.allowedActions.contains(request.action.rawValue) else {
            throw ChatGPTCommandError.controlChanged
        }
        switch input {
        case .steer(_, let revision, let turn, _):
            guard current.control.controlRevision == revision else {throw ChatGPTCommandError.controlChanged}
            guard current.control.state == "running", !current.hasPendingRequests else {throw ChatGPTCommandError.sessionBusy}
            guard current.control.currentTurnId == turn, let vendor = current.vendorCurrentTurnId,
                  identifier(.string(vendor)) != nil,
                  ChatGPTEventProjector(ref: request.ref, vendorThreadId: current.vendorThreadId).identifier("turn", vendor) == turn else {
                throw ChatGPTCommandError.controlChanged
            }
        case .start(_, let revision, _):
            guard current.control.controlRevision == revision else {throw ChatGPTCommandError.controlChanged}
            if let prior = started[request.ref], prior.epoch == request.executionEpoch, revision <= prior.revision {
                throw ChatGPTCommandError.sessionBusy
            }
            guard ["idle", "completed", "interrupted", "failed"].contains(current.control.state),
                  current.control.currentTurnId == nil, current.vendorCurrentTurnId == nil, !current.hasPendingRequests else {
                throw ChatGPTCommandError.sessionBusy
            }
            guard current.permitsFreshStart else {throw ChatGPTCommandError.unsafeStart}
        case .interrupt(let turn):
            guard ["running", "waitingForUser"].contains(current.control.state),
                  current.control.currentTurnId == turn, let vendor = current.vendorCurrentTurnId,
                  identifier(.string(vendor)) != nil,
                  ChatGPTEventProjector(ref: request.ref, vendorThreadId: current.vendorThreadId).identifier("turn", vendor) == turn else {
                throw ChatGPTCommandError.controlChanged
            }
        }
    }
    private func identifier(_ value: AgentJSON?) -> String? {
        guard case .string(let value) = value, !value.isEmpty, value.utf8.count <= 256, !value.contains("\0") else {return nil}
        return value
    }
}
