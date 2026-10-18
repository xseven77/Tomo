import Foundation
import Testing
@testable import Tomo

struct ChatGPTThreadBaselineTests {
    private let ref = RemoteSessionRef(serverId: "server", agentId: "agent.chatgpt", runtimeId: "runtime", sessionId: "opaque")
    private var projector: ChatGPTEventProjector { .init(ref: ref, vendorThreadId: "vendor-thread") }
    private func item(_ id: String, text: String = "你好") -> AgentJSON {
        .object(["id": .string(id), "type": .string("agentMessage"), "text": .string(text), "phase": .string("final_answer")])
    }
    private func turn(_ id: String = "turn", status: String = "completed", items: [AgentJSON]? = nil, extra: [String: AgentJSON] = [:]) -> AgentJSON {
        var value: [String: AgentJSON] = ["id": .string(id), "status": .string(status), "items": .array(items ?? [item("item")]), "startedAt": .integer(100), "itemsView": .string("full")]
        value.merge(extra) { _, next in next }; return .object(value)
    }
    private func response(turns: [AgentJSON]? = nil, status: String = "idle", flags: [AgentJSON] = [], extra: [String: AgentJSON] = [:]) -> AgentJSON {
        var thread: [String: AgentJSON] = ["id": .string("vendor-thread"), "createdAt": .integer(10), "updatedAt": .integer(200),
            "status": .object(["type": .string(status), "activeFlags": .array(flags)]), "turns": .array(turns ?? [turn()]),
            "cwd": .string("/private/path"), "preview": .string("private preview"), "auth": .string("secret")]
        thread.merge(extra) { _, next in next }; return .object(["thread": .object(thread)])
    }

    @Test func baselineAndLiveCompletionShareIDsAndDoNotDuplicateMessages() throws {
        let projection = try projector.baseline(response: response(), executionEpoch: "executor")
        #expect(projection.messages.count == 1 && projection.control.state == "completed")
        #expect(projection.messages.first?.createdAt == "1970-01-01T00:01:40Z")
        let event = AgentRPCEvent.notification(method: "turn/completed", params: .object(["threadId": .string("vendor-thread"), "turn": turn()]))
        guard case .mutations(let values) = projector.project(event, onto: projection) else { throw ChatGPTBaselineError.invalidTurn }
        #expect(values.isEmpty)
        let wire = String(decoding: try JSONEncoder().encode(projection), as: UTF8.self)
        #expect(!wire.contains("vendor-thread") && !wire.contains("secret") && !wire.contains("private"))
        #expect(projection.control.allowedActions == ["history.read"] && projection.pendingRequests.isEmpty)
    }

    @Test func completeImportedThreadBeyondOneThousandMessagesEntersTheDurableArchive() async throws {
        let turns = (1...600).map {turn("turn-\($0)", items: [item("first"), item("second")])}
        let baseline = try projector.baseline(response: response(turns: turns), executionEpoch: "executor")
        #expect(baseline.messages.count == 1200)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("baseline-archive-" + UUID().uuidString).appendingPathComponent("journal.sqlite")
        defer {try? FileManager.default.removeItem(at: url.deletingLastPathComponent())}
        let journal = try RemoteSessionJournal(databaseURL: url)
        let initial = try await journal.replace(ref: ref, projection: baseline)
        #expect(initial.projection.messages == Array(baseline.messages.suffix(200)))
        let snapshot = try await journal.historySnapshot(ref: ref)
        #expect(snapshot.count == 1200)
        let first = try await journal.historyWindow(ref: ref, snapshot: snapshot, before: 50, limit: 50, maximumBytes: 8 * 1024 * 1024)
        #expect(first.messages == Array(baseline.messages.prefix(50)))
    }

    @Test func activeBaselineAcceptsNextDeltaThroughPersistentJournal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try RemoteSessionJournal(databaseURL: root.appendingPathComponent("journal.sqlite"))
        let baseline = try projector.baseline(response: response(turns: [turn(status: "inProgress", items: [item("item", text: "你")])], status: "active"), executionEpoch: "executor")
        let initial = try await journal.replace(ref: ref, projection: baseline)
        let event = AgentRPCEvent.notification(method: "item/agentMessage/delta", params: .object([
            "threadId": .string("vendor-thread"), "turnId": .string("turn"), "itemId": .string("item"), "delta": .string("好")]))
        guard case .mutations(let values) = projector.project(event, onto: baseline) else { throw ChatGPTBaselineError.invalidTurn }
        _ = try await journal.append(ref: ref, mutations: values, expectedStreamEpoch: initial.streamEpoch, expectedSequence: 0)
        let current = try await journal.snapshot(ref: ref)
        #expect(current.projection.messages.count == 1 && current.projection.messages.first?.content.first?.text == "你好")
        #expect(current.projection.messages.first?.messageRevision == 2)
        #expect(try await journal.replay(ref: ref, after: initial.eventCursor).map(\.event.type) == ["message.delta"])
    }

    @Test func filteringMatchesEventsAndDoesNotExposePathsOrToolArguments() throws {
        let user = AgentJSON.object(["id": .string("user"), "type": .string("userMessage"), "content": .array([
            .object(["type": .string("text"), "text": .string("看图片")]),
            .object(["type": .string("localImage"), "path": .string("/private/image")])])])
        let hidden = AgentJSON.object(["id": .string("tool"), "type": .string("commandExecution"), "command": .string("npm run typecheck"), "arguments": .string("secret")])
        let projection = try projector.baseline(response: response(turns: [turn(items: [user, hidden, item("answer")])]), executionEpoch: "executor")
        #expect(projection.messages.map(\.role) == ["user", "assistant"])
        #expect(projection.activities.count == 1 && projection.activities.first?.kind == "command")
        #expect(projection.activities.first?.status == "completed")
        #expect(projection.messages.first?.content.map(\.type) == ["text", "unsupported"])
        let wire = String(decoding: try JSONEncoder().encode(projection), as: UTF8.self)
        #expect(!wire.contains("secret") && !wire.contains("/private"))
        #expect(throws: ChatGPTBaselineError.unsupportedContent) {
            try projector.baseline(response: response(turns: [turn(items: [.object(["id": .string("future"), "type": .string("futureItem")])])]), executionEpoch: "executor")
        }
    }

    @Test func partialHistoryDuplicateIDsAndInconsistentSourcesAreRejected() throws {
        for mode in ["summary", "notLoaded", "future"] {
            #expect(throws: ChatGPTBaselineError.incompleteHistory) {
                try projector.baseline(response: response(turns: [turn(extra: ["itemsView": .string(mode)])]), executionEpoch: "executor")
            }
        }
        #expect(throws: ChatGPTBaselineError.incompleteHistory) { try projector.baseline(response: response(extra: ["historyMode": .string("paginated")]), executionEpoch: "executor") }
        for invalid in [response(turns: [turn(), turn()]), response(turns: [turn(items: [item("same"), item("same")])]),
                        response(turns: [turn(status: "inProgress"), turn("next")])] {
            #expect(throws: ChatGPTBaselineError.invalidTurn) { try projector.baseline(response: invalid, executionEpoch: "executor") }
        }
        for invalid in [response(extra: ["id": .string("foreign")]), response(extra: ["createdAt": .integer(-1)]),
                        response(extra: ["updatedAt": .integer(1)]), response(status: "future"), response(status: "active")] {
            #expect(throws: ChatGPTBaselineError.invalidThread) { try projector.baseline(response: invalid, executionEpoch: "executor") }
        }
    }

    @Test func pendingApprovalAndSystemErrorNeverAdvertiseControlOrLiveAvailability() throws {
        for flag in ["waitingOnApproval", "waitingOnUserInput"] {
            let projection = try projector.baseline(response: response(turns: [turn(status: "inProgress")], status: "active", flags: [.string(flag)]), executionEpoch: "executor")
            #expect(projection.control.state == "waitingForUser" && projection.control.controlMode == "unavailable")
            #expect(projection.control.currentTurnId == nil && projection.control.allowedActions.isEmpty && projection.pendingRequests.isEmpty)
        }
        let projection = try projector.baseline(response: response(status: "systemError"), executionEpoch: "executor")
        #expect(projection.control.state == "unknown" && projection.control.allowedActions.isEmpty)
        #expect(throws: ChatGPTBaselineError.invalidThread) {
            try projector.baseline(response: response(turns: [turn(status: "inProgress")], status: "active", flags: [.string("future")]), executionEpoch: "executor")
        }
    }

    @Test func emptyHistoryAndResourceLimitsAreExplicit() throws {
        let projection = try projector.baseline(response: response(turns: [], status: "notLoaded"), executionEpoch: "executor")
        #expect(projection.messages.isEmpty && projection.control.state == "idle")
        #expect(throws: ChatGPTBaselineError.invalidThread) { try projector.baseline(response: response(), executionEpoch: "") }
        #expect(throws: ChatGPTBaselineError.limitExceeded) {
            try projector.baseline(response: response(turns: (0...1000).map { turn("turn-\($0)") }), executionEpoch: "executor")
        }
    }
}
