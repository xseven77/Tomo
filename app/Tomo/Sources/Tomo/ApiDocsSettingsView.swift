import SwiftUI
import AppKit

struct ApiDocsSettingsView: View {
    @State private var manager = ApiDocsManager.shared
    @State private var portText = ""
    @State private var inputError: String?
    var body: some View {
        SettingsSection(title: "桌面 API 文档", subtitle: "独立只读端口，查阅随应用打包的接口文档") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("端口")
                    TextField("58351", text: $portText).frame(width: 100).disabled(manager.isActive)
                    Toggle("允许局域网查阅", isOn: Binding(get: {manager.allowLAN}, set: {manager.allowLAN = $0})).disabled(manager.isActive)
                }
                Text("默认仅本机访问。此端口不提供业务 API，也不携带配对 Token。")
                    .font(.system(size: 11)).foregroundStyle(Color.codexMuted)
                HStack {
                    Button(manager.isActive ? "停止文档服务" : "启动文档服务") {
                        if manager.isActive {manager.stop(); return}
                        guard let value = UInt16(portText), value > 0 else {inputError = "请输入 1–65535 的端口。"; return}
                        inputError = nil; manager.port = value; manager.start()
                    }
                    Button("打开文档") {NSWorkspace.shared.open(manager.localURL)}.disabled(manager.status != .running)
                    Text(manager.localURL.absoluteString).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }
                if let url = manager.lanURL, manager.status == .running {
                    HStack {
                        Text("局域网：")
                        Text(url.absoluteString).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        Button("复制地址") {NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string)}
                    }
                }
                if let inputError {Text(inputError).foregroundStyle(.red)}
                switch manager.status {
                case .stopped: Text("已停止").foregroundStyle(Color.codexMuted)
                case .starting: Text("正在启动…").foregroundStyle(Color.codexMuted)
                case .running: Text(manager.allowLAN ? "已启动，局域网设备可通过这台 Mac 的 IP 查阅。" : "已启动，仅本机可查阅。")
                case .failed(let reason): Text(reason).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
        .onAppear {portText = String(manager.port)}
    }
}
