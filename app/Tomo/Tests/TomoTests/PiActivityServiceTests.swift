import Foundation
import XCTest
@testable import Tomo

final class PiActivityServiceTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiActivityTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    func testLoadActiveSessionsParsesMetadataAndDerivesExecutingState() throws {
        let workspaceDir = tempDir.appendingPathComponent("--Users-test-project--")
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)

        let sessionID = "01a06632-f23b-7c62-81c3-02f789d6d1a2"
        let fileURL = workspaceDir.appendingPathComponent("2026-09-04T12-00-00-000Z_\(sessionID).jsonl")

        let lines = [
            #"{"type":"session","version":3,"id":"\#(sessionID)","timestamp":"2026-09-04T12:00:00.000Z","cwd":"/Users/test/project"}"#,
            #"{"type":"message","id":"msg-1","timestamp":"2026-09-04T12:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"请帮我优化代码性能"}]}}"#,
            #"{"type":"message","id":"msg-2","timestamp":"2026-09-04T12:00:05.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"call-1","name":"bash","arguments":{"command":"ls -la"}}]},"stopReason":"toolUse"}"#
        ]
        try lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)

        let service = PiActivityService(sessionsRoot: tempDir)
        let snapshot = service.loadSnapshot(now: Date())

        XCTAssertEqual(snapshot.state, .executing)
        XCTAssertEqual(snapshot.detail, "Pi 正在执行 bash")
        XCTAssertEqual(snapshot.threadTitle, "请帮我优化代码性能")
        XCTAssertEqual(snapshot.activeTaskCount, 1)

        let task = try XCTUnwrap(snapshot.activeTasks.first)
        XCTAssertEqual(task.id, "pi:\(sessionID)")
        XCTAssertEqual(task.workspaceName, "project")
        XCTAssertEqual(task.model, "Pi")
        XCTAssertEqual(task.agentDisplayName, "Pi")
    }

    func testIdleStateAfterTurnComplete() throws {
        let workspaceDir = tempDir.appendingPathComponent("--Users-test-workspace--")
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)

        let sessionID = "01a09999-f23b-7c62-81c3-02f789d6d1a2"
        let fileURL = workspaceDir.appendingPathComponent("2026-09-04T12-00-00-000Z_\(sessionID).jsonl")

        let now = Date()
        let nowISO = ISO8601DateFormatter().string(from: now)

        let lines = [
            #"{"type":"session","version":3,"id":"\#(sessionID)","timestamp":"\#(nowISO)","cwd":"/Users/test/workspace"}"#,
            #"{"type":"message","id":"msg-1","timestamp":"\#(nowISO)","message":{"role":"user","content":[{"type":"text","text":"重构完成了吗？"}]}}"#,
            #"{"type":"message","id":"msg-2","timestamp":"\#(nowISO)","message":{"role":"assistant","content":[{"type":"text","text":"已经全部重构完成，请查验。"}]},"stopReason":"stop"}"#
        ]
        try lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)

        let service = PiActivityService(sessionsRoot: tempDir)
        let sessions = service.loadActiveSessions(now: now)

        // 对话正常结束后，该 session 视为 idle，不会作为未完成的活跃任务推入列表
        XCTAssertEqual(sessions.count, 0)
    }

    func testThinkingStateAfterUserMessage() throws {
        let workspaceDir = tempDir.appendingPathComponent("--Users-test-workspace--")
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)

        let sessionID = "01a08888-f23b-7c62-81c3-02f789d6d1a2"
        let fileURL = workspaceDir.appendingPathComponent("2026-09-04T12-00-00-000Z_\(sessionID).jsonl")

        let now = Date()
        let nowISO = ISO8601DateFormatter().string(from: now)

        let lines = [
            #"{"type":"session","version":3,"id":"\#(sessionID)","timestamp":"\#(nowISO)","cwd":"/Users/test/workspace"}"#,
            #"{"type":"message","id":"msg-1","timestamp":"\#(nowISO)","message":{"role":"user","content":[{"type":"text","text":"如何设计状态机？"}]}}"#
        ]
        try lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)

        let service = PiActivityService(sessionsRoot: tempDir)
        let snapshot = service.loadSnapshot(now: now)

        XCTAssertEqual(snapshot.state, .thinking)
        XCTAssertEqual(snapshot.detail, "Pi 正在思考")
        XCTAssertEqual(snapshot.threadTitle, "如何设计状态机？")
    }

    func testCountTodaySessions() throws {
        let workspaceDir = tempDir.appendingPathComponent("--Users-test-workspace--")
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)

        let file1 = workspaceDir.appendingPathComponent("file1.jsonl")
        let file2 = workspaceDir.appendingPathComponent("file2.jsonl")
        let fileNonJSONL = workspaceDir.appendingPathComponent("ignore.txt")

        try "{}".write(to: file1, atomically: true, encoding: .utf8)
        try "{}".write(to: file2, atomically: true, encoding: .utf8)
        try "text".write(to: fileNonJSONL, atomically: true, encoding: .utf8)

        let service = PiActivityService(sessionsRoot: tempDir)
        let count = service.countTodaySessions(now: Date())
        XCTAssertEqual(count, 2)
    }
}
