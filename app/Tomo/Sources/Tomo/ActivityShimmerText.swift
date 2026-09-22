import SwiftUI

/// 单行文字流光。位移由时间轴的绝对时间决定，View 重建时不会重置动画进度。
struct ActivityShimmerText: View {
    let text: String
    var font: Font = .system(size: 8.5)
    var base: Color = .codexMuted
    var highlight: Color = .white
    var isAnimated = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // 使用真实 Text 参与布局和绘制，确保受限宽度下由 SwiftUI 生成尾部省略号。
        // 流光层复用同一份截断后的 Text，避免 Canvas 直接绘制完整字符串时在边缘硬裁切。
        Text(text)
            .font(font)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(base)
            .overlay {
                if isAnimated {
                    TimelineView(
                        .animation(
                            minimumInterval: 1.0 / 30.0,
                            paused: reduceMotion
                        )
                    ) { timeline in
                        shimmerLayer(at: timeline.date.timeIntervalSinceReferenceDate)
                    }
                }
            }
            .accessibilityLabel(text)
    }

    private func shimmerLayer(at time: TimeInterval) -> some View {
        GeometryReader { geometry in
            let bandWidth = max(24, geometry.size.width * 0.5)
            let offset = ActivityShimmerMotion.offset(
                canvasWidth: geometry.size.width,
                bandWidth: bandWidth,
                at: time,
                isAnimated: isAnimated && !reduceMotion
            )

            Text(text)
                .font(font)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(highlight)
                .frame(
                    width: geometry.size.width,
                    height: geometry.size.height,
                    alignment: .topLeading
                )
                .mask(alignment: .leading) {
                    LinearGradient(
                        colors: [.clear, .white, .white, .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: bandWidth)
                    .offset(x: offset)
                }
        }
        .allowsHitTesting(false)
    }
}

enum ActivityShimmerMotion {
    /// 与原任务条一致，每 2.4 秒从文字左侧完整扫到右侧一次。
    static let duration: TimeInterval = 2.4

    static func offset(
        canvasWidth: CGFloat,
        bandWidth: CGFloat,
        at time: TimeInterval,
        isAnimated: Bool = true
    ) -> CGFloat {
        guard isAnimated else { return (canvasWidth - bandWidth) / 2 }
        let phase = time.truncatingRemainder(dividingBy: duration) / duration
        return -bandWidth + CGFloat(phase) * (canvasWidth + 2 * bandWidth)
    }
}
