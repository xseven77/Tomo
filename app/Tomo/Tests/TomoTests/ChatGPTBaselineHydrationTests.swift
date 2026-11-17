import Foundation
import Testing
@testable import Tomo

private actor BaselineRPCFixture {
    var channel: AgentRPCChannel?
    var overlap = false
    var held = false
    var requested = false
    func configure(_ channel: AgentRPCChannel, overlap: Bool = false, held: Bool = false) {
        self.channel = channel; self.overlap = overlap; self.held = held
    }
    func write(_ bytes: Data) async throws {
        guard case .object(let frame) = try JSONDecoder().decode(AgentJSON.self, from: bytes), let id = frame["id"] else { throw AgentRPCError.invalidFrame }
        #expect(frame["method"] == .string("thread/read"))
        #expect(frame["params"] == .object(["threadId": .string("thread"), "includeTurns": .bool(true)]) ||
                frame["params"] == .object(["threadId": .string("thread"), "includeTurns": .bool(false)]))
        requested = true
        if held { return }
        var frames: [AgentJSON] = []
        if overlap { frames.append(.object(["method": .string("item/agentMessage/delta"), "params": .object([
            "threadId": .string("thread"), "turnId": .string("turn"), "itemId": .string("item"), "delta": .string("重复风险")])])) }
        frames.append(.object(["id": id, "result": .object(["thread": .object([
            "id": .string("thread"), "createdAt": .integer(1), "updatedAt": .integer(100), "status": .object(["type": .string("active"), "activeFlags": .array([])]),
            "turns": .array([.object(["id": .string("turn"), "status": .string("inProgress"), "itemsView": .string("full"),
                "items": .array([.object(["id": .string("item"), "type": .string("agentMessage"), "text": .string("基线")])])])])])])]))
        var batch = Data()
        for frame in frames { batch.append(try JSONEncoder().encode(frame)); batch.append(10) }
        try await channel?.receive(batch)
    }
}

struct ChatGPTBaselineHydrationTests {
    private let ref = RemoteSessionRef(serverId: "server", agentId: "agent.chatgpt", runtimeId: "runtime", sessionId: "session")
    private func root() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true); return value
    }
    private func wait(_ condition: @escaping @Sendable () async throws -> Bool) async throws {
        for _ in 0..<400 { if try await condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw AgentRPCError.timedOut
    }

    @Test func quietRPCSnapshotBindsAndSubsequentDeltaUsesTheImportedItemIdentity() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let fixture = BaselineRPCFixture(), journal = try RemoteSessionJournal(databaseURL: root.appendingPathComponent("journal.sqlite"))
        let channel = AgentRPCChannel(writer: {try await fixture.write($0)})
        await fixture.configure(channel)
        let pump = ChatGPTRuntimeEventPump(serverId: "server", runtimeId: "runtime", channel: channel, journal: journal)
        try await pump.start()
        try await pump.hydrate(ref: ref, vendorThreadId: "thread", executionEpoch: "executor")
        #expect(await pump.status(vendorThreadId: "thread") == .active)
        var delta = try JSONEncoder().encode(AgentJSON.object(["method": .string("item/agentMessage/delta"), "params": .object([
            "threadId": .string("thread"), "turnId": .string("turn"), "itemId": .string("item"), "delta": .string("之后")])]))
        delta.append(10); try await channel.receive(delta)
        try await wait {try await journal.snapshot(ref: ref).sequence == 1}
        #expect(try await journal.snapshot(ref: ref).projection.messages.first?.content.first?.text == "基线之后")
        await pump.stop()
    }

    @Test func notificationAndResponseInOneTransportReadCannotDoubleApplyAnIncludedDelta() async throws {
        let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
        let fixture = BaselineRPCFixture(), journal = try RemoteSessionJournal(databaseURL: root.appendingPathComponent("journal.sqlite"))
        let channel = AgentRPCChannel(writer: {try await fixture.write($0)})
        await fixture.configure(channel, overlap: true)
        let pump = ChatGPTRuntimeEventPump(serverId: "server", runtimeId: "runtime", channel: channel, journal: journal)
        try await pump.start()
        await #expect(throws: ChatGPTEventPumpError.baselineChanged) { try await pump.hydrate(ref: ref, vendorThreadId: "thread", executionEpoch: "executor") }
        #expect(await pump.status(vendorThreadId: "thread") == .removed)
        await #expect(throws: RemoteJournalError.notFound) {try await journal.snapshot(ref: ref)}
        // Reservation is released after the failed attempt; explicit quiet retry succeeds.
        await fixture.configure(channel)
        try await pump.hydrate(ref: ref, vendorThreadId: "thread", executionEpoch: "executor")
        #expect(try await journal.snapshot(ref: ref).projection.messages.first?.content.first?.text == "基线")
        await pump.stop()
    }

    @Test func cancelAndStopDuringRPCReleaseReservationsWithoutPublishingAPartialBaseline() async throws {
        for cancel in [true, false] {
            let root = try root(); defer {try? FileManager.default.removeItem(at: root)}
            let fixture = BaselineRPCFixture(), journal = try RemoteSessionJournal(databaseURL: root.appendingPathComponent("journal.sqlite"))
            let channel = AgentRPCChannel(writer: {try await fixture.write($0)})
            await fixture.configure(channel, held: true)
            let pump = ChatGPTRuntimeEventPump(serverId: "server", runtimeId: "runtime", channel: channel, journal: journal)
            try await pump.start()
            let operation = Task { try await pump.hydrate(ref: ref, vendorThreadId: "thread", executionEpoch: "executor") }
            try await wait {await fixture.requested}
            if cancel { operation.cancel() } else { await pump.stop() }
            do {try await operation.value; Issue.record("cancelled baseline published")} catch {}
            #expect(await pump.status(vendorThreadId: "thread") == .removed)
            await #expect(throws: RemoteJournalError.notFound) {try await journal.snapshot(ref: ref)}
            await pump.stop()
        }
    }
}
