import SwiftUI

struct QuotaResetTimeView: View {
    let resetsAt: String
    let resetDate: Date?
    let prefix: String
    let fallbackText: String
    let isCouponExpiry: Bool
    @AppStorage private var showsCountdown: Bool

    enum Provider { case chatGPT, gemini, resetCoupon }

    init(resetsAt: String, provider: Provider = .chatGPT, date: Date? = nil) {
        self.resetsAt = resetsAt
        self.resetDate = date ?? UsageDateFormat.parseISO8601(resetsAt)
        self.prefix = provider == .chatGPT ? "额度重置：" : ""
        self.isCouponExpiry = provider == .resetCoupon
        let key: String
        switch provider {
        case .chatGPT:
            self.fallbackText = UsageDateFormat.dateAndTime(resetsAt)
            key = "chatGPTQuotaResetShowsCountdown"
        case .gemini:
            self.fallbackText = "重置时间待更新"
            key = "geminiQuotaResetShowsCountdown"
        case .resetCoupon:
            self.fallbackText = "\(resetsAt) 到期"
            key = "resetCouponExpiryShowsCountdown"
        }
        self._showsCountdown = AppStorage(wrappedValue: true, key)
    }

    var body: some View {
        Button {
            showsCountdown.toggle()
        } label: {
            if showsCountdown, let date = resetDate {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    Text(countdownText(to: date, now: timeline.date))
                        .monospacedDigit()
                }
            } else {
                Text(absoluteText)
            }
        }
        .buttonStyle(.plain)
        .help(resetDate.map { "点击切换具体时间与倒计时显示 · \(UsageDateFormat.display($0))" }
              ?? (isCouponExpiry ? "到期时间待更新" : "重置时间待更新"))
        .accessibilityHint("切换具体时间与倒计时显示")
        .contextMenu {
            Button { showsCountdown = false } label: {
                Label("具体时间", systemImage: showsCountdown ? "clock" : "checkmark")
            }
            Button { showsCountdown = true } label: {
                Label("倒计时", systemImage: showsCountdown ? "checkmark" : "timer")
            }
        }
    }

    private var absoluteText: String {
        guard let resetDate else { return prefix + fallbackText }
        return isCouponExpiry ? "\(UsageDateFormat.display(resetDate)) 到期"
            : prefix + UsageDateFormat.syncTime(resetDate)
    }

    private func countdownText(to date: Date, now: Date) -> String {
        if isCouponExpiry, date <= now { return "已到期" }
        return prefix + QuotaResetFormatter.countdown(to: date, now: now) + (isCouponExpiry ? "到期" : "")
    }
}

enum QuotaResetFormatter {
    static func countdown(to date: Date, now: Date = Date()) -> String {
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return "即将重置" }
        let total = Int(ceil(interval))
        let parts = [(total / 86_400, "天"), ((total % 86_400) / 3_600, "小时"),
                     ((total % 3_600) / 60, "分"), (total % 60, "秒")]
            .filter { $0.0 > 0 }
            .prefix(2)
            .map { "\($0.0)\($0.1)" }
        return parts.joined() + "后"
    }
}
