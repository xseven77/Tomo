import AppKit
import ImageIO
import XCTest
@testable import Tomo

@MainActor
final class LogoPNGExportTests: XCTestCase {
    func testBothLettermarksExportAtExactPixelsWithTransparentOuterCanvas() throws {
        var results: [Data] = []
        for family in ["pure", "pure_go"] {
            let config = TomoThemeConfig(logoFamily: family, accentColor: "#007AFF", materialTexture: "glass")
            let original = config
            let png = try TomoMarkSvgRenderer.exportedPNG(config: config)
            XCTAssertEqual(config, original)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, 1024)
            XCTAssertEqual(image.height, 1024)
            var pixels = [UInt8](repeating: 0, count: 1024 * 1024 * 4)
            try pixels.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1024, height: 1024, bitsPerComponent: 8,
                    bytesPerRow: 1024 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
            }
            XCTAssertEqual(pixels[3], 0)
            var opaque = 0
            for index in stride(from: 3, to: pixels.count, by: 4) where pixels[index] > 200 { opaque += 1 }
            XCTAssertGreaterThan(opaque, 100_000, "Export must contain visible artwork")
            results.append(png)
        }
        XCTAssertNotEqual(results[0], results[1])
    }
}
