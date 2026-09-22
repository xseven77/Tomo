import Foundation
import XCTest
@testable import Tomo

final class AntigravityActivityServiceTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AntigravityTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    func testLoadActiveSessionsParsesTranscriptAndExtractsTitleAndState() throws {
        let convDir = tempDir.appendingPathComponent("conversations")
        let brainDir = tempDir.appendingPathComponent("brain")
        try FileManager.default.createDirectory(at: convDir, withIntermediateDirectories: true)

        let sessionID = "test-session-123"
        let dbURL = convDir.appendingPathComponent("\(sessionID).db")
        try "dummy db".write(to: dbURL, atomically: true, encoding: .utf8)

        let logDir = brainDir
            .appendingPathComponent(sessionID)
            .appendingPathComponent(".system_generated")
            .appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        let transcriptLines = [
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-08-24T12:00:00Z","content":"<USER_REQUEST>\n调研一下 Gemini 额度查询与 Antigravity 状态检测\n</USER_REQUEST>"}"#,
            #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-08-24T12:00:05Z","content":"好的","tool_calls":[{"name":"view_file","parameters":{"AbsolutePath":"/path/to/SKILL.md"}}]}"#
        ]
        let transcriptURL = logDir.appendingPathComponent("transcript.jsonl")
        try transcriptLines.joined(separator: "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        let service = AntigravityActivityService(
            antigravityRoot: tempDir
        )

        let sessions = service.loadActiveSessions(now: Date())
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, sessionID)
        XCTAssertEqual(sessions.first?.title, "调研一下 Gemini 额度查询与 Antigravity 状态检测")
        XCTAssertEqual(sessions.first?.state, .reviewing)
        XCTAssertTrue(sessions.first?.detail.contains("view_file") ?? false)
    }

    func testWaitingForUserStateDetection() throws {
        let convDir = tempDir.appendingPathComponent("conversations")
        let brainDir = tempDir.appendingPathComponent("brain")
        try FileManager.default.createDirectory(at: convDir, withIntermediateDirectories: true)

        let sessionID = "test-ask-question"
        let dbURL = convDir.appendingPathComponent("\(sessionID).db")
        try "dummy db".write(to: dbURL, atomically: true, encoding: .utf8)

        let logDir = brainDir
            .appendingPathComponent(sessionID)
            .appendingPathComponent(".system_generated")
            .appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        let transcriptLines = [
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-08-24T12:00:00Z","content":"修复此问题"}"#,
            #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-08-24T12:00:05Z","content":"请选择方案","tool_calls":[{"name":"ask_question","parameters":{"question":"选哪个？"}}]}"#
        ]
        let transcriptURL = logDir.appendingPathComponent("transcript.jsonl")
        try transcriptLines.joined(separator: "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        let service = AntigravityActivityService(
            antigravityRoot: tempDir
        )

        let sessions = service.loadActiveSessions(now: Date())
        XCTAssertEqual(sessions.first?.state, .waitingForUser)
        XCTAssertEqual(sessions.first?.detail, "等待用户确认操作")
    }
}
