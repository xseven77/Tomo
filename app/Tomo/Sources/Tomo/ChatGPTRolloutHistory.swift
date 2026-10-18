import Foundation
import CryptoKit
import Darwin

struct RemoteHistoryPart: Codable, Equatable, Sendable {
    let partId: String
    let type: String
    let text: String
}
struct RemoteHistoryMessage: Codable, Equatable, Sendable {
    let messageId: String
    let turnId: String?
    let messageRevision: Int
    let role: String
    let createdAt: String
    let status: String
    let content: [RemoteHistoryPart]
    enum CodingKeys: String, CodingKey { case messageId, turnId, messageRevision, role, createdAt, status, content }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(messageId, forKey: .messageId)
        try values.encode(turnId, forKey: .turnId)
        try values.encode(messageRevision, forKey: .messageRevision)
        try values.encode(role, forKey: .role)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(status, forKey: .status)
        try values.encode(content, forKey: .content)
    }
}
struct RolloutHistoryWindow: Sendable {
    let messages: [RemoteHistoryMessage]
    let snapshotBytes: UInt64
    /// Internal byte boundary, never accepted directly from an HTTP client.
    let olderBeforeOffset: UInt64?
    let unsupportedContentCount: Int
    let snapshotDigest: String
}
enum RolloutHistoryError: Error, Equatable {
    case invalidWindow
    case sessionMismatch
    case missingSessionMetadata
    case malformedRecord
    case recordTooLarge
    case snapshotTruncated
    case fileTooLarge
    case snapshotChanged
}

/// Reads only visible user/assistant messages from a trusted runtime's rollout.
/// No reasoning, system/developer prompts, or vendor tool arguments are exported.
/// Adapter/index code must resolve the URL from an owner-registered storage root.
struct ChatGPTRolloutHistory: Sendable {
    private static let sessionMetaPattern = Data("\"session_meta\"".utf8)
    private static let taskStartedPattern = Data("\"task_started\"".utf8)
    private static let responseItemPattern = Data("\"response_item\"".utf8)
    private static let messagePattern = Data("\"message\"".utf8)

    // Vendor logs can contain multi-MB tool output or inline image payloads,
    // even when those fields are excluded from the visible history projection.
    var maximumRecordBytes = 16_777_216
    var maximumSnapshotBytes: UInt64 = 2_147_483_648

    func read(url: URL, expectedSessionID: String, namespace: String, limit: Int = 50,
              snapshotBytes: UInt64? = nil, beforeOffset: UInt64? = nil) throws -> RolloutHistoryWindow {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try read(file: file, expectedSessionID: expectedSessionID, namespace: namespace,
            limit: limit, snapshotBytes: snapshotBytes, beforeOffset: beforeOffset)
    }

    /// The runtime resolver supplies an already pinned, validated descriptor.
    func read(file: FileHandle, expectedSessionID: String, namespace: String, limit: Int = 50,
              snapshotBytes: UInt64? = nil, beforeOffset: UInt64? = nil) throws -> RolloutHistoryWindow {
        guard (1...100).contains(limit), !expectedSessionID.isEmpty, !namespace.isEmpty else {
            throw RolloutHistoryError.invalidWindow
        }
        let size = try file.seekToEnd()
        let snapshot = snapshotBytes ?? size
        guard snapshot <= size else { throw RolloutHistoryError.snapshotTruncated }
        guard snapshot <= maximumSnapshotBytes else { throw RolloutHistoryError.fileTooLarge }
        let boundary = beforeOffset ?? snapshot
        guard boundary <= snapshot else { throw RolloutHistoryError.invalidWindow }
        try file.seek(toOffset: 0)
        var remaining = snapshot
        var snapshotHasher = SHA256()
        var line = Data()
        var offset: UInt64 = 0
        var lineStart: UInt64 = 0
        var metadataSeen = false
        var discardingCompaction = false
        var turnID: String?
        var window: [(offset: UInt64, message: RemoteHistoryMessage, unsupported: Int)] = []
        var hasOlder = false
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainFormatter = ISO8601DateFormatter()

        func canDiscardCompaction(_ data: Data) -> Bool {
            guard metadataSeen else { return false }
            let prefix = String(decoding: data.prefix(4096), as: UTF8.self)
            guard let delimiter = prefix.range(of: #",\s*"payload"\s*:"#, options: .regularExpression),
                  let header = (String(prefix[..<delimiter.lowerBound]) + "}").data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: header) as? [String: Any],
                  Set(object.keys).isSubset(of: ["timestamp", "type"]), object["type"] as? String == "compacted" else { return false }
            return true
        }

        func checkRecordBound() throws {
            guard line.count > maximumRecordBytes else { return }
            if canDiscardCompaction(line) {
                discardingCompaction = true
                line.removeAll(keepingCapacity: false)
            } else { throw RolloutHistoryError.recordTooLarge }
        }

        func process(_ data: Data, at start: UInt64) throws {
            guard !data.isEmpty else { return }

            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let kind = object["type"] as? String else {
                throw RolloutHistoryError.malformedRecord
            }
            if kind == "session_meta" {
                guard let payload = object["payload"] as? [String: Any] else { throw RolloutHistoryError.malformedRecord }
                guard payload["id"] as? String == expectedSessionID else { throw RolloutHistoryError.sessionMismatch }
                metadataSeen = true
                return
            }
            guard metadataSeen else { throw RolloutHistoryError.missingSessionMetadata }
            guard ["event_msg", "response_item"].contains(kind) else { return }
            guard let payload = object["payload"] as? [String: Any] else { throw RolloutHistoryError.malformedRecord }
            if kind == "event_msg", payload["type"] as? String == "task_started" {
                turnID = payload["turn_id"] as? String
            }
            guard start < boundary, kind == "response_item", payload["type"] as? String == "message",
                  let role = payload["role"] as? String, ["user", "assistant"].contains(role) else { return }
            guard payload["phase"] as? String != "analysis" else { return }
            guard let timestamp = object["timestamp"] as? String,
                  let date = formatter.date(from: timestamp) ?? plainFormatter.date(from: timestamp),
                  let blocks = payload["content"] as? [[String: Any]] else {
                throw RolloutHistoryError.malformedRecord
            }
            var parts: [RemoteHistoryPart] = []
            var unsupported = 0
            for (index, block) in blocks.enumerated() {
                let type = block["type"] as? String
                if ["input_text", "output_text", "text"].contains(type), let text = block["text"] as? String {
                    parts.append(.init(partId: "part_\(index)", type: "text", text: text))
                } else {
                    unsupported += 1
                    parts.append(.init(partId: "part_\(index)", type: "text", text: "[Unsupported attachment]"))
                }
            }
            guard !parts.isEmpty else { return }
            // Byte positions remain stable while a rollout is append-only. Account
            // namespace prevents identical vendor IDs from sharing message identity.
            let identity = Data("\(namespace)\u{0}\(expectedSessionID)\u{0}\(start)".utf8)
            let digest = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
            let message = RemoteHistoryMessage(messageId: "msg_" + String(digest.prefix(32)), turnId: turnID,
                messageRevision: 1, role: role, createdAt: formatter.string(from: date), status: "completed", content: parts)
            window.append((start, message, unsupported))
            if window.count > limit { window.removeFirst(); hasOlder = true }
        }

        while remaining > 0 {
            let toRead = Int(min(remaining, 1_048_576))
            guard let chunk = try file.read(upToCount: toRead), !chunk.isEmpty else {
                throw RolloutHistoryError.snapshotTruncated
            }
            remaining -= UInt64(chunk.count)
            snapshotHasher.update(data: chunk)

            try chunk.withUnsafeBytes { raw in
                guard let basePtr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                var cursor = 0
                let count = raw.count
                while cursor < count {
                    let ptr = basePtr + cursor
                    let left = count - cursor
                    if let found = memchr(ptr, 10, left) {
                        let lineLen = UnsafeRawPointer(found) - UnsafeRawPointer(ptr)
                        if discardingCompaction {
                            discardingCompaction = false
                        } else if line.isEmpty {
                            let lineData = Data(bytes: ptr, count: lineLen)
                            if lineData.count > maximumRecordBytes {
                                guard canDiscardCompaction(lineData) else { throw RolloutHistoryError.recordTooLarge }
                            } else {
                                do { try process(lineData, at: lineStart) }
                                catch let error as RolloutHistoryError { throw error }
                                catch { throw RolloutHistoryError.malformedRecord }
                            }
                        } else {
                            line.append(ptr, count: lineLen)
                            try checkRecordBound()
                            if !discardingCompaction {
                                do { try process(line, at: lineStart) }
                                catch let error as RolloutHistoryError { throw error }
                                catch { throw RolloutHistoryError.malformedRecord }
                            }
                            discardingCompaction = false
                            line.removeAll(keepingCapacity: true)
                        }
                        cursor += lineLen + 1
                        offset += UInt64(lineLen + 1)
                        lineStart = offset
                    } else {
                        if !discardingCompaction {
                            line.append(ptr, count: left)
                            try checkRecordBound()
                        }
                        cursor += left
                        offset += UInt64(left)
                    }
                }
            }
        }
        // A writer may be appending a partial JSON record. It is not a message
        // until newline-committed, and is retried in the next snapshot.
        guard metadataSeen else { throw RolloutHistoryError.missingSessionMetadata }
        return RolloutHistoryWindow(messages: window.map(\.message), snapshotBytes: snapshot,
            olderBeforeOffset: hasOlder ? window.first?.offset : nil,
            unsupportedContentCount: window.reduce(0) { $0 + $1.unsupported },
            snapshotDigest: snapshotHasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
