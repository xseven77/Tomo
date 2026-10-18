import SwiftUI
import AppKit

struct RemoteProductionSettingsView: View {
    @State private var manager = RemoteProductionManager.shared
    @State private var cloud = DesktopCloudManager.shared
    @State private var endpoint = ""
    @State private var certificate = ""
    @State private var includeInteraction = false
    @State private var copyingConfiguration = false
    @State private var configurationMessage: String?
    @State private var root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
    @State private var authorization: RemoteProductionManager.AuthorizationMode = .local
    private var usesTLS: Bool { URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme != "http" }
    var body: some View {
        SettingsSection(title: "TomoGo 会话服务", subtitle: "原生设备通过 HTTP / HTTPS 和本机权限访问已注册的会话") {
            SettingsUpdateCard {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("设备授权方式", selection: $authorization) {
                        Text("本机批准").tag(RemoteProductionManager.AuthorizationMode.local)
                        Text("云账号与本机批准").tag(RemoteProductionManager.AuthorizationMode.cloud)
                    }.disabled(manager.isBusy || manager.status == .running)
                    TextField("会话服务地址（HTTP / HTTPS）", text: $endpoint).textFieldStyle(.roundedBorder)
                        .disabled(manager.isBusy || manager.status == .running)
                    if usesTLS { HStack {
                        Picker("TLS 身份", selection: $certificate) {
                            Text("请选择证书").tag("")
                            ForEach(manager.choices) { Text($0.label).tag($0.id) }
                        }.disabled(manager.isBusy || manager.status == .running)
                        Button("读取 Keychain 证书") { Task { await manager.loadCertificates() } }
                            .disabled(manager.isBusy || manager.status == .running)
                    } }
                    if usesTLS, let choice = manager.choices.first(where: { $0.id == certificate }) {
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
                        Button("启动会话服务") { Task { await manager.start(endpoint: endpoint, certificateId: certificate,
                            storageRoot: URL(fileURLWithPath: (root as NSString).expandingTildeInPath), mode: authorization) } }
                            .disabled(manager.isBusy || manager.status == .running || (authorization == .cloud && (cloud.isBusy || cloud.server == nil)) || endpoint.isEmpty || (usesTLS && certificate.isEmpty))
                        Button("停止服务") { Task { await manager.stop() } }.disabled(manager.status == .stopped || manager.status == .stopping)
                        Text(statusText).font(.system(size: 11))
                    }
                    if let url = manager.endpoint, manager.status == .running {
                        Text(url.absoluteString).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                    if let message = manager.message { Text(message).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                    Text(authorization == .local
                        ? "本机批准模式无需云账号。复制配置后，在这台 Mac 上核对设备公钥并批准所选会话权限。"
                        : "云账号模式需登录并登记这台 Mac；设备的会话权限仍需在本机批准。")
                        .font(.system(size: 11)).foregroundStyle(Color.codexMuted).fixedSize(horizontal: false, vertical: true)
                    if usesTLS { Text("HTTPS 使用对应域名的 TLS 证书并进行系统验证。")
                        .font(.system(size: 11)).foregroundStyle(Color.codexMuted) }
                    if manager.status == .running {
                        Toggle("配置中包含可用的会话交互", isOn: $includeInteraction).disabled(copyingConfiguration)
                        HStack {
                            Button(copyingConfiguration ? "正在读取配置…" : "复制 TomoGo 会话配置") {
                                copyingConfiguration = true; configurationMessage = nil
                                Task {
                                    defer { copyingConfiguration = false }
                                    do {
                                        let text = try await manager.mobileHostConfiguration(includeInteraction: includeInteraction)
                                        NSPasteboard.general.clearContents()
                                        configurationMessage = NSPasteboard.general.setString(text, forType: .string)
                                            ? "已复制。在 TomoGo 的服务器信息页粘贴并确认，再申请会话访问。" : "复制失败，请重试。"
                                    } catch { configurationMessage = "无法读取当前服务配置，请确认安全服务和会话目录可用。" }
                                }
                            }.disabled(copyingConfiguration || manager.ownerBusy)
                        }
                        Text("配置包含服务地址与请求范围；实际访问权限仍需在这台 Mac 上逐台批准。")
                            .font(.system(size: 11)).foregroundStyle(Color.codexMuted)
                        if let configurationMessage { Text(configurationMessage).font(.system(size: 11)).textSelection(.enabled) }
                        RemoteOwnerSettingsView()
                    }
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
