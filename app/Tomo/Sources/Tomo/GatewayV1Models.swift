import Foundation
import AppKit

public struct GatewayV1ModelItem: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String?
    public let displayName: String?
    public let object: String?
    public let created: Int64?
    public let provider: String?
    public let ownedBy: String?
    public let account: String?
    public let permissionTier: String?
    public let quotaRemaining: String?
    public let description: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case displayName = "display_name"
        case object
        case created
        case provider
        case ownedBy = "owned_by"
        case account
        case permissionTier = "permission_tier"
        case quotaRemaining = "quota_remaining"
        case description
    }

    public init(
        id: String,
        name: String? = nil,
        displayName: String? = nil,
        object: String? = "model",
        created: Int64? = nil,
        provider: String? = nil,
        ownedBy: String? = nil,
        account: String? = nil,
        permissionTier: String? = nil,
        quotaRemaining: String? = nil,
        description: String? = nil
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.object = object
        self.created = created
        self.provider = provider
        self.ownedBy = ownedBy
        self.account = account
        self.permissionTier = permissionTier
        self.quotaRemaining = quotaRemaining
        self.description = description
    }

    public var effectiveDisplayName: String {
        if let dn = displayName, !dn.isEmpty { return dn }
        if let n = name, !n.isEmpty { return n }
        return id
    }

    public var effectiveProvider: String {
        if let p = provider, !p.isEmpty { return p }
        if let o = ownedBy, !o.isEmpty {
            switch o.lowercased() {
            case "openai": return "OpenAI / Codex"
            case "google": return "Google Gemini"
            case "deepseek": return "DeepSeek 官方"
            case "opencode": return "OpenCode 聚合平台"
            default: return o.capitalized
            }
        }
        let prefix = id.components(separatedBy: "/").first ?? ""
        switch prefix.lowercased() {
        case "openai": return "OpenAI / Codex"
        case "google": return "Google Gemini"
        case "deepseek": return "DeepSeek 官方"
        case "opencode": return "OpenCode 聚合平台"
        default: return prefix.capitalized
        }
    }

    public var providerColor: NSColor {
        let p = effectiveProvider.lowercased()
        if p.contains("openai") || p.contains("codex") {
            return NSColor(red: 0.06, green: 0.65, blue: 0.53, alpha: 1.0)
        } else if p.contains("google") || p.contains("gemini") {
            return NSColor(red: 0.26, green: 0.52, blue: 0.96, alpha: 1.0)
        } else if p.contains("deepseek") {
            return NSColor(red: 0.18, green: 0.44, blue: 0.95, alpha: 1.0)
        } else if p.contains("opencode") {
            return NSColor(red: 0.85, green: 0.45, blue: 0.12, alpha: 1.0)
        }
        return NSColor.systemGray
    }
}

public struct GatewayV1ModelsResponse: Codable, Sendable {
    public let object: String?
    public let data: [GatewayV1ModelItem]

    public init(object: String? = "list", data: [GatewayV1ModelItem] = []) {
        self.object = object
        self.data = data
    }
}
