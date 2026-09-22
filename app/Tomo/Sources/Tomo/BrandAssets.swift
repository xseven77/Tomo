import AppKit
import SwiftUI

enum BrandAssetID: String, Sendable {
    case codex
    case hermesAgent = "hermes-agent"
    case piAgent = "pi-agent"
    case deepSeek = "deepseek"
    case openCode = "opencode"
    case antigravity = "antigravity"
    case googleGemini = "google-gemini"
    case geminiCLI = "gemini-cli"

    static func agent(_ id: AgentID) -> BrandAssetID {
        switch id {
        case .codex: .codex
        case .hermes: .hermesAgent
        case .deepseekHarness: .deepSeek
        case .antigravity: .antigravity
        case .pi: .piAgent
        default: .codex
        }
    }

    static func provider(_ id: ProviderID) -> BrandAssetID {
        switch id {
        case .deepSeek: .deepSeek
        case .openCodeGo, .openCodeZen: .openCode
        case .gemini: .googleGemini
        default: .codex
        }
    }
}

enum BrandAssetCatalog {
    static func image(for id: BrandAssetID, prefersColor: Bool = true) -> NSImage? {
        guard let root = Bundle.main.resourceURL?
            .appendingPathComponent("BrandAssets/catalog", isDirectory: true)
            .appendingPathComponent(id.rawValue, isDirectory: true) else { return nil }
        // Codex, Hermes, Antigravity, and Google Gemini use official raster exports
        let candidates: [String]
        if (id == .codex || id == .hermesAgent || id == .piAgent || id == .antigravity || id == .googleGemini), prefersColor {
            candidates = ["app-icon.png", "color.svg", "icon.svg"]
        } else {
            candidates = prefersColor
                ? ["color.svg", "icon.svg", "app-icon.png"]
                : ["icon.svg", "color.svg", "app-icon.png"]
        }
        for file in candidates {
            let url = root.appendingPathComponent(file)
            if let image = NSImage(contentsOf: url) { return image }
        }
        return nil
    }
}

struct BrandIconView: View {
    let asset: BrandAssetID
    var size: CGFloat = 38
    var cornerRadius: CGFloat = 10

    var body: some View {
        Group {
            if let image = BrandAssetCatalog.image(for: asset) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(contentInset)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(Color.codexMuted)
            }
        }
        .frame(width: size, height: size)
        .background(Color.white, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.codexLine.opacity(0.75), lineWidth: 0.7)
        }
        .accessibilityHidden(true)
    }

    private var contentInset: CGFloat {
        // Raster-first icons already include a white tile and optical
        // padding, so the generic inset would make their artwork too small.
        switch asset {
        case .codex, .hermesAgent, .piAgent, .antigravity, .googleGemini:
            size * 0.10
        case .deepSeek, .openCode, .geminiCLI:
            size * 0.16
        }
    }
}
