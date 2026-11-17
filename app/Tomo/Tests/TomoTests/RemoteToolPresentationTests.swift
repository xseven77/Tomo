import Foundation
import Testing
@testable import Tomo

struct RemoteToolPresentationTests {
    let ref = RemoteSessionRef(serverId: "server", agentId: "agent.chatgpt", runtimeId: "runtime", sessionId: "tool-session")
    var projector: ChatGPTEventProjector { .init(ref: ref, vendorThreadId: "private-thread") }

    @Test func commandAndFileResultsUseOnlyExplicitVisibleFields() throws {
        let command: [String: AgentJSON] = ["command": .string("npm run typecheck"), "cwd": .string("/workspace/rn"),
            "aggregatedOutput": .string("<script>ignored()</script>\n检查通过 🐙"), "exitCode": .integer(0), "durationMs": .integer(42),
            "arguments": .string("private-arguments"), "processId": .string("private-process"), "output": .string("not-a-schema-field")]
        let result = try #require(projector.toolPresentation(command, type: "commandExecution"))
        #expect(result.valid && !result.truncated)
        #expect(result.blocks.map(\.text) == ["npm run typecheck", "/workspace/rn", "0", "42", "<script>ignored()</script>\n检查通过 🐙"])
        let wire = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(!wire.contains("private-") && !wire.contains("not-a-schema-field"))
        let file = try #require(projector.toolPresentation(["changes": .array([.object([
            "path": .string("src/old.ts"), "kind": .object(["type": .string("update"), "move_path": .string("src/new.ts")]),
            "diff": .string("-old\n+new")])])], type: "fileChange"))
        #expect(file.blocks.map(\.text) == ["src/old.ts", "update", "src/new.ts", "-old\n+new"])
    }

    @Test func mcpAndDynamicResultsExcludeArgumentsStructuredDataAndResourcePayloads() throws {
        for type in ["mcpToolCall", "dynamicToolCall"] {
            let content = AgentJSON.array([.object(["type": .string(type == "mcpToolCall" ? "text" : "inputText"), "text": .string("visible result")]),
                .object(["type": .string("image"), "data": .string("private-base64")]),
                .object(["type": .string("resource"), "resource": .object(["uri": .string("file:///private-resource")])])])
            let item: [String: AgentJSON] = ["tool": .string("lookup"), "server": .string("docs"), "arguments": .string("private-arguments"),
                "contentItems": content, "result": .object(["content": content, "structuredContent": .string("private-structure")])]
            let result = try #require(projector.toolPresentation(item, type: type))
            let wire = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
            #expect(wire.contains("visible result") && !wire.contains("private-"))
            #expect(result.blocks.filter { $0.label == "其他内容" }.count == 2)
        }
        #expect(projector.toolPresentation(["result": .string("private-image-bytes")], type: "imageGeneration") == nil)
        #expect(projector.toolPresentation(["prompt": .string("private-agent-prompt")], type: "collabAgentToolCall") == nil)
    }

    @Test func utf8AndEscapingBoundsMarkTruncationWithoutBreakingScalars() throws {
        for value in [String(repeating: "🐙中文", count: 10_000), String(repeating: "\u{1}\n\"", count: 10_000)] {
            let result = try #require(projector.toolPresentation(["command": .string("check"), "aggregatedOutput": .string(value)], type: "commandExecution"))
            #expect(result.valid && result.truncated)
            #expect(try JSONEncoder().encode(result).count <= 32 * 1024)
            #expect(!result.blocks.map(\.text).joined().contains("�"))
        }
    }

    @Test func resultRevisionsReplayPersistAndBoundTheRecentWindow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("tools.sqlite"), journal = try RemoteSessionJournal(databaseURL: url)
        let initial = try await journal.replace(ref: ref, projection: .init(control: .init(executionEpoch: "epoch", controlRevision: 0,
            state: "running", controlMode: "readOnly", currentTurnId: "turn", allowedActions: ["history.read"]),
            messages: [], pendingRequests: [], olderHistoryCursor: nil, hasOlder: false))
        for index in 0..<18 {
            let activity = RemoteToolActivity(activityId: "activity-\(index)", turnId: "turn", activityRevision: 1, kind: "command", status: "running",
                createdAt: "2026-10-12T01:00:00Z", presentation: .init(title: "执行命令", blocks: [.init(label: "命令", text: "check \(index)")], truncated: false))
            _ = try await journal.append(ref: ref, mutation: .activity(activity))
        }
        let result = RemoteToolPresentation(title: "执行命令", blocks: [.init(label: "输出", text: "检查通过")], truncated: false)
        _ = try await journal.append(ref: ref, mutation: .activity(.init(activityId: "activity-17", turnId: "turn", activityRevision: 2,
            kind: "command", status: "running", createdAt: "2026-10-12T01:00:00Z", presentation: result)))
        _ = try await journal.append(ref: ref, mutation: .activity(.init(activityId: "activity-17", turnId: "turn", activityRevision: 3,
            kind: "command", status: "completed", createdAt: "2026-10-12T01:00:00Z", presentation: result)))
        let reopened = try RemoteSessionJournal(databaseURL: url), final = try await reopened.snapshot(ref: ref)
        #expect(final.projection.activities.count == 18)
        #expect(final.projection.activities.compactMap(\.presentation).count == 16)
        #expect(final.projection.activities.last?.presentation == result)
        #expect(final.projection.activities.last?.activityRevision == 3)
        let replay = try await reopened.replay(ref: ref, after: initial.eventCursor)
        #expect(replay.count == 20 && replay.suffix(2).allSatisfy { $0.event.type == "activity.updated" })
        if let path = ProcessInfo.processInfo.environment["TOMO_TOOL_WIRE_FIXTURE"] {
            struct Export: Encodable {let ref: RemoteSessionRef; let initial: RemoteJournalSync; let final: RemoteJournalSync; let events: [RemoteJournalRecord]}
            try JSONEncoder().encode(Export(ref: ref, initial: initial, final: final, events: replay)).write(to: URL(fileURLWithPath: path))
        }
    }
}
