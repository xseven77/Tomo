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
        gradientAngle: Int = 135
    ) -> String {
        let isNotched = notch
        let fillRef: String
        var defs = ""

        if fillType == "gradient" {
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
            fillRef = accentColor
        }

        var pathContent = ""
        switch family {
        case "circle":
            var body = "M85 50A35 35 0 1 1 15 50A35 35 0 1 1 85 50ZM34 31Q30 31 30 35V40Q30 44 34 44H42V65Q42 70 47 70H53Q58 70 58 65V44H66Q70 44 70 40V35Q70 31 66 31Z"
            if isNotched {
                body = body.replacingOccurrences(of: T_STD_CLOSED, with: T_STD_NOTCHED)
            }
            pathContent = "<path fill-rule=\"evenodd\" d=\"\(body)\" fill=\"\(fillRef)\"/>"

        case "squircle":
            var body = "M40 16H60C77 16 84 23 84 40V60C84 77 77 84 60 84H40C23 84 16 77 16 60V40C16 23 23 16 40 16ZM34 31Q30 31 30 35V40Q30 44 34 44H42V65Q42 70 47 70H53Q58 70 58 65V44H66Q70 44 70 40V35Q70 31 66 31Z"
            if isNotched {
                body = body.replacingOccurrences(of: T_STD_CLOSED, with: T_STD_NOTCHED)
            }
            pathContent = "<path fill-rule=\"evenodd\" d=\"\(body)\" fill=\"\(fillRef)\"/>"

        case "cloud7":
            var body = "M 50.00 18.50 Q 69.09 10.36 74.63 30.36 Q 92.90 40.21 80.71 57.01 Q 84.40 77.43 63.67 78.38 Q 50.00 94.00 36.33 78.38 Q 15.60 77.43 19.29 57.01 Q 7.10 40.21 25.37 30.36 Q 30.91 10.36 50.00 18.50Z M35.60 32.90Q32.00 32.90 32.00 36.50V41.00Q32.00 44.60 35.60 44.60H42.80V63.50Q42.80 68.00 47.30 68.00H52.70Q57.20 68.00 57.20 63.50V44.60H64.40Q68.00 44.60 68.00 41.00V36.50Q68.00 32.90 64.40 32.90Z"
            if isNotched {
                body = body.replacingOccurrences(of: T_G8_CLOSED, with: T_G8_NOTCHED)
            }
            pathContent = "<path fill-rule=\"evenodd\" d=\"\(body)\" fill=\"\(fillRef)\"/>"

        case "quota":
            let body = "M44 16Q50 13 56 16L76 27Q82 30 82 37V63Q82 70 76 73L56 84Q50 87 44 84L24 73Q18 70 18 63V37Q18 30 24 27ZM34 30H39Q43 30 43 34V39Q43 43 39 43H34Q30 43 30 39V34Q30 30 34 30ZM61 57H66Q70 57 70 61V66Q70 70 66 70H61Q57 70 57 66V61Q57 57 61 57ZM60 30Q63 27 66 30Q69 32 66 36L40 70Q37 73 34 70Q31 68 34 64Z"
            pathContent = "<path fill-rule=\"evenodd\" d=\"\(body)\" fill=\"\(fillRef)\"/>"

        default: // "hex"
            var body = "M44 16Q50 13 56 16L76 27Q82 30 82 37V63Q82 70 76 73L56 84Q50 87 44 84L24 73Q18 70 18 63V37Q18 30 24 27ZM34 31Q30 31 30 35V40Q30 44 34 44H42V65Q42 70 47 70H53Q58 70 58 65V44H66Q70 44 70 40V35Q70 31 66 31Z"
            if isNotched {
                body = body.replacingOccurrences(of: T_STD_CLOSED, with: T_STD_NOTCHED)
            }
            pathContent = "<path fill-rule=\"evenodd\" d=\"\(body)\" fill=\"\(fillRef)\"/>"
        }

        return """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
          \(defs)
          \(pathContent)
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
        targetSize: NSSize = NSSize(width: 100, height: 100)
    ) -> NSImage? {
        let svg = svgString(
            family: family,
            notch: notch,
            accentColor: accentColor,
            accentEndColor: accentEndColor,
            fillType: fillType,
            gradientAngle: gradientAngle
        )
        guard let data = svg.data(using: .utf8) else { return nil }
        guard let image = NSImage(data: data) else { return nil }
        image.size = targetSize
        return image
    }
}

// MARK: - SwiftUI View for Transparent Vector Mark

public struct TomoMarkView: View {
    public let family: String
    public let notch: Bool
    public let accentColor: String
    public let accentEndColor: String?
    public let fillType: String
    public let gradientAngle: Int
    public var size: CGFloat

    public init(
        family: String = "hex",
        notch: Bool = false,
        accentColor: String = "#D74C32",
        accentEndColor: String? = nil,
        fillType: String = "solid",
        gradientAngle: Int = 135,
        size: CGFloat = 36
    ) {
        self.family = family
        self.notch = notch
        self.accentColor = accentColor
        self.accentEndColor = accentEndColor
        self.fillType = fillType
        self.gradientAngle = gradientAngle
        self.size = size
    }

    public init(config: TomoThemeConfig, size: CGFloat = 36) {
        self.family = config.logoFamily
        self.notch = config.notchMode == "on"
        self.accentColor = config.accentColor
        self.accentEndColor = config.accentEndColor
        self.fillType = config.fillType
        self.gradientAngle = config.gradientAngle
        self.size = size
    }

    public var body: some View {
        if let image = TomoMarkSvgRenderer.image(
            family: family,
            notch: notch,
            accentColor: accentColor,
            accentEndColor: accentEndColor,
            fillType: fillType,
            gradientAngle: gradientAngle,
            targetSize: NSSize(width: size, height: size)
        ) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "hexagon")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        }
    }
}
