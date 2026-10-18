import Foundation
import Testing
@testable import Tomo

private actor RPCWrites {
    var values: [[String: AgentJSON]] = []
    func write(_ data: Data) throws {
        guard case .object(let value) = try JSONDecoder().decode(AgentJSON.self, from: data) else { return }
        values.append(value)
    }
    func waitFor(_ count: Int) async throws -> [[String: AgentJSON]] {
        for _ in 0..<1000 {
            if values.count >= count { return values }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw AgentRPCError.timedOut
    }
}

struct AgentRPCChannelTests {
    private func frame(_ value: [String: AgentJSON]) throws -> Data {
        var bytes = try JSONEncoder().encode(AgentJSON.object(value)); bytes.append(10); return bytes
    }

    @Test func idleEventsFragmentedUnicodeAndApprovalsArePreserved() async throws {
        let writes = RPCWrites()
        let channel = AgentRPCChannel(writer: { try await writes.write($0) })
        var events = channel.events.makeAsyncIterator()
        let notification = try frame(["method": .string("item/agentMessage/delta"), "params": .string("你好 🌿")])
        for byte in notification { try await channel.receive(Data([byte])) }
        #expect(try await events.next() == .notification(method: "item/agentMessage/delta", params: .string("你好 🌿")))
        try await channel.receive(frame(["id": .integer(9223372036854775807), "method": .string("item/commandExecution/requestApproval")]))
        #expect(try await events.next() == .request(id: .integer(Int64.max), method: "item/commandExecution/requestApproval", params: .null))
        try await channel.reply(id: .integer(Int64.max), result: .object(["decision": .string("decline")]))
        let sent = try await writes.waitFor(1)
        #expect(sent[0]["id"] == .integer(Int64.max))
        await #expect(throws: AgentRPCError.unknownRequest) { try await channel.reply(id: .integer(Int64.max), result: .null) }
        await channel.close()
    }

    @Test func concurrentRepliesUseIDsAndDoNotConsumeNotifications() async throws {
        let writes = RPCWrites()
        let channel = AgentRPCChannel(writer: { try await writes.write($0) })
        let first = Task { try await channel.request(method: "thread/read") }
        let second = Task { try await channel.request(method: "thread/list") }
        let sent = try await writes.waitFor(2)
        for value in sent.reversed() {
            try await channel.receive(frame(["id": value["id"]!, "result": value["method"]!]))
        }
        #expect(try await first.value == .string("thread/read"))
        #expect(try await second.value == .string("thread/list"))
        try await channel.receive(frame(["method": .string("turn/completed"), "params": .null]))
        var events = channel.events.makeAsyncIterator()
        #expect(try await events.next() == .notification(method: "turn/completed", params: .null))
        await channel.close()
    }

    @Test func timeoutCancellationLateRepliesAndDisconnectResolveWaiters() async throws {
        let writes = RPCWrites()
        let channel = AgentRPCChannel(writer: { try await writes.write($0) })
        await #expect(throws: AgentRPCError.timedOut) { try await channel.request(method: "timeout", timeout: .milliseconds(5)) }
        let sent = try await writes.waitFor(1)
        try await channel.receive(frame(["id": sent[0]["id"]!, "result": .null]))
        let cancelled = Task { try await channel.request(method: "cancel") }
        _ = try await writes.waitFor(2)
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let disconnected = Task { try await channel.request(method: "disconnect") }
        _ = try await writes.waitFor(3)
        await channel.close()
        await #expect(throws: AgentRPCError.disconnected) { try await disconnected.value }
        await #expect(throws: AgentRPCError.disconnected) { try await channel.request(method: "after-close") }
    }

    @Test func overflowAndMalformedFramesFailClosed() async throws {
        let limited = AgentRPCChannel(frameLimit: 30, writer: { _ in })
        await #expect(throws: AgentRPCError.frameTooLarge) { try await limited.receive(Data(repeating: 65, count: 31)) }
        let events = AgentRPCChannel(eventLimit: 1, writer: { _ in })
        try await events.receive(frame(["method": .string("first")]))
        await #expect(throws: AgentRPCError.overloaded) { try await events.receive(frame(["method": .string("second")])) }
        for data in [Data([0xff, 10]), Data("{\"id\":true,\"result\":null}\n".utf8),
                     Data("{\"id\":1,\"result\":null,\"error\":{}}\n".utf8)] {
            let bad = AgentRPCChannel(writer: { _ in })
            await #expect(throws: AgentRPCError.invalidFrame) { try await bad.receive(data) }
        }
        let duplicate = AgentRPCChannel(writer: { _ in })
        let request = try frame(["id": .string("approval"), "method": .string("approve")])
        try await duplicate.receive(request)
        await #expect(throws: AgentRPCError.duplicateRequest) { try await duplicate.receive(request) }
    }

    @Test func vendorFailureAndWriteFailureAreReported() async throws {
        let writes = RPCWrites()
        let channel = AgentRPCChannel(writer: { try await writes.write($0) })
        let task = Task { try await channel.request(method: "thread/resume") }
        let sent = try await writes.waitFor(1)
        try await channel.receive(frame(["id": sent[0]["id"]!, "error": .object(["code": .integer(-32000), "message": .string("unavailable")])]))
        await #expect(throws: AgentRPCError.vendor(code: -32000, message: "unavailable")) { try await task.value }
        await channel.close()
        let failing = AgentRPCChannel(writer: { _ in throw AgentRPCError.disconnected })
        await #expect(throws: AgentRPCError.disconnected) { try await failing.request(method: "initialize") }
    }

    @Test func localCheckpointIsOrderedBoundedAndNeverWrittenToVendor() async throws {
        let channel = AgentRPCChannel(writer: { _ in Issue.record("local checkpoint escaped to vendor") })
        let id = UUID()
        try await channel.receive(frame(["method": .string("before")]))
        try await channel.checkpoint(id)
        try await channel.receive(frame(["method": .string("after")]))
        var events = channel.events.makeAsyncIterator()
        #expect(try await events.next() == .notification(method: "before", params: .null))
        #expect(try await events.next() == .checkpoint(id))
        #expect(try await events.next() == .notification(method: "after", params: .null))
        await channel.close()
        await #expect(throws: AgentRPCError.disconnected) { try await channel.checkpoint(UUID()) }
        let full = AgentRPCChannel(eventLimit: 1, writer: { _ in })
        try await full.receive(frame(["method": .string("buffered")]))
        await #expect(throws: AgentRPCError.overloaded) { try await full.checkpoint(UUID()) }
        await #expect(throws: AgentRPCError.overloaded) { try await full.request(method: "after-overflow") }
    }

    @Test func newUpstreamEventInvalidatesReplyPreflightWithoutConsumingTheCallback() async throws {
        let writes = RPCWrites(), channel = AgentRPCChannel(writer: { try await writes.write($0) })
        try await channel.receive(frame(["id": .integer(7), "method": .string("item/tool/requestUserInput"),
            "params": .object(["threadId": .string("thread")])]))
        let oldRevision = try await channel.checkpoint(UUID())
        try await channel.receive(frame(["method": .string("turn/completed"), "params": .object(["threadId": .string("thread")])]))
        await #expect(throws: AgentRPCError.staleRequest) {
            try await channel.reply(id: .integer(7), result: .null, expectedEventRevision: oldRevision)
        }
        #expect(await writes.values.isEmpty)
        let currentRevision = try await channel.checkpoint(UUID())
        #expect(currentRevision == oldRevision + 1)
        // The channel only supplies the atomic guard. Its owner must process the
        // checkpoint and revalidate the turn/request before using the revision.
        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do { try await channel.reply(id: .integer(7), result: .null, expectedEventRevision: currentRevision); return true }
                    catch { return false }
                }
            }
            var count = 0
            for await success in group { if success { count += 1 } }
            return count
        }
        let sentCount = await writes.values.count
        #expect(successes == 1 && sentCount == 1)
        await channel.close()
    }

    @Test func serverResolutionWithdrawsOnlyTheMatchingThreadAndRPCIdentity() async throws {
        let writes = RPCWrites(), channel = AgentRPCChannel(writer: { try await writes.write($0) })
        for id in [AgentJSON.integer(1), .string("1")] {
            try await channel.receive(frame(["id": id, "method": .string("item/tool/requestUserInput"),
                "params": .object(["threadId": .string("a")])]))
        }
        try await channel.receive(frame(["method": .string("serverRequest/resolved"),
            "params": .object(["threadId": .string("b"), "requestId": .integer(1)])]))
        try await channel.reply(id: .integer(1), result: .null)
        try await channel.receive(frame(["method": .string("serverRequest/resolved"),
            "params": .object(["threadId": .string("a"), "requestId": .string("1")])]))
        await #expect(throws: AgentRPCError.unknownRequest) { try await channel.reply(id: .string("1"), result: .null) }
        #expect(await writes.values.count == 1)
        await channel.close()
    }

    @Test func scopedRepliedIDsRemainReservedUntilUpstreamResolution() async throws {
        let bytes = try frame(["id": .integer(3), "method": .string("item/tool/requestUserInput"),
            "params": .object(["threadId": .string("thread")])])
        let premature = AgentRPCChannel(writer: { _ in })
        try await premature.receive(bytes)
        try await premature.reply(id: .integer(3), result: .null)
        await #expect(throws: AgentRPCError.duplicateRequest) { try await premature.receive(bytes) }

        let writes = RPCWrites(), channel = AgentRPCChannel(pendingLimit: 1, writer: { try await writes.write($0) })
        try await channel.receive(bytes)
        try await channel.reply(id: .integer(3), result: .null)
        await #expect(throws: AgentRPCError.unknownRequest) { try await channel.reply(id: .integer(3), result: .null) }
        try await channel.receive(frame(["method": .string("serverRequest/resolved"),
            "params": .object(["threadId": .string("thread"), "requestId": .integer(3)])]))
        try await channel.receive(bytes)
        let revision = try await channel.checkpoint(UUID())
        try await channel.reply(id: .integer(3), result: .object(["fresh": .bool(true)]), expectedEventRevision: revision)
        #expect(await writes.values.count == 2)
        await channel.close()
    }
}
