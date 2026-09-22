import Foundation

/// 预置的官方大模型能力规格基准。
/// 参考 cc-switch 与各大厂商官方 API 文档。
public struct GatewayModelCapabilityProfile: Equatable, Sendable {
    public let contextWindow: Int
    public let maxTokens: Int
    public let supportsImage: Bool
    public let reasoningLevels: [String]
    public let defaultReasoningLevel: String?

    public init(
        contextWindow: Int,
        maxTokens: Int,
        supportsImage: Bool,
        reasoningLevels: [String] = [],
        defaultReasoningLevel: String? = nil
    ) {
        self.contextWindow = contextWindow
        self.maxTokens = maxTokens
        self.supportsImage = supportsImage
        self.reasoningLevels = reasoningLevels
        self.defaultReasoningLevel = defaultReasoningLevel
    }
}

/// 模型能力白名单注册表。
/// 严禁模糊匹配（如 contains("gemini")），必须使用精确归一化后的模型 tail slug 匹配。
public enum ModelCapabilityRegistry {
    public static let fallbackContextWindow = 131_072
    public static let fallbackMaxTokens = 16_384

    /// 规范化的思考档位映射
    public static let canonicalReasoningLevels: [String] = [
        "off", "low", "medium", "high", "xhigh", "max"
    ]

    /// 官方确认支持推理调节的模型规格白名单
    /// Key 为小写规范化的 model slug（不带 provider 前缀与账号后缀）
    private static let officialProfiles: [String: GatewayModelCapabilityProfile] = [
        // MARK: - Google Gemini
        "gemini-2.5-pro": GatewayModelCapabilityProfile(
            contextWindow: 1_048_576,
            maxTokens: 65_536,
            supportsImage: true,
            reasoningLevels: ["off", "low", "medium", "high"],
            defaultReasoningLevel: "off"
        ),
        "gemini-2.5-flash": GatewayModelCapabilityProfile(
            contextWindow: 1_048_576,
            maxTokens: 65_536,
            supportsImage: true,
            reasoningLevels: ["off", "low", "medium", "high"],
            defaultReasoningLevel: "off"
        ),
        "gemini-2.5-flash-thinking": GatewayModelCapabilityProfile(
            contextWindow: 1_048_576,
            maxTokens: 65_536,
            supportsImage: true,
            reasoningLevels: ["low", "medium", "high"],
            defaultReasoningLevel: "medium"
        ),
        "gemini-3.1-pro-low": GatewayModelCapabilityProfile(
            contextWindow: 1_048_576,
            maxTokens: 65_536,
            supportsImage: true,
            reasoningLevels: ["low"],
            defaultReasoningLevel: "low"
        ),
        "gemini-3.6-flash-high": GatewayModelCapabilityProfile(
            contextWindow: 1_048_576,
            maxTokens: 65_536,
            supportsImage: true,
            reasoningLevels: ["high"],
            defaultReasoningLevel: "high"
        ),
        "gemini-3.8-flash-tiered": GatewayModelCapabilityProfile(
            contextWindow: 1_048_576,
            maxTokens: 65_536,
            supportsImage: true,
            reasoningLevels: ["off", "low", "medium", "high"],
            defaultReasoningLevel: "off"
        ),

        // MARK: - Anthropic Claude
        "claude-3-7-sonnet": GatewayModelCapabilityProfile(
            contextWindow: 200_000,
            maxTokens: 64_000,
            supportsImage: true,
            reasoningLevels: ["off", "low", "medium", "high", "max"],
            defaultReasoningLevel: "off"
        ),
        "claude-sonnet-4-6": GatewayModelCapabilityProfile(
            contextWindow: 200_000,
            maxTokens: 64_000,
            supportsImage: true,
            reasoningLevels: ["off", "low", "medium", "high"],
            defaultReasoningLevel: "off"
        ),
        "claude-3-5-sonnet": GatewayModelCapabilityProfile(
            contextWindow: 200_000,
            maxTokens: 8_192,
            supportsImage: true,
            reasoningLevels: [] // 纯指令模型，官方无 effort 档位
        ),
        "claude-3-5-haiku": GatewayModelCapabilityProfile(
            contextWindow: 200_000,
            maxTokens: 8_192,
            supportsImage: false,
            reasoningLevels: []
        ),
        "claude-opus-4-6-thinking": GatewayModelCapabilityProfile(
            contextWindow: 200_000,
            maxTokens: 32_768,
            supportsImage: true,
            reasoningLevels: ["low", "medium", "high"],
            defaultReasoningLevel: "medium"
        ),

        // MARK: - OpenAI
        "gpt-5.5": GatewayModelCapabilityProfile(
            contextWindow: 262_144,
            maxTokens: 65_536,
            supportsImage: true,
            reasoningLevels: ["low", "medium", "high", "xhigh"],
            defaultReasoningLevel: "medium"
        ),
        "gpt-5.6-sol": GatewayModelCapabilityProfile(
            contextWindow: 262_144,
            maxTokens: 65_536,
            supportsImage: true,
            reasoningLevels: ["low", "medium", "high", "xhigh"],
            defaultReasoningLevel: "medium"
        ),
        "gpt-5.6-luna": GatewayModelCapabilityProfile(
            contextWindow: 262_144,
            maxTokens: 65_536,
            supportsImage: true,
            reasoningLevels: ["low", "medium", "high"],
            defaultReasoningLevel: "medium"
        ),
        "o3": GatewayModelCapabilityProfile(
            contextWindow: 200_000,
            maxTokens: 100_000,
            supportsImage: true,
            reasoningLevels: ["low", "medium", "high"],
            defaultReasoningLevel: "medium"
        ),
        "o3-mini": GatewayModelCapabilityProfile(
            contextWindow: 200_000,
            maxTokens: 100_000,
            supportsImage: false,
            reasoningLevels: ["low", "medium", "high"],
            defaultReasoningLevel: "medium"
        ),
        "o1": GatewayModelCapabilityProfile(
            contextWindow: 200_000,
            maxTokens: 100_000,
            supportsImage: true,
            reasoningLevels: ["low", "medium", "high"],
            defaultReasoningLevel: "medium"
        ),
        "gpt-4o": GatewayModelCapabilityProfile(
            contextWindow: 128_000,
            maxTokens: 16_384,
            supportsImage: true,
            reasoningLevels: []
        ),
        "gpt-4.5": GatewayModelCapabilityProfile(
            contextWindow: 128_000,
            maxTokens: 16_384,
            supportsImage: true,
            reasoningLevels: []
        ),

        // MARK: - DeepSeek
        "deepseek-chat": GatewayModelCapabilityProfile(
            contextWindow: 131_072,
            maxTokens: 8_192,
            supportsImage: false,
            reasoningLevels: []
        ),
        "deepseek-reasoner": GatewayModelCapabilityProfile(
            contextWindow: 131_072,
            maxTokens: 8_192,
            supportsImage: false,
            reasoningLevels: [] // 官方原生思维链固定输出，不支持 effort 参数
        ),
        "deepseek-v4-flash": GatewayModelCapabilityProfile(
            contextWindow: 1_048_576,
            maxTokens: 32_768,
            supportsImage: false,
            reasoningLevels: ["low", "high"],
            defaultReasoningLevel: "high"
        ),
        "deepseek-v4-pro": GatewayModelCapabilityProfile(
            contextWindow: 1_048_576,
            maxTokens: 32_768,
            supportsImage: false,
            reasoningLevels: ["low", "high"],
            defaultReasoningLevel: "high"
        ),

        // MARK: - Moonshot Kimi
        "kimi-k2.5": GatewayModelCapabilityProfile(
            contextWindow: 262_144,
            maxTokens: 16_384,
            supportsImage: false,
            reasoningLevels: []
        ),
        "kimi-k2.6": GatewayModelCapabilityProfile(
            contextWindow: 262_144,
            maxTokens: 32_768,
            supportsImage: false,
            reasoningLevels: ["off", "high"],
            defaultReasoningLevel: "high"
        ),

        // MARK: - MiniMax & Xiaomi MiMo
        "minimax-m2.7": GatewayModelCapabilityProfile(
            contextWindow: 1_000_000,
            maxTokens: 16_384,
            supportsImage: false,
            reasoningLevels: []
        ),
        "mimo-v2.5-pro": GatewayModelCapabilityProfile(
            contextWindow: 262_144,
            maxTokens: 16_384,
            supportsImage: false,
            reasoningLevels: []
        ),

        // MARK: - Zhipu GLM
        "glm-5.1": GatewayModelCapabilityProfile(
            contextWindow: 131_072,
            maxTokens: 8_192,
            supportsImage: false,
            reasoningLevels: []
        ),
        "glm-5.2": GatewayModelCapabilityProfile(
            contextWindow: 131_072,
            maxTokens: 8_192,
            supportsImage: false,
            reasoningLevels: []
        ),
        "glm-5.3": GatewayModelCapabilityProfile(
            contextWindow: 131_072,
            maxTokens: 8_192,
            supportsImage: false,
            reasoningLevels: []
        ),
        "glm-5.2v": GatewayModelCapabilityProfile(
            contextWindow: 131_072,
            maxTokens: 8_192,
            supportsImage: true,
            reasoningLevels: []
        )
    ]

    /// 提取规范化的纯模型 slug
    public static func normalizeModelSlug(_ rawID: String) -> String {
        var slug = rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // 去除 provider 前缀，如 "google/gemini-2.5-flash" -> "gemini-2.5-flash"
        if let lastSlash = slug.split(separator: "/").last {
            slug = String(lastSlash)
        }
        // 去除 account 范围后缀，如 "gemini-2.5-flash@account-1" -> "gemini-2.5-flash"
        if let atIndex = slug.firstIndex(of: "@") {
            slug = String(slug[..<atIndex])
        }
        // 去除点前缀或 Hermes label 前缀，如 "Google·gemini-2.5-flash"
        if let dotIndex = slug.split(separator: "·").last {
            slug = String(dotIndex).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return slug
    }

    /// 查找官方预置规格
    public static func officialProfile(for rawID: String) -> GatewayModelCapabilityProfile? {
        let slug = normalizeModelSlug(rawID)
        return officialProfiles[slug]
    }

    /// 综合解析模型能力：
    /// 优先级：用户自定义覆盖（override） > 官方白名单推荐 > 安全保守兜底
    public static func resolveCapability(
        for rawID: String,
        override: GatewayModelCapabilityOverride?
    ) -> GatewayModelCapabilityProfile {
        let official = officialProfile(for: rawID)
        let slug = normalizeModelSlug(rawID)

        // 上下文窗口
        let contextWindow = override?.contextWindow
            ?? official?.contextWindow
            ?? fallbackContextWindow

        // 最大输出
        let maxTokens = override?.maxTokens
            ?? official?.maxTokens
            ?? fallbackMaxTokens

        // 图片多模态支持
        let supportsImage: Bool
        if let userImg = override?.supportsImage {
            supportsImage = userImg
        } else if let offImg = official?.supportsImage {
            supportsImage = offImg
        } else {
            // 保守判断：若带有 -vl / vision 或 qwen-vl 显式标记则支持，否则默认 false
            supportsImage = slug.contains("-vl") || slug.contains("vision") || slug.contains("vl-") || slug.contains("qwen3-vl")
        }

        // 推理档位支持
        let reasoningLevels: [String]
        let defaultReasoningLevel: String?
        if let userLevels = override?.reasoningLevels {
            reasoningLevels = userLevels
            defaultReasoningLevel = override?.defaultReasoningLevel
        } else if let offProfile = official {
            reasoningLevels = offProfile.reasoningLevels
            defaultReasoningLevel = offProfile.defaultReasoningLevel
        } else {
            reasoningLevels = []
            defaultReasoningLevel = nil
        }

        return GatewayModelCapabilityProfile(
            contextWindow: contextWindow,
            maxTokens: maxTokens,
            supportsImage: supportsImage,
            reasoningLevels: reasoningLevels,
            defaultReasoningLevel: defaultReasoningLevel
        )
    }
}
