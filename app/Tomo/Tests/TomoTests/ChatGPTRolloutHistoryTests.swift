import Foundation
import Testing
@testable import Tomo

struct ChatGPTRolloutHistoryTests {
    @Test func largeCompactionMetadataIsDiscardedWithoutRelaxingMessageBounds() throws {
        for count in [2048, 2_100_000] {
            var data = try meta
            data.append(Data(("{\"timestamp\":\"2026-10-03T00:00:00Z\",\"type\":\"compacted\",\"payload\":{\"replacement_history\":\"" + String(repeating: "x", count: count) + "\"}}\n").utf8))
            data.append(try message("actual visible message"))
            try withFile(data) { url in
                let result = try ChatGPTRolloutHistory(maximumRecordBytes: 512).read(url: url, expectedSessionID: "vendor-session", namespace: "a")
                #expect(result.messages.count == 1)
                #expect(result.messages[0].content[0].text == "actual visible message")
                #expect(result.snapshotBytes == UInt64(data.count))
            }
        }
        var oversizedMessage = try meta
        oversizedMessage.append(try message(String(repeating: "x", count: 2048)))
        try withFile(oversizedMessage) { url in
            #expect(throws: RolloutHistoryError.recordTooLarge) {
                try ChatGPTRolloutHistory(maximumRecordBytes: 512).read(url: url, expectedSessionID: "vendor-session", namespace: "a")
            }
        }
    }

    private func record(_ type: String, _ payload: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": "2026-10-03T00:00:00Z", "payload": payload], options: .sortedKeys)
        data.append(10)
        return data
    }
    private func message(_ text: String, role: String = "assistant") throws -> Data {
        try record("response_item", ["type": "message", "role": role, "content": [["type": "output_text", "text": text]]])
    }
    private func withFile(_ data: Data, body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rollout.jsonl")
        try data.write(to: url)
        try body(url)
    }
    private var meta: Data { get throws { try record("session_meta", ["id": "vendor-session"]) } }

    @Test func visibleMessagesExcludePromptsReasoningAndToolArguments() throws {
        var data = try meta
        data.append(try message("private system secret", role: "system"))
        data.append(try message("private developer prompt", role: "developer"))
        data.append(try record("response_item", ["type": "reasoning", "encrypted_content": "hidden reasoning"]))
        data.append(try record("response_item", ["type": "message", "role": "assistant", "phase": "analysis", "content": [["type": "output_text", "text": "hidden analysis"]]]))
        data.append(try record("response_item", ["type": "function_call", "arguments": "secret API key"]))
        data.append(try record("event_msg", ["type": "task_started", "turn_id": "turn-1"]))
        data.append(try message("你好", role: "user"))
        data.append(try record("event_msg", ["type": "agent_message", "message": "duplicate mirror"]))
        data.append(try message("已完成"))
        try withFile(data) { url in
            let result = try ChatGPTRolloutHistory().read(url: url, expectedSessionID: "vendor-session", namespace: "account-a")
            #expect(result.messages.map { $0.content[0].text } == ["你好", "已完成"])
            #expect(result.messages.allSatisfy { $0.turnId == "turn-1" })
            #expect(result.olderBeforeOffset == nil)
        }
    }

    @Test func historicalPagesKeepSnapshotStableAcrossAppendAndDoNotOverlap() throws {
        var data = try meta
        for index in 0..<5 { data.append(try message("message-\(index)")) }
        try withFile(data) { url in
            let reader = ChatGPTRolloutHistory()
            let first = try reader.read(url: url, expectedSessionID: "vendor-session", namespace: "a", limit: 2)
            #expect(first.messages.map { $0.content[0].text } == ["message-3", "message-4"])
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd(); try handle.write(contentsOf: message("new")); try handle.close()
            let firstOffset: UInt64 = try #require(first.olderBeforeOffset)
            let second = try reader.read(url: url, expectedSessionID: "vendor-session", namespace: "a", limit: 2,
                snapshotBytes: first.snapshotBytes, beforeOffset: firstOffset)
            #expect(second.messages.map { $0.content[0].text } == ["message-1", "message-2"])
            let secondOffset: UInt64 = try #require(second.olderBeforeOffset)
            let third = try reader.read(url: url, expectedSessionID: "vendor-session", namespace: "a", limit: 2,
                snapshotBytes: first.snapshotBytes, beforeOffset: secondOffset)
            #expect(third.messages.map { $0.content[0].text } == ["message-0"])
            #expect(third.olderBeforeOffset == nil)
            let refreshed = try reader.read(url: url, expectedSessionID: "vendor-session", namespace: "a", limit: 2)
            #expect(refreshed.messages.map { $0.content[0].text } == ["message-4", "new"])
            #expect(refreshed.messages[0].messageId == first.messages[1].messageId)
        }
    }

    @Test func incompleteAppendIsNotParsedUntilNewlineCommitted() throws {
        let full = try message("new message")
        let split = full.count / 2
        var data = try meta; data.append(try message("complete")); data.append(full.prefix(split))
        try withFile(data) { url in
            let reader = ChatGPTRolloutHistory()
            let first = try reader.read(url: url, expectedSessionID: "vendor-session", namespace: "a")
            #expect(first.messages.count == 1)
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd(); try handle.write(contentsOf: full.dropFirst(split)); try handle.close()
            let next = try reader.read(url: url, expectedSessionID: "vendor-session", namespace: "a")
            #expect(next.messages.count == 2)
            #expect(next.messages[0].messageId == first.messages[0].messageId)
        }
    }

    @Test func accountNamespacesDoNotShareMessageIdentity() throws {
        var data = try meta; data.append(try message("same"))
        try withFile(data) { url in
            let reader = ChatGPTRolloutHistory()
            let a = try reader.read(url: url, expectedSessionID: "vendor-session", namespace: "account-a")
            let b = try reader.read(url: url, expectedSessionID: "vendor-session", namespace: "account-b")
            #expect(a.messages[0].messageId != b.messages[0].messageId)
        }
    }

    @Test func largeToolOutputDoesNotBlockLaterVisibleMessages() throws {
        var data = try meta
        data.append(try record("response_item", ["type": "function_call_output", "output": String(repeating: "x", count: 2_300_000)]))
        data.append(try message("after tool output"))
        try withFile(data) { url in
            let result = try ChatGPTRolloutHistory().read(url: url, expectedSessionID: "vendor-session", namespace: "a")
            #expect(result.messages.count == 1)
            #expect(result.messages[0].content[0].text == "after tool output")
        }
    }

    @Test func wrongSessionMissingMetadataAndMalformedCommittedRecordsFailClosed() throws {
        try withFile(try meta) { url in
            #expect(throws: RolloutHistoryError.sessionMismatch) {
                try ChatGPTRolloutHistory().read(url: url, expectedSessionID: "another", namespace: "a")
            }
        }
        try withFile(try message("unattributed")) { url in
            #expect(throws: RolloutHistoryError.missingSessionMetadata) {
                try ChatGPTRolloutHistory().read(url: url, expectedSessionID: "vendor-session", namespace: "a")
            }
        }
        var data = try meta; data.append(Data("broken JSON\n".utf8))
        try withFile(data) { url in
            #expect(throws: RolloutHistoryError.malformedRecord) {
                try ChatGPTRolloutHistory().read(url: url, expectedSessionID: "vendor-session", namespace: "a")
            }
        }
    }

    @Test func limitsTruncationAndAttachmentsAreExplicit() throws {
        var data = try meta
        data.append(try record("response_item", ["type": "message", "role": "user", "content": [["type": "input_image", "image_url": "file:///private/secret.png"]]]))
        try withFile(data) { url in
            let reader = ChatGPTRolloutHistory()
            let result = try reader.read(url: url, expectedSessionID: "vendor-session", namespace: "a")
            #expect(result.unsupportedContentCount == 1)
            #expect(result.messages[0].content[0].text == "[Unsupported attachment]")
            #expect(throws: RolloutHistoryError.invalidWindow) { try reader.read(url: url, expectedSessionID: "vendor-session", namespace: "a", limit: 101) }
            #expect(throws: RolloutHistoryError.snapshotTruncated) { try reader.read(url: url, expectedSessionID: "vendor-session", namespace: "a", snapshotBytes: UInt64(data.count + 1)) }
            #expect(throws: RolloutHistoryError.recordTooLarge) { try ChatGPTRolloutHistory(maximumRecordBytes: 16).read(url: url, expectedSessionID: "vendor-session", namespace: "a") }
            #expect(throws: RolloutHistoryError.fileTooLarge) { try ChatGPTRolloutHistory(maximumSnapshotBytes: 16).read(url: url, expectedSessionID: "vendor-session", namespace: "a") }
        }
    }
}
