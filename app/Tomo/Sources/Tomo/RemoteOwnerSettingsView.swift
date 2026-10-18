import SwiftUI
import AppKit

struct RemoteOwnerSettingsView: View {
    @State private var manager = RemoteProductionManager.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("移动设备授权").font(.headline)
                Spacer()
                Button("刷新") { Task { await manager.refreshOwnerState() } }.disabled(manager.ownerBusy)
            }
            if let message = manager.ownerMessage { Text(message).foregroundStyle(.red).font(.caption) }
            if let state = manager.ownerState {
                RemoteOwnedRuntimeSettingsView(state: state)
                if state.pending.isEmpty { Text("暂无待批准的配对请求").foregroundStyle(.secondary).font(.caption) }
                ForEach(state.pending, id: \.id) { pending in
                    RemotePendingDeviceView(pending: pending, runtimes: state.runtimes, lease: state.lease,
                        version: state.bindings.first { $0.userId == pending.userId && $0.deviceId == pending.deviceId }?.localVersion ?? 0)
                }
                ForEach(Array(state.bindings.enumerated()), id: \.offset) { _, binding in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("设备：\(binding.deviceId)").font(.caption).textSelection(.enabled)
                        Text("用户：\(binding.userId)").font(.caption).textSelection(.enabled)
                        Text("\(binding.revoked ? "已撤销" : "已批准") · 本机版本 \(binding.localVersion) · \(binding.scopes.joined(separator: ", "))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("公钥：\(binding.thumbprint)").font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        if !binding.revoked {
                            Button("撤销此设备", role: .destructive) {
                                Task { await manager.revokeDevice(userId: binding.userId, deviceId: binding.deviceId, expectedVersion: binding.localVersion, lease: state.lease) }
                            }.disabled(manager.ownerBusy)
                        }
                    }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            Text("仅在本机批准所选会话资源。发送与控制权限不会自动授予；撤销后现有授权失效，重新配对需要新的绑定版本。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task {
            while !Task.isCancelled {
                await manager.refreshOwnerState()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
}

private struct RemoteOwnedRuntimeSettingsView: View {
    let state: RemoteProductionService.OwnerState
    @State private var manager = RemoteProductionManager.shared
    @State private var selected = ""
    @State private var executable = ""
    @State private var workspace = ""
    @State private var sourceRuntimeId = ""
    @State private var allowSteer = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("本机受控会话").font(.headline)
            HStack {
                TextField("ChatGPT CLI 可执行文件", text: $executable).textFieldStyle(.roundedBorder)
                Button("选择程序") {
                    let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                    panel.begin { result in if result == .OK, let url = panel.url { executable = url.path } }
                }
            }
            Picker("本机会话", selection: $selected) {
                Text("请选择要接管的会话").tag("")
                ForEach(state.ownedChoices) { Text($0.title).tag($0.id) }
            }
            Toggle("允许向活动回合追加消息", isOn: $allowSteer)
            Text("接管会启动专属进程并恢复所选任务；只接管选定会话。空闲会话不会自动开始新回合，手机仍需单独批准对应 runtime 权限。")
                .font(.caption).foregroundStyle(.secondary)
            Button("接管所选会话") {
                guard let choice = state.ownedChoices.first(where: { $0.id == selected }) else { return }
                let url = URL(fileURLWithPath: (executable as NSString).expandingTildeInPath)
                Task { await manager.attachOwnedChatGPT(sourceRuntimeId: choice.sourceRuntimeId, sessionId: choice.sessionId, executable: url, allowSteer: allowSteer, lease: state.lease) }
            }.disabled(executable.isEmpty || !state.ownedChoices.contains(where: { $0.id == selected }))
            HStack {
                Picker("新会话账号", selection: $sourceRuntimeId) {
                    Text("选择已登记账号").tag("")
                    ForEach(state.ownedAccounts) { account in
                        Text(account.label).tag(account.id)
                    }
                }
                TextField("工作区目录", text: $workspace).textFieldStyle(.roundedBorder)
                Button("选择目录") {
                    let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
                    panel.begin { result in if result == .OK, let url = panel.url { workspace = url.path } }
                }
            }
            Text("新会话仅属于本机专属进程；停止后不能续接。创建后仍需单独批准设备对该工作区和会话的权限。")
                .font(.caption).foregroundStyle(.secondary)
            Button("创建独立新会话") {
                let program = URL(fileURLWithPath: (executable as NSString).expandingTildeInPath)
                let project = URL(fileURLWithPath: (workspace as NSString).expandingTildeInPath)
                Task { await manager.createOwnedChatGPT(sourceRuntimeId: sourceRuntimeId, workspace: project,
                                                          executable: program, lease: state.lease) }
            }.disabled(executable.isEmpty || workspace.isEmpty || sourceRuntimeId.isEmpty)
            ForEach(state.ownedRuntimes) { runtime in
                HStack {
                    VStack(alignment: .leading) {
                        Text(runtime.title).font(.caption)
                        Text(runtime.id).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    }
                    Spacer()
                    Button("停止接管") { Task { await manager.detachOwnedChatGPT(id: runtime.id, lease: state.lease) } }
                }
            }
        }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8)).disabled(manager.ownerBusy)
    }
}

private struct RemotePendingDeviceView: View {
    let pending: RemoteBindingApproval.Pending
    let runtimes: [RemoteRuntimeScopeRegistry.OwnerRuntime]
    let lease: UUID
    let version: Int
    @State private var selected = Set<String>()
    @State private var scopes: Set<String> = ["discovery", "session.read"]
    @State private var manager = RemoteProductionManager.shared
    private let options = [("discovery", "列出会话"), ("session.read", "读取历史"), ("session.write", "发送消息与中断"), ("session.approve", "回答问题与批准操作")]
    private var available: Set<String> { RemoteProductionService.ownerScopes(runtimes.filter { selected.contains($0.id) }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(pending.deviceName).font(.headline)
            Text("\(pending.userEmail) · \(pending.deviceId)").font(.caption).textSelection(.enabled)
            Text("公钥：\(pending.thumbprint)").font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
            Text("请求到期：\(pending.expiresAt.formatted()) · 当前本机版本 \(version)").font(.caption).foregroundStyle(.secondary)
            Text("选择允许访问的会话资源").font(.caption)
            ForEach(runtimes) { runtime in
                Toggle("\(runtime.label) · \(runtime.runtimeId)", isOn: membership(runtime.id, in: $selected))
            }
            ForEach(options, id: \.0) { scope, title in
                Toggle(title, isOn: membership(scope, in: $scopes)).disabled(!available.contains(scope))
            }
            HStack {
                Button("批准所选权限") {
                    let chosen = scopes.intersection(available).sorted()
                    Task { await manager.approveDevice(id: pending.id, scopes: chosen, runtimeIds: selected, expectedVersion: version, lease: lease) }
                }.disabled(manager.ownerBusy || selected.isEmpty || scopes.intersection(available).isEmpty)
                Button("拒绝", role: .destructive) { Task { await manager.rejectDevice(id: pending.id, lease: lease) } }.disabled(manager.ownerBusy)
            }
        }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .disabled(manager.ownerBusy)
    }
    private func membership(_ value: String, in values: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { values.wrappedValue.contains(value) }, set: { selected in
            if selected { values.wrappedValue.insert(value) } else { values.wrappedValue.remove(value) }
        })
    }
}
