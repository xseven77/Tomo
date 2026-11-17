import Foundation
import Testing
@testable import Tomo

struct RemoteSessionJournalTests {
    private let ref = RemoteSessionRef(serverId: "desktop", agentId: "agent.chatgpt", runtimeId: "work", sessionId: "session")
    private var control: RemoteSessionControl {
        .init(executionEpoch: "executor", controlRevision: 1, state: "running", controlMode: "readOnly", currentTurnId: "turn", allowedActions: ["history.read"])
    }
    private func message(revision: Int = 1, text: String = "", status: String = "streaming") -> RemoteHistoryMessage {
        .init(messageId: "message", turnId: "turn", messageRevision: revision, role: "assistant", createdAt: "2026-10-03T00:00:00.001Z", status: status,
              content: [.init(partId: "text", type: "text", text: text)])
    }
    private var projection: RemoteSessionProjection {
        .init(control: control, messages: [message()], pendingRequests: [], olderHistoryCursor: nil, hasOlder: false)
    }
    private func location() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tomo-journal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("events.sqlite")
    }

    @Test func legacyStoredProjectionWithoutActivitiesDecodesAsEmpty() throws {
        let old = """
        {"control":{"executionEpoch":"executor","controlRevision":1,"state":"running","controlMode":"readOnly","currentTurnId":"turn","allowedActions":["history.read"]},"messages":[],"pendingRequests":[],"olderHistoryCursor":null,"hasOlder":false}
        """
        let decoded = try JSONDecoder().decode(RemoteSessionProjection.self, from: Data(old.utf8))
        #expect(decoded.activities.isEmpty)
        #expect(decoded.control.currentTurnId == "turn")
    }

    @Test func snapshotReplayAndRestartShareExactlyCommittedPosition() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = try RemoteSessionJournal(databaseURL: url)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let first = try await journal.replace(ref: ref, projection: projection)
        let delta = try #require(await journal.append(ref: ref, mutation: .delta(messageId: "message", partId: "text", revision: 2, text: "你好")))
        let complete = try #require(await journal.append(ref: ref, mutation: .message(message(revision: 3, text: "你好 🌿", status: "completed"))))
        let restarted = try RemoteSessionJournal(databaseURL: url)
        let snapshot = try await restarted.snapshot(ref: ref)
        #expect(snapshot.sequence == 2)
        #expect(snapshot.streamEpoch == first.streamEpoch)
        #expect(snapshot.eventCursor == complete.cursor)
        #expect(snapshot.projection.messages == [message(revision: 3, text: "你好 🌿", status: "completed")])
        let replay = try await restarted.replay(ref: ref, after: first.eventCursor)
        #expect(replay == [delta, complete])
        #expect(try await restarted.replay(ref: ref, after: delta.cursor) == [complete])
        #expect(try await restarted.replay(ref: ref, after: snapshot.eventCursor).isEmpty)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        #expect(json["olderHistoryCursor"] is NSNull)
        #expect(json["currentTurnId"] as? String == "turn")
        #expect(json["controlRevision"] as? Int == 1)
    }

    @Test func invalidMutationAndPayloadOverflowRollBackProjectionAndLog() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = try RemoteSessionJournal(databaseURL: url, limits: .init(replayCount: 10, replayBytes: 2000, replayAge: 300, eventBytes: 1000, projectionBytes: 4000))
        let baseline = try await journal.replace(ref: ref, projection: projection)
        await #expect(throws: RemoteJournalError.revisionConflict) {
            try await journal.append(ref: ref, mutation: .delta(messageId: "message", partId: "text", revision: 3, text: "gap"))
        }
        await #expect(throws: RemoteJournalError.limitExceeded) {
            try await journal.append(ref: ref, mutation: .delta(messageId: "message", partId: "text", revision: 2, text: String(repeating: "a", count: 3000)))
        }
        let result = try await journal.snapshot(ref: ref)
        #expect(result.sequence == 0 && result.eventCursor == baseline.eventCursor)
        #expect(result.projection == projection)
        #expect(try await journal.replay(ref: ref, after: baseline.eventCursor).isEmpty)
        #expect(try await journal.append(ref: ref, mutation: .message(message())) == nil)
    }

    @Test func countTimeAndEpochExpirationNeverReturnIncompleteReplay() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = try RemoteSessionJournal(databaseURL: url, limits: .init(replayCount: 2, replayBytes: 200000, replayAge: 30, eventBytes: 10000, projectionBytes: 20000))
        let now = Date()
        let baseline = try await journal.replace(ref: ref, projection: projection, now: now)
        let first = try #require(await journal.append(ref: ref, mutation: .delta(messageId: "message", partId: "text", revision: 2, text: "1"), now: now))
        _ = try await journal.append(ref: ref, mutation: .delta(messageId: "message", partId: "text", revision: 3, text: "2"), now: now)
        await #expect(throws: RemoteJournalError.cursorExpired) { try await journal.replay(ref: ref, after: baseline.eventCursor, now: now) }
        #expect(try await journal.replay(ref: ref, after: first.cursor, now: now).count == 1)
        await #expect(throws: RemoteJournalError.cursorExpired) { try await journal.replay(ref: ref, after: first.cursor, now: now.addingTimeInterval(31)) }
        let head = try await journal.snapshot(ref: ref)
        #expect(try await journal.replay(ref: ref, after: head.eventCursor, now: now.addingTimeInterval(31)).isEmpty)
        let rebuilt = try await journal.replace(ref: ref, projection: projection, now: now)
        #expect(rebuilt.streamEpoch != head.streamEpoch)
        await #expect(throws: RemoteJournalError.cursorExpired) { try await journal.replay(ref: ref, after: head.eventCursor, now: now) }
    }

    @Test func fullSourceTupleSeparatesStreamsAndByteRetentionIsBounded() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = try RemoteSessionJournal(databaseURL: url, limits: .init(replayCount: 20, replayBytes: 900, replayAge: 300, eventBytes: 900, projectionBytes: 10000))
        let other = RemoteSessionRef(serverId: ref.serverId, agentId: ref.agentId, runtimeId: "personal", sessionId: ref.sessionId)
        let first = try await journal.replace(ref: ref, projection: projection)
        _ = try await journal.replace(ref: other, projection: projection)
        await #expect(throws: RemoteJournalError.cursorExpired) { try await journal.replay(ref: other, after: first.eventCursor) }
        for revision in 2...4 {
            _ = try await journal.append(ref: ref, mutation: .delta(messageId: "message", partId: "text", revision: revision, text: String(repeating: "a", count: 200)))
        }
        await #expect(throws: RemoteJournalError.cursorExpired) { try await journal.replay(ref: ref, after: first.eventCursor) }
        #expect(try await journal.snapshot(ref: other).sequence == 0)
    }

    @Test func approvalsAndExecutionChangeAreAtomicAndRevisionChecked() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = try RemoteSessionJournal(databaseURL: url)
        _ = try await journal.replace(ref: ref, projection: projection)
        let request = RemoteApprovalRequest(requestId: "approval", requestRevision: 1, type: "approval", executionEpoch: "executor", turnId: "turn",
                                           summary: "执行一个命令", allowedDecisions: ["accept", "decline"], expiresAt: "2026-10-04T00:00:00Z")
        _ = try await journal.append(ref: ref, mutation: .approval(request))
        #expect(try await journal.append(ref: ref, mutation: .approval(request)) == nil)
        await #expect(throws: RemoteJournalError.revisionConflict) { try await journal.append(ref: ref, mutation: .resolveApproval(requestId: "approval", expectedRevision: 0)) }
        #expect(try await journal.snapshot(ref: ref).projection.pendingRequests == [request])
        _ = try await journal.append(ref: ref, mutation: .resolveApproval(requestId: "approval", expectedRevision: 1))
        #expect(try await journal.snapshot(ref: ref).projection.pendingRequests.isEmpty)
        _ = try await journal.append(ref: ref, mutation: .approval(request))
        let changed = RemoteSessionControl(executionEpoch: "new-executor", controlRevision: 0, state: "unknown", controlMode: "unavailable", currentTurnId: nil, allowedActions: [])
        _ = try await journal.append(ref: ref, mutation: .control(changed))
        let snapshot = try await journal.snapshot(ref: ref)
        #expect(snapshot.projection.pendingRequests.isEmpty)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        #expect(json["currentTurnId"] is NSNull)
    }

    @Test func independentInstancesSerializeCompetingRevisionAndRejectPrivateRoles() async throws {
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try RemoteSessionJournal(databaseURL: url), second = try RemoteSessionJournal(databaseURL: url)
        _ = try await first.replace(ref: ref, projection: projection)
        let mutation = RemoteJournalMutation.delta(messageId: "message", partId: "text", revision: 2, text: "one")
        let results = await withTaskGroup(of: Bool.self) { group in
            group.addTask { do { _ = try await first.append(ref: ref, mutation: mutation); return true } catch { return false } }
            group.addTask { do { _ = try await second.append(ref: ref, mutation: mutation); return true } catch { return false } }
            var success = 0; for await value in group { if value { success += 1 } }; return success
        }
        #expect(results == 1)
        #expect(try await second.snapshot(ref: ref).sequence == 1)
        let privateMessage = RemoteHistoryMessage(messageId: "system", turnId: nil, messageRevision: 1, role: "system", createdAt: "2026-10-03T00:00:00Z", status: "completed", content: [])
        await #expect(throws: RemoteJournalError.invalidProjection) { try await second.append(ref: ref, mutation: .message(privateMessage)) }
        #expect(try await first.snapshot(ref: ref).sequence == 1)
    }
}
