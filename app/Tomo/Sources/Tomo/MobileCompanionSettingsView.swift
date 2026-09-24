import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

// MARK: - QR Code View

private struct QRCodeView: View {
    let content: String
    let size: CGFloat

    var body: some View {
        if let image = generateQRCode(from: content) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .padding(10)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 2)
        } else {
            Rectangle()
                .fill(Color.codexMist)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    Text("无法生成二维码")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.codexMuted)
                )
        }
    }

    private func generateQRCode(from string: String) -> NSImage? {
        guard let data = string.data(using: .utf8) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else { return nil }
        let transform = CGAffineTransform(scaleX: 6, y: 6)
        let scaledImage = outputImage.transformed(by: transform)

        let rep = NSCIImageRep(ciImage: scaledImage)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }
}

// MARK: - Mobile Companion Settings View

struct MobileCompanionSettingsView: View {
    var accentColor: Color = Color.codexGreen
    @State private var syncManager = MobileSyncManager.shared
    @State private var pluginInstaller = WebPluginInstaller.shared
    @State private var pluginStatus: WebPluginStatus = WebPluginInstaller.shared.currentStatus()
    @State private var isDownloadingPlugin = false
    @State private var isCheckingForUpdate = false
    @State private var availableUpdate: WebPluginInstaller.RemoteReleaseInfo?
    @State private var downloadProgress: Double = 0.0
    @State private var actionMessage: String?
    @State private var isErrorMessage = false
    @State private var showsTokenRegenerateAlert = false
    @State private var isRestartingService = false

    var onShowToast: (String, String) -> Void = { _, _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            serverAndPairingSection
            pluginManagementSection
        }
        .padding(.bottom, 24)
        .background(ScrollIndicatorHider(id: "mobileCompanion"))
        .onAppear {
            refreshStatus()
        }
        // Resolve the restart by watching the listener's real status. Watching
        // `isRunning` would report a failure immediately, because restart()
        // stops first and that legitimately dips the flag to false.
        .onChange(of: syncManager.serverStatus) { _, status in
            guard isRestartingService else { return }
            switch status {
            case .ready:
                isRestartingService = false
                onShowToast("开放 API 服务已重启 · 端口 \(syncManager.port)", "checkmark.circle")
            case .failed where !syncManager.isAwaitingRetry:
                // Retries exhausted — this is a terminal failure.
                isRestartingService = false
                onShowToast(
                    "服务重启失败：\(syncManager.serverError ?? "未知原因")",
                    "exclamationmark.triangle"
                )
            default:
                break // still starting, or failing but retrying
            }
        }
        .task(id: isRestartingService) {
            guard isRestartingService else { return }
            // Safety net so the button cannot spin forever.
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, isRestartingService else { return }
            isRestartingService = false
            onShowToast("服务重启超时，请检查端口是否被占用", "exclamationmark.triangle")
        }
    }

    // MARK: - Section 1: Server & Pairing

    private var serverAndPairingSection: some View {
        SettingsSection(
            title: "开放 API 服务与移动端配对",
            subtitle: "向自建应用提供状态、额度与宠物 API，支持手机扫码配对"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                serviceStatusCard

                if syncManager.isEnabled && syncManager.isRunning {
                    pairingCard
                } else {
                    waitingCard
                }
            }
        }
    }

    // MARK: Server status

    private var serviceStatusCard: some View {
        SettingsUpdateCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    SettingsUpdateGlyph(systemName: serviceStatusSymbol, tint: serviceStatusTint)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("开放 API 服务")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.codexInk)

                        Text(serviceStatusText)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(serviceStatusTint)
                    }

                    Spacer(minLength: 12)

                    // Label stays for VoiceOver even though the switch renders bare.
                    Toggle("启用开放 API 服务", isOn: $syncManager.isEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                Divider().overlay(Color.codexLine.opacity(0.6))

                // Port and address live on their own row: cramming them beside the
                // toggle wrapped "端口 58350" onto a second line.
                HStack(spacing: 10) {
                    Label {
                        Text(verbatim: "\(syncManager.lanIPv4):\(syncManager.port)")
                            .font(.system(size: 11.5, design: .monospaced))
                    } icon: {
                        Image(systemName: "network")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(Color.codexMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("监听地址与端口")

                    Spacer(minLength: 8)

                    Button {
                        isRestartingService = true
                        syncManager.restart()
                    } label: {
                        HStack(spacing: 5) {
                            if isRestartingService {
                                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(isRestartingService ? "重启中…" : "重启服务")
                        }
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.codexMist.opacity(0.6))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color.codexLine.opacity(0.7), lineWidth: 0.75)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!syncManager.isEnabled || isRestartingService)
                    .help("在当前端口重新绑定监听；无需退出 Tomo")
                }

                if let err = syncManager.serverError {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.codexRed)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("服务启动异常：\(err)")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Color.codexRed)
                            Text(
                                syncManager.isAwaitingRetry
                                    ? "正在自动重试绑定…若持续失败，请确认端口未被其它程序占用，或点击「重启服务」。"
                                    : "自动重试已用尽，请点击「重启服务」，或改用其它端口。"
                            )
                            .font(.system(size: 11))
                            .foregroundStyle(Color.codexMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.codexRed.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }

    // MARK: Pairing

    private var pairingCard: some View {
        SettingsUpdateCard {
            HStack(alignment: .top, spacing: 18) {
                QRCodeView(content: syncManager.webURLString, size: 132)

                VStack(alignment: .leading, spacing: 9) {
                    Text("手机扫码一键连接")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.codexInk)

                    Text("在同一 Wi-Fi 局域网下，用 iPhone 相机或任意移动端浏览器扫码，即可打开 1:1 伴生看板，无需安装 App。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.codexMuted)
                        .lineSpacing(2.5)
                        .fixedSize(horizontal: false, vertical: true)

                    addressRow

                    Divider().overlay(Color.codexLine.opacity(0.6))

                    HStack(spacing: 8) {
                        SettingsUpdateChip(
                            title: "复制 Token",
                            systemImage: "key"
                        ) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(syncManager.token, forType: .string)
                            onShowToast("已复制配对 Token", "key")
                        }
                        .help("仅复制当前配对 Token")

                        SettingsUpdateChip(
                            title: "重新生成配对 Token",
                            systemImage: "arrow.triangle.2.circlepath",
                            tint: Color.codexMuted
                        ) {
                            showsTokenRegenerateAlert = true
                        }
                        .help("旧设备将需要重新扫码")

                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .alert("重新生成配对 Token？", isPresented: $showsTokenRegenerateAlert) {
            Button("取消", role: .cancel) {}
            Button("重新生成", role: .destructive) {
                syncManager.regenerateToken()
                onShowToast("已生成全新配对 Token，历史二维码已失效", "checkmark.shield")
            }
        } message: {
            Text("重新生成后，之前已连接或保存旧 Token 的设备将无法访问，需要重新扫码连接。")
        }
    }

    private var addressRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("局域网直连网址")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.codexMuted)

            HStack(spacing: 8) {
                Text(syncManager.webURLString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.codexInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.codexMist.opacity(0.6), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color.codexLine.opacity(0.7), lineWidth: 0.75)
                    )

                SettingsUpdateChip(title: "复制", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(syncManager.webURLString, forType: .string)
                    onShowToast("已复制移动端访问网址", "doc.on.doc")
                }

                SettingsUpdateChip(title: "打开", systemImage: "arrow.up.forward.square") {
                    if let url = URL(string: syncManager.webURLString) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .help("在默认浏览器中打开预览")
            }
        }
    }

    /// Shown while the service is off, starting, or failed — always with the
    /// reason and the way forward, never a blank slab.
    private var waitingCard: some View {
        SettingsUpdateCard {
            HStack(alignment: .top, spacing: 12) {
                SettingsUpdateGlyph(systemName: waitingSymbol, tint: waitingTint, size: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text(waitingTitle)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.codexInk)
                    Text(waitingDetail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.codexMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Section 2: Plugin Management

    private var pluginManagementSection: some View {
        SettingsSection(
            title: "Web 伴生前端插件",
            subtitle: "管理桌面端私有托管的 1:1 移动看板 Web Core 静态资源包"
        ) {
            SettingsUpdateCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        SettingsUpdateGlyph(
                            systemName: pluginStatus.isInstalled ? "shippingbox.fill" : "shippingbox",
                            tint: pluginStatus.isInstalled ? accentColor : Color.codexAmber
                        )

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 7) {
                                Text(pluginStatus.isInstalled ? "Web 伴生插件已就绪" : "未安装 Web 前端插件")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.codexInk)

                                if pluginStatus.isInstalled {
                                    Text(verbatim: "v\(pluginStatus.displayVersion)")
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .foregroundStyle(accentColor)
                                        .background(accentColor.opacity(0.12), in: Capsule())
                                }
                            }

                            Text(pluginSubtitle)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Color.codexMuted)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 12)

                        if !pluginStatus.isInstalled {
                            SettingsUpdatePrimaryAction(
                                title: isDownloadingPlugin ? "正在安装…" : "一键安装",
                                systemImage: "arrow.down.circle.fill",
                                isBusy: isDownloadingPlugin,
                                isEnabled: !isDownloadingPlugin
                            ) {
                                downloadAndInstallPlugin()
                            }
                        } else if let update = availableUpdate, update.hasUpdate {
                            SettingsUpdatePrimaryAction(
                                title: isDownloadingPlugin ? "正在更新…" : "更新至 v\(update.version)",
                                systemImage: "arrow.up.circle.fill",
                                isBusy: isDownloadingPlugin,
                                isEnabled: !isDownloadingPlugin
                            ) {
                                downloadAndInstallPlugin(remoteURL: update.downloadURL)
                            }
                        } else {
                            SettingsUpdateChip(
                                title: isCheckingForUpdate ? "检查中…" : "检查更新",
                                systemImage: "arrow.triangle.2.circlepath",
                                isEnabled: !isCheckingForUpdate && !isDownloadingPlugin,
                                isBusy: isCheckingForUpdate
                            ) {
                                checkForPluginUpdates()
                            }
                        }
                    }

                    if isDownloadingPlugin {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(actionMessage ?? "正在下载插件包…")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(Color.codexInk)

                                Spacer()

                                if downloadProgress > 0 {
                                    Text(verbatim: "\(Int(downloadProgress * 100))%")
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Color.codexPrimary)
                                }
                            }

                            ProgressView(value: downloadProgress > 0 ? downloadProgress : nil)
                                .progressViewStyle(.linear)
                                .tint(Color.codexPrimary)
                                .controlSize(.small)
                        }
                        .padding(.vertical, 2)
                    } else if let message = actionMessage {
                        HStack(spacing: 6) {
                            Image(systemName: isErrorMessage ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .font(.system(size: 11))
                            Text(message)
                                .font(.system(size: 11.5))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(isErrorMessage ? Color.codexRed : accentColor)
                        .padding(.leading, 2)
                    }

                    Divider().overlay(Color.codexLine.opacity(0.6))

                    HStack(spacing: 8) {
                        SettingsUpdateChip(
                            title: "从本地 .zip 导入…",
                            systemImage: "square.and.arrow.down",
                            isEnabled: !isDownloadingPlugin
                        ) {
                            importLocalPluginZip()
                        }

                        SettingsUpdateChip(title: "在访达中打开", systemImage: "folder") {
                            NSWorkspace.shared.selectFile(
                                nil,
                                inFileViewerRootedAtPath: pluginInstaller.pluginDirectory.path
                            )
                        }

                        Spacer(minLength: 0)

                        if pluginStatus.isInstalled {
                            SettingsUpdateChip(
                                title: "移除插件",
                                systemImage: "trash",
                                tint: Color.codexRed,
                                isEnabled: !isDownloadingPlugin
                            ) {
                                uninstallPlugin()
                            }
                        }
                    }
                }
            }
        }
    }

    private var pluginSubtitle: String {
        guard pluginStatus.isInstalled else {
            return "未安装时访问 58350 根路由会展示友好引导页，API 数据广播不受影响。"
        }
        return "资源体积 \(pluginStatus.displaySizeString) · 支持 10 款伴生宠物与 Canvas 液态波浪"
    }

    // MARK: - Status derivation

    private var serviceStatusTint: Color {
        guard syncManager.isEnabled else { return Color.codexMuted.opacity(0.5) }
        switch syncManager.serverStatus {
        case .ready: return accentColor
        case .starting: return Color.codexAmber
        case .failed: return Color.codexRed
        case .idle: return Color.codexMuted.opacity(0.5)
        }
    }

    private var serviceStatusSymbol: String {
        guard syncManager.isEnabled else { return "power" }
        switch syncManager.serverStatus {
        case .ready: return "antenna.radiowaves.left.and.right"
        case .starting: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle.fill"
        case .idle: return "power"
        }
    }

    private var serviceStatusText: String {
        guard syncManager.isEnabled else { return "已停止" }
        switch syncManager.serverStatus {
        case .ready: return "服务正常运行中"
        case .starting: return "正在启动…"
        case .failed: return syncManager.isAwaitingRetry ? "启动失败 · 自动重试中" : "启动失败"
        case .idle: return "已停止"
        }
    }

    private var waitingSymbol: String {
        guard syncManager.isEnabled else { return "power.circle" }
        switch syncManager.serverStatus {
        case .starting: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "power.circle"
        }
    }

    private var waitingTint: Color {
        guard syncManager.isEnabled else { return Color.codexMuted }
        switch syncManager.serverStatus {
        case .starting: return Color.codexAmber
        case .failed: return Color.codexRed
        default: return Color.codexMuted
        }
    }

    private var waitingTitle: String {
        guard syncManager.isEnabled else { return "同步服务未开启" }
        switch syncManager.serverStatus {
        case .starting: return "正在启动同步服务…"
        case .failed: return "同步服务未能启动"
        default: return "同步服务未运行"
        }
    }

    private var waitingDetail: String {
        guard syncManager.isEnabled else {
            return "打开上方开关后，这里会出现局域网配对二维码与直连网址。"
        }
        switch syncManager.serverStatus {
        case .starting:
            return "正在绑定局域网端口，稍候即可扫码连接。"
        case .failed:
            return "请查看上方错误说明，或点击「重启服务」重试。"
        default:
            return "服务当前未在监听，点击「重启服务」可重新绑定端口。"
        }
    }

    // MARK: - Actions

    private func refreshStatus() {
        pluginStatus = pluginInstaller.currentStatus()
        // If the installed version already matches or exceeds the found update, clear it.
        if let update = availableUpdate {
            let currentVer = pluginStatus.displayVersion
            if currentVer == update.version || currentVer == "v\(update.version)" {
                availableUpdate = nil
            }
        }
    }

    private func checkForPluginUpdates() {
        isCheckingForUpdate = true
        actionMessage = "正在查询远端最新版本…"
        isErrorMessage = false

        Task {
            do {
                let releaseInfo = try await pluginInstaller.checkForUpdates()
                await MainActor.run {
                    self.isCheckingForUpdate = false
                    self.availableUpdate = releaseInfo
                    if releaseInfo.hasUpdate {
                        self.actionMessage = "发现新版本 v\(releaseInfo.version)，可点击「更新至 v\(releaseInfo.version)」"
                        self.isErrorMessage = false
                        self.onShowToast("发现 Web 伴生插件新版本 v\(releaseInfo.version)", "arrow.up.circle.fill")
                    } else {
                        self.actionMessage = "当前已是最新版本 (v\(self.pluginStatus.displayVersion))"
                        self.isErrorMessage = false
                        self.onShowToast("Web 插件已是最新版本", "checkmark.circle")
                    }
                }
            } catch {
                await MainActor.run {
                    self.isCheckingForUpdate = false
                    self.actionMessage = "检查更新失败: \(error.localizedDescription)"
                    self.isErrorMessage = true
                }
            }
        }
    }

    private func downloadAndInstallPlugin(remoteURL: URL? = nil) {
        isDownloadingPlugin = true
        downloadProgress = 0.0
        actionMessage = "正在连接 GitHub Release 下载最新插件包…"
        isErrorMessage = false

        let targetURL = remoteURL ?? WebPluginInstaller.defaultReleaseURL

        Task {
            do {
                try await pluginInstaller.downloadAndInstall(from: targetURL, onProgress: { progress, currentBytes, totalBytes in
                    Task { @MainActor in
                        self.downloadProgress = progress
                        if totalBytes > 0 {
                            let currStr = ByteCountFormatter.string(fromByteCount: currentBytes, countStyle: .file)
                            let totalStr = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
                            self.actionMessage = "正在下载插件包：\(currStr) / \(totalStr) (\(Int(progress * 100))%)"
                        } else {
                            self.actionMessage = "正在下载插件包…"
                        }
                    }
                })
                await MainActor.run {
                    self.isDownloadingPlugin = false
                    self.downloadProgress = 1.0
                    self.availableUpdate = nil
                    self.refreshStatus()
                    self.actionMessage = "插件安装成功！当前版本 v\(self.pluginStatus.displayVersion)"
                    self.isErrorMessage = false
                    self.onShowToast("Web 伴生插件已成功安装", "checkmark.circle.fill")
                }
            } catch {
                await MainActor.run {
                    self.isDownloadingPlugin = false
                    self.downloadProgress = 0.0
                    self.actionMessage = "安装失败: \(error.localizedDescription)"
                    self.isErrorMessage = true
                }
            }
        }
    }

    private func importLocalPluginZip() {
        let panel = NSOpenPanel()
        panel.title = "选择 Web 伴生插件压缩包 (.zip)"
        panel.prompt = "导入插件"
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let fileURL = panel.url else { return }

        do {
            try pluginInstaller.install(fromLocalZip: fileURL)
            refreshStatus()
            actionMessage = "本地插件导入成功！版本 v\(pluginStatus.displayVersion)"
            isErrorMessage = false
            onShowToast("本地插件导入成功", "checkmark.circle.fill")
        } catch {
            actionMessage = "导入失败: \(error.localizedDescription)"
            isErrorMessage = true
        }
    }

    private func uninstallPlugin() {
        do {
            try pluginInstaller.uninstall()
            refreshStatus()
            actionMessage = "已移除 Web 伴生插件，服务现使用内置默认页。"
            isErrorMessage = false
            onShowToast("已移除 Web 插件", "trash")
        } catch {
            actionMessage = "移除失败: \(error.localizedDescription)"
            isErrorMessage = true
        }
    }
}
