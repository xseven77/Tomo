import Foundation
import SQLite3

/// 读取 Hermes 的会话存储（~/.hermes/state.db，SQLite），把最近活跃的会话映射成
/// Codex 活动快照。Hermes 不提供明确的「当前状态」字段，这里用「未结束 + 最近有活动」
/// 判定进行中，并用最后一条消息的角色粗粒度推断状态。
struct HermesActivityService: Sendable {
    let databaseURL: URL

    init(
        databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/state.db")
    ) {
        self.databaseURL = databaseURL
    }

    /// 最近多久内有活动才算「进行中」。
    static let activeWindow: TimeInterval = 120

    func loadSnapshot(now: Date = Date()) -> CodexActivitySnapshot {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return .unavailable
        }
        let sessions = loadActiveSessions(now: now)
        guard !sessions.isEmpty else {
            return CodexActivitySnapshot(
                state: .idle,
                detail: "Hermes 当前空闲",
                threadTitle: nil,
                activeTaskCount: 0,
                updatedAt: now
            )
        }

        let tasks = sessions.map { session -> CodexTaskActivity in
            CodexTaskActivity(
                id: "hermes:\(session.id)",
                state: session.state,
                detail: session.state.taskLabel,
                title: session.title,
                updatedAt: session.lastActivity,
                workspaceName: session.workspaceName,
                gitBranch: session.gitBranch,
                model: "Hermes"
            )
        }
        let selected = sessions.max { lhs, rhs in lhs.lastActivity < rhs.lastActivity }!
        return CodexActivitySnapshot(
            state: selected.state,
            detail: selected.state.taskLabel,
            threadTitle: selected.title,
            activeTaskCount: tasks.count,
            updatedAt: selected.lastActivity,
            activeTasks: tasks
        )
    }

    func countTodaySessions(now: Date = Date(), calendar: Calendar = .current) -> Int {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return 0 }
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            return 0
        }
        defer { sqlite3_close(database) }

        let startOfDay = calendar.startOfDay(for: now).timeIntervalSince1970
        let sql = """
        SELECT COUNT(*)
        FROM sessions
        WHERE (last_activity_at >= ? OR started_at >= ?) AND archived = 0
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return 0
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, startOfDay)
        sqlite3_bind_double(statement, 2, startOfDay)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    struct Session {
        let id: String
        let title: String
        let state: CodexActivityState
        let lastActivity: Date
        let workspaceName: String?
        let gitBranch: String?
    }

    func loadActiveSessions(now: Date = Date()) -> [Session] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            return []
        }
        defer { sqlite3_close(database) }

        let sql = """
        SELECT id, title, last_activity_at, cwd, git_branch
        FROM sessions
        WHERE ended_at IS NULL AND archived = 0
        ORDER BY last_activity_at DESC
        LIMIT 12
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var sessions: [Session] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0) else { continue }
            let id = String(cString: idText)
            let title = sqliteString(statement, column: 1)?.nilIfEmpty ?? "Hermes 会话"
            let lastActivityEpoch = sqlite3_column_double(statement, 2)
            guard lastActivityEpoch > 0 else { continue }
            let lastActivity = Date(timeIntervalSince1970: lastActivityEpoch)
            // 太久没有活动 → 视为空闲，不展示为进行中任务。
            guard now.timeIntervalSince(lastActivity) < Self.activeWindow else { continue }

            let cwd = sqliteString(statement, column: 3)
            let workspaceName = cwd.map { URL(fileURLWithPath: $0).lastPathComponent }?.nilIfEmpty
            let branch = sqliteString(statement, column: 4)?.nilIfEmpty
            let last = lastMessage(for: id, database: database)
            let state = state(forLastMessage: last ?? LastMessage(role: nil, finishReason: nil, hasToolCalls: false))
            // 最后一条是「已回复完」(assistant stop) 或没有进行中的工作 → 不算进行中任务。
            guard state != .idle else { continue }
            sessions.append(Session(
                id: id,
                title: title,
                state: state,
                lastActivity: lastActivity,
                workspaceName: workspaceName,
                gitBranch: branch
            ))
        }
        return sessions
    }

    struct LastMessage {
        let role: String?
        let finishReason: String?
        let hasToolCalls: Bool
    }

    private func lastMessage(for sessionID: String, database: OpaquePointer) -> LastMessage? {
        let sql = """
        SELECT role, finish_reason, (tool_calls IS NOT NULL AND tool_calls != '')
        FROM messages WHERE session_id = ? ORDER BY rowid DESC LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        return sessionID.withCString { cString in
            sqlite3_bind_text(statement, 1, cString, -1, nil)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return LastMessage(
                role: sqliteString(statement, column: 0),
                finishReason: sqliteString(statement, column: 1),
                hasToolCalls: sqlite3_column_int(statement, 2) != 0
            )
        }
    }

    func state(forLastMessage message: LastMessage) -> CodexActivityState {
        switch message.role {
        case "user":
            return .thinking
        case "tool":
            return .executing
        case "assistant":
            // 请求工具调用 → 正在执行；stop / 流式中断 → 已回复完，等待用户。
            return (message.finishReason == "tool_calls" || message.hasToolCalls) ? .executing : .idle
        default:
            return .idle
        }
    }

    private func sqliteString(_ statement: OpaquePointer, column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
}
