import Foundation
import Testing
@testable import Tomo

struct RemoteWebSearchPresentationTests {
    private let ref = RemoteSessionRef(serverId: "server", agentId: "agent.chatgpt", runtimeId: "runtime", sessionId: "search-session")
    private var projector: ChatGPTEventProjector { .init(ref: ref, vendorThreadId: "private-thread") }
    private func item(_ action: AgentJSON, query: String = "") -> [String: AgentJSON] {
        ["type": .string("webSearch"), "id": .string("private-search"), "query": .string(query), "action": action]
    }

    @Test func queriesRetainOrderWithoutDuplicatesAndUnknownResultsRemainOpaque() throws {
        var value = item(.object(["type": .string("search"), "query": .string("Tomo RN"),
            "queries": .array([.string("Tomo RN"), .string("iOS 中文🐙"), .string(""), .string("iOS 中文🐙")]),
            "headers": .string("private-action-headers")]), query: "Tomo RN")
        value["results"] = .array([.object(["title": .string("private-opaque-title"),
            "url": .string("https://private.invalid/opaque"), "text": .string("private-opaque-body")])])
        let result = try #require(projector.toolPresentation(value, type: "webSearch"))
        #expect(result.title == "搜索网页" && result.truncated && result.valid)
        #expect(result.blocks.map(\.text) == ["Tomo RN", "iOS 中文🐙", "此版本暂不支持显示结构化搜索结果。"])
        let archive = try #require(projector.toolResultText(value, type: "webSearch"))
        #expect(archive.truncated && archive.text.contains("iOS 中文🐙"))
        #expect(!archive.text.contains("private-") && !archive.text.contains("opaque"))
    }

    @Test func pageActionsPreserveLiteralUrlAndPatternWithoutForwardingOtherFields() throws {
        let url = "https://example.org/guide/" + String(repeating: "long-path-", count: 12) + "?q=中文"
        let open = try #require(projector.toolPresentation(item(.object(["type": .string("openPage"),
            "url": .string(url), "text": .string("private-unvalidated-page") ])), type: "webSearch"))
        #expect(open.title == "打开网页" && open.blocks.map(\.text) == [url] && !open.truncated)
        let find = try #require(projector.toolPresentation(item(.object(["type": .string("findInPage"),
            "url": .string(url), "pattern": .string("<script>仅作为查找文本</script> 🐙"),
            "result": .string("private-unvalidated-result") ])), type: "webSearch"))
        #expect(find.title == "页内查找" && find.blocks.map(\.label) == ["网页", "查找内容"])
        #expect(find.blocks.map(\.text) == [url, "<script>仅作为查找文本</script> 🐙"])
        #expect(!String(decoding: try JSONEncoder().encode(find), as: UTF8.self).contains("private-"))
    }

    @Test func legacyNullMalformedAndUnknownActionsHaveAnExplicitSafeFallback() throws {
        let legacy = try #require(projector.toolPresentation(item(.null, query: "legacy query"), type: "webSearch"))
        #expect(legacy.blocks.map(\.text) == ["legacy query"] && !legacy.truncated)
        for (action, title) in [("search", "搜索网页"), ("openPage", "打开网页"), ("findInPage", "页内查找"), ("other", "网页操作")] {
            let sparse = try #require(projector.toolPresentation(item(.object(["type": .string(action)])), type: "webSearch"))
            #expect(sparse.title == title && !sparse.truncated && !sparse.blocks.isEmpty)
        }
        for action in [AgentJSON.string("private-malformed"), .object(["type": .string("futureAction"), "url": .string("private-url")])] {
            let value = try #require(projector.toolPresentation(item(action, query: "visible query"), type: "webSearch"))
            #expect(value.truncated && value.blocks.contains { $0.text == "此搜索操作暂不支持显示。" })
            #expect(!String(decoding: try JSONEncoder().encode(value), as: UTF8.self).contains("private-"))
        }
        let huge = String(repeating: "中文🐙", count: 6000) + "END-OF-PATTERN"
        let value = item(.object(["type": .string("findInPage"), "url": .string("https://example.org"), "pattern": .string(huge)]))
        let preview = try #require(projector.toolPresentation(value, type: "webSearch"))
        #expect(preview.valid && preview.truncated && !preview.blocks.map(\.text).joined().contains("END-OF-PATTERN"))
        let archive = try #require(projector.toolResultText(value, type: "webSearch"))
        #expect(!archive.truncated && archive.text.contains(huge))
    }

    @Test func finalSearchActionUpdatesTheSameActivityAndReplaysItsDurableReadOnlyResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("journal.sqlite"), journal = try RemoteSessionJournal(databaseURL: url)
        let initial = try await journal.replace(ref: ref, projection: .init(control: .init(executionEpoch: "epoch", controlRevision: 1,
            state: "running", controlMode: "readOnly", currentTurnId: projector.identifier("turn", "private-turn"), allowedActions: ["history.read"]),
            messages: [], pendingRequests: [], olderHistoryCursor: nil, hasOlder: false))
        let action = AgentJSON.object(["type": .string("findInPage"),
            "url": .string("https://example.org/guide/" + String(repeating: "long-path-", count: 12) + "?q=中文"),
            "pattern": .string("Tomo 会话 🐙\n<script>仅作为文本</script>")])
        for (method, value) in [("item/started", item(.null, query: "Tomo 会话")), ("item/completed", item(action, query: "Tomo 会话"))] {
            let current = try await journal.snapshot(ref: ref)
            let event = AgentRPCEvent.notification(method: method, params: .object([
                "threadId": .string("private-thread"), "turnId": .string("private-turn"), "item": .object(value)]))
            guard case .mutations(let mutations) = projector.project(event, onto: current.projection) else {
                Issue.record("Search lifecycle failed to project"); return
            }
            _ = try await journal.append(ref: ref, mutations: mutations)
        }
        let reopened = try RemoteSessionJournal(databaseURL: url), final = try await reopened.snapshot(ref: ref)
        let activity = try #require(final.projection.activities.first)
        #expect(final.projection.activities.count == 1 && activity.kind == "webSearch")
        #expect(activity.activityRevision == 2 && activity.status == "completed" && activity.presentation?.title == "页内查找")
        #expect(final.projection.control.allowedActions == ["history.read"])
        let page = try await reopened.toolResultPage(ref: ref, activityId: activity.activityId)
        #expect(page.text.contains("查找内容\nTomo 会话 🐙") && page.text.contains("<script>仅作为文本</script>"))
        let replay = try await reopened.replay(ref: ref, after: initial.eventCursor)
        #expect(replay.map(\.event.type) == ["activity.created", "activity.updated"])
        struct Export: Encodable { let ref: RemoteSessionRef; let initial: RemoteJournalSync; let final: RemoteJournalSync; let events: [RemoteJournalRecord]; let page: RemoteToolResultPage }
        let wire = try JSONEncoder().encode(Export(ref: ref, initial: initial, final: final, events: replay, page: page))
        #expect(!String(decoding: wire, as: UTF8.self).contains("private-"))
        if let path = ProcessInfo.processInfo.environment["TOMO_SEARCH_WIRE_FIXTURE"] {
            try wire.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
