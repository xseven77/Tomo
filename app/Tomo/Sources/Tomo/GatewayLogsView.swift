import AppKit
import SwiftUI

// MARK: - 运行日志视图
@MainActor
struct GatewayLogsView: View {
    @Bindable var store: GatewayLogStore = .shared

    @State private var tailTimer: Timer?
    @State private var showCopiedToast = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerBar

            tabFilterBar

            logConsoleView
        }
        .onAppear {
            store.loadIfNeeded()
            startTail()
        }
        .onDisappear {
            stopTail()
        }
    }

    // MARK: - 1. 顶部 Header 栏
    private var headerBar: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("运行日志")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.codexInk)
                        .lineLimit(1)

                    if store.isLoading {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }

                Text("聚合本地网关守护进程与上游错误日志 · 实时追踪与多维筛选")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.codexMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .layoutPriority(0)

            Spacer(minLength: 8)

            // 快捷操作工具组
            HStack(spacing: 6) {
                // 实时追踪开关
                Button {
                    store.isAutoTail.toggle()
                    if store.isAutoTail {
                        startTail()
                    } else {
                        stopTail()
                    }
                } label: {
                    HStack(spacing: 4.5) {
                        Circle()
                            .fill(store.isAutoTail ? Color.codexGreen : Color.codexMuted.opacity(0.35))
                            .frame(width: 6, height: 6)
                        Text("实时追踪")
                            .font(.system(size: 10.5, weight: store.isAutoTail ? .semibold : .medium))
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(
                        store.isAutoTail ? Color.codexGreen.opacity(0.12) : Color.codexMist,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                    )
                    .foregroundStyle(store.isAutoTail ? Color.codexGreen : Color.codexInk)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(store.isAutoTail ? Color.codexGreen.opacity(0.35) : Color.codexLine.opacity(0.35), lineWidth: 0.7)
                    )
                }
                .buttonStyle(CodexPressableStyle(cornerRadius: 5))
                .help(store.isAutoTail ? "已开启实时追踪（每 2 秒自动刷新）" : "点击开启实时追踪")

                // 手动刷新按钮
                Button {
                    store.reload()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(store.isLoading ? 360 : 0))
                            .animation(store.isLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: store.isLoading)
                        Text("刷新")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Color.codexMist, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .foregroundStyle(Color.codexInk)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.7)
                    )
                }
                .buttonStyle(CodexPressableStyle(cornerRadius: 5))
                .disabled(store.isLoading)
                .help("重新读取本地日志文件")

                // 复制筛选日志
                Button {
                    copyLogs()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showCopiedToast ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .semibold))
                        Text(showCopiedToast ? "已复制" : "复制")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(
                        showCopiedToast ? Color.codexGreen.opacity(0.12) : Color.codexMist,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                    )
                    .foregroundStyle(showCopiedToast ? Color.codexGreen : Color.codexInk)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(showCopiedToast ? Color.codexGreen.opacity(0.35) : Color.codexLine.opacity(0.35), lineWidth: 0.7)
                    )
                }
                .buttonStyle(CodexPressableStyle(cornerRadius: 5))
                .help("复制当前筛选后的日志内容")

                // 打开日志目录
                Button {
                    NSWorkspace.shared.open(GatewayLogStore.logsDirectory)
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.codexInk)
                        .frame(width: 22, height: 22)
                        .background(Color.codexMist, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.7)
                        )
                }
                .buttonStyle(CodexPressableStyle(cornerRadius: 5))
                .help("在访达中打开日志目录")
            }
        }
    }

    // MARK: - 2. 顶部的 Tab 筛选行（呼吸感充足、选中有纯白卡片背景、文字绝不截断）
    private var tabFilterBar: some View {
        HStack(alignment: .center, spacing: 14) {
            // 级别 Tab 组
            HStack(spacing: 6) {
                ForEach(GatewayLogLevelFilter.allCases) { item in
                    let isSelected = store.activeLevelFilter == item
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            store.activeLevelFilter = item
                        }
                    } label: {
                        HStack(spacing: 5) {
                            if item == .error {
                                Circle()
                                    .fill(Color.codexRed)
                                    .frame(width: 5.5, height: 5.5)
                            } else if item == .warn {
                                Circle()
                                    .fill(Color.codexAmber)
                                    .frame(width: 5.5, height: 5.5)
                            }
                            Text(item.rawValue)
                                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            isSelected ? Color.codexCard : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .shadow(color: isSelected ? Color.black.opacity(0.06) : Color.clear, radius: 2, x: 0, y: 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(isSelected ? Color.codexLine.opacity(0.4) : Color.clear, lineWidth: 0.8)
                        )
                        .foregroundStyle(isSelected ? Color.codexInk : Color.codexMuted)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()
                .frame(height: 14)
                .overlay(Color.codexLine.opacity(0.35))

            // 来源 Tab 组
            HStack(spacing: 6) {
                ForEach(GatewayLogSourceFilter.allCases) { item in
                    let isSelected = store.activeSourceFilter == item
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            store.activeSourceFilter = item
                        }
                    } label: {
                        Text(item.rawValue)
                            .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(
                                isSelected ? Color.codexCard : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                            .shadow(color: isSelected ? Color.black.opacity(0.06) : Color.clear, radius: 2, x: 0, y: 1)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(isSelected ? Color.codexLine.opacity(0.4) : Color.clear, lineWidth: 0.8)
                            )
                            .foregroundStyle(isSelected ? Color.codexInk : Color.codexMuted)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 8)

            // 搜索过滤框
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.codexMuted)

                TextField("搜索日志...", text: $store.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.codexInk)
                    .frame(width: 130)

                if !store.searchText.isEmpty {
                    Button {
                        store.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.codexMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Color.codexCard, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: Color.black.opacity(0.03), radius: 1.5, x: 0, y: 0.5)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.7)
            )

            if hasActiveFilters {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        store.clearFilters()
                    }
                } label: {
                    Text("重置")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.codexBlue)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 3)
    }

    private var hasActiveFilters: Bool {
        store.activeLevelFilter != .all
            || store.activeSourceFilter != .all
            || !store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 3. 日志列表展示区（恢复最初纯粹干净的单行日志条目）
    private var logConsoleView: some View {
        let rows = store.pagedEntries

        return VStack(alignment: .leading, spacing: 8) {
            // 表头信息与统计
            HStack(spacing: 8) {
                Text("共 \(store.totalCount) 条日志")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.codexMuted)

                if store.totalCount != store.entries.count {
                    Text("（已过滤）")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.codexMuted.opacity(0.8))
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)

            if rows.isEmpty {
                emptyState
            } else {
                ScrollView(showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(rows) { entry in
                            logRow(entry)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            // 分页栏
            if store.totalCount > store.pageSize {
                paginationBar
            }
        }
    }

    // 经典清爽的单行日志样式（原汁原味，不加冗余花哨线条）
    private func logRow(_ entry: GatewayLogEntry) -> some View {
        let isError = entry.level == .error
        let isWarn = entry.level == .warn

        return HStack(alignment: .top, spacing: 8) {
            // 时间戳 (包含年份、日期与时间 yyyy-MM-dd HH:mm:ss，自适应宽度不截断)
            Text(entry.formattedTime)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.codexMuted)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.top, 1)

            // 级别徽章
            Text(entry.level.label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    entry.level == .error
                        ? Color.codexRed.opacity(0.14)
                        : (entry.level == .warn ? Color.codexAmber.opacity(0.14) : Color.codexMist),
                    in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                )
                .foregroundStyle(
                    entry.level == .error
                        ? Color.codexRed
                        : (entry.level == .warn ? Color.codexAmber : Color.codexMuted)
                )
                .frame(width: 46, alignment: .center)
                .padding(.top, 1)

            // 来源徽章
            Text(entry.source.label)
                .font(.system(size: 9.5, weight: .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.codexMist.opacity(0.8), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .foregroundStyle(entry.source == .gateway ? Color.codexBlue : Color.purple)
                .frame(width: 58, alignment: .center)
                .padding(.top, 1)

            // 日志文本内容（支持原生选中与全选复制）
            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isError ? Color.codexRed : (isWarn ? Color.codexAmber : Color.codexInk))
                .textSelection(.enabled)
                .lineLimit(nil)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            isError
                ? Color.codexRed.opacity(0.04)
                : (isWarn ? Color.codexAmber.opacity(0.03) : Color.codexCard),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isError ? Color.codexRed.opacity(0.2) : Color.codexLine.opacity(0.25), lineWidth: 0.6)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(Color.codexMuted.opacity(0.6))

            Text(store.entries.isEmpty ? "暂无日志" : "无匹配日志")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.codexInk)

            Text("网关启停、端口状态及上游异常会自动记录在此。")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.codexMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // 分页条
    private var paginationBar: some View {
        HStack(spacing: 10) {
            Text("第 \(store.currentPage) / \(store.totalPages) 页")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.codexInk)

            Spacer(minLength: 6)

            HStack(spacing: 4) {
                Text("每页")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.codexMuted)

                Picker("", selection: Binding(
                    get: { store.pageSize },
                    set: { store.pageSize = $0 }
                )) {
                    Text("50 条").tag(50)
                    Text("100 条").tag(100)
                    Text("200 条").tag(200)
                    Text("500 条").tag(500)
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 82)
            }

            Divider()
                .frame(height: 12)

            HStack(spacing: 3) {
                Button {
                    store.goToPage(1)
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 9))
                        .padding(4)
                }
                .disabled(store.currentPage <= 1)
                .buttonStyle(.plain)

                Button {
                    store.prevPage()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(4)
                }
                .disabled(store.currentPage <= 1)
                .buttonStyle(.plain)

                Button {
                    store.nextPage()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(4)
                }
                .disabled(store.currentPage >= store.totalPages)
                .buttonStyle(.plain)

                Button {
                    store.goToPage(store.totalPages)
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 9))
                        .padding(4)
                }
                .disabled(store.currentPage >= store.totalPages)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.codexMist.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func copyLogs() {
        let text = store.exportText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(.easeOut(duration: 0.16)) {
            showCopiedToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeOut(duration: 0.2)) {
                showCopiedToast = false
            }
        }
    }

    private func startTail() {
        tailTimer?.invalidate()
        tailTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak store] _ in
            guard let store else { return }
            Task { @MainActor in
                guard store.isAutoTail else { return }
                store.reload()
            }
        }
    }

    private func stopTail() {
        tailTimer?.invalidate()
        tailTimer = nil
    }
}
