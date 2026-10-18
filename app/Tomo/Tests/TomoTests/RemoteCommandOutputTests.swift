import Foundation
import Testing
@testable import Tomo

struct RemoteCommandOutputTests {
    let ref = RemoteSessionRef(serverId: "server", agentId: "agent.chatgpt", runtimeId: "runtime", sessionId: "output-session")
    var projector: ChatGPTEventProjector { .init(ref: ref, vendorThreadId: "private-thread") }
    var baseline: RemoteSessionProjection {
        .init(control: .init(executionEpoch: "epoch", controlRevision: 0, state: "running", controlMode: "readOnly",
            currentTurnId: projector.identifier("turn", "private-turn"), allowedActions: ["history.read"]),
            messages: [], pendingRequests: [], olderHistoryCursor: nil, hasOlder: false)
    }
    func event(_ method: String, _ fields: [String: AgentJSON], thread: String = "private-thread", turn: String = "private-turn") -> AgentRPCEvent {
        .notification(method: method, params: .object(fields.merging(["threadId": .string(thread), "turnId": .string(turn)]) { _, new in new }))
    }
    func command(_ status: String, output: AgentJSON = .null) -> AgentJSON {
        .object(["type": .string("commandExecution"), "id": .string("private-item"), "status": .string(status),
            "command": .string("synthetic-check"), "cwd": .string("/workspace/rn"), "aggregatedOutput": output,
            "exitCode": status == "completed" ? .integer(0) : .null, "durationMs": status == "completed" ? .integer(42) : .null,
            "processId": .string("private-process"), "arguments": .string("private-arguments")])
    }
    func activity(_ event: AgentRPCEvent, onto projection: RemoteSessionProjection) throws -> RemoteToolActivity {
        guard case .mutations(let values) = projector.project(event, onto: projection), case .activity(let value) = values.first else {
            throw RemoteJournalError.invalidProjection
        }
        return value
    }
    func runningProjection() throws -> RemoteSessionProjection {
        var result = baseline
        result.activities = [try activity(event("item/started", ["item": command("inProgress")]), onto: result)]
        return result
    }

    @Test func actualCommandDeltasPersistReplayAndAreReplacedByFinalAggregate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try RemoteSessionJournal(databaseURL: root.appendingPathComponent("stream.sqlite"))
        let initial = try await journal.replace(ref: ref, projection: baseline)
        let notifications = [event("item/started", ["item": command("inProgress")]),
            event("item/commandExecution/outputDelta", ["itemId": .string("private-item"), "delta": .string("实时 🐙\n")]),
            event("item/commandExecution/outputDelta", ["itemId": .string("private-item"), "delta": .string("<script>仅文本</script>\n")])]
        for notification in notifications {
            let projection = try await journal.snapshot(ref: ref).projection
            _ = try await journal.append(ref: ref, mutation: .activity(activity(notification, onto: projection)))
        }
        let streamed = try await journal.snapshot(ref: ref)
        let current = try #require(streamed.projection.activities.first)
        #expect(current.status == "running" && current.activityRevision == 3)
        #expect(current.presentation?.blocks.last?.text == "实时 🐙\n<script>仅文本</script>\n")
        let finalEvent = event("item/completed", ["item": command("completed", output: .string("最终校正结果 🐙"))])
        _ = try await journal.append(ref: ref, mutation: .activity(activity(finalEvent, onto: streamed.projection)))
        let reopened = try RemoteSessionJournal(databaseURL: root.appendingPathComponent("stream.sqlite"))
        let final = try await reopened.snapshot(ref: ref), records = try await reopened.replay(ref: ref, after: initial.eventCursor)
        #expect(final.projection.activities.count == 1 && final.projection.activities.first?.activityRevision == 4)
        #expect(final.projection.activities.first?.presentation?.blocks.last?.text == "最终校正结果 🐙")
        #expect(final.projection.activities.first?.presentation?.truncated == false)
        #expect(records.map(\.event.type) == ["activity.created", "activity.updated", "activity.updated", "activity.updated"])
        #expect(records.map(\.event.payload).count == 4)
        guard case .mutations(let duplicate) = projector.project(finalEvent, onto: final.projection) else { throw RemoteJournalError.invalidProjection }
        // The pure adapter may refresh the independent completed-text archive,
        // but a duplicate must not advance projection/replay or activity identity.
        #expect(try await journal.append(ref: ref, mutations: duplicate).isEmpty)
        #expect(try await journal.snapshot(ref: ref).sequence == final.sequence)
        let wire = String(decoding: try JSONEncoder().encode(final), as: UTF8.self)
        #expect(!wire.contains("private-") && !wire.contains("实时"))
        if let path = ProcessInfo.processInfo.environment["TOMO_TOOL_STREAM_WIRE_FIXTURE"] {
            struct Export: Encodable {let ref: RemoteSessionRef; let initial: RemoteJournalSync; let final: RemoteJournalSync; let events: [RemoteJournalRecord]}
            try JSONEncoder().encode(Export(ref: ref, initial: initial, final: final, events: records)).write(to: URL(fileURLWithPath: path))
        }
    }

    @Test func absentFinalAggregateKeepsObservedOutputAsPartialButEmptyAggregateClearsIt() throws {
        var projection = try runningProjection()
        projection.activities = [try activity(event("item/commandExecution/outputDelta", ["itemId": .string("private-item"), "delta": .string("已接收片段")]), onto: projection)]
        let missing = try activity(event("item/completed", ["item": command("completed")]), onto: projection)
        #expect(missing.presentation?.blocks.last?.text == "已接收片段" && missing.presentation?.truncated == true)
        let empty = try activity(event("item/completed", ["item": command("completed", output: .string(""))]), onto: projection)
        #expect(empty.presentation?.blocks.contains(where: { $0.label == RemoteToolPresentation.commandOutputLabel }) == false)
        #expect(empty.presentation?.truncated == false)
    }

    @Test func oversizedDeltasStopGrowingAndFinalMetadataSurvivesTruncation() throws {
        var projection = try runningProjection()
        let huge = String(repeating: "🐙中文\u{1}\n", count: 20_000)
        let delta = event("item/commandExecution/outputDelta", ["itemId": .string("private-item"), "delta": .string(huge)])
        let streamed = try activity(delta, onto: projection)
        #expect(streamed.presentation?.valid == true && streamed.presentation?.truncated == true)
        #expect(streamed.presentation?.blocks.last?.text.contains("�") == false)
        projection.activities = [streamed]
        guard case .ignored = projector.project(delta, onto: projection) else { Issue.record("Full prefix must not keep generating revisions"); return }
        let final = try activity(event("item/completed", ["item": command("completed", output: .string(huge))]), onto: projection)
        #expect(final.presentation?.truncated == true && final.presentation?.valid == true)
        #expect(final.presentation?.blocks.contains(where: { $0.label == "退出码" && $0.text == "0" }) == true)
        #expect(final.presentation?.blocks.contains(where: { $0.label == "耗时（毫秒）" && $0.text == "42" }) == true)
    }

    @Test func missingWrongTurnTerminalAndWrongKindDeltasCannotCreateOrReviveActivities() throws {
        let delta = event("item/commandExecution/outputDelta", ["itemId": .string("private-item"), "delta": .string("text")])
        var wrongKind = try runningProjection(), terminal = wrongKind
        let original = try #require(wrongKind.activities.first)
        wrongKind.activities = [.init(activityId: original.activityId, turnId: original.turnId, activityRevision: 1,
            kind: "fileChange", status: "running", createdAt: original.createdAt)]
        terminal.activities = [.init(activityId: original.activityId, turnId: original.turnId, activityRevision: 2,
            kind: "command", status: "completed", createdAt: original.createdAt)]
        for projection in [baseline, wrongKind, terminal] {
            guard case .requiresSync("tool_delta_without_baseline") = projector.project(delta, onto: projection) else {
                Issue.record("Output must belong to the exact running command"); continue
            }
        }
        guard case .requiresSync = projector.project(event("item/commandExecution/outputDelta", ["itemId": .string("private-item"), "delta": .integer(1)]), onto: terminal) else { throw RemoteJournalError.invalidProjection }
        guard case .requiresSync = projector.project(event("item/commandExecution/outputDelta", ["itemId": .string("private-item"), "delta": .string("text")], turn: "other"), onto: terminal) else { throw RemoteJournalError.invalidProjection }
        guard case .ignored = projector.project(event("item/commandExecution/outputDelta", ["itemId": .string("private-item"), "delta": .string("text")], thread: "other"), onto: terminal) else { throw RemoteJournalError.invalidProjection }
        var evicted = try runningProjection()
        for index in 1...17 { evicted.activities.append(.init(activityId: "other-\(index)", turnId: original.turnId, activityRevision: 1, kind: "command", status: "running", createdAt: original.createdAt)) }
        evicted.activities = RemoteToolPresentation.compact(evicted.activities)
        guard case .ignored = projector.project(delta, onto: evicted) else { throw RemoteJournalError.invalidProjection }
    }
}
