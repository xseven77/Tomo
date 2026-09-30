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
    @State private var operatingApplication: GatewayAgentConnectTarget? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerBar

            if let msg = agentConfigMessage {
                agentAlertBanner(msg: msg)
            }

            CodexAgentCardView(
                store: store,
                configuringAgent: $configuringAgent,
                unconfiguringAgent: $unconfiguringAgent,
                agentConfigMessage: $agentConfigMessage,
                agentConfigSucceeded: $agentConfigSucceeded,
                operatingApplication: $operatingApplication
            )

            DSHAgentCardView(
                store: store,
                configuringAgent: $configuringAgent,
                unconfiguringAgent: $unconfiguringAgent,
                agentConfigMessage: $agentConfigMessage,
                agentConfigSucceeded: $agentConfigSucceeded
            )

            HermesAgentCardView(
                store: store,
                supervisor: supervisor,
                configuringAgent: $configuringAgent,
                unconfiguringAgent: $unconfiguringAgent,
                agentConfigMessage: $agentConfigMessage,
                agentConfigSucceeded: $agentConfigSucceeded,
                operatingApplication: $operatingApplication
            )

            PiAgentCardView(
                store: store,
                configuringAgent: $configuringAgent,
                unconfiguringAgent: $unconfiguringAgent,
                agentConfigMessage: $agentConfigMessage,
                agentConfigSucceeded: $agentConfigSucceeded,
                operatingApplication: $operatingApplication
            )

            ClineAgentCardView(
                store: store,
                configuringAgent: $configuringAgent,
                unconfiguringAgent: $unconfiguringAgent,
                agentConfigMessage: $agentConfigMessage,
                agentConfigSucceeded: $agentConfigSucceeded,
                operatingApplication: $operatingApplication
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

@MainActor
private struct AgentApplicationButtons: View {
    let target: GatewayAgentConnectTarget
    let application: AgentApplicationTarget
    @Binding var operatingApplication: GatewayAgentConnectTarget?
    @Binding var message: String?
    @Binding var succeeded: Bool
    var disabled: Bool
    @State private var restarting = false

    var body: some View {
        HStack(spacing: 8) {
            actionButton(restart: false)
            actionButton(restart: true)
        }
        .disabled(disabled || operatingApplication != nil)
    }

    private func actionButton(restart: Bool) -> some View {
        let isWorking = operatingApplication == target && restarting == restart
        return Button {
            guard !disabled, operatingApplication == nil else { return }
            restarting = restart
            operatingApplication = target
            message = nil
            Task {
                do {
                    try await AgentApplicationController().perform(application, restart: restart)
                    succeeded = true
                    let name = application == .pi ? "Pi 终端会话" : application.displayName
                    message = restart ? "已重启 \(name)" : "已打开 \(name)"
                } catch {
                    succeeded = false
                    message = "\(restart ? "重启" : "打开") \(application.displayName) 失败：\(error.localizedDescription)"
                }
                operatingApplication = nil
            }
        } label: {
            HStack(spacing: 4) {
                if isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: restart ? "arrow.clockwise" : "arrow.up.forward.app")
                        .font(.system(size: 10))
                }
                Text(isWorking ? (restart ? "重启中…" : "打开中…") : (restart ? "重启软件" : "打开软件"))
            }
            .font(.system(size: 10.5, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(Color.codexInk)
            .background(Color.codexMuted.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(restart
              ? (application == .pi ? "重启由 Tomo 打开的 Pi 终端会话" : "退出并重新打开软件，正在执行的任务会中断")
              : (application == .pi ? "在独立终端会话中打开 Pi" : "打开 \(application.displayName)"))
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
    @Binding var operatingApplication: GatewayAgentConnectTarget?
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
                VStack(alignment: .trailing, spacing: 6) {
                    actionButtons
                    AgentApplicationButtons(
                        target: .hermes, application: .hermes,
                        operatingApplication: $operatingApplication,
                        message: $agentConfigMessage, succeeded: $agentConfigSucceeded,
                        disabled: configuringAgent != nil || unconfiguringAgent != nil || operatingApplication != nil
                    )
                }
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
                    guard configuringAgent == nil && unconfiguringAgent == nil && operatingApplication == nil else { return }
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
                .disabled(configuringAgent != nil || unconfiguringAgent != nil || operatingApplication != nil)
            }

            Button {
                guard configuringAgent == nil && unconfiguringAgent == nil && operatingApplication == nil else { return }
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
            .disabled(configuringAgent != nil || unconfiguringAgent != nil || operatingApplication != nil)
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
    @Binding var operatingApplication: GatewayAgentConnectTarget?

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
                VStack(alignment: .trailing, spacing: 6) {
                    actionButtons
                    AgentApplicationButtons(
                        target: .pi, application: .pi,
                        operatingApplication: $operatingApplication,
                        message: $agentConfigMessage, succeeded: $agentConfigSucceeded,
                        disabled: configuringAgent != nil || unconfiguringAgent != nil || operatingApplication != nil
                    )
                }
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
                    guard configuringAgent == nil && unconfiguringAgent == nil && operatingApplication == nil else { return }
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
                .disabled(configuringAgent != nil || unconfiguringAgent != nil || operatingApplication != nil)
            }

            Button {
                guard configuringAgent == nil && unconfiguringAgent == nil && operatingApplication == nil else { return }
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
            .disabled(configuringAgent != nil || unconfiguringAgent != nil || operatingApplication != nil)
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

// MARK: - Codex Agent Card
private struct CodexAgentCardView: View {
    @Bindable var store: GatewayStore
    @Binding var configuringAgent: GatewayAgentConnectTarget?
    @Binding var unconfiguringAgent: GatewayAgentConnectTarget?
    @Binding var agentConfigMessage: String?
    @Binding var agentConfigSucceeded: Bool
    @Binding var operatingApplication: GatewayAgentConnectTarget?

    @State private var setAsDefaultProvider = true
    @State private var isRefreshingModels = false
    @State private var showingSessionResume = false

    private var isBusy: Bool {
        configuringAgent != nil || unconfiguringAgent != nil || operatingApplication != nil || isRefreshingModels
    }

    private var configuredModelCount: Int {
        store.v1Models.isEmpty ? store.allExportedModels.count : store.v1Models.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                BrandIconView(asset: .codex, size: 38, cornerRadius: 8)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("ChatGPT")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.codexInk)

                        statusBadge
                    }

                    Text("OpenAI 官方代码助手。一键将 Tomo Gateway 注册为本地自定义模型供应商（[model_providers.tomo]）。")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.codexMuted)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    actionButtons
                    AgentApplicationButtons(
                        target: .codex, application: .chatGPT,
                        operatingApplication: $operatingApplication,
                        message: $agentConfigMessage, succeeded: $agentConfigSucceeded,
                        disabled: isBusy
                    )
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 16) {
                    Label(
                        title: { Text("配置路径: ~/.codex/config.toml").font(.system(size: 10.5)) },
                        icon: { Image(systemName: "folder").font(.system(size: 10)) }
                    )
                    .foregroundStyle(Color.codexMuted)

                    Label(
                        title: { Text("通讯协议: OpenAI Responses 协议代理").font(.system(size: 10.5)) },
                        icon: { Image(systemName: "network").font(.system(size: 10)) }
                    )
                    .foregroundStyle(Color.codexMuted)
                }

                HStack(alignment: .center, spacing: 12) {
                    HStack(spacing: 6) {
                        Image(systemName: "cpu")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.codexInk)
                        Text("\(configuredModelCount) 个模型")
                            .font(.system(size: 9.5))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.codexMuted.opacity(0.12), in: Capsule())
                            .foregroundStyle(Color.codexMuted)
                    }

                    Spacer()

                    Button("继续已有会话") { showingSessionResume = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isBusy || !store.codexAgentInstalled)

                    Button {
                        guard !isBusy else { return }
                        isRefreshingModels = true
                        agentConfigMessage = nil
                        Task {
                            let res = await store.refreshCodexModels()
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
                    .disabled(isBusy || !store.codexAgentConfigured)

                }

                Text("刷新会更新 Gateway 模型清单。官方通道的已有会话需要重新加载供应商，单独切换模型不会切换通道，请使用“继续已有会话”。")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.codexMuted)
                    .lineSpacing(2)

                defaultProviderCheckbox
            }
        }
        .padding(14)
        .background(Color.codexCard)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.codexLine.opacity(0.35), lineWidth: 0.8)
        )
        .sheet(isPresented: $showingSessionResume) {
            CodexGatewaySessionResumeView(store: store)
        }
    }

    private var defaultProviderCheckbox: some View {
        Button {
            guard !isBusy else { return }
            setAsDefaultProvider.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: setAsDefaultProvider ? "checkmark.square.fill" : "square")
                    .font(.system(size: 10.5))
                    .foregroundStyle(setAsDefaultProvider ? Color.codexPrimary : Color.codexMuted)
                Text("同时将 Tomo 设为 ChatGPT 默认供应商（写入 model_provider = \"tomo\"）")
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
        } else if store.codexAgentConfigured {
            badge(store.codexIsTomoDefault ? "已接入 (默认)" : "已注册 Provider", tint: .green, weight: .semibold)
        } else if store.codexAgentInstalled {
            badge("已安装 / 未接入", tint: .blue, weight: .medium)
        } else {
            badge("未检测到 ~/.codex", tint: Color.codexMuted, weight: .regular)
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
            if store.codexAgentConfigured {
                Button {
                    guard !isBusy else { return }
                    unconfiguringAgent = .codex
                    agentConfigMessage = nil
                    Task {
                        let result = await store.unconfigureCodexAgent()
                        agentConfigSucceeded = result.success
                        agentConfigMessage = result.message
                        unconfiguringAgent = nil
                    }
                } label: {
                    HStack(spacing: 4) {
                        if unconfiguringAgent == .codex {
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
                configuringAgent = .codex
                agentConfigMessage = nil
                Task {
                    let res = await store.configureCodexAgent(setAsDefaultProvider: setAsDefaultProvider)
                    agentConfigSucceeded = res.success
                    agentConfigMessage = res.message
                    configuringAgent = nil
                }
            } label: {
                HStack(spacing: 4) {
                    if configuringAgent == .codex {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.codexOnPrimary)
                        Text("接入中…")
                    } else {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10))
                        Text(store.codexAgentConfigured ? "更新接入配置" : "一键接入 Gateway")
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .frame(minWidth: store.codexAgentConfigured ? 92 : 118)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.codexPrimary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .foregroundStyle(Color.codexOnPrimary)
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .opacity(configuringAgent != nil && configuringAgent != .codex ? 0.55 : 1)
        }
    }
}

@MainActor
private struct CodexGatewaySessionResumeView: View {
    @Bindable var store: GatewayStore
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [CodexGatewaySession] = []
    @State private var sessionID: String?
    @State private var model = ""
    @State private var search = ""
    @State private var loading = true
    @State private var working = false
    @State private var message: String?
    @State private var failed = false

    private var selectedSession: CodexGatewaySession? { sessions.first { $0.id == sessionID } }
    private var filteredSessions: [CodexGatewaySession] {
        guard !search.isEmpty else { return sessions }
        return sessions.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.id.contains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("通过 Gateway 继续已有会话").font(.headline)
            Text("保留原会话和历史。桌面端需要重启以加载 Gateway 供应商，打开后再从模型菜单选择 Gateway 模型。")
                .font(.callout).foregroundStyle(.secondary)

            TextField("搜索最近 100 个本地会话", text: $search)
                .textFieldStyle(.roundedBorder)
                .disabled(working)
            if loading {
                ProgressView("读取会话…").frame(maxWidth: .infinity)
            } else if sessions.isEmpty {
                Text("没有找到本地会话，请先在 ChatGPT 客户端创建会话。")
                    .foregroundStyle(.secondary)
            } else {
                List(filteredSessions, selection: $sessionID) { session in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.title).lineLimit(1)
                        Text("\(session.provider.isEmpty ? "未知供应商" : session.provider) · \(session.cwd)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .tag(session.id)
                }
                .frame(height: 200)
                .disabled(working)
            }

            Picker("Gateway 模型", selection: $model) {
                ForEach(store.codexCatalogModels(), id: \.slug) { item in
                    Text(item.displayName).tag(item.slug)
                }
            }
            .disabled(working || loading)

            Text("重启将退出整个 ChatGPT 客户端，请先结束或保存其他正在执行的任务。所选模型会设为 Gateway 默认模型，原会话仍需在菜单中选择。终端续接命令会明确指定供应商与模型，无需重启桌面端。")
                .font(.caption).foregroundStyle(.secondary)
            Text("如果旧会话含供应商专属的加密压缩历史，其他供应商可能无法读取；遇到该错误时需要使用原供应商或新建会话。")
                .font(.caption).foregroundStyle(.secondary)

            if let message {
                Text(message).font(.callout).foregroundStyle(failed ? Color.red : Color.codexInk)
                    .textSelection(.enabled)
            }

            HStack {
                Button("关闭") { dismiss() }.disabled(working)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("复制终端续接命令") { perform(restart: false) }
                    .disabled(working || selectedSession == nil || model.isEmpty || loading)
                Button("重启并打开原会话") { perform(restart: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || selectedSession == nil || model.isEmpty || loading)
            }
        }
        .padding(24)
        .frame(width: 660)
        .interactiveDismissDisabled(working)
        .task {
            do {
                sessions = try await store.loadCodexGatewaySessions()
                sessionID = sessions.first?.id
                model = store.codexCatalogModels().first?.slug ?? ""
            } catch {
                failed = true
                message = error.localizedDescription
            }
            loading = false
        }
    }

    private func perform(restart: Bool) {
        guard let session = selectedSession else { return }
        working = true
        message = nil
        Task {
            do {
                if restart {
                    try await store.reopenCodexGatewaySession(session: session, model: model)
                    message = "已重启并打开原会话，请在模型菜单中选择所需的 Gateway 模型。"
                } else {
                    let command = try await store.codexGatewayResumeCommand(session: session, model: model)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    message = "续接命令已复制，请粘贴到终端执行。命令使用原会话 ID，并明确指定 Gateway 供应商和所选模型。"
                }
                failed = false
            } catch {
                failed = true
                message = error.localizedDescription
            }
            working = false
        }
    }
}

// MARK: - Cline Agent Card
private struct ClineAgentCardView: View {
    @Bindable var store: GatewayStore
    @Binding var configuringAgent: GatewayAgentConnectTarget?
    @Binding var unconfiguringAgent: GatewayAgentConnectTarget?
    @Binding var agentConfigMessage: String?
    @Binding var agentConfigSucceeded: Bool
    @Binding var operatingApplication: GatewayAgentConnectTarget?

    private var isBusy: Bool {
        configuringAgent != nil || unconfiguringAgent != nil || operatingApplication != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                BrandIconView(asset: .cline, size: 38, cornerRadius: 8)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("Cline")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.codexInk)

                        statusBadge
                    }

                    Text("自主 AI 编码助手。一键将 Tomo 作为自定义模型 Provider 写入 Cline 桌面端与插件配置。")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.codexMuted)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    actionButtons
                    AgentApplicationButtons(
                        target: .cline, application: .cline,
                        operatingApplication: $operatingApplication,
                        message: $agentConfigMessage, succeeded: $agentConfigSucceeded,
                        disabled: isBusy
                    )
                }
            }

            Divider()

            HStack(spacing: 16) {
                Label(
                    title: { Text("配置路径: ~/.cline/data/settings/providers.json").font(.system(size: 10.5)) },
                    icon: { Image(systemName: "folder").font(.system(size: 10)) }
                )
                .foregroundStyle(Color.codexMuted)

                Label(
                    title: { Text("通讯协议: OpenAI Chat Completions 兼容协议").font(.system(size: 10.5)) },
                    icon: { Image(systemName: "network").font(.system(size: 10)) }
                )
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
            badge("正在检测…", tint: Color.codexMuted, weight: .regular)
        } else if store.clineAgentConfigured {
            badge("已接入 Gateway", tint: .green, weight: .semibold)
        } else if store.clineAgentInstalled {
            badge("已安装 / 未接入", tint: .blue, weight: .medium)
        } else {
            badge("未检测到 ~/.cline", tint: Color.codexMuted, weight: .regular)
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
            if store.clineAgentConfigured {
                Button {
                    guard !isBusy else { return }
                    unconfiguringAgent = .cline
                    agentConfigMessage = nil
                    Task {
                        let result = await store.unconfigureClineAgent()
                        agentConfigSucceeded = result.success
                        agentConfigMessage = result.message
                        unconfiguringAgent = nil
                    }
                } label: {
                    HStack(spacing: 4) {
                        if unconfiguringAgent == .cline {
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
                configuringAgent = .cline
                agentConfigMessage = nil
                Task {
                    let res = await store.configureClineAgent()
                    agentConfigSucceeded = res.success
                    agentConfigMessage = res.message
                    configuringAgent = nil
                }
            } label: {
                HStack(spacing: 4) {
                    if configuringAgent == .cline {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.codexOnPrimary)
                        Text("接入中…")
                    } else {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10))
                        Text(store.clineAgentConfigured ? "更新接入配置" : "一键接入 Gateway")
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .frame(minWidth: store.clineAgentConfigured ? 92 : 118)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.codexPrimary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .foregroundStyle(Color.codexOnPrimary)
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .opacity(configuringAgent != nil && configuringAgent != .cline ? 0.55 : 1)
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
