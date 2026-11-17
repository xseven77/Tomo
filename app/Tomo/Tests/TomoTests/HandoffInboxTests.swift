import Foundation
import Testing
@testable import Tomo

struct HandoffInboxTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func handoff(title: String = "整理登录页", status: String = "in-progress", workspace: String = "/Users/me/code/Secret/Tomo") -> String {
        "---\ntomo-handoff: 1\ntitle: \(title)\nagent: Codex\nworkspace: \(workspace)\nsession: unknown\nstatus: \(status)\n---\n\n## 目标\n修复登录页\n"
    }

    @Test func parsesHeaderAndKeepsOnlyTheFolderNameOfTheWorkspace() throws {
        let item = try HandoffInbox.parse(id: "a", text: handoff(), updatedAt: Date(timeIntervalSince1970: 1))
        #expect(item.summary.title == "整理登录页")
        #expect(item.summary.agent == "Codex")
        #expect(item.summary.workspaceName == "Tomo")
        #expect(item.body == "## 目标\n修复登录页")
    }

    @Test func malformedOrUnknownFilesAreSkippedNotTrusted() throws {
        let dir = try folder()
        try handoff().write(to: dir.appendingPathComponent("good.md"), atomically: true, encoding: .utf8)
        try handoff(status: "running").write(to: dir.appendingPathComponent("badstatus.md"), atomically: true, encoding: .utf8)
        try "no header".write(to: dir.appendingPathComponent("plain.md"), atomically: true, encoding: .utf8)
        try handoff().write(to: dir.appendingPathComponent(".partial.md"), atomically: true, encoding: .utf8)
        try handoff().write(to: dir.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let outside = try folder().appendingPathComponent("outside.md")
        try handoff(title: "outside").write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link.md"), withDestinationURL: outside)
        try String(repeating: "x", count: HandoffInbox.maximumBytes + 1).write(to: dir.appendingPathComponent("huge.md"), atomically: true, encoding: .utf8)
        let inbox = HandoffInbox(directory: dir)
        #expect(inbox.list().map(\.id) == ["good"])
        for id in ["../good", ".partial", "link", "a/b", ""] {
            #expect(throws: (any Error).self) { try inbox.read(id: id) }
        }
    }

    @Test func newestFirst() throws {
        let dir = try folder()
        for (name, time) in [("old", 100.0), ("new", 200.0)] {
            let url = dir.appendingPathComponent(name + ".md")
            try handoff(title: name).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: time)], ofItemAtPath: url.path)
        }
        #expect(HandoffInbox(directory: dir).list().map(\.id) == ["new", "old"])
    }
}
