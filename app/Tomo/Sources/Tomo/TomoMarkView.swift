import AppKit
import SwiftUI

// MARK: - Tomo SVG Mark Renderer

public enum TomoMarkSvgRenderer {
    private static let T_STD_CLOSED = "M34 31Q30 31 30 35V40Q30 44 34 44H42V65Q42 70 47 70H53Q58 70 58 65V44H66Q70 44 70 40V35Q70 31 66 31Z"
    private static let T_STD_NOTCHED = "M34 31H54Q58 31 58 35V65Q58 70 53 70H47Q42 70 42 65V44H34Q30 44 30 40V35Q30 31 34 31Z M63.8 31H67.4Q70 31 70 33.6V41.4Q70 44 67.4 44H63.8Q61.2 44 61.2 41.4V33.6Q61.2 31 63.8 31Z"

    private static let T_G8_CLOSED = "M35.60 32.90Q32.00 32.90 32.00 36.50V41.00Q32.00 44.60 35.60 44.60H42.80V63.50Q42.80 68.00 47.30 68.00H52.70Q57.20 68.00 57.20 63.50V44.60H64.40Q68.00 44.60 68.00 41.00V36.50Q68.00 32.90 64.40 32.90Z"
    private static let T_G8_NOTCHED = "M35.60 32.90H53.60Q57.20 32.90 57.20 36.50V63.50Q57.20 68.00 52.70 68.00H47.30Q42.80 68.00 42.80 63.50V44.60H35.60Q32.00 44.60 32.00 41.00V36.50Q32.00 32.90 35.60 32.90Z M62.60 32.90H65.60Q68.00 32.90 68.00 35.30V42.20Q68.00 44.60 65.60 44.60H62.60Q60.20 44.60 60.20 42.20V35.30Q60.20 32.90 62.60 32.90Z"
    private static let PERCENT_PATH = "M34 30H39Q43 30 43 34V39Q43 43 39 43H34Q30 43 30 39V34Q30 30 34 30ZM61 57H66Q70 57 70 61V66Q70 70 66 70H61Q57 70 57 66V61Q57 57 61 57ZM60 30Q63 27 66 30Q69 32 66 36L40 70Q37 73 34 70Q31 68 34 64Z"
    private static let GO_LETTERS_PATH = "M4.8 0H5.15C7.05 0 8.2 .52 8.9 1.65Q9.35 2.5 8.55 3Q7.6 3.5 7.05 2.8C6.65 2.35 6.1 2.25 5 2.25H4.6C3.15 2.25 2.7 2.95 2.7 4.6V4.9C2.7 6.55 3.15 7.15 4.6 7.15H5.15Q6.1 7.15 6.8 6.8V6.2H5.4Q4.65 6.2 4.65 5.45Q4.65 4.55 5.4 4.55H8.45Q9.5 4.55 9.5 5.6V7.2C9.5 8.8 7.5 9.5 5 9.5H4.8C1.5 9.5 0 8 0 4.8C0 1.5 1.5 0 4.8 0Z M15.1 0H17.3Q21 0 21 3.7V5.8Q21 9.5 17.3 9.5H15.1Q11.4 9.5 11.4 5.8V3.7Q11.4 0 15.1 0ZM15.7 2.5H16.7Q18.3 2.5 18.3 4.1V5.4Q18.3 7 16.7 7H15.7Q14.1 7 14.1 5.4V4.1Q14.1 2.5 15.7 2.5Z"

    private static func hexToRgb(_ hex: String) -> (r: Double, g: Double, b: Double) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        if h.count == 3 {
            h = h.map { "\($0)\($0)" }.joined()
        }
        guard h.count == 6, let num = UInt64(h, radix: 16) else { return (0, 0, 0) }
        return (Double((num >> 16) & 0xFF), Double((num >> 8) & 0xFF), Double(num & 0xFF))
    }

    public static func blendHex(_ hex1: String, _ hex2: String, ratio: Double = 0.5) -> String {
        let c1 = hexToRgb(hex1)
        let c2 = hexToRgb(hex2)
        let r = Int(round(c1.r * (1.0 - ratio) + c2.r * ratio))
        let g = Int(round(c1.g * (1.0 - ratio) + c2.g * ratio))
        let b = Int(round(c1.b * (1.0 - ratio) + c2.b * ratio))
        return String(format: "#%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }

    public static func svgString(
        family: String,
        logoContent: String = "t",
        notch: Bool,
        accentColor: String,
        accentEndColor: String? = nil,
        fillType: String = "solid",
        gradientAngle: Int = 135,
        renderMode: String = "color",
        glyphMode: String = "solid",
        tileBgColor: String = "#FFFFFF",
        materialTexture: String = "flat",
        glassOpacity: Double = 0.72
    ) -> String {
        let isNotched = notch

        let isGradient = fillType == "gradient" && renderMode != "mono"
        let start = accentColor
        let end = accentEndColor ?? accentColor

        let (x1, y1, x2, y2): (String, String, String, String)
        switch gradientAngle {
        case 180: (x1, y1, x2, y2) = ("0%", "0%", "0%", "100%")
        case 90:  (x1, y1, x2, y2) = ("0%", "0%", "100%", "0%")
        case 45:  (x1, y1, x2, y2) = ("0%", "100%", "100%", "0%")
        default:  (x1, y1, x2, y2) = ("0%", "0%", "100%", "100%")
        }

        let gradDef = """
          <linearGradient id="tomo-grad" x1="\(x1)" y1="\(y1)" x2="\(x2)" y2="\(y2)">
            <stop offset="0%" stop-color="\(start)"/>
            <stop offset="100%" stop-color="\(end)"/>
          </linearGradient>
        """

        // Determine Ink Color & Fill
        let inkColor: String
        let glyphFill: String
        switch renderMode {
        case "mono":
            inkColor = "#202321"
            glyphFill = "#FFFFFF"
        case "inverse":
            inkColor = "#F4F2ED"
            glyphFill = isGradient ? "url(#tomo-grad)" : accentColor
        default: // "color"
            inkColor = accentColor
            glyphFill = "#FFFFFF"
        }

        let fillRef: String
        var defs = ""

        if materialTexture == "glass" && renderMode != "inverse" {
            fillRef = "url(#tomo-glass-tint)"
        } else if isGradient && renderMode == "color" {
            fillRef = "url(#tomo-grad)"
        } else if isGradient && renderMode == "inverse" {
            fillRef = inkColor
        } else {
            fillRef = inkColor
        }

        let isPure = family == "pure"
        let isPureGo = family == "pure_go"

        let tStdUsed = isNotched ? T_STD_NOTCHED : T_STD_CLOSED
        let tG8Used = isNotched ? T_G8_NOTCHED : T_G8_CLOSED

        let outerPath: String
        switch family {
        case "hex", "quota":
            outerPath = "M44 16Q50 13 56 16L76 27Q82 30 82 37V63Q82 70 76 73L56 84Q50 87 44 84L24 73Q18 70 18 63V37Q18 30 24 27Z"
        case "squircle":
            outerPath = "M40 16H60C77 16 84 23 84 40V60C84 77 77 84 60 84H40C23 84 16 77 16 60V40C16 23 23 16 40 16Z"
        case "cloud7":
            outerPath = "M 50.00 18.50 Q 69.09 10.36 74.63 30.36 Q 92.90 40.21 80.71 57.01 Q 84.40 77.43 63.67 78.38 Q 50.00 94.00 36.33 78.38 Q 15.60 77.43 19.29 57.01 Q 7.10 40.21 25.37 30.36 Q 30.91 10.36 50.00 18.50Z"
        default: // "circle"
            outerPath = "M85 50A35 35 0 1 1 15 50A35 35 0 1 1 85 50Z"
        }

        let isPercent = (logoContent == "percent") || (family == "quota")
        let innerSymbol = isPercent ? PERCENT_PATH : (family == "cloud7" ? tG8Used : tStdUsed)
        let body = "\(outerPath) \(innerSymbol)"

        let outerClipPath: String
        if isPure {
            outerClipPath = "<path d=\"\(innerSymbol)\" transform=\"translate(50 50) scale(1.36) translate(-50 -50.5)\"/>"
        } else if isPureGo {
            outerClipPath = "<path d=\"\(innerSymbol)\" transform=\"translate(50 41) scale(1.06) translate(-50 -50.5)\"/><rect x=\"34\" y=\"66\" width=\"32\" height=\"14\" rx=\"4.5\"/>"
        } else {
            outerClipPath = "<path d=\"\(outerPath)\"/>"
        }

        let goMaskDef = isPureGo ? """
          <mask id="tomo-go-mask" maskUnits="userSpaceOnUse" x="0" y="0" width="100" height="100">
            <rect width="100" height="100" fill="white"/>
            <g transform="translate(39.5 68.25)" fill="black">
              <path fill-rule="evenodd" d="\(GO_LETTERS_PATH)"/>
            </g>
          </mask>
        """ : ""

        var pathContent = ""
        var glyphContent = ""
        var sheenOverlay = ""

        if materialTexture == "glass" && renderMode == "inverse" {
            if isGradient || !goMaskDef.isEmpty {
                defs = "<defs>\n\(isGradient ? gradDef : "")\n\(goMaskDef)\n</defs>"
            }
            if isPure {
                pathContent = "<path d=\"\(innerSymbol)\" transform=\"translate(50 50) scale(1.36) translate(-50 -50.5)\" fill=\"\(inkColor)\"/>"
            } else if isPureGo {
                pathContent = """
                <path d="\(innerSymbol)" transform="translate(50 41) scale(1.06) translate(-50 -50.5)" fill="\(inkColor)"/>
                <rect x="34" y="66" width="32" height="14" rx="4.5" fill="\(inkColor)" mask="url(#tomo-go-mask)"/>
                """
            } else {
                pathContent = "<path fill-rule=\"evenodd\" d=\"\(body)\" fill=\"\(inkColor)\"/>"
                if glyphMode == "solid" {
                    glyphContent = "<path d=\"\(innerSymbol)\" fill=\"\(glyphFill)\"/>"
                }
            }
            sheenOverlay = ""
        } else if materialTexture == "glass" {
            let cStart: String
            let cMid: String
            let cEnd: String
            if renderMode == "mono" {
                cStart = "#505452"; cMid = "#202321"; cEnd = "#101211"
            } else if fillType == "gradient" {
                cStart = accentColor
                cEnd = accentEndColor ?? accentColor
                cMid = blendHex(cStart, cEnd, ratio: 0.5)
            } else {
                cMid = accentColor
                cStart = blendHex(accentColor, "#ffffff", ratio: 0.05)
                cEnd = blendHex(accentColor, "#000000", ratio: 0.06)
            }

            let tintOpacity = glassOpacity
            let tintStop0 = String(format: "%.3f", tintOpacity * 0.95)
            let tintStop1 = String(format: "%.3f", tintOpacity)
            let tintStop2 = String(format: "%.3f", min(0.98, tintOpacity * 1.05))

            let sheenFactor = 1.0 - (tintOpacity - 0.2) * 0.25
            let sheen0 = String(format: "%.3f", 0.10 * sheenFactor)
            let sheen1 = String(format: "%.3f", 0.04 * sheenFactor)

            defs = """
            <defs>
              \(isGradient ? gradDef : "")
              \(goMaskDef)
              <linearGradient id="tomo-glass-tint" x1="0%" y1="0%" x2="100%" y2="100%">
                <stop offset="0%" stop-color="\(cStart)" stop-opacity="\(tintStop0)"/>
                <stop offset="55%" stop-color="\(cMid)" stop-opacity="\(tintStop1)"/>
                <stop offset="100%" stop-color="\(cEnd)" stop-opacity="\(tintStop2)"/>
              </linearGradient>
              <linearGradient id="tomo-glass-rim" x1="0%" y1="0%" x2="100%" y2="100%">
                <stop offset="0%" stop-color="#ffffff" stop-opacity="0.95"/>
                <stop offset="35%" stop-color="#ffffff" stop-opacity="0.55"/>
                <stop offset="70%" stop-color="#ffffff" stop-opacity="0.18"/>
                <stop offset="100%" stop-color="#ffffff" stop-opacity="0.45"/>
              </linearGradient>
              <linearGradient id="tomo-glass-sheen" x1="0%" y1="0%" x2="0%" y2="100%">
                <stop offset="0%" stop-color="#ffffff" stop-opacity="\(sheen0)"/>
                <stop offset="35%" stop-color="#ffffff" stop-opacity="\(sheen1)"/>
                <stop offset="70%" stop-color="#ffffff" stop-opacity="0"/>
                <stop offset="100%" stop-color="#ffffff" stop-opacity="0"/>
              </linearGradient>
              <clipPath id="tomo-outer-clip">
                \(outerClipPath)
              </clipPath>
              <filter id="tomo-inlay-shadow" x="-30%" y="-30%" width="160%" height="160%">
                <feDropShadow dx="0" dy="1.2" stdDeviation="1.2" flood-color="#000000" flood-opacity="0.22"/>
              </filter>
            </defs>
            """

            if isPure {
                pathContent = "<path d=\"\(innerSymbol)\" transform=\"translate(50 50) scale(1.36) translate(-50 -50.5)\" fill=\"url(#tomo-glass-tint)\" stroke=\"url(#tomo-glass-rim)\" stroke-width=\"1.3\" stroke-linejoin=\"round\"/>"
            } else if isPureGo {
                pathContent = """
                <path d="\(innerSymbol)" transform="translate(50 41) scale(1.06) translate(-50 -50.5)" fill="url(#tomo-glass-tint)" stroke="url(#tomo-glass-rim)" stroke-width="1.3" stroke-linejoin=\"round\"/>
                <rect x="34" y="66" width="32" height="14" rx="4.5" fill="url(#tomo-glass-tint)" stroke="url(#tomo-glass-rim)" stroke-width="1.3" stroke-linejoin="round" mask="url(#tomo-go-mask)"/>
                """
            } else {
                pathContent = "<path fill-rule=\"evenodd\" d=\"\(body)\" fill=\"url(#tomo-glass-tint)\" stroke=\"url(#tomo-glass-rim)\" stroke-width=\"1.3\" stroke-linejoin=\"round\"/>"
                if glyphMode == "solid" {
                    glyphContent = "<g filter=\"url(#tomo-inlay-shadow)\"><path d=\"\(innerSymbol)\" fill=\"\(glyphFill)\"/></g>"
                }
            }
            sheenOverlay = "<g clip-path=\"url(#tomo-outer-clip)\"><ellipse cx=\"50\" cy=\"22\" rx=\"38\" ry=\"26\" fill=\"url(#tomo-glass-sheen)\"/></g>"
        } else {
            if isGradient || !goMaskDef.isEmpty {
                defs = "<defs>\n\(isGradient ? gradDef : "")\n\(goMaskDef)\n</defs>"
            }
            if isPure {
                pathContent = "<path d=\"\(innerSymbol)\" transform=\"translate(50 50) scale(1.36) translate(-50 -50.5)\" fill=\"\(fillRef)\"/>"
            } else if isPureGo {
                pathContent = """
                <path d="\(innerSymbol)" transform="translate(50 41) scale(1.06) translate(-50 -50.5)" fill="\(fillRef)"/>
                <rect x="34" y="66" width="32" height="14" rx="4.5" fill="\(fillRef)" mask="url(#tomo-go-mask)"/>
                """
            } else {
                pathContent = "<path fill-rule=\"evenodd\" d=\"\(body)\" fill=\"\(fillRef)\"/>"
                if glyphMode == "solid" {
                    glyphContent = "<path d=\"\(innerSymbol)\" fill=\"\(glyphFill)\"/>"
                }
            }
        }

        return """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
          \(defs)
          \(pathContent)
          \(glyphContent)
          \(sheenOverlay)
        </svg>
        """
    }

    public static func svgString(config: TomoThemeConfig) -> String {
        svgString(
            family: config.logoFamily,
            logoContent: config.logoContent,
            notch: config.notchMode == "on",
            accentColor: config.accentColor,
            accentEndColor: config.accentEndColor,
            fillType: config.fillType,
            gradientAngle: config.gradientAngle,
            renderMode: config.renderMode,
            glyphMode: config.glyphMode,
            tileBgColor: config.tileBgColor,
            materialTexture: config.materialTexture,
            glassOpacity: config.glassOpacity
        )
    }

    public static func image(
        family: String,
        logoContent: String = "t",
        notch: Bool,
        accentColor: String,
        accentEndColor: String? = nil,
        fillType: String = "solid",
        gradientAngle: Int = 135,
        renderMode: String = "color",
        glyphMode: String = "solid",
        tileBgColor: String = "#FFFFFF",
        materialTexture: String = "flat",
        glassOpacity: Double = 0.72,
        targetSize: NSSize = NSSize(width: 100, height: 100)
    ) -> NSImage? {
        let svg = svgString(
            family: family,
            logoContent: logoContent,
            notch: notch,
            accentColor: accentColor,
            accentEndColor: accentEndColor,
            fillType: fillType,
            gradientAngle: gradientAngle,
            renderMode: renderMode,
            glyphMode: glyphMode,
            tileBgColor: tileBgColor,
            materialTexture: materialTexture,
            glassOpacity: glassOpacity
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
            logoContent: config.logoContent,
            notch: config.notchMode == "on",
            accentColor: config.accentColor,
            accentEndColor: config.accentEndColor,
            fillType: config.fillType,
            gradientAngle: config.gradientAngle,
            renderMode: config.renderMode,
            glyphMode: config.glyphMode,
            tileBgColor: config.tileBgColor,
            materialTexture: config.materialTexture,
            glassOpacity: config.glassOpacity,
            targetSize: NSSize(width: size, height: size)
        )
        return fallback ?? NSImage(size: NSSize(width: size, height: size))
    }

    /// Generates a valid multi-resolution macOS .icns file using the system /usr/bin/iconutil tool.
    public static func generateIcns(image: NSImage, outputPath: String) -> Bool {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("tomo_iconset_" + UUID().uuidString + ".iconset")
        defer { try? fm.removeItem(at: tempDir) }

        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            return false
        }

        let sizes = [16, 32, 128, 256, 512]
        for s in sizes {
            for scale in [1, 2] {
                let px = s * scale
                guard let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: px,
                    pixelsHigh: px,
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0,
                    bitsPerPixel: 0
                ) else { continue }

                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                image.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1.0)
                NSGraphicsContext.restoreGraphicsState()

                guard let png = rep.representation(using: .png, properties: [:]) else { continue }
                let filename = scale == 1 ? "icon_\(s)x\(s).png" : "icon_\(s)x\(s)@2x.png"
                try? png.write(to: tempDir.appendingPathComponent(filename))
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", tempDir.path, "-o", outputPath]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Persists the custom icon to the macOS .app bundle on disk so Finder, Launchpad & Spotlight display the configured icon.
    @MainActor
    public static func updateSystemBundleIcon(config: TomoThemeConfig, refreshLaunchpad: Bool = false) {
        let icon = appIconImage(config: config, size: 512)

        // Find candidate application bundles
        var targetPaths: [String] = []
        let mainPath = Bundle.main.bundlePath
        if mainPath.hasSuffix(".app") {
            targetPaths.append(mainPath)
        }
        let devDistPath = NSString(string: "~/code/Personal/Tomo/app/Tomo/dist/Tomo.app").expandingTildeInPath
        if FileManager.default.fileExists(atPath: devDistPath) && !targetPaths.contains(devDistPath) {
            targetPaths.append(devDistPath)
        }
        let installedAppPath = "/Applications/Tomo.app"
        if FileManager.default.fileExists(atPath: installedAppPath) && !targetPaths.contains(installedAppPath) {
            targetPaths.append(installedAppPath)
        }

        guard !targetPaths.isEmpty else { return }
        let paths = targetPaths

        // Perform disk I/O, icns generation and LaunchServices registration off the main thread
        DispatchQueue.global(qos: .utility).async {
            for path in paths {
                // 1. Set macOS custom icon on the folder / bundle
                DispatchQueue.main.sync {
                    _ = NSWorkspace.shared.setIcon(icon, forFile: path, options: [])
                }

                // 2. Overwrite Contents/Resources/AppIcon.icns if writable
                let icnsPath = "\(path)/Contents/Resources/AppIcon.icns"
                let resDir = "\(path)/Contents/Resources"
                if FileManager.default.isWritableFile(atPath: icnsPath) || FileManager.default.isWritableFile(atPath: resDir) {
                    _ = generateIcns(image: icon, outputPath: icnsPath)
                }

                // 3. Touch bundle to update mtime
                let touch = Process()
                touch.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
                touch.arguments = [path]
                try? touch.run()
                touch.waitUntilExit()

                // 4. Register with LaunchServices
                let lsregisterPath = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
                let ls = Process()
                ls.executableURL = URL(fileURLWithPath: lsregisterPath)
                ls.arguments = ["-f", path]
                try? ls.run()
                ls.waitUntilExit()

                DispatchQueue.main.async {
                    NSWorkspace.shared.noteFileSystemChanged(path)
                }
            }

            if refreshLaunchpad {
                let dockProc = Process()
                dockProc.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
                dockProc.arguments = ["Dock"]
                try? dockProc.run()
            }
        }
    }
}

// MARK: - Apple App Icon HIG Standard Baseline & Proportion Grid (Reference Auxiliary Overlay Only)

public struct AppleIconGridOverlay: View {
    public var isDark: Bool = false
    public var strokeColor: Color? = nil

    public init(isDark: Bool = false, strokeColor: Color? = nil) {
        self.isDark = isDark
        self.strokeColor = strokeColor
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let cx = w * 0.5
            let cy = h * 0.5
            let color = strokeColor ?? (isDark ? Color.white : Color(hex: "#2563eb"))
            let baseOp: Double = isDark ? 0.42 : 0.40

            // The App Icon tile occupies 82.8% of the stage canvas
            // Radius R = (w * 0.828) / 2 = w * 0.414
            let tileD = w * 0.828
            let rOuter = tileD * 0.5
            let rInner = rOuter / 1.41421356 // rOuter / sqrt(2) = safe area radius
            let innerD = rInner * 2.0

            // 4 vertical and horizontal guide offsets from center
            let xOuterL = cx - rOuter
            let xOuterR = cx + rOuter
            let xInnerL = cx - rInner
            let xInnerR = cx + rInner

            let yOuterT = cy - rOuter
            let yOuterB = cy + rOuter
            let yInnerT = cy - rInner
            let yInnerB = cy + rInner

            let solidLineWidth = max(0.65, w * 0.007)
            let dashLineWidth = max(0.5, w * 0.005)
            let dashPattern: [CGFloat] = [3, 2.5]

            ZStack {
                // 1. Solid Center Crosshairs (Continuous axes spanning the full canvas)
                Path { path in
                    path.move(to: CGPoint(x: cx, y: 0))
                    path.addLine(to: CGPoint(x: cx, y: h))
                    path.move(to: CGPoint(x: 0, y: cy))
                    path.addLine(to: CGPoint(x: w, y: cy))
                }
                .stroke(color.opacity(baseOp), lineWidth: solidLineWidth)

                // 2. Solid 45-Degree Diagonals (Crossing center cx, cy and spanning full canvas)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 0))
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.move(to: CGPoint(x: 0, y: h))
                    path.addLine(to: CGPoint(x: w, y: 0))
                }
                .stroke(color.opacity(baseOp * 0.95), lineWidth: solidLineWidth * 0.95)

                // 3. Dashed Extension Guidelines (4 Vertical + 4 Horizontal Guides)
                Path { path in
                    // 4 Vertical Guides
                    path.move(to: CGPoint(x: xOuterL, y: 0))
                    path.addLine(to: CGPoint(x: xOuterL, y: h))
                    path.move(to: CGPoint(x: xInnerL, y: 0))
                    path.addLine(to: CGPoint(x: xInnerL, y: h))
                    path.move(to: CGPoint(x: xInnerR, y: 0))
                    path.addLine(to: CGPoint(x: xInnerR, y: h))
                    path.move(to: CGPoint(x: xOuterR, y: 0))
                    path.addLine(to: CGPoint(x: xOuterR, y: h))

                    // 4 Horizontal Guides
                    path.move(to: CGPoint(x: 0, y: yOuterT))
                    path.addLine(to: CGPoint(x: w, y: yOuterT))
                    path.move(to: CGPoint(x: 0, y: yInnerT))
                    path.addLine(to: CGPoint(x: w, y: yInnerT))
                    path.move(to: CGPoint(x: 0, y: yInnerB))
                    path.addLine(to: CGPoint(x: w, y: yInnerB))
                    path.move(to: CGPoint(x: 0, y: yOuterB))
                    path.addLine(to: CGPoint(x: w, y: yOuterB))
                }
                .stroke(color.opacity(baseOp * 0.75), style: StrokeStyle(lineWidth: dashLineWidth, dash: dashPattern))

                // 4. Outer Squircle Boundary (Matches App Icon Squircle: 82.8% tile, corner radius 22.4%)
                RoundedRectangle(cornerRadius: tileD * 0.224, style: .continuous)
                    .stroke(color.opacity(baseOp), lineWidth: solidLineWidth)
                    .frame(width: tileD, height: tileD)

                // 5. Outer Circle (Radius R = tileD / 2, tangent to the 4 outer dashed guides & tile edges)
                Circle()
                    .stroke(color.opacity(baseOp * 0.95), lineWidth: solidLineWidth)
                    .frame(width: tileD, height: tileD)

                // 6. Inner Circle (Radius r = R / sqrt(2), inscribed in and tangent to the 4 inner dashed guides)
                Circle()
                    .stroke(color.opacity(baseOp * 0.85), lineWidth: solidLineWidth * 0.9)
                    .frame(width: innerD, height: innerD)

                // 7. Inner Safe-Area Rounded Rectangle (70.71% width, corners aligned on diagonals and outer circle)
                RoundedRectangle(cornerRadius: innerD * 0.224, style: .continuous)
                    .stroke(color.opacity(baseOp * 0.80), style: StrokeStyle(lineWidth: dashLineWidth, dash: dashPattern))
                    .frame(width: innerD, height: innerD)
            }
            .frame(width: w, height: h)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - SwiftUI View for Transparent Vector Mark & App Icon Tile

public struct TomoMarkView: View {
    public let family: String
    public let logoContent: String
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
    public let materialTexture: String
    public let glassOpacity: Double
    public let showTile: Bool
    public let showAppleGrid: Bool
    public var size: CGFloat

    public init(
        family: String = "circle",
        logoContent: String = "t",
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
        logoScale: Double = 0.90,
        shadowDirection: String = "down",
        materialTexture: String = "flat",
        glassOpacity: Double = 0.72,
        showTile: Bool = false,
        showAppleGrid: Bool = false,
        size: CGFloat = 36
    ) {
        self.family = family
        self.logoContent = logoContent
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
        self.materialTexture = materialTexture
        self.glassOpacity = glassOpacity
        self.showTile = showTile
        self.showAppleGrid = showAppleGrid
        self.size = size
    }

    public init(config: TomoThemeConfig, size: CGFloat = 36, showTile: Bool = false, showAppleGrid: Bool = false) {
        self.family = config.logoFamily
        self.logoContent = config.logoContent
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
        self.materialTexture = config.materialTexture
        self.glassOpacity = config.glassOpacity
        self.showTile = showTile
        self.showAppleGrid = showAppleGrid
        self.size = size
    }


    private func gradientPoints(for angle: Int) -> (UnitPoint, UnitPoint) {
        switch angle {
        case 180: return (.top, .bottom)
        case 90:  return (.leading, .trailing)
        case 45:  return (.bottomLeading, .topTrailing)
        default:  return (.topLeading, .bottomTrailing) // 135
        }
    }

    private var effectiveTileBg: Color {
        if renderMode == "inverse" {
            return Color(hex: accentColor)
        }
        return Color(hex: tileBgColor)
    }

    private var isTileBackgroundDark: Bool {
        if renderMode == "inverse" { return true }
        let hex = tileBgColor.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if let val = Int(hex, radix: 16), hex.count == 6 {
            let r = Double((val >> 16) & 0xff) / 255.0
            let g = Double((val >> 8) & 0xff) / 255.0
            let b = Double(val & 0xff) / 255.0
            return (0.299 * r + 0.587 * g + 0.114 * b) < 0.5
        }
        return false
    }

    public var body: some View {
        // macOS App Icon standard squircle occupies ~82.8% of the canvas
        let tileSize = showTile ? size * 0.828 : size
        let markSize = tileSize * CGFloat(logoScale)
        let isSoft = shadowStyle == "soft"
        let scaleRatio = markSize / 100.0

        // 1. 微距紧贴接触投影（Contact Shadow：稳固底板接触面重心，消除悬浮位移感）
        let contactColor: Color = (shadowEnabled && renderMode != "inverse")
            ? Color.black.opacity(isSoft ? 0.06 : 0.08)
            : Color.clear
        let contactRadius = (isSoft ? 2.0 : 1.5) * scaleRatio
        let contactOffsets: (x: CGFloat, y: CGFloat) = {
            if !shadowEnabled || renderMode == "inverse" { return (0, 0) }
            switch shadowDirection {
            case "down":
                return (0, (isSoft ? 1.5 : 1.0) * scaleRatio)
            case "up":
                return (0, -(isSoft ? 1.5 : 1.0) * scaleRatio)
            case "bottomRight":
                return ((isSoft ? 1.0 : 0.7) * scaleRatio, (isSoft ? 1.5 : 1.0) * scaleRatio)
            case "radial":
                return (0, 0)
            default:
                return (0, (isSoft ? 1.5 : 1.0) * scaleRatio)
            }
        }()

        // 2. 色彩流体环境光投影（Ambient Shadow：自然微距立体光晕）
        let ambientColor: Color = {
            if !shadowEnabled || renderMode == "inverse" { return Color.clear }
            if renderMode == "mono" {
                return Color.black.opacity(isSoft ? 0.20 : 0.16)
            }
            return Color(hex: accentColor).opacity(isSoft ? 0.44 : 0.38)
        }()
        let ambientRadius = (isSoft ? 9.0 : 5.0) * scaleRatio
        let ambientOffsets: (x: CGFloat, y: CGFloat) = {
            if !shadowEnabled || renderMode == "inverse" { return (0, 0) }
            switch shadowDirection {
            case "down":
                return (0, (isSoft ? 4.5 : 2.5) * scaleRatio)
            case "up":
                return (0, -(isSoft ? 4.5 : 2.5) * scaleRatio)
            case "bottomRight":
                return ((isSoft ? 3.5 : 2.0) * scaleRatio, (isSoft ? 3.5 : 2.0) * scaleRatio)
            case "radial":
                return (0, 0)
            default:
                return (0, (isSoft ? 4.5 : 2.5) * scaleRatio)
            }
        }()

        let imageNode: some View = Group {
            if let image = TomoMarkSvgRenderer.image(
                family: family,
                logoContent: logoContent,
                notch: notch,
                accentColor: accentColor,
                accentEndColor: accentEndColor,
                fillType: fillType,
                gradientAngle: gradientAngle,
                renderMode: renderMode,
                glyphMode: glyphMode,
                tileBgColor: tileBgColor,
                materialTexture: materialTexture,
                glassOpacity: glassOpacity,
                targetSize: NSSize(width: markSize, height: markSize)
            ) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: markSize, height: markSize)
                    .shadow(color: contactColor, radius: contactRadius, x: contactOffsets.x, y: contactOffsets.y)
                    .shadow(color: ambientColor, radius: ambientRadius, x: ambientOffsets.x, y: ambientOffsets.y)
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
                if renderMode == "inverse" && materialTexture == "glass" {
                    let cStartHex = fillType == "gradient" ? accentColor : TomoMarkSvgRenderer.blendHex(accentColor, "#ffffff", ratio: 0.04)
                    let cEndHex = fillType == "gradient" ? (accentEndColor ?? accentColor) : TomoMarkSvgRenderer.blendHex(accentColor, "#000000", ratio: 0.06)
                    let (startPt, endPt) = fillType == "gradient" ? gradientPoints(for: gradientAngle) : (.topLeading, .bottomTrailing)

                    let tintGradient = LinearGradient(
                        stops: [
                            .init(color: Color(hex: cStartHex).opacity(glassOpacity * 0.95), location: 0.0),
                            .init(color: Color(hex: accentColor).opacity(glassOpacity), location: 0.5),
                            .init(color: Color(hex: cEndHex).opacity(min(0.98, glassOpacity * 1.05)), location: 1.0)
                        ],
                        startPoint: startPt,
                        endPoint: endPt
                    )

                    let rimGradient = LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.95), location: 0.0),
                            .init(color: .white.opacity(0.55), location: 0.35),
                            .init(color: .white.opacity(0.18), location: 0.70),
                            .init(color: .white.opacity(0.45), location: 1.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    RoundedRectangle(cornerRadius: tileSize * 0.224, style: .continuous)
                        .fill(tintGradient)
                        .overlay(
                            RoundedRectangle(cornerRadius: tileSize * 0.224, style: .continuous)
                                .stroke(rimGradient, lineWidth: 1.3)
                        )
                        .shadow(color: Color.black.opacity(0.24), radius: size * 0.035, x: 0, y: size * 0.024)
                        .frame(width: tileSize, height: tileSize)
                } else if renderMode == "inverse" && fillType == "gradient" {
                    let start = Color(hex: accentColor)
                    let end = Color(hex: accentEndColor ?? accentColor)
                    let (startPt, endPt) = gradientPoints(for: gradientAngle)
                    RoundedRectangle(cornerRadius: tileSize * 0.224, style: .continuous)
                        .fill(LinearGradient(colors: [start, end], startPoint: startPt, endPoint: endPt))
                        .overlay(
                            RoundedRectangle(cornerRadius: tileSize * 0.224, style: .continuous)
                                .stroke(Color.black.opacity(0.08), lineWidth: 0.8)
                        )
                        .shadow(color: Color.black.opacity(0.24), radius: size * 0.035, x: 0, y: size * 0.024)
                        .frame(width: tileSize, height: tileSize)
                } else {
                    RoundedRectangle(cornerRadius: tileSize * 0.224, style: .continuous)
                        .fill(effectiveTileBg)
                        .overlay(
                            RoundedRectangle(cornerRadius: tileSize * 0.224, style: .continuous)
                                .stroke(Color.black.opacity(0.08), lineWidth: 0.8)
                        )
                        .shadow(color: Color.black.opacity(0.24), radius: size * 0.035, x: 0, y: size * 0.024)
                        .frame(width: tileSize, height: tileSize)
                }

                if renderMode == "inverse" && materialTexture == "glass" {
                    imageNode
                        .shadow(color: Color.black.opacity(0.22), radius: size * 0.015, x: 0, y: size * 0.012)
                } else {
                    imageNode
                }

                if showAppleGrid {
                    AppleIconGridOverlay(isDark: isTileBackgroundDark)
                        .frame(width: size, height: size)
                }
            }
            .frame(width: size, height: size)
        } else {
            if showAppleGrid {
                ZStack {
                    imageNode
                    AppleIconGridOverlay(isDark: isTileBackgroundDark)
                        .frame(width: size, height: size)
                }
                .frame(width: size, height: size)
            } else {
                imageNode
            }
        }
    }
}
