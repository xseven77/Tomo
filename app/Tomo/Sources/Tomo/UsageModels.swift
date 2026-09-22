import Foundation
import Observation
import SwiftUI

struct UsageWindow: Codable, Equatable, Sendable {
    let label: String
    var remaining: Int
    var total: Int
    var resetsAt: String

    var percent: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(remaining) / Double(total), 0), 1)
    }

    var percentText: String {
        "\(Int((percent * 100).rounded()))%"
    }

    var amountText: String {
        "\(remaining)/\(total)"
    }
}

struct CreditBalance: Codable, Equatable, Sendable {
    var balance: Int
    var expiresAt: String
}

struct ResetCoupon: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var count: Int
    var expiresAt: String
    var source: String
    var title: String?
    var description: String?
    var grantedAt: String?
    var profileUserID: String?
    var profileImageURL: String?
    var status: String?
    var resetType: String?
}

struct CodexUsageSnapshot: Codable, Equatable, Sendable {
    var accountName: String?
    var accountEmail: String
    var workspaceName: String
    var planName: String
    /// `nil` when Codex temporarily does not expose the five-hour limit.
    var shortWindow: UsageWindow?
    var weekly: UsageWindow
    var credits: CreditBalance
    var resetCoupons: [ResetCoupon]
    var fetchedAt: Date
    var refreshState: String
    var sourceURL: String
    /// RFC3339 from `GET /backend-api/subscriptions` → `active_until`.
    var subscriptionActiveUntilISO: String?
    var subscriptionWillRenew: Bool?
}

extension CodexUsageSnapshot {
    /// The primary limit is the default status signal. When unavailable, the
    /// secondary limit is used as the fallback.
    var primaryWindow: UsageWindow {
        guard let shortWindow, shortWindow.total > 0 else { return weekly }
        return shortWindow
    }

    var hasShortWindow: Bool {
        // Older cached snapshots and a temporarily disabled API window can both
        // contain a 0/0 primary quota. Treat either as unavailable.
        (shortWindow?.total ?? 0) > 0
    }

    var hasWeeklyWindow: Bool {
        weekly.total > 0
    }

    var detailWindow: UsageWindow? {
        if hasWeeklyWindow {
            return weekly
        }
        if hasShortWindow {
            return shortWindow
        }
        return nil
    }

    var subscriptionExpiryDate: Date? {
        guard let subscriptionActiveUntilISO else { return nil }
        return UsageDateFormat.parseISO8601(subscriptionActiveUntilISO)
    }

    /// 距到期日的整天数；已过期为负数。
    var subscriptionDaysRemaining: Int? {
        guard let expiry = subscriptionExpiryDate else { return nil }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.startOfDay(for: expiry)
        return calendar.dateComponents([.day], from: start, to: end).day
    }

    var showsSubscriptionExpiryReminder: Bool {
        guard let days = subscriptionDaysRemaining else { return false }
        return days <= 7
    }

    var subscriptionSettingsExpiryLine: String? {
        guard let expiry = subscriptionExpiryDate else { return nil }
        let when = UsageDateFormat.syncTime(expiry)
        if subscriptionWillRenew == false {
            return "会员到期：\(when)"
        }
        return "当前周期至 \(when)"
    }

    var subscriptionSettingsRenewalLine: String? {
        guard subscriptionExpiryDate != nil else { return nil }
        if subscriptionWillRenew == true { return "自动续费" }
        if subscriptionWillRenew == false { return "不自动续费" }
        return nil
    }

    /// 侧栏 / 紧凑场景：日期与续费状态合并为一行。
    var subscriptionCompactSummaryLine: String? {
        guard let expiry = subscriptionExpiryDate else { return nil }
        let when = UsageDateFormat.syncTime(expiry)
        if subscriptionWillRenew == true { return "\(when) · 自动续费" }
        if subscriptionWillRenew == false { return "\(when) · 不自动续费" }
        return when
    }

    var subscriptionSettingsSubtitle: String? {
        guard let expiryLine = subscriptionSettingsExpiryLine else { return nil }
        if let renewalLine = subscriptionSettingsRenewalLine {
            return "\(expiryLine) · \(renewalLine)"
        }
        return expiryLine
    }

    var subscriptionExpiryReminderMessage: String? {
        guard showsSubscriptionExpiryReminder, let expiry = subscriptionExpiryDate else { return nil }
        let when = UsageDateFormat.syncTime(expiry)
        let plan = planName.isEmpty ? "订阅" : planName.capitalized
        if let days = subscriptionDaysRemaining, days < 0 {
            return "\(plan) 已于 \(when) 到期"
        }
        if let days = subscriptionDaysRemaining, days == 0 {
            return "\(plan) 将于今天（\(when)）到期"
        }
        if let days = subscriptionDaysRemaining {
            if subscriptionWillRenew == true {
                return "\(plan) 当前周期还有 \(days) 天结束（\(when)，将自动续费）"
            }
            return "\(plan) 还有 \(days) 天到期（\(when)）"
        }
        return "\(plan) 将于 \(when) 到期"
    }
}

@Observable
@MainActor
final class UsageSnapshotStore {
    private let cache = UsageSnapshotCache()
    private let persistsCache: Bool
    var snapshot: CodexUsageSnapshot
    var isLoggedIn: Bool
    private(set) var isUnifiedRefreshing = false
    private(set) var refreshToast: RefreshToast?
    private var refreshToastGeneration = 0

    init(
        snapshot: CodexUsageSnapshot? = nil,
        isLoggedIn: Bool? = nil,
        persistsCache: Bool = true
    ) {
        self.persistsCache = persistsCache
        self.snapshot = snapshot ?? cache.load() ?? CodexUsageSnapshot.preview
        self.isLoggedIn = isLoggedIn ?? false
    }

    func markRefreshing(allowsAuthorization: Bool) {
        snapshot.refreshState = allowsAuthorization ? "授权中" : "刷新中"
    }

    func apply(_ snapshot: CodexUsageSnapshot) {
        self.snapshot = snapshot
        isLoggedIn = true
        if persistsCache {
            cache.save(snapshot)
        }
    }

    func markDisconnected() {
        isLoggedIn = false
        snapshot.fetchedAt = Date()
        snapshot.refreshState = "已退出登录"
        snapshot.subscriptionActiveUntilISO = nil
        snapshot.subscriptionWillRenew = nil
    }

    func markAuthenticationExpired() {
        isLoggedIn = false
        snapshot.refreshState = "登录已过期，请重新授权"
    }

    func markFailed(_ message: String) {
        snapshot.refreshState = message
    }

    /// OAuth 已成功、token 已落盘，但额度抓取失败（如请求超时）。此时视为已登录，
    /// 用空态替换掉可能的 `preview` 占位数据，避免展示假的账号/额度。
    func markAuthenticated(message: String) {
        isLoggedIn = true
        if snapshot.sourceURL == "preview" {
            snapshot = .empty(refreshState: message)
        } else {
            snapshot.refreshState = message
        }
    }

    func showManualRefreshToast(for outcome: RefreshOutcome) {
        refreshToastGeneration += 1
        let generation = refreshToastGeneration
        refreshToast = RefreshToast(outcome: outcome)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            guard let self, generation == self.refreshToastGeneration else { return }
            self.refreshToast = nil
        }
    }

    func setUnifiedRefreshing(_ refreshing: Bool) {
        isUnifiedRefreshing = refreshing
    }
}

struct RefreshOutcome: Equatable, Sendable {
    var successCount = 0
    var failures: [String] = []

    mutating func merge(_ other: Self) {
        successCount += other.successCount
        failures.append(contentsOf: other.failures)
    }
}

struct RefreshToast: Equatable {
    let id = UUID()
    let message: String
    let isSuccess: Bool

    init(outcome: RefreshOutcome) {
        isSuccess = outcome.successCount > 0 && outcome.failures.isEmpty
        if isSuccess {
            message = outcome.successCount == 1
                ? "刷新成功"
                : "刷新成功 · 已更新 \(outcome.successCount) 个连接"
        } else if outcome.successCount > 0 {
            message = "部分刷新失败 · \(outcome.failures.count) 个连接"
        } else {
            message = outcome.failures.first.map { "刷新失败 · \($0)" }
                ?? "刷新失败 · 没有可刷新的连接"
        }
    }
}

struct UsageSnapshotCache {
    private var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private var fileURL: URL {
        return supportDirectory
            .appendingPathComponent("Tomo", isDirectory: true)
            .appendingPathComponent("latest_snapshot.json")
    }

    private var legacyFileURL: URL {
        supportDirectory
            .appendingPathComponent("CodexLight", isDirectory: true)
            .appendingPathComponent("latest_snapshot.json")
    }

    func load() -> CodexUsageSnapshot? {
        if let snapshot = load(from: fileURL) {
            return snapshot
        }
        if let snapshot = load(from: legacyFileURL) {
            save(snapshot)
            return snapshot
        }
        return nil
    }

    private func load(from url: URL) -> CodexUsageSnapshot? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CodexUsageSnapshot.self, from: data)
    }

    func save(_ snapshot: CodexUsageSnapshot) {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Cache failures should never block showing fresh usage data.
        }
    }
}

struct UsageActions {
    var refresh: () -> Void
    var openUsagePage: () -> Void
    var loginAndFetch: () -> Void
    var disconnect: () -> Void
    var openDetachedWindow: () -> Void
    var openGatewayWindow: (() -> Void)? = nil
    var quit: () -> Void
}

enum ChatGPTWebLinks {
    static let billingPage = URL(string: "https://chatgpt.com/#settings/Billing")!
}

enum UsageDateFormat {
    static func display(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    static func timeOnly(_ value: String) -> String {
        let parts = value.split(separator: " ")
        guard let time = parts.last else { return value }
        return String(time)
    }

    static func dateAndTime(_ value: String, now: Date = Date()) -> String {
        let input = DateFormatter()
        input.locale = Locale(identifier: "en_US_POSIX")
        input.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let date = input.date(from: value) else { return value }

        return syncTime(date, now: now)
    }

    /// 底部「上次同步」等场景：显示具体时刻，不用「刚刚」。
    static func syncTime(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "今天 HH:mm"
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            formatter.dateFormat = "M月d日 HH:mm"
        } else {
            formatter.dateFormat = "yyyy年M月d日 HH:mm"
        }
        return formatter.string(from: date)
    }

    static func parseISO8601(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) {
            return date
        }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) {
            return date
        }

        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZ",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd HH:mm:ss",
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }
}

enum QuotaHealthLevel: Equatable, Sendable {
    case gray
    case green
    case yellow
    case red

    static func from(window: UsageWindow, isLoggedIn: Bool) -> QuotaHealthLevel {
        guard isLoggedIn, window.total > 0 else { return .gray }

        switch window.percent {
        case 0.5...:
            return .green
        case 0.2..<0.5:
            return .yellow
        default:
            return .red
        }
    }

    static func from(ratio: Double?) -> QuotaHealthLevel {
        guard let ratio else { return .gray }
        switch ratio {
        case 0.5...:
            return .green
        case 0.2..<0.5:
            return .yellow
        default:
            return .red
        }
    }
}

extension QuotaHealthLevel {
    var color: Color {
        switch self {
        case .gray:
            .codexMuted
        case .green:
            .codexGreen
        case .yellow:
            .codexAmber
        case .red:
            .codexRed
        }
    }

    var nsColor: NSColor {
        switch self {
        case .gray:
            NSColor.systemGray
        case .green:
            NSColor(red: 0.157, green: 0.753, blue: 0.306, alpha: 1)
        case .yellow:
            NSColor(red: 1.000, green: 0.745, blue: 0.000, alpha: 1)
        case .red:
            NSColor(red: 1.000, green: 0.373, blue: 0.373, alpha: 1)
        }
    }

    var surfaceColors: [Color] {
        switch self {
        case .gray:
            [.codexSurface, .codexMist, .codexSurface]
        case .green:
            [.codexSurface, .codexGreen.opacity(0.10), .codexSurface]
        case .yellow:
            [.codexSurface, .codexAmber.opacity(0.12), .codexSurface]
        case .red:
            [.codexSurface, .codexRed.opacity(0.10), .codexSurface]
        }
    }
}

extension CodexUsageSnapshot {
    /// 已登录但额度尚未获取成功时的空态，避免把 `preview` 的假数据当成真实额度展示。
    static func empty(refreshState: String) -> CodexUsageSnapshot {
        CodexUsageSnapshot(
            accountName: nil,
            accountEmail: "",
            workspaceName: "",
            planName: "",
            shortWindow: nil,
            weekly: UsageWindow(label: "周额度", remaining: 0, total: 0, resetsAt: "未知"),
            credits: CreditBalance(balance: 0, expiresAt: "未知"),
            resetCoupons: [],
            fetchedAt: Date(),
            refreshState: refreshState,
            sourceURL: "",
            subscriptionActiveUntilISO: nil,
            subscriptionWillRenew: nil
        )
    }

    static let preview = CodexUsageSnapshot(
        accountName: "name",
        accountEmail: "name@example.com",
        workspaceName: "Personal",
        planName: "Plus",
        shortWindow: UsageWindow(label: "5 小时", remaining: 72, total: 100, resetsAt: "2026-07-07 18:30:00"),
        weekly: UsageWindow(label: "周额度", remaining: 410, total: 1000, resetsAt: "2026-07-14 23:59:00"),
        credits: CreditBalance(balance: 123, expiresAt: "2027-07-01 00:00:00"),
        resetCoupons: [
            ResetCoupon(
                name: "重置券", count: 1, expiresAt: "2026-07-20 00:00:00", source: "Codex Team",
                title: "Full reset",
                description: "Thanks for using Codex! You've been granted one free rate limit reset.",
                grantedAt: "2026-06-20 00:00:00",
                profileUserID: "Codex Team",
                status: "available",
                resetType: "codex_rate_limits"
            ),
            ResetCoupon(
                name: "重置券", count: 1, expiresAt: "2026-08-05 00:00:00", source: "Codex Team",
                title: "Full reset",
                grantedAt: "2026-07-05 00:00:00",
                profileUserID: "Codex Team",
                status: "available",
                resetType: "codex_rate_limits"
            ),
            ResetCoupon(name: "学生重置券", count: 1, expiresAt: "2026-09-01 00:00:00", source: "学生奖励")
        ],
        fetchedAt: Date(),
        refreshState: "预览数据",
        sourceURL: "preview"
    )
}
