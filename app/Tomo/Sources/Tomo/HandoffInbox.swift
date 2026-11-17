import Foundation

/// Task handoffs written by any agent through the `tomo-handoff` skill: Markdown files with a
/// short header in a private local folder. Read-only here; Tomo never runs or trusts their content.
struct HandoffInbox: Sendable {
    struct Summary: Codable, Sendable, Equatable {
        let id: String
        let title: String
        let agent: String
        let status: String
        /// The project folder's name only; the full local path stays on this Mac.
        let workspaceName: String?
        let updatedAt: Date
    }
    struct Handoff: Codable, Sendable, Equatable {
        let summary: Summary
        /// The Markdown body after the header.
        let body: String
    }

    static let maximumBytes = 256 * 1024
    static let maximumListed = 200
    static let statuses: Set<String> = ["in-progress", "blocked", "done"]

    let directory: URL

    static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["TOMO_HANDOFF_DIR"], override.hasPrefix("/") {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tomo/Handoffs", isDirectory: true)
    }

    /// Newest first. Unreadable or malformed files are skipped, never surfaced as errors.
    func list() -> [Summary] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        let items = names.compactMap { name -> Summary? in
            guard name.hasSuffix(".md") else { return nil }
            return try? read(id: String(name.dropLast(3))).summary
        }
        return Array(items.sorted { $0.updatedAt == $1.updatedAt ? $0.id > $1.id : $0.updatedAt > $1.updatedAt }
            .prefix(Self.maximumListed))
    }

    func read(id: String) throws -> Handoff {
        guard Self.isValidId(id) else { throw RemoteReadError.invalidRequest }
        let file = directory.appendingPathComponent(id + ".md", isDirectory: false)
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard let values, values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= Self.maximumBytes else { throw RemoteReadError.notFound }
        guard let text = String(data: try Data(contentsOf: file), encoding: .utf8) else { throw RemoteReadError.notFound }
        return try Self.parse(id: id, text: text, updatedAt: values.contentModificationDate ?? Date())
    }

    /// Ids are file names chosen by the helper script or the agent: no separators, no hidden files.
    static func isValidId(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && !id.hasPrefix(".")
            && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0) }
    }

    static func parse(id: String, text: String, updatedAt: Date) throws -> Handoff {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { throw RemoteReadError.notFound }
        var header: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if header[key] == nil { header[key] = value }
        }
        func field(_ key: String, limit: Int = 200) -> String? {
            guard let value = header[key], !value.isEmpty else { return nil }
            let clean = String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
            return String(clean.prefix(limit))
        }
        guard header["tomo-handoff"] == "1", let title = field("title"), let agent = field("agent", limit: 64),
              let status = field("status"), statuses.contains(status) else { throw RemoteReadError.notFound }
        let workspace = field("workspace", limit: 1024).flatMap { path -> String? in
            guard path != "none" else { return nil }
            let name = (path as NSString).lastPathComponent
            return name.isEmpty || name == "/" ? nil : String(name.prefix(128))
        }
        lines.removeSubrange(0...end)
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Handoff(summary: .init(id: id, title: title, agent: agent, status: status, workspaceName: workspace, updatedAt: updatedAt),
                       body: body)
    }
}
