import AppKit
import SwiftUI

@MainActor
struct GatewayAgentsView: View {
    @Bindable var store: GatewayStore
    var supervisor: GatewaySupervisor = .shared
    var settingsStore: MultiAgentSettingsStore? = nil
    var onToast: GatewayToastHandler? = nil

    @State private var agentConfigMessage: String? = nil
    @State private var agentConfigSucceeded = true
    @State private var configuringAgent: GatewayAgentConnectTarget? = nil
    @State private var unconfiguringAgent: GatewayAgentConnectTarget? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerBar

            if let msg = agentConfigMessage {
                agentAlertBanner(msg: msg)
            }

            HermesAgentCardView(
                store: store,
                supervisor: supervisor,
                configuringAgent: $configuringAgent,
                unconfiguringAgent: $unconfiguringAgent,
                agentConfigMessage: $agentConfigMessage,
                agentConfigSucceeded: $agentConfigSucceeded
            )

            PiAgentCardView(
                store: store,
                configuringAgent: $configuringAgent,
                unconfiguringAgent: $unconfiguringAgent,
                agentConfigMessage: $agentConfigMessage,
                agentConfigSucceeded: $agentConfigSucceeded
            )

            DSHAgentCardView(
                store: store,
                configuringAgent: $configuringAgent,
                unconfiguringAgent: $unconfiguringAgent,
                agentConfigMessage: $agentConfigMessage,
                agentConfigSucceeded: $agentConfigSucceeded
            )

            GenericAgentCardsView(
                supervisor: supervisor,
                agentConfigMessage: $agentConfigMessage
            )
        }
        .task {
            await store.refreshAgentIntegrationStatus()
        }
    }

    private var headerBar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("本地 Agent 接入与快速检测")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.codexInk)
                Text("一键将 Tomo 作为模型 Provider 接入本地 Coding Agent。安装新 CLI 后可点击右侧重新检测即时全局同步。")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.codexMuted)
            }

            Spacer()

            Button {
                guard !store.isRefreshingAgentIntegrationStatus else { return }
                Task {
                    await store.refreshAgentIntegrationStatus()
                    settingsStore?.refresh()
                    onToast?("已刷新本地 Agent 检测状态", "arrow.clockwise", true)
                }
            } label: {
                HStack(spacing: 5) {
                    if store.isRefreshingAgentIntegrationStatus {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                    }
                    Text(store.isRefreshingAgentIntegrationStatus ? "正在检测…" : "重新检测")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.codexMuted.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .foregroundStyle(Color.codexInk)
            }
            .buttonStyle(.plain)
            .disabled(store.isRefreshingAgentIntegrationStatus)
        }
        .padding(.horizontal, 2)
    }

    private func agentAlertBanner(msg: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: agentConfigSucceeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(agentConfigSucceeded ? Color.green : Color.red)
            Text(msg)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.codexInk)
            Spacer()
            Button {
                agentConfigMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.codexMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background((agentConfigSucceeded ? Color.green : Color.red).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Hermes Agent Card
@MainActor
private struct HermesAgentCardView: View {
    @Bindable var store: GatewayStore
    var supervisor: GatewaySupervisor
    @Binding var configuringAgent: GatewayAgentConnectTarget?
    @Binding var unconfiguringAgent: GatewayAgentConnectTarget?
    @Binding var agentConfigMessage: String?
    @Binding var agentConfigSucceeded: Bool
    @State private var isBypassOperating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                BrandIconView(asset: .hermesAgent, size: 34, cornerRadius: 8)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("Hermes Agent")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.codexInk)
                        statusBadge
                    }
                    Text("自主 Coding Agent，支持 Hooks 监控、网页端与 CLI TUI 交互")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.codexMuted)
                }
                Spacer()
                actionButtons
            }

            CodexDivider(.horizontal)

            VStack(alignment: .leading, spacing: 6) {
                Text("接入配置参数")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.codexInk)
                VStack(alignment: .leading, spacing: 4) {
                    if let path = store.hermesExecutablePath {
                        HStack {
                            Text("CLI 路径:")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Color.codexMuted)
                                .frame(width: 80, alignment: .leading)
                            Text(path)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Color.codexInk)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    HStack {
                        Text("Provider:")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Color.codexMuted)
                            .frame(width: 80, alignment: .leading)
                        Text("Tomo")
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.codexInk)
                    }
                    HStack {
                        Text("Base URL:")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Color.codexMuted)
                            .frame(width: 80, alignment: .leading)
                        Text("http://127.0.0.1:\(String(supervisor.port))/v1")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Color.codexInk)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.codexBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            CodexDivider(.horizontal)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center) {
                    HStack(spacing: 6) {
                        Text("局域网直连白名单")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.codexInk)

                        if store.hermesLanBypassConfigured {
                            Text("已开启 NO_PROXY")
                                .font(.system(size: 9.5, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color.green.opacity(0.12), in: Capsule())
                                .foregroundStyle(.green)
                        } else {
                            Text("未配置")
                                .font(.system(size: 9.5))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color.codexMuted.opacity(0.12), in: Capsule())
                                .foregroundStyle(Color.codexMuted)
                        }
                    }

                    Spacer()

                    if store.hermesLanBypassConfigured {
                        Button {
                            guard !isBypassOperating else { return }
                            isBypassOperating = true
                            Task {
                                let res = await store.unconfigureHermesLanBypass()
                                agentConfigSucceeded = res.success
                                agentConfigMessage = res.message
                                isBypassOperating = false
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if isBypassOperating {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "trash")
                                        .font(.system(size: 9.5))
                                }
                                Text("一键删除白名单")
                            }
                            .font(.system(size: 10.5, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .foregroundStyle(Color.red.opacity(0.9))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color.red.opacity(0.2), lineWidth: 0.8)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isBypassOperating)
                    } else {
                        Button {
                            guard !isBypassOperating else { return }
                            isBypassOperating = true
                            Task {
                                let res = await store.configureHermesLanBypass()
                                agentConfigSucceeded = res.success
                                agentConfigMessage = res.message
                                isBypassOperating = false
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if isBypassOperating {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "shield.checkered")
                                        .font(.system(size: 9.5))
                                }
                                Text("一键配置直连白名单")
                            }
                            .font(.system(size: 10.5, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.codexPrimary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .foregroundStyle(Color.codexOnPrimary)
                        }
                        .buttonStyle(.plain)
                        .disabled(isBypassOperating)
                    }
                }

                Text("自动写入 ~/.hermes/.env（NO_PROXY=127.0.0.1,localhost,192.168.0.0/16,10.0.0.0/8），防止 Clash 等网络代理拦截局域网访问导致超时。")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.codexMuted)
                    .lineSpacing(2)
            }
        }
        .padding(14)
        .background(Color.codexCard)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.8)
        )
    }

    @ViewBuilder
    private var statusBadge: some View {
        if !store.hasLoadedAgentIntegrationStatus || store.isRefreshingAgentIntegrationStatus {
            Text("正在检测…")
                .font(.system(size: 9.5))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Color.codexMuted.opacity(0.12), in: Capsule())
                .foregroundStyle(Color.codexMuted)
        } else if store.hermesAgentConfigured {
            Text("已接入 Gateway")
                .font(.system(size: 9.5, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Color.green.opacity(0.12), in: Capsule())
                .foregroundStyle(.green)
        } else if store.hermesAgentInstalled {
            Text("已安装 / 未接入")
                .font(.system(size: 9.5, weight: .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Color.blue.opacity(0.12), in: Capsule())
                .foregroundStyle(.blue)
        } else {
            Text("未检测到 CLI")
                .font(.system(size: 9.5))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Color.codexMuted.opacity(0.12), in: Capsule())
                .foregroundStyle(Color.codexMuted)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            if store.hermesAgentConfigured {
                Button {
                    guard configuringAgent == nil && unconfiguringAgent == nil else { return }
                    unconfiguringAgent = .hermes
                    agentConfigMessage = nil
                    Task {
                        let result = await store.unconfigureHermesAgent()
                        agentConfigSucceeded = result.success
                        agentConfigMessage = result.message
                        unconfiguringAgent = nil
                    }
                } label: {
                    HStack(spacing: 4) {
                        if unconfiguringAgent == .hermes {
                            ProgressView().controlSize(.small)
                            Text("移除中…")
                        } else {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                            Text("移除")
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .foregroundStyle(Color.red.opacity(0.9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.red.opacity(0.25), lineWidth: 0.8)
                    }
                }
                .buttonStyle(.plain)
                .disabled(configuringAgent != nil || unconfiguringAgent != nil)
            }

            Button {
                guard configuringAgent == nil && unconfiguringAgent == nil else { return }
                configuringAgent = .hermes
                agentConfigMessage = nil
                Task {
                    let res = await store.configureHermesAgent()
                    agentConfigSucceeded = res.success
                    agentConfigMessage = res.message
                    configuringAgent = nil
                }
            } label: {
                HStack(spacing: 4) {
                    if configuringAgent == .hermes {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.codexOnPrimary)
                        Text("接入中…")
                    } else {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10))
                        Text(store.hermesAgentConfigured ? "更新接入配置" : "一键接入 Gateway")
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .frame(minWidth: store.hermesAgentConfigured ? 92 : 118)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.codexPrimary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .foregroundStyle(Color.codexOnPrimary)
            }
            .buttonStyle(.plain)
            .disabled(configuringAgent != nil || unconfiguringAgent != nil)
            .opacity(configuringAgent != nil && configuringAgent != .hermes ? 0.55 : 1)
        }
    }
}

// MARK: - Pi Agent Card
@MainActor
private struct PiAgentCardView: View {
    @Bindable var store: GatewayStore
    @Binding var configuringAgent: GatewayAgentConnectTarget?
    @Binding var unconfiguringAgent: GatewayAgentConnectTarget?
    @Binding var agentConfigMessage: String?
    @Binding var agentConfigSucceeded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                BrandIconView(asset: .piAgent, size: 34, cornerRadius: 8)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("Pi Agent")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.codexInk)
                        statusBadge
                    }
                    Text("极简轻量级终端 Coding Agent，支持流式交互与多模型热切")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.codexMuted)
                }
                Spacer()
                actionButtons
            }

            CodexDivider(.horizontal)

            VStack(alignment: .leading, spacing: 6) {
                if let path = store.piExecutablePath {
                    HStack {
                        Text("CLI 路径:")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Color.codexMuted)
                            .frame(width: 80, alignment: .leading)
                        Text(path)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Color.codexInk)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.codexBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                Text("模型注册: ~/.pi/agent/models.json · 默认模型: ~/.pi/agent/settings.json")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.codexMuted)
            }
        }
        .padding(14)
        .background(Color.codexCard)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.8)
        )
    }

    @ViewBuilder
    private var statusBadge: some View {
        if !store.hasLoadedAgentIntegrationStatus || store.isRefreshingAgentIntegrationStatus {
            Text("正在检测…")
                .font(.system(size: 9.5))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Color.codexMuted.opacity(0.12), in: Capsule())
                .foregroundStyle(Color.codexMuted)
        } else if store.piAgentConfigured {
            Text("已接入 Gateway")
                .font(.system(size: 9.5, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Color.green.opacity(0.12), in: Capsule())
                .foregroundStyle(.green)
        } else if store.piAgentInstalled {
            Text("已安装 / 未接入")
                .font(.system(size: 9.5, weight: .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Color.blue.opacity(0.12), in: Capsule())
                .foregroundStyle(.blue)
        } else {
            Text("未检测到 CLI")
                .font(.system(size: 9.5))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Color.codexMuted.opacity(0.12), in: Capsule())
                .foregroundStyle(Color.codexMuted)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            if store.piAgentConfigured {
                Button {
                    guard configuringAgent == nil && unconfiguringAgent == nil else { return }
                    unconfiguringAgent = .pi
                    agentConfigMessage = nil
                    Task {
                        let result = await store.unconfigurePiAgent()
                        agentConfigSucceeded = result.success
                        agentConfigMessage = result.message
                        unconfiguringAgent = nil
                    }
                } label: {
                    HStack(spacing: 4) {
                        if unconfiguringAgent == .pi {
                            ProgressView().controlSize(.small)
                            Text("移除中…")
                        } else {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                            Text("移除")
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .foregroundStyle(Color.red.opacity(0.9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.red.opacity(0.25), lineWidth: 0.8)
                    }
                }
                .buttonStyle(.plain)
                .disabled(configuringAgent != nil || unconfiguringAgent != nil)
            }

            Button {
                guard configuringAgent == nil && unconfiguringAgent == nil else { return }
                configuringAgent = .pi
                agentConfigMessage = nil
                Task {
                    let res = await store.configurePiAgent()
                    agentConfigSucceeded = res.success
                    agentConfigMessage = res.message
                    configuringAgent = nil
                }
            } label: {
                HStack(spacing: 4) {
                    if configuringAgent == .pi {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.codexOnPrimary)
                        Text("接入中…")
                    } else {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10))
                        Text(store.piAgentConfigured ? "更新接入配置" : "一键接入 Gateway")
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .frame(minWidth: store.piAgentConfigured ? 92 : 118)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.codexPrimary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .foregroundStyle(Color.codexOnPrimary)
            }
            .buttonStyle(.plain)
            .disabled(configuringAgent != nil || unconfiguringAgent != nil)
            .opacity(configuringAgent != nil && configuringAgent != .pi ? 0.55 : 1)
        }
    }
}

// MARK: - DSH (DeepSeek Harness) Card
@MainActor
private struct DSHAgentCardView: View {
    @Bindable var store: GatewayStore
    @Binding var configuringAgent: GatewayAgentConnectTarget?
    @Binding var unconfiguringAgent: GatewayAgentConnectTarget?
    @Binding var agentConfigMessage: String?
    @Binding var agentConfigSucceeded: Bool

    @State private var isRefreshingModels = false
    @State private var setAsDefaultModel = false

    private var isBusy: Bool {
        configuringAgent != nil || unconfiguringAgent != nil || isRefreshingModels
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                BrandIconView(asset: .deepSeek, size: 34, cornerRadius: 8)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("DSH (DeepSeek Harness)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.codexInk)
                        statusBadge
                    }
                    Text("通过内置 llm-pi-ai 适配器以 OpenAI 兼容协议接入，支持工具调用与流式交互")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.codexMuted)
                }
                Spacer()
                actionButtons
            }

            CodexDivider(.horizontal)

            VStack(alignment: .leading, spacing: 6) {
                Text("接入配置参数")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.codexInk)
                VStack(alignment: .leading, spacing: 4) {
                    parameterRow(label: "路由", value: "tomo")
                    parameterRow(label: "Base URL", value: "http://127.0.0.1:\(String(GatewaySupervisor.shared.port))/v1")
                    parameterRow(label: "设置文档", value: store.dshSettingsPath)
                    parameterRow(label: "凭据文档", value: store.dshCredentialsPath)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.codexBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            CodexDivider(.horizontal)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center) {
                    HStack(spacing: 6) {
                        Text("模型列表")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.codexInk)
                        Text("\(configuredModelCount) 个模型")
                            .font(.system(size: 9.5))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.codexMuted.opacity(0.12), in: Capsule())
                            .foregroundStyle(Color.codexMuted)
                    }

                    Spacer()

                    Button {
                        guard !isBusy else { return }
                        isRefreshingModels = true
                        agentConfigMessage = nil
                        Task {
                            let res = await store.refreshDSHModels()
                            agentConfigSucceeded = res.success
                            agentConfigMessage = res.message
                            isRefreshingModels = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if isRefreshingModels {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 9.5))
                            }
                            Text("刷新模型列表")
                        }
                        .font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.codexMuted.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .foregroundStyle(Color.codexInk)
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy || !store.dshAgentConfigured)
                }

                Text("刷新会就地重写 tomo 路由的模型清单：下架的模型随之移除、新模型随即出现，整个替换在单次原子写入内完成，不存在「先移除再接入」的空窗期。")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.codexMuted)
                    .lineSpacing(2)

                if store.dshCredentialShadowed {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.orange)
                        Text("检测到进程环境变量 TOMO_GATEWAY_TOKEN，DSH 会优先生效该值，从而遮蔽此处写入的令牌。请取消该环境变量后重新接入。")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.orange)
                            .lineSpacing(2)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                defaultModelToggle
            }
        }
        .padding(14)
        .background(Color.codexCard)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.8)
        )
    }

    private var configuredModelCount: Int {
        store.dshAgentConfigured ? store.dshAvailableModelCount : 0
    }

    private func parameterRow(label: String, value: String) -> some View {
        HStack {
            Text("\(label):")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Color.codexMuted)
                .frame(width: 66, alignment: .leading)
            Text(value)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Color.codexInk)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var defaultModelToggle: some View {
        Button {
            setAsDefaultModel.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: setAsDefaultModel ? "checkmark.square.fill" : "square")
                    .font(.system(size: 10.5))
                    .foregroundStyle(setAsDefaultModel ? Color.codexPrimary : Color.codexMuted)
                Text("同时将 Tomo 设为 DSH 默认模型（写入 agent-default-model）")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.codexInk)
            }
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if !store.hasLoadedAgentIntegrationStatus || store.isRefreshingAgentIntegrationStatus {
            badge("正在检测…", tint: Color.codexMuted, weight: .regular)
        } else if store.dshAgentConfigured {
            badge("已接入 Gateway", tint: .green, weight: .semibold)
        } else if store.dshAgentInstalled {
            badge("已安装 / 未接入", tint: .blue, weight: .medium)
        } else {
            badge("未检测到 ~/.dsh", tint: Color.codexMuted, weight: .regular)
        }
    }

    private func badge(_ text: String, tint: Color, weight: Font.Weight) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: weight))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            if store.dshAgentConfigured {
                Button {
                    guard !isBusy else { return }
                    unconfiguringAgent = .dsh
                    agentConfigMessage = nil
                    Task {
                        let result = await store.unconfigureDSHAgent()
                        agentConfigSucceeded = result.success
                        agentConfigMessage = result.message
                        unconfiguringAgent = nil
                    }
                } label: {
                    HStack(spacing: 4) {
                        if unconfiguringAgent == .dsh {
                            ProgressView().controlSize(.small)
                            Text("移除中…")
                        } else {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                            Text("移除")
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .foregroundStyle(Color.red.opacity(0.9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.red.opacity(0.25), lineWidth: 0.8)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
            }

            Button {
                guard !isBusy else { return }
                configuringAgent = .dsh
                agentConfigMessage = nil
                Task {
                    let res = await store.configureDSHAgent(setAsDefaultModel: setAsDefaultModel)
                    agentConfigSucceeded = res.success
                    agentConfigMessage = res.message
                    configuringAgent = nil
                }
            } label: {
                HStack(spacing: 4) {
                    if configuringAgent == .dsh {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.codexOnPrimary)
                        Text("接入中…")
                    } else {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10))
                        Text(store.dshAgentConfigured ? "更新接入配置" : "一键接入 Gateway")
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .frame(minWidth: store.dshAgentConfigured ? 92 : 118)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.codexPrimary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .foregroundStyle(Color.codexOnPrimary)
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .opacity(configuringAgent != nil && configuringAgent != .dsh ? 0.55 : 1)
        }
    }
}

// MARK: - Generic Agents Environment Variables Card
@MainActor
private struct GenericAgentCardsView: View {
    var supervisor: GatewaySupervisor
    @Binding var agentConfigMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("通用 Agent / Cursor / Cline 环境变量")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.codexInk)

            HStack {
                Text("export OPENAI_BASE_URL=http://127.0.0.1:\(String(supervisor.port))/v1\nexport OPENAI_API_KEY=\(supervisor.localToken)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.codexInk)
                    .lineSpacing(4)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("export OPENAI_BASE_URL=http://127.0.0.1:\(supervisor.port)/v1\nexport OPENAI_API_KEY=\(supervisor.localToken)", forType: .string)
                    agentConfigMessage = "已复制通用环境变量！可在任何终端直接贴入生效。"
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                        Text("复制")
                    }
                    .font(.system(size: 10.5))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.codexCard)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(10)
            .background(Color.codexBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(14)
        .background(Color.codexCard)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.8)
        )
    }
}
