import Foundation

/// 读取 Google Antigravity 的会话日志与状态（~/.gemini/antigravity/），把活跃会话的
/// 事件流（transcript.jsonl）映射成 Codex 活动快照。
///
/// Antigravity 采用追加式 JSONL 记录 Agent 的每一个原子步骤，这里只读取首尾事件
/// 即可精准推断任务状态（思考中、执行中、检查中、等待确认、已完成等）。
struct AntigravityActivityService: Sendable {
    let antigravityRoot: URL

    init(
        antigravityRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity", isDirectory: true)
    ) {
        self.antigravityRoot = antigravityRoot
    }

    /// 判定一个 session 文件是否仍在活跃（最近 3 分钟内有过写入）。
    static let activeWindow: TimeInterval = 180

    func loadSnapshot(now: Date = Date()) -> CodexActivitySnapshot {
        guard FileManager.default.fileExists(atPath: antigravityRoot.path) else {
            return .unavailable
        }
        let sessions = loadActiveSessions(now: now)
        guard !sessions.isEmpty else {
            return CodexActivitySnapshot(
                state: .idle,
                detail: "Antigravity 当前空闲",
                threadTitle: nil,
                activeTaskCount: 0,
                updatedAt: now
            )
        }

        let tasks = sessions.map { session -> CodexTaskActivity in
            CodexTaskActivity(
                id: "antigravity:\(session.id)",
                state: session.state,
                detail: session.detail,
                title: session.title,
                updatedAt: session.lastActivity,
                workspaceName: session.workspaceName,
                gitBranch: nil,
                model: "Antigravity"
            )
        }

        // 优先级仲裁：优先展示等待确认、执行中、检查中、思考中的任务
        let selected = sessions.max { lhs, rhs in
            if lhs.state.arbitrationPriority == rhs.state.arbitrationPriority {
                return lhs.lastActivity < rhs.lastActivity
            }
            return lhs.state.arbitrationPriority < rhs.state.arbitrationPriority
        }!

        return CodexActivitySnapshot(
            state: selected.state,
            detail: selected.detail,
            threadTitle: selected.title,
            activeTaskCount: tasks.count,
            updatedAt: selected.lastActivity,
            activeTasks: tasks
        )
    }

    func countTodaySessions(now: Date = Date(), calendar: Calendar = .current) -> Int {
        let conversationsDir = antigravityRoot.appendingPathComponent("conversations", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: conversationsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        return files.filter { file in
            guard file.pathExtension == "db" else { return false }
            let mod = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return calendar.isDateInToday(mod)
        }.count
    }

    struct Session {
        let id: String
        let title: String
        let state: CodexActivityState
        let detail: String
        let lastActivity: Date
        let workspaceName: String?
    }

    struct StepEvent: Decodable {
        let stepIndex: Int?
        let source: String?
        let type: String?
        let status: String?
        let createdAt: String?
        let content: String?
        let toolCalls: [ToolCall]?

        struct ToolCall: Decodable {
            let name: String
            let toolAction: String?
            let toolSummary: String?
            let args: [String: AnyCodableValue]?

            enum CodingKeys: String, CodingKey {
                case name, toolAction, toolSummary, args
            }
        }

        enum CodingKeys: String, CodingKey {
            case stepIndex = "step_index"
            case source, type, status
            case createdAt = "created_at"
            case content
            case toolCalls = "tool_calls"
        }
    }

    struct AnyCodableValue: Decodable {}

    func loadActiveSessions(now: Date = Date()) -> [Session] {
        let conversationsDir = antigravityRoot.appendingPathComponent("conversations", isDirectory: true)
        let brainDir = antigravityRoot.appendingPathComponent("brain", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: conversationsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var activeSessions: [Session] = []
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackISOFormatter = ISO8601DateFormatter()

        for file in files where file.pathExtension == "db" {
            let sessionID = file.deletingPathExtension().lastPathComponent
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(modified) < Self.activeWindow else { continue }

            let transcriptURL = brainDir
                .appendingPathComponent(sessionID, isDirectory: true)
                .appendingPathComponent(".system_generated/logs/transcript.jsonl")

            guard FileManager.default.fileExists(atPath: transcriptURL.path),
                  let data = try? Data(contentsOf: transcriptURL),
                  let content = String(data: data, encoding: .utf8) else {
                continue
            }

            let lines = content.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !lines.isEmpty else { continue }

            let decoder = JSONDecoder()
            let headEvents = lines.prefix(8).compactMap { try? decoder.decode(StepEvent.self, from: Data($0.utf8)) }
            let tailEvents = lines.suffix(6).compactMap { try? decoder.decode(StepEvent.self, from: Data($0.utf8)) }

            guard let lastEvent = tailEvents.last else { continue }

            let title = extractTitle(from: headEvents) ?? "Antigravity 任务"
            let (derivedState, detail) = deriveState(from: tailEvents, lastEvent: lastEvent, now: now, modifiedAt: modified, isoFormatter: isoFormatter, fallbackFormatter: fallbackISOFormatter)

            guard derivedState != .idle else { continue }

            let lastTime: Date = {
                if let createdStr = lastEvent.createdAt,
                   let date = isoFormatter.date(from: createdStr) ?? fallbackISOFormatter.date(from: createdStr) {
                    return date
                }
                return modified
            }()

            activeSessions.append(Session(
                id: sessionID,
                title: title,
                state: derivedState,
                detail: detail,
                lastActivity: lastTime,
                workspaceName: nil
            ))
        }

        return activeSessions
    }

    private func extractTitle(from headEvents: [StepEvent]) -> String? {
        for event in headEvents where event.type == "USER_INPUT" {
            guard let text = event.content else { continue }
            if let start = text.range(of: "<USER_REQUEST>"),
               let end = text.range(of: "</USER_REQUEST>", range: start.upperBound..<text.endIndex) {
                let extracted = text[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                if !extracted.isEmpty {
                    return String(extracted.prefix(40))
                }
            }
            if let objStart = text.range(of: "# USER Objective:\n") {
                let after = text[objStart.upperBound...]
                let line = after.split(separator: "\n").first?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let line, !line.isEmpty {
                    return String(line.prefix(40))
                }
            }
            let firstLine = text.split(separator: "\n").first?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let firstLine, !firstLine.isEmpty {
                return String(firstLine.prefix(40))
            }
        }
        return nil
    }

    private func deriveState(
        from tailEvents: [StepEvent],
        lastEvent: StepEvent,
        now: Date,
        modifiedAt: Date,
        isoFormatter: ISO8601DateFormatter,
        fallbackFormatter: ISO8601DateFormatter
    ) -> (CodexActivityState, String) {
        if lastEvent.status == "ERROR" {
            return (.interrupted, "任务已中断")
        }

        // 1. 用户刚输入或正在处理工具结果 -> 思考中
        if lastEvent.type == "USER_INPUT" || lastEvent.source == "USER_EXPLICIT" || lastEvent.type == "GENERIC" {
            return (.thinking, "正在思考与规划...")
        }

        // 2. 模型决策包含 tool_calls
        if let tools = lastEvent.toolCalls, !tools.isEmpty {
            if tools.contains(where: { $0.name == "ask_question" }) {
                return (.waitingForUser, "等待用户确认操作")
            }

            let tool = tools.first!
            let action = tool.toolAction ?? tool.toolSummary ?? tool.name

            // 只读类工具
            let readingTools: Set<String> = [
                "view_file", "list_dir", "grep_search", "find_by_name",
                "read_url_content", "search_web", "read_browser_page"
            ]
            if readingTools.contains(tool.name) {
                return (.reviewing, "正在检索: \(action)")
            }

            // 写/执行类工具
            return (.executing, "正在执行: \(action)")
        }

        // 3. 模型输出了最终纯文本回复
        if lastEvent.type == "PLANNER_RESPONSE" {
            let lastEventTime: Date = {
                if let createdStr = lastEvent.createdAt,
                   let date = isoFormatter.date(from: createdStr) ?? fallbackFormatter.date(from: createdStr) {
                    return date
                }
                return modifiedAt
            }()

            if now.timeIntervalSince(lastEventTime) < 45 {
                return (.completed, "任务已完成")
            } else {
                return (.idle, "Antigravity 当前空闲")
            }
        }

        return (.idle, "Antigravity 当前空闲")
    }
}
