import AppKit
import Foundation
import Observation

// MARK: - 日志级别
public enum GatewayLogLevel: String, CaseIterable, Identifiable, Sendable {
    case info
    case warn
    case error

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .info: return "INFO"
        case .warn: return "WARN"
        case .error: return "ERROR"
        }
    }
}

public enum GatewayLogLevelFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "全部"
    case error = "错误"
    case warn = "警告"
    case info = "信息"

    public var id: String { rawValue }
}

// MARK: - 日志来源 / 子系统
public enum GatewayLogSource: String, CaseIterable, Identifiable, Sendable {
    case gateway       // Rust gateway 二进制自身的运行错误（gateway.log）
    case supervisor    // Swift 守护进程捕获的进程 stderr + 生命周期诊断（gateway-supervisor.log）

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .gateway: return "网关协议"
        case .supervisor: return "守护进程"
        }
    }
}

public enum GatewayLogSourceFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "全部"
    case gateway = "网关"
    case supervisor = "守护"

    public var id: String { rawValue }
}

// MARK: - 单条日志
public struct GatewayLogEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let timestamp: Date
    public let source: GatewayLogSource
    public let level: GatewayLogLevel
    public var message: String
    public let file: String

    public init(
        source: GatewayLogSource,
        timestamp: Date,
        level: GatewayLogLevel,
        message: String,
        file: String,
        lineNumber: Int
    ) {
        self.id = "\(source.rawValue)-\(Int(timestamp.timeIntervalSince1970))-\(file)-\(lineNumber)"
        self.source = source
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.file = file
    }

    public var formattedTime: String {
        Self.timeFormatter.string(from: timestamp)
    }

    public var fullText: String {
        "[\(Self.datetimeFormatter.string(from: timestamp))] [\(source.label)] [\(level.label)] \(message)"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let datetimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

/// 聚合本地 Gateway 生命周期与上游错误日志的统一入口。
///
/// 聚合两个日志来源（均为 `[unix_epoch] 消息` 行格式）：
/// - `gateway-supervisor.log`：Swift 守护进程捕获的 Rust stderr + 生命周期诊断；
/// - `gateway.log`：Rust gateway 二进制自身写入的运行错误（如 Gemini OAuth 上游连接失败）。
///
/// 级别无法从原始行直接读取，这里按关键词语义推断，便于 UI 上用颜色区分。
///
/// 为避免日志文件变大后在 UI 线程卡顿：读取/解析在后台任务完成，仅把结果回主线程；
/// 展示层用分页切片（`pagedEntries`），一次只渲染 `pageSize` 条。
@MainActor
@Observable
public final class GatewayLogStore {
    public static let shared = GatewayLogStore()

    public private(set) var entries: [GatewayLogEntry] = []
    public private(set) var isLoading: Bool = false
    public private(set) var lastError: String?

    // 筛选状态（空集合表示「全部」）；任一变化都回到第一页
    public var selectedSources: Set<GatewayLogSource> = [] {
        didSet { if oldValue != selectedSources { currentPage = 1 } }
    }
    public var selectedLevels: Set<GatewayLogLevel> = [] {
        didSet { if oldValue != selectedLevels { currentPage = 1 } }
    }
    public var searchText: String = "" {
        didSet { if oldValue != searchText { currentPage = 1 } }
    }
    public var isAutoTail: Bool = true

    // 便捷单选枚举（对应 UI 上的 Segmented Control）
    public var activeLevelFilter: GatewayLogLevelFilter = .all {
        didSet {
            switch activeLevelFilter {
            case .all: selectedLevels = []
            case .error: selectedLevels = [.error]
            case .warn: selectedLevels = [.warn]
            case .info: selectedLevels = [.info]
            }
        }
    }

    public var activeSourceFilter: GatewayLogSourceFilter = .all {
        didSet {
            switch activeSourceFilter {
            case .all: selectedSources = []
            case .gateway: selectedSources = [.gateway]
            case .supervisor: selectedSources = [.supervisor]
            }
        }
    }

    // 分页状态
    public var pageSize: Int = 100 {
        didSet { if oldValue != pageSize { currentPage = 1 } }
    }
    public private(set) var currentPage: Int = 1

    public var totalCount: Int { filteredAll.count }

    public var totalPages: Int {
        guard totalCount > 0 else { return 1 }
        return max(1, Int(ceil(Double(totalCount) / Double(pageSize))))
    }

    /// 当前页的切片，供视图渲染（避免一次渲染全部行）。
    public var pagedEntries: [GatewayLogEntry] {
        let all = filteredAll
        guard !all.isEmpty else { return [] }
        let start = (currentPage - 1) * pageSize
        guard start < all.count else { return [] }
        let end = min(start + pageSize, all.count)
        return Array(all[start..<end])
    }

    private var hasLoaded = false

    public static var logsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tomo", isDirectory: true)
    }

    public static var supervisorLogURL: URL {
        logsDirectory.appendingPathComponent("gateway-supervisor.log")
    }

    public static var gatewayLogURL: URL {
        logsDirectory.appendingPathComponent("gateway.log")
    }

    /// 首次进入日志页时才读取，避免 App 启动即读文件。
    public func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        reload()
    }

    /// 未分页的完整筛选结果（用于复制导出与总数统计）。
    public var filteredEntries: [GatewayLogEntry] { filteredAll }

    private var filteredAll: [GatewayLogEntry] {
        var result = entries
        if !selectedSources.isEmpty {
            result = result.filter { selectedSources.contains($0.source) }
        }
        if !selectedLevels.isEmpty {
            result = result.filter { selectedLevels.contains($0.level) }
        }
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let needle = searchText.lowercased()
            result = result.filter {
                $0.message.lowercased().contains(needle)
                    || $0.source.label.lowercased().contains(needle)
                    || $0.level.label.lowercased().contains(needle)
            }
        }
        return result
    }

    public var exportText: String {
        filteredAll.map { $0.fullText }.joined(separator: "\n")
    }

    public func goToPage(_ page: Int) {
        let target = max(1, min(page, totalPages))
        if target != currentPage {
            currentPage = target
        }
    }

    public func nextPage() { goToPage(currentPage + 1) }
    public func prevPage() { goToPage(currentPage - 1) }

    /// 后台读取 + 解析两个日志文件，只把结果回主线程，避免 UI 卡顿。
    public func reload() {
        isLoading = true
        let sources: [(URL, GatewayLogSource)] = [
            (Self.supervisorLogURL, .supervisor),
            (Self.gatewayLogURL, .gateway),
        ]

        Task.detached(priority: .userInitiated) { [weak self] in
            var merged: [GatewayLogEntry] = []
            for (url, source) in sources {
                guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
                    continue
                }
                merged.append(contentsOf: Self.parse(text: text, source: source, file: url.lastPathComponent))
            }
            merged.sort { $0.timestamp > $1.timestamp }
            // 防止超大日志文件拖慢内存与后续分页；按时间倒序截断到最近 5000 条。
            if merged.count > 5000 {
                merged = Array(merged.prefix(5000))
            }
            let result = merged

            await MainActor.run {
                guard let self else { return }
                self.entries = result
                // 数据收缩后 clamp 当前页，避免落在空页。
                if self.currentPage > self.totalPages {
                    self.currentPage = self.totalPages
                }
                self.isLoading = false
            }
        }
    }

    public func clearFilters() {
        activeSourceFilter = .all
        activeLevelFilter = .all
        selectedSources.removeAll()
        selectedLevels.removeAll()
        searchText = ""
        isAutoTail = true
    }

    // MARK: - 解析

    nonisolated private static func parse(text: String, source: GatewayLogSource, file: String) -> [GatewayLogEntry] {
        var entries: [GatewayLogEntry] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let pattern = try? NSRegularExpression(pattern: #"^\[(\d+)\]\s?(.*)$"#)

        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if let match = pattern?.firstMatch(
                in: line,
                options: [],
                range: NSRange(line.startIndex..., in: line)
            ),
               let tsRange = Range(match.range(at: 1), in: line),
               let msgRange = Range(match.range(at: 2), in: line),
               let epoch = TimeInterval(line[tsRange]) {
                let message = String(line[msgRange])
                let entry = GatewayLogEntry(
                    source: source,
                    timestamp: Date(timeIntervalSince1970: epoch),
                    level: inferLevel(message),
                    message: message,
                    file: file,
                    lineNumber: index
                )
                entries.append(entry)
            } else if var last = entries.popLast() {
                // 无时间戳的行（异常堆栈续行）追加到前一条日志。
                last.message += "\n" + line
                entries.append(last)
            }
        }
        return entries
    }

    nonisolated private static func inferLevel(_ message: String) -> GatewayLogLevel {
        let lower = message.lowercased()
        let errorKeys = [
            "error", "fail", "失败", "无法", "意外退出", "不再监听",
            "conn refused", "couldn't connect", "connection timeout",
            "address already in use", "addrinuse", "端口占用", "端口冲突",
            "blocked", "upstream", "ssl connection", "错误", "401", "400",
            "403", "429", "502", "503", "refused",
        ]
        for key in errorKeys where lower.contains(key) {
            return .error
        }
        let warnKeys = ["warning", "warn", "重试", "恢复", "正在恢复", "清理", "stale", "conflict", "占用"]
        for key in warnKeys where lower.contains(key) {
            return .warn
        }
        return .info
    }
}
