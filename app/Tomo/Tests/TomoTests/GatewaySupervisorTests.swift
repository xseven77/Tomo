import XCTest
@testable import Tomo

/// Stands in for `Task.sleep` in `GatewaySupervisor`: a delay stays pending
/// until the test calls `advance()`, so a scheduled recovery runs exactly when
/// the test says and no test waits on the wall clock.
@MainActor
private final class GatewayTestClock {
    private var pendingDelays: [CheckedContinuation<Void, Never>] = []
    private var delayWaiters: [CheckedContinuation<Void, Never>] = []

    func delay(_ duration: Duration) async {
        // Like `Task.sleep`, a cancelled task does not wait.
        guard !Task.isCancelled else { return }
        await withCheckedContinuation { continuation in
            pendingDelays.append(continuation)
            let waiters = delayWaiters
            delayWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    /// Returns once a scheduled task is waiting out its delay.
    func waitForPendingDelay() async {
        guard pendingDelays.isEmpty else { return }
        await withCheckedContinuation { delayWaiters.append($0) }
    }

    /// Ends every pending delay, as if its duration had passed.
    func advance() {
        let due = pendingDelays
        pendingDelays.removeAll()
        due.forEach { $0.resume() }
    }
}

/// Stands in for the `/status` request that asks whether a Gateway left on the
/// port is healthy: it stays pending until the test answers, and nothing is
/// sent to the port.
@MainActor
private final class GatewayProbeStub {
    private var pendingProbes: [CheckedContinuation<Bool, Never>] = []
    private var probeWaiters: [CheckedContinuation<Void, Never>] = []

    func probe(_ request: URLRequest) async -> Bool {
        // Like URLSession, a cancelled request fails without waiting.
        guard !Task.isCancelled else { return false }
        return await withCheckedContinuation { continuation in
            pendingProbes.append(continuation)
            let waiters = probeWaiters
            probeWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    /// Returns once the supervisor is waiting for an answer.
    func waitForProbe() async {
        guard pendingProbes.isEmpty else { return }
        await withCheckedContinuation { probeWaiters.append($0) }
    }

    func answer(healthy: Bool) {
        let probes = pendingProbes
        pendingProbes.removeAll()
        probes.forEach { $0.resume(returning: healthy) }
    }
}

/// A supervisor built like `shared` (tests have no helper, so it starts in
/// mock loopback mode), with a hand-driven clock, a stubbed status probe and a
/// temporary diagnostic log instead of the user's.
@MainActor
private struct SupervisorFixture {
    let clock = GatewayTestClock()
    let probe = GatewayProbeStub()
    let logURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("gateway-supervisor-test-\(UUID().uuidString).log")
    /// The supervisor reads its token and LAN setting here, never from the
    /// user's gateway-settings.json (a missing file would also be rewritten).
    let settingsURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("gateway-supervisor-settings-test-\(UUID().uuidString).json")
    let supervisor: GatewaySupervisor

    /// `requiresHelper` makes it behave like the packaged App, which reports a
    /// missing helper instead of emulating the Gateway.
    init(requiresHelper: Bool = false) {
        let clock = clock, probe = probe
        supervisor = GatewaySupervisor(
            reachesLoopbackGateway: false,
            settingsStorage: GatewaySettingsStorage(fileURL: settingsURL),
            requiresHelper: requiresHelper,
            delay: { await clock.delay($0) },
            probeStatus: { await probe.probe($0) },
            diagnosticLogURL: logURL
        )
        XCTAssertNil(supervisor.requestEndpoint, "单元测试不得访问本机正在运行的 Gateway")
    }

    var diagnosticLog: String {
        (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    }

    /// The state after a healthy Gateway left by an earlier App instance was
    /// adopted: running, with no local `process`.
    func adoptGateway() {
        supervisor.stop()
        supervisor.adoptHealthyGateway()
        XCTAssertTrue(supervisor.isRunning)
    }

    /// What a launch does when its helper cannot bind the port: probe the
    /// Gateway already listening there. Returns the pending probe.
    func probeLeftGateway() async throws -> Task<Void, Never> {
        supervisor.stop()
        supervisor.adoptExistingGatewayOrScheduleRecovery()
        let probeTask = try XCTUnwrap(supervisor.pendingRestartTask, "应在等待探测结果")
        await probe.waitForProbe()
        return probeTask
    }

    func tearDown() {
        supervisor.stop()
        // Lets a cancelled recovery or probe that is still waiting finish.
        clock.advance()
        probe.answer(healthy: false)
        try? FileManager.default.removeItem(at: logURL)
        try? FileManager.default.removeItem(at: settingsURL)
    }
}

@MainActor
final class GatewaySupervisorTests: XCTestCase {
    func testMockLoopbackIgnoresRefusedHealthCheck() {
        let fixture = SupervisorFixture()
        defer { fixture.tearDown() }
        let supervisor = fixture.supervisor
        XCTAssertTrue(supervisor.isRunning)
        XCTAssertEqual(supervisor.statusText, "运行中")

        // What `/status` reports when nothing listens on the port, as for a
        // running App whose helper binary was deleted.
        supervisor.recordGatewayHealthFailure(URLError(.cannotConnectToHost))

        XCTAssertTrue(supervisor.isRunning, "模拟模式本来就没有 Gateway 在监听，连接被拒不代表 Gateway 消失")
        XCTAssertEqual(supervisor.statusText, "运行中")
        XCTAssertNil(supervisor.pendingRestartTask, "模拟模式不应安排恢复")
        XCTAssertEqual(fixture.diagnosticLog, "", "模拟模式不应写「Gateway 不再监听」日志")
    }

    func testAdoptedGatewayRefusalStillTriggersRecovery() async throws {
        let fixture = SupervisorFixture()
        defer { fixture.tearDown() }
        let supervisor = fixture.supervisor
        fixture.adoptGateway()

        supervisor.recordGatewayHealthFailure(URLError(.cannotConnectToHost))

        XCTAssertFalse(supervisor.isRunning)
        XCTAssertEqual(supervisor.statusText, "正在恢复 Gateway")
        XCTAssertTrue(fixture.diagnosticLog.contains("已连接的 Gateway 不再监听本地端口。"))
        let recovery = try XCTUnwrap(supervisor.pendingRestartTask, "接管的 Gateway 消失后应安排恢复")

        await fixture.clock.waitForPendingDelay()
        XCTAssertFalse(supervisor.isRunning, "恢复要等延迟结束")
        fixture.clock.advance()
        await recovery.value

        // Tests have no helper, so the recovery falls back to mock loopback.
        XCTAssertTrue(supervisor.isRunning)
        XCTAssertEqual(supervisor.statusText, "运行中")
        XCTAssertNil(supervisor.pendingRestartTask)
    }

    func testStopDuringRecoveryCancelsRecovery() async throws {
        let fixture = SupervisorFixture()
        defer { fixture.tearDown() }
        let supervisor = fixture.supervisor
        fixture.adoptGateway()
        supervisor.recordGatewayHealthFailure(URLError(.cannotConnectToHost))
        XCTAssertEqual(supervisor.statusText, "正在恢复 Gateway")
        let recovery = try XCTUnwrap(supervisor.pendingRestartTask)
        await fixture.clock.waitForPendingDelay()

        supervisor.stop()

        XCTAssertFalse(supervisor.isRunning)
        XCTAssertEqual(supervisor.statusText, "已停止")
        XCTAssertNil(supervisor.pendingRestartTask)

        fixture.clock.advance()
        await recovery.value
        XCTAssertFalse(supervisor.isRunning, "停止后，待执行的恢复不应再启动 Gateway")
        XCTAssertEqual(supervisor.statusText, "已停止")

        // The cancelled recovery must not block the next one.
        supervisor.adoptHealthyGateway()
        supervisor.recordGatewayHealthFailure(URLError(.cannotConnectToHost))
        XCTAssertEqual(supervisor.statusText, "正在恢复 Gateway")
        XCTAssertNotNil(supervisor.pendingRestartTask, "取消过一次恢复后，之后的恢复仍应能安排")
    }

    func testHealthyLeftGatewayIsAdopted() async throws {
        let fixture = SupervisorFixture()
        defer { fixture.tearDown() }
        let supervisor = fixture.supervisor
        let probe = try await fixture.probeLeftGateway()

        fixture.probe.answer(healthy: true)
        await probe.value

        XCTAssertTrue(supervisor.isRunning)
        XCTAssertEqual(supervisor.statusText, "运行中")
        XCTAssertTrue(supervisor.statusDetail.hasPrefix("已连接现有本地 Gateway"))
        XCTAssertNil(supervisor.pendingRestartTask)
        // Adopted rather than mock loopback: losing its listener means recovery.
        supervisor.recordGatewayHealthFailure(URLError(.cannotConnectToHost))
        XCTAssertEqual(supervisor.statusText, "正在恢复 Gateway")
    }

    func testUnhealthyLeftGatewaySchedulesRecovery() async throws {
        let fixture = SupervisorFixture()
        defer { fixture.tearDown() }
        let supervisor = fixture.supervisor
        let probe = try await fixture.probeLeftGateway()

        fixture.probe.answer(healthy: false)
        await probe.value

        XCTAssertFalse(supervisor.isRunning)
        XCTAssertEqual(supervisor.statusText, "正在恢复 Gateway")
        XCTAssertTrue(fixture.diagnosticLog.contains("Gateway 端口占用且无法接管"))
        XCTAssertNotNil(supervisor.pendingRestartTask, "无法接管时应安排恢复")
    }

    func testStopWhileProbingLeftGatewayDiscardsTheAnswer() async throws {
        let fixture = SupervisorFixture()
        defer { fixture.tearDown() }
        let supervisor = fixture.supervisor
        let probe = try await fixture.probeLeftGateway()

        supervisor.stop()
        XCTAssertNil(supervisor.pendingRestartTask)

        // The answer arrives after the stop, as from a restart() mid-probe.
        fixture.probe.answer(healthy: true)
        await probe.value

        XCTAssertFalse(supervisor.isRunning, "停止后，迟到的探测结果不应接管 Gateway")
        XCTAssertEqual(supervisor.statusText, "已停止")
        XCTAssertNil(supervisor.pendingRestartTask)
    }

    func testPackagedAppReportsMissingHelperInsteadOfEmulating() {
        // Tests never find a helper, and init has already called start().
        let fixture = SupervisorFixture(requiresHelper: true)
        defer { fixture.tearDown() }
        let supervisor = fixture.supervisor

        XCTAssertFalse(supervisor.isRunning, "打包的 App 找不到 helper 时不应假装 Gateway 在运行")
        XCTAssertEqual(supervisor.statusText, "Gateway 组件缺失")
        XCTAssertTrue(supervisor.statusDetail.contains("找不到 TomoGateway"))
        XCTAssertEqual(supervisor.lastError, supervisor.statusDetail)
        XCTAssertEqual(supervisor.uptimeText, "--:--:--")
        XCTAssertNil(supervisor.pendingRestartTask, "不应安排恢复，也就不会来回切换")

        // 启动服务 looks for the helper again; the same failure is logged once.
        supervisor.toggle()
        XCTAssertFalse(supervisor.isRunning)
        XCTAssertEqual(supervisor.statusText, "Gateway 组件缺失")
        XCTAssertEqual(fixture.diagnosticLog.components(separatedBy: "找不到 TomoGateway").count, 2)
    }

    func testPackagedAppReportsHelperThatCannotLaunch() {
        let fixture = SupervisorFixture(requiresHelper: true)
        defer { fixture.tearDown() }
        let supervisor = fixture.supervisor

        supervisor.startChildProcess(at: Self.nonexistentHelperURL)

        XCTAssertFalse(supervisor.isRunning)
        XCTAssertEqual(supervisor.statusText, "Gateway 组件无法启动")
        XCTAssertTrue(supervisor.statusDetail.hasPrefix("TomoGateway 无法启动，请重新打包或重新安装 Tomo。原因："))
        XCTAssertNil(supervisor.pendingRestartTask)
    }

    func testDevelopmentRunStillEmulatesGatewayWhenHelperCannotLaunch() {
        let fixture = SupervisorFixture()
        defer { fixture.tearDown() }
        let supervisor = fixture.supervisor
        supervisor.stop()

        supervisor.startChildProcess(at: Self.nonexistentHelperURL)

        XCTAssertTrue(supervisor.isRunning, "swift run 等开发运行仍用模拟模式")
        XCTAssertEqual(supervisor.statusText, "运行中")
        XCTAssertNotNil(supervisor.lastError)
    }

    /// `Process.run()` fails on it before anything is launched.
    private static let nonexistentHelperURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("tomo-gateway-missing-\(UUID().uuidString)")
}
