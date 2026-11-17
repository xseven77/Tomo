import Foundation
import Testing
@testable import Tomo

struct RemoteToolResultArchiveTests {
    private actor ReadGate {
        let entered: AsyncStream<Void>
        let signal: AsyncStream<Void>.Continuation
        var calls = 0
        var resume: CheckedContinuation<Void, Never>?
        init() { let pair = AsyncStream<Void>.makeStream(); entered = pair.stream; signal = pair.continuation }
        func available() async -> Bool {
            calls += 1
            if calls == 2 {
                await withCheckedContinuation { continuation in resume = continuation; signal.yield(()) }
            }
            return true
        }
        func release() { resume?.resume(); resume = nil; signal.finish() }
    }
    private let ref = RemoteSessionRef(serverId: "server", agentId: "agent.chatgpt", runtimeId: "runtime", sessionId: "session")
    private var projector: ChatGPTEventProjector { .init(ref: ref, vendorThreadId: "private-thread") }
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("tool-results-" + UUID().uuidString) }
    private func projection() -> RemoteSessionProjection {
        .init(control: .init(executionEpoch: "epoch", controlRevision: 0, state: "running", controlMode: "readOnly",
            currentTurnId: projector.identifier("turn", "vendor-turn"), allowedActions: ["history.read"]),
            messages: [], pendingRequests: [], olderHistoryCursor: nil, hasOlder: false)
    }
    private func principal(id: UUID = UUID(), generation: UInt64 = 1, actions: Set<RemoteAction> = [.readHistory],
                           expires: Date = Date().addingTimeInterval(600),
                           pagingOwner: RemoteAccessStore.PagingOwner? = nil) -> RemoteAccessStore.Principal {
        .init(id: id, expiresAt: expires, scopes: [.init(agentId: ref.agentId, runtimeId: ref.runtimeId,
            sessionId: ref.sessionId, actions: actions)], origin: nil, generation: generation, pagingOwner: pagingOwner)
    }
    private func activity(_ id: String, status: String = "completed") -> RemoteToolActivity {
        .init(activityId: id, turnId: "turn", activityRevision: 1, kind: "command", status: status, createdAt: "2026-10-12T01:00:00Z")
    }
    private func complete(_ journal: RemoteSessionJournal, text: String) async throws -> String {
        let snapshot = try await journal.snapshot(ref: ref)
        let event = AgentRPCEvent.notification(method: "item/completed", params: .object([
            "threadId": .string("private-thread"), "turnId": .string("vendor-turn"), "item": .object([
                "id": .string("private-item"), "type": .string("commandExecution"), "status": .string("completed"),
                "command": .string("synthetic-check"), "cwd": .string("/synthetic"), "aggregatedOutput": .string(text),
                "exitCode": .integer(0), "processId": .string("private-process"), "arguments": .string("private-arguments")])]))
        guard case .mutations(let mutations) = projector.project(event, onto: snapshot.projection) else { throw RemoteJournalError.invalidProjection }
        _ = try await journal.append(ref: ref, mutations: mutations)
        return projector.identifier("activity", projector.identifier("turn", "vendor-turn"), "private-item")
    }
    private func page(_ service: RemoteSessionService, _ id: String, _ owner: RemoteAccessStore.Principal,
                      cursor: String? = nil, extra: [String: String] = [:]) async throws -> RemoteToolResultPage {
        var query = ["agent_id": ref.agentId, "runtime_id": ref.runtimeId]
        if let cursor { query["result_cursor"] = cursor }
        query.merge(extra) { _, value in value }
        let data = try await service.toolResult(sessionId: ref.sessionId, activityId: id, query: query, principal: owner)
        #expect(data.count < 64 * 1024)
        return try JSONDecoder().decode(RemoteToolResultPage.self, from: data)
    }

    @Test func longUnicodeAndLiteralHTMLRoundTripThroughDurablePagesWithoutGrowingSync() async throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("journal.sqlite"), journal = try RemoteSessionJournal(databaseURL: url)
        let initial = try await journal.replace(ref: ref, projection: projection())
        let output = String(repeating: "中文🐙<script>仅文本</script>\n\u{1}", count: 6000)
        let id = try await complete(journal, text: output)
        let reopened = try RemoteSessionJournal(databaseURL: url)
        let sync = try await reopened.snapshot(ref: ref)
        #expect(sync.projection.activities.last?.presentation?.truncated == true)
        #expect(sync.projection.toolResults.isEmpty)
        #expect(try JSONEncoder().encode(sync).count < 40 * 1024)
        #expect(try await reopened.replay(ref: ref, after: initial.eventCursor).count == 1)
        let service = RemoteSessionService(serverId: ref.serverId)
        _ = try await service.register(ref: ref, journal: reopened)
        let owner = principal()
        var cursor: String?, text = "", version: String?, count = 0
        repeat {
            let value = try await page(service, id, owner, cursor: cursor)
            #expect(value.utf8Offset == text.utf8.count && value.text.utf8.count <= 8192)
            #expect(!value.truncated && !value.text.contains("�"))
            if let version { #expect(value.resultVersion == version) } else { version = value.resultVersion }
            text += value.text; cursor = value.nextCursor; count += 1
            #expect(count < 100)
        } while cursor != nil
        #expect(count > 20)
        #expect(text == "执行命令\n\n命令\nsynthetic-check\n\n工作目录\n/synthetic\n\n退出码\n0\n\n输出（stdout / stderr 合并）\n" + output)
        #expect(!text.contains("private-"))
        await #expect(throws: RemoteJournalError.cursorExpired) { try await reopened.toolResultPage(ref: ref, activityId: id, offset: 1) }
        await #expect(throws: RemoteJournalError.invalidProjection) { try await reopened.toolResultPage(ref: ref, activityId: id, offset: Int.max) }
    }

    @Test func baselineImportsFullEarlierResultsOutsideTheSixteenPreviewWindow() async throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try RemoteSessionJournal(databaseURL: dir.appendingPathComponent("journal.sqlite"))
        let items = (0..<18).map { index in AgentJSON.object(["id": .string("item-\(index)"), "type": .string("commandExecution"),
            "command": .string("check-\(index)"), "status": .string("completed"), "aggregatedOutput": .string("result-\(index)")]) }
        let response = AgentJSON.object(["thread": .object(["id": .string("private-thread"), "createdAt": .integer(10), "updatedAt": .integer(20),
            "status": .object(["type": .string("idle")]), "turns": .array([.object(["id": .string("vendor-turn"),
                "status": .string("completed"), "items": .array(items), "itemsView": .string("full")])])])])
        let baseline = try projector.baseline(response: response, executionEpoch: "epoch")
        #expect(baseline.toolResults.count == 18 && baseline.activities.first?.presentation == nil)
        let wire = String(decoding: try JSONEncoder().encode(baseline), as: UTF8.self)
        #expect(!wire.contains("result-0") && !wire.contains("toolResults"))
        _ = try await journal.replace(ref: ref, projection: baseline)
        let id = try #require(baseline.activities.first?.activityId)
        #expect(try await journal.toolResultPage(ref: ref, activityId: id).text.contains("result-0"))
        _ = try await journal.replace(ref: ref, projection: projection())
        await #expect(throws: RemoteJournalError.notFound) { try await journal.toolResultPage(ref: ref, activityId: id) }
    }

    @Test func cursorBindsOwnerGenerationSourceActivityAndResultVersion() async throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try RemoteSessionJournal(databaseURL: dir.appendingPathComponent("journal.sqlite"))
        _ = try await journal.replace(ref: ref, projection: projection())
        let long = String(repeating: "x", count: 100_000)
        let id = try await complete(journal, text: long)
        let service = RemoteSessionService(serverId: ref.serverId)
        _ = try await service.register(ref: ref, journal: journal)
        let owner = principal(), first = try await page(service, id, owner)
        let cursor = try #require(first.nextCursor)
        let once = try await page(service, id, owner, cursor: cursor)
        #expect(try await page(service, id, owner, cursor: cursor).text == once.text)
        for (target, other) in [(id, principal()), (id, principal(id: owner.id, generation: 2)), ("other-activity", owner)] {
            await #expect(throws: RemoteReadError.cursorExpired) { try await page(service, target, other, cursor: cursor) }
        }
        await #expect(throws: RemoteReadError.cursorExpired) { try await page(service, id, owner, cursor: "forged") }
        // Change only the tail beyond the preview. It must invalidate pagination
        // even though no additional sync/SSE preview revision is necessary.
        _ = try await complete(journal, text: long + "new tail")
        await #expect(throws: RemoteJournalError.cursorExpired) { try await page(service, id, owner, cursor: cursor) }
        #expect(try await page(service, id, owner).resultVersion != first.resultVersion)
        let latest = try await page(service, id, owner)
        await service.unregister(sessionId: ref.sessionId)
        _ = try await service.register(ref: ref, journal: journal)
        await #expect(throws: RemoteReadError.cursorExpired) { try await page(service, id, owner, cursor: latest.nextCursor) }
    }

    @Test func sourceACLExpiryAndAvailabilityAreCheckedForEveryPage() async throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try RemoteSessionJournal(databaseURL: dir.appendingPathComponent("journal.sqlite"))
        _ = try await journal.replace(ref: ref, projection: projection())
        let id = try await complete(journal, text: String(repeating: "v", count: 30_000))
        let service = RemoteSessionService(serverId: ref.serverId)
        _ = try await service.register(ref: ref, journal: journal)
        let owner = principal(), first = try await page(service, id, owner)
        await #expect(throws: RemoteAccessError.forbidden) { try await page(service, id, principal(id: owner.id, actions: []), cursor: first.nextCursor) }
        await #expect(throws: RemoteAccessError.forbidden) { try await page(service, id, principal(expires: Date().addingTimeInterval(-1))) }
        await #expect(throws: RemoteAccessError.forbidden) { try await page(service, id, owner, extra: ["runtime_id": "foreign"]) }
        await #expect(throws: RemoteReadError.invalidRequest) { try await page(service, id, owner, extra: ["offset": "8192"]) }
        await service.unregister(sessionId: ref.sessionId)
        _ = try await service.register(ref: ref, journal: journal, available: { false })
        await #expect(throws: RemoteReadError.unavailable) { try await page(service, id, owner) }
    }

    @Test func renewedDeviceCredentialContinuesToolPagesButChangedPolicyCannot() async throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try RemoteSessionJournal(databaseURL: dir.appendingPathComponent("journal.sqlite"))
        _ = try await journal.replace(ref: ref, projection: projection())
        let id = try await complete(journal, text: String(repeating: "synthetic ", count: 3000))
        let service = RemoteSessionService(serverId: ref.serverId)
        _ = try await service.register(ref: ref, journal: journal)
        func owner(version: Int = 1) -> RemoteAccessStore.PagingOwner {
            .device(server: ref.serverId, user: "user", device: "phone", binding: "pairing", bindingRevision: 1,
                localVersion: version, key: "verified-key", scopes: [.init(agentId: ref.agentId,
                    runtimeId: ref.runtimeId, sessionId: ref.sessionId, actions: [.readHistory])])
        }
        let previous = principal(pagingOwner: owner()), renewed = principal(pagingOwner: owner())
        #expect(previous.id != renewed.id)
        let first = try await page(service, id, previous), cursor = try #require(first.nextCursor)
        let next = try await page(service, id, renewed, cursor: cursor)
        #expect(next.utf8Offset == first.text.utf8.count && !next.text.isEmpty)
        await #expect(throws: RemoteReadError.cursorExpired) {
            try await page(service, id, principal(pagingOwner: owner(version: 2)), cursor: cursor)
        }
        await #expect(throws: RemoteAccessError.forbidden) {
            try await page(service, id, principal(expires: Date().addingTimeInterval(-1), pagingOwner: owner()), cursor: cursor)
        }
    }

    @Test func pendingResultsCannotBypassReviewAndBatchFailureRollsBackArchive() async throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try RemoteSessionJournal(databaseURL: dir.appendingPathComponent("journal.sqlite"))
        let initial = try await journal.replace(ref: ref, projection: projection())
        let text = RemoteToolResultText(text: "visible only after completion", truncated: false)
        await #expect(throws: RemoteJournalError.invalidProjection) {
            try await journal.append(ref: ref, mutations: [.activity(activity("pending", status: "running")), .toolResult(activityId: "pending", result: text)])
        }
        await #expect(throws: RemoteJournalError.invalidProjection) {
            try await journal.append(ref: ref, mutations: [.activity(activity("finished")), .toolResult(activityId: "finished", result: text), .requireSync(reason: "")])
        }
        #expect(try await journal.snapshot(ref: ref).eventCursor == initial.eventCursor)
        await #expect(throws: RemoteJournalError.notFound) { try await journal.toolResultPage(ref: ref, activityId: "finished") }
        let fields: [String: AgentJSON] = ["id": .string("file"), "type": .string("fileChange"), "status": .string("inProgress"),
            "changes": .array([.object(["path": .string("private-pending-file"), "diff": .string("pending-diff")])])]
        guard case .mutations(let values) = projector.itemMutation(.object(fields), turnId: "turn", completed: false, projection: projection(), now: Date()) else {
            throw RemoteJournalError.invalidProjection
        }
        for value in values { if case .toolResult = value { Issue.record("Pending file result was archived") } }
    }

    @Test func sourceRemovedWhileFinalAvailabilityCheckIsSuspendedCannotReleaseText() async throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try RemoteSessionJournal(databaseURL: dir.appendingPathComponent("journal.sqlite"))
        _ = try await journal.replace(ref: ref, projection: projection())
        let id = try await complete(journal, text: "must not be released after source removal")
        let service = RemoteSessionService(serverId: ref.serverId), gate = ReadGate()
        _ = try await service.register(ref: ref, journal: journal, available: { await gate.available() })
        let owner = principal()
        let reading = Task { try await page(service, id, owner) }
        for await _ in gate.entered { break }
        await service.unregister(sessionId: ref.sessionId)
        await gate.release()
        await #expect(throws: RemoteReadError.unavailable) { try await reading.value }
    }

    @Test func archiveRecordCountIsBoundedEvenWithTinyResults() async throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try RemoteSessionJournal(databaseURL: dir.appendingPathComponent("journal.sqlite"), limits: .init(toolResultCount: 2))
        _ = try await journal.replace(ref: ref, projection: projection())
        for id in ["one", "two", "three"] {
            _ = try await journal.append(ref: ref, mutations: [.activity(activity(id)), .toolResult(activityId: id, result: .init(text: id, truncated: false))])
        }
        await #expect(throws: RemoteJournalError.notFound) { try await journal.toolResultPage(ref: ref, activityId: "one") }
        #expect(try await journal.toolResultPage(ref: ref, activityId: "two").text == "two")
    }

    @Test func fullTurnArchiveWritesDoNotReduceTheExistingPublicBatchCapacity() async throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try RemoteSessionJournal(databaseURL: dir.appendingPathComponent("journal.sqlite"))
        _ = try await journal.replace(ref: ref, projection: projection())
        let items = (0..<129).map { AgentJSON.object(["id": .string("tool-\($0)"), "type": .string("commandExecution"),
            "command": .string("check"), "status": .string("completed"), "aggregatedOutput": .string("result-\($0)")]) }
        let event = AgentRPCEvent.notification(method: "turn/completed", params: .object(["threadId": .string("private-thread"),
            "turn": .object(["id": .string("vendor-turn"), "status": .string("completed"), "items": .array(items)])]))
        guard case .mutations(let mutations) = projector.project(event, onto: projection()) else { throw RemoteJournalError.invalidProjection }
        #expect(mutations.count == 259)
        #expect(try await journal.append(ref: ref, mutations: mutations).count == 130)
        let snapshot = try await journal.snapshot(ref: ref)
        #expect(snapshot.projection.control.state == "completed" && snapshot.projection.activities.count == 129)
        #expect(try await journal.toolResultPage(ref: ref, activityId: #require(snapshot.projection.activities.first?.activityId)).text.hasSuffix("result-0"))
        await #expect(throws: RemoteJournalError.limitExceeded) {
            try await journal.append(ref: ref, mutations: Array(repeating: .requireSync(reason: "too-many"), count: 257))
        }
    }

    @Test func archiveRetentionIsIndependentOfReplayAndGlobalBytesAreBounded() async throws {
        let dir = root(); defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try RemoteSessionJournal(databaseURL: dir.appendingPathComponent("journal.sqlite"), limits: .init(toolResultBytes: 16 * 1024 * 1024))
        _ = try await journal.replace(ref: ref, projection: projection())
        let text = RemoteToolResultText(text: String(repeating: "x", count: 6 * 1024 * 1024), truncated: false)
        for id in ["one", "two", "three"] {
            _ = try await journal.append(ref: ref, mutations: [.activity(activity(id)), .toolResult(activityId: id, result: text)])
        }
        await #expect(throws: RemoteJournalError.notFound) { try await journal.toolResultPage(ref: ref, activityId: "one") }
        #expect(try await journal.toolResultPage(ref: ref, activityId: "two").totalUTF8Bytes == text.text.utf8.count)
        #expect(try await journal.toolResultPage(ref: ref, activityId: "three").totalUTF8Bytes == text.text.utf8.count)
    }

    @Test func oversizedTextMarksLossAndKeepsWholeUTF8Scalars() throws {
        let text = RemoteToolResultText(title: "结果", blocks: [.init(label: "输出", text: String(repeating: "🐙", count: 4_200_000))], truncated: false)
        #expect(text.valid && text.truncated && !text.text.contains("�"))
        #expect(text.text.utf8.count <= RemoteToolResultText.byteLimit)
        let projector = self.projector
        let result = try #require(projector.toolResultText(["command": .string("check"), "aggregatedOutput": .null], type: "commandExecution",
            previous: .init(title: "执行命令", blocks: [.init(label: RemoteToolPresentation.commandOutputLabel, text: "observed")], truncated: false)))
        #expect(result.truncated && result.text.hasSuffix("observed"))
    }
}
