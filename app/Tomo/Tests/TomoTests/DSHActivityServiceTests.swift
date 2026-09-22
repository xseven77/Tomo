import CZSTD
import XCTest
@testable import Tomo

final class DSHActivityServiceTests: XCTestCase {
    private func makeService() -> DSHActivityService {
        DSHActivityService(sessionsRoot: FileManager.default.temporaryDirectory)
    }

    func testParseEventsAndStateMapping() {
        let service = makeService()
        let events = service.parseEvents(from: """
        {"type":"session","time":1786812701838}
        {"type":"turn/start","time":1786812713323,"data":{"turn":1}}
        {"type":"user/message","time":1786812713343,"data":{"content":[{"type":"text","text":"hello"}]}}
        {"type":"session/title","time":1786812713344,"data":{"title":"My Task"}}
        {"type":"tool/call","time":1786812720000,"data":{"name":"bash"}}
        """)

        XCTAssertEqual(events.count, 5)
        XCTAssertEqual(events.map(\.type), ["session", "turn/start", "user/message", "session/title", "tool/call"])
        XCTAssertEqual(service.state(for: events), .executing)
        XCTAssertEqual(service.sessionTitle(from: events, fallback: "x"), "My Task")
    }

    func testStateIdleAfterTurnEnd() {
        let service = makeService()
        let events = service.parseEvents(from: """
        {"type":"turn/start","time":1}
        {"type":"assistant/message","time":2,"data":{"content":[]}}
        {"type":"turn/end","time":3}
        """)
        XCTAssertEqual(service.state(for: events), .idle)
    }

    func testStateThinkingAfterUserMessage() {
        let service = makeService()
        let events = service.parseEvents(from: """
        {"type":"user/message","time":1,"data":{"content":[{"type":"text","text":"hi"}]}}
        """)
        XCTAssertEqual(service.state(for: events), .thinking)
    }

    func testStateReviewingAfterAssistantMessage() {
        let service = makeService()
        let events = service.parseEvents(from: """
        {"type":"assistant/message","time":1,"data":{"content":[]}}
        """)
        XCTAssertEqual(service.state(for: events), .reviewing)
    }

    func testStateWaitingForUserAfterApprovalAsked() {
        let service = makeService()
        let events = service.parseEvents(from: """
        {"type":"tool/call","time":1,"data":{"name":"bash"}}
        {"type":"approval/asked","time":2,"data":{"toolName":"bash","reason":"escalate sandbox"}}
        """)
        XCTAssertEqual(service.state(for: events), .waitingForUser)
    }

    func testStateThinkingAfterApprovalDecided() {
        let service = makeService()
        let events = service.parseEvents(from: """
        {"type":"approval/asked","time":1}
        {"type":"approval/decided","time":2,"data":{"outcome":"allowed-once"}}
        """)
        XCTAssertEqual(service.state(for: events), .thinking)
    }

    func testMetadataEventsDoNotOverrideState() {
        let service = makeService()
        // 会话结束后追加的元数据事件不应把状态从 idle 改成别的，也不该误判为活跃。
        let events = service.parseEvents(from: """
        {"type":"tool/call","time":1}
        {"type":"tool/result","time":2}
        {"type":"turn/end","time":3}
        {"type":"goal/change","time":4,"data":{"operation":"complete"}}
        {"type":"compaction/prune","time":5}
        {"type":"session/end-seed","time":6,"data":{}}
        """)
        XCTAssertEqual(service.state(for: events), .idle)
    }

    func testCommandRunMapsToExecuting() {
        let service = makeService()
        let events = service.parseEvents(from: """
        {"type":"command/run","time":1,"data":{}}
        """)
        XCTAssertEqual(service.state(for: events), .executing)
    }

    func testSessionTitleFallsBackToFirstMessage() {
        let service = makeService()
        let events = service.parseEvents(from: """
        {"type":"user/message","time":1,"data":{"content":[{"type":"text","text":"帮我修一下这个 bug"}]}}
        {"type":"tool/call","time":2}
        """)
        let title = service.sessionTitle(from: events, fallback: "fallback")
        XCTAssertEqual(title, "帮我修一下这个 bug")
    }

    func testDecompressedTailRoundTrip() {
        let service = makeService()
        let events = (1...10).map { "{\"type\":\"event\",\"n\":\($0)}" }
        var compressed = Data()
        for event in events {
            compressed.append(zstdCompress(Data((event + "\n").utf8)))
        }

        let tail = service.decompressedTail(from: compressed, maxFrames: 3)
        let text = String(data: tail ?? Data(), encoding: .utf8) ?? ""

        // 用带 `}` 的完整键值避免 "n":1 误匹配 "n":10。
        XCTAssertTrue(text.contains("\"n\":8}"))
        XCTAssertTrue(text.contains("\"n\":9}"))
        XCTAssertTrue(text.contains("\"n\":10}"))
        XCTAssertFalse(text.contains("\"n\":1}"))
        XCTAssertFalse(text.contains("\"n\":7}"))
    }

    func testDecompressedHeadRoundTrip() {
        let service = makeService()
        let events = (1...10).map { "{\"type\":\"event\",\"n\":\($0)}" }
        var compressed = Data()
        for event in events {
            compressed.append(zstdCompress(Data((event + "\n").utf8)))
        }

        let head = service.decompressedHead(from: compressed, maxFrames: 3)
        let text = String(data: head ?? Data(), encoding: .utf8) ?? ""

        XCTAssertTrue(text.contains("\"n\":1}"))
        XCTAssertTrue(text.contains("\"n\":2}"))
        XCTAssertTrue(text.contains("\"n\":3}"))
        XCTAssertFalse(text.contains("\"n\":4}"))
        XCTAssertFalse(text.contains("\"n\":10}"))
    }

    // MARK: - DSH 会话格式 generation 感知的发现逻辑

    func testLogGenerationParsing() {
        // v0 沿用裸名；v1+ 带 `.vN`；压缩后缀可选。
        XCTAssertEqual(DSHActivityService.logGeneration(ofFileName: "session.jsonl.zstd"), 0)
        XCTAssertEqual(DSHActivityService.logGeneration(ofFileName: "session.jsonl"), 0)
        XCTAssertEqual(DSHActivityService.logGeneration(ofFileName: "session.v1.jsonl.zstd"), 1)
        XCTAssertEqual(DSHActivityService.logGeneration(ofFileName: "session.v2.jsonl"), 2)
        XCTAssertEqual(DSHActivityService.logGeneration(ofFileName: "session.v3.jsonl.zstd"), 3)
        XCTAssertEqual(DSHActivityService.logGeneration(ofFileName: "session.v10.jsonl.zstd"), 10)

        // 非日志文件、非规范名不得被当成某一代。
        XCTAssertNil(DSHActivityService.logGeneration(ofFileName: "session.lock"))
        XCTAssertNil(DSHActivityService.logGeneration(ofFileName: "session.v01.jsonl.zstd"))
        XCTAssertNil(DSHActivityService.logGeneration(ofFileName: "session.v.jsonl.zstd"))
        XCTAssertNil(DSHActivityService.logGeneration(ofFileName: "session.vX.jsonl.zstd"))
        XCTAssertNil(DSHActivityService.logGeneration(ofFileName: "other.jsonl.zstd"))
        XCTAssertNil(DSHActivityService.logGeneration(ofFileName: "session.v3.jsonl.zstd.tmp"))
    }

    func testSessionLogFilePicksHighestGeneration() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = DSHActivityService(sessionsRoot: root)

        let workspace = root.appendingPathComponent("--Users-me-proj--")
        let sessionDir = workspace.appendingPathComponent("session-1")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        // 迁移后的目录可能同时留有旧代与新代，必须读最高代。
        try Data("v0\n".utf8).write(to: sessionDir.appendingPathComponent("session.jsonl.zstd"))
        try Data("v3\n".utf8).write(to: sessionDir.appendingPathComponent("session.v3.jsonl.zstd"))
        try Data("v1\n".utf8).write(to: sessionDir.appendingPathComponent("session.v1.jsonl.zstd"))
        try Data().write(to: sessionDir.appendingPathComponent("session.lock"))

        let log = try XCTUnwrap(service.sessionLogFile(in: sessionDir))
        XCTAssertEqual(log.formatVersion, 3)
        XCTAssertEqual(log.url.lastPathComponent, "session.v3.jsonl.zstd")
    }

    func testLatestSessionFileFindsVersionedLogsOnlyWorkspace() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = DSHActivityService(sessionsRoot: root)

        // 复现线上形态：旧 workspace 只剩停写的 v0，新会话全部是 v3。
        let oldDir = root
            .appendingPathComponent("--Users-me-old--")
            .appendingPathComponent("session-old")
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try Data("old\n".utf8).write(to: oldDir.appendingPathComponent("session.jsonl.zstd"))

        let newDir = root
            .appendingPathComponent("--Users-me-new--")
            .appendingPathComponent("session-new")
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        let newLog = newDir.appendingPathComponent("session.v3.jsonl.zstd")
        try Data("new\n".utf8).write(to: newLog)

        let latest = try XCTUnwrap(service.latestSessionFile())
        XCTAssertEqual(latest.sessionID, "session-new")
        XCTAssertEqual(latest.formatVersion, 3)
        XCTAssertEqual(latest.url.lastPathComponent, "session.v3.jsonl.zstd")
    }

    func testLoadSnapshotReadsVersionedCompressedLog() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = DSHActivityService(sessionsRoot: root)

        // 只有 v3 日志的 workspace：修复前这里恒为 .unavailable。
        let sessionDir = root
            .appendingPathComponent("--Users-me-proj--")
            .appendingPathComponent("session-live")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let log = sessionDir.appendingPathComponent("session.v3.jsonl.zstd")
        try writeFrames(to: log, lines: [
            #"{"type":"session","time":1}"#,
            #"{"type":"user/message","time":2,"data":{"content":[{"type":"text","text":"hi"}]}}"#,
            #"{"type":"tool/call","time":3,"data":{"name":"bash"}}"#,
        ])

        let snapshot = service.loadSnapshot(now: Date())
        XCTAssertEqual(snapshot.state, .executing)
        XCTAssertEqual(snapshot.activeTaskCount, 1)
        XCTAssertEqual(snapshot.activeTasks.first?.id, "dsh:session-live")
    }

    func testLoadSnapshotReadsUncompressedLog() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = DSHActivityService(sessionsRoot: root)

        // `compression: 'none'` 时日志是纯文本行。
        let sessionDir = root
            .appendingPathComponent("--Users-me-proj--")
            .appendingPathComponent("session-raw")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let body = """
        {"type":"user/message","time":1,"data":{"content":[{"type":"text","text":"hi"}]}}
        {"type":"tool/call","time":2,"data":{"name":"bash"}}

        """
        try Data(body.utf8).write(to: sessionDir.appendingPathComponent("session.v3.jsonl"))

        let snapshot = service.loadSnapshot(now: Date())
        XCTAssertEqual(snapshot.state, .executing)
        XCTAssertEqual(snapshot.activeTasks.first?.id, "dsh:session-raw")
    }

    func testCountTodaySessionsIncludesVersionedLogs() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = DSHActivityService(sessionsRoot: root)

        let workspace = root.appendingPathComponent("--Users-me-proj--")
        for (name, log) in [("session-a", "session.v3.jsonl.zstd"), ("session-b", "session.jsonl.zstd")] {
            let dir = workspace.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x\n".utf8).write(to: dir.appendingPathComponent(log))
        }

        XCTAssertEqual(service.countTodaySessions(now: Date()), 2)
    }

    // MARK: - Helpers

    /// 每个用例独立的临时根目录，避免 `latestSessionFile` 扫到 /tmp 下的无关目录。
    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-activity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// 按行写入 zstd 帧（与 DSH 的逐帧追加写入一致）。
    private func writeFrames(to url: URL, lines: [String]) throws {
        var compressed = Data()
        for line in lines {
            compressed.append(zstdCompress(Data((line + "\n").utf8)))
        }
        try compressed.write(to: url)
    }

    private func zstdCompress(_ data: Data) -> Data {
        let bound = ZSTD_compressBound(data.count)
        var dst = Data(count: Int(bound))
        let written = data.withUnsafeBytes { src in
            dst.withUnsafeMutableBytes { dstBuf in
                Int(ZSTD_compress(
                    dstBuf.baseAddress!,
                    Int(bound),
                    src.baseAddress!,
                    data.count,
                    1
                ))
            }
        }
        return dst.prefix(written)
    }
}
