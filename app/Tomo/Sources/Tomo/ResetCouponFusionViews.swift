import SwiftUI

// MARK: - Reset coupon (timeline rail + grant message card)

private struct ResetCouponDisplayItem: Identifiable {
    let id: String
    let coupon: ResetCoupon
}

struct ResetCouponSummaryView: View {
    let coupons: [ResetCoupon]

    /// 临时预览空态；看完改回 `false` 并重新 `./rebuild_and_run.sh`。
    private static let forceEmptyForPreview = false

    private var displayCoupons: [ResetCoupon] {
        if Self.forceEmptyForPreview { return [] }
        return coupons
    }

    private var items: [ResetCouponDisplayItem] {
        displayCoupons.flatMap { coupon in
            (0..<coupon.count).map { copyIndex in
                ResetCouponDisplayItem(id: "\(coupon.id)-\(copyIndex)", coupon: coupon)
            }
        }
    }

    var body: some View {
        Group {
            if items.isEmpty {
                ResetCouponEmptyStateView()
            } else {
        ResetCouponFusionDeck(items: items)
            .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 居中空态（方案 E-1）：虚线圆环图标 + 居中双行文字 + 虚线容器。
private struct ResetCouponEmptyStateView: View {
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .strokeBorder(
                        Color.codexMuted.opacity(isDark ? 0.50 : 0.55),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
                    .frame(width: 38, height: 38)
                Image(systemName: "ticket")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.codexMuted)
            }

            Text("重置券 0 张")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.codexInk)

            Text("当前没有可用重置券")
                .font(.system(size: 10))
                .foregroundStyle(Color.codexMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.vertical, 18)
        .background(
            Color.codexMist.opacity(isDark ? 0.20 : 0.24),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    Color.codexLine.opacity(isDark ? 0.50 : 0.60),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("重置券 0 张，当前没有可用重置券")
    }
}

private struct ResetCouponFusionDeck: View {
    let items: [ResetCouponDisplayItem]

    @State private var selectedIndex = 0

    private var sortedIndices: [Int] {
        items.indices.sorted { lhs, rhs in
            let left = ResetCouponDateParser.date(from: items[lhs].coupon.expiresAt) ?? .distantFuture
            let right = ResetCouponDateParser.date(from: items[rhs].coupon.expiresAt) ?? .distantFuture
            return left < right
        }
    }

    private var displayOrder: [Int] {
        sortedIndices
    }

    var body: some View {
        ResetCouponFusionCard(
            items: items,
            displayOrder: displayOrder,
            selectedIndex: selectedIndex,
            onSelect: { index in
                guard index >= 0, index < displayOrder.count else { return }
                selectedIndex = index
            },
            onNext: {
                guard displayOrder.count > 1 else { return }
                selectedIndex = (selectedIndex + 1) % displayOrder.count
            }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("重置券 \(items.count) 张，当前第 \(selectedIndex + 1) 张")
        .onChange(of: items.map(\.id)) { _, ids in
            if ids.isEmpty || selectedIndex >= ids.count {
                selectedIndex = 0
            }
        }
    }
}

private struct ResetCouponFusionCard: View {
    private static let cardSpace = "resetCouponFusionCard"

    let items: [ResetCouponDisplayItem]
    let displayOrder: [Int]
    let selectedIndex: Int
    let onSelect: (Int) -> Void
    let onNext: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var ripples: [CodexMaterialWaveToken] = []
    @State private var trackFrameInCard: CGRect = .zero

    private var selected: ResetCouponDisplayItem {
        items[displayOrder[selectedIndex]]
    }

    private var isDark: Bool { colorScheme == .dark }

    private var timelineRange: (min: Date, max: Date) {
        ResetCouponDateParser.timelineRange(for: displayOrder.map { items[$0].coupon })
    }

    private func dotCenter(for orderIndex: Int) -> CGPoint {
        guard !displayOrder.isEmpty, trackFrameInCard.width > 0 else {
            return CGPoint(x: 60, y: 60)
        }
        let itemIndex = displayOrder[orderIndex]
        let coupon = items[itemIndex].coupon
        let date = ResetCouponDateParser.date(from: coupon.expiresAt) ?? timelineRange.max
        let fraction = ResetCouponDateParser.fraction(of: date, in: timelineRange)
        let inset = ResetCouponTimelineTrack.dotInset
        let usableWidth = max(0, trackFrameInCard.width - inset * 2)
        return CGPoint(
            x: trackFrameInCard.minX + inset + usableWidth * fraction,
            y: trackFrameInCard.midY
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ResetCouponTimelineRail(
                items: items,
                displayOrder: displayOrder,
                selectedIndex: selectedIndex,
                range: timelineRange,
                isDark: isDark,
                cardSpace: Self.cardSpace,
                onTrackFrameChange: { trackFrameInCard = $0 },
                onSelect: { index in
                    ripples.spawnWave(at: dotCenter(for: index))
                    onSelect(index)
                }
            )

            CodexDivider()

            ResetCouponGrantMessageSection(
                coupon: selected.coupon,
                position: selectedIndex + 1,
                total: displayOrder.count,
                isDark: isDark,
                showsNext: displayOrder.count > 1,
                onNext: {
                    let nextIndex = (selectedIndex + 1) % displayOrder.count
                    ripples.spawnWave(at: dotCenter(for: nextIndex))
                    onNext()
                }
            )
        }
        .background(
            Color.codexCard.opacity(isDark ? 0.98 : 1),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.codexLine.opacity(isDark ? 0.42 : 0.78), lineWidth: 0.75)
        }
        .shadow(color: Color.black.opacity(isDark ? 0.14 : 0.05), radius: 14, x: 0, y: 6)
        .shadow(color: Color.black.opacity(isDark ? 0.06 : 0.02), radius: 3, x: 0, y: 1)
        .overlay {
            CodexMaterialWaveLayer(ripples: $ripples)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .coordinateSpace(name: Self.cardSpace)
    }
}

private struct ResetCouponTimelineRail: View {
    let items: [ResetCouponDisplayItem]
    let displayOrder: [Int]
    let selectedIndex: Int
    let range: (min: Date, max: Date)
    let isDark: Bool
    let cardSpace: String
    let onTrackFrameChange: (CGRect) -> Void
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("重置券有效期")
                    .font(.system(size: 10.5, weight: .semibold))
                Spacer(minLength: 8)
                Text("\(displayOrder.count) 张 · 按到期排序")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.codexMuted)
            }

            ResetCouponTimelineTrack(
                items: items,
                displayOrder: displayOrder,
                selectedIndex: selectedIndex,
                range: range,
                isDark: isDark,
                cardSpace: cardSpace,
                onFrameChange: onTrackFrameChange,
                onSelect: onSelect
            )

            ResetCouponTimelineMetaGrid(coupon: items[displayOrder[selectedIndex]].coupon)
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 10)
        .background(
            LinearGradient(
                colors: [
                    isDark ? Color.white.opacity(0.04) : Color(red: 0.98, green: 0.99, blue: 0.98),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

private struct ResetCouponTimelineTrack: View {
    let items: [ResetCouponDisplayItem]
    let displayOrder: [Int]
    let selectedIndex: Int
    let range: (min: Date, max: Date)
    let isDark: Bool
    let cardSpace: String
    let onFrameChange: (CGRect) -> Void
    let onSelect: (Int) -> Void

    static let dotInset: CGFloat = 12

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let usableWidth = max(0, width - Self.dotInset * 2)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.codexTrack.opacity(isDark ? 0.85 : 1))
                    .frame(height: 3)
                    .frame(maxHeight: .infinity, alignment: .center)

                ForEach(Array(displayOrder.enumerated()), id: \.offset) { orderIndex, itemIndex in
                    let coupon = items[itemIndex].coupon
                    let fraction = ResetCouponDateParser.fraction(
                        of: ResetCouponDateParser.date(from: coupon.expiresAt) ?? range.max,
                        in: range
                    )
                    let x = Self.dotInset + usableWidth * fraction
                    let isSelected = orderIndex == selectedIndex

                    Button {
                        onSelect(orderIndex)
                    } label: {
                        ZStack {
                            if isSelected {
                                Circle()
                                    .fill(Color.codexGreen.opacity(0.22))
                                    .frame(width: 22, height: 22)
                            }
                            Circle()
                                .fill(isSelected ? Color.codexGreen : Color.codexLine.opacity(isDark ? 0.9 : 0.95))
                                .frame(width: isSelected ? 12 : 9, height: isSelected ? 12 : 9)
                                .overlay {
                                    Circle()
                                        .stroke(Color.codexCard, lineWidth: 2)
                                }
                                .shadow(
                                    color: isSelected ? Color.codexGreen.opacity(0.35) : Color.black.opacity(0.08),
                                    radius: isSelected ? 4 : 1,
                                    y: 1
                                )
                        }
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .position(x: x, y: geometry.size.height / 2)
                    .accessibilityLabel("第 \(orderIndex + 1) 张，\(coupon.expiresAt) 到期")
                }
            }
        }
        .frame(height: 28)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        onFrameChange(geometry.frame(in: .named(cardSpace)))
                    }
                    .onChange(of: geometry.frame(in: .named(cardSpace))) { _, frame in
                        onFrameChange(frame)
                    }
            }
        }
    }
}

private struct ResetCouponTimelineMetaGrid: View {
    let coupon: ResetCoupon

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
            alignment: .leading,
            spacing: 3
        ) {
            metaCell(title: "类型", value: ResetCouponDateParser.resetTypeLabel(coupon.resetType))
            metaCell(title: "状态", value: coupon.status ?? coupon.source)
        }
    }

    private func metaCell(title: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(Color.codexMuted)
            Text(value)
                .foregroundStyle(Color.primary.opacity(0.88))
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .font(.system(size: 8.5, weight: .medium))
    }
}

private struct ResetCouponGrantMessageSection: View {
    private static let footerHeight: CGFloat = 44

    let coupon: ResetCoupon
    let position: Int
    let total: Int
    let isDark: Bool
    let showsNext: Bool
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 9) {
                ResetCouponGrantAvatar(urlString: coupon.profileImageURL, isDark: isDark)

                VStack(alignment: .leading, spacing: 1) {
                    Text(coupon.profileUserID ?? coupon.source)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                    Text("授予 · \(ResetCouponDateParser.shortDate(from: coupon.grantedAt) ?? "—")")
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(Color.codexMuted)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Text("\(position)/\(total)")
                    .font(.system(size: 8, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.codexMuted)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            VStack(alignment: .leading, spacing: 4) {
                Text(coupon.title ?? coupon.name)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(0.92))
                    .lineLimit(1)

                if let description = coupon.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Color.codexMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 8)

            HStack(alignment: .center, spacing: 8) {
                Text("\(coupon.expiresAt) 到期")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.codexMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 0)

                if showsNext {
                    HStack(spacing: 6) {
                        ResetCouponPageDots(count: total, index: position - 1)
                        Button(action: onNext) {
                            Text("下一张")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.codexGreen)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(
                                    Color.codexGreen.opacity(isDark ? 0.14 : 0.09),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.codexGreen.opacity(0.22), lineWidth: 0.6)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("下一张重置券")
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(height: Self.footerHeight, alignment: .center)
            .background(Color.codexMist.opacity(isDark ? 0.22 : 0.38))
        }
    }
}

private struct ResetCouponGrantAvatar: View {
    let urlString: String?
    let isDark: Bool

    var body: some View {
        Group {
            if let urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        fallbackIcon
                    }
                }
            } else {
                fallbackIcon
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.codexLine.opacity(0.45), lineWidth: 0.6)
        }
    }

    private var fallbackIcon: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.codexGreen.opacity(isDark ? 0.22 : 0.14),
                    Color.codexGreen.opacity(isDark ? 0.10 : 0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Image(systemName: "ticket.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.codexGreen.opacity(isDark ? 0.88 : 0.82))

            Image(systemName: "arrow.clockwise")
                .font(.system(size: 7, weight: .black))
                .foregroundStyle(isDark ? Color.black.opacity(0.72) : Color.white)
        }
        .accessibilityHidden(true)
    }
}

private struct ResetCouponPageDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { dotIndex in
                Capsule(style: .continuous)
                    .fill(dotIndex == index ? Color.codexGreen : Color.codexLine.opacity(0.85))
                    .frame(width: dotIndex == index ? 11 : 4, height: 4)
            }
        }
        .accessibilityHidden(true)
    }
}

enum ResetCouponDateParser {
    static let minimumTimelineDaySpan = 10

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let shortDisplayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    static func date(from value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let date = displayFormatter.date(from: value) { return date }
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        return nil
    }

    static func shortDate(from value: String?) -> String? {
        guard let date = date(from: value) else { return nil }
        return shortDisplayFormatter.string(from: date)
    }

    static func timelineRange(
        for coupons: [ResetCoupon],
        relativeTo now: Date = Date(),
        calendar: Calendar = .current
    ) -> (min: Date, max: Date) {
        let today = calendar.startOfDay(for: now)
        // This is the visible scale of the rail, not a change to coupon
        // validity. A rolling ten-day minimum lets a lone expiry marker move
        // left as its expiration approaches instead of remaining at the end.
        let minimumMaximum = calendar.date(
            byAdding: .day,
            value: minimumTimelineDaySpan,
            to: today
        ) ?? today.addingTimeInterval(TimeInterval(minimumTimelineDaySpan * 86_400))
        let expiresDates = coupons.compactMap { date(from: $0.expiresAt) }
        let latestExpiry = expiresDates.max() ?? today
        return (today, max(latestExpiry, minimumMaximum))
    }

    static func fraction(of date: Date, in range: (min: Date, max: Date)) -> CGFloat {
        let span = range.max.timeIntervalSince(range.min)
        guard span > 0 else { return 0.5 }
        let raw = date.timeIntervalSince(range.min) / span
        return CGFloat(min(max(raw, 0), 1))
    }

    static func resetTypeLabel(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "重置券" }
        if value == "codex_rate_limits" { return "重置 Codex 速率额度" }
        return value
    }
}

#if DEBUG
#Preview("重置券 · 空态") {
    ResetCouponSummaryView(coupons: [])
        .padding(14)
        .frame(width: 380)
        .background(Color.codexMist.opacity(0.3))
}

#Preview("重置券 · M1") {
    ResetCouponSummaryView(coupons: CodexUsageSnapshot.preview.resetCoupons)
        .padding(14)
        .frame(width: 380)
        .background(Color.codexMist.opacity(0.3))
}
#endif
