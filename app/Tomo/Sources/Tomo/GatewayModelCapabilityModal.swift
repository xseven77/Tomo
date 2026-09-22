import SwiftUI

/// 用户自定义模型能力弹窗（上下文长度、最大输出、多模态图片、推理档位）
struct GatewayModelCapabilityModal: View {
    let modelID: String
    let modelName: String
    @Binding var settings: GatewaySettings
    let onSave: () -> Void
    let onDismiss: () -> Void

    @State private var contextWindowText: String = ""
    @State private var maxTokensText: String = ""
    @State private var supportsImage: Bool = false
    @State private var hasReasoning: Bool = false
    @State private var selectedReasoningLevels: Set<String> = []
    @State private var defaultReasoningLevel: String = "off"

    @State private var isCustomContextWindow: Bool = false
    @State private var isCustomMaxTokens: Bool = false

    private let standardContextWindows = [
        ("128K", 131_072),
        ("200K", 200_000),
        ("256K", 262_144),
        ("1M", 1_048_576),
        ("2M", 2_097_152),
    ]

    private let standardMaxTokens = [
        ("8K", 8_192),
        ("16K", 16_384),
        ("32K", 32_768),
        ("64K", 65_536),
        ("100K", 100_000),
    ]

    private let availableReasoningLevels = ["off", "low", "medium", "high", "xhigh", "max"]

    private var currentOfficialProfile: GatewayModelCapabilityProfile? {
        ModelCapabilityRegistry.officialProfile(for: modelID)
    }

    private var currentResolvedProfile: GatewayModelCapabilityProfile {
        let existing = settings.modelCapabilityOverrides[modelID]
            ?? settings.modelCapabilityOverrides[ModelCapabilityRegistry.normalizeModelSlug(modelID)]
        return ModelCapabilityRegistry.resolveCapability(for: modelID, override: existing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        Text("配置模型规格与推理能力")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    Text(modelName)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.codexMuted)
                }
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.codexMuted)
                }
                .buttonStyle(.plain)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 上下文长度
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("上下文窗口大小 (Context Window)")
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            if let official = currentOfficialProfile {
                                Text("官方基准: \(official.contextWindow)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.codexMuted)
                            }
                        }

                        // 档位选择胶囊按钮
                        HStack(spacing: 6) {
                            ForEach(standardContextWindows, id: \.1) { label, val in
                                let isSelected = !isCustomContextWindow && Int(contextWindowText) == val
                                Button {
                                    isCustomContextWindow = false
                                    contextWindowText = String(val)
                                } label: {
                                    Text(label)
                                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.codexMuted.opacity(0.08))
                                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                            }

                            Button {
                                isCustomContextWindow.toggle()
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 9))
                                    Text("自定义")
                                        .font(.system(size: 11, weight: isCustomContextWindow ? .semibold : .regular))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(isCustomContextWindow ? Color.accentColor.opacity(0.15) : Color.codexMuted.opacity(0.08))
                                .foregroundStyle(isCustomContextWindow ? Color.accentColor : Color.primary)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(isCustomContextWindow ? Color.accentColor : Color.clear, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        // 仅在点击自定义时展开输入框
                        if isCustomContextWindow {
                            HStack {
                                TextField("输入上下文 Token 数，例如 200000", text: $contextWindowText)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12, design: .monospaced))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(Color(nsColor: .textBackgroundColor))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.accentColor, lineWidth: 1.5)
                                    )
                            }
                            .padding(.horizontal, 3)
                            .padding(.vertical, 2)
                        }
                    }

                    // 最大输出 Tokens
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("最大输出 (Max Output Tokens)")
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            if let official = currentOfficialProfile {
                                Text("官方基准: \(official.maxTokens)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.codexMuted)
                            }
                        }

                        // 档位选择胶囊按钮
                        HStack(spacing: 6) {
                            ForEach(standardMaxTokens, id: \.1) { label, val in
                                let isSelected = !isCustomMaxTokens && Int(maxTokensText) == val
                                Button {
                                    isCustomMaxTokens = false
                                    maxTokensText = String(val)
                                } label: {
                                    Text(label)
                                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.codexMuted.opacity(0.08))
                                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                            }

                            Button {
                                isCustomMaxTokens.toggle()
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 9))
                                    Text("自定义")
                                        .font(.system(size: 11, weight: isCustomMaxTokens ? .semibold : .regular))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(isCustomMaxTokens ? Color.accentColor.opacity(0.15) : Color.codexMuted.opacity(0.08))
                                .foregroundStyle(isCustomMaxTokens ? Color.accentColor : Color.primary)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(isCustomMaxTokens ? Color.accentColor : Color.clear, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        // 仅在点击自定义时展开输入框
                        if isCustomMaxTokens {
                            HStack {
                                TextField("输入最大输出 Token 数，例如 32768", text: $maxTokensText)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12, design: .monospaced))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(Color(nsColor: .textBackgroundColor))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.accentColor, lineWidth: 1.5)
                                    )
                            }
                            .padding(.horizontal, 3)
                            .padding(.vertical, 2)
                        }
                    }

                    // 多模态图片支持
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: $supportsImage) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("支持图片多模态 (Vision / Image Input)")
                                    .font(.system(size: 12, weight: .medium))
                                Text("开启后，DSH 与外部客户端将允许向该模型发送图片附件")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Color.codexMuted)
                            }
                        }
                    }

                    Divider()

                    // 推理强度 / 思考模式配置
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: $hasReasoning) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("支持思考模式 / 推理强度调节 (Reasoning Effort)")
                                    .font(.system(size: 12, weight: .medium))
                                Text("启用后向客户端声明思考档位集，客户端（如 DSH）可展示思考调节滑块或选项")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Color.codexMuted)
                            }
                        }

                        if hasReasoning {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("可选推理档位：")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.codexMuted)

                                HStack(spacing: 10) {
                                    ForEach(availableReasoningLevels, id: \.self) { level in
                                        Button {
                                            if selectedReasoningLevels.contains(level) {
                                                selectedReasoningLevels.remove(level)
                                            } else {
                                                selectedReasoningLevels.insert(level)
                                            }
                                        } label: {
                                            HStack(spacing: 4) {
                                                Image(systemName: selectedReasoningLevels.contains(level) ? "checkmark.square.fill" : "square")
                                                Text(level)
                                            }
                                            .font(.system(size: 11))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }

                                HStack(spacing: 12) {
                                    Text("默认档位：")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(Color.codexMuted)

                                    Picker("", selection: $defaultReasoningLevel) {
                                        ForEach(Array(selectedReasoningLevels).sorted(), id: \.self) { lvl in
                                            Text(lvl).tag(lvl)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 120)
                                }
                            }
                            .padding(10)
                            .background(Color.codexBackground.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
            }

            Divider()

            // Footer actions
            HStack(spacing: 12) {
                Button("恢复官方推荐基准值") {
                    restoreOfficialDefaults()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11.5))

                Spacer()

                Button("取消") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("保存配置") {
                    saveOverride()
                    onSave()
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 520, height: 500)
        .onAppear {
            loadCurrent()
        }
    }

    private func loadCurrent() {
        let profile = currentResolvedProfile
        contextWindowText = String(profile.contextWindow)
        maxTokensText = String(profile.maxTokens)
        supportsImage = profile.supportsImage
        hasReasoning = !profile.reasoningLevels.isEmpty
        selectedReasoningLevels = Set(profile.reasoningLevels)
        defaultReasoningLevel = profile.defaultReasoningLevel ?? "off"

        // 判断当前值是否属于标准预设，如果不属于任何预设档位，则默认自动展开自定义输入框
        isCustomContextWindow = !standardContextWindows.contains { $0.1 == profile.contextWindow }
        isCustomMaxTokens = !standardMaxTokens.contains { $0.1 == profile.maxTokens }
    }

    private func restoreOfficialDefaults() {
        let official = currentOfficialProfile ?? GatewayModelCapabilityProfile(
            contextWindow: ModelCapabilityRegistry.fallbackContextWindow,
            maxTokens: ModelCapabilityRegistry.fallbackMaxTokens,
            supportsImage: false,
            reasoningLevels: []
        )
        contextWindowText = String(official.contextWindow)
        maxTokensText = String(official.maxTokens)
        supportsImage = official.supportsImage
        hasReasoning = !official.reasoningLevels.isEmpty
        selectedReasoningLevels = Set(official.reasoningLevels)
        defaultReasoningLevel = official.defaultReasoningLevel ?? "off"

        isCustomContextWindow = !standardContextWindows.contains { $0.1 == official.contextWindow }
        isCustomMaxTokens = !standardMaxTokens.contains { $0.1 == official.maxTokens }
    }

    private func saveOverride() {
        let cw = Int(contextWindowText.trimmingCharacters(in: .whitespacesAndNewlines))
        let mt = Int(maxTokensText.trimmingCharacters(in: .whitespacesAndNewlines))
        let levels = hasReasoning ? Array(selectedReasoningLevels).sorted() : []
        let defLevel = hasReasoning ? defaultReasoningLevel : nil

        let override = GatewayModelCapabilityOverride(
            modelID: modelID,
            contextWindow: cw,
            maxTokens: mt,
            supportsImage: supportsImage,
            reasoningLevels: levels,
            defaultReasoningLevel: defLevel
        )
        settings.modelCapabilityOverrides[modelID] = override
        // 同时存一份纯 slug 的，确保规范化时能命中
        let slug = ModelCapabilityRegistry.normalizeModelSlug(modelID)
        settings.modelCapabilityOverrides[slug] = override
    }
}
