import SwiftUI
import AppKit

struct RemoteProductionSettingsView: View {
    @State private var manager = RemoteProductionManager.shared
    @State private var cloud = DesktopCloudManager.shared
    @State private var endpoint = ""
    @State private var certificate = ""
    @State private var root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
    var body: some View {
        SettingsSection(title: "TomoGo 安全会话服务", subtitle: "原生设备通过 HTTPS 和本机权限访问已注册的会话") {
            SettingsUpdateCard {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("HTTPS 地址，例如 https://你的Mac域名:58352", text: $endpoint).textFieldStyle(.roundedBorder)
                        .disabled(manager.isBusy || manager.status == .running)
                    HStack {
                        Picker("TLS 身份", selection: $certificate) {
                            Text("请选择证书").tag("")
                            ForEach(manager.choices) { Text($0.label).tag($0.id) }
                        }.disabled(manager.isBusy || manager.status == .running)
                        Button("读取 Keychain 证书") { Task { await manager.loadCertificates() } }
                            .disabled(manager.isBusy || manager.status == .running)
                    }
                    if let choice = manager.choices.first(where: { $0.id == certificate }) {
                        Text("证书 SHA-256：\(choice.fingerprint)").font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    }
                    HStack {
                        TextField("ChatGPT 会话目录", text: $root).textFieldStyle(.roundedBorder).disabled(manager.isBusy || manager.status == .running)
                        Button("选择目录") {
                            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
                            panel.begin { result in if result == .OK, let url = panel.url { root = url.path } }
                        }.disabled(manager.isBusy || manager.status == .running)
                    }
                    HStack {
                        Button("启动安全服务") { Task { await manager.start(endpoint: endpoint, certificateId: certificate, storageRoot: URL(fileURLWithPath: (root as NSString).expandingTildeInPath)) } }
                            .disabled(manager.isBusy || manager.status == .running || cloud.isBusy || cloud.server == nil || endpoint.isEmpty || certificate.isEmpty)
                        Button("停止服务") { Task { await manager.stop() } }.disabled(manager.status == .stopped || manager.status == .stopping)
                        Text(statusText).font(.system(size: 11))
                    }
                    if let url = manager.endpoint, manager.status == .running {
                        Text(url.absoluteString).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                    if let message = manager.message { Text(message).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                    Text("先登录并登记这台 Mac，再选择对应域名的 TLS 证书。当前目录提供会话与历史读取；移动设备的权限还需在本机批准。")
                        .font(.system(size: 11)).foregroundStyle(Color.codexMuted).fixedSize(horizontal: false, vertical: true)
                    if manager.status == .running { RemoteOwnerSettingsView() }
                }
            }
        }
    }
    private var statusText: String {
        switch manager.status {
        case .stopped: "已停止"
        case .loadingCertificates: "正在读取证书…"
        case .starting: "正在启动…"
        case .running: "已启动"
        case .stopping: "正在停止…"
        case .failed: "启动或运行失败"
        }
    }
}
