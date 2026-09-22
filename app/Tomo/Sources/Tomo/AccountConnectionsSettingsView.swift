import SwiftUI
@preconcurrency import AppKit
import SwiftUI

private enum ConnectionPickerTab: String, CaseIterable, Identifiable {
    case agent
    case apiKey

    var id: String { rawValue }
    var title: String { self == .agent ? "Agent 账号" : "API Key" }
}

enum ConnectionModalPage {
    case picker
    case deepSeek
    case openCodeGo
    case openCodeZen
}

/// 编辑目标：复用一个创建连接的 modal 来编辑已有连接。
struct AccountConnectionEditTarget: Identifiable, Equatable {
    enum Kind: Equatable {
        case deepSeek
        case openCode(OpenCodePlan)
    }

    let id: ConnectionID
    let kind: Kind
    let initialLabel: String
    let initialAPIKey: String
    let initialWorkspaceURL: String?

    var page: ConnectionModalPage {
        switch kind {
        case .deepSeek: .deepSeek
        case .openCode(.go): .openCodeGo
        case .openCode(.zen): .openCodeZen
        }
    }

    var displayName: String {
        switch kind {
        case .deepSeek: "DeepSeek"
        case .openCode(let plan): plan.displayName
        }
    }
}

/// Dashboard-owned modal matching the connection picker demonstrated by the
/// landing Preview. It intentionally stays inside the dashboard instead of
/// navigating to Settings or presenting a native macOS sheet.
struct AccountConnectionsModalView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var store: MultiAgentSettingsStore
    /// 传入后进入编辑模式：跳过 picker、直达对应表单并预填当前值，
    /// 保存时调用 store 的 update 方法而非 add。
    var editing: AccountConnectionEditTarget? = nil
    let onClose: () -> Void

    @State private var selectedTab: ConnectionPickerTab = .agent
    @State private var page: ConnectionModalPage = .picker
    @State private var label = ""
    @State private var apiKey = ""
    @State private var workspaceInput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            modalHeader

            switch page {
            case .picker:
                pickerContent
            case .deepSeek:
                deepSeekForm
            case .openCodeGo:
                openCodeForm(plan: .go)
            case .openCodeZen:
                openCodeForm(plan: .zen)
            }
        }
        .padding(16)
        .frame(maxWidth: 330)
        .background(modalSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(modalBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.52 : 0.24), radius: 28, y: 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("添加账号或 API Key")
        .onDisappear {
            store.cancelCurrentCodexOAuth()
            store.cancelCurrentGeminiOAuth()
        }
        .onAppear {
            guard let editing else { return }
            label = editing.initialLabel
            apiKey = editing.initialAPIKey
            workspaceInput = editing.initialWorkspaceURL ?? ""
            page = editing.page
        }
    }

    private var modalHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(editing != nil ? "EDIT CREDENTIAL" : (page == .picker ? "NEW CONNECTION" : "NEW CREDENTIAL"))
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(Color.codexGreen)
                Text(headerTitle)
                    .font(.system(size: 17, weight: .bold))
                Text(headerSubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.codexMuted)
                    .padding(.top, 2)
            }
            Spacer(minLength: 8)
            Button(action: closeModal) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.codexMuted)
                    .frame(width: 38, height: 38)
                    .contentShape(Circle())
                    .background(closeButtonSurface, in: Circle())
            }
            .buttonStyle(CodexPressableCircleStyle())
            .accessibilityLabel(editing == nil ? "关闭添加连接" : "关闭编辑连接")
        }
    }

    private var headerTitle: String {
        if let editing {
            return "编辑 \(editing.displayName) API Key"
        }
        return switch page {
        case .picker: "添加账号或 API Key"
        case .deepSeek: "添加 DeepSeek API Key"
        case .openCodeGo: "添加 OpenCode Go API Key"
        case .openCodeZen: "添加 OpenCode Zen API Key"
        }
    }

    private var headerSubtitle: String {
        if editing != nil {
            return "修改名称或 API Key，保存后会重新验证。"
        }
        return switch page {
        case .picker: "同一种 Agent 可以登录多个账号。"
        case .deepSeek: "Key 只存入 macOS Keychain，用于官方余额接口。"
        case .openCodeGo: "Key 只存本机，用于验证 Go 模型可用性；额度暂不可查询。"
        case .openCodeZen: "Key 只存本机，用于验证 Zen 模型可用性；余额暂不可查询。"
        }
    }

    private var pickerContent: some View {
        VStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(ConnectionPickerTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Text(tab.title)
                            .font(.system(size: 10, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .contentShape(Rectangle())
                            .background(
                                selectedTab == tab ? selectedTabSurface : Color.clear,
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                            )
                    }
                    .buttonStyle(CodexPressableStyle(cornerRadius: 9))
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(selectedTab == tab ? Color.codexInk : Color.codexMuted)
                }
            }
            .padding(4)
            .background(segmentedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.top, 14)

            if selectedTab == .agent {
                connectionOption(
                    asset: .codex,
                    title: "添加 Codex 账号",
                    subtitle: "通过官方 OAuth 授权，与其他供应商账号平等",
                    isOAuthInProgress: store.isCodexOAuthInProgress,
                    supportsOAuthCancellation: true,
                    onCancelOAuth: { store.cancelCurrentCodexOAuth() }
                ) {
                    resetFields()
                    Task {
                        if await store.addCodexAccount() {
                            onClose()
                        }
                    }
                }
                connectionOption(
                    asset: .googleGemini,
                    title: "添加 Gemini 账号",
                    subtitle: "使用 Google OAuth 官方授权",
                    isOAuthInProgress: store.isGeminiOAuthInProgress,
                    supportsOAuthCancellation: true,
                    onCancelOAuth: { store.cancelCurrentGeminiOAuth() }
                ) {
                    resetFields()
                    Task {
                        if await store.addGeminiAccount() {
                            onClose()
                        }
                    }
                }
            } else {
                connectionOption(
                    asset: .deepSeek,
                    title: "添加 DeepSeek API Key",
                    subtitle: "查询官方账户余额"
                ) {
                    resetFields()
                    page = .deepSeek
                }
                connectionOption(
                    asset: .openCode,
                    title: "添加 OpenCode Go API Key",
                    subtitle: "验证 Go 订阅模型；5h / 周 / 月额度暂不可查"
                ) {
                    resetFields()
                    page = .openCodeGo
                }
                connectionOption(
                    asset: .openCode,
                    title: "添加 OpenCode Zen API Key",
                    subtitle: "验证 Zen 模型；账户余额暂不可查"
                ) {
                    resetFields()
                    page = .openCodeZen
                }
            }
            if let message = store.lastMessage,
               message.contains("失败") || message.contains("取消") {
                Text(message)
                    .font(.system(size: 9))
                    .foregroundStyle(message.contains("失败") ? Color.codexRed : Color.codexMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func connectionOption(
        asset: BrandAssetID,
        title: String,
        subtitle: String,
        isOAuthInProgress: Bool = false,
        supportsOAuthCancellation: Bool = false,
        onCancelOAuth: (() -> Void)? = nil,
        action: @escaping () -> Void
    ) -> some View {
        ZStack(alignment: .trailing) {
            Button(action: action) {
                HStack(spacing: 10) {
                    BrandIconView(asset: asset, size: 38, cornerRadius: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.88)
                        Text(subtitle)
                            .font(.system(size: 9))
                            .foregroundStyle(Color.codexMuted)
                            .lineLimit(2)
                    }
                    .layoutPriority(1)
                    Spacer()
                    if supportsOAuthCancellation && isOAuthInProgress {
                        Color.clear.frame(width: 44, height: 1)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.codexMuted)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 58)
                .contentShape(Rectangle())
                .background(optionSurface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(Color.codexLine, lineWidth: 1)
                }
            }
            .buttonStyle(CodexPressableCardStyle(cornerRadius: 13))
            .disabled(store.isMutatingConnections)

            if supportsOAuthCancellation && isOAuthInProgress {
                CancelCodexOAuthButton {
                    onCancelOAuth?()
                }
                .padding(.trailing, 9)
            }
        }
    }

    private var deepSeekForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            PlainTextField(text: $label, placeholder: "连接名称")
                .frame(height: 28)
            PlainTextField(text: $apiKey, placeholder: "sk-…")
                .frame(height: 28)
            Text("Key 明文显示，可选中复制", tableName: nil, bundle: nil, comment: "")
                .font(.system(size: 9))
                .foregroundStyle(Color.codexMuted)
            if let message = store.lastMessage, message.contains("失败") {
                Text(message)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.red)
            }
            HStack(spacing: 8) {
                if editing == nil {
                    Button { page = .picker } label: {
                        Text("返回")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(segmentedSurface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(CodexPressableStyle(cornerRadius: 7))
                }
                Spacer()
                Button {
                    Task {
                        if let editing {
                            if await store.updateDeepSeekConnection(
                                connectionID: editing.id,
                                label: label,
                                apiKey: apiKey
                            ) {
                                onClose()
                            }
                        } else if await store.addDeepSeekConnection(label: label, apiKey: apiKey) {
                            onClose()
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if store.isMutatingConnections {
                            CodexButtonLoading(tint: .white, size: 10)
                        } else {
                            Text(editing == nil ? "验证并添加" : "验证并保存")
                        }
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.codexOnPrimary)
                    .padding(.horizontal, 15)
                    .frame(height: 32)
                    .background(Color.codexPrimary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(CodexPressableStyle(cornerRadius: 7, ink: .softLight))
                .disabled(store.isMutatingConnections || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.top, 16)
    }

    private func openCodeForm(plan: OpenCodePlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            PlainTextField(text: $label, placeholder: "连接名称")
                .frame(height: 28)
            PlainTextField(text: $apiKey, placeholder: "sk-…")
                .frame(height: 28)
            PlainTextField(text: $workspaceInput, placeholder: "工作间地址（可选） https://opencode.ai/workspace/wrk_.../go")
                .frame(height: 28)
            Text(plan == .go
                 ? "会验证 Go 模型目录；官方尚未提供 5h / 周 / 月用量 API。"
                 : "会验证 Zen 模型目录；官方尚未提供单 Key 余额 API。")
                .font(.system(size: 9))
                .foregroundStyle(Color.codexMuted)
                .fixedSize(horizontal: false, vertical: true)
            Text("工作间地址用于 footer「前往官方页面」深链到你的账号页（含 wrk_ 的 workspace 地址）。")
                .font(.system(size: 9))
                .foregroundStyle(Color.codexMuted)
                .fixedSize(horizontal: false, vertical: true)
            if let message = store.lastMessage, message.contains("失败") {
                Text(message)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.red)
            }
            HStack(spacing: 8) {
                if editing == nil {
                    Button { page = .picker } label: {
                        Text("返回")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(segmentedSurface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(CodexPressableStyle(cornerRadius: 7))
                }
                Spacer()
                Button {
                    Task {
                        if let editing {
                            if await store.updateOpenCodeConnection(
                                connectionID: editing.id,
                                label: label,
                                apiKey: apiKey,
                                workspaceURL: workspaceInput
                            ) {
                                onClose()
                            }
                        } else if await store.addOpenCodeConnection(
                            plan: plan,
                            label: label,
                            apiKey: apiKey,
                            workspaceURL: workspaceInput
                        ) {
                            onClose()
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if store.isMutatingConnections {
                            CodexButtonLoading(tint: .white, size: 10)
                        } else {
                            Text(editing == nil ? "验证并添加" : "验证并保存")
                        }
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.codexOnPrimary)
                    .padding(.horizontal, 15)
                    .frame(height: 32)
                    .background(Color.codexPrimary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(CodexPressableStyle(cornerRadius: 7, ink: .softLight))
                .disabled(store.isMutatingConnections || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func resetFields() {
        label = ""
        apiKey = ""
        workspaceInput = ""
    }

    private func closeModal() {
        store.cancelCurrentCodexOAuth()
        onClose()
    }

    private var modalSurface: Color {
        colorScheme == .dark
            ? Color(red: 0.205, green: 0.205, blue: 0.218)
            : Color(red: 0.985, green: 0.985, blue: 0.980)
    }

    private var modalBorder: Color {
        colorScheme == .dark ? Color.white.opacity(0.28) : Color.black.opacity(0.12)
    }

    private var segmentedSurface: Color {
        colorScheme == .dark ? Color.black.opacity(0.35) : Color.black.opacity(0.055)
    }

    private var selectedTabSurface: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.95)
    }

    private var optionSurface: Color {
        colorScheme == .dark ? Color.white.opacity(0.035) : Color.white.opacity(0.62)
    }

    private var closeButtonSurface: Color {
        colorScheme == .dark ? Color.black.opacity(0.12) : Color.black.opacity(0.035)
    }
}

/// 取消 Codex OAuth 的按钮：未悬停时只显示灰色 spin，悬停后才暴露「x 取消」。
private struct CancelCodexOAuthButton: View {
    let onCancel: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onCancel) {
            Group {
                if isHovered {
                    HStack(spacing: 5) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                        Text("取消")
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.codexRed)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.gray)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(
                (isHovered ? Color.codexRed : Color.gray).opacity(0.08),
                in: Capsule()
            )
        }
        .buttonStyle(CodexPressableStyle(cornerRadius: 15))
        .onHover { isHovered in
            self.isHovered = isHovered
        }
        .accessibilityLabel("取消 OAuth 登录")
    }
}

// MARK: - Plain TextField (NSTextField wrapper)

/// 用原生 NSTextField 包装的文本输入框。Overlay/modal 中没有标准
/// Edit 菜单时，编辑快捷键需要直接路由给 NSTextField 的 Field Editor。
struct PlainTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        field.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        field.lineBreakMode = .byTruncatingTail
        context.coordinator.attach(to: field)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    static func dismantleNSView(_ nsView: NSTextField, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: PlainTextField
        weak var field: NSTextField?
        private var shortcutMonitor: Any?

        init(_ parent: PlainTextField) {
            self.parent = parent
        }

        func attach(to field: NSTextField) {
            self.field = field
            shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                nonisolated(unsafe) let mainThreadEvent = event
                nonisolated(unsafe) let mainThreadCoordinator = self
                let handled = MainActor.assumeIsolated {
                    guard let mainThreadCoordinator,
                          let field = mainThreadCoordinator.field,
                          mainThreadEvent.window === field.window,
                          field.currentEditor() != nil,
                          TextFieldShortcutRouter.handle(event: mainThreadEvent, for: field)
                    else { return false }
                    return true
                }
                return handled ? nil : event
            }
        }

        func detach() {
            if let shortcutMonitor {
                NSEvent.removeMonitor(shortcutMonitor)
                self.shortcutMonitor = nil
            }
            field = nil
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
    }
}

@MainActor
enum TextFieldShortcutRouter {
    static func handle(event: NSEvent, for field: NSTextField) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              !flags.contains(.control),
              !flags.contains(.option),
              let editor = field.currentEditor(),
              let characters = event.charactersIgnoringModifiers?.lowercased()
        else { return false }

        switch characters {
        case "c":
            editor.copy(nil)
        case "v":
            editor.paste(nil)
        case "x":
            editor.cut(nil)
        case "a":
            editor.selectAll(nil)
        case "z" where flags.contains(.shift):
            editor.undoManager?.redo()
        case "z":
            editor.undoManager?.undo()
        default:
            return false
        }
        return true
    }
}
