import Foundation
import SQLite3

/// 读取 Cline 的 SQLite 存储（~/.cline/data/db/sessions.db 与 tasks.db），
/// 将活跃会话与任务映射成 Codex 活动快照。
///
/// Cline 在 macOS 桌面端和 VS Code/Cursor 插件环境下，通常将全局状态和任务记录在
/// `~/.cline/data/db/sessions.db` 以及 `~/.cline/data/db/tasks.db` 中。
/// 当 sessions 表中存在未结束的会话，或者 tasks 表中有进行中的任务时，
/// 提取最近活跃任务并映射为对应状态（thinking, executing, waitingForUser 等）。
struct ClineActivityService: Sendable {
    let clineDataURL: URL

    init(
        clineDataURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cline/data", isDirectory: true)
    ) {
        self.clineDataURL = clineDataURL
    }

    var sessionsDBURL: URL {
        clineDataURL.appendingPathComponent("db/sessions.db")
    }

    var tasksDBURL: URL {
        clineDataURL.appendingPathComponent("db/tasks.db")
    }

    /// 最近多久内有活动才算进行中任务（秒）
    static let activeWindow: TimeInterval = 180

    func loadSnapshot(now: Date = Date()) -> CodexActivitySnapshot {
        guard FileManager.default.fileExists(atPath: sessionsDBURL.path)
                || FileManager.default.fileExists(atPath: tasksDBURL.path) else {
            return .unavailable
        }

        let sessions = loadActiveSessions(now: now)
        let tasksFromAgenda = loadActiveAgendaTasks(now: now)

        var combinedTasks: [CodexTaskActivity] = []

        for session in sessions {
            combinedTasks.append(
                CodexTaskActivity(
                    id: "cline:\(session.id)",
                    state: session.state,
                    detail: session.state.taskLabel,
                    title: session.title,
                    updatedAt: session.lastActivity,
                    workspaceName: session.workspaceName,
                    gitBranch: nil,
                    model: session.model ?? "Cline"
                )
            )
        }

        for task in tasksFromAgenda {
            // 如果已有相同 session_id 的任务，避免重复
            if let originSession = task.sessionID, combinedTasks.contains(where: { $0.id == "cline:\(originSession)" }) {
                continue
            }
            combinedTasks.append(
                CodexTaskActivity(
                    id: "cline:task:\(task.id)",
                    state: task.state,
                    detail: task.state.taskLabel,
                    title: task.title,
                    updatedAt: task.lastActivity,
                    workspaceName: task.workspaceName,
                    gitBranch: nil,
                    model: "Cline"
                )
            )
        }

        guard !combinedTasks.isEmpty else {
            return CodexActivitySnapshot(
                state: .idle,
                detail: "Cline 当前空闲",
                threadTitle: nil,
                activeTaskCount: 0,
                updatedAt: now
            )
        }

        let selected = combinedTasks.max { lhs, rhs in
            if lhs.state.arbitrationPriority == rhs.state.arbitrationPriority {
                return lhs.updatedAt < rhs.updatedAt
            }
            return lhs.state.arbitrationPriority < rhs.state.arbitrationPriority
        }!

        return CodexActivitySnapshot(
            state: selected.state,
            detail: selected.detail,
            threadTitle: selected.title,
            activeTaskCount: combinedTasks.count,
            updatedAt: selected.updatedAt,
            activeTasks: combinedTasks
        )
    }

    func countTodaySessions(now: Date = Date(), calendar: Calendar = .current) -> Int {
        guard FileManager.default.fileExists(atPath: sessionsDBURL.path) else { return 0 }
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            sessionsDBURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            return 0
        }
        defer { sqlite3_close(database) }

        let startOfDay = calendar.startOfDay(for: now)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let startIso = formatter.string(from: startOfDay)

        let sql = """
        SELECT COUNT(*)
        FROM sessions
        WHERE started_at >= ? OR updated_at >= ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return 0
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (startIso as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (startIso as NSString).utf8String, -1, nil)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    struct SessionInfo {
        let id: String
        let title: String
        let state: CodexActivityState
        let lastActivity: Date
        let workspaceName: String?
        let model: String?
    }

    struct AgendaTaskInfo {
        let id: String
        let sessionID: String?
        let title: String
        let state: CodexActivityState
        let lastActivity: Date
        let workspaceName: String?
    }

    func loadActiveSessions(now: Date = Date()) -> [SessionInfo] {
        guard FileManager.default.fileExists(atPath: sessionsDBURL.path) else { return [] }
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            sessionsDBURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            return []
        }
        defer { sqlite3_close(database) }

        let sql = """
        SELECT session_id, prompt, status, updated_at, cwd, model
        FROM sessions
        WHERE status IN ('running', 'pending', 'idle')
        ORDER BY updated_at DESC
        LIMIT 10
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var result: [SessionInfo] = []
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0) else { continue }
            let id = String(cString: idText)
            let prompt = sqliteString(statement, column: 1)?.nilIfEmpty ?? "Cline 会话"
            let status = sqliteString(statement, column: 2) ?? ""
            let updatedText = sqliteString(statement, column: 3) ?? ""
            let cwd = sqliteString(statement, column: 4)
            let model = sqliteString(statement, column: 5)?.nilIfEmpty

            let updatedDate = isoFormatter.date(from: updatedText) ?? ISO8601DateFormatter().date(from: updatedText) ?? .distantPast
            guard now.timeIntervalSince(updatedDate) < Self.activeWindow else { continue }

            let state: CodexActivityState
            switch status {
            case "running":
                state = .executing
            case "pending":
                state = .thinking
            default:
                continue
            }

            let workspaceName = cwd.map { URL(fileURLWithPath: $0).lastPathComponent }?.nilIfEmpty
            result.append(
                SessionInfo(
                    id: id,
                    title: prompt,
                    state: state,
                    lastActivity: updatedDate,
                    workspaceName: workspaceName,
                    model: model
                )
            )
        }
        return result
    }

    func loadActiveAgendaTasks(now: Date = Date()) -> [AgendaTaskInfo] {
        guard FileManager.default.fileExists(atPath: tasksDBURL.path) else { return [] }
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            tasksDBURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            return []
        }
        defer { sqlite3_close(database) }

        let sql = """
        SELECT task_id, title, status, updated_at, cwd, last_session_id
        FROM agenda_tasks
        WHERE status IN ('in_progress', 'pending_approval')
        ORDER BY updated_at DESC
        LIMIT 10
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var result: [AgendaTaskInfo] = []
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0) else { continue }
            let id = String(cString: idText)
            let title = sqliteString(statement, column: 1)?.nilIfEmpty ?? "Cline 任务"
            let status = sqliteString(statement, column: 2) ?? ""
            let updatedText = sqliteString(statement, column: 3) ?? ""
            let cwd = sqliteString(statement, column: 4)
            let sessionID = sqliteString(statement, column: 5)?.nilIfEmpty

            let updatedDate = isoFormatter.date(from: updatedText) ?? ISO8601DateFormatter().date(from: updatedText) ?? .distantPast
            guard now.timeIntervalSince(updatedDate) < Self.activeWindow else { continue }

            let state: CodexActivityState
            switch status {
            case "in_progress":
                state = .executing
            case "pending_approval":
                state = .waitingForUser
            default:
                continue
            }

            let workspaceName = cwd.map { URL(fileURLWithPath: $0).lastPathComponent }?.nilIfEmpty
            result.append(
                AgendaTaskInfo(
                    id: id,
                    sessionID: sessionID,
                    title: title,
                    state: state,
                    lastActivity: updatedDate,
                    workspaceName: workspaceName
                )
            )
        }
        return result
    }

    private func sqliteString(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard let statement, let pointer = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: pointer)
    }
}
