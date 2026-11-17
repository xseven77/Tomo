import Foundation
import CryptoKit

/// A completed tool's explicitly mapped, user-visible text. Kept outside the
/// small sync/SSE projection. This is never an upstream item or arbitrary JSON.
struct RemoteToolResultText: Equatable, Sendable {
    static let byteLimit = 16 * 1024 * 1024 // matches the app-server frame ceiling
    let text: String
    let truncated: Bool

    init(title: String, blocks: [RemoteToolPresentation.Block], truncated: Bool) {
        var data = Data(title.utf8), cut = truncated
        for block in blocks {
            let value = "\n\n" + block.label + "\n" + block.text.replacingOccurrences(of: "\0", with: "�")
            let remaining = Self.byteLimit - data.count
            if value.utf8.count > remaining {
                var prefix = Data(value.utf8.prefix(remaining))
                while String(data: prefix, encoding: .utf8) == nil { prefix.removeLast() }
                data.append(prefix); cut = true; break
            }
            data.append(contentsOf: value.utf8)
        }
        self.text = String(decoding: data, as: UTF8.self); self.truncated = cut
    }

    init(text: String, truncated: Bool) { self.text = text; self.truncated = truncated }
    var valid: Bool { !text.isEmpty && !text.contains("\0") && text.utf8.count <= Self.byteLimit }
    var version: String {
        var bytes = Data(text.utf8); bytes.append(truncated ? 1 : 0)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

struct RemoteToolResultPage: Codable, Equatable, Sendable {
    let activityId: String
    let resultVersion: String
    let text: String
    let utf8Offset: Int
    let totalUTF8Bytes: Int
    let truncated: Bool
    var nextCursor: String?
}
