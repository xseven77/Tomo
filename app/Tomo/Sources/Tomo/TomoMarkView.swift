import AppKit
import SwiftUI

// MARK: - Tomo SVG Mark Renderer

public enum TomoMarkSvgRenderer {
    private static let T_STD_CLOSED = "M34 31Q30 31 30 35V40Q30 44 34 44H42V65Q42 70 47 70H53Q58 70 58 65V44H66Q70 44 70 40V35Q70 31 66 31Z"
    private static let T_STD_NOTCHED = "M34 31H54Q58 31 58 35V65Q58 70 53 70H47Q42 70 42 65V44H34Q30 44 30 40V35Q30 31 34 31Z M63.8 31H67.4Q70 31 70 33.6V41.4Q70 44 67.4 44H63.8Q61.2 44 61.2 41.4V33.6Q61.2 31 63.8 31Z"

    private static let T_G8_CLOSED = "M35.60 32.90Q32.00 32.90 32.00 36.50V41.00Q32.00 44.60 35.60 44.60H42.80V63.50Q42.80 68.00 47.30 68.00H52.70Q57.20 68.00 57.20 63.50V44.60H64.40Q68.00 44.60 68.00 41.00V36.50Q68.00 32.90 64.40 32.90Z"
    private static let T_G8_NOTCHED = "M35.60 32.90H53.60Q57.20 32.90 57.20 36.50V63.50Q57.20 68.00 52.70 68.00H47.30Q42.80 68.00 42.80 63.50V44.60H35.60Q32.00 44.60 32.00 41.00V36.50Q32.00 32.90 35.60 32.90Z M62.60 32.90H65.60Q68.00 32.90 68.00 35.30V42.20Q68.00 44.60 65.60 44.60H62.60Q60.20 44.60 60.20 42.20V35.30Q60.20 32.90 62.60 32.90Z"

    public static func svgString(
        family: String,
        notch: Bool,
        accentColor: String,
        accentEndColor: String? = nil,
        fillType: String = "solid",
        gradientAngle: Int = 135,
        renderMode: String = "color",
        glyphMode: String = "solid",
        tileBgColor: String = "#FFFFFF"
    ) -> String {
        let isNotched = notch

        // Determine Ink Color & Fill
        let inkColor: String
        let glyphFill: String
        switch renderMode {
        case "mono":
            inkColor = "#202321"
            glyphFill = "#FFFFFF"
        case "inverse":
            inkColor = "#F4F2ED"
            glyphFill = accentColor
        default: // "color"
            inkColor = accentColor
            glyphFill = "#FFFFFF"
        }

        let fillRef: String
        var defs = ""

        if fillType == "gradient" && renderMode != "mono" && renderMode != "inverse" {
            let start = accentColor
            let end = accentEndColor ?? accentColor
            let (x1, y1, x2, y2): (String, String, String, String)
            switch gradientAngle {
            case 180: (x1, y1, x2, y2) = ("0%", "0%", "0%", "100%")
            case 90:  (x1, y1, x2, y2) = ("0%", "0%", "100%", "0%")
            case 45:  (x1, y1, x2, y2) = ("0%", "100%", "100%", "0%")
            default:  (x1, y1, x2, y2) = ("0%", "0%", "100%", "100%")
            }
            defs = """
            <defs>
              <linearGradient id="tomo-grad" x1="\(x1)" y1="\(y1)" x2="\(x2)" y2="\(y2)">
                <stop offset="0%" stop-color="\(start)"/>
                <stop offset="100%" stop-color="\(end)"/>
              </linearGradient>
            </defs>
            """
            fillRef = "url(#tomo-grad)"
        } else {
            fillRef = inkColor
        }

        let tStdUsed = isNotched ? T_STD_NOTCHED : T_STD_CLOSED
        let tG8Used = isNotched ? T_G8_NOTCHED : T_G8_CLOSED

        var pathContent = ""
        var glyphContent = ""

        switch family {
        case "circle":
            let body = "M85 50A35 35 0 1 1 15 50A35 35 0 1 1 85 50ZM34 31Q30 31 30 35V40Q30 44 34 44H42V65Q42 70 47 70H53Q58 70 58 65V44H66Q70 44 70 40V35Q70 31 66 31Z"
                .replacingOccurrences(of: T_STD_CLOSED, with: tStdUsed)
            pathContent = "<path fill-rule=\"evenodd\" d=\"\(body)\" fill=\"\(fillRef)\"/>"
            if glyphMode == "solid" {
                glyphContent = "<path d=\"\(tStdUsed)\" fill=\"\(glyphFill)\"/>"
            }

        case "squircle":
            let body = "M40 16H60C77 16 84 23 84 40V60C84 77 77 84 60 84H40C23 84 16 77 16 60V40C16 23 23 16 40 16ZM34 31Q30 31 30 35V40Q30 44 34 44H42V65Q42 70 47 70H53Q58 70 58 65V44H66Q70 44 70 40V35Q70 31 66 31Z"
                .replacingOccurrences(of: T_STD_CLOSED, with: tStdUsed)
            pathContent = "<path fill-rule=\"evenodd\" d=\"\(body)\" fill=\"\(fillRef)\"/>"
            if glyphMode == "solid" {
                glyphContent = "<path d=\"\(tStdUsed)\" fill=\"\(glyphFill)\"/>"
            }

        case "cloud7":
            let body = "M 50.00 18.50 Q 69.09 10.36 74.63 30.36 Q 92.90 40.21 80.71 57.01 Q 84.40 77.43 63.67 78.38 Q 50.00 94.00 36.33 78.38 Q 15.60 77.43 19.29 57.01 Q 7.10 40.21 25.37 30.36 Q 30.91 10.36 50.00 18.50Z M35.60 32.90Q32.00 32.90 32.00 36.50V41.00Q32.00 44.60 35.60 44.60H42.80V63.50Q42.80 68.00 47.30 68.00H52.70Q57.20 68.00 57.20 63.50V44.60H64.40Q68.00 44.60 68.00 41.00V36.50Q68.00 32.90 64.40 32.90Z"
                .replacingOccurrences(of: T_G8_CLOSED, with: tG8Used)
            pathContent = "<path fill-rule=\"evenodd\" d=\"\(body)\" fill=\"\(fillRef)\"/>"
            if glyphMode == "solid" {
                glyphContent = "<path d=\"\(tG8Used)\" fill=\"\(glyphFill)\"/>"
            }

        case "quota":
            let body = "M44 16Q50 13 56 16L76 27Q82 30 82 37V63Q82 70 76 73L56 84Q50 87 44 84L24 73Q18 70 18 63V37Q18 30 24 27ZM34 30H39Q43 30 43 34V39Q43 43 39 43H34Q30 43 30 39V34Q30 30 34 30ZM61 57H66Q70 57 70 61V66Q70 70 66 70H61Q57 70 57 66V61Q57 57 61 57ZM60 30Q63 27 66 30Q69 32 66 36L40 70Q37 73 34 70Q31 68 34 64Z"
            pathContent = "<path fill-rule=\"evenodd\" d=\"\(body)\" fill=\"\(fillRef)\"/>"
            if glyphMode == "solid" {
                glyphContent = "<path d=\"M34 30H39Q43 30 43 34V39Q43 43 39 43H34Q30 43 30 39V34Q30 30 34 30ZM61 57H66Q70 57 70 61V66Q70 70 66 70H61Q57 70 57 66V61Q57 57 61 57ZM60 30Q63 27 66 30Q69 32 66 36L40 70Q37 73 34 70Q31 68 34 64Z\" fill=\"\(glyphFill)\"/>"
            }

        default: // "hex"
            let body = "M44 16Q50 13 56 16L76 27Q82 30 82 37V63Q82 70 76 73L56 84Q50 87 44 84L24 73Q18 70 18 63V37Q18 30 24 27ZM34 31Q30 31 30 35V40Q30 44 34 44H42V65Q42 70 47 70H53Q58 70 58 65V44H66Q70 44 70 40V35Q70 31 66 31Z"
                .replacingOccurrences(of: T_STD_CLOSED, with: tStdUsed)
            pathContent = "<path fill-rule=\"evenodd\" d=\"\(body)\" fill=\"\(fillRef)\"/>"
            if glyphMode == "solid" {
                glyphContent = "<path d=\"\(tStdUsed)\" fill=\"\(glyphFill)\"/>"
            }
        }

        return """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
          \(defs)
          \(pathContent)
          \(glyphContent)
        </svg>
        """
    }

    public static func image(
        family: String,
        notch: Bool,
        accentColor: String,
        accentEndColor: String? = nil,
        fillType: String = "solid",
        gradientAngle: Int = 135,
        renderMode: String = "color",
        glyphMode: String = "solid",
        tileBgColor: String = "#FFFFFF",
        targetSize: NSSize = NSSize(width: 100, height: 100)
    ) -> NSImage? {
        let svg = svgString(
            family: family,
            notch: notch,
            accentColor: accentColor,
            accentEndColor: accentEndColor,
            fillType: fillType,
            gradientAngle: gradientAngle,
            renderMode: renderMode,
            glyphMode: glyphMode,
            tileBgColor: tileBgColor
        )
        guard let data = svg.data(using: .utf8) else { return nil }
        guard let image = NSImage(data: data) else { return nil }
        image.size = targetSize
        return image
    }

    /// Renders a full macOS Dock / Application icon tile (with rounded rect container and subtle shadow)
    @MainActor
    public static func appIconImage(config: TomoThemeConfig, size: CGFloat = 512) -> NSImage {
        let view = TomoMarkView(config: config, size: size, showTile: true)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: size, height: size)

        let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) ??
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size),
                pixelsHigh: Int(size),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )

        if let rep {
            hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
            let image = NSImage(size: NSSize(width: size, height: size))
            image.addRepresentation(rep)
            return image
        }

        // Fallback: render vector SVG directly if view caching fails
        let fallback = image(
            family: config.logoFamily,
            notch: config.notchMode == "on",
            accentColor: config.accentColor,
            accentEndColor: config.accentEndColor,
            fillType: config.fillType,
            gradientAngle: config.gradientAngle,
            renderMode: config.renderMode,
            glyphMode: config.glyphMode,
            tileBgColor: config.tileBgColor,
            targetSize: NSSize(width: size, height: size)
        )
        return fallback ?? NSImage(size: NSSize(width: size, height: size))
    }
}

// MARK: - SwiftUI View for Transparent Vector Mark & App Icon Tile

public struct TomoMarkView: View {
    public let family: String
    public let notch: Bool
    public let accentColor: String
    public let accentEndColor: String?
    public let fillType: String
    public let gradientAngle: Int
    public let renderMode: String
    public let glyphMode: String
    public let tileBgColor: String
    public let shadowEnabled: Bool
    public let shadowStyle: String
    public let logoScale: Double
    public let shadowDirection: String
    public let showTile: Bool
    public var size: CGFloat

    public init(
        family: String = "hex",
        notch: Bool = false,
        accentColor: String = "#D74C32",
        accentEndColor: String? = nil,
        fillType: String = "solid",
        gradientAngle: Int = 135,
        renderMode: String = "color",
        glyphMode: String = "solid",
        tileBgColor: String = "#FFFFFF",
        shadowEnabled: Bool = false,
        shadowStyle: String = "tight",
        logoScale: Double = 0.72,
        shadowDirection: String = "down",
        showTile: Bool = false,
        size: CGFloat = 36
    ) {
        self.family = family
        self.notch = notch
        self.accentColor = accentColor
        self.accentEndColor = accentEndColor
        self.fillType = fillType
        self.gradientAngle = gradientAngle
        self.renderMode = renderMode
        self.glyphMode = glyphMode
        self.tileBgColor = tileBgColor
        self.shadowEnabled = shadowEnabled
        self.shadowStyle = shadowStyle
        self.logoScale = logoScale
        self.shadowDirection = shadowDirection
        self.showTile = showTile
        self.size = size
    }

    public init(config: TomoThemeConfig, size: CGFloat = 36, showTile: Bool = false) {
        self.family = config.logoFamily
        self.notch = config.notchMode == "on"
        self.accentColor = config.accentColor
        self.accentEndColor = config.accentEndColor
        self.fillType = config.fillType
        self.gradientAngle = config.gradientAngle
        self.renderMode = config.renderMode
        self.glyphMode = config.glyphMode
        self.tileBgColor = config.tileBgColor
        self.shadowEnabled = config.shadowEnabled
        self.shadowStyle = config.shadowStyle
        self.logoScale = config.logoScale
        self.shadowDirection = config.shadowDirection
        self.showTile = showTile
        self.size = size
    }

    private var shadowColor: Color {
        if !shadowEnabled || renderMode == "inverse" { return Color.clear }
        if renderMode == "mono" {
            return Color.black.opacity(shadowStyle == "soft" ? 0.20 : 0.16)
        }
        return Color(hex: accentColor).opacity(shadowStyle == "soft" ? 0.50 : 0.44)
    }

    private var shadowRadius: CGFloat {
        if !shadowEnabled || renderMode == "inverse" { return 0 }
        return shadowStyle == "soft" ? size * 0.08 : size * 0.04
    }

    private var shadowOffsets: (x: CGFloat, y: CGFloat) {
        if !shadowEnabled || renderMode == "inverse" { return (0, 0) }
        let baseOffset = shadowStyle == "soft" ? size * 0.04 : size * 0.02
        switch shadowDirection {
        case "down": // 默认向下
            return (0, baseOffset)
        case "bottomRight": // 右下
            return (baseOffset * 0.7, baseOffset * 0.7)
        case "radial": // 弥散
            return (0, 0)
        case "up": // 向上
            return (0, -baseOffset)
        default:
            return (0, baseOffset)
        }
    }

    private var effectiveTileBg: Color {
        if renderMode == "inverse" {
            return Color(hex: accentColor)
        }
        return Color(hex: tileBgColor)
    }

    public var body: some View {
        // macOS App Icon standard squircle occupies ~82.8% of the canvas
        let tileSize = showTile ? size * 0.828 : size
        let markSize = tileSize * CGFloat(logoScale)

        let imageNode: some View = Group {
            if let image = TomoMarkSvgRenderer.image(
                family: family,
                notch: notch,
                accentColor: accentColor,
                accentEndColor: accentEndColor,
                fillType: fillType,
                gradientAngle: gradientAngle,
                renderMode: renderMode,
                glyphMode: glyphMode,
                tileBgColor: tileBgColor,
                targetSize: NSSize(width: markSize, height: markSize)
            ) {
                let offsets = shadowOffsets
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: markSize, height: markSize)
                    .shadow(color: shadowColor, radius: shadowRadius, x: offsets.x, y: offsets.y)
            } else {
                Image(systemName: "hexagon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: markSize, height: markSize)
            }
        }

        if showTile {
            ZStack {
                // macOS HIG standard squircle with smooth curvature and native drop shadow
                RoundedRectangle(cornerRadius: tileSize * 0.224, style: .continuous)
                    .fill(effectiveTileBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: tileSize * 0.224, style: .continuous)
                            .stroke(Color.black.opacity(0.08), lineWidth: 0.8)
                    )
                    .shadow(color: Color.black.opacity(0.24), radius: size * 0.035, x: 0, y: size * 0.024)
                    .frame(width: tileSize, height: tileSize)

                imageNode
            }
            .frame(width: size, height: size)
        } else {
            imageNode
        }
    }
}
