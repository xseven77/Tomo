import Foundation
import Testing
@testable import Tomo

struct RemoteCollabPresentationTests {
    private let ref = RemoteSessionRef(serverId: "server", agentId: "agent.chatgpt", runtimeId: "runtime", sessionId: "collab-session")
    private var projector: ChatGPTEventProjector { .init(ref: ref, vendorThreadId: "private-parent") }
    private func item(_ states: [String: AgentJSON], status: String = "completed") -> [String: AgentJSON] {
        ["type": .string("collabAgentToolCall"), "id": .string("private-call"), "tool": .string("wait"),
         "status": .string(status), "senderThreadId": .string("private-parent"),
         "receiverThreadIds": .array([.string("private-z"), .string("private-a"), .string("private-z")]),
         "prompt": .string("private-prompt"), "agentsStates": .object(states)]
    }

    @Test func orderedChildStatesAndResultsExcludePrivateRoutingAndPrompts() throws {
        let value = item([
            "private-a": .object(["status": .string("running"), "message": .null]),
            "private-z": .object(["status": .string("completed"), "message": .string("检查完成 🐙\n<script>只作为文本</script>"),
                                   "prompt": .string("private-nested-prompt")]),
        ])
        let result = try #require(projector.toolPresentation(value, type: "collabAgentToolCall"))
        #expect(result.title == "子任务协作" && result.valid && !result.truncated)
        #expect(result.blocks.map(\.label) == ["操作", "子任务 1 · 已完成", "子任务 2 · 进行中"])
        #expect(result.blocks.map(\.text) == ["等待子任务", "检查完成 🐙\n<script>只作为文本</script>", "进行中"])
        let wire = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(!wire.contains("private-"))
        #expect(!wire.contains("agentsStates") && !wire.contains("receiverThreadIds"))
    }

    @Test func malformedStatesAndUnknownOperationsNeverSerializeOpaquePayloads() throws {
        var value = item(["private-z": .object(["status": .string("future-state"), "message": .string("private-unvalidated")]),
                          "private-a": .string("private-malformed")])
        let result = try #require(projector.toolPresentation(value, type: "collabAgentToolCall"))
        #expect(result.blocks.dropFirst().allSatisfy { $0.text == "状态暂不可用" })
        #expect(!String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("private-"))
        value["tool"] = .string("private-unknown-tool")
        #expect(projector.toolPresentation(value, type: "collabAgentToolCall") == nil)
        #expect(projector.toolPresentation(["prompt": .string("private-prompt")], type: "collabAgentToolCall") == nil)
    }

    @Test func longChildResultsUseExistingPreviewBoundsAndFullResultArchive() throws {
        let text = String(repeating: "中文🐙\n", count: 6000) + "END-OF-CHILD"
        let value = item(["private-z": .object(["status": .string("completed"), "message": .string(text)]),
                          "private-a": .object(["status": .string("errored"), "message": .string("需要重试")])])
        let preview = try #require(projector.toolPresentation(value, type: "collabAgentToolCall"))
        #expect(preview.valid && preview.truncated)
        #expect(!preview.blocks.map(\.text).joined().contains("END-OF-CHILD"))
        let archive = try #require(projector.toolResultText(value, type: "collabAgentToolCall"))
        #expect(archive.valid && !archive.truncated)
        #expect(archive.text.contains(text) && archive.text.contains("需要重试"))
        #expect(!archive.text.contains("private-"))
    }

    @Test func completedChildResultReplaysWithStableActivityAndPersistsAcrossRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("collab-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("journal.sqlite"), journal = try RemoteSessionJournal(databaseURL: url)
        let initial = try await journal.replace(ref: ref, projection: .init(control: .init(executionEpoch: "epoch", controlRevision: 1,
            state: "running", controlMode: "readOnly", currentTurnId: projector.identifier("turn", "private-turn"), allowedActions: ["history.read"]),
            messages: [], pendingRequests: [], olderHistoryCursor: nil, hasOlder: false))
        for (method, value) in [
            ("item/started", item(["private-z": .object(["status": .string("running")])], status: "inProgress")),
            ("item/completed", item(["private-z": .object(["status": .string("completed"), "message": .string("子任务已完成 🐙")])])),
        ] {
            let current = try await journal.snapshot(ref: ref)
            let event = AgentRPCEvent.notification(method: method, params: .object([
                "threadId": .string("private-parent"), "turnId": .string("private-turn"), "item": .object(value)]))
            guard case .mutations(let mutations) = projector.project(event, onto: current.projection) else {
                Issue.record("Collab lifecycle failed to project"); return
            }
            _ = try await journal.append(ref: ref, mutations: mutations)
        }
        let reopened = try RemoteSessionJournal(databaseURL: url), final = try await reopened.snapshot(ref: ref)
        let activity = try #require(final.projection.activities.first)
        #expect(final.projection.activities.count == 1 && activity.kind == "collabTool")
        #expect(activity.activityRevision == 2 && activity.status == "completed")
        #expect(final.projection.control.allowedActions == ["history.read"])
        let page = try await reopened.toolResultPage(ref: ref, activityId: activity.activityId)
        #expect(page.text.contains("子任务已完成 🐙"))
        let replay = try await reopened.replay(ref: ref, after: initial.eventCursor)
        #expect(replay.map(\.event.type) == ["activity.created", "activity.updated"])
        struct Export: Encodable { let ref: RemoteSessionRef; let initial: RemoteJournalSync; let final: RemoteJournalSync; let events: [RemoteJournalRecord]; let page: RemoteToolResultPage }
        let wire = try JSONEncoder().encode(Export(ref: ref, initial: initial, final: final, events: replay, page: page))
        #expect(!String(decoding: wire, as: UTF8.self).contains("private-"))
        if let path = ProcessInfo.processInfo.environment["TOMO_COLLAB_WIRE_FIXTURE"] {
            try wire.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
