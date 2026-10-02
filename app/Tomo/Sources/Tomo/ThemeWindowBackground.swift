import SwiftUI

/// Shared backdrop for the settings and Gateway windows.
struct ThemeWindowBackground: View {
    let accentHex: String
    let isDark: Bool

    private var preset: TomoChromePresetColor {
        TomoThemeConstants.chromePresetColors.first {
            !$0.isCustom && $0.seedHex.caseInsensitiveCompare(accentHex) == .orderedSame
        } ?? TomoChromePresetColor(
            id: "custom", name: "自定义主题", seedHex: accentHex,
            lightFg: TomoThemeConstants.computeAutoGradient(startHex: accentHex, algo: "subtle"),
            lightBg: accentHex, lightBase: "#F4F5F7",
            darkFg: "#1E293B", darkBg: accentHex, darkBase: "#181D24", isCustom: true
        )
    }

    var body: some View {
        let base = Color(hex: isDark ? preset.darkBase : preset.lightBase)
        ZStack {
            base.ignoresSafeArea()
            LinearGradient(
                colors: [Color(hex: isDark ? preset.darkFg : preset.lightFg).opacity(0.45),
                         base.opacity(0.12), .clear],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 260)
            .frame(maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
        }
    }
}
