import Foundation
import Testing
@testable import Tomo

struct ChatGPTEventProjectorTests {
    private let ref = RemoteSessionRef(serverId: "server", agentId: "agent.chatgpt", runtimeId: "runtime", sessionId: "opaque")
    private func event(_ method: String, _ fields: [String: AgentJSON], thread: String = "vendor-thread") -> AgentRPCEvent {
        var values = fields; values["threadId"] = .string(thread)
        return .notification(method: method, params: .object(values))
    }
    private func item(_ type: String, id: String = "item", text: String = "") -> AgentJSON {
        .object(["type": .string(type), "id": .string(id), "text": .string(text)])
    }
    private func turn(_ status: String, items: [AgentJSON] = []) -> AgentJSON {
        .object(["id": .string("vendor-turn"), "status": .string(status), "items": .array(items)])
    }
    private var baseline: RemoteSessionProjection {
        .init(control: .init(executionEpoch: "process", controlRevision: 0, state: "idle", controlMode: "readOnly", currentTurnId: nil, allowedActions: ["history.read"]),
              messages: [], pendingRequests: [], olderHistoryCursor: nil, hasOlder: false)
    }
    private func location() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("events.sqlite")
    }
    private func consume(_ event: AgentRPCEvent, projector: ChatGPTEventProjector, journal: RemoteSessionJournal) async throws {
        let current = try await journal.snapshot(ref: ref)
        guard case .mutations(let values) = projector.project(event, onto: current.projection) else { throw RemoteJournalError.invalidProjection }
        _ = try await journal.append(ref: ref, mutations: values)
    }

    @Test func threadStatusHintsDoNotInventRequestsOrOverrideExplicitTurnLifecycle() {
        let projector = ChatGPTEventProjector(ref: ref, vendorThreadId: "vendor-thread")
        for status in [AgentJSON.object(["type": .string("idle")]),
            .object(["type": .string("active"), "activeFlags": .array([])]),
            .object(["type": .string("active"), "activeFlags": .array([.string("waitingOnApproval"), .string("waitingOnUserInput")])])]
        {
            guard case .ignored = projector.project(event("thread/status/changed", ["status": status]), onto: baseline) else {
                Issue.record("Known status hints must defer to explicit requests/turn events"); continue
            }
        }
        for status in [AgentJSON.object(["type": .string("systemError")]), .object(["type": .string("notLoaded")]),
            .object(["type": .string("active"), "activeFlags": .array([.string("futureWait")])]),
            .object(["type": .string("active"), "activeFlags": .array([.string("waitingOnApproval"), .string("waitingOnApproval")])])]
        {
            guard case .requiresSync = projector.project(event("thread/status/changed", ["status": status]), onto: baseline) else {
                Issue.record("Unsupported thread state must invalidate control"); continue
            }
        }
    }

    @Test func savedThreadSettingsDoNotWithdrawALiveConversationOrExposePrivateConfiguration() {
        let projector = ChatGPTEventProjector(ref: ref, vendorThreadId: "vendor-thread")
        let notification = event("thread/settings/updated", ["threadSettings": .object([
            "model": .string("configured-model"), "cwd": .string("/private/isolated-workspace"),
            "approvalPolicy": .string("never"), "sandboxPolicy": .object(["type": .string("readOnly")])])])
        // The installed runtime emits this saved-configuration notice on the
        // first turn. It carries no execution, ownership or approval authority.
        guard case .ignored = projector.project(notification, onto: baseline) else {
            Issue.record("Saved settings incorrectly make the active session unavailable"); return
        }
        guard case .requiresSync = projector.project(event("thread/futurePermissionEvent", [:]), onto: baseline) else {
            Issue.record("Unknown lifecycle events must still fail closed"); return
        }
        guard case .requiresSync = projector.project(event("thread/settings/updated", ["threadSettings": .null]), onto: baseline) else {
            Issue.record("Malformed settings notifications must still fail closed"); return
        }
    }

    @Test func threadMetadataNoticesRightAfterAResumeDoNotMakeTheSessionUnavailable() {
        let projector = ChatGPTEventProjector(ref: ref, vendorThreadId: "vendor-thread")
        for name in ["thread/goal/cleared", "thread/goal/updated", "thread/name/updated", "mcpServer/startupStatus/updated"] {
            guard case .ignored = projector.project(event(name, [:]), onto: baseline) else {
                Issue.record("\(name) must not degrade a resumed session"); return
            }
        }
    }

    @Test func visibleLifecycleUsesStableIDsAndFinalMessageRepairsDeltaText() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = try RemoteSessionJournal(databaseURL: url), projector = ChatGPTEventProjector(ref: ref, vendorThreadId: "vendor-thread")
        let initial = try await journal.replace(ref: ref, projection: baseline)
        try await consume(event("turn/started", ["turn": turn("inProgress")]), projector: projector, journal: journal)
        try await consume(event("item/started", ["turnId": .string("vendor-turn"), "item": item("agentMessage")]), projector: projector, journal: journal)
        try await consume(event("item/agentMessage/delta", ["turnId": .string("vendor-turn"), "itemId": .string("item"), "delta": .string("你好")]), projector: projector, journal: journal)
        let streamed = try await journal.snapshot(ref: ref)
        #expect(streamed.projection.messages.first?.content.first?.text == "你好")
        let toolStarted = AgentJSON.object(["type": .string("commandExecution"), "id": .string("command-1"),
                                            "status": .string("inProgress"), "command": .string("npm run typecheck")])
        let toolCompleted = AgentJSON.object(["type": .string("commandExecution"), "id": .string("command-1"),
                                              "status": .string("completed"), "command": .string("npm run typecheck")])
        try await consume(event("item/started", ["turnId": .string("vendor-turn"), "item": toolStarted]), projector: projector, journal: journal)
        try await consume(event("turn/completed", ["turn": turn("completed", items: [item("agentMessage", text: "你好，完整正文"), toolCompleted])]), projector: projector, journal: journal)
        let final = try await journal.snapshot(ref: ref)
        #expect(final.projection.messages.count == 1)
        #expect(final.projection.messages.first?.messageId == streamed.projection.messages.first?.messageId)
        #expect(final.projection.messages.first?.messageRevision == 3)
        #expect(final.projection.messages.first?.content.first?.text == "你好，完整正文")
        #expect(final.projection.control.state == "completed" && final.projection.control.currentTurnId == nil)
        #expect(final.projection.control.allowedActions == ["history.read"])
        let events = try await journal.replay(ref: ref, after: initial.eventCursor)
        #expect(events.map(\.event.type) == ["session.updated", "message.created", "message.delta", "activity.created", "message.completed", "activity.updated", "session.updated"])
        let wire = try JSONEncoder().encode(final)
        #expect(!String(decoding: wire, as: UTF8.self).contains("vendor-turn"))
        #expect(!String(decoding: wire, as: UTF8.self).contains("vendor-thread"))
        #expect(String(decoding: wire, as: UTF8.self).contains("npm run typecheck"))
        if let path = ProcessInfo.processInfo.environment["TOMO_JOURNAL_WIRE_FIXTURE"] {
            struct Export: Encodable {
                let ref: RemoteSessionRef
                let initial: RemoteJournalSync
                let final: RemoteJournalSync
                let events: [RemoteJournalRecord]
            }
            try JSONEncoder().encode(Export(ref: ref, initial: initial, final: final, events: events))
                .write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        // Repeated full completion is idempotent, not a second message/event.
        try await consume(event("turn/completed", ["turn": turn("completed", items: [item("agentMessage", text: "你好，完整正文"), toolCompleted])]), projector: projector, journal: journal)
        #expect(try await journal.snapshot(ref: ref).sequence == final.sequence)
    }

    @Test func reasoningAndAttachmentLocationsNeverBecomeVisibleText() throws {
        let projector = ChatGPTEventProjector(ref: ref, vendorThreadId: "vendor-thread")
        var projection = baseline
        projection.control = .init(executionEpoch: "process", controlRevision: 1, state: "running", controlMode: "readOnly",
            currentTurnId: projector.identifier("turn", "vendor-turn"), allowedActions: ["history.read"])
        for type in ["reasoning", "hookPrompt", "functionCallOutput", "plan"] {
            let result = projector.project(event("item/started", ["turnId": .string("vendor-turn"), "item": item(type, text: "private")]), onto: projection)
            guard case .ignored = result else { Issue.record("private item escaped filter"); continue }
        }
        let user = AgentJSON.object(["id": .string("user"), "type": .string("userMessage"), "content": .array([
            .object(["type": .string("text"), "text": .string("看这张图")]),
            .object(["type": .string("localImage"), "path": .string("/private/user/picture.png")])
        ])])
        let result = projector.project(event("item/started", ["turnId": .string("vendor-turn"), "item": user]), onto: projection)
        guard case .mutations(let values) = result, case .message(let message) = values.first else { throw RemoteJournalError.invalidProjection }
        #expect(message.content.map(\.type) == ["text", "unsupported"])
        #expect(!String(decoding: try JSONEncoder().encode(message), as: UTF8.self).contains("/private"))
    }

    @Test func toolLifecyclePublishesOnlyExplicitVisibleFieldsAndSurvivesJournalRestart() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = try RemoteSessionJournal(databaseURL: url)
        let projector = ChatGPTEventProjector(ref: ref, vendorThreadId: "vendor-thread")
        let initial = try await journal.replace(ref: ref, projection: baseline)
        try await consume(event("turn/started", ["turn": turn("inProgress")]), projector: projector, journal: journal)
        let secret = "/private/keys/token.txt --secret=do-not-export"
        let started = AgentJSON.object(["type": .string("commandExecution"), "id": .string("tool-1"),
                                        "status": .string("inProgress"), "command": .string("npm run typecheck"), "output": .string(secret), "arguments": .string(secret)])
        try await consume(event("item/started", ["turnId": .string("vendor-turn"), "item": started]), projector: projector, journal: journal)
        let prior = try #require(await journal.snapshot(ref: ref).projection.activities.first)
        await #expect(throws: RemoteJournalError.revisionConflict) {
            try await journal.append(ref: ref, mutation: .activity(.init(activityId: prior.activityId, turnId: prior.turnId,
                activityRevision: 3, kind: prior.kind, status: "completed", createdAt: prior.createdAt)))
        }
        let finished = AgentJSON.object(["type": .string("commandExecution"), "id": .string("tool-1"),
                                         "status": .string("completed"), "command": .string("npm run typecheck"), "output": .string(secret), "arguments": .string(secret)])
        try await consume(event("item/completed", ["turnId": .string("vendor-turn"), "item": finished]), projector: projector, journal: journal)
        let reopened = try RemoteSessionJournal(databaseURL: url)
        let snapshot = try await reopened.snapshot(ref: ref)
        #expect(snapshot.projection.activities.count == 1)
        #expect(snapshot.projection.activities.first?.kind == "command")
        #expect(snapshot.projection.activities.first?.status == "completed")
        #expect(snapshot.projection.activities.first?.activityRevision == 2)
        let wire = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        #expect(!wire.contains(secret) && !wire.contains("tool-1") && !wire.contains("vendor-turn"))
        let replay = try await reopened.replay(ref: ref, after: initial.eventCursor)
        #expect(replay.map(\.event.type) == ["session.updated", "activity.created", "activity.updated"])
        #expect(!String(decoding: try JSONEncoder().encode(replay), as: UTF8.self).contains(secret))
    }

    @Test func differentThreadsAreIsolatedAndMissingBaselinesRequireSync() {
        let projector = ChatGPTEventProjector(ref: ref, vendorThreadId: "vendor-thread")
        if case .ignored = projector.project(event("turn/started", ["turn": turn("inProgress")], thread: "other"), onto: baseline) {} else { Issue.record("wrong thread accepted") }
        if case .requiresSync("delta_without_baseline") = projector.project(event("item/agentMessage/delta", ["turnId": .string("vendor-turn"), "itemId": .string("missing"), "delta": .string("x")]), onto: baseline) {} else { Issue.record("missing baseline ignored") }
        let request = AgentRPCEvent.request(id: .integer(1), method: "item/commandExecution/requestApproval", params: .object(["threadId": .string("vendor-thread")]))
        if case .requiresSync = projector.project(request, onto: baseline) {} else { Issue.record("unsupported approval became actionable") }
        if case .requiresSync = projector.project(event("future/notification", [:]), onto: baseline) {} else { Issue.record("future event silently lost") }
    }

    @Test func oneUpstreamEventBatchRollsBackAllEarlierMutationsOnConflict() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = try RemoteSessionJournal(databaseURL: url)
        let initial = try await journal.replace(ref: ref, projection: baseline)
        let message = RemoteHistoryMessage(messageId: "m", turnId: nil, messageRevision: 1, role: "assistant", createdAt: "2026-10-03T00:00:00Z", status: "streaming", content: [.init(partId: "text", type: "text", text: "first")])
        await #expect(throws: RemoteJournalError.revisionConflict) {
            try await journal.append(ref: ref, mutations: [.message(message), .delta(messageId: "m", partId: "text", revision: 3, text: "gap")])
        }
        let current = try await journal.snapshot(ref: ref)
        #expect(current.sequence == 0 && current.eventCursor == initial.eventCursor && current.projection.messages.isEmpty)
    }
}
