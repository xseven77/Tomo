import SwiftUI

@MainActor
public struct GatewayAutomationView: View {
    @Bindable var store: GatewayStore
    var supervisor: GatewaySupervisor = .shared
    var settingsStore: MultiAgentSettingsStore?
    var availableWindowHeight: CGFloat?
    var onToast: GatewayToastHandler

    @State private var isCreatingTask = false
    @State private var editingTask: GatewayAutomationTask? = nil
    @State private var runningTaskIDs: Set<String> = []
    @State private var logForTask: GatewayAutomationTask? = nil

    init(
        store: GatewayStore,
        supervisor: GatewaySupervisor = .shared,
        settingsStore: MultiAgentSettingsStore? = nil,
        availableWindowHeight: CGFloat? = nil,
        onToast: @escaping GatewayToastHandler
    ) {
        self.store = store
        self.supervisor = supervisor
        self.settingsStore = settingsStore
        self.availableWindowHeight = availableWindowHeight
        self.onToast = onToast
    }

    private func toast(_ message: String, systemImage: String = "checkmark.circle.fill", isSuccess: Bool = true) {
        onToast(message, systemImage, isSuccess)
    }

    private var activeTasksCount: Int {
        store.automationTasks.filter { $0.enabled }.count
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 全量/单账号巡检实时横幅
            GatewayModelCheckBanner(store: store, onToast: onToast)

            // 顶栏操作区与启动配置条
            headerBar

            if store.automationTasks.isEmpty {
                emptyStateView
            } else {
                tasksListView
            }
        }
        .task {
            // 定时任务的“上次触发/执行日志”由网关进程写入，进入页面时先同步磁盘
            store.reloadAutomationStateFromDisk()
            await store.refreshModelHealth()
            await store.pollModelCheckStatus()
            if store.isModelCheckRunning {
                store.startPollingModelCheckStatus()
            }
        }
        .sheet(isPresented: $isCreatingTask) {
            AutomationTaskEditorSheet(
                task: nil,
                store: store,
                onSave: { newTask in
                    store.addAutomationTask(newTask)
                    toast("已创建自动化任务: \(newTask.name)")
                }
            )
        }
        .sheet(item: $editingTask) { task in
            AutomationTaskEditorSheet(
                task: task,
                store: store,
                onSave: { updated in
                    store.updateAutomationTask(updated)
                    toast("已更新自动化任务: \(updated.name)")
                }
            )
        }
        .sheet(item: $logForTask) { task in
            AutomationRunLogSheet(
                task: task,
                store: store,
                maximumHeight: max(
                    320,
                    (availableWindowHeight ?? GatewayWindowController.minWindowHeight) - 48
                )
            )
        }
    }

    // MARK: - 顶栏
    private var headerBar: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.codexPrimary.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: "clock.arrow.2.circlepath")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.codexPrimary)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("自动化任务编排")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.codexInk)

                    Text("共 \(store.automationTasks.count) 个计划 · \(activeTasksCount) 个已启用")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.codexLine.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.codexMuted)
                }

                Text("按计划在本地自动执行模型巡检与各类自动化工作流")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.codexMuted)
            }

            Spacer()

            Button {
                isCreatingTask = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                    Text("新建自动化任务")
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Color.codexPrimary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .foregroundStyle(Color.codexOnPrimary)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Color.codexCard)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.02), radius: 2, x: 0, y: 1)
    }

    // MARK: - 空状态
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.codexPrimary.opacity(0.08))
                    .frame(width: 64, height: 64)
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.codexPrimary)
            }

            VStack(spacing: 6) {
                Text("暂无自动化巡检任务")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.codexInk)

                Text("您可以按需设置每天哪几个小时对哪些供应商或账号进行自动巡检，\n确保模型健康探测井然有序，或通过定时探针提前对齐 5 小时额度刷新窗口。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.codexMuted)
                    .multilineTextAlignment(.center)
            }

            // 推荐方案卡片组
            VStack(spacing: 8) {
                // 推荐 1: 5小时额度窗口对齐 (社区精选)
                Button {
                    let task = GatewayAutomationTask(
                        name: "5小时额度对齐巡检 (05, 10, 15, 20点)",
                        taskType: .modelHealthCheck,
                        enabled: true,
                        providers: ["openai", "google"],
                        allAccounts: true,
                        hours: [5, 10, 15, 20]
                    )
                    store.addAutomationTask(task)
                    toast("已应用推荐：5小时额度对齐巡检")
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.codexPrimary.opacity(0.12))
                                .frame(width: 32, height: 32)
                            Image(systemName: "bolt.badge.clock")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.codexPrimary)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("应用「5小时额度对齐」巡检")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Color.codexInk)

                                Text("推荐 · 社区最佳实践")
                                    .font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(Color.codexPrimary.opacity(0.15), in: Capsule())
                                    .foregroundStyle(Color.codexPrimary)
                            }

                            Text("每天 05:00 / 10:00 / 15:00 / 20:00 自动探针，在上午上班与下午高峰前校准滚动窗口")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.codexMuted)
                        }

                        Spacer()

                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.codexPrimary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.codexBackground.opacity(0.8), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.codexPrimary.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                // 推荐 2 & 3 横排轻量选项
                HStack(spacing: 8) {
                    Button {
                        let task = GatewayAutomationTask(
                            name: "工作时段常规巡检 (09, 13, 18点)",
                            taskType: .modelHealthCheck,
                            enabled: true,
                            providers: ["openai", "google"],
                            allAccounts: true,
                            hours: [9, 13, 18]
                        )
                        store.addAutomationTask(task)
                        toast("已应用：工作时段常规巡检")
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "briefcase")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.codexMuted)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("工作时段打卡 (09, 13, 18点)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.codexInk)
                                Text("早午晚3次，不打扰夜间休眠")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.codexMuted)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.codexBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.codexLine.opacity(0.2), lineWidth: 0.8)
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        let task = GatewayAutomationTask(
                            name: "高频全天候巡检 (每4小时)",
                            taskType: .modelHealthCheck,
                            enabled: true,
                            providers: ["openai", "google"],
                            allAccounts: true,
                            hours: [0, 4, 8, 12, 16, 20]
                        )
                        store.addAutomationTask(task)
                        toast("已应用：高频全天候巡检")
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.arrow.2.circlepath")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.codexMuted)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("高频全天候 (每4小时一次)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.codexInk)
                                Text("全天6次循环，适合多账号监控")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.codexMuted)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.codexBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.codexLine.opacity(0.2), lineWidth: 0.8)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 500)

            // 自定义创建计划入口
            Button {
                isCreatingTask = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11))
                    Text("自定义创建计划...")
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(Color.codexLine.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .foregroundStyle(Color.codexInk)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(Color.codexCard)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.02), radius: 2, x: 0, y: 1)
    }

    // MARK: - 任务列表
    private var tasksListView: some View {
        VStack(spacing: 12) {
            ForEach(store.automationTasks) { task in
                taskCard(task)
            }
        }
    }

    private func taskCard(_ task: GatewayAutomationTask) -> some View {
        let isThisTaskRunning = runningTaskIDs.contains(task.id) || (store.isModelCheckRunning && task.lastRunStatus == "running")
        let isAnyRunning = store.isModelCheckRunning || !runningTaskIDs.isEmpty

        return VStack(alignment: .leading, spacing: 12) {
            // 卡片头部
            HStack(alignment: .center, spacing: 10) {
                Toggle("", isOn: Binding(
                    get: { task.enabled },
                    set: { _ in store.toggleAutomationTask(id: task.id) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .scaleEffect(0.8)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(task.name)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(task.enabled ? Color.codexInk : Color.codexMuted)

                        HStack(spacing: 4) {
                            Image(systemName: task.taskType.iconName)
                                .font(.system(size: 9))
                            Text(task.taskType.title)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Color.codexPrimary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .foregroundStyle(Color.codexPrimary)
                    }

                    if !task.enabled {
                        Text("计划已暂停，不会按时自动触发")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.codexMuted)
                    }
                }

                Spacer()

                // 执行状态标签：如果当前正在全量巡检或此任务在运行，明确显示运行中
                statusBadge(task: task, isRunning: isThisTaskRunning || (store.isModelCheckRunning && task.enabled && task.lastRunStatus == "running"))
            }

            Divider()
                .overlay(Color.codexLine.opacity(0.2))

            // 属性详情网格
            VStack(alignment: .leading, spacing: 8) {
                // 1. 计划时间点
                HStack(alignment: .top, spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                        Text("每天时间点:")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Color.codexMuted)
                    .frame(width: 90, alignment: .leading)

                    if task.hours.isEmpty {
                        Text("未设置时间")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.red.opacity(0.8))
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(task.hours.sorted(), id: \.self) { hour in
                                    Text(String(format: "%02d:00", hour))
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.codexPrimary.opacity(0.10), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                        .foregroundStyle(Color.codexPrimary)
                                }
                            }
                        }
                    }
                }

                // 2. 供应商范围
                HStack(alignment: .center, spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 10))
                        Text("目标供应商:")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Color.codexMuted)
                    .frame(width: 90, alignment: .leading)

                    if task.providers.isEmpty {
                        Text("全部供应商")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.codexInk)
                    } else {
                        FlowLayout(spacing: 5) {
                            ForEach(task.providers, id: \.self) { p in
                                providerBadge(p)
                            }
                        }
                    }
                }

                // 3. 账号范围
                HStack(alignment: .center, spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 10))
                        Text("账号范围:")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Color.codexMuted)
                    .frame(width: 90, alignment: .leading)

                    if task.allAccounts {
                        Text("所选供应商下的全部账号 (自动包含新增账号)")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.codexInk)
                    } else {
                        Text("指定 \(task.accountIds.count) 个特定账号")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.codexInk)
                    }
                }

                // 4. 最近执行记录
                if let lastRunAt = task.lastRunDate {
                    HStack(alignment: .center, spacing: 8) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10))
                            Text("上次触发:")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(Color.codexMuted)
                        .frame(width: 90, alignment: .leading)

                        HStack(spacing: 6) {
                            Text(lastRunAt.formatted(date: .numeric, time: .standard))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Color.codexMuted)

                            if let summary = task.lastRunSummary, !summary.isEmpty {
                                Text("·  \(summary)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.codexInk)
                            }
                        }
                    }
                }
            }

            Divider()
                .overlay(Color.codexLine.opacity(0.15))

            // 卡片底部操作按钮
            HStack(spacing: 8) {
                Button {
                    runningTaskIDs.insert(task.id)
                    Task {
                        let res = await store.runAutomationTaskNow(task)
                        runningTaskIDs.remove(task.id)
                        toast(res.message, systemImage: res.success ? "checkmark.circle.fill" : "exclamationmark.circle.fill", isSuccess: res.success)
                    }
                } label: {
                    HStack(spacing: 4) {
                        if isThisTaskRunning {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.7)
                            Text("探测进行中...")
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9))
                            Text("立即运行一次")
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Color.codexLine.opacity(isAnyRunning ? 0.08 : 0.15), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .foregroundStyle(isAnyRunning ? Color.codexMuted.opacity(0.5) : Color.codexInk)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.8)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isAnyRunning)
                .help(isAnyRunning ? "已有巡检或自动化任务正在运行中" : "立即触发该自动化任务运行一次")

                Spacer()

                Button {
                    logForTask = task
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 10))
                        Text("执行日志")
                            .font(.system(size: 11))
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Color.codexLine.opacity(0.1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .foregroundStyle(Color.codexInk)
                }
                .buttonStyle(.plain)
                .help("查看该任务的历史执行记录（触发时间、耗时与成功/失败结果）")

                Button {
                    editingTask = task
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "pencil")
                            .font(.system(size: 10))
                        Text("编辑")
                            .font(.system(size: 11))
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Color.codexLine.opacity(0.1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .foregroundStyle(Color.codexInk)
                }
                .buttonStyle(.plain)

                Button {
                    store.deleteAutomationTask(id: task.id)
                    toast("已删除任务: \(task.name)")
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                        Text("删除")
                            .font(.system(size: 11))
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .foregroundStyle(Color.red.opacity(0.85))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Color.codexCard)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(task.enabled ? Color.codexLine.opacity(0.35) : Color.codexLine.opacity(0.18), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.02), radius: 2, x: 0, y: 1)
    }

    private func providerBadge(_ provider: String) -> some View {
        let (title, icon) = providerInfo(provider)
        return HStack(spacing: 3) {
            AutomationProviderIcon(provider: provider, fallback: icon, size: 14)
            Text(title)
                .font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.codexLine.opacity(0.15), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .foregroundStyle(Color.codexInk)
    }

    private func providerInfo(_ provider: String) -> (String, String) {
        let p = provider.lowercased()
        if p == "openai" || p == "codex" {
            return ("OpenAI / Codex", "apple.terminal")
        } else if p == "google" || p == "gemini" {
            return ("Google Gemini", "sparkles")
        } else if p == "deepseek" {
            return ("DeepSeek", "bolt.horizontal.circle")
        } else if p == "opencode" {
            return ("OpenCode", "network")
        }
        return (provider, "server.rack")
    }

    private func statusBadge(task: GatewayAutomationTask, isRunning: Bool) -> some View {
        HStack(spacing: 4) {
            if isRunning {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.65)
                Text("巡检进行中")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.blue)
            } else if task.lastRunStatus == "success" {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.green)
                Text("运行正常")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.green)
            } else if task.lastRunStatus == "failed" {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.red)
                Text("执行失败")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.red)
            } else if task.lastRunStatus == "cancelled" {
                Image(systemName: "slash.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.codexMuted)
                Text("已取消")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.codexMuted)
            } else {
                Text("等待下个周期")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.codexMuted)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(
            isRunning ? Color.blue.opacity(0.10) :
            (task.lastRunStatus == "success" ? Color.green.opacity(0.10) :
            (task.lastRunStatus == "failed" ? Color.red.opacity(0.10) : Color.codexLine.opacity(0.12))),
            in: Capsule()
        )
    }
}

/// Shared branding for automation summaries and provider selection.
private struct AutomationProviderIcon: View {
    let provider: String
    let fallback: String
    let size: CGFloat

    private var asset: BrandAssetID? {
        switch provider.lowercased() {
        case "openai", "codex": .codex
        case "google", "gemini": .googleGemini
        case "deepseek": .deepSeek
        case "opencode": .openCode
        default: nil
        }
    }

    var body: some View {
        if let asset {
            BrandIconView(asset: asset, size: size, cornerRadius: 3)
        } else {
            Image(systemName: fallback)
                .font(.system(size: size * 0.65))
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - 任务创建与编辑弹窗
@MainActor
public struct AutomationTaskEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    var originalTask: GatewayAutomationTask?
    var store: GatewayStore
    var onSave: (GatewayAutomationTask) -> Void

    @State private var name: String = ""
    @State private var taskType: AutomationTaskType = .modelHealthCheck
    @State private var enabled: Bool = true
    @State private var selectedProviders: Set<String> = []
    @State private var allAccounts: Bool = true
    @State private var selectedAccountIds: Set<String> = []
    @State private var selectedHours: Set<Int> = [8, 14, 21]

    private let availableProviders = [
        ("openai", "OpenAI / Codex", "apple.terminal"),
        ("google", "Google Gemini", "sparkles"),
        ("deepseek", "DeepSeek 官方", "bolt.horizontal.circle"),
        ("opencode", "OpenCode 聚合平台", "network"),
    ]

    /// Keep the editor visually generous and independent from the form's
    /// intrinsic content height. A sheet may become the key window while it
    /// is presented, so prefer its parent (the Gateway window) when present.
    private var editorHeight: CGFloat {
        let hostWindow = NSApp.keyWindow?.sheetParent ?? NSApp.mainWindow ?? NSApp.keyWindow
        let hostHeight = hostWindow?.frame.height ?? 768
        // Leave a consistent 24pt breathing space above and below the sheet.
        return max(1, hostHeight - 48)
    }

    public init(
        task: GatewayAutomationTask?,
        store: GatewayStore,
        onSave: @escaping (GatewayAutomationTask) -> Void
    ) {
        self.originalTask = task
        self.store = store
        self.onSave = onSave

        if let task {
            _name = State(initialValue: task.name)
            _taskType = State(initialValue: task.taskType)
            _enabled = State(initialValue: task.enabled)
            _selectedProviders = State(initialValue: Set(task.providers))
            _allAccounts = State(initialValue: task.allAccounts)
            _selectedAccountIds = State(initialValue: Set(task.accountIds))
            _selectedHours = State(initialValue: Set(task.hours))
        } else {
            _name = State(initialValue: "定时模型健康巡检")
            _selectedProviders = State(initialValue: ["openai", "google"])
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Sheet Header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.codexPrimary.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: originalTask == nil ? "plus.circle.fill" : "slider.horizontal.3")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.codexPrimary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(originalTask == nil ? "新建自动化任务" : "编辑自动化任务")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.codexInk)
                    Text("设定每天特定触发时点、巡检的供应商与账号范围")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.codexMuted)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.codexMuted.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .background(Color.codexCard)

            Divider()
                .overlay(Color.codexLine.opacity(0.3))

            // Form Body
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    // 1. 任务基础名称
                    VStack(alignment: .leading, spacing: 6) {
                        Text("任务名称")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.codexInk)

                        TextField("如：Codex 每日三检、全量夜间巡检", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    // 2. 任务类型 (扩展槽位)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("任务类型")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.codexInk)

                        HStack(spacing: 10) {
                            HStack(spacing: 8) {
                                Image(systemName: "stethoscope")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.codexPrimary)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("模型健康巡检")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.codexInk)
                                    Text("定时发起小包探测，自动更新并持久化模型可用性与延时指标")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.codexMuted)
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.codexPrimary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.codexPrimary.opacity(0.3), lineWidth: 1)
                            )
                        }
                    }

                    // 3. 24 小时触发时点选择器
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("每天触发时点 (小时)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.codexInk)

                            Spacer()

                            // 快捷选择预设
                            HStack(spacing: 4) {
                                presetButton("5小时额度对齐 (5,10,15,20)", hours: [5, 10, 15, 20])
                                presetButton("工作时段 (9,13,18)", hours: [9, 13, 18])
                                presetButton("每4小时", hours: [0, 4, 8, 12, 16, 20])
                                presetButton("全选", hours: Array(0...23))
                                presetButton("清空", hours: [])
                            }
                        }

                        // 24小时矩阵格子 (4行 x 6列)
                        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(0..<24, id: \.self) { hour in
                                let isSelected = selectedHours.contains(hour)
                                Button {
                                    if isSelected {
                                        selectedHours.remove(hour)
                                    } else {
                                        selectedHours.insert(hour)
                                    }
                                } label: {
                                    Text(String(format: "%02d:00", hour))
                                        .font(.system(size: 11, weight: isSelected ? .bold : .medium, design: .monospaced))
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 28)
                                        .background(
                                            isSelected ? Color.codexPrimary : Color.codexLine.opacity(0.12),
                                            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        )
                                        .foregroundStyle(isSelected ? Color.codexOnPrimary : Color.codexInk)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Text("已选 \(selectedHours.count) 个时间点：\(selectedHoursSummary)")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.codexMuted)
                    }

                    // 4. 目标供应商 (多选)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("目标供应商 (支持多选)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.codexInk)

                        FlowLayout(spacing: 8) {
                            ForEach(availableProviders, id: \.0) { key, title, icon in
                                let isSelected = selectedProviders.contains(key)
                                Button {
                                    if isSelected {
                                        selectedProviders.remove(key)
                                    } else {
                                        selectedProviders.insert(key)
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                                            .font(.system(size: 12))
                                            .foregroundStyle(isSelected ? Color.codexPrimary : Color.codexMuted)
                                        AutomationProviderIcon(provider: key, fallback: icon, size: 15)
                                        Text(title)
                                            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                                            .lineLimit(1)
                                            .fixedSize()
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        isSelected ? Color.codexPrimary.opacity(0.12) : Color.codexLine.opacity(0.10),
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .stroke(isSelected ? Color.codexPrimary.opacity(0.55) : Color.codexLine.opacity(0.35), lineWidth: 0.8)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if selectedProviders.isEmpty {
                            Text("⚠️ 未选择供应商时，巡检将默认涵盖所有可用供应商")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.orange)
                        }
                    }

                    // 5. 账号范围 (全量 vs 指定)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("账号范围")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.codexInk)

                        HStack(spacing: 16) {
                            Button {
                                allAccounts = true
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: allAccounts ? "largecircle.fill.circle" : "circle")
                                        .font(.system(size: 12))
                                        .foregroundStyle(allAccounts ? Color.codexPrimary : Color.codexMuted)
                                    Text("所选供应商下的全部账号 (推荐，包含未来新增账号)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.codexInk)
                                }
                            }
                            .buttonStyle(.plain)

                            Button {
                                allAccounts = false
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: !allAccounts ? "largecircle.fill.circle" : "circle")
                                        .font(.system(size: 12))
                                        .foregroundStyle(!allAccounts ? Color.codexPrimary : Color.codexMuted)
                                    Text("仅巡检指定账号")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.codexInk)
                                }
                            }
                            .buttonStyle(.plain)
                        }

                        if !allAccounts {
                            accountSelectorView
                        }
                    }

                    // 6. 任务启用开关
                    Toggle(isOn: $enabled) {
                        Text("创建后立即启用此计划")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.codexInk)
                    }
                    .toggleStyle(.checkbox)
                }
                .padding(18)
            }

            Divider()
                .overlay(Color.codexLine.opacity(0.3))

            // Footer Actions
            HStack {
                Button("取消") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .frame(height: 28)
                .padding(.horizontal, 14)
                .background(Color.codexLine.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .foregroundStyle(Color.codexInk)

                Spacer()

                Button {
                    let task = GatewayAutomationTask(
                        id: originalTask?.id ?? UUID().uuidString,
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "自动化巡检计划" : name,
                        taskType: taskType,
                        enabled: enabled,
                        providers: Array(selectedProviders).sorted(),
                        allAccounts: allAccounts,
                        accountIds: allAccounts ? [] : Array(selectedAccountIds),
                        hours: Array(selectedHours).sorted(),
                        lastRunAt: originalTask?.lastRunAt,
                        lastRunStatus: originalTask?.lastRunStatus,
                        lastRunSummary: originalTask?.lastRunSummary
                    )
                    onSave(task)
                    dismiss()
                } label: {
                    Text(originalTask == nil ? "立即创建" : "保存修改")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.codexOnPrimary)
                        .padding(.horizontal, 16)
                        .frame(height: 28)
                        .background(Color.codexPrimary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(selectedHours.isEmpty)
            }
            .padding(14)
            .background(Color.codexCard)
        }
        .frame(width: 580, height: editorHeight)
    }

    private var selectedHoursSummary: String {
        if selectedHours.isEmpty { return "无" }
        if selectedHours.count == 24 { return "全天候 (每小时)" }
        return selectedHours.sorted().map { String(format: "%02d:00", $0) }.joined(separator: ", ")
    }

    private func presetButton(_ label: String, hours: [Int]) -> some View {
        Button {
            selectedHours = Set(hours)
        } label: {
            Text(label)
                .font(.system(size: 10))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.codexLine.opacity(0.1), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .foregroundStyle(Color.codexInk)
        }
        .buttonStyle(.plain)
    }

    // 账号选择列表
    private var accountSelectorView: some View {
        let matchingAccounts = store.accountModelGroups.filter { group in
            if selectedProviders.isEmpty { return true }
            return selectedProviders.contains(where: { p in
                group.id.lowercased().hasPrefix(p.lowercased())
            })
        }

        return VStack(alignment: .leading, spacing: 6) {
            Text("勾选需要巡检的账号:")
                .font(.system(size: 10))
                .foregroundStyle(Color.codexMuted)

            if matchingAccounts.isEmpty {
                Text("所选供应商下暂无已连接的账号")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.codexMuted)
                    .padding(8)
            } else {
                VStack(spacing: 4) {
                    ForEach(matchingAccounts) { acc in
                        let cid = acc.connectionID?.rawValue.uuidString ?? acc.id
                        let isChecked = selectedAccountIds.contains(cid)

                        Button {
                            if isChecked {
                                selectedAccountIds.remove(cid)
                            } else {
                                selectedAccountIds.insert(cid)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 12))
                                    .foregroundStyle(isChecked ? Color.codexPrimary : Color.codexMuted)

                                Image(systemName: acc.iconName)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.codexInk)

                                Text(acc.accountName)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.codexInk)

                                if let email = acc.email, !email.isEmpty {
                                    Text("(\(email))")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.codexMuted)
                                }

                                Spacer()

                                Text(acc.providerTitle)
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.codexMuted)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 26)
                            .background(isChecked ? Color.codexPrimary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(Color.codexLine.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }
}

// MARK: - 自适应内容长度自动换行流式布局 (FlowLayout)
struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    init(spacing: CGFloat = 8) {
        self.horizontalSpacing = spacing
        self.verticalSpacing = spacing
    }

    init(horizontal: CGFloat, vertical: CGFloat) {
        self.horizontalSpacing = horizontal
        self.verticalSpacing = vertical
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentRowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var currentRowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentRowWidth + size.width > maxWidth, currentRowWidth > 0 {
                // 换行
                totalHeight += currentRowHeight + verticalSpacing
                currentRowWidth = size.width + horizontalSpacing
                currentRowHeight = size.height
            } else {
                currentRowWidth += size.width + horizontalSpacing
                currentRowHeight = max(currentRowHeight, size.height)
            }
        }

        totalHeight += currentRowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : currentRowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var currentRowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                // 自动折行到下一行
                x = bounds.minX
                y += currentRowHeight + verticalSpacing
                currentRowHeight = 0
            }

            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + horizontalSpacing
            currentRowHeight = max(currentRowHeight, size.height)
        }
    }
}

// MARK: - 自动化任务执行日志弹窗
struct AutomationRunLogSheet: View {
    let task: GatewayAutomationTask
    let store: GatewayStore
    let maximumHeight: CGFloat
    @Environment(\.dismiss) private var dismiss
    @State private var logs: [GatewayAutomationRunLog] = []
    @State private var isRunningNow = false
    @State private var currentPage = 1
    /// 点击展开的执行记录 id，用于查看该次执行的成功/错误详情。
    @State private var expandedLogIDs: Set<String> = []
    /// 点击展开的单条模型探测详情 key（"\(log.id)-\(index)-\(result.scopedId)"）。
    @State private var expandedProbeKeys: Set<String> = []
    /// 展开记录内部的模型筛选状态（"all", "success", "fail", "skipped"），以 log.id 为键。
    @State private var probeFilters: [String: String] = [:]

    private let pageSize = 20

    private var successCount: Int { logs.filter { $0.outcome == .success }.count }
    private var failCount: Int { logs.filter { $0.outcome == .failed }.count }
    private var cancelledCount: Int { logs.filter { $0.outcome == .cancelled }.count }
    private var runningCount: Int { logs.filter { $0.outcome == .running }.count }
    private var totalPages: Int { max(1, (logs.count + pageSize - 1) / pageSize) }
    private var pageStartIndex: Int { min((currentPage - 1) * pageSize, logs.count) }
    private var pageEndIndex: Int { min(pageStartIndex + pageSize, logs.count) }
    private var pagedLogs: ArraySlice<GatewayAutomationRunLog> {
        logs[pageStartIndex..<pageEndIndex]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider().overlay(Color.codexLine.opacity(0.2))

            if logs.isEmpty {
                emptyState
            } else {
                summaryStrip
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 4) {
                        ForEach(pagedLogs, id: \.id) { log in
                            logRow(log)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                }
                .id(currentPage)
                .scrollIndicators(.hidden)
                .background(ScrollIndicatorHider())

                Divider().overlay(Color.codexLine.opacity(0.2))
                paginationBar
            }
        }
        .background(Color.codexCard)
        .frame(minWidth: 560, idealWidth: 620)
        .frame(height: maximumHeight)
        .onAppear {
            reload()
        }
        .task {
            // 弹窗打开期间持续同步：巡检被取消/跑完后，停在「进行中」的那条记录
            // 必须立刻变成「已取消/成功/失败」，否则用户看到的就还是「进行中」。
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                reload()
            }
        }
    }

    // 头部: 任务类型徽章 + 标题 + 副标题 + 关闭
    private var headerBar: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.codexPrimary.opacity(0.12))
                    .frame(width: 38, height: 38)
                Image(systemName: task.taskType.iconName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.codexPrimary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("执行日志")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.codexInk)
                    .lineLimit(1)
                Text(task.name)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.codexMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.codexMuted)
                    .frame(width: 26, height: 26)
                    .background(Color.codexMist.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // 顶部统计条
    private var summaryStrip: some View {
        HStack(spacing: 12) {
            Text("共 \(logs.count) 次执行")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.codexMuted)

            HStack(spacing: 4) {
                Circle().fill(Color.green.opacity(0.85)).frame(width: 6, height: 6)
                Text("成功 \(successCount)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.codexMuted)
            }
            HStack(spacing: 4) {
                Circle().fill(Color.red.opacity(0.85)).frame(width: 6, height: 6)
                Text("失败 \(failCount)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.codexMuted)
            }
            if cancelledCount > 0 {
                HStack(spacing: 4) {
                    Circle().fill(Color.codexMuted).frame(width: 6, height: 6)
                    Text("已取消 \(cancelledCount)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Color.codexMuted)
                }
            }
            if runningCount > 0 {
                HStack(spacing: 4) {
                    Circle().fill(Color.orange.opacity(0.85)).frame(width: 6, height: 6)
                    Text("进行中 \(runningCount)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Color.codexMuted)
                }
            }

            Spacer()

            runNowButton
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 2)
    }

    private var runNowButton: some View {
        Button {
            runNow()
        } label: {
            HStack(spacing: 4) {
                if isRunningNow {
                    ProgressView().controlSize(.mini).scaleEffect(0.7)
                } else {
                    Image(systemName: "play.fill").font(.system(size: 9))
                }
                Text(isRunningNow ? "运行中..." : "立即运行一次")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Color.codexPrimary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .foregroundStyle(Color.codexPrimary)
        }
        .buttonStyle(.plain)
        .disabled(isRunningNow || store.isModelCheckRunning)
    }

    private var paginationBar: some View {
        HStack(spacing: 10) {
            Text("\(pageStartIndex + 1)–\(pageEndIndex) / \(logs.count) 条")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Color.codexMuted)

            Spacer(minLength: 8)

            Text("第 \(currentPage) / \(totalPages) 页")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.codexInk)

            HStack(spacing: 4) {
                paginationButton(
                    systemName: "chevron.left",
                    help: "上一页",
                    isDisabled: currentPage <= 1
                ) {
                    currentPage -= 1
                }

                paginationButton(
                    systemName: "chevron.right",
                    help: "下一页",
                    isDisabled: currentPage >= totalPages
                ) {
                    currentPage += 1
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 42)
        .background(Color.codexCard)
    }

    private func paginationButton(
        systemName: String,
        help: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 26, height: 24)
                .background(Color.codexMist.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isDisabled ? Color.codexMuted.opacity(0.35) : Color.codexInk)
        .disabled(isDisabled)
        .help(help)
    }

    // 空态: 居中、紧凑、带主操作
    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.codexMist.opacity(0.5))
                    .frame(width: 52, height: 52)
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.codexMuted.opacity(0.7))
            }
            VStack(spacing: 3) {
                Text("暂无执行记录")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.codexInk)
                Text("任务触发后将展示开始时间、耗时与成功/失败结果")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.codexMuted)
            }
            runNowButton
                .disabled(isRunningNow)
                .padding(.top, 2)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private func runNow() {
        guard !isRunningNow, !store.isModelCheckRunning else { return }
        isRunningNow = true
        Task {
            _ = await store.runAutomationTaskNow(task)
            isRunningNow = false
            reload()
        }
    }

    private func reload() {
        // 定时触发由网关进程执行并写入同一个 settings 文件，先同步磁盘再展示。
        store.reloadAutomationStateFromDisk()
        logs = store.gatewaySettings.automationRunLogs
            .filter { $0.taskId == task.id }
            .sorted { $0.startedAt > $1.startedAt }
        currentPage = min(currentPage, totalPages)
    }

    private func logRow(_ log: GatewayAutomationRunLog) -> some View {
        let isExpanded = expandedLogIDs.contains(log.id)

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isExpanded {
                        expandedLogIDs.remove(log.id)
                    } else {
                        expandedLogIDs.insert(log.id)
                    }
                }
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    // 状态圆点
                    Circle()
                        .fill(color(for: log))
                        .frame(width: 7, height: 7)

                    // 开始时间
                    Text(log.startDate.formatted(date: .numeric, time: .standard))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.codexInk)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(width: 148, alignment: .leading)

                    // 耗时胶囊
                    Text(log.durationText)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.codexMuted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.codexMist.opacity(0.6), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .lineLimit(1)
                        .frame(width: 74, alignment: .leading)

                    // 结果标签
                    Text(resultLabel(for: log))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(color(for: log))
                        .frame(width: 50, alignment: .leading)
                        .lineLimit(1)

                    // 摘要
                    if let summary = log.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.codexMuted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.codexMuted.opacity(0.7))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "收起该次执行详情" : "点击展开该次执行的成功/错误详情")

            if isExpanded {
                logDetail(log)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
        .background(Color.codexMist.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isExpanded ? color(for: log).opacity(0.4) : Color.codexLine.opacity(0.25),
                    lineWidth: 0.6
                )
        )
    }

    /// 单次执行的详情：精确时点、完整摘要，以及该次巡检的模型列表与探测详情。
    private func logDetail(_ log: GatewayAutomationRunLog) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
                .overlay(Color.codexLine.opacity(0.25))
                .padding(.top, 2)

            HStack(alignment: .top, spacing: 6) {
                Text("开始")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.codexMuted)
                    .frame(width: 34, alignment: .leading)
                Text(log.startDate.formatted(date: .numeric, time: .standard))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.codexInk)
            }

            HStack(alignment: .top, spacing: 6) {
                Text("结束")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.codexMuted)
                    .frame(width: 34, alignment: .leading)
                Text(log.finishedAt.map { Date(timeIntervalSince1970: TimeInterval($0)).formatted(date: .numeric, time: .standard) } ?? "尚未结束")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(log.isUnfinished ? Color.orange : Color.codexInk)
            }

            HStack(alignment: .top, spacing: 6) {
                Text("结果")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.codexMuted)
                    .frame(width: 34, alignment: .leading)
                Text("\(resultLabel(for: log)) · 耗时 \(log.durationText)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(color(for: log))
            }

            HStack(alignment: .top, spacing: 6) {
                Text("摘要")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.codexMuted)
                    .frame(width: 34, alignment: .leading)
                Text(log.summary?.isEmpty == false ? log.summary! : (log.isUnfinished ? "巡检进行中，尚未生成摘要" : "网关未返回摘要"))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.codexInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 模型巡检完整列表
            modelResultsSection(for: log)
        }
        .textSelection(.enabled)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.codexCard.opacity(0.7), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: - 单次执行的模型巡检完整列表
    @ViewBuilder
    private func modelResultsSection(for log: GatewayAutomationRunLog) -> some View {
        let results = resolveProbeResults(for: log)
        let currentFilter = probeFilters[log.id] ?? "all"

        let filteredResults: [GatewayModelCheckResult] = {
            switch currentFilter {
            case "success":
                return results.filter { $0.status == "available" }
            case "fail":
                return results.filter { $0.status == "unavailable" || $0.status == "error" }
            case "skipped":
                return results.filter { $0.status == "skipped" }
            default:
                return results
            }
        }()

        let successCount = results.filter { $0.status == "available" }.count
        let failCount = results.filter { $0.status == "unavailable" || $0.status == "error" }.count
        let skippedCount = results.filter { $0.status == "skipped" }.count

        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .overlay(Color.codexLine.opacity(0.25))
                .padding(.top, 4)

            HStack(spacing: 8) {
                Text("模型巡检列表")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.codexInk)

                if !results.isEmpty {
                    Text("共 \(results.count) 个")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.codexMuted)
                }

                Spacer()

                if !results.isEmpty {
                    HStack(spacing: 4) {
                        filterChip(title: "全部 \(results.count)", isSelected: currentFilter == "all") {
                            probeFilters[log.id] = "all"
                        }
                        if successCount > 0 {
                            filterChip(title: "成功 \(successCount)", color: .green, isSelected: currentFilter == "success") {
                                probeFilters[log.id] = "success"
                            }
                        }
                        if failCount > 0 {
                            filterChip(title: "失败 \(failCount)", color: .red, isSelected: currentFilter == "fail") {
                                probeFilters[log.id] = "fail"
                            }
                        }
                        if skippedCount > 0 {
                            filterChip(title: "跳过 \(skippedCount)", color: .codexMuted, isSelected: currentFilter == "skipped") {
                                probeFilters[log.id] = "skipped"
                            }
                        }
                    }
                }
            }

            if results.isEmpty {
                if log.isUnfinished && store.isModelCheckRunning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini).scaleEffect(0.7)
                        Text("正在启动巡检并探测模型…")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.codexMuted)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.codexMist.opacity(0.45), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.codexMuted)
                        Text("该次历史记录未保存逐个模型探测详情")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.codexMuted)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.codexMist.opacity(0.35), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            } else if filteredResults.isEmpty {
                Text("无符合当前筛选条件的模型")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.codexMuted)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .background(Color.codexMist.opacity(0.35), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                ScrollView(showsIndicators: true) {
                    LazyVStack(spacing: 5) {
                        ForEach(Array(filteredResults.enumerated()), id: \.offset) { index, result in
                            modelProbeRow(logId: log.id, index: index + 1, result: result)
                        }

                        if log.isUnfinished,
                           store.isModelCheckRunning,
                           let status = store.modelCheckStatus,
                           !status.current.isEmpty,
                           status.results.last(where: { $0.scopedId == status.current }) == nil,
                           currentFilter == "all"
                        {
                            activeModelRow(index: filteredResults.count + 1, scopedId: status.current)
                        }
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 1)
                }
                .frame(maxHeight: 280)
            }
        }
    }

    private func modelProbeRow(
        logId: String,
        index: Int,
        result: GatewayModelCheckResult
    ) -> some View {
        let probeKey = "\(logId)-\(index)-\(result.scopedId)"
        let isProbeExpanded = expandedProbeKeys.contains(probeKey)

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isProbeExpanded {
                        expandedProbeKeys.remove(probeKey)
                    } else {
                        expandedProbeKeys.insert(probeKey)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text("\(index)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Color.codexMuted.opacity(0.7))
                        .frame(width: 28, alignment: .trailing)

                    probeStatusIcon(result.status)

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

                    Text(probeStatusLabel(result.status))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(probeStatusColor(result.status))
                        .frame(width: 38, alignment: .leading)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Color.codexMuted.opacity(0.75))
                        .rotationEffect(.degrees(isProbeExpanded ? 180 : 0))
                }
                .padding(.horizontal, 9)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isProbeExpanded ? "收起该条探测详情" : "点击展开该条探测详情")

            if isProbeExpanded {
                probeDetail(result: result)
                    .padding(.horizontal, 9)
                    .padding(.bottom, 8)
            }
        }
        .background(Color.codexMist.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isProbeExpanded ? probeStatusColor(result.status).opacity(0.4) : Color.clear,
                    lineWidth: 1
                )
        )
    }

    private func activeModelRow(index: Int, scopedId: String) -> some View {
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

    private func probeDetail(result: GatewayModelCheckResult) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Divider()
                .overlay(Color.codexLine.opacity(0.25))
                .padding(.bottom, 3)

            detailLine(label: "模型", value: result.scopedId)
            detailLine(label: "结果", value: "\(probeStatusLabel(result.status)) · \(result.status)")
            detailLine(label: "耗时", value: result.latencyMs.map { "\($0)ms" } ?? "—")
            detailLine(label: result.status == "available" ? "详情" : "原因", value: detailReason(for: result))
        }
        .textSelection(.enabled)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.codexCard.opacity(0.8), in: RoundedRectangle(cornerRadius: 5))
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

    private func detailReason(for result: GatewayModelCheckResult) -> String {
        if let reason = result.reason, !reason.isEmpty { return reason }
        switch result.status {
        case "available": return "探测成功，网关未返回附加信息"
        case "skipped": return "已跳过：网关未返回跳过原因（通常是账号不可用或额度耗尽）"
        default: return "网关未返回失败原因"
        }
    }

    private func filterChip(
        title: String,
        color: Color = Color.codexInk,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9.5, weight: isSelected ? .semibold : .regular, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    isSelected ? color.opacity(0.15) : Color.codexMist.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                )
                .foregroundStyle(isSelected ? color : Color.codexMuted)
        }
        .buttonStyle(.plain)
    }

    private func resolveProbeResults(for log: GatewayAutomationRunLog) -> [GatewayModelCheckResult] {
        if let results = log.results, !results.isEmpty {
            return results
        }
        if log.isUnfinished, store.isModelCheckRunning, let status = store.modelCheckStatus, !status.results.isEmpty {
            return status.results
        }
        if let status = store.modelCheckStatus, !status.results.isEmpty {
            if status.startedAt == log.startedAt || (status.lastFinishedAt != nil && status.lastFinishedAt == log.finishedAt) {
                return status.results
            }
        }
        if let resp = store.modelHealthResponse {
            let all = resp.accounts.flatMap { acc in
                acc.models.map { m in
                    GatewayModelCheckResult(
                        scopedId: m.scopedId,
                        status: m.status,
                        reason: m.reason,
                        latencyMs: m.latencyMs
                    )
                }
            }
            if !all.isEmpty && (log.id == logs.first?.id || (resp.lastFullCheckAt != nil && abs(resp.lastFullCheckAt! - (log.finishedAt ?? log.startedAt)) < 600)) {
                return all
            }
        }
        return []
    }

    @ViewBuilder
    private func probeStatusIcon(_ status: String) -> some View {
        Image(systemName: probeStatusIconName(status))
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(probeStatusColor(status))
            .frame(width: 10)
    }

    private func probeStatusIconName(_ status: String) -> String {
        switch status {
        case "available": "checkmark.circle.fill"
        case "unavailable": "xmark.circle.fill"
        case "error": "exclamationmark.triangle.fill"
        case "skipped": "arrow.forward.circle.fill"
        default: "questionmark.circle"
        }
    }

    private func probeStatusLabel(_ status: String) -> String {
        switch status {
        case "available": "成功"
        case "unavailable": "失败"
        case "error": "异常"
        case "skipped": "跳过"
        default: "未知"
        }
    }

    private func probeStatusColor(_ status: String) -> Color {
        switch status {
        case "available": Color.green
        case "unavailable": Color.red
        case "error": Color.orange
        case "skipped": Color.codexMuted
        default: Color.codexMuted
        }
    }

    private func resultLabel(for log: GatewayAutomationRunLog) -> String {
        log.outcome.label
    }

    private func color(for log: GatewayAutomationRunLog) -> Color {
        switch log.outcome {
        case .running: Color.orange.opacity(0.85)
        case .success: Color.green.opacity(0.85)
        case .failed: Color.red.opacity(0.85)
        case .cancelled: Color.codexMuted
        }
    }
}
