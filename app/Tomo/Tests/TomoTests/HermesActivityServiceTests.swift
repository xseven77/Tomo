import SQLite3
import XCTest
@testable import Tomo

final class HermesActivityServiceTests: XCTestCase {
    func testStateForLastMessage() {
        let service = HermesActivityService(databaseURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("unused.db"))
        func msg(_ role: String?, _ finish: String?, hasToolCalls: Bool = false) -> HermesActivityService.LastMessage {
            .init(role: role, finishReason: finish, hasToolCalls: hasToolCalls)
        }

        XCTAssertEqual(service.state(forLastMessage: msg("user", nil)), .thinking)
        XCTAssertEqual(service.state(forLastMessage: msg("tool", nil)), .executing)
        XCTAssertEqual(service.state(forLastMessage: msg("assistant", "tool_calls", hasToolCalls: true)), .executing)
        XCTAssertEqual(service.state(forLastMessage: msg("assistant", "stop")), .idle)
        XCTAssertEqual(service.state(forLastMessage: msg("assistant", nil)), .idle)
        XCTAssertEqual(service.state(forLastMessage: msg(nil, nil)), .idle)
    }

    func testLoadActiveSessionsFiltersRecencyAndIdleAndMapsState() throws {
        let now = Date()
        let url = try makeDatabase(rows: [
            Row(id: "recent-user", title: "Recent Task", lastActivity: now.addingTimeInterval(-10), role: "user"),
            Row(id: "recent-done", title: "Done Task", lastActivity: now.addingTimeInterval(-5), role: "assistant", finishReason: "stop"),
            Row(id: "recent-tool", title: "Tool Task", lastActivity: now.addingTimeInterval(-3), role: "assistant", finishReason: "tool_calls", hasToolCalls: true),
            Row(id: "stale", title: "Stale Task", lastActivity: now.addingTimeInterval(-99_999), role: "user"),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let service = HermesActivityService(databaseURL: url)
        let sessions = service.loadActiveSessions(now: now)

        // recent-done（assistant stop）应被当作空闲过滤掉；stale 按活跃窗口过滤。
        XCTAssertEqual(sessions.map(\.id), ["recent-tool", "recent-user"])
        XCTAssertEqual(sessions.first?.state, .executing)
        XCTAssertEqual(sessions.last?.state, .thinking)
        XCTAssertEqual(sessions.first?.title, "Tool Task")
    }

    func testSnapshotMergingConcatenatesTasksAndArbitratesState() {
        let now = Date()
        let codex = CodexActivitySnapshot(
            state: .executing,
            detail: "Codex 工作",
            threadTitle: "Codex 任务",
            activeTaskCount: 1,
            updatedAt: now,
            activeTasks: [
                CodexTaskActivity(id: "codex-1", state: .executing, detail: "执行中", title: "Codex · A", updatedAt: now)
            ],
            localAgentTasks: []
        )
        let dsh = CodexActivitySnapshot(
            state: .waitingForUser,
            detail: "Deepseek Harness 等待确认",
            threadTitle: "DSH 任务",
            activeTaskCount: 1,
            updatedAt: now.addingTimeInterval(5),
            activeTasks: [
                CodexTaskActivity(id: "dsh-1", state: .waitingForUser, detail: "等待确认", title: "Deepseek Harness · B", updatedAt: now.addingTimeInterval(5))
            ],
            localAgentTasks: []
        )
        let hermes = CodexActivitySnapshot(
            state: .idle,
            detail: "Hermes 空闲",
            threadTitle: nil,
            activeTaskCount: 0,
            updatedAt: now,
            activeTasks: [],
            localAgentTasks: []
        )

        let merged = CodexActivitySnapshot.merged([codex, dsh, hermes])

        XCTAssertEqual(merged.state, .waitingForUser)
        XCTAssertEqual(merged.threadTitle, "DSH 任务")
        XCTAssertEqual(merged.activeTaskCount, 2)
        XCTAssertEqual(Set(merged.activeTasks.map(\.title)), ["Codex · A", "Deepseek Harness · B"])
    }

    // MARK: - Helpers

    private struct Row {
        let id: String
        let title: String
        let lastActivity: Date
        let role: String
        var finishReason: String? = nil
        var hasToolCalls: Bool = false
    }

    private func makeDatabase(rows: [Row]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-test-\(UUID().uuidString).db")
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw TestError.openFailed
        }
        defer { sqlite3_close(database) }

        sqlite3_exec(
            database,
            "CREATE TABLE sessions (id TEXT PRIMARY KEY, title TEXT, ended_at REAL, archived INTEGER DEFAULT 0, last_activity_at REAL, cwd TEXT, git_branch TEXT)",
            nil, nil, nil
        )
        sqlite3_exec(
            database,
            "CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, role TEXT, finish_reason TEXT, tool_calls TEXT)",
            nil, nil, nil
        )

        for row in rows {
            sqlite3_exec(
                database,
                "INSERT INTO sessions (id, title, last_activity_at) VALUES ('\(row.id)', '\(row.title)', \(row.lastActivity.timeIntervalSince1970))",
                nil, nil, nil
            )
            let finishSQL = row.finishReason.map { "'\($0)'" } ?? "NULL"
            let toolCallsSQL = row.hasToolCalls ? "'[\"call\"]'" : "NULL"
            sqlite3_exec(
                database,
                "INSERT INTO messages (session_id, role, finish_reason, tool_calls) VALUES ('\(row.id)', '\(row.role)', \(finishSQL), \(toolCallsSQL))",
                nil, nil, nil
            )
        }
        return url
    }

    private enum TestError: Error {
        case openFailed
    }
}
