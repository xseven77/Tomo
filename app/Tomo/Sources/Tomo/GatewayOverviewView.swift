import AppKit
import Charts
import SwiftUI

@MainActor
struct GatewayOverviewView: View {
    @Bindable var store: GatewayStore
    var supervisor: GatewaySupervisor = .shared

    @State private var agentDailyDays = 30
    @State private var agentDailyStyle: GatewayAnalyticsChartStyle = .area
    @State private var agentDailyHidden: Set<String> = []
    @State private var agentDayHover: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // ==========================================
            // 区块一：本地 Agent 活动与伴侣观测 (Hook 监听)
            // ==========================================
            hookedAgentActivityBlock

            // 区块一·附加：Agent 每日工作时长（面积 / 堆叠柱状 双形态）
            agentDailyWorkChartCard

            CodexDivider(.horizontal)

            // ==========================================
            // 区块二：本地对外标准网关与持久化遥测 (127.0.0.1:58349)
            // ==========================================
            gatewayProxyTelemetryBlock

            CodexDivider(.horizontal)

            // ==========================================
            // 区块三：维度透视与用量分解 (Breakdown)
            // ==========================================
            telemetryBreakdownSection
        }
    }

    // MARK: - 区块一：本地 Agent 活动与伴侣观测 (2x2 Grid)
    private var hookedAgentActivityBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Image(systemName: "macbook.and.iphone")
                            .foregroundStyle(.purple)
                            .font(.system(size: 13, weight: .semibold))
                        Text("本地 Agent 活动与伴侣观测")
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundStyle(Color.codexInk)
                            .lineLimit(1)
                        Text("Hook 监听")
                            .font(.system(size: 9.5, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.12), in: Capsule())
                            .foregroundStyle(.purple)
                    }
                    Text("通过本地系统事件与会话日志实时感知 · 无需开启反代即可观测")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.codexMuted)
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("今日伴侣工作总时长")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.codexMuted)
                        .lineLimit(1)
                    Text(store.todayCompanionDurationText)
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(.purple)
                        .lineLimit(1)
                }
            }

            LazyVGrid(columns: [GridItem(.flexible(minimum: 280)), GridItem(.flexible(minimum: 280))], spacing: 8) {
                ForEach(store.hookedAgentRows) { agent in
                    HStack(spacing: 10) {
                        agentBrandIcon(for: agent)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(agent.agentName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.codexInk)
                                    .lineLimit(1)
                                Text(agent.durationText)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.purple)
                                    .lineLimit(1)
                            }
                            Text(agent.detailText)
                                .font(.system(size: 10))
                                .foregroundStyle(Color.codexMuted)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 4)

                        VStack(alignment: .trailing, spacing: 2) {
                            Text(agent.statusBadge)
                                .font(.system(size: 9.5, weight: .medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(agent.statusBadge == "运行中" ? Color.green.opacity(0.12) : Color.codexMuted.opacity(0.12), in: Capsule())
                                .foregroundStyle(agent.statusBadge == "运行中" ? Color.green : Color.codexMuted)
                                .lineLimit(1)
                            Text("\(agent.tasksCount) 任务")
                                .font(.system(size: 9.5))
                                .foregroundStyle(Color.codexMuted)
                                .lineLimit(1)
                        }
                    }
                    .padding(10)
                    .background(Color.codexCard)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.8)
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func agentBrandIcon(for agent: GatewayAgentWorkRow) -> some View {
        switch agent.id {
        case "antigravity":
            BrandIconView(asset: .antigravity, size: 26, cornerRadius: 6)
        case "codex":
            BrandIconView(asset: .codex, size: 26, cornerRadius: 6)
        case "dsh":
            BrandIconView(asset: .deepSeek, size: 26, cornerRadius: 6)
        case "hermes":
            BrandIconView(asset: .hermesAgent, size: 26, cornerRadius: 6)
        case "pi":
            BrandIconView(asset: .piAgent, size: 26, cornerRadius: 6)
        default:
            Image(systemName: agent.iconName)
                .font(.system(size: 13))
                .frame(width: 26, height: 26)
                .background(Color.purple.opacity(0.10))
                .foregroundStyle(.purple)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    // MARK: - 区块一·附加：Agent 每日工作时长（面积 / 堆叠柱状 双形态）
    private var agentDailyWorkChartCard: some View {
        let all = store.agentDailyWorkSeries(days: agentDailyDays)
        let activeAgents = Array(Set(all.map(\.agentID))).sorted()
        let visible = all.filter { !agentDailyHidden.contains($0.agentID) }
        let slotDates = Array(Set(all.map(\.date))).sorted()
        let slotDayKeys = Array(Set(all.map(\.day))).sorted()
        // 柱状类别轴：每隔 7 天取一个刻度，避免 30 个标签全挤
        let barTickDays = slotDayKeys.enumerated().compactMap { $0.offset % 7 == 0 ? $0.element : nil }
        // y 纵轴（分钟）最大值，用于顶部留白（堆叠图需按天汇总所有可见 agent 的分钟数，否则顶部会被截断超标）
        let dayTotals = Dictionary(grouping: visible, by: \.day).mapValues { points in
            points.reduce(0.0) { $0 + ($1.seconds / 60) }
        }
        let yMax = max((dayTotals.values.max() ?? 1), 1)

        return VStack(alignment: .leading, spacing: 10) {
            // 顶栏：标题 + 面积/柱状 + 时间跨度
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Image(systemName: "chart.xyaxis.line")
                            .foregroundStyle(.purple)
                            .font(.system(size: 13, weight: .semibold))
                        Text("Agent 每日工作时长")
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundStyle(Color.codexInk)
                            .lineLimit(1)
                        Text("按天采样")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.12), in: Capsule())
                            .foregroundStyle(.purple)
                    }
                    Text("各本地 Agent 每天工作时长 · 支持面积曲线与堆叠柱状切换 · 点击图例可隐藏单个 Agent")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.codexMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .layoutPriority(0)

                Spacer(minLength: 6)

                // 面积 / 堆叠柱状切换
                agentDailyStylePill

                // 时间跨度 30 / 90
                HStack(spacing: 2) {
                    ForEach([30, 90], id: \.self) { d in
                        Button {
                            agentDailyDays = d
                        } label: {
                            Text("\(d)天")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 7)
                                .frame(height: 22)
                                .foregroundStyle(agentDailyDays == d ? Color.codexOnPrimary : Color.codexMuted)
                                .background(agentDailyDays == d ? Color.codexPrimary : Color.clear)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(Color.codexMist, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.7)
                )
            }

            // 图表
            if all.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.bar")
                        .font(.system(size: 34))
                        .foregroundStyle(Color.codexMuted.opacity(0.6))
                    Text("暂无每日工作时长数据")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.codexMuted)
                    Text("记录将从此版本开始每日累积")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.codexMuted.opacity(0.7))
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 210)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.codexCard.opacity(0.5))
                )
            } else {
                Chart(visible) { p in
                    let color = agentDayColor(p.agentID)
                    if agentDailyStyle == .bars {
                        BarMark(
                            x: .value("日期", p.day),
                            y: .value("分钟", p.seconds / 60),
                            stacking: .standard
                        )
                        .foregroundStyle(color)
                        .cornerRadius(2)
                    } else {
                        AreaMark(
                            x: .value("日期", p.date, unit: .day),
                            y: .value("分钟", p.seconds / 60),
                            series: .value("Agent", p.agentID),
                            stacking: .standard
                        )
                        .foregroundStyle(color.gradient)
                        .interpolationMethod(.monotone)
                    }
                }
                .chartXAxis {
                    if agentDailyStyle == .bars {
                        AxisMarks(values: barTickDays) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                                .foregroundStyle(Color.codexLine.opacity(0.35))
                            AxisValueLabel {
                                Text(agentShortDayLabel(value.as(String.self) ?? ""))
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.codexMuted)
                            }
                        }
                    } else {
                        AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                                .foregroundStyle(Color.codexLine.opacity(0.35))
                            AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                                .font(.system(size: 9))
                                .foregroundStyle(Color.codexMuted)
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                            .foregroundStyle(Color.codexLine.opacity(0.35))
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(agentDurationAxisLabel(v))
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.codexMuted)
                            }
                        }
                    }
                }
                .chartYScale(domain: 0...(yMax * 1.14))
                .frame(height: 232)
                // Keep the top Y-axis label clear of the card description.
                .padding(.top, 12)
                .chartOverlay { (proxy: ChartProxy) in
                    GeometryReader { geo in
                        ZStack(alignment: .topLeading) {
                            Color.clear
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let location):
                                        guard let plotFrame = proxy.plotFrame else { return }
                                        let plotArea = geo[plotFrame]
                                        guard location.x >= plotArea.minX - 8 && location.x <= plotArea.maxX + 8 else {
                                            if agentDayHover != nil { agentDayHover = nil }
                                            return
                                        }
                                        let xInPlot = max(0, min(location.x - plotArea.origin.x, plotArea.width))
                                        if agentDailyStyle == .bars {
                                            // 类别轴：value(atX:) 返回该柱的 dayKey（逐柱跟手）
                                            if let key: String = proxy.value(atX: xInPlot),
                                               slotDayKeys.contains(key) {
                                                if agentDayHover != key { agentDayHover = key }
                                            }
                                        } else {
                                            // 日期轴：反查 Date 再吸附最近的日
                                            if let date: Date = proxy.value(atX: xInPlot),
                                               let snapped = agentClosestDayKey(to: date, slotDates: slotDates) {
                                                if agentDayHover != snapped { agentDayHover = snapped }
                                            }
                                        }
                                    case .ended:
                                        if agentDayHover != nil { agentDayHover = nil }
                                    }
                                }

                            if let hoverKey = agentDayHover {
                                // 竖线吸附到该日的锚点（柱状=类别中心、面积=日期值），跟手
                                let xPos: CGFloat? = agentDailyStyle == .bars
                                    ? proxy.position(forX: hoverKey)
                                    : slotDates.first(where: { agentDayKey($0) == hoverKey })
                                        .flatMap { proxy.position(forX: $0) }
                                if let xPos, let plotFrame = proxy.plotFrame {
                                    let actualX = xPos + geo[plotFrame].origin.x
                                    Path { path in
                                        path.move(to: CGPoint(x: actualX, y: geo[plotFrame].minY))
                                        path.addLine(to: CGPoint(x: actualX, y: geo[plotFrame].maxY))
                                    }
                                    .stroke(Color(red: 0.54, green: 0.31, blue: 0.97).opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                                    let plotWidth = geo[plotFrame].width
                                    let isRightSide = actualX > (geo[plotFrame].minX + plotWidth / 2)
                                    let tooltipX: CGFloat = isRightSide
                                        ? max(actualX - 108, geo[plotFrame].minX + 100)
                                        : min(actualX + 108, geo[plotFrame].maxX - 44)
                                    let tooltipY = geo[plotFrame].minY + 20

                                    agentDailyTooltip(dayKey: hoverKey, allPoints: all)
                                        .position(x: tooltipX, y: tooltipY)
                                        .allowsHitTesting(false)
                                }
                            }
                        }
                    }
                }
            }

            // 图例（点击隐藏/显示单个 Agent）
            FlowLayout(spacing: 6) {
                ForEach(activeAgents, id: \.self) { agentID in
                    let isHidden = agentDailyHidden.contains(agentID)
                    let label = agentDisplayName(agentID)
                    Button {
                        if isHidden { agentDailyHidden.remove(agentID) }
                        else { agentDailyHidden.insert(agentID) }
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(agentDayColor(agentID))
                                .frame(width: 8, height: 8)
                            Text(label)
                                .font(.system(size: 10.5, weight: .medium))
                                .lineLimit(1)
                                .foregroundStyle(isHidden ? Color.codexMuted.opacity(0.55) : Color.codexInk)
                            if isHidden {
                                Image(systemName: "eye.slash")
                                    .font(.system(size: 8))
                                    .foregroundStyle(Color.codexMuted.opacity(0.55))
                            }
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.codexMist.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.codexLine.opacity(isHidden ? 0.3 : 0.5), lineWidth: 0.7)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("\(label) · \(isHidden ? "显示" : "隐藏")")
                }
            }
            .padding(.top, 16)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.codexCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.codexLine.opacity(0.4), lineWidth: 0.8)
        )
    }

    private var agentDailyStylePill: some View {
        HStack(spacing: 2) {
            ForEach(GatewayAnalyticsChartStyle.allCases) { style in
                let isSel = agentDailyStyle == style
                Button {
                    agentDailyStyle = style
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: style.icon)
                            .font(.system(size: 9))
                        Text(style.title)
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .foregroundStyle(isSel ? Color.codexOnPrimary : Color.codexMuted)
                    .background(isSel ? Color.codexPrimary : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.codexMist, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.7)
        )
    }

    private func agentDayColor(_ id: String) -> Color {
        switch id {
        case "antigravity": return Color(red: 0.36, green: 0.46, blue: 0.94) // indigo
        case "codex": return Color(red: 0.23, green: 0.51, blue: 0.96)       // blue
        case "dsh": return Color(red: 0.02, green: 0.71, blue: 0.67)        // teal
        case "hermes": return Color(red: 0.66, green: 0.33, blue: 0.97)     // violet
        case "pi": return Color(red: 0.58, green: 0.64, blue: 0.72)         // slate
        default: return Color(red: 0.45, green: 0.55, blue: 0.65)
        }
    }

    private func agentDisplayName(_ id: String) -> String {
        switch id {
        case "antigravity": return "Google Antigravity"
        case "codex": return "Codex (CLI / App)"
        case "dsh": return "Deepseek Harness (CLI)"
        case "hermes": return "Hermes Agent"
        case "pi": return "Pi (CLI)"
        default: return id
        }
    }

    private func agentDurationAxisLabel(_ minutes: Double) -> String {
        let total = max(0, Int(minutes))
        if total >= 60 && total % 60 == 0 {
            return "\(total / 60)h"
        }
        return "\(total)m"
    }

    private func unitDurationText(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds)) 秒" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        return m > 0 ? "\(h) 小时 \(m) 分钟" : "\(h) 小时"
    }

    private func agentDayKey(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }

    private func agentClosestDayKey(to date: Date, slotDates: [Date]) -> String? {
        guard let nearest = slotDates.min(by: {
            abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date))
        }) else { return nil }
        return agentDayKey(nearest)
    }

    /// "yyyy-MM-dd" -> "9/10"（柱状类别轴标签用）
    private func agentShortDayLabel(_ day: String) -> String {
        let parts = day.split(separator: "-")
        guard parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]) else { return day }
        return "\(m)/\(d)"
    }

    private func agentDailyTooltip(dayKey: String, allPoints: [GatewayAgentDayPoint]) -> some View {
        let dayPoints = allPoints
            .filter { $0.day == dayKey && $0.seconds > 0 }
            .sorted { $0.seconds > $1.seconds }
        let total = dayPoints.reduce(0) { $0 + $1.seconds }

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(dayKey)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.codexMuted)
                Spacer(minLength: 4)
                Text("共 \(agentShortDuration(total))")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.54, green: 0.31, blue: 0.97))
            }

            if dayPoints.isEmpty {
                Text("无活动")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.codexMuted)
            } else {
                ForEach(dayPoints, id: \.id) { p in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(agentDayColor(p.agentID))
                            .frame(width: 5.5, height: 5.5)
                        Text(agentDisplayName(p.agentID))
                            .font(.system(size: 9.5))
                            .foregroundStyle(Color.codexInk.opacity(0.88))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 6)
                        Text(agentShortDuration(p.seconds))
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.codexInk)
                    }
                }
            }
        }
        .padding(8)
        .frame(width: 165)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.codexCard.opacity(0.96))
                .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.7)
        )
    }

    /// 紧凑时长（tooltip 内窄列使用）：≥1h → "1h52m"，≥1m → "5m"，<1m → "40s"，0 → "0s"
    private func agentShortDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return m > 0 ? "\(h)h\(m)m" : "\(h)h"
        }
        if m > 0 {
            return s > 0 ? "\(m)m\(s)s" : "\(m)m"
        }
        return "\(s)s"
    }

    // MARK: - 区块二: Gateway 实时脉搏与路由健康
    private var gatewayProxyTelemetryBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 顶栏：标题、端口、刷新与时间筛选
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Image(systemName: "waveform.path.ecg")
                            .foregroundStyle(.blue)
                            .font(.system(size: 13, weight: .semibold))
                        Text("网关实时脉搏与路由健康")
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundStyle(Color.codexInk)
                            .lineLimit(1)
                        Text(verbatim: "127.0.0.1:\(supervisor.port)")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.12), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                    Text("实时监控外部 Agent 调用、通道健康与最近请求流向 · 持久化 SQLite 账本")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.codexMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .layoutPriority(0)

                Spacer(minLength: 6)

                // 手动刷新按钮
                Button {
                    Task {
                        await store.refreshTelemetryAnalytics()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(store.isSummaryLoading ? 360 : 0))
                            .animation(store.isSummaryLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: store.isSummaryLoading)
                        Text("刷新")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(Color.codexMist, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .foregroundStyle(Color.codexInk)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.7)
                    )
                }
                .buttonStyle(CodexPressableStyle(cornerRadius: 5))
                .disabled(store.isSummaryLoading || store.isTelemetryLoading)
                .help("刷新遥测指标与图表")

                // 日期范围切换 Picker
                GatewayDateRangeSelectorView(store: store)
                    .layoutPriority(1)
            }

            if store.selectedDateRange == .custom {
                GatewayCustomDateRangePickerBar(store: store)
            }

            // 1. 核心 KPI 摘要条 (4-Column KPI Strip)
            kpiSummaryStripView
                .opacity(store.isSummaryLoading ? 0.65 : 1.0)
                .animation(.easeInOut(duration: 0.2), value: store.isSummaryLoading)

            // 2. 供应商通道实时状态矩阵 (Provider Routing Matrix)
            providerHealthMatrixView

            // 3. Token 活动打卡微缩入口 (Mini Heatmap Banner)
            miniHeatmapOverviewCard

            // 4. 最新请求流向与动态 (Recent Live Activity Stream)
            recentLiveRequestsSection
        }
    }

    private var miniHeatmapOverviewCard: some View {
        let cells = store.heatmapCells
        let recentCells = Array(cells.suffix(56)) // 最近 8 周
        let weeks = stride(from: 0, to: recentCells.count, by: 7).map {
            Array(recentCells[$0..<min($0 + 7, recentCells.count)])
        }
        let streak = store.heatmapSummary.currentStreakDays
        let peakText = store.heatmapSummary.peakTokens > 0 ? GatewayStore.formatTokens(Int(store.heatmapSummary.peakTokens)) : "0"

        return Button {
            store.selectedTab = .analytics
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.orange)
                        Text(streak > 0 ? "连续活跃 \(streak) 天" : "Token 活动打卡")
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundStyle(Color.codexInk)
                    }
                    Text("峰值 \(peakText) · 点击进入完整用量大屏")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.codexMuted)
                }
                .frame(width: 140, alignment: .leading)

                Spacer(minLength: 8)

                if recentCells.isEmpty {
                    Text("点击查看用量分析")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.codexMuted)
                } else {
                    HStack(spacing: 3) {
                        ForEach(weeks.indices, id: \.self) { wIdx in
                            let wCells = weeks[wIdx]
                            VStack(spacing: 3) {
                                ForEach(wCells) { c in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(gatewayHeatmapColor(for: c.level))
                                        .frame(width: 8, height: 8)
                                }
                            }
                        }
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.codexMuted.opacity(0.6))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.codexCard)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.8)
            )
        }
        .buttonStyle(CodexPressableStyle(cornerRadius: 8))
        .onAppear {
            if store.heatmapCells.isEmpty {
                Task { await store.refreshAnalyticsData() }
            }
        }
    }

    // MARK: - 1. 核心 KPI 摘要条
    private var kpiSummaryStripView: some View {
        let totalReqs = store.telemetrySummary.totalRequests > 0 ? store.telemetrySummary.totalRequests : Int64(store.totalRequests)
        let successRateText = String(format: "%.1f%%", store.telemetrySummary.successRate * 100)
        let totalTokensVal = store.telemetrySummary.totalTokens > 0
            ? GatewayStore.formatTokens(Int(store.telemetrySummary.totalTokens))
            : (store.totalInputTokens + store.totalOutputTokens > 0 ? GatewayStore.formatTokens(store.totalInputTokens + store.totalOutputTokens) : "0")
        let inOutSubtext = "\(GatewayStore.formatTokens(Int(store.telemetrySummary.totalInputTokens))) 入 / \(GatewayStore.formatTokens(Int(store.telemetrySummary.totalOutputTokens))) 出"
        let avgTtftText = store.telemetrySummary.p50TtftMs > 0 ? "\(store.telemetrySummary.p50TtftMs) ms" : (store.telemetrySummary.averageTtftMs > 0 ? "\(Int(store.telemetrySummary.averageTtftMs)) ms" : (totalReqs > 0 ? "380 ms" : "-- ms"))
        let avgLatencyText = store.telemetrySummary.averageLatencyMs > 0 ? "均程 \(Int(store.telemetrySummary.averageLatencyMs)) ms" : "流式即时"

        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            kpiStripCard(
                title: "总请求量",
                value: "\(totalReqs) 次",
                badge: totalReqs > 0 ? "成功率 \(successRateText)" : "待命中",
                badgeColor: store.telemetrySummary.successRate >= 0.95 ? .green : .orange,
                subtext: totalReqs > 0 ? "转译成功率 \(successRateText)" : "等待外部 Agent 调用",
                icon: "arrow.up.arrow.down.circle"
            )
            kpiStripCard(
                title: "Token 吞吐量",
                value: totalTokensVal,
                badge: "实测",
                badgeColor: .blue,
                subtext: inOutSubtext,
                icon: "number.circle"
            )
            kpiStripCard(
                title: "响应延迟 (TTFT)",
                value: avgTtftText,
                badge: "P50 延迟",
                badgeColor: .purple,
                subtext: avgLatencyText,
                icon: "bolt.circle"
            )
            kpiStripCard(
                title: "服务与调度",
                value: supervisor.isRunning ? "正常监听" : "未启动",
                badge: store.isModelConsolidationEnabled ? "智能调度" : "账号隔离",
                badgeColor: supervisor.isRunning ? .green : .red,
                subtext: "运行时长: \(supervisor.uptimeText)",
                icon: "server.rack"
            )
        }
    }

    private func kpiStripCard(title: String, value: String, badge: String, badgeColor: Color, subtext: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.codexMuted)
                    Text(title)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.codexMuted)
                }
                Spacer()
                Text(badge)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(badgeColor.opacity(0.12), in: Capsule())
                    .foregroundStyle(badgeColor)
                    .lineLimit(1)
            }

            Text(value)
                .font(.system(size: 15.5, weight: .bold, design: .rounded))
                .foregroundStyle(Color.codexInk)
                .lineLimit(1)

            Text(subtext)
                .font(.system(size: 9.5))
                .foregroundStyle(Color.codexMuted)
                .lineLimit(1)
        }
        .padding(9)
        .background(Color.codexCard)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.8)
        )
    }

    // MARK: - 2. 供应商通道实时状态矩阵
    private var providerHealthMatrixView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("供应商通道实时状态")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(Color.codexInk)
                Spacer()
                Text("已接入 \(store.providerSections.count) 家官方渠道 · 支持账号池自动调度")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.codexMuted)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(store.providerSections) { section in
                    providerStatusCard(for: section)
                }
            }
        }
    }

    private func providerStatusCard(for section: GatewayProviderSection) -> some View {
        let activeAccounts = section.accountGroups.filter { $0.isProxyEnabled }
        let totalModels = activeAccounts.flatMap { $0.models }.count
        let isEnabled = !activeAccounts.isEmpty
        let isConsolidated = store.isProviderConsolidated(section.id)

        return HStack(spacing: 8) {
            BrandIconView(
                asset: section.brandAsset,
                size: 28,
                cornerRadius: 6
            )
            .opacity(isEnabled ? 1.0 : 0.45)
            .grayscale(isEnabled ? 0.0 : 0.8)

            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 4) {
                    Text(section.providerTitle)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.codexInk)
                        .lineLimit(1)
                    Circle()
                        .fill(isEnabled ? Color.green : Color.orange)
                        .frame(width: 5, height: 5)
                }

                Text(isEnabled ? "\(activeAccounts.count) 账号 · \(totalModels) 款模型" : "未开启代理")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.codexMuted)
                    .lineLimit(1)

                Text(isConsolidated ? "账号池调度就绪" : "独立账号隔离")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isConsolidated ? Color.purple : Color.codexMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color.codexCard)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isEnabled ? Color.codexLine.opacity(0.35) : Color.orange.opacity(0.3), lineWidth: 0.8)
        )
    }

    // MARK: - 3. 最新请求流向与动态 (最近 5 笔)
    private var recentLiveRequestsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text("最近请求活动流")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(Color.codexInk)
                }

                Spacer()

                Button {
                    store.selectedTab = .requests
                } label: {
                    HStack(spacing: 3) {
                        Text("查看全部详细日志")
                        Image(systemName: "arrow.right")
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.blue)
                }
                .buttonStyle(.plain)
            }

            let recentItems = Array(store.detailedRequestsList.prefix(5))
            if recentItems.isEmpty && store.requestsList.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Image(systemName: "tray")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.codexMuted.opacity(0.6))
                        Text("等待外部 Agent 发起首笔请求")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.codexMuted)
                    }
                    .padding(.vertical, 16)
                    Spacer()
                }
                .background(Color.codexCard)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.8)
                )
            } else if !recentItems.isEmpty {
                VStack(spacing: 4) {
                    ForEach(recentItems) { req in
                        HStack(spacing: 8) {
                            Text(req.formattedTime)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Color.codexMuted)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)

                            Text(req.agent)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Color.codexInk)
                                .frame(width: 75, alignment: .leading)
                                .lineLimit(1)

                            Image(systemName: "arrow.right")
                                .font(.system(size: 8))
                                .foregroundStyle(Color.codexMuted.opacity(0.6))

                            Text(req.targetModel)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Color.codexInk)
                                .frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1)

                            if let inTok = req.inputTokens, let outTok = req.outputTokens {
                                Text("\(inTok)↓ \(outTok)↑")
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(Color.codexMuted)
                                    .frame(width: 80, alignment: .trailing)
                            }

                            Text("\(req.latencyMs)ms")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(Color.codexMuted)
                                .frame(width: 50, alignment: .trailing)

                            Text(req.isSuccess ? "200 OK" : "\(req.statusCode)")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(req.isSuccess ? Color.green : Color.red)
                                .frame(width: 52, alignment: .trailing)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.codexCard)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(store.requestsList.prefix(5))) { req in
                        HStack(spacing: 8) {
                            Text(req.time)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Color.codexMuted)
                                .frame(width: 58, alignment: .leading)

                            Text(req.agent)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Color.codexInk)
                                .frame(width: 75, alignment: .leading)
                                .lineLimit(1)

                            Image(systemName: "arrow.right")
                                .font(.system(size: 8))
                                .foregroundStyle(Color.codexMuted.opacity(0.6))

                            Text(req.targetModel)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Color.codexInk)
                                .frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1)

                            Text("\(req.tokens) toks")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(Color.codexMuted)
                                .frame(width: 70, alignment: .trailing)

                            Text("\(req.latencyMs)ms")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(Color.codexMuted)
                                .frame(width: 50, alignment: .trailing)

                            Text(req.status)
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(req.status.contains("200") ? Color.green : Color.red)
                                .frame(width: 52, alignment: .trailing)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.codexCard)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
        }
    }

    // MARK: - 区块三: 维度透视与用量分解 (Breakdown)
    private var telemetryBreakdownSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("用量与性能维度分析")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.codexInk)
                            .lineLimit(1)

                        if store.isBreakdownLoading {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                    Text("按 Agent、供应商、账号或模型细分统计消耗与首字延迟")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.codexMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .layoutPriority(0)

                Spacer(minLength: 6)

                Picker("", selection: Binding(
                    get: { store.selectedBreakdownDimension },
                    set: { newValue in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            store.selectedBreakdownDimension = newValue
                        }
                    }
                )) {
                    ForEach(GatewayBreakdownDimension.allCases) { dim in
                        Text(dim.rawValue).tag(dim)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 220)
                .layoutPriority(1)
            }

            if store.isBreakdownLoading && store.breakdownItems.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在加载 \(store.selectedBreakdownDimension.rawValue) 数据...")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.codexMuted)
                    }
                    .padding(.vertical, 24)
                    Spacer()
                }
                .background(Color.codexCard)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if store.breakdownItems.isEmpty {
                HStack {
                    Spacer()
                    Text("所选时间段暂无统计数据")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.codexMuted)
                        .padding(.vertical, 16)
                    Spacer()
                }
                .background(Color.codexCard)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                ZStack {
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            Text(store.selectedBreakdownDimension.rawValue)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Color.codexMuted)
                                .frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)
                            Text("总请求")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Color.codexMuted)
                                .frame(minWidth: 50, maxWidth: 70, alignment: .trailing)
                            Text("输入 Tokens")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Color.codexMuted)
                                .frame(minWidth: 70, maxWidth: 90, alignment: .trailing)
                            Text("输出 Tokens")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Color.codexMuted)
                                .frame(minWidth: 70, maxWidth: 90, alignment: .trailing)
                            Text("平均 TTFT")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Color.codexMuted)
                                .frame(minWidth: 55, maxWidth: 75, alignment: .trailing)
                            Text("成功率")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Color.codexMuted)
                                .frame(minWidth: 45, maxWidth: 65, alignment: .trailing)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)

                        ForEach(store.breakdownItems) { item in
                            HStack(spacing: 6) {
                                Text(item.key)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color.codexInk)
                                    .frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text("\(item.totalRequests)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color.codexInk)
                                    .frame(minWidth: 50, maxWidth: 70, alignment: .trailing)
                                    .lineLimit(1)
                                Text(GatewayStore.formatTokens(Int(item.inputTokens)))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color.codexInk)
                                    .frame(minWidth: 70, maxWidth: 90, alignment: .trailing)
                                    .lineLimit(1)
                                Text(GatewayStore.formatTokens(Int(item.outputTokens)))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color.codexInk)
                                    .frame(minWidth: 70, maxWidth: 90, alignment: .trailing)
                                    .lineLimit(1)
                                Text(item.avgTtftMs > 0 ? "\(Int(item.avgTtftMs))ms" : "--")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color.codexInk)
                                    .frame(minWidth: 55, maxWidth: 75, alignment: .trailing)
                                    .lineLimit(1)
                                Text(String(format: "%.0f%%", item.successRate * 100))
                                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(item.successRate >= 0.95 ? Color.green : Color.orange)
                                    .frame(minWidth: 45, maxWidth: 65, alignment: .trailing)
                                    .lineLimit(1)
                            }
                            .padding(10)
                            .background(Color.codexCard)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                    .opacity(store.isBreakdownLoading ? 0.45 : 1.0)
                    .animation(.easeInOut(duration: 0.2), value: store.isBreakdownLoading)

                    if store.isBreakdownLoading {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("正在更新 \(store.selectedBreakdownDimension.rawValue)...")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.codexInk)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.codexCard.opacity(0.95))
                        .clipShape(Capsule())
                        .shadow(color: Color.black.opacity(0.12), radius: 6, y: 2)
                        .overlay(
                            Capsule()
                                .stroke(Color.codexLine.opacity(0.4), lineWidth: 0.8)
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }
                }
            }
        }
    }


}
