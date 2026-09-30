import SwiftUI

/// Codex 模型映射管理弹窗，支持配置自定义 slug、上游模型、推理强度及默认模型
struct CodexModelMappingSheet: View {
    @Bindable var store: GatewayStore
    @Environment(\.dismiss) private var dismiss

    @State private var mappings: [CodexModelMapping] = []
    @State private var editingMapping: CodexModelMapping? = nil
    @State private var isAddingNew = false

    @State private var formSlug = ""
    @State private var formDisplayName = ""
    @State private var formUpstreamModel = ""
    @State private var formReasoningEffort = "none"
    @State private var formIsDefault = false
    @State private var errorMessage: String? = nil

    private var availableUpstreamModels: [String] {
        if !store.v1Models.isEmpty {
            return store.v1Models.map { $0.id }
        }
        return store.allExportedModels.map { $0.modelName }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 580, height: 480)
        .background(Color.codexCard)
        .onAppear {
            mappings = store.gatewaySettings.codexModelMappings
        }
    }
}

extension CodexModelMappingSheet {
    var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.swap")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.codexPrimary)
                    Text("Codex 模型映射管理")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.codexInk)
                }
                Text("自定义 Codex 中请求的模型 Slug 并重定向至 Tomo 网关上游模型，支持独立指定推理强度。")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.codexMuted)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.codexMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    var content: some View {
        Group {
            if isAddingNew || editingMapping != nil {
                editFormView
            } else {
                mappingListView
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    var footer: some View {
        HStack {
            Text("配置修改后将自动保存并即时同步到 Tomo Gateway 配置文件。")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.codexMuted)
            Spacer()
            Button("完成") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

extension CodexModelMappingSheet {
    var mappingListView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("已配置的映射 (\(mappings.count))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.codexInk)
                Spacer()
                Button {
                    openNewMappingForm()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                        Text("添加映射")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.codexPrimary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .foregroundStyle(Color.codexOnPrimary)
                }
                .buttonStyle(.plain)
            }

            if mappings.isEmpty {
                emptyPlaceholderView
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(mappings) { item in
                            mappingRow(item)
                        }
                    }
                }
            }
        }
    }

    var emptyPlaceholderView: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 24))
                .foregroundStyle(Color.codexMuted.opacity(0.6))
            Text("暂无自定义映射")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.codexMuted)
            Text("未配置自定义映射时，Codex 将直接使用 Tomo 网关中的全部原始模型。")
                .font(.system(size: 11))
                .foregroundStyle(Color.codexMuted.opacity(0.8))
                .multilineTextAlignment(.center)

            if !availableUpstreamModels.isEmpty {
                Button {
                    autoFillPresets()
                } label: {
                    Text("基于当前模型池自动生成常用别名")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.codexMuted.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .foregroundStyle(Color.codexInk)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.codexBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}


extension CodexModelMappingSheet {
    func mappingRow(_ item: CodexModelMapping) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.slug)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.codexInk)

                    if item.isDefault {
                        Text("默认")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.15), in: Capsule())
                            .foregroundStyle(.green)
                    }

                    if let effort = item.defaultReasoningEffort, !effort.isEmpty {
                        Text("推理: \(effort)")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.12), in: Capsule())
                            .foregroundStyle(.purple)
                    }
                }

                HStack(spacing: 4) {
                    Text(item.displayName.isEmpty ? item.slug : item.displayName)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.codexMuted)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.codexMuted.opacity(0.6))
                    Text(item.upstreamModel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.codexInk)
                }
            }

            Spacer()

            HStack(spacing: 6) {
                if !item.isDefault {
                    Button {
                        setDefault(item)
                    } label: {
                        Text("设为默认")
                            .font(.system(size: 10))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.codexMuted.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(Color.codexInk)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    openEditMappingForm(item)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                        .padding(5)
                        .background(Color.codexMuted.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(Color.codexInk)
                }
                .buttonStyle(.plain)

                Button {
                    deleteMapping(item)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .padding(5)
                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(Color.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color.codexBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.codexLine.opacity(0.3), lineWidth: 0.8)
        )
    }
}


extension CodexModelMappingSheet {
    var editFormView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(editingMapping != nil ? "编辑模型映射" : "添加模型映射")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.codexInk)
                Spacer()
                Button {
                    closeForm()
                } label: {
                    Text("取消")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.codexMuted)
                }
                .buttonStyle(.plain)
            }

            if let err = errorMessage {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.red)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            }

            formInputFields

            Spacer()

            HStack {
                Spacer()
                Button {
                    saveForm()
                } label: {
                    Text("保存此映射")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.codexPrimary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .foregroundStyle(Color.codexOnPrimary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}


extension CodexModelMappingSheet {
    var formInputFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Codex 模型标识 (Slug)*")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.codexInk)
                TextField("例如: deepseek-chat 或 custom-gpt-4o", text: $formSlug)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.codexLine.opacity(0.4), lineWidth: 0.8))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("显示名称 (Display Name)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.codexInk)
                TextField("例如: DeepSeek V3 (网关直通)", text: $formDisplayName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.codexLine.opacity(0.4), lineWidth: 0.8))
            }

            upstreamModelPickerField

            reasoningAndDefaultField
        }
    }

    var upstreamModelPickerField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("路由上游模型 (Upstream Model)*")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.codexInk)

            HStack {
                TextField("例如: deepseek/deepseek-chat 或 gemini-2.5-flash", text: $formUpstreamModel)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.codexLine.opacity(0.4), lineWidth: 0.8))

                if !availableUpstreamModels.isEmpty {
                    Menu {
                        ForEach(availableUpstreamModels, id: \.self) { model in
                            Button(model) {
                                formUpstreamModel = model
                                if formSlug.isEmpty {
                                    formSlug = model.replacingOccurrences(of: "/", with: "-")
                                }
                                if formDisplayName.isEmpty {
                                    formDisplayName = model
                                }
                            }
                        }
                    } label: {
                        Text("选择现有模型")
                            .font(.system(size: 10.5))
                    }
                    .menuStyle(.borderedButton)
                }
            }
        }
    }

    var reasoningAndDefaultField: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("默认推理强度 (Reasoning Effort)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.codexInk)
                Picker("", selection: $formReasoningEffort) {
                    Text("继承 / 不设置").tag("none")
                    Text("低 (low)").tag("low")
                    Text("中 (medium)").tag("medium")
                    Text("高 (high)").tag("high")
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Codex 默认模型")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.codexInk)
                Toggle("设为默认调用模型", isOn: $formIsDefault)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
            }
        }
    }
}


extension CodexModelMappingSheet {
    func openNewMappingForm() {
        formSlug = ""
        formDisplayName = ""
        formUpstreamModel = availableUpstreamModels.first ?? ""
        formReasoningEffort = "none"
        formIsDefault = mappings.isEmpty
        errorMessage = nil
        editingMapping = nil
        isAddingNew = true
    }

    func openEditMappingForm(_ item: CodexModelMapping) {
        formSlug = item.slug
        formDisplayName = item.displayName
        formUpstreamModel = item.upstreamModel
        formReasoningEffort = item.defaultReasoningEffort ?? "none"
        formIsDefault = item.isDefault
        errorMessage = nil
        editingMapping = item
        isAddingNew = false
    }

    func closeForm() {
        editingMapping = nil
        isAddingNew = false
        errorMessage = nil
    }

    func saveForm() {
        let cleanSlug = formSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUpstream = formUpstreamModel.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanSlug.isEmpty else {
            errorMessage = "Codex 模型 Slug 不能为空"
            return
        }
        guard !cleanUpstream.isEmpty else {
            errorMessage = "路由上游模型不能为空"
            return
        }

        let effort = formReasoningEffort == "none" ? nil : formReasoningEffort
        let mapping = CodexModelMapping(
            slug: cleanSlug,
            displayName: formDisplayName.trimmingCharacters(in: .whitespacesAndNewlines),
            upstreamModel: cleanUpstream,
            defaultReasoningEffort: effort,
            isDefault: formIsDefault
        )

        store.saveCodexModelMapping(mapping)
        mappings = store.gatewaySettings.codexModelMappings
        closeForm()

        if store.codexAgentConfigured {
            Task {
                _ = await store.refreshCodexModels()
            }
        }
    }

    func deleteMapping(_ item: CodexModelMapping) {
        store.removeCodexModelMapping(slug: item.slug)
        mappings = store.gatewaySettings.codexModelMappings
        if store.codexAgentConfigured {
            Task {
                _ = await store.refreshCodexModels()
            }
        }
    }

    func setDefault(_ item: CodexModelMapping) {
        store.setDefaultCodexModelMapping(slug: item.slug)
        mappings = store.gatewaySettings.codexModelMappings
        if store.codexAgentConfigured {
            Task {
                _ = await store.refreshCodexModels()
            }
        }
    }

    func autoFillPresets() {
        for model in availableUpstreamModels {
            let slug = model.replacingOccurrences(of: "/", with: "-")
            let mapping = CodexModelMapping(
                slug: slug,
                displayName: model,
                upstreamModel: model,
                defaultReasoningEffort: nil,
                isDefault: mappings.isEmpty
            )
            store.saveCodexModelMapping(mapping)
        }
        mappings = store.gatewaySettings.codexModelMappings
        if store.codexAgentConfigured {
            Task {
                _ = await store.refreshCodexModels()
            }
        }
    }
}

