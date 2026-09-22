import AppKit
import Charts
import SwiftUI

@MainActor
struct GatewayAnalyticsView: View {
    @Bindable var store: GatewayStore

    @State private var hoveredHeatmapCell: GatewayHeatmapCell? = nil
    @State private var hoveredCellLocation: (week: Int, day: Int)? = nil
    @State private var hiddenAnalyticsGroups: Set<String> = []
    @State private var hoveredSlotDate: Date? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // 1. 全局里程碑指标看板 (参考图4顶部极简数据条)
            analyticsMilestoneStripView

            // 2. Token 年度活跃热力图 (参考图4 GitHub 风格全年 52 周矩阵)
            tokenHeatmapSectionView

            // 3. 轮次与用量趋势分析 (参考图2/3平滑极光面积波形图)
            turnsStackedChartSectionView

            // 4. 下方分栏: 模型用量与 Token 构成透视 & 网关性能与接入场景
            HStack(alignment: .top, spacing: 16) {
                modelAndTokenCompositionSectionView
                    .frame(maxWidth: .infinity)
                performanceAndClientsSectionView
                    .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            Task {
                await store.refreshAnalyticsData()
            }
        }
    }

    // MARK: - 1. 全局里程碑指标看板 (参考图 2 极简无边框设计)
    private var analyticsMilestoneStripView: some View {
        let summary = store.heatmapSummary
        let totalTokText = summary.totalTokens > 0 ? GatewayStore.formatTokens(Int(summary.totalTokens)) : "0"
        let peakTokText = summary.peakTokens > 0 ? GatewayStore.formatTokens(Int(summary.peakTokens)) : "0"

        return HStack(spacing: 0) {
            milestoneMetricCard(
                value: totalTokText,
                title: "累计 Token 数"
            )
            CodexDivider(.vertical)
                .frame(height: 28)
            milestoneMetricCard(
                value: peakTokText,
                title: "峰值 Token 数"
            )
            CodexDivider(.vertical)
                .frame(height: 28)
            milestoneMetricCard(
                value: summary.longestSessionDurationText,
                title: "最长连入时长"
            )
            CodexDivider(.vertical)
                .frame(height: 28)
            milestoneMetricCard(
                value: "\(summary.currentStreakDays) 天",
                title: "当前连续天数"
            )
            CodexDivider(.vertical)
                .frame(height: 28)
            milestoneMetricCard(
                value: "\(summary.maxStreakDays) 天",
                title: "最长连续天数"
            )
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .background(Color.codexCard.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.codexLine.opacity(0.25), lineWidth: 0.7)
        )
    }

    private func milestoneMetricCard(
        value: String,
        title: String
    ) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(Color.codexInk)
                .lineLimit(1)

            Text(title)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color.codexMuted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 2. Token 活跃热力图 (参考图 2 极简圆形网格矩阵)
    private var tokenHeatmapSectionView: some View {
        let cells = store.heatmapCells
        let weeks = stride(from: 0, to: cells.count, by: 7).map {
            Array(cells[$0..<min($0 + 7, cells.count)])
        }

        return VStack(alignment: .leading, spacing: 12) {
            // 顶栏: 左侧 'Token 活跃'，右侧 '滚动年 / 某年份' Tab 选择器
            HStack(alignment: .center) {
                Text("Token 活跃")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.codexInk)

                Spacer()

                // 范围切换胶囊: 滚动一年 + 历史各自然年份
                HStack(spacing: 2) {
                    // 1. 滚动一年按钮 (0)
                    let isRolling = store.selectedHeatmapYear == 0
                    Button {
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
                            store.selectedHeatmapYear = 0
                        }
                    } label: {
                        Text("滚动一年")
                            .font(.system(size: 11, weight: isRolling ? .semibold : .medium))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3.5)
                            .background(
                                isRolling ? Color.codexCard : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                            )
                            .shadow(color: isRolling ? Color.black.opacity(0.06) : Color.clear, radius: 1, y: 0.5)
                            .foregroundStyle(isRolling ? Color.codexInk : Color.codexMuted)
                    }
                    .buttonStyle(.plain)

                    // 2. 具体年份按钮 (如 2026年, 2025年)
                    ForEach(store.availableAnalyticsYears, id: \.self) { yr in
                        let isSelected = store.selectedHeatmapYear == yr
                        Button {
                            withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
                                store.selectedHeatmapYear = yr
                            }
                        } label: {
                            Text("\(String(yr))年")
                                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3.5)
                                .background(
                                    isSelected ? Color.codexCard : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                                )
                                .shadow(color: isSelected ? Color.black.opacity(0.06) : Color.clear, radius: 1, y: 0.5)
                                .foregroundStyle(isSelected ? Color.codexInk : Color.codexMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(Color.codexMist.opacity(0.65), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            if cells.isEmpty && store.isAnalyticsLoading {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Text(store.selectedHeatmapYear == 0 ? "正在统计滚动一年 Token 活跃数据..." : "正在统计 \(store.selectedHeatmapYear) 年 Token 活跃数据...")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.codexMuted)
                    Spacer()
                }
                .padding(.vertical, 24)
            } else {
                let totalWeeks = max(1, weeks.count)
                let cellSize: CGFloat = 9.5
                let colSpacing: CGFloat = 3.5
                let colPitch: CGFloat = cellSize + colSpacing
                let matrixWidth: CGFloat = CGFloat(totalWeeks) * cellSize + CGFloat(max(0, totalWeeks - 1)) * colSpacing

                VStack(alignment: .leading, spacing: 6) {
                    // 方块点矩阵 (圆角矩形，每列 7 天，周一到周日)
                    HStack(spacing: colSpacing) {
                        ForEach(weeks.indices, id: \.self) { weekIdx in
                            let weekCells = weeks[weekIdx]
                            VStack(spacing: colSpacing) {
                                ForEach(weekCells.indices, id: \.self) { dayIdx in
                                    let cell = weekCells[dayIdx]
                                    RoundedRectangle(cornerRadius: 2.2, style: .continuous)
                                        .fill(heatmapColor(for: cell.level))
                                        .frame(width: cellSize, height: cellSize)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 2.2, style: .continuous)
                                                .stroke(hoveredHeatmapCell?.id == cell.id ? Color.codexInk : Color.clear, lineWidth: 1.2)
                                        )
                                        .contentShape(Rectangle())
                                        .onHover { isHovered in
                                            if isHovered {
                                                hoveredHeatmapCell = cell
                                                hoveredCellLocation = (week: weekIdx, day: dayIdx)
                                            } else if hoveredHeatmapCell?.id == cell.id {
                                                hoveredHeatmapCell = nil
                                                hoveredCellLocation = nil
                                            }
                                        }
                                }
                            }
                        }
                    }

                    // 月份标签行：采用与矩阵宽度对齐的定位，保证与上方网格列完全对应
                    ZStack(alignment: .leading) {
                        Color.clear
                            .frame(width: matrixWidth, height: 14)

                        ForEach(weeks.indices, id: \.self) { weekIdx in
                            let weekCells = weeks[weekIdx]
                            if let label = weekCells.first(where: { !$0.monthLabel.isEmpty })?.monthLabel, !label.isEmpty {
                                Text(label)
                                    .font(.system(size: 9.5, weight: .regular))
                                    .foregroundStyle(Color.codexMuted.opacity(0.85))
                                    .fixedSize()
                                    .offset(x: CGFloat(weekIdx) * colPitch)
                            }
                        }
                    }
                    .frame(width: matrixWidth, alignment: .leading)
                }
                .frame(width: matrixWidth, alignment: .leading)
                .overlay(alignment: .topLeading) {
                    // 悬停浮层气泡 (精确定位在当前悬停单元格上方)
                    if let hovered = hoveredHeatmapCell, let loc = hoveredCellLocation {
                        let tipX = CGFloat(loc.week) * colPitch + cellSize / 2
                        let tipY = CGFloat(loc.day) * colPitch - 14
                        heatmapTooltipView(for: hovered)
                            .position(
                                x: tipX,
                                y: max(14, tipY)
                            )
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center) // 水平完美居中
                .padding(.top, 2)
            }
        }
        .padding(14)
        .background(Color.codexCard.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.codexLine.opacity(0.25), lineWidth: 0.7)
        )
    }

    private func heatmapTooltipView(for cell: GatewayHeatmapCell) -> some View {
        let df = DateFormatter()
        df.dateFormat = "M月d日"
        let dateStr = df.string(from: cell.date)
        let tokenStr = cell.totalTokens > 0 ? GatewayStore.formatTokens(Int(cell.totalTokens)) : "0"

        return HStack(spacing: 0) {
            Text("\(dateStr) 使用了 \(tokenStr) 个 Token")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.codexInk)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.codexCard)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .shadow(color: Color.black.opacity(0.12), radius: 6, y: 2)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.7)
        )
    }

    private func heatmapColor(for level: Int) -> Color {
        switch level {
        case 0: return Color.codexDynamic(
            light: (0.915, 0.925, 0.938),
            dark: (0.22, 0.23, 0.25)
        )
        case 1: return Color(red: 0.68, green: 0.82, blue: 0.98)
        case 2: return Color(red: 0.44, green: 0.68, blue: 0.95)
        case 3: return Color(red: 0.22, green: 0.50, blue: 0.90)
        case 4: return Color(red: 0.12, green: 0.35, blue: 0.78)
        default: return Color.codexMist.opacity(0.4)
        }
    }

    // MARK: - 3. 轮次与用量趋势分析 (支持按模型、供应商、账号、客户端多维度透视)
    private var turnsStackedChartSectionView: some View {
        let currentGrouping = store.analyticsGrouping
        let allPoints: [GatewayModelTimeseriesPoint] = {
            switch currentGrouping {
            case "provider": return store.providerTimeseriesPoints
            case "account": return store.accountTimeseriesPoints
            case "surface": return store.agentTimeseriesPoints
            default: return store.modelTimeseriesPoints
            }
        }()
        let uniqueGroups = Array(Set(allPoints.map { $0.groupKey })).sorted()

        // 按排序后的图例顺序为每个分组唯一分配色号（分组数 ≤ 调色板数则绝不撞色），
        // 这样同族的多模型各占一色，图例虽密集但每一项颜色独立、可清晰分辨。
        let neutralColor = Color(red: 0.55, green: 0.58, blue: 0.62)
        let groupColors: [String: Color] = {
            var m: [String: Color] = [:]
            var ordinal = 0
            for g in uniqueGroups {
                let k = g.lowercased()
                if k == "other-models" || k == "未知模型" {
                    m[g] = neutralColor
                } else {
                    m[g] = elegantBluePalette[ordinal % elegantBluePalette.count]
                    ordinal += 1
                }
            }
            return m
        }()
        let activePoints = allPoints
            .filter { !hiddenAnalyticsGroups.contains($0.groupKey) }
            .sorted {
                if $0.groupKey != $1.groupKey {
                    return $0.groupKey < $1.groupKey
                }
                return $0.date < $1.date
            }
        let slotDates: [Date] = Array(Set(activePoints.map { $0.date })).sorted()
        let totalTurns = activePoints.reduce(0) { $0 + $1.count }
        let totalTokens = activePoints.reduce(Int64(0)) { $0 + $1.tokens }
        let selectedSlotDate: Date? = hoveredSlotDate

        let isTokensMetric = store.analyticsMetricMode == .tokens
        let heroTitle: String = {
            switch currentGrouping {
            case "provider": return isTokensMetric ? "供应商 Token 用量" : "供应商调用轮次"
            case "account":
                if let p = store.selectedAnalyticsProviderFilter, !p.isEmpty, p != "全部" {
                    return isTokensMetric ? "\(p) 账号 Token 用量" : "\(p) 账号调用轮次"
                }
                return isTokensMetric ? "账号 Token 用量" : "账号调用轮次"
            case "surface": return isTokensMetric ? "客户端 Token 用量" : "客户端会话轮次"
            default: return isTokensMetric ? "模型 Token 用量" : "模型交互轮次"
            }
        }()

        return VStack(alignment: .leading, spacing: 14) {
            // 顶栏: Hero Title 与指标 + 多维度控制胶囊
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(heroTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.codexMuted)

                    if let selectedSlotDate {
                        let hoverMatching = activePoints.filter { pt in
                            abs(pt.date.timeIntervalSince(selectedSlotDate)) < 1.0
                        }
                        let hTurns = hoverMatching.reduce(0) { sum, pt in sum + pt.count }
                        let hToks = hoverMatching.reduce(0) { sum, pt in sum + pt.tokens }
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if isTokensMetric {
                                Text("\(GatewayStore.formatTokens(Int(hToks)))")
                                    .font(.system(size: 32, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.accentColor)

                                Text("· \(hTurns) 轮次 (选定时段)")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.codexMuted)
                            } else {
                                Text("\(hTurns)")
                                    .font(.system(size: 32, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.accentColor)

                                Text("· \(GatewayStore.formatTokens(Int(hToks))) Tokens (选定时段)")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.codexMuted)
                            }
                        }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if isTokensMetric {
                                Text("\(GatewayStore.formatTokens(Int(totalTokens)))")
                                    .font(.system(size: 32, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.codexInk)

                                Text("· \(totalTurns) 轮次")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.codexMuted)
                            } else {
                                Text("\(totalTurns)")
                                    .font(.system(size: 32, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.codexInk)

                                Text("· \(GatewayStore.formatTokens(Int(totalTokens))) Tokens")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.codexMuted)
                            }
                        }
                    }
                }

                Spacer(minLength: 12)

                // 控制栏: 固定分两行排布
                // 第一行: Tokens / 轮次 模式切换 + 面积/堆叠呈现方式 + 时间跨度 (7天 | 30天 | 90天)
                // 第二行: 全部供应商下拉筛选 + By 系列多维切换 (By model | By provider | By account | By surface)
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 8) {
                        metricModePill
                        chartStylePill
                        daysRangePill
                    }
                    .fixedSize(horizontal: true, vertical: false)

                    HStack(spacing: 8) {
                        providerFilterMenu
                        groupingPill
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            if activePoints.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "chart.xyaxis.line")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.codexMuted.opacity(0.6))
                        Text(allPoints.isEmpty ? "当前所选时间段暂无请求轮次数据" : "当前所有图例分类已被隐藏")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.codexMuted)
                        if !hiddenAnalyticsGroups.isEmpty {
                            Button("重置显示所有图例") {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                    hiddenAnalyticsGroups.removeAll()
                                }
                            }
                            .font(.system(size: 11, weight: .medium))
                            .buttonStyle(.link)
                            .padding(.top, 4)
                        }
                    }
                    .padding(.vertical, 36)
                    Spacer()
                }
            } else {
                turnsStackedChartView(activePoints: activePoints, slotDates: slotDates, groupColors: groupColors, neutralColor: neutralColor)
                    .id("turns_chart_\(store.analyticsGrouping)_\(store.analyticsMetricMode.rawValue)_\(store.analyticsChartStyle.rawValue)_\(store.analyticsDaysRange)_\(store.selectedAnalyticsProviderFilter ?? "")_\(hiddenAnalyticsGroups.count)")
                    .frame(height: 200)
                    .transition(.opacity)

                // 交互式可点击图例栏 (自适应内容宽度，允许图例换行，图例项内单行不折行)
                AnalyticsLegendFlowLayout(horizontalSpacing: 14, verticalSpacing: 8, alignment: .leading) {
                    ForEach(uniqueGroups, id: \.self) { grp in
                        legendItemButton(grp: grp, uniqueGroups: uniqueGroups, colors: groupColors, neutral: neutralColor)
                    }

                    if !hiddenAnalyticsGroups.isEmpty {
                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                hiddenAnalyticsGroups.removeAll()
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 8.5))
                                Text("重置图例")
                                    .font(.system(size: 10, weight: .medium))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .fixedSize()
                        .help("恢复展示所有被隐藏的图例分类")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.codexCard.opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.codexLine.opacity(0.3), lineWidth: 0.8)
        )
    }


    // MARK: - 3.1 趋势控制栏子组件
    private var metricModePill: some View {
        HStack(spacing: 2) {
            ForEach(GatewayAnalyticsMetricMode.allCases) { mode in
                let isSelected = store.analyticsMetricMode == mode
                Button {
                    store.analyticsMetricMode = mode
                } label: {
                    Text(mode.rawValue)
                        .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(isSelected ? Color.codexCard : Color.clear, in: Capsule())
                        .foregroundStyle(isSelected ? Color.codexInk : Color.codexMuted)
                        .animation(.spring(response: 0.22, dampingFraction: 0.85), value: isSelected)
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
        }
        .padding(2)
        .background(Color.codexMist.opacity(0.6), in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.6)
        )
        .fixedSize()
    }

    private var chartStylePill: some View {
        HStack(spacing: 2) {
            ForEach(GatewayAnalyticsChartStyle.allCases) { style in
                let isSelected = store.analyticsChartStyle == style
                Button {
                    store.analyticsChartStyle = style
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: style == .area ? "waveform.path.ecg" : "chart.bar.fill")
                            .font(.system(size: 8.5))
                        Text(style.rawValue)
                            .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isSelected ? Color.codexCard : Color.clear, in: Capsule())
                    .foregroundStyle(isSelected ? Color.codexInk : Color.codexMuted)
                    .animation(.spring(response: 0.22, dampingFraction: 0.85), value: isSelected)
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
        }
        .padding(2)
        .background(Color.codexMist.opacity(0.6), in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.6)
        )
        .fixedSize()
    }

    @ViewBuilder
    private var providerFilterMenu: some View {
        if !store.availableAnalyticsProviders.isEmpty {
            Menu {
                Button("全部供应商") {
                    store.selectedAnalyticsProviderFilter = nil
                    Task { await store.refreshAnalyticsData() }
                }
                Divider()
                ForEach(store.availableAnalyticsProviders, id: \.self) { prov in
                    Button(prov) {
                        store.selectedAnalyticsProviderFilter = prov
                        Task { await store.refreshAnalyticsData() }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 10))
                    Text(store.selectedAnalyticsProviderFilter ?? "全部供应商")
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7.5))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    store.selectedAnalyticsProviderFilter != nil ? Color.accentColor.opacity(0.12) : Color.codexMist.opacity(0.6),
                    in: Capsule()
                )
                .overlay(
                    Capsule()
                        .stroke(store.selectedAnalyticsProviderFilter != nil ? Color.accentColor.opacity(0.4) : Color.codexLine.opacity(0.35), lineWidth: 0.6)
                )
                .foregroundStyle(store.selectedAnalyticsProviderFilter != nil ? Color.accentColor : Color.codexInk)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("筛选指定供应商，查看同供应商名下的账号或模型表现")
        }
    }

    private var groupingPill: some View {
        HStack(spacing: 2) {
            groupingPillButton(title: "By model", key: "model")
            groupingPillButton(title: "By provider", key: "provider")
            groupingPillButton(title: "By account", key: "account")
            groupingPillButton(title: "By surface", key: "surface")
        }
        .padding(2)
        .background(Color.codexMist.opacity(0.6), in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.6)
        )
        .fixedSize()
    }

    private var daysRangePill: some View {
        HStack(spacing: 2) {
            daysPillButton(days: 7)
            daysPillButton(days: 30)
            daysPillButton(days: 90)
        }
        .padding(2)
        .background(Color.codexMist.opacity(0.6), in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.6)
        )
        .fixedSize()
    }

    private static let tooltipDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "MM/dd HH:mm"
        return df
    }()

    private func findClosestSlotDate(to targetDate: Date, in slotDates: [Date]) -> Date? {
        guard !slotDates.isEmpty else { return nil }
        var low = 0
        var high = slotDates.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if slotDates[mid] < targetDate {
                low = mid + 1
            } else if slotDates[mid] > targetDate {
                high = mid - 1
            } else {
                return slotDates[mid]
            }
        }
        if low >= slotDates.count { return slotDates[slotDates.count - 1] }
        if high < 0 { return slotDates[0] }
        let d1 = abs(slotDates[low].timeIntervalSince(targetDate))
        let d2 = abs(slotDates[high].timeIntervalSince(targetDate))
        return d1 < d2 ? slotDates[low] : slotDates[high]
    }

    @ViewBuilder
    private func chartTooltipPopup(for date: Date, in activePoints: [GatewayModelTimeseriesPoint], groupColors: [String: Color], neutralColor: Color) -> some View {
        let matching = activePoints.filter { abs($0.date.timeIntervalSince(date)) < 1.0 }
        let totalTurns = matching.reduce(0) { $0 + $1.count }
        let totalTokens = matching.reduce(0) { $0 + $1.tokens }
        let dateString = Self.tooltipDateFormatter.string(from: date)

        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(dateString)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.codexMuted)
                Spacer(minLength: 4)
                Text("\(totalTurns) 轮")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.09, green: 0.49, blue: 0.98))
            }

            if totalTokens > 0 {
                Text("\(GatewayStore.formatTokens(Int(totalTokens))) Tokens")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.codexMuted.opacity(0.85))
            }

            Rectangle()
                .fill(Color.codexLine.opacity(0.25))
                .frame(height: 0.6)

            let isTokensMetric = store.analyticsMetricMode == .tokens
            let activeItems = matching
                .filter { $0.count > 0 || $0.tokens > 0 }
                .sorted {
                    if isTokensMetric {
                        if $0.tokens != $1.tokens {
                            return $0.tokens > $1.tokens
                        }
                        return $0.count > $1.count
                    } else {
                        if $0.count != $1.count {
                            return $0.count > $1.count
                        }
                        return $0.tokens > $1.tokens
                    }
                }
            if activeItems.isEmpty {
                Text("无活动记录")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.codexMuted)
            } else {
                ForEach(activeItems, id: \.groupKey) { item in
                    let isOther = item.groupKey == "other-models"
                    HStack(spacing: 5) {
                        Circle()
                            .fill(groupColors[item.groupKey] ?? neutralColor)
                            .frame(width: 5.5, height: 5.5)
                        Text(isOther ? "other-models" : item.groupKey)
                            .font(.system(size: 9.5))
                            .foregroundStyle(Color.codexInk.opacity(0.88))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 6)
                        if isTokensMetric {
                            Text(GatewayStore.formatTokens(item.tokens))
                                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.codexInk)
                        } else {
                            Text("\(item.count) 轮")
                                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.codexInk)
                        }
                    }
                    .help(isOther ? "包含周期内用量小于 10,000 Tokens 的低频模型集合" : item.groupKey)
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

    @ViewBuilder
    private func turnsStackedChartView(
        activePoints: [GatewayModelTimeseriesPoint],
        slotDates: [Date],
        groupColors: [String: Color],
        neutralColor: Color
    ) -> some View {
        let isTokens = store.analyticsMetricMode == .tokens
        let style = store.analyticsChartStyle

        Chart {
            ForEach(activePoints) { (pt: GatewayModelTimeseriesPoint) in
                let y = isTokens ? pt.tokens : Int64(pt.count)
                if style == .bars {
                    BarMark(
                        x: .value("Date", pt.date),
                        y: .value(isTokens ? "Tokens" : "Turns", y),
                        stacking: .standard
                    )
                    .foregroundStyle((groupColors[pt.groupKey] ?? neutralColor).opacity(0.85))
                    .cornerRadius(2)
                } else {
                    AreaMark(
                        x: .value("Date", pt.date),
                        y: .value(isTokens ? "Tokens" : "Turns", y),
                        series: .value("Group", pt.groupKey),
                        stacking: .standard
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle((groupColors[pt.groupKey] ?? neutralColor).opacity(0.78))
                }
            }
        }
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    .foregroundStyle(Color.codexLine.opacity(0.25))
                AxisValueLabel {
                    if isTokens {
                        if let intVal = value.as(Int64.self) {
                            Text(GatewayStore.formatTokens(intVal))
                                .font(.system(size: 9))
                                .foregroundStyle(Color.codexMuted.opacity(0.8))
                        } else if let intVal = value.as(Int.self) {
                            Text(GatewayStore.formatTokens(Int64(intVal)))
                                .font(.system(size: 9))
                                .foregroundStyle(Color.codexMuted.opacity(0.8))
                        }
                    } else {
                        if let intVal = value.as(Int.self) {
                            Text("\(intVal)")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.codexMuted.opacity(0.8))
                        }
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { (value: AxisValue) in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    .foregroundStyle(Color.codexLine.opacity(0.2))
                if let dt = value.as(Date.self) {
                    AxisValueLabel {
                        Text(dt, format: .dateTime.month(.defaultDigits).day())
                            .font(.system(size: 9))
                            .foregroundStyle(Color.codexMuted.opacity(0.8))
                    }
                }
            }
        }
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

                                // 允许横向在 plotArea 边缘有微量缓冲（±8px），超出则取消 hover
                                guard location.x >= plotArea.minX - 8 && location.x <= plotArea.maxX + 8 else {
                                    if hoveredSlotDate != nil {
                                        hoveredSlotDate = nil
                                    }
                                    return
                                }
                                guard location.y >= 0 && location.y <= geo.size.height else {
                                    if hoveredSlotDate != nil {
                                        hoveredSlotDate = nil
                                    }
                                    return
                                }

                                // 关键修复：proxy.value(atX:) 接受的是相对于 plotArea 绘图区域的 x 坐标！
                                let xInPlot = max(0, min(location.x - plotArea.origin.x, plotArea.width))
                                if let date: Date = proxy.value(atX: xInPlot),
                                   let snapped = findClosestSlotDate(to: date, in: slotDates) {
                                    if hoveredSlotDate != snapped {
                                        hoveredSlotDate = snapped
                                    }
                                }
                            case .ended:
                                if hoveredSlotDate != nil {
                                    hoveredSlotDate = nil
                                }
                            }
                        }

                    if let selectedSlotDate = hoveredSlotDate,
                       let xPos = proxy.position(forX: selectedSlotDate),
                       let plotFrame = proxy.plotFrame {
                        let actualX = xPos + geo[plotFrame].origin.x
                        // 1. 垂直指示虚线 (在 overlay 中用 Path 直接绘制，无任何 Swift Charts 重绘开销)
                        Path { path in
                            path.move(to: CGPoint(x: actualX, y: geo[plotFrame].minY))
                            path.addLine(to: CGPoint(x: actualX, y: geo[plotFrame].maxY))
                        }
                        .stroke(Color(red: 0.09, green: 0.49, blue: 0.98).opacity(0.85), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))

                        // 2. 悬浮 Tooltip 气泡
                        let plotWidth = geo[plotFrame].width
                        let isRightSide = actualX > (geo[plotFrame].minX + plotWidth / 2)
                        let tooltipX: CGFloat = isRightSide
                            ? max(actualX - 98, geo[plotFrame].minX + 92)
                            : min(actualX + 98, geo[plotFrame].maxX - 92)
                        let tooltipY: CGFloat = geo[plotFrame].minY + 45

                        chartTooltipPopup(for: selectedSlotDate, in: activePoints, groupColors: groupColors, neutralColor: neutralColor)
                            .position(x: tooltipX, y: tooltipY)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

// MARK: - 4. 模型消耗与 Token 构成透视 (左卡片)
    private var modelAndTokenCompositionSectionView: some View {
        let comp = store.analyticsTokenComposition

        return VStack(alignment: .leading, spacing: 14) {
            // 头部指标
            VStack(alignment: .leading, spacing: 2) {
                Text("模型消耗与 Token 结构")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.codexMuted)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(comp.totalTokens > 0 ? GatewayStore.formatTokens(comp.totalTokens) : "0")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.codexInk)
                    Text("总 Token 吞吐")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.codexMuted)
                }
            }

            // 1. Token 输入/输出/缓存 比例条
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Token 构成透视")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.codexInk.opacity(0.85))
                    Spacer()
                    if comp.totalTokens > 0 {
                        Text("输入 \(Int(comp.inputPercentage))% · 输出 \(Int(comp.outputPercentage))%")
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.codexMuted)
                    }
                }

                // 双段比例条
                GeometryReader { geo in
                    let w = geo.size.width
                    let inW = comp.totalTokens > 0 ? max(2, w * CGFloat(comp.inputPercentage / 100.0)) : 0
                    let outW = max(0, w - inW)

                    HStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color(red: 0.09, green: 0.49, blue: 0.98))
                            .frame(width: max(0, inW - 1))
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color(red: 0.45, green: 0.75, blue: 0.98))
                            .frame(width: max(0, outW - 1))
                    }
                }
                .frame(height: 7)

                // 比例指标项
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Circle().fill(Color(red: 0.09, green: 0.49, blue: 0.98)).frame(width: 5.5, height: 5.5)
                        Text("输入: \(GatewayStore.formatTokens(comp.inputTokens))")
                            .font(.system(size: 9.5))
                            .foregroundStyle(Color.codexMuted)
                            .lineLimit(1)
                    }
                    HStack(spacing: 4) {
                        Circle().fill(Color(red: 0.45, green: 0.75, blue: 0.98)).frame(width: 5.5, height: 5.5)
                        Text("输出: \(GatewayStore.formatTokens(comp.outputTokens))")
                            .font(.system(size: 9.5))
                            .foregroundStyle(Color.codexMuted)
                            .lineLimit(1)
                    }
                    if comp.cacheReadTokens > 0 {
                        HStack(spacing: 4) {
                            Circle().fill(Color(red: 0.14, green: 0.30, blue: 0.66)).frame(width: 5.5, height: 5.5)
                            Text("缓存: \(GatewayStore.formatTokens(comp.cacheReadTokens))")
                                .font(.system(size: 9.5))
                                .foregroundStyle(Color.codexMuted)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(10)
            .background(Color.codexMist.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Rectangle()
                .fill(Color.codexLine.opacity(0.25))
                .frame(height: 0.6)

            // 2. 多维用量结构排行 (支持按模型、供应商、账号)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    Text(rankingSectionTitle)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.codexMuted)
                        .lineLimit(1)
                        .layoutPriority(1)

                    Spacer(minLength: 12)

                    // 排行维度选择器
                    HStack(spacing: 2) {
                        ForEach(GatewayAnalyticsRankingDimension.allCases) { dim in
                            let isSelected = store.analyticsRankingDimension == dim
                            Button {
                                withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                                    store.analyticsRankingDimension = dim
                                }
                            } label: {
                                Text(dim.rawValue)
                                    .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(isSelected ? Color.codexCard : Color.clear, in: Capsule())
                                    .foregroundStyle(isSelected ? Color.codexInk : Color.codexMuted)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .fixedSize()
                        }
                    }
                    .padding(2)
                    .background(Color.codexMist.opacity(0.6), in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.6)
                    )
                    .fixedSize()
                }

                switch store.analyticsRankingDimension {
                case .model:
                    modelRankingsListView
                case .provider:
                    providerRankingsListView
                case .account:
                    accountRankingsListView
                }
            }
        }
        .padding(16)
        .background(Color.codexCard.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.codexLine.opacity(0.3), lineWidth: 0.8)
        )
    }

    private var rankingSectionTitle: String {
        switch store.analyticsRankingDimension {
        case .model: return "Top 模型消耗"
        case .provider: return "Top 供应商消耗"
        case .account:
            if let p = store.selectedAnalyticsProviderFilter, !p.isEmpty, p != "全部" {
                return "\(p) 账号消耗"
            }
            return "Top 账号消耗"
        }
    }

    // 模型排行列表
    private var modelRankingsListView: some View {
        let models = store.analyticsModelRankings
        return Group {
            if models.isEmpty {
                Text("暂无模型记录")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.codexMuted)
                    .padding(.vertical, 8)
            } else {
                let maxToks = max(1, models.first?.tokens ?? 1)
                ForEach(models) { item in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(colorForCategory(item.name))
                            .frame(width: 6, height: 6)
                        Text(item.name)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.codexInk)
                            .frame(width: 95, alignment: .leading)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        GeometryReader { g in
                            let barW = max(4, g.size.width * CGFloat(item.tokens) / CGFloat(maxToks))
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.codexMist.opacity(0.4))
                                Capsule().fill(colorForCategory(item.name).opacity(0.85))
                                    .frame(width: barW)
                            }
                        }
                        .frame(height: 6)

                        HStack(spacing: 4) {
                            Spacer(minLength: 0)
                            Text(GatewayStore.formatTokens(item.tokens))
                                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.codexInk)
                                .lineLimit(1)
                            Text("(\(String(format: "%.0f%%", item.percentage)))")
                                .font(.system(size: 8.5))
                                .foregroundStyle(Color.codexMuted)
                                .lineLimit(1)
                        }
                        .lineLimit(1)
                        .frame(width: 96, alignment: .trailing)
                    }
                }
            }
        }
    }

    // 供应商排行列表
    private var providerRankingsListView: some View {
        let providers = store.analyticsProviderRankings
        return Group {
            if providers.isEmpty {
                Text("暂无供应商消耗记录")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.codexMuted)
                    .padding(.vertical, 8)
            } else {
                let maxToks = max(1, providers.first?.tokens ?? 1)
                ForEach(providers) { item in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(colorForCategory(item.name))
                            .frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.codexInk)
                                .lineLimit(1)
                            Text("\(item.accountsCount) 个已连账号")
                                .font(.system(size: 8.5))
                                .foregroundStyle(Color.codexMuted)
                                .lineLimit(1)
                        }
                        .frame(width: 105, alignment: .leading)

                        GeometryReader { g in
                            let barW = max(4, g.size.width * CGFloat(item.tokens) / CGFloat(maxToks))
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.codexMist.opacity(0.4))
                                Capsule().fill(colorForCategory(item.name).opacity(0.85))
                                    .frame(width: barW)
                            }
                        }
                        .frame(height: 6)

                        HStack(spacing: 4) {
                            Spacer(minLength: 0)
                            Text(GatewayStore.formatTokens(item.tokens))
                                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.codexInk)
                                .lineLimit(1)
                            Text("(\(String(format: "%.0f%%", item.percentage)))")
                                .font(.system(size: 8.5))
                                .foregroundStyle(Color.codexMuted)
                                .lineLimit(1)
                        }
                        .lineLimit(1)
                        .frame(width: 96, alignment: .trailing)
                    }
                }
            }
        }
    }

    // 账号排行列表 (解决同供应商不同账号查看痛点)
    private var accountRankingsListView: some View {
        let accounts = store.analyticsAccountRankings
        return Group {
            if accounts.isEmpty {
                Text("暂无账号消耗记录")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.codexMuted)
                    .padding(.vertical, 8)
            } else {
                let maxToks = max(1, accounts.first?.tokens ?? 1)
                ForEach(accounts) { item in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(colorForCategory(item.name))
                            .frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.codexInk)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text(item.provider)
                                .font(.system(size: 8.5))
                                .foregroundStyle(Color.codexMuted)
                                .lineLimit(1)
                        }
                        .frame(width: 105, alignment: .leading)

                        GeometryReader { g in
                            let barW = max(4, g.size.width * CGFloat(item.tokens) / CGFloat(maxToks))
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.codexMist.opacity(0.4))
                                Capsule().fill(colorForCategory(item.name).opacity(0.85))
                                    .frame(width: barW)
                            }
                        }
                        .frame(height: 6)

                        HStack(spacing: 4) {
                            Spacer(minLength: 0)
                            Text(GatewayStore.formatTokens(item.tokens))
                                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.codexInk)
                                .lineLimit(1)
                            Text("(\(String(format: "%.0f%%", item.percentage)))")
                                .font(.system(size: 8.5))
                                .foregroundStyle(Color.codexMuted)
                                .lineLimit(1)
                        }
                        .lineLimit(1)
                        .frame(width: 96, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - 5. 网关性能基准与客户端透视 (右卡片)
    private var performanceAndClientsSectionView: some View {
        let latencies = store.analyticsLatencyRankings
        let clients = store.analyticsClientRankings
        let overallAvgTtft = latencies.isEmpty ? 0 : latencies.reduce(0) { $0 + $1.avgTtftMs } / latencies.count

        return VStack(alignment: .leading, spacing: 14) {
            // 头部指标
            VStack(alignment: .leading, spacing: 2) {
                Text("网关性能与接入场景")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.codexMuted)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(overallAvgTtft > 0 ? "\(overallAvgTtft) ms" : "--")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.codexInk)
                    Text("平均首字延迟 (TTFT)")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.codexMuted)
                }
            }

            // 1. 各模型首字延迟基准 (TTFT 吐字速度)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("模型首字延迟 (TTFT 流式吐字速度)")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.codexInk.opacity(0.85))
                    Spacer()
                    Text("越低越快")
                        .font(.system(size: 8.5))
                        .foregroundStyle(Color.codexMuted.opacity(0.7))
                }

                if latencies.isEmpty {
                    Text("暂无首字延迟采样记录")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.codexMuted)
                        .padding(.vertical, 8)
                } else {
                    let maxTtft = max(1, latencies.map { $0.avgTtftMs }.max() ?? 1)
                    ForEach(latencies) { item in
                        HStack(spacing: 8) {
                            Text(item.name)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.codexInk)
                                .frame(width: 95, alignment: .leading)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            // 延迟条
                            GeometryReader { g in
                                let barW = max(4, g.size.width * CGFloat(item.avgTtftMs) / CGFloat(max(maxTtft, 1200)))
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.codexMist.opacity(0.4))
                                    Capsule()
                                        .fill(ttftColor(item.avgTtftMs))
                                        .frame(width: barW)
                                }
                            }
                            .frame(height: 6)

                            // 毫秒数与速度徽标
                            HStack(spacing: 3) {
                                Spacer(minLength: 0)
                                Text("\(item.avgTtftMs)ms")
                                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Color.codexInk)
                                    .lineLimit(1)
                                Text(ttftBadge(item.avgTtftMs))
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(ttftColor(item.avgTtftMs))
                                    .lineLimit(1)
                                    .padding(.horizontal, 3.5)
                                    .padding(.vertical, 1)
                                    .background(ttftColor(item.avgTtftMs).opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                            }
                            .lineLimit(1)
                            .frame(width: 78, alignment: .trailing)
                        }
                    }
                }
            }
            .padding(10)
            .background(Color.codexMist.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Rectangle()
                .fill(Color.codexLine.opacity(0.25))
                .frame(height: 0.6)

            // 2. 客户端 / Agent 接入排行
            VStack(alignment: .leading, spacing: 8) {
                Text("客户端 / Agent 接入排行")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.codexMuted)

                if clients.isEmpty {
                    Text("暂无客户端数据")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.codexMuted)
                        .padding(.vertical, 8)
                } else {
                    let maxClientToks = max(1, clients.first?.tokens ?? 1)
                    ForEach(clients) { item in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(colorForCategory(item.name))
                                .frame(width: 6, height: 6)
                            Text(item.name)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.codexInk)
                                .frame(width: 95, alignment: .leading)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            // 进度条
                            GeometryReader { g in
                                let barW = max(4, g.size.width * CGFloat(item.tokens) / CGFloat(maxClientToks))
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.codexMist.opacity(0.4))
                                    Capsule().fill(colorForCategory(item.name).opacity(0.85))
                                        .frame(width: barW)
                                }
                            }
                            .frame(height: 6)

                            // 数值与轮次
                            HStack(spacing: 4) {
                                Spacer(minLength: 0)
                                Text(GatewayStore.formatTokens(item.tokens))
                                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Color.codexInk)
                                    .lineLimit(1)
                                Text("(\(item.turns)轮)")
                                    .font(.system(size: 8.5))
                                    .foregroundStyle(Color.codexMuted)
                                    .lineLimit(1)
                            }
                            .lineLimit(1)
                            .frame(width: 108, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color.codexCard.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.codexLine.opacity(0.3), lineWidth: 0.8)
        )
    }

    private func ttftColor(_ ms: Int) -> Color {
        if ms < 500 {
            return Color(red: 0.10, green: 0.65, blue: 0.40)
        } else if ms < 1000 {
            return Color(red: 0.09, green: 0.49, blue: 0.98)
        } else {
            return Color(red: 0.85, green: 0.52, blue: 0.15)
        }
    }

    private func ttftBadge(_ ms: Int) -> String {
        if ms < 500 {
            return "极速"
        } else if ms < 1000 {
            return "良好"
        } else {
            return "较慢"
        }
    }

    // 冷色相近但可区分的调色板 (蓝 → 青 → 靛 → 紫灰谱系，同一模型始终独占一色)
    private let elegantBluePalette: [Color] = [
        Color(red: 0.09, green: 0.49, blue: 0.98), // 0: 经典亮蓝 (Primary Tech Blue)
        Color(red: 0.45, green: 0.75, blue: 0.98), // 1: 柔和天蓝 (Sky Blue)
        Color(red: 0.14, green: 0.30, blue: 0.66), // 2: 沉稳藏青 (Deep Cobalt Navy)
        Color(red: 0.24, green: 0.60, blue: 0.90), // 3: 蔚蓝海蓝 (Cerulean Azure)
        Color(red: 0.38, green: 0.52, blue: 0.70), // 4: 雅致钢蓝 (Steel Slate Blue)
        Color(red: 0.60, green: 0.82, blue: 0.96), // 5: 浅冰晶蓝 (Glacier Ice Blue)
        Color(red: 0.30, green: 0.44, blue: 0.62), // 6: 沉静灰蓝 (Muted Slate Blue)
        Color(red: 0.10, green: 0.62, blue: 0.55), // 7: 清透湖绿 (Teal)
        Color(red: 0.55, green: 0.85, blue: 0.75), // 8: 薄荷青 (Mint Teal)
        Color(red: 0.20, green: 0.48, blue: 0.42), // 9: 深邃墨绿 (Deep Jade)
        Color(red: 0.20, green: 0.68, blue: 0.82), // 10: 冰蓝 Cyan (Cyan Blue)
        Color(red: 0.72, green: 0.88, blue: 0.94), // 11: 淡雾青 (Ice Cyan)
        Color(red: 0.35, green: 0.30, blue: 0.85), // 12: 深靛蓝 (Deep Indigo)
        Color(red: 0.70, green: 0.42, blue: 0.90), // 13: 柔和紫罗兰 (Soft Violet)
        Color(red: 0.85, green: 0.65, blue: 0.92), // 14: 浅紫丁香 (Lavender)
        Color(red: 0.40, green: 0.36, blue: 0.60), // 15: 蓝紫灰 (Slate Purple)
        Color(red: 0.28, green: 0.22, blue: 0.55), // 16: 深邃紫 (Deep Violet)
        Color(red: 0.42, green: 0.66, blue: 0.82), // 17: 灰蓝 (Steel Blue)
        Color(red: 0.16, green: 0.54, blue: 0.72), // 18: 湖蓝 (Aqua Teal)
        Color(red: 0.50, green: 0.58, blue: 0.74), // 19: 雾灰蓝 (Ash Blue)
    ]

    // 确定性字符串哈希 (DJB2)：跨启动稳定，保证同一模型永远映射到同一颜色
    private func stableHash(_ s: String) -> Int {
        var h = 5381
        for byte in s.utf8 {
            h = ((h << 5) &+ h) &+ Int(byte)
        }
        return h & 0x7fffffff
    }

    // 每个分类项独占一色：按名称稳定哈希取色，杜绝同族模型撞色
    private func colorForCategory(_ key: String) -> Color {
        let k = key.lowercased()
        if k == "other-models" || k == "未知模型" {
            return Color(red: 0.55, green: 0.58, blue: 0.62) // 中性灰，明确区分"汇总集合"
        }
        return elegantBluePalette[stableHash(k) % elegantBluePalette.count]
    }

    private func groupingPillButton(title: String, key: String) -> some View {
        let isSelected = store.analyticsGrouping == key
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                store.analyticsGrouping = key
                hiddenAnalyticsGroups.removeAll()
            }
        } label: {
            Text(title)
                .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(isSelected ? Color.codexCard : Color.clear, in: Capsule())
                .foregroundStyle(isSelected ? Color.codexInk : Color.codexMuted)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func daysPillButton(days: Int) -> some View {
        let isSelected = store.analyticsDaysRange == days
        return Button {
            store.analyticsDaysRange = days
            hiddenAnalyticsGroups.removeAll()
            Task { await store.refreshAnalyticsData() }
        } label: {
            Text("\(days)天")
                .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isSelected ? Color.codexCard : Color.clear, in: Capsule())
                .foregroundStyle(isSelected ? Color.codexInk : Color.codexMuted)
                .animation(.spring(response: 0.22, dampingFraction: 0.85), value: isSelected)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func toggleLegendGroup(_ grp: String, uniqueGroups: [String]) {
        if hiddenAnalyticsGroups.contains(grp) {
            hiddenAnalyticsGroups.remove(grp)
        } else {
            let activeCount = uniqueGroups.filter { !hiddenAnalyticsGroups.contains($0) }.count
            if activeCount <= 1 {
                hiddenAnalyticsGroups.removeAll()
            } else {
                hiddenAnalyticsGroups.insert(grp)
            }
        }
    }

    private func legendItemButton(grp: String, uniqueGroups: [String], colors: [String: Color], neutral: Color) -> some View {
        let isHidden = hiddenAnalyticsGroups.contains(grp)
        let isOtherModels = grp == "other-models"

        return Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                toggleLegendGroup(grp, uniqueGroups: uniqueGroups)
            }
        } label: {
            HStack(spacing: 5) {
                Capsule(style: .continuous)
                    .fill(isHidden ? Color.codexMuted.opacity(0.35) : (colors[grp] ?? neutral))
                    .frame(width: 12, height: 2.5)

                Text(isOtherModels ? "other-models (微量模型集合)" : grp)
                    .font(.system(size: 11, weight: isHidden ? .regular : .medium))
                    .foregroundStyle(isHidden ? Color.codexMuted.opacity(0.40) : Color.codexInk.opacity(0.88))
                    .strikethrough(isHidden, color: Color.codexMuted.opacity(0.40))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                if isOtherModels {
                    Text("低频汇总")
                        .font(.system(size: 8.5))
                        .foregroundStyle(Color.codexMuted.opacity(0.75))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.codexMist.opacity(0.5), in: RoundedRectangle(cornerRadius: 3))
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .help(isOtherModels ? "包含当前周期内 Token 用量小于 10,000 的低频模型集合，点击隐藏或显示" : (isHidden ? "点击重新展示 \(grp)" : "点击隐藏 \(grp)"))
    }
}

// MARK: - 自适应流式图例布局 (支持自然靠左对齐、按内容自适应宽度、图例换行、图例内文字不折行)
struct AnalyticsLegendFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 16
    var verticalSpacing: CGFloat = 8
    var alignment: HorizontalAlignment = .leading

    struct Row {
        var subviews: [LayoutSubview] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = []
        var currentRow = Row()

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let neededWidth = currentRow.subviews.isEmpty ? size.width : (currentRow.width + horizontalSpacing + size.width)

            if neededWidth > maxWidth && !currentRow.subviews.isEmpty {
                rows.append(currentRow)
                currentRow = Row(subviews: [subview], sizes: [size], width: size.width, height: size.height)
            } else {
                currentRow.subviews.append(subview)
                currentRow.sizes.append(size)
                currentRow.width = neededWidth
                currentRow.height = max(currentRow.height, size.height)
            }
        }

        if !currentRow.subviews.isEmpty {
            rows.append(currentRow)
        }

        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        let maxWidth = proposal.width ?? .infinity
        let totalHeight = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * verticalSpacing
        let maxRowWidth = rows.reduce(0) { max($0, $1.width) }
        return CGSize(width: maxWidth.isFinite ? maxWidth : maxRowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)
        var y = bounds.minY

        for row in rows {
            let xOffset: CGFloat
            switch alignment {
            case .leading:
                xOffset = 0
            case .trailing:
                xOffset = max(0, bounds.width - row.width)
            case .center:
                xOffset = max(0, (bounds.width - row.width) / 2.0)
            default:
                xOffset = 0
            }
            var x = bounds.minX + xOffset

            for (subview, size) in zip(row.subviews, row.sizes) {
                let yOffset = (row.height - size.height) / 2.0
                subview.place(
                    at: CGPoint(x: x, y: y + yOffset),
                    proposal: ProposedViewSize(width: ceil(size.width) + 1, height: ceil(size.height))
                )
                x += size.width + horizontalSpacing
            }

            y += row.height + verticalSpacing
        }
    }
}
