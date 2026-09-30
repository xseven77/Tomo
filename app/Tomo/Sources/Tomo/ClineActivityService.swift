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
        SELECT session_id, prompt, status, updated_at, cwd, model, pid, messages_path
        FROM sessions
        ORDER BY updated_at DESC
        LIMIT 50
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
        let fallbackIsoFormatter = ISO8601DateFormatter()

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0) else { continue }
            let id = String(cString: idText)
            let prompt = sqliteString(statement, column: 1)
            let status = sqliteString(statement, column: 2) ?? ""
            let updatedText = sqliteString(statement, column: 3) ?? ""
            let cwd = sqliteString(statement, column: 4)
            let model = sqliteString(statement, column: 5)?.nilIfEmpty
            let pid = Int32(sqlite3_column_int(statement, 6))
            let messagesPath = sqliteString(statement, column: 7)?.nilIfEmpty

            // 1. 基准更新时间（sessions.db 的 updated_at）
            var latestDate = isoFormatter.date(from: updatedText) ?? fallbackIsoFormatter.date(from: updatedText) ?? .distantPast

            // 2. 检查进程存活
            let isProcessAlive = pid > 0 && kill(pid, 0) == 0

            // 3. 从 hub-events-*.db 查询该会话的最新活动事件
            let hubActivity = loadLatestHubActivity(sessionID: id)
            if let hubDate = hubActivity?.timestamp, hubDate > latestDate {
                latestDate = hubDate
            }

            // 4. 从 messages.json 获取文件 mtime
            let resolvedMessagesURL: URL?
            if let messagesPath {
                resolvedMessagesURL = URL(fileURLWithPath: messagesPath)
            } else {
                let defaultMessages = clineDataURL.appendingPathComponent("sessions/\(id)/\(id).messages.json")
                resolvedMessagesURL = FileManager.default.fileExists(atPath: defaultMessages.path) ? defaultMessages : nil
            }

            if let resolvedMessagesURL,
               let attrs = try? FileManager.default.attributesOfItem(atPath: resolvedMessagesURL.path),
               let fileDate = attrs[.modificationDate] as? Date,
               fileDate > latestDate {
                latestDate = fileDate
            }

            let timeSinceActivity = now.timeIntervalSince(latestDate)

            // 5. 检查 messages.json 中最后一条消息状态
            let lastMessageState = inspectLastMessageState(messagesURL: resolvedMessagesURL)

            // Hub lifecycle events are authoritative. The session row and the last
            // persisted assistant message can still describe the previous run.
            let hubIsCurrent = hubActivity.map {
                $0.timestamp >= (lastMessageState.timestamp ?? .distantPast)
                    && now.timeIntervalSince($0.timestamp) < Self.activeWindow
            } ?? false
            // A terminal event remains terminal after the freshness window.
            // Permit a newly updated running row to announce a later run.
            if let hubActivity, hubActivity.state == nil,
               hubActivity.timestamp >= (lastMessageState.timestamp ?? .distantPast) {
                let rowDate = isoFormatter.date(from: updatedText) ?? fallbackIsoFormatter.date(from: updatedText) ?? .distantPast
                if status != "running" || rowDate.timeIntervalSince(hubActivity.timestamp) < 1 { continue }
            }
            let state: CodexActivityState
            if hubIsCurrent, let hubActivity {
                guard let activeState = hubActivity.state else { continue }
                state = activeState
            } else {
                guard ["running", "pending", "idle"].contains(status) else { continue }
                if lastMessageState.isCompletedOrStopped && status != "running" { continue }
                guard timeSinceActivity < Self.activeWindow || (status == "running" && isProcessAlive) else { continue }
                if lastMessageState.isWaitingForUser {
                    state = .waitingForUser
                } else if lastMessageState.hasToolUse {
                    state = .executing
                } else {
                    state = .thinking
                }
            }

            // 6. 提取并清理任务标题
            let title = extractCleanTitle(
                dbPrompt: prompt,
                messagesURL: resolvedMessagesURL
            )

            let workspaceName = cwd.map { URL(fileURLWithPath: $0).lastPathComponent }?.nilIfEmpty
            result.append(
                SessionInfo(
                    id: id,
                    title: title,
                    state: state,
                    lastActivity: latestDate,
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
        let fallbackIsoFormatter = ISO8601DateFormatter()

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0) else { continue }
            let id = String(cString: idText)
            let title = sqliteString(statement, column: 1)?.nilIfEmpty ?? "Cline 任务"
            let status = sqliteString(statement, column: 2) ?? ""
            let updatedText = sqliteString(statement, column: 3) ?? ""
            let cwd = sqliteString(statement, column: 4)
            let sessionID = sqliteString(statement, column: 5)?.nilIfEmpty

            var updatedDate = isoFormatter.date(from: updatedText) ?? fallbackIsoFormatter.date(from: updatedText) ?? .distantPast

            // 如果关联了 sessionID，同样结合 hub-events 确认最新时间
            if let sessionID, let hubDate = loadLatestHubActivity(sessionID: sessionID)?.timestamp, hubDate > updatedDate {
                updatedDate = hubDate
            }

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
                    title: Self.sanitizeTaskTitle(title),
                    state: state,
                    lastActivity: updatedDate,
                    workspaceName: workspaceName
                )
            )
        }
        return result
    }
    // MARK: - Hub Events

    struct HubActivity {
        let event: String
        let timestamp: Date

        var state: CodexActivityState? {
            switch event {
            case "run.completed", "run.failed", "run.aborted", "agent.done": return nil
            case "tool.started", "tool.updated": return .executing
            case "approval.requested", "user_input.requested": return .waitingForUser
            default: return .thinking
            }
        }
    }

    private func loadLatestHubActivity(sessionID: String) -> HubActivity? {
        let dbDirectory = clineDataURL.appendingPathComponent("db")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dbDirectory.path) else {
            return nil
        }

        let hubDbFiles = files.filter { $0.hasPrefix("hub-events") && $0.hasSuffix(".db") }
        guard !hubDbFiles.isEmpty else { return nil }

        var latest: HubActivity?
        for file in hubDbFiles {
            let dbURL = dbDirectory.appendingPathComponent(file)
            var database: OpaquePointer?
            guard sqlite3_open_v2(
                dbURL.path,
                &database,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
                nil
            ) == SQLITE_OK, let database else {
                continue
            }
            defer { sqlite3_close(database) }

            let sql = """
            SELECT event, created_at
            FROM hub_events
            WHERE session_id = ?
              AND event IN ('run.started', 'run.completed', 'run.failed', 'run.aborted',
                            'agent.started', 'agent.done', 'iteration.started', 'iteration.finished',
                            'tool.started', 'tool.updated', 'tool.finished',
                            'approval.requested', 'user_input.requested')
            ORDER BY sequence DESC
            LIMIT 1
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                continue
            }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, (sessionID as NSString).utf8String, -1, nil)
            if sqlite3_step(statement) == SQLITE_ROW {
                if let eventText = sqlite3_column_text(statement, 0) {
                    let event = String(cString: eventText)
                    let createdAtMillis = sqlite3_column_int64(statement, 1)
                    let timestamp = Date(timeIntervalSince1970: Double(createdAtMillis) / 1000.0)
                    if latest == nil || timestamp > latest!.timestamp {
                        latest = HubActivity(event: event, timestamp: timestamp)
                    }
                }
            }
        }
        return latest
    }

    /// 检查该会话的最后一条消息是否表明任务已停止/完成（例如以纯文本结论回复、say == "completion_result" 或无需进一步执行）
    struct LastMessageState {
        let isCompletedOrStopped: Bool
        let hasToolUse: Bool
        let isWaitingForUser: Bool
        let timestamp: Date?
    }

    private func inspectLastMessageState(messagesURL: URL?) -> LastMessageState {
        guard let messagesURL,
              let data = try? Data(contentsOf: messagesURL),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let messages = (obj as? [String: Any])?["messages"] as? [[String: Any]] ?? obj as? [[String: Any]],
              let last = messages.last else {
            return LastMessageState(isCompletedOrStopped: false, hasToolUse: false, isWaitingForUser: false, timestamp: nil)
        }

        let role = last["role"] as? String ?? ""
        let say = last["say"] as? String
        let ask = last["ask"] as? String
        let ts = (last["ts"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000.0) }

        if say == "completion_result" {
            return LastMessageState(isCompletedOrStopped: true, hasToolUse: false, isWaitingForUser: false, timestamp: ts)
        }

        if ask == "followup" || ask == "command" || ask == "tool" {
            return LastMessageState(isCompletedOrStopped: false, hasToolUse: false, isWaitingForUser: true, timestamp: ts)
        }

        var hasToolUse = false
        var hasToolResult = false
        var hasText = false

        if let content = last["content"] as? [[String: Any]] {
            for part in content {
                let type = part["type"] as? String ?? ""
                if type == "tool_use" {
                    hasToolUse = true
                } else if type == "tool_result" {
                    hasToolResult = true
                } else if type == "text" {
                    hasText = true
                }
            }
        } else if last["content"] is String {
            hasText = true
        }

        // 如果 assistant 输出了纯文本总结/回复，并且没有紧随其后的未决 tool_use，且不是正在等待用户输入结果，
        // 则表明当前回合已经输出完毕并停止（进入等待用户新指令或已完成）
        let isAssistantTextOnly = (role == "assistant" && hasText && !hasToolUse && !hasToolResult)

        return LastMessageState(
            isCompletedOrStopped: isAssistantTextOnly,
            hasToolUse: hasToolUse,
            isWaitingForUser: false,
            timestamp: ts
        )
    }

    // MARK: - Title Sanitization & Extraction

    private func extractCleanTitle(dbPrompt: String?, messagesURL: URL?) -> String {
        // 1. 如果有 messages.json，提取最近一条真实用户输入
        if let messagesURL,
           let data = try? Data(contentsOf: messagesURL),
           let json = try? JSONSerialization.jsonObject(with: data),
           let messages = (json as? [String: Any])?["messages"] as? [[String: Any]] ?? json as? [[String: Any]] {
            for m in messages.reversed() {
                guard m["role"] as? String == "user" else { continue }
                let rawText: String
                if let contentStr = m["content"] as? String {
                    rawText = contentStr
                } else if let parts = m["content"] as? [[String: Any]] {
                    if parts.contains(where: { ($0["type"] as? String) == "tool_result" }) {
                        continue
                    }
                    rawText = parts.compactMap { part -> String? in
                        guard part["type"] as? String == "text" else { return nil }
                        return part["text"] as? String
                    }.joined(separator: " ")
                } else {
                    continue
                }

                let cleaned = Self.sanitizeTaskTitle(rawText)
                if !cleaned.isEmpty {
                    return cleaned
                }
            }
        }

        // 2. 回退到 sessions.db 中的 prompt
        if let dbPrompt, !dbPrompt.isEmpty {
            let cleaned = Self.sanitizeTaskTitle(dbPrompt)
            if !cleaned.isEmpty {
                return cleaned
            }
        }

        return "Cline 会话"
    }

    /// 清洗与格式化 Cline 的任务/用户提示文本
    static func sanitizeTaskTitle(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // 移除 <user_input ...> ... </user_input> 标签
        if let regex = try? NSRegularExpression(pattern: #"<user_input(?:\s+[^>]*)?>(.*?)</user_input>"#, options: [.dotMatchesLineSeparators]) {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
        }

        // 移除 <task> ... </task> 标签
        if let regex = try? NSRegularExpression(pattern: #"<task(?:\s+[^>]*)?>(.*?)</task>"#, options: [.dotMatchesLineSeparators]) {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
        }

        // 移除常见的包装/上下文注入标识（如 Context summary:、Goal 等 markdown 块）
        if text.hasPrefix("Context summary:") {
            if let goalRange = text.range(of: "## Goal\n") {
                let remainder = text[goalRange.upperBound...]
                let firstLine = remainder.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
                if !firstLine.isEmpty {
                    text = firstLine
                }
            }
        }

        // 移除多余的 XML 标签（如 <system_prompt>, <environment> 等）
        if let xmlRegex = try? NSRegularExpression(pattern: #"<[^>]+>"#, options: []) {
            text = xmlRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }

        // 仅保留首行非空文字
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let firstMeaningful = lines.first ?? ""
        var cleaned = firstMeaningful.trimmingCharacters(in: .whitespacesAndNewlines)

        // 去掉开头的 markdown 符号 (如 #, -, *, >)
        while cleaned.hasPrefix("#") || cleaned.hasPrefix("-") || cleaned.hasPrefix("*") || cleaned.hasPrefix(">") || cleaned.hasPrefix(" ") {
            cleaned.removeFirst()
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.count > 60 {
            let index = cleaned.index(cleaned.startIndex, offsetBy: 57)
            return String(cleaned[..<index]) + "..."
        }
        return cleaned.isEmpty ? "Cline 任务" : cleaned
    }


    private func sqliteString(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard let statement, let pointer = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: pointer)
    }
}
