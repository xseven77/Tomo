import SwiftUI

struct DesktopCloudSettingsView: View {
    @State private var manager = DesktopCloudManager.shared
    @State private var issuer = ""
    @State private var email = ""
    @State private var code = ""
    @State private var serverName = Host.current().localizedName ?? "Tomo Desktop"

    var body: some View {
        SettingsSection(title: "TomoGo 云账号与服务器身份", subtitle: "登录云账号，将这台 Mac 登记为你的服务器") {
            SettingsUpdateCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        TextField("https://你的云服务域名", text: $issuer).textFieldStyle(.roundedBorder)
                            .disabled(manager.isConfigured || manager.isBusy)
                        Button("连接云服务") { Task { await manager.configure(issuer) } }
                            .disabled(manager.isConfigured || manager.isBusy || issuer.isEmpty)
                    }
                    if manager.isConfigured {
                        Text(manager.configuredURL).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        if let summary = manager.summary {
                            Text("已登录 · 用户 \(summary.userId.uuidString.lowercased())").font(.system(size: 11)).textSelection(.enabled)
                            Text("会话有效期：\(summary.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 11)).foregroundStyle(Color.codexMuted)
                            HStack {
                                TextField("服务器名称", text: $serverName).textFieldStyle(.roundedBorder).disabled(manager.isBusy)
                                Button(manager.server == nil ? "登记这台 Mac" : "更新服务器登记") { Task { await manager.register(name: serverName) } }
                                    .disabled(manager.isBusy || serverName.isEmpty)
                            }
                        } else {
                            HStack {
                                TextField("账号邮箱", text: $email).textFieldStyle(.roundedBorder).disabled(manager.isBusy)
                                Button("发送验证码") { Task { code = ""; await manager.sendCode(email: email) } }
                                    .disabled(manager.isBusy || email.isEmpty)
                            }
                            if manager.codeSent {
                                HStack {
                                    SecureField("六位邮件验证码", text: $code).textFieldStyle(.roundedBorder).disabled(manager.isBusy)
                                    Button("登录") { Task { let submitted = code; code = ""; await manager.signIn(code: submitted) } }
                                        .disabled(manager.isBusy || code.range(of: "^[0-9]{6}$", options: .regularExpression) == nil)
                                }
                            }
                        }
                        if let server = manager.server {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("已登记：\(server.name)").font(.system(size: 12, weight: .semibold))
                                Text("服务器 ID：\(server.id.uuidString.lowercased())")
                                Text("公钥摘要：\(server.keyThumbprint)")
                            }.font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        }
                        HStack {
                            Button("刷新登录状态") { Task { await manager.refresh() } }.disabled(manager.isBusy)
                            Button("退出登录") { Task { code = ""; await manager.logout() } }
                                .disabled(manager.operation == .signingOut)
                            Button("更换云服务") { Task { code = ""; await manager.logout(clearConfiguration: true); issuer = manager.configuredURL } }
                                .disabled(manager.operation == .signingOut)
                        }
                    }
                    if manager.isBusy { HStack { ProgressView().controlSize(.small); Text(operationText).font(.system(size: 11)) } }
                    if let message = manager.message { Text(message).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                    Text("服务器登记后，还需配置安全连接并在这台 Mac 上批准移动设备的会话权限。")
                        .font(.system(size: 11)).foregroundStyle(Color.codexMuted).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task { issuer = manager.configuredURL; await manager.restore() }
    }
    private var operationText: String {
        switch manager.operation {
        case .idle: ""
        case .restoring: "正在检查云会话…"
        case .sendingCode: "正在发送验证码…"
        case .signingIn: "正在登录…"
        case .registering: "正在登记服务器…"
        case .signingOut: "正在退出…"
        }
    }
}
