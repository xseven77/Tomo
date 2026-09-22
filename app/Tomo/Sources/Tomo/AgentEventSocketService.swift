import Darwin
import Foundation

enum AgentEventSocketError: LocalizedError {
    case pathTooLong
    case createFailed(Int32)
    case bindFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .pathTooLong:
            "Agent 事件 Socket 路径过长"
        case let .createFailed(code):
            "无法创建 Agent 事件 Socket（errno \(code)）"
        case let .bindFailed(code):
            "无法绑定 Agent 事件 Socket（errno \(code)）"
        }
    }
}

/// Receives privacy-filtered datagrams from the bundled Hook bridge. The
/// socket is local-only and mode 0600; malformed or oversized packets are
/// ignored so vendor hooks always remain fail-open.
final class AgentEventSocketService: @unchecked Sendable {
    static let maximumPayloadBytes = 8 * 1_024

    let socketURL: URL

    private let queue = DispatchQueue(label: "com.qiizo.tomo.agent-events")
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private var handler: (@Sendable (NormalizedAgentEvent) -> Void)?

    init(socketURL: URL = AgentEventSocketService.defaultSocketURL) {
        self.socketURL = socketURL
    }

    static var defaultSocketURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tomo/agent-events.sock")
    }

    func start(handler: @escaping @Sendable (NormalizedAgentEvent) -> Void) throws {
        stop()
        let path = socketURL.path
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw AgentEventSocketError.pathTooLong
        }

        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        unlink(path)

        let socketDescriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard socketDescriptor >= 0 else {
            throw AgentEventSocketError.createFailed(errno)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { pathPointer in
                path.withCString { source in
                    strlcpy(pathPointer, source, pathCapacity)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(socketDescriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            close(socketDescriptor)
            unlink(path)
            throw AgentEventSocketError.bindFailed(code)
        }

        chmod(path, mode_t(S_IRUSR | S_IWUSR))
        descriptor = socketDescriptor
        self.handler = handler
        let source = DispatchSource.makeReadSource(fileDescriptor: socketDescriptor, queue: queue)
        source.setEventHandler { [weak self] in
            self?.receiveAvailableDatagrams()
        }
        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
        handler = nil
        unlink(socketURL.path)
    }

    private func receiveAvailableDatagrams() {
        guard descriptor >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: Self.maximumPayloadBytes + 1)
        let count = recv(descriptor, &buffer, buffer.count, MSG_DONTWAIT)
        guard count > 0, count <= Self.maximumPayloadBytes else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let event = try? decoder.decode(
            NormalizedAgentEvent.self,
            from: Data(buffer.prefix(Int(count)))
        ), event.schemaVersion == NormalizedAgentEvent.currentSchemaVersion else {
            return
        }
        handler?(event)
    }

    deinit {
        stop()
    }
}

struct AgentEventActivityReducer {
    private struct Entry {
        var event: NormalizedAgentEvent
        var state: AgentActivityState
    }

    private var entries: [String: Entry] = [:]

    mutating func ingest(_ event: NormalizedAgentEvent) {
        let key = [
            event.agentID.rawValue,
            event.connectionID?.rawValue.uuidString ?? "vendor",
            event.sessionID ?? event.turnID ?? "current",
        ].joined(separator: ":")
        if event.event == .sessionEnded {
            entries.removeValue(forKey: key)
        } else {
            entries[key] = Entry(event: event, state: PetStateMapper.activity(for: event))
        }
    }

    mutating func mergedSnapshot(
        base: CodexActivitySnapshot,
        now: Date = Date()
    ) -> CodexActivitySnapshot {
        entries = entries.filter { _, entry in
            let age = now.timeIntervalSince(entry.event.timestamp)
            let retention: TimeInterval = switch entry.state {
            case .completed, .failed, .rateLimited, .interrupted: 15
            default: 10 * 60
            }
            return age >= -5 && age <= retention
        }

        let baseCandidate = SnapshotCandidate(
            state: agentState(from: base.state),
            updatedAt: base.updatedAt,
            snapshot: base
        )
        let baseHasActiveCodexTask = !base.activeTasks.isEmpty
        let hookCandidates = entries.values.compactMap { entry -> SnapshotCandidate? in
            if entry.event.agentID == .codex, baseHasActiveCodexTask { return nil }
            let snapshot = snapshot(for: entry)
            return SnapshotCandidate(state: entry.state, updatedAt: entry.event.timestamp, snapshot: snapshot)
        }
        let candidates = [baseCandidate] + hookCandidates
        guard let selected = candidates.max(by: { lhs, rhs in
            if lhs.state.arbitrationPriority == rhs.state.arbitrationPriority {
                return lhs.updatedAt < rhs.updatedAt
            }
            return lhs.state.arbitrationPriority < rhs.state.arbitrationPriority
        }) else { return base }

        let hookTasks = hookCandidates
            .filter { $0.snapshot.state.isEngagedForUnifiedActivity }
            .map { $0.snapshot.activeTasks[0] }
        let observedHookTasks = hookCandidates.compactMap { $0.snapshot.localAgentTasks.first }
        var merged = selected.snapshot
        merged.activeTasks = (base.activeTasks + hookTasks)
            .reduce(into: [String: CodexTaskActivity]()) { result, task in result[task.id] = task }
            .values
            .sorted { lhs, rhs in lhs.updatedAt > rhs.updatedAt }
        merged.localAgentTasks = (base.activeTasks + base.localAgentTasks + observedHookTasks)
            .reduce(into: [String: CodexTaskActivity]()) { result, task in result[task.id] = task }
            .values
            .sorted { lhs, rhs in lhs.updatedAt > rhs.updatedAt }
        merged.activeTaskCount = merged.activeTasks.count
        return merged
    }

    private func snapshot(for entry: Entry) -> CodexActivitySnapshot {
        let agentName = BuiltInAgentCatalog.prioritized
            .first(where: { $0.id == entry.event.agentID })?.displayName ?? "Agent"
        let surfaceName = switch entry.event.surfaceID {
        case .codexCLI: "CLI"
        case .codexDesktop: "Desktop"
        case .hermesCLI: "CLI"
        case .deepseekHarnessCLI: "CLI"
        case .antigravityDesktop: "Desktop"
        case .antigravityIDE: "IDE"
        case .antigravityCLI: "CLI"
        case .piCLI: "CLI"
        }
        let state = codexState(from: entry.state)
        let title = "\(agentName) · \(surfaceName)"
        let detail = detail(for: entry.state, agentName: agentName)
        let task = CodexTaskActivity(
            id: [entry.event.agentID.rawValue, entry.event.connectionID?.rawValue.uuidString ?? "vendor", entry.event.sessionID ?? entry.event.turnID ?? "current"].joined(separator: ":"),
            state: state,
            detail: detail,
            title: title,
            updatedAt: entry.event.timestamp,
            model: agentName
        )
        return CodexActivitySnapshot(
            state: state,
            detail: detail,
            threadTitle: title,
            activeTaskCount: state.isEngagedForUnifiedActivity ? 1 : 0,
            updatedAt: entry.event.timestamp,
            activeTasks: state.isEngagedForUnifiedActivity ? [task] : [],
            localAgentTasks: [task]
        )
    }

    private func detail(for state: AgentActivityState, agentName: String) -> String {
        switch state {
        case .offline: "\(agentName) 当前离线"
        case .idle: "\(agentName) 当前空闲"
        case .thinking: "\(agentName) 正在思考"
        case .executing: "\(agentName) 正在使用工具"
        case .reviewing: "\(agentName) 正在检查结果"
        case .waitingForUser: "\(agentName) 等待你确认"
        case .completed: "\(agentName) 已完成本轮任务"
        case .interrupted: "\(agentName) 已中止"
        case .rateLimited: "\(agentName) 遇到速率限制"
        case .failed: "\(agentName) 执行失败"
        }
    }

    private func codexState(from state: AgentActivityState) -> CodexActivityState {
        switch state {
        case .offline: .unavailable
        case .idle: .idle
        case .thinking: .thinking
        case .executing: .executing
        case .reviewing: .reviewing
        case .waitingForUser: .waitingForUser
        case .completed: .completed
        case .interrupted, .rateLimited, .failed: .interrupted
        }
    }

    private func agentState(from state: CodexActivityState) -> AgentActivityState {
        switch state {
        case .unavailable: .offline
        case .idle: .idle
        case .thinking: .thinking
        case .executing: .executing
        case .reviewing: .reviewing
        case .waitingForUser: .waitingForUser
        case .completed: .completed
        case .interrupted: .interrupted
        }
    }

    private struct SnapshotCandidate {
        let state: AgentActivityState
        let updatedAt: Date
        let snapshot: CodexActivitySnapshot
    }
}

private extension CodexActivityState {
    var isEngagedForUnifiedActivity: Bool {
        switch self {
        case .thinking, .executing, .reviewing, .waitingForUser: true
        default: false
        }
    }
}
