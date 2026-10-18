import Foundation

enum ChatGPTBaselineError: Error, Equatable {
    case invalidThread, invalidTurn, incompleteHistory, unsupportedContent, limitExceeded
}

/// Imports an explicitly requested, full app-server thread/read response using
/// the same item identities and content filter as subsequent live events.
/// This pure importer does not establish a stream/baseline synchronization barrier.
extension ChatGPTEventProjector {
    func baseline(response: AgentJSON, executionEpoch: String) throws -> RemoteSessionProjection {
        guard !executionEpoch.isEmpty, executionEpoch.utf8.count <= 256, !executionEpoch.contains("\0"),
              case .object(let result) = response, case .object(let thread) = result["thread"],
              thread["id"] == .string(vendorThreadId), case .array(let turns) = thread["turns"],
              case .object(let status) = thread["status"], case .string(let statusType) = status["type"],
              ["idle", "notLoaded", "active", "systemError"].contains(statusType),
              let created = baselineDate(thread["createdAt"]), let updated = baselineDate(thread["updatedAt"]), updated >= created else {
            throw ChatGPTBaselineError.invalidThread
        }
        // Paginated thread/read may return an incomplete turn window even when
        // includeTurns was requested. Never mistake it for the complete history.
        if let mode = thread["historyMode"], mode != .null, mode != .string("legacy") {
            throw ChatGPTBaselineError.incompleteHistory
        }
        guard turns.count <= 1000, try JSONEncoder().encode(response).count <= 8 * 1024 * 1024 else {
            throw ChatGPTBaselineError.limitExceeded
        }
        var projection = RemoteSessionProjection(control: .init(executionEpoch: executionEpoch, controlRevision: 0,
            state: "idle", controlMode: "readOnly", currentTurnId: nil, allowedActions: ["history.read"]),
            messages: [], pendingRequests: [], olderHistoryCursor: nil, hasOlder: false)
        var turnIDs = Set<String>(), messageIDs = Set<String>(), activityIDs = Set<String>(), activeTurn: String?, lastStatus = "idle", itemCount = 0
        for (index, value) in turns.enumerated() {
            guard case .object(let turn) = value, case .string(let id) = turn["id"], !id.isEmpty,
                  id.utf8.count <= 256, !id.contains("\0"), turnIDs.insert(id).inserted,
                  case .string(let state) = turn["status"], ["inProgress", "completed", "interrupted", "failed"].contains(state),
                  case .array(let items) = turn["items"] else { throw ChatGPTBaselineError.invalidTurn }
            if let view = turn["itemsView"], view != .string("full") { throw ChatGPTBaselineError.incompleteHistory }
            guard activeTurn == nil, state != "inProgress" || index == turns.count - 1 else { throw ChatGPTBaselineError.invalidTurn }
            let started: Date
            if let value = turn["startedAt"], value != .null {
                guard let date = baselineDate(value), date >= created, date <= updated else { throw ChatGPTBaselineError.invalidTurn }
                started = date
            } else { started = created }
            let turnId = identifier("turn", id)
            if state == "inProgress" { activeTurn = turnId }
            lastStatus = state == "inProgress" ? "running" : state
            var vendorItems = Set<String>()
            for item in items {
                itemCount += 1
                guard itemCount <= 10000 else { throw ChatGPTBaselineError.limitExceeded }
                guard case .object(let fields) = item, case .string(let vendorID) = fields["id"],
                      !vendorID.isEmpty, !vendorID.contains("\0"), vendorItems.insert(vendorID).inserted else { throw ChatGPTBaselineError.invalidTurn }
                switch itemMutation(item, turnId: turnId, completed: state != "inProgress", projection: projection, now: started) {
                case .ignored: continue
                case .requiresSync: throw ChatGPTBaselineError.unsupportedContent
                case .mutations(let mutations):
                    for mutation in mutations {
                        switch mutation {
                        case .message(let message):
                            guard messageIDs.insert(message.messageId).inserted else { throw ChatGPTBaselineError.invalidTurn }
                            projection.messages.append(message)
                            // Imported messages go into the durable archive;
                            // only its recent/active tail enters live projection.
                            guard projection.messages.count <= 10000 else { throw ChatGPTBaselineError.limitExceeded }
                        case .activity(let activity):
                            guard activityIDs.insert(activity.activityId).inserted else { throw ChatGPTBaselineError.invalidTurn }
                            projection.activities.append(activity)
                            guard projection.activities.count <= 1000 else { throw ChatGPTBaselineError.limitExceeded }
                        case .toolResult(let id, let result): projection.toolResults[id] = result
                        default: throw ChatGPTBaselineError.invalidTurn
                        }
                    }
                }
            }
        }
        var waiting = false
        if statusType == "active" {
            guard activeTurn != nil, case .array(let flags) = status["activeFlags"],
                  flags.allSatisfy({ $0 == .string("waitingOnApproval") || $0 == .string("waitingOnUserInput") }), Set(flags.map { String(describing: $0) }).count == flags.count else {
                throw ChatGPTBaselineError.invalidThread
            }
            waiting = !flags.isEmpty
        } else if activeTurn != nil { throw ChatGPTBaselineError.invalidThread }
        let unavailable = waiting || statusType == "systemError"
        projection.control = .init(executionEpoch: executionEpoch, controlRevision: 0,
            state: waiting ? "waitingForUser" : statusType == "systemError" ? "unknown" : lastStatus,
            controlMode: unavailable ? "unavailable" : "readOnly", currentTurnId: unavailable ? nil : activeTurn,
            allowedActions: unavailable ? [] : ["history.read"])
        projection.activities = RemoteToolPresentation.compact(projection.activities)
        return projection
    }

    private func baselineDate(_ value: AgentJSON?) -> Date? {
        guard case .integer(let seconds) = value, (0...253402300799).contains(seconds) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}
