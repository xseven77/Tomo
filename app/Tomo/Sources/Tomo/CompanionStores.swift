import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class PetFrameStore {
    private let player = PetAnimationPlayer()
    private(set) var currentFrame: NSImage?
    private(set) var selectedPet: CodexPet?
    private(set) var activityState: CodexActivityState = .unavailable
    private var lastInteractionAction: PetAnimationState?
    var onFrameChanged: (() -> Void)?

    init() {
        player.onFrame = { [weak self] image in
            guard let self else { return }
            currentFrame = image
            onFrameChanged?()
        }
    }

    func update(pet: CodexPet?, activityState: CodexActivityState) {
        selectedPet = pet
        self.activityState = activityState
        player.setPet(pet)
        guard !player.isPlayingOneShot else { return }
        player.setState(activityState.petAnimationState)
    }

    var canPlayIdleInteraction: Bool {
        selectedPet != nil
    }

    @discardableResult
    func playRandomIdleAction() -> PetAnimationState? {
        guard canPlayIdleInteraction else { return nil }
        let candidates = PetAnimationState.idleInteractionCandidates.filter {
            $0 != lastInteractionAction
        }
        guard let action = candidates.randomElement()
            ?? PetAnimationState.idleInteractionCandidates.randomElement() else {
            return nil
        }
        lastInteractionAction = action
        player.playOneShot(action) { [weak self] in
            guard let self else { return }
            player.setState(activityState.petAnimationState)
        }
        return action
    }

    func stop() {
        player.stop()
    }
}

@MainActor
@Observable
final class CompanionStatsStore {
    private struct DayRecord: Codable {
        var accumulatedSeconds: TimeInterval
        var perAgentSeconds: [String: TimeInterval]
    }

    private struct Record: Codable {
        var localDay: String
        var accumulatedSeconds: TimeInterval
        var perAgentSeconds: [String: TimeInterval]?
        var activeSince: Date?
        var activeAgent: String?
        var lastPersistedAt: Date
        var dailyHistory: [String: DayRecord] = [:]
    }

    private let fileURL: URL
    private let calendar: Calendar
    private var record: Record
    private var timer: Timer?

    var onMinutesChanged: (() -> Void)?

    private(set) var todaySeconds: TimeInterval = 0 {
        didSet {
            if Int(oldValue / 60) != Int(todaySeconds / 60) { onMinutesChanged?() }
        }
    }

    var todayMinutes: Int {
        Int(todaySeconds / 60)
    }

    init(fileURL: URL? = nil, now: Date = Date(), calendar: Calendar = .current) {
        self.calendar = calendar
        self.fileURL = fileURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("Tomo", isDirectory: true)
            .appendingPathComponent("companion_stats.json")

        let day = Self.dayKey(for: now, calendar: calendar)
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder.tomo.decode(Record.self, from: data) {
            if decoded.localDay == day {
                record = decoded
                let recordedSum = (record.perAgentSeconds ?? [:]).values.reduce(0, +)
                if record.accumulatedSeconds > recordedSum {
                    let diff = record.accumulatedSeconds - recordedSum
                    var map = record.perAgentSeconds ?? [:]
                    map["antigravity", default: 0] += diff
                    record.perAgentSeconds = map
                }
            } else {
                // 跨日冷启动：先把上一天的记录归档进每日历史，再开新的一天
                var history = decoded.dailyHistory
                history[decoded.localDay] = DayRecord(
                    accumulatedSeconds: decoded.accumulatedSeconds,
                    perAgentSeconds: decoded.perAgentSeconds ?? [:]
                )
                history = Self.trim(history)
                record = Record(
                    localDay: day,
                    accumulatedSeconds: 0,
                    perAgentSeconds: [:],
                    activeSince: nil,
                    activeAgent: nil,
                    lastPersistedAt: now,
                    dailyHistory: history
                )
            }
        } else {
            record = Record(
                localDay: day,
                accumulatedSeconds: 0,
                perAgentSeconds: [:],
                activeSince: nil,
                activeAgent: nil,
                lastPersistedAt: now
            )
        }
        todaySeconds = record.accumulatedSeconds
    }

    func start() {
        stop(settle: false)
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }

    func setActivityState(_ state: CodexActivityState, agentID: String? = nil, now: Date = Date()) {
        settle(now: now)
        if state.isCompanionActive {
            record.activeSince = now
            if let agentID {
                record.activeAgent = agentID
            }
        } else {
            record.activeSince = nil
            record.activeAgent = nil
        }
        persist(now: now)
    }

    func tick(now: Date = Date()) {
        settle(now: now)
        persist(now: now)
    }

    func stop(now: Date = Date(), settle: Bool = true) {
        timer?.invalidate()
        timer = nil
        if settle {
            self.settle(now: now)
            record.activeSince = nil
            record.activeAgent = nil
            persist(now: now)
        }
    }

    func seconds(for agentID: String) -> TimeInterval {
        let agentSecs = record.perAgentSeconds?[agentID] ?? 0
        let recordedSum = (record.perAgentSeconds ?? [:]).values.reduce(0, +)
        let unassigned = max(0, record.accumulatedSeconds - recordedSum)

        if agentID == "antigravity" {
            let otherSecs = (record.perAgentSeconds ?? [:]).filter { $0.key != "antigravity" }.values.reduce(0, +)
            if otherSecs == 0 {
                return max(agentSecs, record.accumulatedSeconds)
            } else {
                return agentSecs + unassigned
            }
        }
        return agentSecs
    }

    private func settle(now: Date) {
        let day = Self.dayKey(for: now, calendar: calendar)
        if record.localDay != day {
            // 跨日：把当天累积值归档进每日历史，再开新的一天
            var history = record.dailyHistory
            history[record.localDay] = DayRecord(
                accumulatedSeconds: record.accumulatedSeconds,
                perAgentSeconds: record.perAgentSeconds ?? [:]
            )
            history = Self.trim(history)
            record = Record(
                localDay: day,
                accumulatedSeconds: 0,
                perAgentSeconds: [:],
                activeSince: record.activeSince == nil ? nil : now,
                activeAgent: record.activeSince == nil ? nil : record.activeAgent,
                lastPersistedAt: now,
                dailyHistory: history
            )
        } else if let activeSince = record.activeSince {
            // A regular heartbeat is 30 seconds. Cap a single interval so a
            // sleeping Mac cannot inflate the daily companion total.
            let increment = min(max(now.timeIntervalSince(activeSince), 0), 90)
            record.accumulatedSeconds += increment
            let agent = record.activeAgent ?? "antigravity"
            var agentMap = record.perAgentSeconds ?? [:]
            agentMap[agent, default: 0] += increment
            record.perAgentSeconds = agentMap
            record.activeSince = now
        }
        todaySeconds = record.accumulatedSeconds
    }

    private func persist(now: Date) {
        record.lastPersistedAt = now
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder.tomo.encode(record)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Companion stats are optional and must not affect core usage UI.
        }
    }

    private static func trim(_ history: [String: DayRecord]) -> [String: DayRecord] {
        // 只保留最近 92 天，避免文件无限膨胀
        let keys = history.keys.sorted()
        if keys.count <= 92 { return history }
        var trimmed = history
        for k in keys.prefix(keys.count - 92) { trimmed.removeValue(forKey: k) }
        return trimmed
    }

    /// 过去 `days` 天（含今天）内，每个 Agent 每天的工作秒数，按天升序。
    /// history 不含今天，今天用当前累积值补齐；当天无记录的 Agent 记为 0。
    func dailyAgentSeconds(days: Int, now: Date = Date()) -> [(day: String, agent: String, seconds: TimeInterval)] {
        // 生成最近 days 天的 dayKey 序列（含今天）
        var dayKeys: [String] = []
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.calendar = calendar
        df.locale = Locale(identifier: "en_US_POSIX")
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let dt = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            dayKeys.append(df.string(from: dt))
        }

        let todayKey = dayKeys.last ?? Self.dayKey(for: now, calendar: calendar)
        let agents = ["antigravity", "codex", "dsh", "hermes", "pi"]
        var out: [(day: String, agent: String, seconds: TimeInterval)] = []

        for day in dayKeys {
            let isToday = day == todayKey
            let dayRecord: DayRecord? = isToday
                ? DayRecord(accumulatedSeconds: record.accumulatedSeconds, perAgentSeconds: record.perAgentSeconds ?? [:])
                : record.dailyHistory[day]
            for a in agents {
                let s = dayRecord?.perAgentSeconds[a] ?? (isToday ? seconds(for: a) : 0)
                out.append((day, a, s))
            }
        }
        return out
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

private extension CodexActivityState {
    var isCompanionActive: Bool {
        switch self {
        case .thinking, .executing, .reviewing, .waitingForUser:
            true
        default:
            false
        }
    }
}

private extension JSONEncoder {
    static var tomo: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var tomo: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
