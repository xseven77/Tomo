import Foundation

/// 共享的 Agent 轮播驱动器（方案 A2）。
///
/// 负责统一的「计时间隔 + 悬停暂停/续播 + 独立启停」语义，供刘海面板的
/// agent 轮播与主界面任务卡轮播复用。推进动作通过 `onTick` 回调用方各自实现，
/// 互不强耦合；调用方各自持有一个实例，可单独开关、单独 pause/resume。
@MainActor
final class AgentCarouselDriver {
    /// 统一轮播间隔，与原刘海 agent 轮播一致。
    static let tickInterval: TimeInterval = 2.8

    /// 该轮播是否启用（预留开关；关闭后不再调度，`pause`/`resume` 无效果）。
    var isEnabled: Bool {
        didSet { syncScheduling() }
    }

    private let onTick: () -> Void
    private var isPaused = false
    private var workItem: DispatchWorkItem?

    init(isEnabled: Bool = true, onTick: @escaping () -> Void) {
        self.isEnabled = isEnabled
        self.onTick = onTick
    }

    /// 开始轮播（幂等）。初始化后调用一次即可启动调度。
    func start() {
        guard !isPaused else { return }
        scheduleIfNeeded()
    }

    /// 悬停进入：暂停轮播。移开前不再推进。
    func pause() {
        guard !isPaused else { return }
        isPaused = true
        cancelScheduling()
    }

    /// 悬停移开：恢复轮播并重新计时。
    func resume() {
        guard isPaused else { return }
        isPaused = false
        scheduleIfNeeded()
    }

    /// 忽略暂停状态强制立即推进一次并重新计时（例如数据变化后想立刻同步）。
    /// 处于暂停时调用会保持暂停，仅推送一次当前 tick。
    func tickNow() {
        guard isEnabled else { return }
        cancelScheduling()
        onTick()
        scheduleIfNeeded()
    }

    /// 停止调度（如视图消失）并重置暂停态。
    func stop() {
        pause()
        isPaused = false
        cancelScheduling()
    }

    private func syncScheduling() {
        if isPaused { return }
        if isEnabled {
            scheduleIfNeeded()
        } else {
            cancelScheduling()
        }
    }

    private func scheduleIfNeeded() {
        guard isEnabled, !isPaused else { return }
        cancelScheduling()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.isEnabled, !self.isPaused else { return }
                self.onTick()
                self.scheduleIfNeeded()
            }
        }
        workItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.tickInterval,
            execute: work
        )
    }

    private func cancelScheduling() {
        workItem?.cancel()
        workItem = nil
    }
}
