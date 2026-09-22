import CZSTD
import Foundation

/// 读取 Deepseek Harness 的会话日志（`~/.dsh/sessions/<workspace>/<session>/session.vN.jsonl.zstd`），
/// 把最近会话的事件映射成 Codex 活动快照。DSH 会话是 zstd 压缩的 JSONL，逐帧追加写入，
/// 这里只解压末尾少量帧来推断当前状态，避免每次解压整份日志。
///
/// 日志名带 DSH 的**会话格式 generation**：v0 沿用 `session.jsonl`，其后每一代在
/// `.jsonl` 前插入小写 `.vN`（当前为 `session.v3.jsonl.zstd`）。DSH 自己的运行时按
/// “数值最高的 generation”选择日志，本服务必须用同一规则发现文件：写死某个文件名会在
/// DSH 换代后静默只看到已停写的旧会话，表现为「DSH 明明有任务，App 却一直空闲」。
struct DSHActivityService: Sendable {
    let sessionsRoot: URL

    init(
        sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/sessions", isDirectory: true)
    ) {
        self.sessionsRoot = sessionsRoot
    }

    /// 判定一个 session 文件是否仍在活跃（最近 3 分钟内有过写入）。
    static let activeWindow: TimeInterval = 180

    func loadSnapshot(now: Date = Date()) -> CodexActivitySnapshot {
        guard let latest = latestSessionFile(now: now) else {
            return .unavailable
        }
        guard now.timeIntervalSince(latest.modifiedAt) < Self.activeWindow else {
            return CodexActivitySnapshot(
                state: .idle,
                detail: "Deepseek Harness 当前空闲",
                threadTitle: nil,
                activeTaskCount: 0,
                updatedAt: now
            )
        }

        // 头部帧抓取 session/title 与首条消息（用于标题），尾部帧推断当前状态。
        let headEvents = decompressedHeadText(of: latest.url).map(parseEvents) ?? []
        let tailEvents = decompressedTailText(of: latest.url).map(parseEvents) ?? []
        let events = headEvents + tailEvents
        guard let last = tailEvents.last ?? headEvents.last else {
            return .unavailable
        }

        let state = state(for: events)
        let title = sessionTitle(from: events, fallback: latest.sessionID)
        let detail = detail(for: state)
        return CodexActivitySnapshot(
            state: state,
            detail: detail,
            threadTitle: title,
            activeTaskCount: state == .idle ? 0 : 1,
            updatedAt: last.time,
            activeTasks: state == .idle ? [] : [
                CodexTaskActivity(
                    id: "dsh:\(latest.sessionID)",
                    state: state,
                    detail: detail,
                    title: "Deepseek Harness",
                    updatedAt: last.time,
                    model: "Deepseek Harness"
                )
            ]
        )
    }

    // MARK: - Session discovery

    struct SessionFile {
        let url: URL
        let sessionID: String
        let modifiedAt: Date
        /// DSH 会话格式 generation：0 = `session.jsonl`，N = `session.vN.jsonl`。
        let formatVersion: Int
    }

    /// 解析一份 DSH 会话日志的文件名，返回它的 generation。
    ///
    /// 规范名由 DSH 自己生成（`sessionFormatLogFilename`）：v0 是 `session.jsonl`，
    /// 其后每代在 `.jsonl` 前插入小写 `.vN`；压缩后缀为 `.zstd` 或空。其他文件
    /// （`session.lock`、迁移临时文件等）返回 nil。
    static func logGeneration(ofFileName name: String) -> Int? {
        let stem: String
        if name.hasSuffix(".jsonl.zstd") {
            stem = String(name.dropLast(".jsonl.zstd".count))
        } else if name.hasSuffix(".jsonl") {
            stem = String(name.dropLast(".jsonl".count))
        } else {
            return nil
        }
        if stem == "session" { return 0 }
        guard stem.hasPrefix("session.v") else { return nil }
        let digits = stem.dropFirst("session.v".count)
        guard !digits.isEmpty,
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let version = Int(digits),
              // 拒绝 `v01` 这类非规范名，避免与 DSH 的选择规则分叉。
              String(version) == digits
        else { return nil }
        return version
    }

    /// 一个会话目录中数值最高的那一代日志。
    ///
    /// 格式迁移可能在同目录留下旧代与新代两份文件；只有最高代记录着会话的当前内容。
    /// 同一代同时存在压缩与未压缩两份是 DSH 明令禁止的（一个 root 只属于一种编码），
    /// 真遇到时优先压缩版，保证结果与遍历顺序无关。
    func sessionLogFile(in sessionDir: URL) -> (url: URL, formatVersion: Int, modifiedAt: Date)? {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: sessionDir,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var best: (url: URL, formatVersion: Int, modifiedAt: Date)?
        for entry in entries {
            guard let version = Self.logGeneration(ofFileName: entry.lastPathComponent) else { continue }
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard let current = best else {
                best = (entry, version, modified)
                continue
            }
            let isNewerGeneration = version > current.formatVersion
            let winsTie = version == current.formatVersion
                && entry.lastPathComponent.hasSuffix(".zstd")
                && !current.url.lastPathComponent.hasSuffix(".zstd")
            if isNewerGeneration || winsTie {
                best = (entry, version, modified)
            }
        }
        return best
    }

    func latestSessionFile(now: Date = Date()) -> SessionFile? {
        var latest: SessionFile?
        let workspaceDirs = (try? FileManager.default.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for workspace in workspaceDirs {
            let sessionDirs = (try? FileManager.default.contentsOfDirectory(
                at: workspace,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for sessionDir in sessionDirs {
                guard let log = sessionLogFile(in: sessionDir) else { continue }
                let candidate = SessionFile(
                    url: log.url,
                    sessionID: sessionDir.lastPathComponent,
                    modifiedAt: log.modifiedAt,
                    formatVersion: log.formatVersion
                )
                if latest == nil || candidate.modifiedAt > latest!.modifiedAt {
                    latest = candidate
                }
            }
        }
        return latest
    }

    func countTodaySessions(now: Date = Date(), calendar: Calendar = .current) -> Int {
        var count = 0
        let workspaceDirs = (try? FileManager.default.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for workspace in workspaceDirs {
            let sessionDirs = (try? FileManager.default.contentsOfDirectory(
                at: workspace,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for sessionDir in sessionDirs {
                guard let log = sessionLogFile(in: sessionDir) else { continue }
                if calendar.isDateInToday(log.modifiedAt) {
                    count += 1
                }
            }
        }
        return count
    }

    // MARK: - zstd tail decompression

    func decompressedTailText(of url: URL, maxFrames: Int = 64) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let tail = decompressedTail(from: data, maxFrames: maxFrames),
           let text = String(data: tail, encoding: .utf8) {
            return text
        }
        // `compression: 'none'` 的日志是纯文本行，没有 zstd 帧可解。
        return plainText(data, selecting: { Array($0.suffix(maxFrames)) })
    }

    func decompressedHeadText(of url: URL, maxFrames: Int = 32) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let head = decompressedHead(from: data, maxFrames: maxFrames),
           let text = String(data: head, encoding: .utf8) {
            return text
        }
        return plainText(data, selecting: { Array($0.prefix(maxFrames)) })
    }

    /// 未压缩日志的回退读取：按行取头/尾若干行。
    private func plainText(_ data: Data, selecting: ([String]) -> [String]) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        let selected = selecting(lines)
        return selected.isEmpty ? nil : selected.joined(separator: "\n")
    }

    func decompressedTail(from data: Data, maxFrames: Int = 64) -> Data? {
        decompressedFrames(from: data, selecting: { Array($0.suffix(maxFrames)) })
    }

    func decompressedHead(from data: Data, maxFrames: Int = 32) -> Data? {
        decompressedFrames(from: data, selecting: { Array($0.prefix(maxFrames)) })
    }

    private func decompressedFrames(
        from data: Data,
        selecting: ([Range<Int>]) -> [Range<Int>]
    ) -> Data? {
        var frameRanges: [Range<Int>] = []
        var offset = 0
        while offset < data.count {
            let remaining = data.count - offset
            let frameSize = data.withUnsafeBytes { raw -> Int in
                let src = raw.baseAddress!.advanced(by: offset)
                return Int(ZSTD_findFrameCompressedSize(src, remaining))
            }
            // ZSTD_findFrameCompressedSize 出错时返回 0；也排除越界。
            guard frameSize > 0, frameSize <= remaining else { break }
            frameRanges.append(offset..<(offset + frameSize))
            offset += frameSize
        }
        guard !frameRanges.isEmpty else { return nil }

        var result = Data()
        for range in selecting(frameRanges) {
            if let frame = decompressFrame(from: data, range: range) {
                result.append(frame)
            }
        }
        return result.isEmpty ? nil : result
    }

    private func decompressFrame(from data: Data, range: Range<Int>) -> Data? {
        let compressedSize = range.count
        let contentSize = data.withUnsafeBytes { raw -> UInt64 in
            let src = raw.baseAddress!.advanced(by: range.lowerBound)
            return ZSTD_getFrameContentSize(src, compressedSize)
        }
        let capacity: Int
        if contentSize == ZSTD_CONTENTSIZE_ERROR {
            return nil
        } else if contentSize == ZSTD_CONTENTSIZE_UNKNOWN {
            // 内容大小未知时用 8MB 兜底（DSH 帧窗口 2MB，事件很小）。
            capacity = 8 * 1024 * 1024
        } else {
            capacity = Int(contentSize)
        }

        var buffer = Data(count: capacity)
        let written = buffer.withUnsafeMutableBytes { rawDst -> Int in
            data.withUnsafeBytes { rawSrc in
                let src = rawSrc.baseAddress!.advanced(by: range.lowerBound)
                return Int(ZSTD_decompress(rawDst.baseAddress!, capacity, src, compressedSize))
            }
        }
        guard written >= 0 else { return nil }
        return buffer.prefix(written)
    }

    // MARK: - Event parsing

    struct DSHEvent {
        let type: String
        let time: Date
        let title: String?
        let messageText: String?
    }

    func parseEvents(from text: String) -> [DSHEvent] {
        var events: [DSHEvent] = []
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else {
                continue
            }
            let time = (object["time"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
            let eventData = object["data"] as? [String: Any]

            var title: String?
            var messageText: String?
            if type == "session/title" {
                title = eventData?["title"] as? String
            } else if type == "user/message", let content = eventData?["content"] as? [[String: Any]] {
                messageText = content.compactMap { $0["text"] as? String }.joined()
            } else if type == "agent/inbox/spliced", let inserted = eventData?["inserted"] as? [[String: Any]] {
                for item in inserted {
                    if let content = item["content"] as? [[String: Any]] {
                        let text = content.compactMap { $0["text"] as? String }.joined()
                        if !text.isEmpty {
                            messageText = text
                            break
                        }
                    }
                }
            }

            events.append(DSHEvent(type: type, time: time, title: title, messageText: messageText))
        }
        return events
    }

    func state(for events: [DSHEvent]) -> CodexActivityState {
        let significant = events.last { isSignificant($0.type) } ?? events.last
        guard let significant else { return .idle }

        switch significant.type {
        case "turn/end", "session/end-seed":
            return .idle
        case "tool/call", "command/run":
            return .executing
        case "tool/result", "assistant/message", "command/done":
            return .reviewing
        case "user/message", "turn/start", "step/start", "request/header", "approval/decided":
            return .thinking
        case "approval/asked":
            return .waitingForUser
        default:
            return .idle
        }
    }

    private func isSignificant(_ type: String) -> Bool {
        ![
            "assistant/chunk",
            "reasoning-chunks",
            "text-chunks",
            "tool-call-chunks",
            "session",
            "session/title",
            "session/title-llm-request",
            "permission/preset",
            "sandbox/mode",
            "approval/policy",
            "request/context",
            "agent/inbox/spliced",
            "subagent/descriptor",
            "web/deepseek-search-llm-request",
            "goal/change",
            "todo/write",
            "llm/retry",
            "llm/retry-started",
            "compaction/start",
            "compaction/summary",
            "compaction/prune",
            "compaction/end",
        ].contains(type)
    }

    func sessionTitle(from events: [DSHEvent], fallback: String) -> String {
        let title = events.reversed().compactMap(\.title).first
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        let firstMessage = events.compactMap(\.messageText).first ?? ""
        let trimmed = firstMessage
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return String(trimmed.prefix(48))
        }
        return "Deepseek Harness 会话"
    }

    private func detail(for state: CodexActivityState) -> String {
        switch state {
        case .thinking: "Deepseek Harness 正在思考"
        case .executing: "Deepseek Harness 正在执行工具"
        case .reviewing: "Deepseek Harness 正在检查结果"
        case .waitingForUser: "Deepseek Harness 等待确认"
        case .idle: "Deepseek Harness 当前空闲"
        default: "Deepseek Harness 活动中"
        }
    }
}
