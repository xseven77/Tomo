import AppKit
import Foundation
import Observation
import SQLite3

enum CodexActivityState: String, CaseIterable, Sendable {
    case unavailable
    case idle
    case thinking
    case executing
    case reviewing
    case waitingForUser
    case completed
    case interrupted

    var showsActivityWave: Bool {
        self != .idle && self != .unavailable
    }

    var statusBarText: String? {
        switch self {
        case .unavailable, .idle:
            nil
        case .thinking:
            "思考中"
        case .executing:
            "工作中"
        case .reviewing:
            "检查中"
        case .waitingForUser:
            "待确认"
        case .completed:
            "已完成"
        case .interrupted:
            "已中止"
        }
    }

    var petAnimationState: PetAnimationState {
        switch self {
        case .unavailable, .idle:
            .idle
        case .thinking, .executing:
            .running
        case .reviewing:
            .review
        case .waitingForUser:
            .waiting
        case .completed:
            .waving
        case .interrupted:
            .failed
        }
    }

    var arbitrationPriority: Int {
        switch self {
        case .waitingForUser: 5
        case .executing: 4
        case .reviewing: 3
        case .thinking: 2
        case .interrupted: 1
        case .completed, .idle, .unavailable: 0
        }
    }

    var hoverTitle: String {
        switch self {
        case .unavailable:
            "Codex 状态不可用"
        case .idle:
            "Codex 当前空闲"
        case .thinking:
            "Codex 正在思考"
        case .executing:
            "Codex 正在工作"
        case .reviewing:
            "Codex 正在检查结果"
        case .waitingForUser:
            "Codex 等待你确认"
        case .completed:
            "Codex 任务已完成"
        case .interrupted:
            "Codex 任务已中止"
        }
    }

    var statusNSColor: NSColor {
        switch self {
        case .unavailable, .idle:
            NSColor(red: 0.682, green: 0.710, blue: 0.702, alpha: 1)
        case .thinking:
            NSColor(red: 0.478, green: 0.259, blue: 0.961, alpha: 1)
        case .executing:
            NSColor(red: 0.180, green: 0.420, blue: 1.000, alpha: 1)
        case .reviewing:
            NSColor(red: 0.020, green: 0.631, blue: 0.800, alpha: 1)
        case .waitingForUser:
            NSColor(red: 0.949, green: 0.451, blue: 0.078, alpha: 1)
        case .completed:
            NSColor(red: 0.122, green: 0.647, blue: 0.353, alpha: 1)
        case .interrupted:
            NSColor(red: 0.929, green: 0.220, blue: 0.302, alpha: 1)
        }
    }
}

extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

struct CodexActivitySnapshot: Equatable, Sendable {
    var state: CodexActivityState
    var detail: String
    var threadTitle: String?
    var activeTaskCount: Int
    var updatedAt: Date
    var activeTasks: [CodexTaskActivity] = []
    /// Recently observed native/Hook tasks, including idle Agents. This powers
    /// the Pet-local overview without mixing those tasks into account scope.
    var localAgentTasks: [CodexTaskActivity] = []

    static let unavailable = CodexActivitySnapshot(
        state: .unavailable,
        detail: "未找到可读取的 Codex 本地活动数据",
        threadTitle: nil,
        activeTaskCount: 0,
        updatedAt: Date()
    )

    var keepsHoverPanelVisible: Bool {
        activeTaskCount > 0
    }

    var hoverSubtitle: String {
        let cleanDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanDetail.isEmpty { return cleanDetail }
        if let threadTitle, !threadTitle.isEmpty { return threadTitle }
        return state.hoverTitle
    }

    var hoverDisplayTitle: String {
        guard state != .unavailable, state != .idle,
              let threadTitle else {
            return state.hoverTitle
        }
        let cleanTitle = threadTitle
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return state.hoverTitle }
        return cleanTitle.count > 44
            ? String(cleanTitle.prefix(43)) + "…"
            : cleanTitle
    }
}

extension CodexActivitySnapshot {
    /// 把多个 Agent 的快照合并成一个：拼接 activeTasks / localAgentTasks，
    /// 整体 state / threadTitle 取优先级最高的那个。
    static func merged(_ snapshots: [CodexActivitySnapshot]) -> CodexActivitySnapshot {
        let sources = snapshots.filter { $0.state != .unavailable }
        guard !sources.isEmpty else { return .unavailable }

        func priority(_ state: CodexActivityState) -> Int {
            switch state {
            case .waitingForUser: 5
            case .executing: 4
            case .reviewing: 3
            case .thinking: 2
            case .interrupted: 1
            default: 0
            }
        }

        let selected = sources.max { lhs, rhs in
            let lp = priority(lhs.state)
            let rp = priority(rhs.state)
            if lp == rp { return lhs.updatedAt < rhs.updatedAt }
            return lp < rp
        }!

        let activeTasks = sources.flatMap(\.activeTasks)
        let localAgentTasks = sources.flatMap { $0.activeTasks + $0.localAgentTasks }
        return CodexActivitySnapshot(
            state: selected.state,
            detail: selected.detail,
            threadTitle: selected.threadTitle,
            activeTaskCount: activeTasks.count,
            updatedAt: selected.updatedAt,
            activeTasks: activeTasks,
            localAgentTasks: localAgentTasks
        )
    }
}

struct CodexActivitySnapshotStabilizer {
    private var pendingRemovalTaskIDs: [String]?

    mutating func resolve(
        current: CodexActivitySnapshot,
        candidate: CodexActivitySnapshot
    ) -> CodexActivitySnapshot? {
        let currentIDs = Set(current.activeTasks.map(\.id))
        let candidateIDs = Set(candidate.activeTasks.map(\.id))
        let removedIDs = currentIDs.subtracting(candidateIDs)

        guard !removedIDs.isEmpty else {
            pendingRemovalTaskIDs = nil
            return candidate
        }

        let signature = candidate.activeTasks.map(\.id).sorted()
        if pendingRemovalTaskIDs == signature {
            pendingRemovalTaskIDs = nil
            return candidate
        }

        pendingRemovalTaskIDs = signature
        return nil
    }
}

struct CodexTaskActivity: Identifiable, Equatable, Sendable {
    let id: String
    var state: CodexActivityState
    var detail: String
    var title: String
    var updatedAt: Date
    var workspaceName: String? = nil
    var gitBranch: String? = nil
    var model: String? = nil

    /// Hook-backed tasks carry the Agent name in `title`/`model`; native Codex
    /// tasks carry the model name instead, so Codex is the safe fallback.
    var agentDisplayName: String {
        if id.hasPrefix("dsh:") { return "Deepseek Harness" }
        if id.hasPrefix("hermes:") { return "Hermes" }
        if id.hasPrefix("antigravity:") { return "Antigravity" }
        if id.hasPrefix("pi:") { return "Pi" }
        if id.hasPrefix("codex:") { return "Codex" }

        for agent in BuiltInAgentCatalog.prioritized {
            if model == agent.displayName
                || title == agent.displayName
                || title.hasPrefix("\(agent.displayName) ·") {
                return agent.displayName
            }
        }
        return "Codex"
    }
}

struct CompanionAgentStatus: Identifiable, Equatable, Sendable {
    var id: String { agentName }
    let agentName: String
    let state: CodexActivityState
    let taskCount: Int
    let updatedAt: Date
}

extension CodexActivitySnapshot {
    /// One ticker item per running Agent. Multiple concurrent tasks from the
    /// same Agent are represented by the freshest state plus a task count.
    var activeAgentStatuses: [CompanionAgentStatus] {
        let sortedTasks = activeTasks.sorted { $0.updatedAt > $1.updatedAt }
        var statuses: [CompanionAgentStatus] = []

        for task in sortedTasks {
            let agentName = task.agentDisplayName
            if let index = statuses.firstIndex(where: { $0.agentName == agentName }) {
                let current = statuses[index]
                statuses[index] = CompanionAgentStatus(
                    agentName: current.agentName,
                    state: current.state,
                    taskCount: current.taskCount + 1,
                    updatedAt: current.updatedAt
                )
            } else {
                statuses.append(
                    CompanionAgentStatus(
                        agentName: agentName,
                        state: task.state,
                        taskCount: 1,
                        updatedAt: task.updatedAt
                    )
                )
            }
        }

        return statuses
    }
}

struct ParsedCodexThreadActivity: Equatable, Sendable {
    var id: String
    var state: CodexActivityState
    var detail: String
    var title: String
    var updatedAt: Date
    var workspaceName: String? = nil
    var gitBranch: String? = nil
    var model: String? = nil

    var isActive: Bool {
        switch state {
        case .thinking, .executing, .reviewing, .waitingForUser:
            true
        default:
            false
        }
    }

}

struct CodexActivityEventParser: Sendable {
    func parse(
        data: Data,
        id: String = UUID().uuidString,
        title: String,
        now: Date = Date()
    ) -> ParsedCodexThreadActivity {
        let isoFormatter = ISO8601DateFormatter()
        var isActive = false
        var state: CodexActivityState = .idle
        var detail = ""
        var updatedAt = Date.distantPast
        var outstandingCalls: [String: String] = [:]

        for line in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else {
                continue
            }

            if let timestamp = object["timestamp"] as? String,
               let date = isoFormatter.date(from: timestamp) {
                updatedAt = max(updatedAt, date)
            }

            switch object["type"] as? String {
            case "event_msg":
                let type = payload["type"] as? String
                switch type {
                case "task_started":
                    isActive = true
                    state = .thinking
                    outstandingCalls.removeAll()
                    if detail.isEmpty { detail = "正在分析任务并准备执行" }
                case "task_complete":
                    isActive = false
                    state = .completed
                    outstandingCalls.removeAll()
                    if detail.isEmpty { detail = "任务已经完成" }
                case "turn_aborted":
                    isActive = false
                    state = .interrupted
                    outstandingCalls.removeAll()
                    detail = "任务已停止或被中止"
                case "agent_message":
                    if let message = payload["message"] as? String,
                       payload["phase"] as? String == "commentary" {
                        detail = sanitize(message)
                    }
                case "agent_reasoning":
                    if isActive, outstandingCalls.isEmpty {
                        state = .thinking
                    }
                case "patch_apply_end":
                    if isActive {
                        state = .reviewing
                        if detail.isEmpty { detail = "正在检查代码改动" }
                    }
                default:
                    break
                }

            case "response_item":
                let type = payload["type"] as? String
                switch type {
                case "custom_tool_call", "function_call":
                    guard isActive else { break }
                    let callID = (payload["call_id"] as? String)
                        ?? (payload["id"] as? String)
                        ?? UUID().uuidString
                    let name = payload["name"] as? String ?? "tool"
                    let input = (payload["input"] as? String)
                        ?? (payload["arguments"] as? String)
                        ?? ""
                    let normalizedName = input.contains("require_escalated") ? "approval" : name
                    outstandingCalls[callID] = normalizedName
                    if isWaitingTool(normalizedName) {
                        state = .waitingForUser
                    } else if isReviewTool(normalizedName) {
                        state = .reviewing
                    } else {
                        state = .executing
                    }
                    detail = toolDescription(normalizedName)

                case "custom_tool_call_output", "function_call_output":
                    if let callID = payload["call_id"] as? String {
                        outstandingCalls.removeValue(forKey: callID)
                    }
                    if isActive {
                        state = outstandingCalls.isEmpty ? .thinking : stateForCalls(outstandingCalls.values)
                    }

                case "message":
                    if payload["phase"] as? String == "commentary",
                       let message = responseMessageText(payload) {
                        detail = sanitize(message)
                    }
                case "reasoning":
                    if isActive, outstandingCalls.isEmpty {
                        state = .thinking
                    }
                default:
                    break
                }
            default:
                break
            }
        }

        if isActive, !outstandingCalls.isEmpty {
            state = stateForCalls(outstandingCalls.values)
            if let name = outstandingCalls.values.first {
                detail = toolDescription(name)
            }
        }

        if !isActive, state == .completed, now.timeIntervalSince(updatedAt) > 20 {
            state = .idle
            detail = "当前没有正在执行的 Codex 任务"
        }
        if updatedAt == .distantPast { updatedAt = now }

        return ParsedCodexThreadActivity(
            id: id,
            state: state,
            detail: detail,
            title: title,
            updatedAt: updatedAt
        )
    }

    private func responseMessageText(_ payload: [String: Any]) -> String? {
        guard let content = payload["content"] as? [[String: Any]] else { return nil }
        return content.compactMap { item in
            let type = item["type"] as? String
            guard type == "output_text" || type == "text" else { return nil }
            return item["text"] as? String
        }.joined(separator: " ")
    }

    private func stateForCalls(_ names: Dictionary<String, String>.Values) -> CodexActivityState {
        if names.contains(where: isWaitingTool) { return .waitingForUser }
        if names.contains(where: isReviewTool) { return .reviewing }
        return .executing
    }

    private func isWaitingTool(_ name: String) -> Bool {
        name == "request_user_input" || name == "approval"
    }

    private func isReviewTool(_ name: String) -> Bool {
        name.contains("view_image") || name.contains("screenshot")
    }

    private func toolDescription(_ name: String) -> String {
        return switch name {
        case "approval", "request_user_input":
            "需要你的确认后才能继续"
        case "exec", "exec_command", "write_stdin":
            "正在运行本地命令"
        case "apply_patch":
            "正在修改项目文件"
        case "wait", "wait_agent":
            "正在等待后台任务返回"
        case "view_image", "imagegen", "image_gen__imagegen":
            "正在处理图像"
        default:
            name.contains("web") || name.contains("search")
                ? "正在检索相关信息"
                : "正在调用工具处理任务"
        }
    }

    private func sanitize(_ text: String) -> String {
        var value = text
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count > 100 {
            value = String(value.prefix(99)) + "…"
        }
        return value
    }
}

struct CodexActivityService: Sendable {
    let databaseURLs: [URL]
    let sessionIndexURLs: [URL]
    let parser = CodexActivityEventParser()

    init(databaseURLs: [URL]? = nil, sessionIndexURLs: [URL]? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let databaseURLs {
            self.databaseURLs = databaseURLs
        } else {
            self.databaseURLs = [
                home.appendingPathComponent(".codex/state_5.sqlite"),
                home.appendingPathComponent(".codex/sqlite/state_5.sqlite")
            ]
        }
        self.sessionIndexURLs = sessionIndexURLs ?? [
            home.appendingPathComponent(".codex/session_index.jsonl")
        ]
    }

    func loadSnapshot(now: Date = Date()) -> CodexActivitySnapshot {
        guard let databaseURL = databaseURLs.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            return .unavailable
        }

        let indexedTitles = loadIndexedThreadTitles()
        let rows = loadRecentThreads(databaseURL: databaseURL)
        guard !rows.isEmpty else {
            return CodexActivitySnapshot(
                state: .idle,
                detail: "当前没有可读取的 Codex 任务",
                threadTitle: nil,
                activeTaskCount: 0,
                updatedAt: now
            )
        }

        let activities = rows.enumerated().compactMap { index, row -> ParsedCodexThreadActivity? in
            guard let data = readTail(
                of: URL(fileURLWithPath: row.rolloutPath),
                expandForLifecycle: index == 0
            ) else { return nil }
            let indexedTitle = indexedTitles[row.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let databaseName = row.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = if let indexedTitle, !indexedTitle.isEmpty {
                indexedTitle
            } else if let databaseName, !databaseName.isEmpty {
                databaseName
            } else {
                row.title
            }
            var activity = parser.parse(data: data, id: row.id, title: displayTitle, now: now)
            activity.workspaceName = row.workspaceName
            activity.gitBranch = row.gitBranch
            activity.model = row.model
            return activity
        }
        guard !activities.isEmpty else { return .unavailable }

        let engaged = activities.filter(\.isActive).sorted { lhs, rhs in
            let lhsPriority = activityPriority(lhs.state)
            let rhsPriority = activityPriority(rhs.state)
            return lhsPriority == rhsPriority
                ? lhs.updatedAt > rhs.updatedAt
                : lhsPriority > rhsPriority
        }
        // Every active user thread is independently navigable. The previous
        // fallback kept only the highest-priority thread whenever the active
        // set mixed states (for example one executing thread plus one waiting
        // for approval), which collapsed a same-Agent task list to 1.
        let visibleTasks = engaged
        let selected: ParsedCodexThreadActivity
        if let selectedEngaged = engaged.first {
            selected = selectedEngaged
        } else {
            selected = activities.max { $0.updatedAt < $1.updatedAt }!
        }

        return CodexActivitySnapshot(
            state: selected.state,
            detail: selected.detail,
            threadTitle: selected.title,
            activeTaskCount: visibleTasks.count,
            updatedAt: selected.updatedAt,
            activeTasks: visibleTasks.map {
                CodexTaskActivity(
                    id: $0.id,
                    state: $0.state,
                    detail: $0.detail,
                    title: $0.title,
                    updatedAt: $0.updatedAt,
                    workspaceName: $0.workspaceName,
                    gitBranch: $0.gitBranch,
                    model: $0.model
                )
            }
        )
    }

    func countTodayThreads(now: Date = Date()) -> Int {
        guard let databaseURL = databaseURLs.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else { return 0 }
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
            nil
        ) == SQLITE_OK, let database else { return 0 }
        defer { sqlite3_close(database) }
        let sql = "SELECT count(*) FROM threads WHERE archived = 0 AND date(updated_at, 'unixepoch', 'localtime') = date('now', 'localtime');"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return 0 }
        defer { sqlite3_finalize(statement) }
        if sqlite3_step(statement) == SQLITE_ROW {
            return Int(sqlite3_column_int(statement, 0))
        }
        return 0
    }

    private typealias RecentThread = (
        id: String,
        rolloutPath: String,
        title: String,
        name: String?,
        workspaceName: String?,
        gitBranch: String?,
        model: String?
    )

    private func loadRecentThreads(databaseURL: URL) -> [RecentThread] {
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

        let threadSourceFilter = tableHasColumn("thread_source", database: database)
            ? "AND COALESCE(thread_source, 'user') <> 'subagent'"
            : ""
        let nameExpression = tableHasColumn("name", database: database) ? "name" : "NULL"
        let cwdExpression = tableHasColumn("cwd", database: database) ? "cwd" : "NULL"
        let branchExpression = tableHasColumn("git_branch", database: database) ? "git_branch" : "NULL"
        let modelExpression = tableHasColumn("model", database: database) ? "model" : "NULL"
        let sql = """
        SELECT id, rollout_path, title,
               \(nameExpression), \(cwdExpression), \(branchExpression), \(modelExpression)
        FROM threads
        WHERE archived = 0
        \(threadSourceFilter)
        ORDER BY updated_at DESC
        LIMIT 12
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var rows: [RecentThread] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let pathText = sqlite3_column_text(statement, 1) else { continue }
            let id = String(cString: idText)
            let path = String(cString: pathText)
            let title = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? "Codex 任务"
            let name = sqliteString(statement, column: 3)
            let cwd = sqliteString(statement, column: 4)
            let workspaceName = cwd.map {
                URL(fileURLWithPath: $0).lastPathComponent
            }?.nilIfEmpty
            let branch = sqliteString(statement, column: 5)?.nilIfEmpty
            let model = sqliteString(statement, column: 6)?.nilIfEmpty
            rows.append((id, path, title, name, workspaceName, branch, model))
        }
        return rows
    }

    private func loadIndexedThreadTitles() -> [String: String] {
        var titles: [String: String] = [:]
        for url in sessionIndexURLs where FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url) else { continue }
            for line in data.split(separator: 0x0A) {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let id = object["id"] as? String,
                      let title = object["thread_name"] as? String else {
                    continue
                }
                titles[id] = title
            }
        }
        return titles
    }

    private func sqliteString(_ statement: OpaquePointer, column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    private func tableHasColumn(_ name: String, database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(threads)", -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let nameText = sqlite3_column_text(statement, 1) else { continue }
            if String(cString: nameText) == name { return true }
        }
        return false
    }

    func readTail(
        of url: URL,
        maxBytes: UInt64 = 4 * 1_024 * 1_024,
        expandForLifecycle: Bool = true
    ) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        guard end > 0 else { return nil }

        var start = end
        var accumulated = Data()
        while start > 0 {
            let chunkSize = min(maxBytes, start)
            start -= chunkSize
            try? handle.seek(toOffset: start)
            guard let chunk = try? handle.read(upToCount: Int(chunkSize)),
                  !chunk.isEmpty else { return nil }
            accumulated.insert(contentsOf: chunk, at: accumulated.startIndex)

            var data = accumulated
            if start > 0, let firstNewline = data.firstIndex(of: 0x0A) {
                data.removeSubrange(data.startIndex...firstNewline)
            }

            if start == 0 || !expandForLifecycle || containsLifecycleEvent(data) {
                return data
            }
        }
        return accumulated
    }

    private func containsLifecycleEvent(_ data: Data) -> Bool {
        ["task_started", "task_complete", "turn_aborted"].contains { marker in
            data.range(of: Data(marker.utf8)) != nil
        }
    }

    private func activityPriority(_ state: CodexActivityState) -> Int {
        switch state {
        case .waitingForUser: 5
        case .executing: 4
        case .reviewing: 3
        case .thinking: 2
        case .interrupted: 1
        default: 0
        }
    }
}

@Observable
@MainActor
final class CodexActivityStore {
    var snapshot = CodexActivitySnapshot.unavailable
    var onSnapshotChanged: ((CodexActivitySnapshot) -> Void)?

    private let codexService: CodexActivityService
    private let dshService: DSHActivityService
    private let hermesService: HermesActivityService
    private let antigravityService: AntigravityActivityService
    private let piService: PiActivityService
    private var baseSnapshot = CodexActivitySnapshot.unavailable
    private var agentEventReducer = AgentEventActivityReducer()
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var snapshotStabilizer = CodexActivitySnapshotStabilizer()

    init(
        codexService: CodexActivityService = CodexActivityService(),
        dshService: DSHActivityService = DSHActivityService(),
        hermesService: HermesActivityService = HermesActivityService(),
        antigravityService: AntigravityActivityService = AntigravityActivityService(),
        piService: PiActivityService = PiActivityService()
    ) {
        self.codexService = codexService
        self.dshService = dshService
        self.hermesService = hermesService
        self.antigravityService = antigravityService
        self.piService = piService
    }

    func start() {
        stop()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    func ingest(_ event: NormalizedAgentEvent) {
        agentEventReducer.ingest(event)
        publishMergedSnapshot()
    }

    private func refresh() {
        guard refreshTask == nil else { return }
        let codexService = self.codexService
        let dshService = self.dshService
        let hermesService = self.hermesService
        let antigravityService = self.antigravityService
        let piService = self.piService
        refreshTask = Task { [weak self] in
            let next = await Task.detached {
                CodexActivitySnapshot.merged([
                    codexService.loadSnapshot(),
                    dshService.loadSnapshot(),
                    hermesService.loadSnapshot(),
                    antigravityService.loadSnapshot(),
                    piService.loadSnapshot(),
                ])
            }.value
            guard !Task.isCancelled, let self else { return }
            refreshTask = nil
            guard let stable = snapshotStabilizer.resolve(
                current: snapshot,
                candidate: next
            ) else {
                return
            }
            baseSnapshot = stable
            publishMergedSnapshot()
        }
    }

    private func publishMergedSnapshot(now: Date = Date()) {
        let merged = agentEventReducer.mergedSnapshot(base: baseSnapshot, now: now)
        if merged != snapshot {
            snapshot = merged
            onSnapshotChanged?(merged)
        }
    }
}
