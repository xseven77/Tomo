import SwiftUI

@MainActor
struct GatewayModelCheckBanner: View {
    @Bindable var store: GatewayStore
    var onToast: GatewayToastHandler

    @State private var isExpanded = false
    /// 点击展开的巡检记录（按列表下标定位），用于查看单条探测的成功/错误详情。
    @State private var expandedResultIndices: Set<Int> = []

    var body: some View {
        Group {
            if store.isModelCheckRunning {
                let status = store.modelCheckStatus
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .controlSize(.small)

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(status?.scope == "all" ? "正在执行全量模型健康巡检" : "正在执行账号模型健康巡检")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(Color.codexInk)

                                        if let status, status.total > 0 {
                                            Text("(\(status.done)/\(status.total))")
                                                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                                .foregroundStyle(Color.accentColor)
                                        } else {
                                            Text("正在启动巡检...")
                                                .font(.system(size: 10.5))
                                                .foregroundStyle(Color.codexMuted)
                                        }
                                    }

                                    if let status {
                                        compactProgress(status)
                                    }
                                }

                                Spacer(minLength: 8)

                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(Color.codexMuted)
                                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                            }
                            .contentShape(Rectangle())
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .help(isExpanded ? "收起巡检过程" : "展开巡检过程")

                        if let startedAt = status?.startedAt, startedAt > 0 {
                            ModelCheckElapsedTimeView(startedAtEpoch: startedAt)
                        }

                        Button {
                            Task {
                                let result = await store.cancelModelCheck()
                                onToast(
                                    result.message,
                                    result.success ? "stop.circle" : "exclamationmark.triangle",
                                    result.success
                                )
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "xmark.circle.fill")
                                Text(store.isCancellingModelCheck ? "正在取消..." : "取消巡检")
                            }
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.codexLine.opacity(0.2), in: RoundedRectangle(cornerRadius: 5))
                            .foregroundStyle(Color.codexInk)
                        }
                        .buttonStyle(.plain)
                        .disabled(store.isCancellingModelCheck)
                    }

                    if isExpanded, let status {
                        Divider()
                            .overlay(Color.accentColor.opacity(0.16))
                            .padding(.top, 10)

                        expandedProgress(status)
                            .padding(.top, 10)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 1)
                )
            }
        }
        .onChange(of: store.isModelCheckRunning) { _, isRunning in
            if !isRunning {
                isExpanded = false
            }
        }
    }

    @ViewBuilder
    private func compactProgress(_ status: GatewayModelCheckJobStatus) -> some View {
        let currentResultIndex = status.results.lastIndex { $0.scopedId == status.current }
        let currentResult = currentResultIndex.map { status.results[$0] }
        let previousResult: GatewayModelCheckResult? =
            if let currentResultIndex, currentResultIndex > 0 {
                status.results[currentResultIndex - 1]
            } else if currentResultIndex == nil {
                status.results.last
            } else {
                nil
            }

        HStack(spacing: 10) {
            if !status.current.isEmpty {
                compactItem(
                    label: "当前",
                    scopedId: status.current,
                    result: currentResult,
                    isRunning: currentResult == nil
                )
            }
            if let previousResult {
                compactItem(
                    label: "上一条",
                    scopedId: previousResult.scopedId,
                    result: previousResult,
                    isRunning: false
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compactItem(
        label: String,
        scopedId: String,
        result: GatewayModelCheckResult?,
        isRunning: Bool
    ) -> some View {
        HStack(spacing: 4) {
            Text("\(label)：")
                .foregroundStyle(Color.codexMuted.opacity(0.82))
            statusIcon(result: result, isRunning: isRunning)
            if isRunning {
                Text("探测中")
                    .foregroundStyle(Color.accentColor)
            } else if let result {
                Text(statusLabel(result.status))
                    .foregroundStyle(statusColor(result.status))
            }
            Text("·")
                .foregroundStyle(Color.codexMuted.opacity(0.6))
            Text(scopedId)
                .foregroundStyle(Color.codexMuted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 10.5))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func expandedProgress(_ status: GatewayModelCheckJobStatus) -> some View {
        let successCount = status.results.filter { $0.status == "available" }.count
        let failureCount = status.results.filter { $0.status == "unavailable" || $0.status == "error" }
            .count

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("巡检过程")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.codexInk)
                Text("成功 \(successCount)")
                    .foregroundStyle(Color.green)
                Text("失败 \(failureCount)")
                    .foregroundStyle(Color.red)
                Spacer()
                Text("单条最多等待 8s")
                    .foregroundStyle(Color.codexMuted.opacity(0.8))
            }
            .font(.system(size: 10.5, design: .monospaced))

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 5) {
                    ForEach(Array(status.results.enumerated()), id: \.offset) { index, result in
                        completedRow(index: index + 1, result: result)
                    }

                    if !status.current.isEmpty,
                        status.results.last(where: { $0.scopedId == status.current }) == nil
                    {
                        activeRow(index: status.results.count + 1, scopedId: status.current)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .background(ScrollIndicatorHider())
            .frame(maxHeight: 280)
        }
    }

    private func completedRow(index: Int, result: GatewayModelCheckResult) -> some View {
        let isExpanded = expandedResultIndices.contains(index)

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isExpanded {
                        expandedResultIndices.remove(index)
                    } else {
                        expandedResultIndices.insert(index)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text("\(index)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Color.codexMuted.opacity(0.7))
                        .frame(width: 28, alignment: .trailing)

                    statusIcon(result: result, isRunning: false)

                    Text(result.scopedId)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Color.codexInk)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 8)

                    if let latencyMs = result.latencyMs {
                        Text("\(latencyMs)ms")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(Color.codexMuted)
                    }

                    Text(statusLabel(result.status))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(statusColor(result.status))
                        .frame(width: 38, alignment: .leading)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Color.codexMuted.opacity(0.75))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.horizontal, 9)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "收起该条探测详情" : "点击展开该条探测的成功/错误详情")

            if isExpanded {
                probeDetail(result: result)
                    .padding(.horizontal, 9)
                    .padding(.bottom, 8)
            }
        }
        .background(Color.codexCard.opacity(0.75), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isExpanded ? statusColor(result.status).opacity(0.35) : Color.clear,
                    lineWidth: 1
                )
        )
    }

    /// 单条探测记录的成功/错误详情（点击行展开）。
    private func probeDetail(result: GatewayModelCheckResult) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Divider()
                .overlay(Color.codexLine.opacity(0.25))
                .padding(.bottom, 3)

            detailLine(label: "模型", value: result.scopedId)
            detailLine(label: "结果", value: "\(statusLabel(result.status)) · \(result.status)")
            detailLine(label: "耗时", value: result.latencyMs.map { "\($0)ms" } ?? "—")
            detailLine(label: detailReasonLabel(for: result.status), value: detailReason(for: result))
        }
        .textSelection(.enabled)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.codexMist.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
    }

    private func detailLine(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color.codexMuted)
                .frame(width: 30, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.codexInk)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func detailReasonLabel(for status: String) -> String {
        status == "available" ? "详情" : "原因"
    }

    private func detailReason(for result: GatewayModelCheckResult) -> String {
        if let reason = result.reason, !reason.isEmpty { return reason }
        switch result.status {
        case "available": return "探测成功，网关未返回附加信息"
        case "skipped": return "已跳过：网关未返回跳过原因（通常是账号不可用或额度耗尽）"
        default: return "网关未返回失败原因"
        }
    }

    private func activeRow(index: Int, scopedId: String) -> some View {
        HStack(spacing: 8) {
            Text("\(index)")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(Color.codexMuted.opacity(0.7))
                .frame(width: 28, alignment: .trailing)
            ProgressView()
                .controlSize(.mini)
                .frame(width: 10, height: 10)
            Text(scopedId)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Color.codexInk)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text("探测中")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, alignment: .leading)
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func statusIcon(result: GatewayModelCheckResult?, isRunning: Bool) -> some View {
        if isRunning {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 10, height: 10)
        } else if let result {
            Image(systemName: statusIconName(result.status))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(statusColor(result.status))
                .frame(width: 10)
        }
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "available": "成功"
        case "unavailable": "失败"
        case "error": "异常"
        case "skipped": "跳过"
        default: "未知"
        }
    }

    private func statusIconName(_ status: String) -> String {
        switch status {
        case "available": "checkmark.circle.fill"
        case "unavailable": "xmark.circle.fill"
        case "error": "exclamationmark.circle.fill"
        case "skipped": "minus.circle.fill"
        default: "questionmark.circle.fill"
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "available": Color.green
        case "unavailable": Color.red
        case "error": Color.orange
        default: Color.codexMuted
        }
    }
}

private struct ModelCheckElapsedTimeView: View {
    let startedAtEpoch: Int64

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let elapsed = max(0, Int64(timeline.date.timeIntervalSince1970) - startedAtEpoch)
            let minutes = elapsed / 60
            let seconds = elapsed % 60
            HStack(spacing: 3.5) {
                Image(systemName: "stopwatch")
                    .font(.system(size: 9.5))
                Text(String(format: "已用时 %02d:%02d", minutes, seconds))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(Color.codexMuted)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(
                Color.codexLine.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }
}
