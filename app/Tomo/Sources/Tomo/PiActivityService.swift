import Foundation

/// 读取 Pi（@earendil-works/pi-coding-agent）的会话日志与状态（~/.pi/agent/sessions/），
/// 把活跃会话的事件流映射成 Codex 活动快照。
///
/// Pi 采用标准追加式 JSONL 记录会话事件（~/.pi/agent/sessions/<workspace>/<timestamp>_<uuid>.jsonl），
/// 通过读取头部帧（提取 session 元数据与初始用户提问作为标题）以及末尾帧（推断当前是思考中、
/// 执行工具中、检查中还是等待用户输入），以无侵入的方式实时同步状态。
struct PiActivityService: Sendable {
    let sessionsRoot: URL

    init(
        sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
    ) {
        self.sessionsRoot = sessionsRoot
    }

    /// 判定一个 session 文件是否仍在活跃（最近 3 分钟内有过写入）。
    static let activeWindow: TimeInterval = 180

    func loadSnapshot(now: Date = Date()) -> CodexActivitySnapshot {
        guard FileManager.default.fileExists(atPath: sessionsRoot.path) else {
            return .unavailable
        }
        let sessions = loadActiveSessions(now: now)
        guard !sessions.isEmpty else {
            return CodexActivitySnapshot(
                state: .idle,
                detail: "Pi 当前空闲",
                threadTitle: nil,
                activeTaskCount: 0,
                updatedAt: now
            )
        }

        let tasks = sessions.map { session -> CodexTaskActivity in
            CodexTaskActivity(
                id: "pi:\(session.id)",
                state: session.state,
                detail: session.detail,
                title: session.title,
                updatedAt: session.lastActivity,
                workspaceName: session.workspaceName,
                gitBranch: nil,
                model: "Pi"
            )
        }

        // 优先级仲裁：优先展示等待输入、执行中、检查中、思考中的任务
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
        let files = discoverSessionFiles()
        return files.filter { file in
            let mod = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return calendar.isDateInToday(mod)
        }.count
    }

    // MARK: - Session discovery

    func discoverSessionFiles() -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                if let subEntries = try? FileManager.default.contentsOfDirectory(
                    at: entry,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ) {
                    for sub in subEntries where sub.pathExtension == "jsonl" {
                        files.append(sub)
                    }
                }
            } else if entry.pathExtension == "jsonl" {
                files.append(entry)
            }
        }
        return files
    }

    struct Session {
        let id: String
        let title: String
        let state: CodexActivityState
        let detail: String
        let lastActivity: Date
        let workspaceName: String?
    }

    func loadActiveSessions(now: Date = Date()) -> [Session] {
        let files = discoverSessionFiles()
        var activeSessions: [Session] = []

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackISOFormatter = ISO8601DateFormatter()

        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(modified) < Self.activeWindow else { continue }

            guard let headText = readHead(of: file, maxBytes: 16 * 1024),
                  let tailText = readTail(of: file, maxBytes: 32 * 1024) else {
                continue
            }

            let headLines = headText.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let tailLines = tailText.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !headLines.isEmpty, !tailLines.isEmpty else { continue }

            let (sessionID, workspaceName, extractedTitle) = parseSessionMetadata(from: headLines, fallbackID: file.deletingPathExtension().lastPathComponent)
            let (derivedState, detail, lastEventTime) = deriveState(
                from: tailLines,
                now: now,
                modifiedAt: modified,
                isoFormatter: isoFormatter,
                fallbackFormatter: fallbackISOFormatter
            )

            guard derivedState != .idle else { continue }

            activeSessions.append(Session(
                id: sessionID,
                title: extractedTitle ?? "Pi 任务",
                state: derivedState,
                detail: detail,
                lastActivity: lastEventTime,
                workspaceName: workspaceName
            ))
        }

        return activeSessions
    }

    // MARK: - Reading helpers

    func readHead(of url: URL, maxBytes: Int = 16 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: maxBytes)
        return String(data: data, encoding: .utf8)
    }

    func readTail(of url: URL, maxBytes: Int = 32 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end > 0 else { return nil }
        let offset = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Metadata parsing

    func parseSessionMetadata(from headLines: [String], fallbackID: String) -> (id: String, workspaceName: String?, title: String?) {
        var sessionID = fallbackID
        var workspaceName: String?
        var title: String?

        for line in headLines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let type = obj["type"] as? String
            if type == "session" {
                if let id = obj["id"] as? String, !id.isEmpty {
                    sessionID = id
                }
                if let cwd = obj["cwd"] as? String, !cwd.isEmpty {
                    workspaceName = URL(fileURLWithPath: cwd).lastPathComponent
                }
            } else if type == "message", title == nil {
                if let message = obj["message"] as? [String: Any],
                   (message["role"] as? String) == "user",
                   let content = message["content"] as? [[String: Any]] {
                    for block in content where (block["type"] as? String) == "text" {
                        if let text = block["text"] as? String {
                            let clean = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                            if !clean.isEmpty {
                                title = clean.count > 44 ? String(clean.prefix(43)) + "…" : clean
                                break
                            }
                        }
                    }
                }
            }
        }

        return (sessionID, workspaceName, title)
    }

    // MARK: - State derivation

    func deriveState(
        from tailLines: [String],
        now: Date,
        modifiedAt: Date,
        isoFormatter: ISO8601DateFormatter,
        fallbackFormatter: ISO8601DateFormatter
    ) -> (state: CodexActivityState, detail: String, lastTime: Date) {
        var lastTime = modifiedAt
        var latestMessage: (role: String, stopReason: String?, content: [[String: Any]], timestamp: Date)?

        for line in tailLines.reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let type = obj["type"] as? String
            let eventTime: Date? = {
                if let tsStr = obj["timestamp"] as? String {
                    return isoFormatter.date(from: tsStr) ?? fallbackFormatter.date(from: tsStr)
                }
                if let msg = obj["message"] as? [String: Any], let tsNum = msg["timestamp"] as? Double {
                    return Date(timeIntervalSince1970: tsNum > 1_000_000_000_000 ? tsNum / 1000 : tsNum)
                }
                if let tsNum = obj["timestamp"] as? Double {
                    return Date(timeIntervalSince1970: tsNum > 1_000_000_000_000 ? tsNum / 1000 : tsNum)
                }
                return nil
            }()

            if latestMessage == nil && type == "message", let msg = obj["message"] as? [String: Any] {
                let role = msg["role"] as? String ?? ""
                let stopReason = obj["stopReason"] as? String ?? msg["stopReason"] as? String
                let content = msg["content"] as? [[String: Any]] ?? []
                let t = eventTime ?? modifiedAt
                latestMessage = (role, stopReason, content, t)
                lastTime = t
                break
            }
        }

        guard let msg = latestMessage else {
            if now.timeIntervalSince(modifiedAt) >= 30 {
                return (.idle, "Pi 当前空闲", modifiedAt)
            }
            return (.thinking, "Pi 正在思考", modifiedAt)
        }

        if msg.role == "user" {
            return (.thinking, "Pi 正在思考", msg.timestamp)
        }

        if msg.role == "assistant" {
            if msg.stopReason == "toolUse" {
                let toolCall = msg.content.last { ($0["type"] as? String) == "toolCall" }
                if let toolName = toolCall?["name"] as? String, !toolName.isEmpty {
                    return (.executing, "Pi 正在执行 \(toolName)", msg.timestamp)
                }
                return (.executing, "Pi 正在执行工具", msg.timestamp)
            }

            if msg.stopReason == "stop" {
                // 模型正常回复完成（无工具调用）说明该轮对话已经结束，Agent 进入空闲状态。
                return (.idle, "Pi 当前空闲", msg.timestamp)
            }

            if msg.stopReason == "error" {
                return (.interrupted, "Pi 执行出错", msg.timestamp)
            }

            if msg.stopReason == "abort" {
                return (.interrupted, "Pi 已中止", msg.timestamp)
            }

            if let lastBlock = msg.content.last, (lastBlock["type"] as? String) == "toolCall" {
                let toolName = lastBlock["name"] as? String ?? "工具"
                return (.executing, "Pi 正在执行 \(toolName)", msg.timestamp)
            }

            return (.idle, "Pi 当前空闲", msg.timestamp)
        }

        if msg.role == "toolResult" || msg.content.contains(where: { ($0["type"] as? String) == "toolResult" }) {
            return (.reviewing, "Pi 正在检查结果", msg.timestamp)
        }

        return (.idle, "Pi 当前空闲", lastTime)
    }
}
