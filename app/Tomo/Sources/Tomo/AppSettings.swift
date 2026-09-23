import AppKit
import Observation
import ServiceManagement
import SwiftUI

enum AppThemePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var symbolName: String {
        switch self {
        case .system: "desktopcomputer"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system:
            nil
        case .light:
            NSAppearance(named: .aqua)
        case .dark:
            NSAppearance(named: .darkAqua)
        }
    }

    /// Drives SwiftUI `colorScheme` inside popovers/windows where AppKit appearance alone is not enough.
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }

    func resolvedColorScheme(system: ColorScheme) -> ColorScheme {
        preferredColorScheme ?? system
    }
}

enum AutoRefreshInterval: Int, CaseIterable, Identifiable {
    case seconds30 = 30
    case minutes1 = 60
    case minutes2 = 120
    case minutes5 = 300
    case minutes10 = 600
    case off = 0

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .seconds30: "30 秒"
        case .minutes1: "1 分钟"
        case .minutes2: "2 分钟"
        case .minutes5: "5 分钟"
        case .minutes10: "10 分钟"
        case .off: "关闭"
        }
    }

    var timeInterval: TimeInterval? {
        rawValue > 0 ? TimeInterval(rawValue) : nil
    }
}

/// 主界面账号 logo 行的自动轮播间隔。关闭时只响应手动选择。
enum AccountCarouselInterval: Int, CaseIterable, Identifiable {
    case off = 0
    case seconds5 = 5
    case seconds10 = 10
    case seconds30 = 30
    case minutes1 = 60

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .off: "关闭"
        case .seconds5: "5 秒"
        case .seconds10: "10 秒"
        case .seconds30: "30 秒"
        case .minutes1: "1 分钟"
        }
    }

    var timeInterval: TimeInterval? {
        rawValue > 0 ? TimeInterval(rawValue) : nil
    }
}

enum StatusBarPetBackgroundColor: String, CaseIterable, Identifiable {
    case neutral
    case automatic
    case green
    case yellow
    case red
    case gray

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "跟随额度"
        case .neutral: "中性"
        case .green: "绿色"
        case .yellow: "黄色"
        case .red: "红色"
        case .gray: "灰色"
        }
    }

    var symbolName: String {
        switch self {
        case .automatic: "wand.and.stars"
        case .neutral: "circle.lefthalf.filled"
        case .green, .yellow, .red, .gray: "circle.fill"
        }
    }

    func resolved(for health: QuotaHealthLevel) -> Self {
        guard self == .automatic else { return self }
        return switch health {
        case .gray: .gray
        case .green: .green
        case .yellow: .yellow
        case .red: .red
        }
    }

    func foregroundColor(for colorScheme: ColorScheme) -> NSColor {
        switch self {
        case .automatic, .neutral:
            .labelColor
        case .green:
            QuotaHealthLevel.green.nsColor
        case .yellow:
            QuotaHealthLevel.yellow.nsColor
        case .red:
            QuotaHealthLevel.red.nsColor
        case .gray:
            colorScheme == .dark
                ? NSColor(red: 0.620, green: 0.645, blue: 0.680, alpha: 1)
                : NSColor(red: 0.357, green: 0.397, blue: 0.447, alpha: 1)
        }
    }

    var foregroundColor: NSColor { foregroundColor(for: .light) }
}

/// 主界面的排布方向。竖向把宠物移到顶部，窗口收窄到 330pt。
enum DashboardOrientation: String, CaseIterable, Identifiable {
    case horizontal
    case vertical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .horizontal: "横向"
        case .vertical: "竖向"
        }
    }

    var symbolName: String {
        switch self {
        case .horizontal: "rectangle.split.2x1"
        case .vertical: "rectangle.split.1x2"
        }
    }
}

/// 曾连接过的显示器硬件元信息记录。
struct KnownDisplayRecord: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let isBuiltin: Bool
    var lastSeen: Date
}

/// 刘海面板出现的目标显示器。
/// 选项由系统 `NSScreen.screens` 动态提供（具体硬件显示器 + 所有显示器 + 关闭）。
enum NotchDisplayTarget: Hashable, Sendable {
    case off
    case allDisplays
    case specificDisplay(String)

    var storageString: String {
        switch self {
        case .off: "off"
        case .allDisplays: "all"
        case .specificDisplay(let id): id
        }
    }

    static func fromStorage(_ string: String) -> NotchDisplayTarget {
        switch string {
        case "off": return .off
        case "all": return .allDisplays
        default: return .specificDisplay(string)
        }
    }

    var title: String {
        switch self {
        case .off: "所有显示器都不开刘海"
        case .allDisplays: "所有显示器"
        case .specificDisplay: "指定显示器"
        }
    }
}

extension NotchDisplayTarget: Identifiable {
    public var id: String { storageString }
}

// MARK: - Tomo Theme & Logo Configuration

public struct TomoThemeConfig: Codable, Equatable, Sendable {
    public var logoFamily: String // "hex" | "circle" | "squircle" | "cloud7" | "quota"
    public var notchMode: String  // "off" | "on"
    public var glyphMode: String  // "solid" (纯白防干扰) | "cutout" (真实镂空)
    public var fillType: String   // "solid" | "gradient"
    public var gradientAlgo: String // "vibrant" | "subtle" | "deep"
    public var gradientAngle: Int // 45 | 90 | 135 | 180
    public var accentColor: String // e.g. "#D74C32"
    public var accentEndColor: String? // e.g. "#FF8838"
    public var tileBgColor: String // e.g. "#FFFFFF"
    public var renderMode: String // "color" | "mono" | "inverse"
    public var shadowEnabled: Bool // 主体流体阴影开关
    public var shadowStyle: String // "tight" (微距 Telegram 款) | "soft" (柔和)
    public var updatedAt: Double // timestamp in ms

    public init(
        logoFamily: String = "hex",
        notchMode: String = "off",
        glyphMode: String = "solid",
        fillType: String = "solid",
        gradientAlgo: String = "vibrant",
        gradientAngle: Int = 135,
        accentColor: String = "#D74C32",
        accentEndColor: String? = nil,
        tileBgColor: String = "#FFFFFF",
        renderMode: String = "color",
        shadowEnabled: Bool = true,
        shadowStyle: String = "tight",
        updatedAt: Double = Date().timeIntervalSince1970 * 1000
    ) {
        self.logoFamily = logoFamily
        self.notchMode = notchMode
        self.glyphMode = glyphMode
        self.fillType = fillType
        self.gradientAlgo = gradientAlgo
        self.gradientAngle = gradientAngle
        self.accentColor = accentColor
        self.accentEndColor = accentEndColor ?? TomoThemeConstants.computeAutoGradient(startHex: accentColor, algo: gradientAlgo)
        self.tileBgColor = tileBgColor
        self.renderMode = renderMode
        self.shadowEnabled = shadowEnabled
        self.shadowStyle = shadowStyle
        self.updatedAt = updatedAt
    }

    public static let `default` = TomoThemeConfig()

    public func asDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "logoFamily": logoFamily,
            "notchMode": notchMode,
            "glyphMode": glyphMode,
            "fillType": fillType,
            "gradientAlgo": gradientAlgo,
            "gradientAngle": gradientAngle,
            "accentColor": accentColor,
            "tileBgColor": tileBgColor,
            "renderMode": renderMode,
            "shadowEnabled": shadowEnabled,
            "shadowStyle": shadowStyle,
            "updatedAt": updatedAt
        ]
        if let accentEndColor { dict["accentEndColor"] = accentEndColor }
        return dict
    }
}

public struct TomoPresetColor: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let hex: String
    public let note: String

    public init(id: String, name: String, hex: String, note: String) {
        self.id = id
        self.name = name
        self.hex = hex
        self.note = note
    }
}

public enum TomoThemeConstants {
    public static let presetColors: [TomoPresetColor] = [
        .init(id: "red-orange", name: "经典红橙", hex: "#D74C32", note: "Tokomi 额度章经典红橙"),
        .init(id: "electric-blue", name: "克莱因电蓝", hex: "#2358E8", note: "AI / 终端科技电蓝"),
        .init(id: "deep-purple", name: "伴侣深紫", hex: "#7042E8", note: "04 伴随屏原版基底紫"),
        .init(id: "turq-green", name: "终端松石绿", hex: "#09866F", note: "健康配额与运行绿"),
        .init(id: "coral-orange", name: "日光珊瑚橙", hex: "#F05A28", note: "明亮高饱和暖色"),
        .init(id: "aurora-indigo", name: "极光靛青", hex: "#5542E0", note: "现代生产力工具调性"),
        .init(id: "night-cyan", name: "暗夜青绿", hex: "#0E7C86", note: "数码设备与清爽终端"),
        .init(id: "obsidian-black", name: "曜石灰黑", hex: "#24272C", note: "硬核极客实体印章"),
    ]

    public static let presetTileBgColors: [TomoPresetColor] = [
        .init(id: "pure-white", name: "纯白", hex: "#FFFFFF", note: "iOS 官方标准纯白底板"),
        .init(id: "light-gray", name: "浅灰", hex: "#F2F3F5", note: "macOS 极简浅灰界面"),
        .init(id: "warm-white", name: "暖白", hex: "#F7F5F0", note: "柔和日系纸质暖白"),
        .init(id: "oatmeal", name: "燕麦", hex: "#EAE7DF", note: "自然质感燕麦米"),
        .init(id: "mist-blue", name: "雾蓝", hex: "#E8EFF8", note: "科技冷调清新浅蓝"),
        .init(id: "dark-gray", name: "深灰", hex: "#2A2C30", note: "深色系统质感灰"),
        .init(id: "charcoal", name: "炭黑", hex: "#1E1F22", note: "沉浸极客炭黑"),
        .init(id: "midnight", name: "极夜", hex: "#121315", note: "OLED 极夜纯黑"),
    ]

    public static func hexToHsl(_ hex: String) -> (h: Double, s: Double, l: Double) {
        var clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if clean.count == 3 {
            clean = clean.map { "\($0)\($0)" }.joined()
        }
        guard let num = UInt64(clean, radix: 16) else { return (0, 0, 0) }
        let r = Double((num >> 16) & 255) / 255.0
        let g = Double((num >> 8) & 255) / 255.0
        let b = Double(num & 255) / 255.0
        let maxVal = max(r, max(g, b))
        let minVal = min(r, min(g, b))
        var h: Double = 0
        var s: Double = 0
        let l = (maxVal + minVal) / 2.0
        if maxVal != minVal {
            let d = maxVal - minVal
            s = l > 0.5 ? d / (2.0 - maxVal - minVal) : d / (maxVal + minVal)
            if maxVal == r {
                h = (g - b) / d + (g < b ? 6.0 : 0.0)
            } else if maxVal == g {
                h = (b - r) / d + 2.0
            } else {
                h = (r - g) / d + 4.0
            }
            h /= 6.0
        }
        return (h * 360.0, s * 100.0, l * 100.0)
    }

    public static func hslToHex(h: Double, s: Double, l: Double) -> String {
        let normH = ((h.truncatingRemainder(dividingBy: 360.0)) + 360.0).truncatingRemainder(dividingBy: 360.0)
        let normS = max(0, min(100, s)) / 100.0
        let normL = max(0, min(100, l)) / 100.0
        let c = (1.0 - abs(2.0 * normL - 1.0)) * normS
        let x = c * (1.0 - abs((normH / 60.0).truncatingRemainder(dividingBy: 2.0) - 1.0))
        let m = normL - c / 2.0
        var r: Double = 0, g: Double = 0, b: Double = 0
        if normH < 60 { r = c; g = x; b = 0 }
        else if normH < 120 { r = x; g = c; b = 0 }
        else if normH < 180 { r = 0; g = c; b = x }
        else if normH < 240 { r = 0; g = x; b = c }
        else if normH < 300 { r = x; g = 0; b = c }
        else { r = c; g = 0; b = x }
        let redByte = Int(round((r + m) * 255.0))
        let greenByte = Int(round((g + m) * 255.0))
        let blueByte = Int(round((b + m) * 255.0))
        return String(format: "#%02X%02X%02X", redByte, greenByte, blueByte)
    }

    public static func computeAutoGradient(startHex: String, algo: String = "vibrant") -> String {
        let (h, s, l) = hexToHsl(startHex)
        if s < 14 {
            if algo == "subtle" { return hslToHex(h: h, s: s, l: min(85, l + 18)) }
            if algo == "deep" { return hslToHex(h: h, s: min(30, s + 10), l: max(10, l - 12)) }
            return hslToHex(h: h, s: min(35, s + 12), l: min(80, l + 26))
        }
        if algo == "subtle" {
            let targetL = l >= 45 ? min(82, l + 15) : min(75, l + 22)
            let targetS = min(100, max(20, s + 2))
            return hslToHex(h: h, s: targetS, l: targetL)
        }
        if algo == "deep" {
            let targetH = (h + 38.0).truncatingRemainder(dividingBy: 360.0)
            let targetL = max(22, l - 15)
            let targetS = min(100, s + 8)
            return hslToHex(h: targetH, s: targetS, l: targetL)
        }
        // vibrant
        var hueDelta = 22.0
        var lightDelta = 10.0
        let satDelta = 4.0
        if h >= 340 || h < 25 {
            hueDelta = 20.0
            lightDelta = 12.0
        } else if h >= 25 && h < 65 {
            hueDelta = 14.0
            lightDelta = 8.0
        } else if h >= 65 && h < 165 {
            hueDelta = 26.0
            lightDelta = 10.0
        } else if h >= 165 && h < 210 {
            hueDelta = 28.0
            lightDelta = 8.0
        } else if h >= 210 && h < 260 {
            hueDelta = 32.0
            lightDelta = 8.0
        } else if h >= 260 && h < 310 {
            hueDelta = 28.0
            lightDelta = 8.0
        } else {
            hueDelta = 24.0
            lightDelta = 10.0
        }
        let targetH = (h + hueDelta).truncatingRemainder(dividingBy: 360.0)
        let targetS = min(100, s + satDelta)
        let targetL = min(72, max(30, l + lightDelta))
        return hslToHex(h: targetH, s: targetS, l: targetL)
    }
}

enum StatusCapsuleColorMode: String, CaseIterable, Identifiable {
    case activityState
    case quotaHealth
    case purple
    case blue
    case cyan
    case orange
    case green
    case red

    var id: String { rawValue }

    static var activityFlowCases: [Self] {
        allCases.filter { $0 != .quotaHealth }
    }

    var title: String {
        switch self {
        case .activityState: "跟随任务状态"
        case .quotaHealth: "跟随额度状态"
        case .purple: "紫色"
        case .blue: "蓝色"
        case .cyan: "青色"
        case .orange: "橙色"
        case .green: "绿色"
        case .red: "红色"
        }
    }

    var swatchColor: Color {
        Color(nsColor: previewNSColor)
    }

    private var previewNSColor: NSColor {
        switch self {
        case .activityState, .purple:
            NSColor(red: 0.478, green: 0.259, blue: 0.961, alpha: 1)
        case .quotaHealth, .green:
            NSColor(red: 0.122, green: 0.647, blue: 0.353, alpha: 1)
        case .blue:
            NSColor(red: 0.180, green: 0.420, blue: 1.000, alpha: 1)
        case .cyan:
            NSColor(red: 0.020, green: 0.631, blue: 0.800, alpha: 1)
        case .orange:
            NSColor(red: 0.949, green: 0.451, blue: 0.078, alpha: 1)
        case .red:
            NSColor(red: 0.929, green: 0.220, blue: 0.302, alpha: 1)
        }
    }

    func resolvedNSColor(
        activityState: CodexActivityState,
        quotaHealth: QuotaHealthLevel
    ) -> NSColor? {
        switch self {
        case .activityState:
            activityState.statusNSColor
        case .quotaHealth:
            quotaHealth.nsColor
        case .purple, .blue, .cyan, .orange, .green, .red:
            previewNSColor
        }
    }
}

@MainActor
@Observable
final class AppSettingsStore {
    private enum Keys {
        static let silentLaunchEnabled = "tomo.silentLaunchEnabled"
        static let theme = "tomo.theme"
        static let autoRefreshInterval = "tomo.autoRefreshInterval"
        static let accountCarouselInterval = "tomo.accountCarouselInterval"
        static let mainWindowProviderCarouselEnabled = "tomo.mainWindowProviderCarouselEnabled"
        static let notchProviderCarouselEnabled = "tomo.notchProviderCarouselEnabled"
        static let petsEnabled = "tomo.petsEnabled"
        static let standalonePetEnabled = "tomo.standalonePetEnabled"
        static let standalonePetEdge = "tomo.standalonePetEdge"
        static let standalonePetScale = "tomo.standalonePetScale"
        static let standalonePetFreeX = "tomo.standalonePetFreeX"
        static let standalonePetFreeY = "tomo.standalonePetFreeY"
        static let selectedPetID = "tomo.selectedPetID"
        static let petBackgroundColor = "tomo.petBackgroundColor"
        static let statusBarIndicatorColorMode = "tomo.statusBarIndicatorColorMode"
        static let statusBarWaveEnabled = "tomo.statusBarWaveEnabled"
        static let statusBarWaveColorMode = "tomo.statusBarWaveColorMode"
        static let statusBarOpacityPercent = "tomo.statusBarOpacityPercent"
        static let statusBarCornerPercent = "tomo.statusBarCornerPercent"
        static let windowAlwaysOnTop = "tomo.windowAlwaysOnTop"
        static let dashboardOrientation = "tomo.dashboardOrientation"
        static let notchDisplayTarget = "tomo.notchDisplayTarget"
        static let notchDraggingEnabled = "tomo.notchDraggingEnabled"
        static let notchDisplayOffsets = "tomo.notchDisplayOffsets"
        static let knownDisplays = "tomo.knownDisplays"
        static let themeConfig = "tomo.themeConfig"
        static let syncThemeWithMobileEnabled = "tomo.syncThemeWithMobileEnabled"
        static let networkProxyEnabled = AppNetworkProxyDefaultsKey.enabled
        static let networkProxyProtocol = AppNetworkProxyDefaultsKey.protocolName
        static let networkProxyHost = AppNetworkProxyDefaultsKey.host
        static let networkProxyPort = AppNetworkProxyDefaultsKey.port
    }

    private let defaults: UserDefaults
    private let codexPetSelectionSync: CodexPetSelectionSync?
    private var suppressCodexPetSelectionWrite = true
    private(set) var systemColorScheme: ColorScheme

    /// 开机自启由 macOS 登录项负责，系统状态是唯一事实来源。
    private(set) var launchAtLoginEnabled: Bool
    private(set) var launchAtLoginErrorMessage: String?

    /// 启动后只驻留在菜单栏，不自动展示主窗口。
    var silentLaunchEnabled: Bool {
        didSet {
            guard silentLaunchEnabled != oldValue else { return }
            defaults.set(silentLaunchEnabled, forKey: Keys.silentLaunchEnabled)
        }
    }

    var networkProxyEnabled: Bool {
        didSet {
            guard networkProxyEnabled != oldValue else { return }
            defaults.set(networkProxyEnabled, forKey: Keys.networkProxyEnabled)
            onNetworkProxyChanged?()
        }
    }

    var networkProxyProtocol: AppNetworkProxyProtocol {
        didSet {
            guard networkProxyProtocol != oldValue else { return }
            defaults.set(networkProxyProtocol.rawValue, forKey: Keys.networkProxyProtocol)
            onNetworkProxyChanged?()
        }
    }

    var networkProxyHost: String {
        didSet {
            guard networkProxyHost != oldValue else { return }
            defaults.set(networkProxyHost, forKey: Keys.networkProxyHost)
            onNetworkProxyChanged?()
        }
    }

    var networkProxyPort: Int {
        didSet {
            guard networkProxyPort != oldValue else { return }
            defaults.set(networkProxyPort, forKey: Keys.networkProxyPort)
            onNetworkProxyChanged?()
        }
    }

    var shouldOpenMainWindowAtLaunch: Bool { !silentLaunchEnabled }

    var theme: AppThemePreference {
        didSet {
            guard theme != oldValue else { return }
            defaults.set(theme.rawValue, forKey: Keys.theme)
            applyAppearance()
            onThemeChanged?(theme)
        }
    }

    var autoRefreshInterval: AutoRefreshInterval {
        didSet {
            guard autoRefreshInterval != oldValue else { return }
            defaults.set(autoRefreshInterval.rawValue, forKey: Keys.autoRefreshInterval)
            onAutoRefreshIntervalChanged?(autoRefreshInterval)
        }
    }

    var accountCarouselInterval: AccountCarouselInterval {
        didSet {
            guard accountCarouselInterval != oldValue else { return }
            defaults.set(accountCarouselInterval.rawValue, forKey: Keys.accountCarouselInterval)
            onAccountCarouselIntervalChanged?(accountCarouselInterval)
        }
    }

    /// 主窗口主界面的「供应商轮播」是否自动轮播。仅作用于主窗口，不影响刘海窗口。
    var mainWindowProviderCarouselEnabled: Bool {
        didSet {
            guard mainWindowProviderCarouselEnabled != oldValue else { return }
            defaults.set(mainWindowProviderCarouselEnabled, forKey: Keys.mainWindowProviderCarouselEnabled)
            onMainWindowProviderCarouselEnabledChanged?(mainWindowProviderCarouselEnabled)
        }
    }

    /// 刘海面板的「供应商轮播」是否自动轮播。仅作用于刘海面板，不影响主窗口。
    var notchProviderCarouselEnabled: Bool {
        didSet {
            guard notchProviderCarouselEnabled != oldValue else { return }
            defaults.set(notchProviderCarouselEnabled, forKey: Keys.notchProviderCarouselEnabled)
            onNotchProviderCarouselEnabledChanged?(notchProviderCarouselEnabled)
        }
    }

    var petsEnabled: Bool {
        didSet {
            guard petsEnabled != oldValue else { return }
            defaults.set(petsEnabled, forKey: Keys.petsEnabled)
            onPetSettingsChanged?()
        }
    }

    var standalonePetEnabled: Bool {
        didSet {
            guard standalonePetEnabled != oldValue else { return }
            defaults.set(standalonePetEnabled, forKey: Keys.standalonePetEnabled)
            onStandalonePetEnabledChanged?(standalonePetEnabled)
        }
    }

    var standalonePetEdge: StandalonePetEdge {
        didSet {
            guard standalonePetEdge != oldValue else { return }
            defaults.set(standalonePetEdge.rawValue, forKey: Keys.standalonePetEdge)
            onStandalonePetSettingsChanged?()
        }
    }

    var standalonePetScale: Double {
        didSet {
            guard standalonePetScale != oldValue else { return }
            defaults.set(standalonePetScale, forKey: Keys.standalonePetScale)
            onStandalonePetSettingsChanged?()
        }
    }

    /// 自由拖拽位置（面板 origin，屏幕坐标）。nil 表示吸附到 `standalonePetEdge`。
    var standalonePetFreeOrigin: NSPoint? {
        didSet {
            guard standalonePetFreeOrigin != oldValue else { return }
            if let origin = standalonePetFreeOrigin {
                defaults.set(origin.x, forKey: Keys.standalonePetFreeX)
                defaults.set(origin.y, forKey: Keys.standalonePetFreeY)
            } else {
                defaults.removeObject(forKey: Keys.standalonePetFreeX)
                defaults.removeObject(forKey: Keys.standalonePetFreeY)
            }
            onStandalonePetSettingsChanged?()
        }
    }

    var selectedPetID: String {
        didSet {
            guard selectedPetID != oldValue else { return }
            defaults.set(selectedPetID, forKey: Keys.selectedPetID)
            if !suppressCodexPetSelectionWrite {
                syncSelectedPetToCodex()
            }
            onPetSettingsChanged?()
        }
    }

    // 保留 UserDefaults 键值以兼容旧版本设置，但当前胶囊不再使用此颜色
    // （状态栏文字现按实际背景自动取黑/白，圆灯由单独的颜色模式控制）。
    var petBackgroundColor: StatusBarPetBackgroundColor {
        didSet {
            guard petBackgroundColor != oldValue else { return }
            defaults.set(petBackgroundColor.rawValue, forKey: Keys.petBackgroundColor)
            onPetSettingsChanged?()
        }
    }

    var statusBarWaveEnabled: Bool {
        didSet {
            guard statusBarWaveEnabled != oldValue else { return }
            defaults.set(statusBarWaveEnabled, forKey: Keys.statusBarWaveEnabled)
            onPetSettingsChanged?()
        }
    }

    var statusBarIndicatorColorMode: StatusCapsuleColorMode {
        didSet {
            guard statusBarIndicatorColorMode != oldValue else { return }
            defaults.set(
                statusBarIndicatorColorMode.rawValue,
                forKey: Keys.statusBarIndicatorColorMode
            )
            onPetSettingsChanged?()
        }
    }

    var statusBarWaveColorMode: StatusCapsuleColorMode {
        didSet {
            guard statusBarWaveColorMode != oldValue else { return }
            defaults.set(statusBarWaveColorMode.rawValue, forKey: Keys.statusBarWaveColorMode)
            onPetSettingsChanged?()
        }
    }

    var statusBarOpacityPercent: Double {
        didSet {
            guard statusBarOpacityPercent != oldValue else { return }
            defaults.set(statusBarOpacityPercent, forKey: Keys.statusBarOpacityPercent)
            onPetSettingsChanged?()
        }
    }

    var statusBarCornerPercent: Double {
        didSet {
            guard statusBarCornerPercent != oldValue else { return }
            defaults.set(statusBarCornerPercent, forKey: Keys.statusBarCornerPercent)
            onPetSettingsChanged?()
        }
    }

    var windowAlwaysOnTop: Bool {
        didSet {
            guard windowAlwaysOnTop != oldValue else { return }
            defaults.set(windowAlwaysOnTop, forKey: Keys.windowAlwaysOnTop)
            onWindowAlwaysOnTopChanged?(windowAlwaysOnTop)
        }
    }

    var dashboardOrientation: DashboardOrientation {
        didSet {
            guard dashboardOrientation != oldValue else { return }
            defaults.set(dashboardOrientation.rawValue, forKey: Keys.dashboardOrientation)
            onDashboardOrientationChanged?(dashboardOrientation)
        }
    }

    var notchDisplayTarget: NotchDisplayTarget {
        didSet {
            guard notchDisplayTarget != oldValue else { return }
            defaults.set(notchDisplayTarget.storageString, forKey: Keys.notchDisplayTarget)
            onNotchDisplayTargetChanged?(notchDisplayTarget)
        }
    }

    /// 是否允许在非内建（外接）显示器上拖拽移动刘海位置。
    var notchDraggingEnabled: Bool {
        didSet {
            guard notchDraggingEnabled != oldValue else { return }
            defaults.set(notchDraggingEnabled, forKey: Keys.notchDraggingEnabled)
            onNotchDraggingEnabledChanged?(notchDraggingEnabled)
        }
    }

    /// 曾连接过的显示器硬件元信息记录（Key: persistentID）。
    var knownDisplays: [String: KnownDisplayRecord] {
        didSet {
            guard knownDisplays != oldValue else { return }
            if let data = try? JSONEncoder().encode(knownDisplays) {
                defaults.set(data, forKey: Keys.knownDisplays)
            }
        }
    }

    /// 各外接显示器的刘海 X 轴相对中心偏移量 (Key: persistentID 硬件 UUID, Value: 偏移 pt)。
    var notchDisplayOffsets: [String: Double] {
        didSet {
            guard notchDisplayOffsets != oldValue else { return }
            defaults.set(notchDisplayOffsets, forKey: Keys.notchDisplayOffsets)
            onNotchDisplayOffsetsChanged?()
        }
    }

    func notchOffset(for persistentID: String) -> CGFloat {
        CGFloat(notchDisplayOffsets[persistentID] ?? 0)
    }

    func setNotchOffset(_ offset: CGFloat, for persistentID: String) {
        var offsets = notchDisplayOffsets
        offsets[persistentID] = Double(offset)
        notchDisplayOffsets = offsets
    }

    func resetNotchOffset(for persistentID: String) {
        var offsets = notchDisplayOffsets
        offsets.removeValue(forKey: persistentID)
        notchDisplayOffsets = offsets
    }

    func resetAllNotchOffsets() {
        notchDisplayOffsets = [:]
    }

    func recordDisplay(id: String, name: String, isBuiltin: Bool) {
        var records = knownDisplays
        records[id] = KnownDisplayRecord(
            id: id,
            name: name,
            isBuiltin: isBuiltin,
            lastSeen: Date()
        )
        knownDisplays = records
    }

    func displayName(for persistentID: String) -> String? {
        knownDisplays[persistentID]?.name
    }

    private(set) var availablePets: [CodexPet] = []
    private(set) var isTomoPetInstalled = true
    private(set) var tomoPetInstallationError: String?
    private(set) var codexPetSyncError: String?
    private(set) var codexPetRestartRequired = false

    var selectedPet: CodexPet? {
        availablePets.first { $0.id == selectedPetID } ?? availablePets.first
    }

    var resolvedColorScheme: ColorScheme {
        theme.resolvedColorScheme(system: systemColorScheme)
    }

    var onAutoRefreshIntervalChanged: ((AutoRefreshInterval) -> Void)?
    var onAccountCarouselIntervalChanged: ((AccountCarouselInterval) -> Void)?
    var onMainWindowProviderCarouselEnabledChanged: ((Bool) -> Void)?
    var onNotchProviderCarouselEnabledChanged: ((Bool) -> Void)?
    var onThemeChanged: ((AppThemePreference) -> Void)?
    var onPetSettingsChanged: (() -> Void)?
    var onStandalonePetEnabledChanged: ((Bool) -> Void)?
    var onStandalonePetSettingsChanged: (() -> Void)?
    var onDashboardOrientationChanged: ((DashboardOrientation) -> Void)?
    var onWindowAlwaysOnTopChanged: ((Bool) -> Void)?
    var onNotchDisplayTargetChanged: ((NotchDisplayTarget) -> Void)?
    var onNotchDraggingEnabledChanged: ((Bool) -> Void)?
    var onNotchDisplayOffsetsChanged: (() -> Void)?
    var onNetworkProxyChanged: (() -> Void)?
    var onSyncThemeWithMobileChanged: ((Bool) -> Void)?
    var onThemeConfigChanged: ((TomoThemeConfig) -> Void)?

    var syncThemeWithMobileEnabled: Bool {
        didSet {
            guard syncThemeWithMobileEnabled != oldValue else { return }
            defaults.set(syncThemeWithMobileEnabled, forKey: Keys.syncThemeWithMobileEnabled)
            onSyncThemeWithMobileChanged?(syncThemeWithMobileEnabled)
        }
    }

    var themeConfig: TomoThemeConfig {
        didSet {
            guard themeConfig != oldValue else { return }
            if let data = try? JSONEncoder().encode(themeConfig) {
                defaults.set(data, forKey: Keys.themeConfig)
            }
            onThemeConfigChanged?(themeConfig)
        }
    }

    init(
        defaults: UserDefaults = .standard,
        codexPetSelectionSync: CodexPetSelectionSync? = nil
    ) {
        self.defaults = defaults
        self.codexPetSelectionSync = codexPetSelectionSync
            ?? (defaults === UserDefaults.standard ? CodexPetSelectionSync() : nil)
        systemColorScheme = Self.currentSystemColorScheme()
        launchAtLoginEnabled = Self.isLaunchAtLoginRegistered
        launchAtLoginErrorMessage = nil
        silentLaunchEnabled = defaults.object(forKey: Keys.silentLaunchEnabled) as? Bool ?? false
        syncThemeWithMobileEnabled = defaults.object(forKey: Keys.syncThemeWithMobileEnabled) as? Bool ?? true
        if let data = defaults.data(forKey: Keys.themeConfig),
           let decoded = try? JSONDecoder().decode(TomoThemeConfig.self, from: data) {
            themeConfig = decoded
        } else {
            themeConfig = .default
        }
        networkProxyEnabled = defaults.bool(forKey: Keys.networkProxyEnabled)
        networkProxyProtocol = defaults.string(forKey: Keys.networkProxyProtocol)
            .flatMap(AppNetworkProxyProtocol.init(rawValue:)) ?? .socks5h
        networkProxyHost = defaults.string(forKey: Keys.networkProxyHost) ?? "127.0.0.1"
        networkProxyPort = defaults.object(forKey: Keys.networkProxyPort) as? Int ?? 7897

        if let raw = defaults.string(forKey: Keys.theme),
           let saved = AppThemePreference(rawValue: raw) {
            theme = saved
        } else {
            theme = .system
        }

        let intervalRaw = defaults.object(forKey: Keys.autoRefreshInterval) as? Int
        if let intervalRaw, let saved = AutoRefreshInterval(rawValue: intervalRaw) {
            autoRefreshInterval = saved
        } else {
            autoRefreshInterval = .minutes1
        }

        let carouselRaw = defaults.object(forKey: Keys.accountCarouselInterval) as? Int
        accountCarouselInterval = carouselRaw.flatMap(AccountCarouselInterval.init(rawValue:)) ?? .off
        mainWindowProviderCarouselEnabled = defaults.object(forKey: Keys.mainWindowProviderCarouselEnabled) as? Bool ?? true
        notchProviderCarouselEnabled = defaults.object(forKey: Keys.notchProviderCarouselEnabled) as? Bool ?? true

        petsEnabled = defaults.object(forKey: Keys.petsEnabled) as? Bool ?? true
        standalonePetEnabled = defaults.object(forKey: Keys.standalonePetEnabled) as? Bool ?? true
        standalonePetEdge = defaults.string(forKey: Keys.standalonePetEdge)
            .flatMap(StandalonePetEdge.init(rawValue:)) ?? .bottom
        let savedScale = defaults.object(forKey: Keys.standalonePetScale) as? Double ?? 1.0
        standalonePetScale = min(max(savedScale, StandalonePetLayout.scaleRange.lowerBound), StandalonePetLayout.scaleRange.upperBound)
        if let freeX = defaults.object(forKey: Keys.standalonePetFreeX) as? Double,
           let freeY = defaults.object(forKey: Keys.standalonePetFreeY) as? Double {
            standalonePetFreeOrigin = NSPoint(x: freeX, y: freeY)
        } else {
            standalonePetFreeOrigin = nil
        }
        selectedPetID = defaults.string(forKey: Keys.selectedPetID) ?? "builtin:codex"
        let backgroundRaw = defaults.string(forKey: Keys.petBackgroundColor)
        petBackgroundColor = backgroundRaw.flatMap(StatusBarPetBackgroundColor.init(rawValue:)) ?? .neutral
        statusBarIndicatorColorMode = defaults.string(forKey: Keys.statusBarIndicatorColorMode)
            .flatMap(StatusCapsuleColorMode.init(rawValue:)) ?? .activityState
        statusBarWaveEnabled = defaults.object(forKey: Keys.statusBarWaveEnabled) as? Bool ?? true
        let savedWaveColorMode = defaults.string(forKey: Keys.statusBarWaveColorMode)
        statusBarWaveColorMode = savedWaveColorMode.flatMap { rawValue in
            ["statusColor", "neutral", StatusCapsuleColorMode.quotaHealth.rawValue].contains(rawValue)
                ? .activityState
                : StatusCapsuleColorMode(rawValue: rawValue)
        } ?? .activityState
        let savedOpacityPercent =
            defaults.object(forKey: Keys.statusBarOpacityPercent) as? Double ?? 20
        statusBarOpacityPercent = min(max(savedOpacityPercent, 0), 50)
        let savedCornerPercent = defaults.object(forKey: Keys.statusBarCornerPercent) as? Double ?? 50
        statusBarCornerPercent = min(max(savedCornerPercent, 20), 50)
        windowAlwaysOnTop = defaults.object(forKey: Keys.windowAlwaysOnTop) as? Bool ?? false
        dashboardOrientation = defaults.string(forKey: Keys.dashboardOrientation)
            .flatMap(DashboardOrientation.init(rawValue:)) ?? .horizontal
        if let data = defaults.data(forKey: Keys.knownDisplays),
           let decoded = try? JSONDecoder().decode([String: KnownDisplayRecord].self, from: data) {
            knownDisplays = decoded
        } else {
            knownDisplays = [:]
        }
        notchDraggingEnabled = defaults.object(forKey: Keys.notchDraggingEnabled) as? Bool ?? false
        notchDisplayOffsets = defaults.object(forKey: Keys.notchDisplayOffsets) as? [String: Double] ?? [:]
        if let stored = defaults.string(forKey: Keys.notchDisplayTarget) {
            notchDisplayTarget = NotchDisplayTarget.fromStorage(stored)
        } else {
            let defaultTarget = NotchDisplayTarget.allDisplays
            notchDisplayTarget = defaultTarget
            defaults.set(defaultTarget.storageString, forKey: Keys.notchDisplayTarget)
        }
        reloadPets(notify: false)
        syncPetSelectionFromCodex()
        suppressCodexPetSelectionWrite = false
    }

    func applyAppearance() {
        let appearance = theme.nsAppearance
        // Do not override NSApplication.appearance: a status item lives in the
        // system menu bar, whose text contrast must continue to follow macOS.
        for window in NSApplication.shared.windows {
            window.appearance = appearance
            window.contentView?.needsDisplay = true
        }
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        launchAtLoginErrorMessage = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLoginErrorMessage = "设置开机自启失败：\(error.localizedDescription)"
        }
        refreshLaunchAtLoginStatus()
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginEnabled = Self.isLaunchAtLoginRegistered
    }

    func clearLaunchAtLoginError() {
        launchAtLoginErrorMessage = nil
    }

    private static var isLaunchAtLoginRegistered: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            true
        case .notRegistered, .notFound:
            false
        @unknown default:
            false
        }
    }

    func refreshSystemAppearanceIfNeeded(_ colorScheme: ColorScheme? = nil) {
        let next = colorScheme ?? Self.currentSystemColorScheme()
        guard next != systemColorScheme else { return }
        systemColorScheme = next
        guard theme == .system else { return }
        applyAppearance()
        onThemeChanged?(theme)
    }

    private static func currentSystemColorScheme() -> ColorScheme {
        let match = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return match == .darkAqua ? .dark : .light
    }

    func reloadPets(notify: Bool = true) {
        PetBidirectionalSyncManager.shared.performBidirectionalSync()
        isTomoPetInstalled = true
        availablePets = CodexPetCatalog().discover()
        if !availablePets.contains(where: { $0.id == selectedPetID }),
           let fallback = availablePets.first {
            selectedPetID = fallback.id
        } else if notify {
            onPetSettingsChanged?()
        }
    }

    func syncPetSelectionFromCodex() {
        guard let codexPetID = codexPetSelectionSync?.readSelectedPetID(),
              availablePets.contains(where: { $0.id == codexPetID }),
              selectedPetID != codexPetID else {
            return
        }
        let wasSuppressingWrite = suppressCodexPetSelectionWrite
        suppressCodexPetSelectionWrite = true
        selectedPetID = codexPetID
        suppressCodexPetSelectionWrite = wasSuppressingWrite
        codexPetRestartRequired = false
        codexPetSyncError = nil
    }

    func refreshPetsAndSyncSelectionFromCodex() {
        let wasSuppressingWrite = suppressCodexPetSelectionWrite
        suppressCodexPetSelectionWrite = true
        reloadPets(notify: false)
        syncPetSelectionFromCodex()
        suppressCodexPetSelectionWrite = wasSuppressingWrite
        onPetSettingsChanged?()
    }

    private func syncSelectedPetToCodex() {
        guard let codexPetSelectionSync else { return }
        do {
            if try codexPetSelectionSync.writeSelectedPetID(selectedPetID) {
                codexPetRestartRequired = true
            }
            codexPetSyncError = nil
        } catch {
            codexPetSyncError = error.localizedDescription
        }
    }

    func markCodexPetRestartCompleted() {
        codexPetRestartRequired = false
    }

    func installTomoPet() {
        do {
            try TomoPetInstaller.install()
            tomoPetInstallationError = nil
            reloadPets()
            selectedPetID = "custom:\(TomoPetInstaller.petID)"
        } catch {
            tomoPetInstallationError = error.localizedDescription
        }
    }
}
