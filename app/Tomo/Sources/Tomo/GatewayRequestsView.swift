import AppKit
import SwiftUI

@MainActor
struct GatewayRequestsView: View {
    @Bindable var store: GatewayStore
    var supervisor: GatewaySupervisor = .shared

    @State private var tableContainerWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Gateway 请求流与明细")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.codexInk)
                            .lineLimit(1)

                        if store.isRequestsLoading {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                    Text("记录入向协议、出向路由、TTFT 首字延迟、真实/估算 Token 保真度及错误状态")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.codexMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .layoutPriority(0)

                Spacer(minLength: 6)

                // 列设置按钮
                Button {
                    store.isColumnSettingsPresented = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 10, weight: .semibold))
                        Text("列设置")
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
                .help("自定义请求流列表显示列（勾选/取消字段）")

                // 手动刷新按钮
                Button {
                    Task {
                        await store.refreshRequestsList()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(store.isRequestsLoading ? 360 : 0))
                            .animation(store.isRequestsLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: store.isRequestsLoading)
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
                .disabled(store.isRequestsLoading)
                .help("手动刷新请求列表与状态")

                GatewayDateRangeSelectorView(store: store)
                    .layoutPriority(1)
            }

            if store.selectedDateRange == .custom {
                GatewayCustomDateRangePickerBar(store: store)
            }

            if store.isRequestsLoading && store.detailedRequestsList.isEmpty && store.requestsList.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("正在查询请求流与明细日志...")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.codexInk)
                        .lineLimit(1)
                    Text("正在连接本地 SQLite 遥测账本检索数据...")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.codexMuted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
                .background(Color.codexCard)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.8)
                )
            } else if store.detailedRequestsList.isEmpty && store.requestsList.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "waveform.path.badge.plus")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.codexMuted)
                    Text("暂无外部 Agent 反代流水")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.codexInk)
                        .lineLimit(1)
                    Text("本地多协议网关已在 http://127.0.0.1:\(String(supervisor.port)) 准备就绪。\n当第三方 Agent 发送请求时，协议转换、TTFT 延迟与 Token 消耗将在此实时记录并持久化。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.codexMuted)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
                .background(Color.codexCard)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.8)
                )
            } else if !store.detailedRequestsList.isEmpty {
                ZStack {
                    VStack(alignment: .leading, spacing: 6) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 6) {
                                requestsTableHeaderView

                                VStack(spacing: 6) {
                                    ForEach(store.detailedRequestsList) { req in
                                        detailedRequestRow(for: req)
                                    }
                                }
                            }
                            .frame(width: effectiveTableWidth, alignment: .leading)
                        }

                        requestsPaginationBar
                    }
                    .opacity(store.isRequestsLoading ? 0.45 : 1.0)
                    .animation(.easeInOut(duration: 0.2), value: store.isRequestsLoading)

                    if store.isRequestsLoading {
                        HStack(spacing: 7) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在加载第 \(store.requestsCurrentPage) 页...")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Color.codexInk)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.codexCard.opacity(0.95))
                        .clipShape(Capsule())
                        .shadow(color: Color.black.opacity(0.12), radius: 8, y: 3)
                        .overlay(
                            Capsule()
                                .stroke(Color.codexLine.opacity(0.4), lineWidth: 0.8)
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }
                }
            } else {
                // Table Header / Column Titles for In-memory Fallback List
                ZStack {
                    VStack(alignment: .leading, spacing: 6) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 6) {
                                requestsTableHeaderView

                                VStack(spacing: 6) {
                                    ForEach(store.requestsList) { req in
                                        fallbackRequestRow(for: req)
                                    }
                                }
                            }
                            .frame(width: effectiveTableWidth, alignment: .leading)
                        }
                    }
                    .opacity(store.isRequestsLoading ? 0.45 : 1.0)
                    .animation(.easeInOut(duration: 0.2), value: store.isRequestsLoading)

                    if store.isRequestsLoading {
                        HStack(spacing: 7) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在更新请求数据...")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Color.codexInk)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.codexCard.opacity(0.95))
                        .clipShape(Capsule())
                        .shadow(color: Color.black.opacity(0.12), radius: 8, y: 3)
                        .overlay(
                            Capsule()
                                .stroke(Color.codexLine.opacity(0.4), lineWidth: 0.8)
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }
                }
            }

            Spacer(minLength: 16)
        }
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: GatewayTableWidthKey.self, value: geo.size.width)
            }
        }
        .onPreferenceChange(GatewayTableWidthKey.self) { newWidth in
            if newWidth > 0 && abs(tableContainerWidth - newWidth) > 1 {
                tableContainerWidth = newWidth
            }
        }
    }

    // MARK: - 请求流动态列渲染组件

    private var minTableWidth: CGFloat {
        let colWidths = store.orderedVisibleColumns.reduce(CGFloat(0)) { $0 + $1.minWidth }
        let spacing = CGFloat(max(0, store.orderedVisibleColumns.count - 1)) * 6.0
        return colWidths + spacing + 20.0
    }

    private var effectiveTableWidth: CGFloat {
        max(minTableWidth, tableContainerWidth)
    }

    private func columnWidth(for col: GatewayRequestColumn) -> CGFloat {
        let base = col.minWidth
        let availableExtra = max(0, effectiveTableWidth - minTableWidth)
        let totalFlexWeight = store.orderedVisibleColumns.reduce(CGFloat(0)) { $0 + $1.flexWeight }
        guard availableExtra > 0, totalFlexWeight > 0 else {
            return base
        }
        return base + (col.flexWeight / totalFlexWeight) * availableExtra
    }

    private var requestsTableHeaderView: some View {
        HStack(spacing: 6) {
            ForEach(store.orderedVisibleColumns) { col in
                requestHeaderCell(for: col)
            }
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(Color.codexMuted)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: effectiveTableWidth, alignment: .leading)
        .background(Color.codexMist.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.codexLine.opacity(0.4), lineWidth: 0.8)
        )
    }

    @ViewBuilder
    private func requestHeaderCell(for column: GatewayRequestColumn) -> some View {
        Text(column.title)
            .frame(width: columnWidth(for: column), alignment: column.alignment)
            .lineLimit(1)
    }

    @ViewBuilder
    private func detailedRequestRow(for req: GatewayTelemetryEventDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(store.orderedVisibleColumns) { col in
                    detailedRequestCell(for: col, req: req)
                }
            }

            if let err = req.errorMessage, !err.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9.5))
                    Text(err)
                        .font(.system(size: 10))
                }
                .foregroundStyle(Color.red)
                .lineLimit(1)
            }
        }
        .padding(10)
        .frame(width: effectiveTableWidth, alignment: .leading)
        .background(Color.codexCard)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.8)
        )
    }

    @ViewBuilder
    private func detailedRequestCell(for column: GatewayRequestColumn, req: GatewayTelemetryEventDetail) -> some View {
        Group {
            switch column {
            case .time:
                Text(req.formattedTime)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.codexMuted)
                    .lineLimit(1)
                    .help(req.formattedDateTime)

            case .id:
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(req.id, forType: .string)
                } label: {
                    HStack(spacing: 2) {
                        Text(String(req.id.suffix(7)))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.codexMuted)
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 8))
                            .foregroundStyle(Color.codexMuted.opacity(0.6))
                    }
                }
                .buttonStyle(.plain)
                .help("请求 ID: \(req.id)\n点击复制")

            case .agent:
                Text(req.agent)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.codexInk)
                    .lineLimit(1)
                    .truncationMode(.tail)

            case .ingressProtocol:
                Text(req.ingressProtocol)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.codexMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)

            case .provider:
                Text(req.provider.isEmpty ? "-" : req.provider)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.codexInk)
                    .lineLimit(1)
                    .truncationMode(.tail)

            case .account:
                Text(req.account.isEmpty ? "-" : req.account)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.codexMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)

            case .targetModel:
                Text(req.targetModel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.codexInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(req.modelAlias.isEmpty || req.modelAlias == req.targetModel ? req.targetModel : "请求别名: \(req.modelAlias)\n目标模型: \(req.targetModel)")

            case .stream:
                Text(req.isStream ? "SSE" : "Sync")
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(req.isStream ? Color.blue.opacity(0.12) : Color.codexMuted.opacity(0.12), in: Capsule())
                    .foregroundStyle(req.isStream ? Color.blue : Color.codexMuted)
                    .lineLimit(1)

            case .tokens:
                Group {
                    if let inTok = req.inputTokens, let outTok = req.outputTokens {
                        Text("\(inTok)↓ \(outTok)↑")
                    } else if let total = req.totalTokens, total > 0 {
                        Text("\(total) toks")
                    } else {
                        Text("-")
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.codexInk)
                .lineLimit(1)

            case .cacheTokens:
                Group {
                    if let read = req.cacheReadTokens, read > 0 {
                        Text("读:\(read)")
                    } else if let write = req.cacheWriteTokens, write > 0 {
                        Text("写:\(write)")
                    } else {
                        Text("-")
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.codexMuted)
                .lineLimit(1)

            case .tools:
                Group {
                    if req.toolCallsCount > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "wrench.and.screwdriver")
                                .font(.system(size: 8))
                            Text("\(req.toolCallsCount)")
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        }
                        .foregroundStyle(Color.purple)
                    } else {
                        Text("-")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.codexMuted)
                    }
                }
                .lineLimit(1)

            case .cost:
                Group {
                    if let cost = req.estimatedCost, cost > 0 {
                        Text("$\(String(format: "%.4f", cost))")
                    } else {
                        Text("-")
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.codexInk)
                .lineLimit(1)

            case .ttft:
                Group {
                    if let ttft = req.ttftMs {
                        Text("\(ttft)ms")
                    } else {
                        Text("-")
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.codexMuted)
                .lineLimit(1)

            case .latency:
                Text("\(req.latencyMs)ms")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.codexInk)
                    .lineLimit(1)

            case .fidelity:
                Text(req.fidelity == "actual" ? "实际" : (req.fidelity == "estimated" ? "估算" : "无"))
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(req.fidelity == "actual" ? Color.green.opacity(0.12) : Color.orange.opacity(0.12), in: Capsule())
                    .foregroundStyle(req.fidelity == "actual" ? Color.green : Color.orange)
                    .lineLimit(1)

            case .status:
                Text(req.isSuccess ? "200 OK" : "\(req.statusCode)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(req.isSuccess ? Color.green : Color.red)
                    .lineLimit(1)
            }
        }
        .frame(width: columnWidth(for: column), alignment: column.alignment)
    }

    @ViewBuilder
    private func fallbackRequestRow(for req: GatewayRequestRow) -> some View {
        HStack(spacing: 6) {
            ForEach(store.orderedVisibleColumns) { col in
                fallbackRequestCell(for: col, req: req)
            }
        }
        .padding(10)
        .frame(width: effectiveTableWidth, alignment: .leading)
        .background(Color.codexCard)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.8)
        )
    }

    @ViewBuilder
    private func fallbackRequestCell(for column: GatewayRequestColumn, req: GatewayRequestRow) -> some View {
        Group {
            switch column {
            case .time:
                Text(req.time)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.codexMuted)
                    .lineLimit(1)

            case .id:
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(req.id, forType: .string)
                } label: {
                    HStack(spacing: 2) {
                        Text(String(req.id.suffix(7)))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.codexMuted)
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 8))
                            .foregroundStyle(Color.codexMuted.opacity(0.6))
                    }
                }
                .buttonStyle(.plain)
                .help("请求 ID: \(req.id)\n点击复制")

            case .agent:
                Text(req.agent)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.codexInk)
                    .lineLimit(1)
                    .truncationMode(.tail)

            case .ingressProtocol:
                Text(req.ingressProtocol)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.codexMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)

            case .provider:
                Text(req.targetProvider.isEmpty ? "-" : req.targetProvider)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.codexInk)
                    .lineLimit(1)
                    .truncationMode(.tail)

            case .account:
                Text("-")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.codexMuted)
                    .lineLimit(1)

            case .targetModel:
                Text(req.targetModel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.codexInk)
                    .lineLimit(1)
                    .truncationMode(.middle)

            case .stream:
                Text("Sync")
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(Color.codexMuted.opacity(0.12), in: Capsule())
                    .foregroundStyle(Color.codexMuted)
                    .lineLimit(1)

            case .tokens:
                Group {
                    if req.tokens > 0 {
                        Text("\(req.tokens) toks")
                    } else {
                        Text("-")
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.codexInk)
                .lineLimit(1)

            case .cacheTokens:
                Text("-")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.codexMuted)
                    .lineLimit(1)

            case .tools:
                Text("-")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.codexMuted)
                    .lineLimit(1)

            case .cost:
                Text("-")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.codexInk)
                    .lineLimit(1)

            case .ttft:
                Group {
                    if req.ttftMs > 0 {
                        Text("\(req.ttftMs)ms")
                    } else {
                        Text("-")
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.codexMuted)
                .lineLimit(1)

            case .latency:
                Text("\(req.latencyMs)ms")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.codexInk)
                    .lineLimit(1)

            case .fidelity:
                Text(req.fidelity == "actual" ? "实际" : (req.fidelity == "estimated" ? "估算" : req.fidelity))
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.12), in: Capsule())
                    .foregroundStyle(Color.blue)
                    .lineLimit(1)

            case .status:
                Text(req.status)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.green)
                    .lineLimit(1)
            }
        }
        .frame(width: columnWidth(for: column), alignment: column.alignment)
    }

    // MARK: - 分页栏

    private var requestsPaginationBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Text("共 \(store.requestsTotalCount) 条记录")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.codexMuted)
                    .lineLimit(1)

                if store.isRequestsLoading {
                    ProgressView()
                        .controlSize(.mini)
                }
            }

            Spacer(minLength: 6)

            HStack(spacing: 4) {
                Text("每页")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.codexMuted)
                    .lineLimit(1)

                Picker("", selection: Binding(
                    get: { store.requestsPageSize },
                    set: { store.setPageSize($0) }
                )) {
                    Text("10 条").tag(10)
                    Text("20 条").tag(20)
                    Text("50 条").tag(50)
                    Text("100 条").tag(100)
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 80)
                .disabled(store.isRequestsLoading)
            }

            Divider()
                .frame(height: 14)

            HStack(spacing: 4) {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        store.goToPage(1)
                    }
                }) {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 10))
                        .padding(4)
                }
                .disabled(store.requestsCurrentPage <= 1 || store.isRequestsLoading)
                .buttonStyle(.plain)
                .foregroundStyle((store.requestsCurrentPage <= 1 || store.isRequestsLoading) ? Color.codexMuted.opacity(0.35) : Color.codexInk)

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        store.prevPage()
                    }
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(4)
                }
                .disabled(store.requestsCurrentPage <= 1 || store.isRequestsLoading)
                .buttonStyle(.plain)
                .foregroundStyle((store.requestsCurrentPage <= 1 || store.isRequestsLoading) ? Color.codexMuted.opacity(0.35) : Color.codexInk)

                Text("第 \(store.requestsCurrentPage) / \(store.requestsTotalPages) 页")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.codexInk)
                    .padding(.horizontal, 4)
                    .lineLimit(1)

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        store.nextPage()
                    }
                }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(4)
                }
                .disabled(store.requestsCurrentPage >= store.requestsTotalPages || store.isRequestsLoading)
                .buttonStyle(.plain)
                .foregroundStyle((store.requestsCurrentPage >= store.requestsTotalPages || store.isRequestsLoading) ? Color.codexMuted.opacity(0.35) : Color.codexInk)

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        store.goToPage(store.requestsTotalPages)
                    }
                }) {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 10))
                        .padding(4)
                }
                .disabled(store.requestsCurrentPage >= store.requestsTotalPages || store.isRequestsLoading)
                .buttonStyle(.plain)
                .foregroundStyle((store.requestsCurrentPage >= store.requestsTotalPages || store.isRequestsLoading) ? Color.codexMuted.opacity(0.35) : Color.codexInk)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(Color.codexCard)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.8)
        )
    }

    // MARK: - Tab: Agents Content (Hermes & Pi 一键接入)

}
