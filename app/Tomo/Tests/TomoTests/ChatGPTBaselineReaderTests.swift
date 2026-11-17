import Foundation
import Testing
@testable import Tomo

private actor PagedHistoryRPC {
    var channel: AgentRPCChannel?
    var responses: [AgentJSON]
    var requests: [AgentJSON] = []
    var injectPageEvent = false
    init(_ responses: [AgentJSON]) { self.responses = responses }
    func configure(_ channel: AgentRPCChannel) { self.channel = channel }
    func setPageEvent(_ enabled: Bool) { injectPageEvent = enabled }
    func write(_ bytes: Data) async throws {
        let request = try JSONDecoder().decode(AgentJSON.self, from: bytes)
        requests.append(request)
        guard case .object(let fields) = request, let id = fields["id"], !responses.isEmpty else { throw AgentRPCError.invalidFrame }
        if injectPageEvent, fields["method"] == .string("thread/turns/list") {
            var event = try JSONEncoder().encode(AgentJSON.object(["method": .string("item/agentMessage/delta"),
                "params": .object(["threadId": .string("thread"), "turnId": .string("one"), "itemId": .string("answer"), "delta": .string("交错")])]))
            event.append(10); try await channel?.receive(event)
        }
        var reply = try JSONEncoder().encode(AgentJSON.object(["id": id, "result": responses.removeFirst()])); reply.append(10)
        try await channel?.receive(reply)
    }
}

struct ChatGPTBaselineReaderTests {
    private func metadata(mode: String = "paginated", updated: Int64 = 200) -> AgentJSON {
        .object(["thread": .object(["id": .string("thread"), "createdAt": .integer(100), "updatedAt": .integer(updated),
            "historyMode": .string(mode), "status": .object(["type": .string("idle")]), "turns": .array([])])])
    }
    private func turn(_ id: String, view: String = "full") -> AgentJSON {
        .object(["id": .string(id), "status": .string("completed"), "itemsView": .string(view), "items": .array([
            .object(["id": .string("user"), "type": .string("userMessage"), "content": .array([.object(["type": .string("text"), "text": .string("你好 " + id)])])]),
            .object(["id": .string("private"), "type": .string("reasoning"), "summary": .array([]), "content": .array([])]),
            .object(["id": .string("answer"), "type": .string("agentMessage"), "text": .string("回复 " + id)])])])
    }
    private func page(_ turns: [AgentJSON], next: AgentJSON = .null) -> AgentJSON {
        .object(["data": .array(turns), "nextCursor": next])
    }
    private func setup(_ responses: [AgentJSON]) async -> (ChatGPTBaselineReader, PagedHistoryRPC) {
        let rpc = PagedHistoryRPC(responses), channel = AgentRPCChannel(writer: {try await rpc.write($0)})
        await rpc.configure(channel)
        return (.init(channel: channel), rpc)
    }

    @Test func exhaustedPagesPreserveTurnOrderAndUseTheExistingContentFilter() async throws {
        let (reader, rpc) = await setup([metadata(), page([turn("one")], next: .string("private-page")), page([turn("two")]), metadata()])
        let response = try await reader.read(threadId: "thread")
        let projector = ChatGPTEventProjector(ref: .init(serverId: "server", agentId: "agent.chatgpt", runtimeId: "runtime", sessionId: "opaque"), vendorThreadId: "thread")
        let projection = try projector.baseline(response: response, executionEpoch: "process")
        #expect(projection.messages.map(\.role) == ["user", "assistant", "user", "assistant"])
        #expect(projection.messages.count == 4 && !projection.hasOlder)
        let requests = await rpc.requests
        guard case .object(let second) = requests[1], case .object(let params) = second["params"],
              case .object(let third) = requests[2], case .object(let next) = third["params"] else { throw AgentRPCError.invalidFrame }
        #expect(second["method"] == .string("thread/turns/list"))
        guard case .object(let first) = requests[0], case .object(let firstParams) = first["params"] else { throw AgentRPCError.invalidFrame }
        #expect(firstParams["includeTurns"] == .bool(false))
        #expect(params["itemsView"] == .string("full") && params["sortDirection"] == .string("asc"))
        #expect(next["cursor"] == .string("private-page"))
        #expect(!String(decoding: try JSONEncoder().encode(projection), as: UTF8.self).contains("private-page"))
        await reader.channel.close()
    }

    @Test func partialViewsDuplicateTurnsAndInvalidCursorsNeverProduceABaseline() async throws {
        let invalid: [[AgentJSON]] = [
            [metadata(), page([turn("one", view: "summary")])],
            [metadata(), page([turn("one"), turn("one")])],
            [metadata(), page([], next: .string("cursor"))],
            [metadata(), page([turn("one")], next: .integer(1))],
            [metadata(), page([turn("one")], next: .string("same")), page([turn("two")], next: .string("same"))]
        ]
        for responses in invalid {
            let (reader, _) = await setup(responses)
            await #expect(throws: ChatGPTBaselineError.incompleteHistory) {try await reader.read(threadId: "thread")}
            await reader.channel.close()
        }
    }

    @Test func changingMetadataInvalidatesTheTraversal() async throws {
        let (reader, _) = await setup([metadata(), page([turn("one")]), metadata(updated: 201)])
        await #expect(throws: ChatGPTEventPumpError.baselineChanged) {try await reader.read(threadId: "thread")}
        await reader.channel.close()
    }

    @Test func boundedTraversalRejectsTooManyTurnsAndPages() async throws {
        var responses = [metadata()]
        for index in 0..<21 {
            responses.append(page((0..<50).map { turn("\(index)-\($0)") }, next: .string("page-\(index)")))
        }
        let (reader, _) = await setup(responses)
        await #expect(throws: ChatGPTBaselineError.limitExceeded) {try await reader.read(threadId: "thread")}
        await reader.channel.close()
        let (manyPages, _) = await setup([metadata()] + (0..<100).map {page([turn("turn-\($0)")], next: .string("page-\($0)"))})
        await #expect(throws: ChatGPTBaselineError.limitExceeded) {try await manyPages.read(threadId: "thread")}
        await manyPages.channel.close()
    }

    @Test func legacyResponseDoesNotCallThePaginationAPI() async throws {
        let initial = metadata(mode: "legacy"), (reader, rpc) = await setup([initial, initial])
        #expect(try await reader.read(threadId: "thread") == initial)
        #expect(await rpc.requests.count == 2)
        await reader.channel.close()
    }

    @Test func paginatedHydrationUsesTheSameLiveEventBarrierBeforePublishing() async throws {
        for overlap in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer {try? FileManager.default.removeItem(at: root)}
            let (reader, rpc) = await setup([metadata(), page([turn("one")]), metadata()])
            await rpc.setPageEvent(overlap)
            let journal = try RemoteSessionJournal(databaseURL: root.appendingPathComponent("journal.sqlite"))
            let ref = RemoteSessionRef(serverId: "server", agentId: "agent.chatgpt", runtimeId: "runtime", sessionId: "opaque")
            let pump = ChatGPTRuntimeEventPump(serverId: "server", runtimeId: "runtime", channel: reader.channel, journal: journal)
            try await pump.start()
            if overlap {
                await #expect(throws: ChatGPTEventPumpError.baselineChanged) {try await pump.hydrate(ref: ref, vendorThreadId: "thread", executionEpoch: "process")}
                await #expect(throws: RemoteJournalError.notFound) {try await journal.snapshot(ref: ref)}
            } else {
                try await pump.hydrate(ref: ref, vendorThreadId: "thread", executionEpoch: "process")
                #expect(try await journal.snapshot(ref: ref).projection.messages.count == 2)
                #expect(await pump.status(vendorThreadId: "thread") == .active)
            }
            await pump.stop()
        }
    }
}
