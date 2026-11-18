import SwiftUI
import AppKit

struct ApiDocsSettingsView: View {
    @State private var manager = ApiDocsManager.shared
    @State private var portText = ""
    @State private var inputError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection(title: "文档服务", subtitle: "在浏览器中查阅随 Tomo 提供的接口文档") {
                VStack(spacing: 0) {
                    SettingsInlineRow(title: "运行状态", subtitle: statusText) {
                        Button {
                            if manager.isActive { manager.stop() } else { start() }
                        } label: {
                            SettingsSecondaryActionLabel(title: manager.isActive ? "停止服务" : "启动服务",
                                                         systemImage: manager.isActive ? "stop" : "play")
                        }
                        .buttonStyle(CodexPressableStyle(cornerRadius: 7))
                    }
                    CodexDivider()
                    SettingsInlineRow(title: "本机地址", subtitle: manager.localURL.absoluteString) {
                        Button { NSWorkspace.shared.open(manager.localURL) } label: {
                            SettingsSecondaryActionLabel(title: "打开文档", systemImage: "arrow.up.right")
                        }
                        .buttonStyle(CodexPressableStyle(cornerRadius: 7))
                        .disabled(manager.status != .running)
                    }
                    if manager.status == .running, let address = manager.lanURL {
                        CodexDivider()
                        SettingsInlineRow(title: "局域网地址", subtitle: address.absoluteString) {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(address.absoluteString, forType: .string)
                            } label: {
                                SettingsSecondaryActionLabel(title: "复制地址", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(CodexPressableStyle(cornerRadius: 7))
                        }
                    }
                }
                .settingsGroupSurface()
            }

            SettingsSection(title: "访问设置", subtitle: "文档使用独立的只读端口。停止服务后可修改设置。") {
                VStack(spacing: 0) {
                    SettingsInlineRow(title: "端口", subtitle: inputError ?? "可用范围为 1–65535") {
                        TextField("端口", text: $portText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 84)
                            .onChange(of: portText) { _, _ in inputError = nil }
                    }
                    CodexDivider()
                    SettingsInlineRow(title: "允许局域网查阅", subtitle: "允许同一网络的设备访问文档") {
                        Toggle("允许局域网查阅", isOn: Binding(get: { manager.allowLAN }, set: { manager.allowLAN = $0 }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
                .disabled(manager.isActive)
                .settingsGroupSurface()
            }
        }
        .onAppear { portText = String(manager.port) }
    }

    private var statusText: String {
        switch manager.status {
        case .stopped: "已停止"
        case .starting: "正在启动…"
        case .running: manager.allowLAN ? "运行中 · 本机和局域网可访问" : "运行中 · 仅本机可访问"
        case .failed(let reason): reason
        }
    }

    private func start() {
        guard let value = UInt16(portText), value > 0 else {
            inputError = "请输入 1–65535 的端口"
            return
        }
        manager.port = value
        manager.start()
    }
}
