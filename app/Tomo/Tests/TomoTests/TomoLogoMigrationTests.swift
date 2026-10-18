import Foundation
import Testing
@testable import Tomo

struct TomoLogoMigrationTests {
    @Test("Old logo families migrate to T while preserving appearance settings")
    func legacySettings() throws {
        for family in ["circle", "hex", "squircle", "cloud7", "quota", "unknown"] {
            let data = try JSONSerialization.data(withJSONObject: [
                "logoFamily": family, "logoContent": "percent", "accentColor": "#D74C32",
                "materialTexture": "glass", "glassOpacity": 0.73, "logoScale": 0.84
            ])
            let config = try JSONDecoder().decode(TomoThemeConfig.self, from: data)
            #expect(config.logoFamily == "pure")
            #expect(config.logoContent == "t")
            #expect(config.accentColor == "#D74C32")
            #expect(config.glassOpacity == 0.73)
            #expect(config.logoScale == 0.84)
            let svg = TomoMarkSvgRenderer.svgString(config: config)
            #expect(svg.contains("scale(1.36)"))
        }
    }

    @Test("T+Go survives round trips and legacy direct renderer calls produce T")
    func supportedSettings() throws {
        let config = TomoThemeConfig(logoFamily: "pure_go")
        let restored = try JSONDecoder().decode(TomoThemeConfig.self, from: JSONEncoder().encode(config))
        #expect(restored.logoFamily == "pure_go")
        #expect(TomoMarkSvgRenderer.svgString(config: restored).contains("tomo-go-mask"))
        #expect(TomoThemeConfig.default.logoFamily == "pure")
        let oldSVG = TomoMarkSvgRenderer.svgString(family: "quota", logoContent: "percent", notch: false, accentColor: "#007AFF")
        #expect(oldSVG.contains("scale(1.36)"))
        #expect(!oldSVG.contains("tomo-go-mask"))
    }
}
