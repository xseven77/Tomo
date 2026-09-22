import AppKit
import SwiftUI

@MainActor
struct GatewayConnectView: View {
    @Bindable var store: GatewayStore
    var supervisor: GatewaySupervisor = .shared
    var settingsStore: MultiAgentSettingsStore?
    var onToast: GatewayToastHandler

    @State private var copiedEndpoint = false
    @State private var copiedKey = false
    @State private var copiedAllModels = false
    @State private var copiedLanOpenAI = false
    @State private var copiedLanAnthropic = false
    @State private var syncingConnectionIDs: Set<ConnectionID> = []
    @State private var isRotatingToken = false
    @State private var showRotateTokenConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 本地网关服务控制 (运行状态 / 开启/停止服务)
            heroControlCard

            // 全局/账号巡检进行中横幅
            GatewayModelCheckBanner(store: store, onToast: onToast)

            // 顶部通用标准接入配置
            universalConnectionBar

            CodexDivider(.horizontal)

            // 供应商聚合模块列表 (彻底解决换行与多账号重复卡片问题)
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("按供应商聚合 · 快速接入方案与全量模型")
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(Color.codexInk)
                    Text("所有账号已自动桥接为标准 OpenAI 与 Anthropic API 格式，点击模型卡片即可一键复制。")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.codexMuted)
                }

                ForEach(store.providerSections) { section in
                    GatewayProviderSectionCard(
                        section: section,
                        store: store,
                        settingsStore: settingsStore,
                        syncingConnectionIDs: $syncingConnectionIDs,
                        onToast: onToast
                    )
                }
            }
        }
        .task {
            await store.refreshModelHealth()
            await store.fetchV1Models()
            await store.pollModelCheckStatus()
            if store.isModelCheckRunning {
                store.startPollingModelCheckStatus()
            }
        }
        .onChange(of: store.modelCheckFinishToken) { _, _ in
            guard store.modelCheckFinishToken != nil, let message = store.modelCheckFinishMessage else { return }
            onToast(message, store.modelCheckFinishSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle", store.modelCheckFinishSuccess)
            store.modelCheckFinishMessage = nil
            store.modelCheckFinishToken = nil
            Task {
                await store.fetchV1Models()
            }
        }
        .alert("确认重新生成 Gateway 访问 Token？", isPresented: $showRotateTokenConfirm) {
            Button("取消", role: .cancel) {}
            Button("重新生成并同步", role: .destructive) {
                isRotatingToken = true
                Task {
                    let result = await store.rotateAuthToken()
                    await MainActor.run {
                        isRotatingToken = false
                        onToast(result.message, result.success ? "checkmark.circle.fill" : "exclamationmark.triangle", result.success)
                    }
                }
            }
        } message: {
            Text("更新后将生成高强度随机复杂码，有效防止局域网滥用。已一键接入的本地 Agent（Hermes、Pi 等）将自动平滑同步更新新凭证。")
        }
    }

    // MARK: - 顶部通用连接参数条
    private var universalConnectionBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                HStack(spacing: 8) {
                    Image(systemName: "network.badge.shield.half.filled")
                        .foregroundStyle(Color.codexInk)
                        .font(.system(size: 14, weight: .semibold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("通用网关接入参数")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.codexInk)
                        Text("兼容 99% 的 AI Agent 客户端（如 Cursor、Hermes、Aider、Claude Code 等）")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.codexMuted)
                    }
                }
                Spacer()

                HStack(spacing: 8) {
                    Button {
                        Task {
                            let res = await store.triggerModelCheck()
                            onToast(res.message, res.success ? "stethoscope" : "exclamationmark.triangle", res.success)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "stethoscope")
                            Text("全量健康巡检")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.codexLine.opacity(store.isModelCheckRunning ? 0.08 : 0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .foregroundStyle(store.isModelCheckRunning ? Color.codexMuted.opacity(0.5) : Color.codexInk)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.8)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isModelCheckRunning)
                    .help(store.isModelCheckRunning ? "巡检正在进行中" : "对所有服务商的所有启用账号模型逐一进行端到端可用性健康巡检")

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(store.allModelNamesListString, forType: .string)
                        copiedAllModels = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            copiedAllModels = false
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: copiedAllModels ? "checkmark" : "doc.on.doc")
                            Text(copiedAllModels ? "已复制全量模型名" : "复制全部可用模型名")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.codexMist, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .foregroundStyle(copiedAllModels ? Color.green : Color.codexInk)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.8)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            // 启动巡检策略开关
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.codexMuted)
                    Text("巡检策略")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.codexMuted)
                }

                Divider()
                    .frame(height: 12)
                    .overlay(Color.codexLine.opacity(0.3))

                Toggle(isOn: Binding(
                    get: { store.autoCheckOnStartupWithHistory },
                    set: { store.autoCheckOnStartupWithHistory = $0 }
                )) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10))
                        Text("软件启动或重启网关时自动巡检一次")
                            .font(.system(size: 11, weight: .regular))
                    }
                    .foregroundStyle(Color.codexInk)
                }
                .toggleStyle(.checkbox)
                .help("开启后，软件启动或网关重启时若已有历史记录仍会自动触发一次巡检；关闭后保留历史数据，仅在定时自动化任务或手动点击时执行")

                Spacer()

                Text("关闭后保留历史，仅按自动化任务计划或手动点击触发")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.codexMuted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.codexBackground.opacity(0.65), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.codexLine.opacity(0.25), lineWidth: 0.8)
            )

            HStack(spacing: 10) {
                // OpenAI Base URL
                connectionTile(
                    title: "OpenAI 兼容 Base URL (推荐)",
                    value: store.openAIBaseURL,
                    isCopied: copiedEndpoint
                ) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.openAIBaseURL, forType: .string)
                    copiedEndpoint = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copiedEndpoint = false
                    }
                }

                // Anthropic Base URL
                connectionTile(
                    title: "Anthropic Messages 端点",
                    value: store.anthropicBaseURL,
                    isCopied: false
                ) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.anthropicBaseURL, forType: .string)
                }

                // API Key
                connectionTile(
                    title: "本地授权 API Key",
                    value: store.localToken,
                    isCopied: copiedKey,
                    copyAction: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(store.localToken, forType: .string)
                        copiedKey = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            copiedKey = false
                        }
                    },
                    secondaryAction: {
                        showRotateTokenConfirm = true
                    },
                    secondaryIcon: "arrow.triangle.2.circlepath",
                    secondaryHelp: "重新生成高强度随机 Token 并自动同步已接入 Agent",
                    isOperating: isRotatingToken
                )
            }

            // 局域网访问开关与状态
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: "network")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.codexMuted)
                    Text("局域网接入")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.codexMuted)
                }

                Divider()
                    .frame(height: 12)
                    .overlay(Color.codexLine.opacity(0.3))

                Toggle(isOn: Binding(
                    get: { store.allowLanAccess },
                    set: { store.allowLanAccess = $0 }
                )) {
                    HStack(spacing: 4) {
                        Image(systemName: store.allowLanAccess ? "wifi" : "wifi.slash")
                            .font(.system(size: 10))
                        Text("允许局域网设备接入 (绑定 0.0.0.0)")
                            .font(.system(size: 11, weight: .regular))
                    }
                    .foregroundStyle(Color.codexInk)
                }
                .toggleStyle(.checkbox)
                .help("开启后网关监听 0.0.0.0，同一局域网下的其他设备可通过局域网 IP 调用；关闭后仅允许本机 127.0.0.1 访问")

                Spacer()

                if store.allowLanAccess {
                    if let ip = store.currentLANIPv4 {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                            Text("本机局域网 IP: \(ip)")
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.green)
                        }
                    } else {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 6, height: 6)
                            Text("未检测到有效局域网 IP")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Color.orange)
                        }
                    }
                } else {
                    Text("默认仅允许本机访问，端口安全隔离")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.codexMuted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.codexBackground.opacity(0.65), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.codexLine.opacity(0.25), lineWidth: 0.8)
            )

            if store.allowLanAccess {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        // LAN OpenAI Base URL
                        connectionTile(
                            title: "局域网 OpenAI Base URL",
                            value: store.lanOpenAIBaseURL ?? "http://<局域网IP>:\(supervisor.port)/v1",
                            isCopied: copiedLanOpenAI
                        ) {
                            if let url = store.lanOpenAIBaseURL {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url, forType: .string)
                                copiedLanOpenAI = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    copiedLanOpenAI = false
                                }
                            }
                        }

                        // LAN Anthropic Base URL
                        connectionTile(
                            title: "局域网 Anthropic Messages 端点",
                            value: store.lanAnthropicBaseURL ?? "http://<局域网IP>:\(supervisor.port)",
                            isCopied: copiedLanAnthropic
                        ) {
                            if let url = store.lanAnthropicBaseURL {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url, forType: .string)
                                copiedLanAnthropic = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    copiedLanAnthropic = false
                                }
                            }
                        }
                    }

                    HStack(spacing: 5) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.codexMuted)
                        Text("局域网设备接入时仍需携带上方「本地授权 API Key」：/v1/chat/completions 与 /v1/models 对非本机来源强制校验该令牌，本机回环调用不受影响。")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.codexMuted)
                    }
                    .padding(.top, 1)
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.2), lineWidth: 0.8)
                )
            }

            // 最终 /v1/models 可访问模型列表（默认折叠，点击展开）
            GatewayV1ModelsCollapsibleSection(store: store, onToast: onToast)

            // Minimal dynamic pass-through footer
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
                Text("全量模型动态透传已生效：直接在客户端指定上游支持的任意模型名即可原生调用。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.codexMuted)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .background(Color.codexCard)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.8)
        )
    }

    private func connectionTile(
        title: String,
        value: String,
        isCopied: Bool,
        copyAction: @escaping () -> Void,
        secondaryAction: (() -> Void)? = nil,
        secondaryIcon: String? = nil,
        secondaryHelp: String? = nil,
        isOperating: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Color.codexMuted)
                .lineLimit(1)

            HStack(spacing: 6) {
                Text(value)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.codexInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(value)

                Spacer(minLength: 2)

                if let secondaryAction, let secondaryIcon {
                    Button(action: secondaryAction) {
                        if isOperating {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: secondaryIcon)
                                .font(.system(size: 10))
                                .foregroundStyle(Color.codexMuted)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isOperating)
                    .help(secondaryHelp ?? "")
                }

                Button(action: copyAction) {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(isCopied ? Color.green : Color.codexMuted)
                }
                .buttonStyle(.plain)
                .help("复制到剪贴板")
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.codexBackground.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.codexLine.opacity(0.25), lineWidth: 0.6)
        )
    }
    private var heroControlCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(supervisor.isRunning ? Color.green : Color.red)
                        .frame(width: 7, height: 7)
                    Text(supervisor.statusText)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(supervisor.isRunning ? Color.green : Color.red)
                        .lineLimit(1)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(supervisor.isRunning ? Color.green.opacity(0.12) : Color.red.opacity(0.12), in: Capsule())

                Spacer()

                Button {
                    supervisor.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: supervisor.isRunning ? "stop.fill" : "play.fill")
                        Text(supervisor.isRunning ? "停止服务" : "启动服务")
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(supervisor.isRunning ? Color.red.opacity(0.88) : Color.accentColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .foregroundStyle(Color.white)
                }
                .buttonStyle(CodexPressableStyle(cornerRadius: 6))
            }

            CodexDivider(.horizontal)

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("对外标准 API 端点")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.codexMuted)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(store.openAIBaseURL)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.codexInk)
                            .lineLimit(1)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(store.openAIBaseURL, forType: .string)
                            copiedEndpoint = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                copiedEndpoint = false
                            }
                        } label: {
                            Image(systemName: copiedEndpoint ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10.5))
                                .foregroundStyle(copiedEndpoint ? Color.green : Color.codexMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()

                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("活跃调用")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.codexMuted)
                            .lineLimit(1)
                        Text("\(supervisor.activeRequests)")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.codexInk)
                            .lineLimit(1)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("外部总请求")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.codexMuted)
                            .lineLimit(1)
                        Text("\(supervisor.todayRequests)")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.codexInk)
                            .lineLimit(1)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("网关运行时间")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.codexMuted)
                            .lineLimit(1)
                        Text(supervisor.uptimeText)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.codexInk)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.codexCard)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.8)
        )
    }
}

// MARK: - 供应商聚合模块卡片 (多账号切换 + 2列防折叠模型矩阵)
@MainActor
struct GatewayProviderSectionCard: View {
    let section: GatewayProviderSection
    @Bindable var store: GatewayStore
    var settingsStore: MultiAgentSettingsStore?
    @Binding var syncingConnectionIDs: Set<ConnectionID>
    var onToast: GatewayToastHandler

    @State private var selectedAccountId: String? = nil
    @State private var isExpanded: Bool = false
    @State private var isHealthDetailExpanded: Bool = false
    @State private var healthFilterMode: HealthFilterMode = .problematic
    @State private var copiedModelId: String? = nil
    @State private var isAddingModel: Bool = false
    @State private var customModelInput: String = ""

    enum HealthFilterMode: String, CaseIterable, Identifiable {
        case problematic = "异常/不可用"
        case all = "全部"
        case available = "仅可用"

        var id: String { rawValue }
    }

    private var activeGroup: GatewayAccountModelGroup {
        if let selectedId = selectedAccountId,
           let match = section.accountGroups.first(where: { $0.id == selectedId }) {
            return match
        }
        return section.accountGroups[0]
    }

    private var isConsolidated: Bool {
        store.isProviderConsolidated(section.id)
    }

    private var consolidatedModels: [GatewayExportedModel] {
        store.consolidatedModels(for: section.id)
    }

    private var displayModels: [GatewayExportedModel] {
        isConsolidated ? consolidatedModels : activeGroup.models
    }

    private var activeAccountHealth: GatewayAccountHealth? {
        guard let cid = activeGroup.connectionID?.rawValue.uuidString else { return nil }
        return store.modelHealthResponse?.accounts.first {
            $0.connectionId.caseInsensitiveCompare(cid) == .orderedSame ||
            $0.connectionId.replacingOccurrences(of: "-", with: "").caseInsensitiveCompare(cid.replacingOccurrences(of: "-", with: "")) == .orderedSame
        }
    }

    private var activeHealthModelsDict: [String: GatewayModelHealthItem] {
        guard let health = activeAccountHealth else { return [:] }
        var dict: [String: GatewayModelHealthItem] = [:]
        for item in health.models {
            dict[item.id] = item
            let normKey = GatewayStore.normalizedModelLookupKey(item.id)
            dict[normKey] = item
            let base = GatewayStore.unscopedModelName(item.id)
            dict[base] = item
            let stripped = GatewayStore.normalizeCodexModelID(base)
            dict[stripped] = item
            dict[GatewayStore.normalizedModelLookupKey(stripped)] = item
        }
        return dict
    }

    /// 聚合模式下全量账号的健康度统计
    private var consolidatedHealthSummary: GatewayModelHealthSummary? {
        guard let accounts = store.modelHealthResponse?.accounts else { return nil }
        let cids = section.accountGroups.compactMap { $0.connectionID?.rawValue.uuidString.lowercased().replacingOccurrences(of: "-", with: "") }
        guard !cids.isEmpty else { return nil }
        let matched = accounts.filter { acc in
            let c = acc.connectionId.lowercased().replacingOccurrences(of: "-", with: "")
            return cids.contains(c)
        }
        guard !matched.isEmpty else { return nil }
        var total = 0, avail = 0, unavail = 0, err = 0, unchk = 0, skip = 0
        for m in matched {
            total += m.summary.total
            avail += m.summary.available
            unavail += m.summary.unavailable
            err += m.summary.error
            unchk += m.summary.unchecked
            skip += m.summary.skipped
        }
        return GatewayModelHealthSummary(
            total: total,
            available: avail,
            unavailable: unavail,
            error: err,
            unchecked: unchk,
            skipped: skip
        )
    }

    /// 聚合模式下基础模型名到健康条目的映射（合并各账号状态）
    private var consolidatedHealthModelsDict: [String: GatewayModelHealthItem] {
        guard let accounts = store.modelHealthResponse?.accounts else { return [:] }
        let cids = section.accountGroups.compactMap { $0.connectionID?.rawValue.uuidString.lowercased().replacingOccurrences(of: "-", with: "") }
        guard !cids.isEmpty else { return [:] }
        let matched = accounts.filter { acc in
            let c = acc.connectionId.lowercased().replacingOccurrences(of: "-", with: "")
            return cids.contains(c)
        }
        var dict: [String: GatewayModelHealthItem] = [:]
        for acc in matched {
            for item in acc.models {
                let base = GatewayStore.unscopedModelName(item.id)
                let norm = GatewayStore.normalizedModelLookupKey(item.id)
                let stripped = GatewayStore.normalizeCodexModelID(base)
                let normStripped = GatewayStore.normalizedModelLookupKey(stripped)
                for key in [base, norm, item.id, stripped, normStripped] {
                    if let existing = dict[key] {
                        // 若任一账号可用，则聚合判定为可用
                        if existing.status != "available" && item.status == "available" {
                            dict[key] = item
                        } else if existing.status == "unchecked" && item.status != "unchecked" {
                            dict[key] = item
                        }
                    } else {
                        dict[key] = item
                    }
                }
            }
        }
        return dict
    }

    private var displayRecommendedModels: [String] {
        if isConsolidated {
            return Array(consolidatedModels.prefix(4).map(\.modelName))
        }
        return activeGroup.recommendedModels
    }

    private var totalModelsCount: Int {
        if isConsolidated {
            return consolidatedModels.count
        }
        return section.accountGroups.reduce(0) { $0 + $1.models.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GatewayProviderCardHeader(
                section: section,
                totalModelsCount: totalModelsCount,
                isConsolidated: isConsolidated,
                onToggleConsolidated: { enabled in
                    store.setProviderConsolidated(section.id, enabled: enabled)
                }
            )

            if isConsolidated {
                GatewayProviderRoutingBar(
                    providerId: section.id,
                    currentMode: store.providerRoutingMode(for: section.id),
                    pinnedAccountId: store.providerPinnedAccountId(for: section.id),
                    accountGroups: section.accountGroups.filter { $0.connectionID != nil && $0.isConnected },
                    onChangeMode: { mode, pinnedId in
                        store.setProviderRoutingMode(section.id, mode: mode, pinnedAccountId: pinnedId)
                    }
                )
            }

            if !section.accountGroups.isEmpty {
                GatewayAccountSwitcherBar(
                    groups: section.accountGroups,
                    activeGroupId: activeGroup.id,
                    isExpanded: isExpanded,
                    isConsolidated: isConsolidated,
                    totalModelsCount: displayModels.count,
                    onSelect: { selectedAccountId = $0 },
                    onToggleExpand: { isExpanded.toggle() }
                )
            }

            activeAccountWorkspace
        }
        .padding(12)
        .background(Color.codexCard)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.8)
        )
    }

    private var activeAccountWorkspace: some View {
        let isSyncing = activeGroup.connectionID.map { syncingConnectionIDs.contains($0) } ?? false

        return VStack(alignment: .leading, spacing: 10) {
            // Info & Primary Actions Row
            HStack(alignment: .center, spacing: 8) {
                accountInfoView

                Spacer()

                if activeGroup.connectionID != nil {
                    GatewayAccountProxyToggleButton(
                        isEnabled: activeGroup.isProxyEnabled,
                        isAllowed: activeGroup.isProxyAllowed,
                        isSyncing: isSyncing,
                        onToggle: { toggleProxy(for: activeGroup) }
                    )
                }

                if let cid = activeGroup.connectionID {
                    let cidStr = cid.rawValue.uuidString.lowercased()
                    let cleanCid = cidStr.replacingOccurrences(of: "-", with: "")
                    let isCheckingThis = store.isModelCheckRunning && store.checkingAccountScopes.contains(where: { scope in
                        let s = scope.lowercased().replacingOccurrences(of: "-", with: "")
                        return s.contains(cleanCid)
                    })

                    if isCheckingThis {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.mini)
                            if store.isCancellingModelCheck {
                                Text("正在取消...")
                            } else if let progress = store.modelCheckStatus, progress.total > 0, progress.scope != "all" {
                                Text("巡检 \(progress.done)/\(progress.total)")
                            } else {
                                Text("巡检中...")
                            }

                            Divider()
                                .frame(height: 10)
                                .opacity(0.3)

                            Button {
                                Task {
                                    let res = await store.cancelModelCheck()
                                    onToast(res.message, res.success ? "stop.circle" : "exclamationmark.triangle", res.success)
                                }
                            } label: {
                                HStack(spacing: 2) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 10))
                                    Text("取消")
                                        .font(.system(size: 10))
                                }
                                .foregroundStyle(Color.codexMuted)
                            }
                            .buttonStyle(.plain)
                            .disabled(store.isCancellingModelCheck)
                            .help("点击取消当前巡检任务")
                        }
                        .font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(Color.codexLine.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(Color.codexInk)
                    } else {
                        Button {
                            Task {
                                let res = await store.triggerModelCheck(provider: section.id, connectionId: cidStr)
                                onToast(res.message, res.success ? "stethoscope" : "exclamationmark.triangle", res.success)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "stethoscope")
                                Text("检查可用性")
                            }
                            .font(.system(size: 10.5, weight: .medium))
                            .padding(.horizontal, 8)
                            .frame(height: 26)
                            .background(Color.codexLine.opacity(store.isModelCheckRunning ? 0.08 : 0.15), in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(store.isModelCheckRunning ? Color.codexMuted.opacity(0.5) : Color.codexInk)
                        }
                        .buttonStyle(.plain)
                        .disabled(store.isModelCheckRunning)
                        .help(store.isModelCheckRunning ? "巡检正在进行中，请等待完成或取消当前巡检" : "逐条对当前账号的模型发送 ping 进行可用性检测并记录原因")
                    }
                }

                healthDiagnosisPillButton
            }

            GatewayAccountStatusBanners(
                isSyncing: isSyncing,
                isProxyEnabled: activeGroup.isProxyEnabled,
                isProxyAllowed: activeGroup.isProxyAllowed,
                hasZeroModels: activeGroup.models.isEmpty && activeGroup.connectionID != nil,
                onResync: { syncModels(for: activeGroup) }
            )

            if isHealthDetailExpanded {
                accountHealthDetailPanel
            }

            if activeGroup.isProxyEnabled && isExpanded {
                let currentMode = store.providerRoutingMode(for: section.id)
                let pinnedId = store.providerPinnedAccountId(for: section.id)
                let pinnedName: String? = {
                    if let pinnedId = pinnedId,
                       let group = section.accountGroups.first(where: {
                           $0.connectionID?.rawValue.uuidString.caseInsensitiveCompare(pinnedId) == .orderedSame
                       }) {
                        return group.accountName
                    }
                    return nil
                }()

                GatewayAccountModelsDrawer(
                    store: store,
                    quickConnectTip: isConsolidated
                        ? "已开启账号池聚合调度，所有可用账号将依据健康状态与额度自动均衡分配。在客户端中指定模型名称（包含供应商前缀）即可直接调用。"
                        : activeGroup.quickConnectTip,
                    models: displayModels,
                    healthModels: isConsolidated ? consolidatedHealthModelsDict : activeHealthModelsDict,
                    isConsolidated: isConsolidated,
                    routingMode: currentMode,
                    pinnedAccountName: pinnedName,
                    isAddingModel: $isAddingModel,
                    customModelInput: $customModelInput,
                    copiedModelId: copiedModelId,
                    onAddCustomModel: { name in
                        addCustomModel(name, toGroupId: activeGroup.id)
                    },
                    onRemoveCustomModel: { name in
                        removeCustomModel(name, fromGroupId: activeGroup.id)
                    },
                    onCopyModel: { name, id in
                        copyModel(name, id: id)
                    }
                )
                .padding(.horizontal, 2)
            }
        }
        .padding(10)
        .background(Color.codexBackground.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.codexLine.opacity(0.25), lineWidth: 0.6)
        )
    }

    static func healthRank(_ status: String) -> Int {
        switch status {
        case "available": 0
        case "error": 1
        case "skipped": 2
        case "unavailable": 3
        default: 4
        }
    }

    /// 单个账号的模型健康巡检详情：列出每个模型的状态、延迟与错误原因。
    @ViewBuilder
    private var accountHealthDetailPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                HStack(spacing: 5) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                    Text("模型可用性巡检诊断")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.codexInk)
                }

                Spacer()

                // 筛选器
                Picker("", selection: $healthFilterMode) {
                    ForEach(HealthFilterMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .frame(width: 220)
            }

            // 诊断结果列表 (无任何二次账号选择器，100% 联动上方当前选定账号)
            ScrollView(showsIndicators: false) {
                if let health = activeAccountHealth {
                    let filtered = health.models.filter { item in
                        switch healthFilterMode {
                        case .all:
                            return true
                        case .problematic:
                            return item.status != "available"
                        case .available:
                            return item.status == "available"
                        }
                    }

                    let ordered = filtered.sorted { lhs, rhs in
                        let r1 = Self.healthRank(lhs.status)
                        let r2 = Self.healthRank(rhs.status)
                        if r1 != r2 { return r1 < r2 }
                        return lhs.id < rhs.id
                    }

                    if ordered.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: healthFilterMode == .problematic ? "checkmark.seal.fill" : "info.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(healthFilterMode == .problematic ? Color.green : Color.codexMuted)
                            Text(healthFilterMode == .problematic ? "太棒了！当前账号没有发现异常或不可用的模型。" : "当前筛选条件下暂无模型。")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Color.codexMuted)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 4)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(ordered) { item in
                                healthDetailRow(item)
                                if item.id != ordered.last?.id {
                                    CodexDivider(.horizontal)
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .background(Color.codexBackground.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                } else {
                    Text("尚未执行巡检，点击上方“检查可用性”后即可查看每个模型的具体状态。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.codexMuted)
                        .padding(.vertical, 6)
                }
            }
            .frame(maxHeight: 380)
            .scrollIndicators(.hidden)
            .background(ScrollIndicatorHider())
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.accentColor.opacity(0.16), lineWidth: 0.8)
        )
    }

    private func healthDetailRow(_ item: GatewayModelHealthItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                // 状态徽章
                HStack(spacing: 4) {
                    Circle()
                        .fill(healthStatusColor(item.status))
                        .frame(width: 7, height: 7)
                    Text(healthStatusText(item.status))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(healthStatusColor(item.status))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(healthStatusColor(item.status).opacity(0.1), in: RoundedRectangle(cornerRadius: 4))

                Text(item.id)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.codexInk)
                    .lineLimit(1)

                Spacer()

                if let ms = item.latencyMs {
                    Text("\(ms)ms")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color.codexMuted)
                }
                if let retries = item.retries, retries > 0 {
                    Text("重试 ×\(retries)")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.orange)
                }
            }

            if let reason = item.reason, !reason.isEmpty, item.status != "available" {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: item.status == "error" ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(healthStatusColor(item.status))
                        .padding(.top, 1.5)

                    Text(reason)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.codexInk.opacity(0.85))
                        .textSelection(.enabled)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer()

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(reason, forType: .string)
                        onToast("已复制报错信息", "checkmark.circle.fill", true)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "doc.on.doc")
                            Text("复制报错")
                        }
                        .font(.system(size: 9))
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("复制该错误原因到剪贴板")
                }
                .padding(6)
                .background(healthStatusColor(item.status).opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(healthStatusColor(item.status).opacity(0.2), lineWidth: 0.5)
                )
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
    }

    private func healthStatusColor(_ status: String) -> Color {
        switch status {
        case "available": .green
        case "unavailable": .red
        case "error": .orange
        case "skipped": .gray
        default: Color.codexMuted
        }
    }

    private func healthStatusText(_ status: String) -> String {
        switch status {
        case "available": "可用"
        case "unavailable": "不可用"
        case "error": "异常"
        case "skipped": "跳过"
        default: "未检查"
        }
    }

    private var accountInfoView: some View {
        VStack(alignment: .leading, spacing: 2.5) {
            if isConsolidated {
                HStack(spacing: 6) {
                    Text("当前调度模式:")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.codexMuted)

                    Text("账号池聚合调度")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(Color.purple)
                        .lineLimit(1)

                    let activeCount = section.accountGroups.filter { $0.isProxyEnabled }.count
                    Text("\(activeCount) 个账号协同")
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color.purple)
                        .lineLimit(1)
                }

                Text("按额度与健康度自动调度，模型名已带供应商统一前缀")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.codexMuted)
                    .lineLimit(1)
            } else {
                HStack(spacing: 6) {
                    Text("当前选定账号:")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.codexMuted)

                    Text(activeGroup.accountName)
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(Color.codexInk)
                        .lineLimit(1)

                    Text(activeGroup.isProxyEnabled ? activeGroup.badgeText : "代理已停用")
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(activeGroup.isProxyEnabled ? Color.green.opacity(0.12) : Color.codexMist, in: Capsule())
                        .foregroundStyle(activeGroup.isProxyEnabled ? Color.green : Color.codexMuted)
                        .lineLimit(1)
                }

                if let email = activeGroup.email, !email.isEmpty {
                    Text(email)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.codexMuted)
                        .lineLimit(1)
                }
            }
        }
    }

    private var healthDiagnosisPillButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isHealthDetailExpanded.toggle()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.accentColor)

                if isConsolidated {
                    if let summary = consolidatedHealthSummary {
                        Text("可用 \(summary.available)")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Color.green)
                        Text("·")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.codexMuted)
                        Text("不可用 \(summary.unavailable)")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(summary.unavailable > 0 ? Color.red : Color.codexMuted)
                        if summary.error > 0 {
                            Text("·")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.codexMuted)
                            Text("异常 \(summary.error)")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(Color.orange)
                        }
                    } else {
                        Text("巡检诊断")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Color.codexMuted)
                    }
                } else {
                    if let health = activeAccountHealth {
                        Text("可用 \(health.summary.available)")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Color.green)
                        Text("·")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.codexMuted)
                        Text("不可用 \(health.summary.unavailable)")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(health.summary.unavailable > 0 ? Color.red : Color.codexMuted)
                        if health.summary.error > 0 {
                            Text("·")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.codexMuted)
                            Text("异常 \(health.summary.error)")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(Color.orange)
                        }
                    } else {
                        Text("巡检诊断")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Color.codexMuted)
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(Color.codexMuted)
                    .rotationEffect(.degrees(isHealthDetailExpanded ? 90 : 0))
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(isHealthDetailExpanded ? Color.accentColor.opacity(0.12) : Color.codexLine.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isHealthDetailExpanded ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
        .help("展开/收起查看模型的具体可用状态与错误原因")
    }

    private func toggleProxy(for group: GatewayAccountModelGroup) {
        guard let connID = group.connectionID, group.isProxyAllowed else { return }
        let isSyncing = syncingConnectionIDs.contains(connID)
        guard !isSyncing else { return }

        let willEnable = !group.isProxyEnabled
        if willEnable {
            syncingConnectionIDs.insert(connID)
            Task { @MainActor in
                if let ss = settingsStore {
                    ss.setConnectionProxyEnabled(id: connID, enabled: true)
                    store.toggleConnectionProxy(id: connID)

                    let result = await ss.syncConnectionModels(id: connID)
                    store.toggleConnectionProxy(id: connID)
                    syncingConnectionIDs.remove(connID)

                    switch result {
                    case let .success(count, _):
                        onToast("已开启 [\(group.accountName)] 代理 · 同步到 \(count) 款可用模型", "checkmark.circle.fill", true)
                    case let .warning(msg):
                        onToast("已开启代理 · \(msg)", "exclamationmark.triangle.fill", true)
                    case let .failure(errMsg):
                        ss.setConnectionProxyEnabled(id: connID, enabled: false)
                        store.toggleConnectionProxy(id: connID)
                        onToast("开启代理失败：\(errMsg)", "xmark.circle.fill", false)
                    }
                } else {
                    store.toggleConnectionProxy(id: connID)
                    syncingConnectionIDs.remove(connID)
                    onToast("已开启网关代理", "checkmark.circle.fill", true)
                }
            }
        } else {
            if let ss = settingsStore {
                ss.setConnectionProxyEnabled(id: connID, enabled: false)
            }
            store.toggleConnectionProxy(id: connID)
            onToast("已关闭 [\(group.accountName)] 网关代理", "pause.circle.fill", true)
        }
    }

    private func syncModels(for group: GatewayAccountModelGroup) {
        guard let connID = group.connectionID else { return }
        syncingConnectionIDs.insert(connID)
        Task { @MainActor in
            if let ss = settingsStore {
                let result = await ss.syncConnectionModels(id: connID)
                store.toggleConnectionProxy(id: connID)
                syncingConnectionIDs.remove(connID)
                switch result {
                case let .success(count, _):
                    onToast("已成功同步 \(count) 款可用模型", "checkmark.circle.fill", true)
                case let .warning(msg):
                    onToast(msg, "exclamationmark.triangle.fill", true)
                case let .failure(errMsg):
                    onToast("同步失败：\(errMsg)", "xmark.circle.fill", false)
                }
            } else {
                syncingConnectionIDs.remove(connID)
            }
        }
    }

    private func copyModel(_ modelName: String, id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(modelName, forType: .string)
        copiedModelId = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copiedModelId = nil
        }
    }

    private func addCustomModel(_ name: String, toGroupId: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            store.addCustomModel(trimmed, toGroupId: toGroupId)
            isAddingModel = false
            customModelInput = ""
        }
    }

    private func removeCustomModel(_ name: String, fromGroupId: String) {
        store.removeCustomModel(name, fromGroupId: fromGroupId)
    }
}

// MARK: - Subviews for ProviderSectionCard

@MainActor
private struct GatewayProviderCardHeader: View {
    let section: GatewayProviderSection
    let totalModelsCount: Int
    let isConsolidated: Bool
    let onToggleConsolidated: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            BrandIconView(
                asset: section.brandAsset,
                size: 34,
                cornerRadius: 8
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(section.providerTitle)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.codexInk)

                    Text("\(section.accountGroups.count) 个已连接账号 · 共 \(totalModelsCount) 款模型")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.codexPrimary.opacity(0.06), in: Capsule())
                        .foregroundStyle(Color.codexInk)
                }

                Text(section.subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.codexMuted)
                    .lineLimit(1)
            }

            Spacer()

            consolidationToggle
        }
    }

    private var consolidationToggle: some View {
        HStack(spacing: 8) {
            VStack(alignment: .trailing, spacing: 1.5) {
                HStack(spacing: 4) {
                    Image(systemName: isConsolidated ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                        .font(.system(size: 10))
                        .foregroundStyle(isConsolidated ? Color.purple : Color.codexMuted)
                    Text("账号池聚合")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.codexInk)
                }
                Text(isConsolidated ? "额度健康调度 · 故障转移" : "逐账号独立隔离")
                    .font(.system(size: 9.5))
                    .foregroundStyle(isConsolidated ? Color.purple : Color.codexMuted)
            }

            Toggle("", isOn: Binding(
                get: { isConsolidated },
                set: { onToggleConsolidated($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            isConsolidated
                ? Color.purple.opacity(0.06)
                : Color.codexMist.opacity(0.4),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isConsolidated
                        ? Color.purple.opacity(0.25)
                        : Color.codexLine.opacity(0.3),
                    lineWidth: 0.8
                )
        )
    }
}

@MainActor
private struct GatewayProviderRoutingBar: View {
    let providerId: String
    let currentMode: ProviderRoutingMode
    let pinnedAccountId: String?
    let accountGroups: [GatewayAccountModelGroup]
    let onChangeMode: (ProviderRoutingMode, String?) -> Void

    private var pinnedAccountName: String {
        if let pinnedId = pinnedAccountId,
           let group = accountGroups.first(where: {
               $0.connectionID?.rawValue.uuidString.caseInsensitiveCompare(pinnedId) == .orderedSame
           }) {
            return group.accountName
        }
        return accountGroups.first?.accountName ?? "选择账号"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.purple)
                    Text("调度策略")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.codexInk)
                }

                Spacer()

                // 调度策略紧凑分段选择器（短 Tab + 项目强调色）
                HStack(spacing: 2) {
                    ForEach(ProviderRoutingMode.allCases) { mode in
                        let isSel = currentMode == mode
                        Button {
                            let targetPinnedId: String? = {
                                if mode == .pinnedAccount {
                                    return pinnedAccountId ?? accountGroups.first?.connectionID?.rawValue.uuidString
                                }
                                return pinnedAccountId
                            }()
                            onChangeMode(mode, targetPinnedId)
                        } label: {
                            Text(mode.title)
                                .font(.system(size: 10.5, weight: isSel ? .semibold : .medium))
                                .padding(.horizontal, 9)
                                .frame(height: 22)
                                .foregroundStyle(isSel ? Color.codexOnPrimary : Color.codexMuted)
                                .background(
                                    isSel ? Color.codexPrimary : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                )
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

                // If pinnedAccount is active, show account dropdown menu
                if currentMode == .pinnedAccount && !accountGroups.isEmpty {
                    Menu {
                        ForEach(accountGroups) { grp in
                            if let cid = grp.connectionID?.rawValue.uuidString {
                                Button {
                                    onChangeMode(.pinnedAccount, cid)
                                } label: {
                                    HStack {
                                        Text(grp.accountName)
                                        if let pId = pinnedAccountId, pId.caseInsensitiveCompare(cid) == .orderedSame {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.purple)
                            Text(pinnedAccountName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.codexInk)
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color.codexMuted)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.purple.opacity(0.3), lineWidth: 0.8)
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            // Strategy explanation helper text
            HStack(spacing: 4) {
                Image(systemName: tipIcon)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.purple.opacity(0.8))
                Text(strategyTip)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.codexMuted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.codexMist.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.codexLine.opacity(0.3), lineWidth: 0.8)
        )
    }

    private var tipIcon: String {
        switch currentMode {
        case .smooth: return "arrow.triangle.2.circlepath"
        case .pinnedAccount: return "pin.fill"
        }
    }

    private var strategyTip: String {
        switch currentMode {
        case .smooth:
            return "平滑过渡：多账号根据额度评分与使用时间 (LRU) 动态轮询，均衡消耗额度并降低 RPM 限频。"
        case .pinnedAccount:
            return "固定特定账号：统一模型请求优先路由至 [\(pinnedAccountName)]；若额度耗尽或报错将自动切换为平滑过渡策略。"
        }
    }
}

@MainActor
private struct GatewayAccountSwitcherBar: View {
    let groups: [GatewayAccountModelGroup]
    let activeGroupId: String
    let isExpanded: Bool
    let isConsolidated: Bool
    let totalModelsCount: Int
    let onSelect: (String) -> Void
    let onToggleExpand: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(groups) { grp in
                            let isSelected = activeGroupId == grp.id
                            Button {
                                onSelect(grp.id)
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    proxy.scrollTo(grp.id, anchor: .center)
                                }
                            } label: {
                                accountTabLabel(grp: grp, isSelected: isSelected)
                            }
                            .id(grp.id)
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 1)
                    .background(ScrollIndicatorHider())
                }
                .scrollIndicators(.hidden)
                .onChange(of: activeGroupId) { _, newID in
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }

            Spacer(minLength: 0)

            // 位于账号行右侧的模型抽屉展开按钮
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    onToggleExpand()
                }
            } label: {
                HStack(spacing: 4) {
                    Text(isExpanded ? "收起" : (isConsolidated ? "全部聚合模型 (\(totalModelsCount))" : "全部模型 (\(totalModelsCount))"))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(isExpanded ? Color.codexPrimary.opacity(0.1) : Color.codexMist, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .foregroundStyle(isExpanded ? Color.codexPrimary : Color.codexInk)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isExpanded ? Color.codexPrimary.opacity(0.3) : Color.codexLine.opacity(0.35), lineWidth: 0.8)
                )
            }
            .buttonStyle(CodexPressableStyle(cornerRadius: 6))
            .help(isExpanded ? "收起模型列表" : "展开查看可访问的模型清单")
        }
    }

    private func accountTabLabel(grp: GatewayAccountModelGroup, isSelected: Bool) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(grp.isProxyEnabled ? (isSelected ? Color.green : Color.green.opacity(0.7)) : Color.codexMuted.opacity(0.4))
                .frame(width: 5.5, height: 5.5)

            Text(grp.accountName)
                .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                .lineLimit(1)

            Text(grp.isProxyEnabled ? grp.badgeText : "已停用")
                .font(.system(size: 9.5))
                .opacity(isSelected ? 0.9 : 0.65)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 27)
        .background(
            isSelected ? Color.codexPrimary : Color.codexMist.opacity(0.55),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .foregroundStyle(isSelected ? Color.codexOnPrimary : (grp.isProxyEnabled ? Color.codexInk : Color.codexMuted))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isSelected ? Color.clear : Color.codexLine.opacity(0.3), lineWidth: 0.6)
        )
    }
}

@MainActor
private struct GatewayAccountProxyToggleButton: View {
    let isEnabled: Bool
    let isAllowed: Bool
    let isSyncing: Bool
    let onToggle: () -> Void

    private var circleColor: Color {
        if isSyncing { return Color.orange }
        if isEnabled { return Color.green }
        return isAllowed ? Color.codexMuted : Color.orange
    }

    private var textColor: Color {
        if isSyncing { return Color.orange }
        if isEnabled { return Color.green }
        return isAllowed ? Color.codexMuted : Color.orange
    }

    private var btnTitle: String {
        if isSyncing {
            return isEnabled ? "正在开启..." : "正在同步..."
        }
        if isEnabled {
            return "代理已开启"
        }
        return isAllowed ? "代理已关闭" : "OAuth 未就绪"
    }

    private var btnBg: Color {
        if isSyncing { return Color.orange.opacity(0.12) }
        if isEnabled { return Color.green.opacity(0.12) }
        return isAllowed ? Color.codexMist : Color.orange.opacity(0.12)
    }

    private var strokeColor: Color {
        if isSyncing { return Color.orange.opacity(0.4) }
        if isEnabled { return Color.green.opacity(0.3) }
        return isAllowed ? Color.codexLine.opacity(0.4) : Color.orange.opacity(0.4)
    }

    private var helpText: String {
        if !isAllowed { return "请重新登录 OAuth 账号后再开启代理" }
        if isSyncing { return "正在验证授权并同步可用模型..." }
        if isEnabled { return "点击关闭该账号的网关代理" }
        return "点击开启该账号的网关代理并同步模型"
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 4.5) {
                if isSyncing {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Circle()
                        .fill(circleColor)
                        .frame(width: 5.5, height: 5.5)
                }
                Text(btnTitle)
            }
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(btnBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .foregroundStyle(textColor)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(strokeColor, lineWidth: 0.8)
            )
        }
        .buttonStyle(CodexPressableStyle(cornerRadius: 6))
        .help(helpText)
        .disabled(!isAllowed || isSyncing)
    }
}

@MainActor
private struct GatewayAccountStatusBanners: View {
    let isSyncing: Bool
    let isProxyEnabled: Bool
    let isProxyAllowed: Bool
    let hasZeroModels: Bool
    let onResync: () -> Void

    var body: some View {
        if isSyncing {
            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("正在验证授权并同步可用模型目录...")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.codexInk)
                    Text("正在向官方服务验证 OAuth 凭据并拉取可用模型配额，首次或重连通常需要 1~2 秒，完成后将自动刷新网关模型路由。")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.codexMuted)
                }
                Spacer()
            }
            .padding(10)
            .background(Color.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.purple.opacity(0.25), lineWidth: 0.8)
            )
        } else if !isProxyEnabled {
            HStack(spacing: 8) {
                Image(systemName: isProxyAllowed ? "pause.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(isProxyAllowed ? "该账号已关闭网关代理" : "OAuth 未就绪")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.codexInk)

                    Text(isProxyAllowed ? "该账号的所有模型已在网关模型列表 (/v1/models) 中隐藏，且不再参与网关路由分流。" : "请重新登录账号；Gateway 只使用有效凭据出流。")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.codexMuted)
                }

                Spacer()
            }
            .padding(10)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.orange.opacity(0.25), lineWidth: 0.8)
            )
        } else if hasZeroModels {
            HStack(spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text("代理已开启 · 暂未发现可用模型")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.codexInk)

                    Text("官方授权已连接，但尚未拉取到可用的模型列表。点击右侧按钮可重新同步，或在下方手动添加自定义透传模型。")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.codexMuted)
                }

                Spacer()

                Button(action: onResync) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("立即同步模型")
                    }
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 9)
                    .frame(height: 25)
                    .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .foregroundStyle(Color.orange)
                }
                .buttonStyle(CodexPressableStyle(cornerRadius: 5))
            }
            .padding(10)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.orange.opacity(0.25), lineWidth: 0.8)
            )
        }
    }
}

@MainActor
private struct GatewayAccountModelsDrawer: View {
    @Bindable var store: GatewayStore
    let quickConnectTip: String
    let models: [GatewayExportedModel]
    var healthModels: [String: GatewayModelHealthItem] = [:]
    var isConsolidated: Bool = false
    var routingMode: ProviderRoutingMode = .smooth
    var pinnedAccountName: String? = nil
    @Binding var isAddingModel: Bool
    @Binding var customModelInput: String
    let copiedModelId: String?
    let onAddCustomModel: (String) -> Void
    let onRemoveCustomModel: (String) -> Void
    let onCopyModel: (String, String) -> Void

    @State private var configuringCapabilityModel: GatewayExportedModel? = nil

    private let tableSpacing: CGFloat = 8
    private let tableHorizontalPadding: CGFloat = 9
    private let operationColumnWidth: CGFloat = 80

    private func healthColor(for status: String) -> Color {
        switch status {
        case "available": Color.green
        case "unavailable": Color.red
        case "error": Color.orange
        default: Color.codexMuted
        }
    }

    private func healthText(for item: GatewayModelHealthItem) -> String {
        switch item.status {
        case "available": "可用"
        case "unavailable": "不可用"
        case "error": "异常"
        case "skipped": "已跳过"
        default: "未检查"
        }
    }

    private func findHealth(for model: GatewayExportedModel) -> GatewayModelHealthItem? {
        let base = GatewayStore.unscopedModelName(model.modelName)
        let normBase = GatewayStore.normalizedModelLookupKey(base)
        let normModelName = GatewayStore.normalizedModelLookupKey(model.modelName)
        let normId = GatewayStore.normalizedModelLookupKey(model.id)
        let lastPart = model.id.components(separatedBy: "/").last ?? ""
        let normLastPart = GatewayStore.normalizedModelLookupKey(lastPart)

        let candidates = [
            base,
            normBase,
            model.modelName,
            normModelName,
            model.id,
            normId,
            lastPart,
            normLastPart,
            "\(base)-wm",
            "\(normBase)-wm",
            "\(lastPart)-wm",
            "\(normLastPart)-wm"
        ]
        for candidate in candidates where !candidate.isEmpty {
            if let h = healthModels[candidate] { return h }
        }
        return nil
    }

    private var filteredModels: [GatewayExportedModel] {
        models.filter { model in
            let h = findHealth(for: model)
            // 未巡检过（h == nil）或巡检判定为 available
            return h == nil || h?.status == "available"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CodexDivider(.horizontal)

            // Quick Connect Tip
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .padding(.top, 1)
                Text(quickConnectTip)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.codexInk)
                    .lineSpacing(2)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.codexPrimary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // Custom Model Input & Models Table
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center) {
                    Text("可访问可用模型清单 (\(filteredModels.count))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.codexInk)

                    Spacer()

                    Button {
                        isAddingModel.toggle()
                        if !isAddingModel {
                            customModelInput = ""
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: isAddingModel ? "xmark" : "plus.circle")
                            Text(isAddingModel ? "取消" : "添加/自定义透传模型")
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(Color.codexInk)
                    }
                    .buttonStyle(.plain)
                }

                if isAddingModel {
                    HStack(spacing: 6) {
                        TextField("输入模型 ID (例如 gemini-3.7-flash, deepseek-v4-pro...)", text: $customModelInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 10.5, design: .monospaced))

                        Button("添加") {
                            onAddCustomModel(customModelInput)
                        }
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Color.codexPrimary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .foregroundStyle(Color.codexOnPrimary)
                        .buttonStyle(CodexPressableStyle(cornerRadius: 5))
                    }
                    .padding(.vertical, 4)
                }

                if filteredModels.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.codexMuted)
                        Text("当前暂无可用模型。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.codexMuted)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 6)
                } else {
                    // 三个数据列始终共享当前卡片的剩余宽度，不声明固定或最小宽度。
                    HStack(spacing: tableSpacing) {
                        Text("模型名称 / ID")
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                        Text("调度 / 特性")
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                        Text("说明 / 状态")
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                        Text("操作")
                            .frame(width: operationColumnWidth, alignment: .trailing)
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.codexMuted)
                    .padding(.horizontal, tableHorizontalPadding)
                    .padding(.vertical, 4)
                    .background(Color.codexMist.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))

                    ForEach(filteredModels) { model in
                        let isCopied = copiedModelId == model.id
                        let healthItem = findHealth(for: model)

                        HStack(spacing: tableSpacing) {
                            HStack(spacing: 5) {
                                Text(model.modelName)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Color.codexInk)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .help(model.modelName)

                                if let healthItem = healthItem {
                                    HStack(spacing: 3.5) {
                                        Circle()
                                            .fill(healthColor(for: healthItem.status))
                                            .frame(width: 5.5, height: 5.5)
                                        Text(healthText(for: healthItem))
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(healthColor(for: healthItem.status))
                                        if let ms = healthItem.latencyMs {
                                            Text("\(ms)ms")
                                                .font(.system(size: 8.5, design: .monospaced))
                                                .foregroundStyle(Color.codexMuted)
                                        }
                                    }
                                    .padding(.horizontal, 4.5)
                                    .padding(.vertical, 1.5)
                                    .background(healthColor(for: healthItem.status).opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                                    .help(healthItem.reason.map { "[\(healthText(for: healthItem))] \($0)" } ?? (healthItem.isAvailable ? "状态正常 (已验证)" : "未检查"))
                                    .fixedSize()
                                } else {
                                    HStack(spacing: 3.5) {
                                        Circle()
                                            .fill(Color.codexMuted.opacity(0.5))
                                            .frame(width: 5, height: 5)
                                        Text("未检查")
                                            .font(.system(size: 9))
                                            .foregroundStyle(Color.codexMuted)
                                    }
                                    .padding(.horizontal, 4.5)
                                    .padding(.vertical, 1.5)
                                    .background(Color.codexLine.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                                    .help("点击上方“检查可用性”即可检测该模型")
                                    .fixedSize()
                                }
                            }
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                            let displayCapability: String = {
                                if isConsolidated {
                                    if routingMode == .pinnedAccount, let pName = pinnedAccountName, !pName.isEmpty {
                                        return "固定直通 \(pName)"
                                    }
                                    return "同供应商额度自动调度聚合模型"
                                }
                                return model.capability
                            }()

                            Text(displayCapability)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.codexMuted)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                .help(displayCapability)

                            Group {
                                if let reason = healthItem?.reason, !reason.isEmpty, healthItem?.status != "available" {
                                    Text(reason)
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundStyle(healthColor(for: healthItem?.status ?? ""))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .help(reason)
                                } else {
                                    Text(model.description)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.codexMuted)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .help(model.description)
                                }
                            }
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                            HStack(spacing: 8) {
                                Button {
                                    configuringCapabilityModel = model
                                } label: {
                                    Image(systemName: "slider.horizontal.3")
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(Color.codexMuted)
                                }
                                .buttonStyle(.plain)
                                .help("配置该模型的规格与推理能力")

                                if model.isCustom {
                                    Button {
                                        onRemoveCustomModel(model.modelName)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 9))
                                            .foregroundStyle(Color.red.opacity(0.7))
                                    }
                                    .buttonStyle(.plain)
                                    .help("移除自定义透传模型")
                                }

                                Button {
                                    onCopyModel(model.modelName, model.id)
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                        Text(isCopied ? "已复制" : "复制")
                                    }
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(isCopied ? Color.green : Color.codexMuted)
                                }
                                .buttonStyle(.plain)
                            }
                            .frame(width: operationColumnWidth, alignment: .trailing)
                        }
                        .padding(.horizontal, tableHorizontalPadding)
                        .padding(.vertical, 5)
                        .background(Color.codexBackground.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .sheet(item: $configuringCapabilityModel) { model in
            GatewayModelCapabilityModal(
                modelID: model.id,
                modelName: model.modelName,
                settings: $store.gatewaySettings,
                onSave: {
                    store.saveGatewaySettings()
                },
                onDismiss: {
                    configuringCapabilityModel = nil
                }
            )
        }
    }
}

// MARK: - 最终 /v1/models 可访问模型列表（默认折叠组件）

@MainActor
private struct GatewayV1ModelsCollapsibleSection: View {
    @Bindable var store: GatewayStore
    let onToast: (String, String, Bool) -> Void

    @State private var isExpanded: Bool = false
    @State private var searchText: String = ""
    @State private var copiedModelId: String? = nil
    @State private var copiedAllIDs: Bool = false

    private var displayModels: [GatewayV1ModelItem] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty {
            return store.v1Models
        }
        return store.v1Models.filter { item in
            item.id.lowercased().contains(trimmed) ||
            item.effectiveDisplayName.lowercased().contains(trimmed) ||
            item.effectiveProvider.lowercased().contains(trimmed) ||
            (item.account?.lowercased().contains(trimmed) ?? false) ||
            (item.description?.lowercased().contains(trimmed) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 折叠条头部
            HStack(spacing: 8) {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                    if isExpanded && store.v1Models.isEmpty {
                        Task {
                            await store.fetchV1Models()
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "list.bullet.rectangle.portrait.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.accentColor)

                        Text("最终 /v1/models 可访问模型列表")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.codexInk)

                        if store.isV1ModelsLoading {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.7)
                        } else {
                            Text("\(store.v1Models.count) 款可用")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(store.v1Models.isEmpty ? Color.codexMuted : Color.green)
                                .padding(.horizontal, 5.5)
                                .padding(.vertical, 1.5)
                                .background(
                                    (store.v1Models.isEmpty ? Color.codexLine.opacity(0.15) : Color.green.opacity(0.12)),
                                    in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                                )
                        }

                        Spacer(minLength: 8)

                        Text(isExpanded ? "收起" : "展开查看")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.codexMuted)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.codexMuted)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // 快捷操作：刷新 & 复制全部
                HStack(spacing: 6) {
                    Divider()
                        .frame(height: 12)
                        .overlay(Color.codexLine.opacity(0.3))

                    Button {
                        Task {
                            await store.fetchV1Models()
                            onToast("已拉取 /v1/models 最新模型列表", "arrow.clockwise", true)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9.5))
                            .foregroundStyle(store.isV1ModelsLoading ? Color.accentColor : Color.codexMuted)
                            .rotationEffect(.degrees(store.isV1ModelsLoading ? 360 : 0))
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isV1ModelsLoading)
                    .help("重新请求网关 /v1/models 接口刷新列表")

                    Button {
                        let allIDs = store.v1Models.map(\.id).joined(separator: ", ")
                        guard !allIDs.isEmpty else {
                            onToast("暂无可复制的模型 ID", "exclamationmark.triangle", false)
                            return
                        }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(allIDs, forType: .string)
                        copiedAllIDs = true
                        onToast("已复制全部 /v1/models 模型 ID", "checkmark.circle.fill", true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            copiedAllIDs = false
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: copiedAllIDs ? "checkmark" : "doc.on.doc")
                            Text(copiedAllIDs ? "已复制" : "复制全部 ID")
                        }
                        .font(.system(size: 9.5, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(Color.codexMist, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .foregroundStyle(copiedAllIDs ? Color.green : Color.codexInk)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(Color.codexLine.opacity(0.3), lineWidth: 0.6)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("复制所有 /v1/models 接口导出的模型调用标识 (逗号分隔)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.codexBackground.opacity(0.65), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.codexLine.opacity(0.25), lineWidth: 0.8)
            )

            // 展开内容
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    // 搜索过滤栏与说明
                    HStack(spacing: 8) {
                        HStack(spacing: 5) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.codexMuted)
                            TextField("搜索模型 ID、提供方、账号...", text: $searchText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 10.5))
                            if !searchText.isEmpty {
                                Button {
                                    searchText = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.codexMuted)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.codexBackground.opacity(0.8), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(Color.codexLine.opacity(0.25), lineWidth: 0.6)
                        )

                        Spacer()

                        Text("此列表与 GET /v1/models 端点响应严格保持一致")
                            .font(.system(size: 9.5))
                            .foregroundStyle(Color.codexMuted)
                    }

                    // 表头
                    HStack(spacing: 8) {
                        Text("模型 ID (实际调用标识)")
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                        Text("所属供应商 / 账号来源")
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                        Text("额度 / 调度特性")
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                        Text("操作")
                            .frame(width: 76, alignment: .trailing)
                    }
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.codexMuted)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.codexMist.opacity(0.4), in: RoundedRectangle(cornerRadius: 5, style: .continuous))

                    // 模型清单滚动区
                    if displayModels.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: store.isV1ModelsLoading ? "arrow.triangle.2.circlepath" : "tray")
                                .font(.system(size: 14))
                                .foregroundStyle(Color.codexMuted)
                            Text(
                                store.isV1ModelsLoading
                                    ? "正在从 /v1/models 端点拉取最新模型..."
                                    : (searchText.isEmpty ? "当前 /v1/models 未返回模型数据（网关未运行或尚无就绪账号）" : "未匹配到相关模型")
                            )
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.codexMuted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 3) {
                                ForEach(displayModels) { model in
                                    let isCopied = copiedModelId == model.id
                                    HStack(spacing: 8) {
                                        // 1. 模型 ID
                                        HStack(spacing: 5) {
                                            Image(systemName: "cube.fill")
                                                .font(.system(size: 9))
                                                .foregroundStyle(Color(nsColor: model.providerColor))

                                            Text(model.id)
                                                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                                .foregroundStyle(Color.codexInk)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                        .help(model.id)

                                        // 2. 所属供应商 / 账号来源
                                        HStack(spacing: 4) {
                                            Text(model.effectiveProvider)
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundStyle(Color.codexInk)
                                                .lineLimit(1)

                                            if let acc = model.account, !acc.isEmpty {
                                                Text("(\(acc))")
                                                    .font(.system(size: 9.5))
                                                    .foregroundStyle(Color.codexMuted)
                                                    .lineLimit(1)
                                            }
                                        }
                                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                                        // 3. 额度 / 特性
                                        HStack(spacing: 4) {
                                            if let quota = model.quotaRemaining, !quota.isEmpty {
                                                Text(quota)
                                                    .font(.system(size: 9.5, weight: .medium))
                                                    .foregroundStyle(Color.green)
                                                    .lineLimit(1)
                                            } else if let tier = model.permissionTier, !tier.isEmpty {
                                                Text(tier)
                                                    .font(.system(size: 9.5))
                                                    .foregroundStyle(Color.codexMuted)
                                                    .lineLimit(1)
                                            } else {
                                                Text("可用")
                                                    .font(.system(size: 9.5))
                                                    .foregroundStyle(Color.green)
                                            }
                                        }
                                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                                        // 4. 操作按钮
                                        Button {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(model.id, forType: .string)
                                            copiedModelId = model.id
                                            onToast("已复制模型 ID: \(model.id)", "checkmark", true)
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                                if copiedModelId == model.id {
                                                    copiedModelId = nil
                                                }
                                            }
                                        } label: {
                                            HStack(spacing: 3) {
                                                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                                Text(isCopied ? "已复制" : "复制 ID")
                                            }
                                            .font(.system(size: 9.5, weight: .medium))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(isCopied ? Color.green.opacity(0.15) : Color.codexMist, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                            .foregroundStyle(isCopied ? Color.green : Color.codexInk)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                                    .stroke(isCopied ? Color.green.opacity(0.4) : Color.codexLine.opacity(0.2), lineWidth: 0.6)
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        .frame(width: 76, alignment: .trailing)
                                    }
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4.5)
                                    .background(Color.codexBackground.opacity(0.55), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                                }
                            }
                            .padding(.vertical, 1)
                        }
                        .frame(maxHeight: 250)
                    }

                    // 展开底部状态栏
                    HStack(spacing: 8) {
                        Text("共 \(displayModels.count) 款可用模型")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Color.codexMuted)

                        if let last = store.v1ModelsLastFetchedAt {
                            Text("· 同步时间: \(last.formatted(date: .omitted, time: .standard))")
                                .font(.system(size: 9.5))
                                .foregroundStyle(Color.codexMuted.opacity(0.7))
                        }

                        Spacer()

                        if let firstID = displayModels.first?.id {
                            Text("客户端请求样例: \"model\": \"\(firstID)\"")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(Color.codexMuted)
                                .lineLimit(1)
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.2), lineWidth: 0.8)
                )
            }
        }
    }
}
