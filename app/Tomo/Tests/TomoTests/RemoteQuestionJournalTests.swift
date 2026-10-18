import Foundation
import Testing
@testable import Tomo

struct RemoteQuestionJournalTests {
    private let ref = RemoteSessionRef(serverId: "desktop", agentId: "agent.chatgpt", runtimeId: "work", sessionId: "session")
    private var control: RemoteSessionControl {
        .init(executionEpoch: "executor", controlRevision: 1, state: "running", controlMode: "live",
              currentTurnId: "turn", allowedActions: ["history.read"])
    }
    private var question: RemotePendingRequest {
        .init(requestId: "request", requestRevision: 1, type: "question", executionEpoch: "executor", turnId: "turn",
            summary: "请选择环境", expiresAt: "2026-10-11T00:15:00Z", questions: [
                .init(questionId: "q", header: "环境", prompt: "请选择目标环境", options: [
                    .init(optionId: "dev", label: "开发", description: "开发环境")], allowsFreeText: true, isSecret: false)])
    }
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tomo-question-" + UUID().uuidString).appendingPathComponent("events.sqlite")
    }
    @Test func questionSurvivesDurableReplayAndResolvesOnlyAtItsExactRevisionAndType() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = try RemoteSessionJournal(databaseURL: url)
        let baseline = try await journal.replace(ref: ref, projection: .init(control: control, messages: [], pendingRequests: [], olderHistoryCursor: nil, hasOlder: false))
        let created = try #require(await journal.append(ref: ref, mutation: .question(question)))
        #expect(created.event.type == "question.requested")
        #expect(try await journal.append(ref: ref, mutation: .question(question)) == nil)
        let reopened = try RemoteSessionJournal(databaseURL: url)
        #expect(try await reopened.snapshot(ref: ref).projection.pendingRequests == [question])
        #expect(try await reopened.replay(ref: ref, after: baseline.eventCursor) == [created])
        await #expect(throws: RemoteJournalError.revisionConflict) {
            try await journal.append(ref: ref, mutation: .resolveQuestion(requestId: "request", expectedRevision: 0))
        }
        await #expect(throws: RemoteJournalError.revisionConflict) {
            try await journal.append(ref: ref, mutation: .resolveApproval(requestId: "request", expectedRevision: 1))
        }
        #expect(try await journal.snapshot(ref: ref).sequence == 1)
        let resolved = try #require(await journal.append(ref: ref, mutation: .resolveQuestion(requestId: "request", expectedRevision: 1)))
        #expect(resolved.event.type == "question.resolved")
        #expect(resolved.event.payload == .object(["requestId": .string("request"), "requestRevision": .integer(2)]))
        #expect(try await reopened.snapshot(ref: ref).projection.pendingRequests.isEmpty)
        await #expect(throws: RemoteJournalError.revisionConflict) {
            try await journal.append(ref: ref, mutation: .resolveQuestion(requestId: "request", expectedRevision: 1))
        }
    }

    @Test func malformedQuestionsAndMutationTypeMismatchRollBackWithoutPublishing() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = try RemoteSessionJournal(databaseURL: url)
        _ = try await journal.replace(ref: ref, projection: .init(control: control, messages: [], pendingRequests: [], olderHistoryCursor: nil, hasOlder: false))
        let invalid = RemotePendingRequest(requestId: "invalid", requestRevision: 1, type: "question", executionEpoch: "executor",
            turnId: "turn", summary: "无可答内容", expiresAt: question.expiresAt, questions: [
                .init(questionId: "q", header: "", prompt: "问题", options: [], allowsFreeText: false, isSecret: false)])
        await #expect(throws: RemoteJournalError.invalidProjection) { try await journal.append(ref: ref, mutation: .question(invalid)) }
        await #expect(throws: RemoteJournalError.invalidProjection) { try await journal.append(ref: ref, mutation: .approval(question)) }
        let snapshot = try await journal.snapshot(ref: ref)
        #expect(snapshot.sequence == 0 && snapshot.projection.pendingRequests.isEmpty)
    }

    @Test func turnAndExecutionChangesWithdrawQuestionsAtomically() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = try RemoteSessionJournal(databaseURL: url)
        for next in [
            RemoteSessionControl(executionEpoch: "executor", controlRevision: 2, state: "completed", controlMode: "live", currentTurnId: nil, allowedActions: ["history.read"]),
            .init(executionEpoch: "replacement", controlRevision: 0, state: "unknown", controlMode: "unavailable", currentTurnId: nil, allowedActions: [])
        ] {
            _ = try await journal.replace(ref: ref, projection: .init(control: control, messages: [], pendingRequests: [question], olderHistoryCursor: nil, hasOlder: false))
            _ = try await journal.append(ref: ref, mutation: .control(next))
            let snapshot = try await journal.snapshot(ref: ref)
            #expect(snapshot.projection.pendingRequests.isEmpty && snapshot.projection.control == next)
        }
    }

    @Test func legacyApprovalDecodesWithoutNewQuestionFields() throws {
        let bytes = Data("""
        {"requestId":"old","requestRevision":1,"type":"approval","executionEpoch":"e","turnId":"t","summary":"命令","allowedDecisions":["accept","decline"],"expiresAt":"2026-10-11T00:15:00Z"}
        """.utf8)
        let legacy = try JSONDecoder().decode(RemotePendingRequest.self, from: bytes)
        #expect(legacy.validContent && legacy.questions.isEmpty && legacy.commandApproval == nil && legacy.isBlocking)
    }
}
