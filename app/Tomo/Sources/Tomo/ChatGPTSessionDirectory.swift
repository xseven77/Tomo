import Foundation
import SQLite3
import CryptoKit
import Darwin

enum ChatGPTDirectoryError: Error, Equatable {
    case invalidConfiguration
    case unavailable
    case incompatibleSchema
    case databaseBusy
    case invalidRecord
    case outsideStorageRoot
    case sessionGone
}

struct ChatGPTDirectoryEntry: Sendable, Equatable {
    let sessionId: String
    let vendorSessionId: String
    let title: String
    let updatedAt: Date
    let archived: Bool
    /// Internal locator only; never encoded in the Remote API response.
    let rolloutURL: URL
}
struct ChatGPTDirectorySnapshot: Sendable {
    let entries: [ChatGPTDirectoryEntry]
    let indexState: String
}

/// Initialized from owner-registered runtime configuration, not HTTP input.
struct ChatGPTSessionDirectory: Sendable {
    let databaseURL: URL
    let storageRoot: URL
    let runtimeId: String

    func snapshot(maximumRows: Int = 10000) throws -> ChatGPTDirectorySnapshot {
        guard (1...10000).contains(maximumRows), !runtimeId.isEmpty else { throw ChatGPTDirectoryError.invalidConfiguration }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let database = connection else {
            if let connection { sqlite3_close(connection) }
            throw ChatGPTDirectoryError.unavailable
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)
        let columns = try threadColumns(database)
        guard Set(["id", "rollout_path", "title", "updated_at"]).isSubset(of: columns) else {
            throw ChatGPTDirectoryError.incompatibleSchema
        }
        let archived = columns.contains("archived") ? "COALESCE(archived, 0)" : "0"
        let source = columns.contains("thread_source") ? "WHERE COALESCE(thread_source, 'user') <> 'subagent'" : ""
        // Query shape is fixed; only optional, verified column names are used.
        let sql = "SELECT id, rollout_path, title, updated_at, \(archived) FROM threads \(source) ORDER BY updated_at DESC, id DESC LIMIT ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ChatGPTDirectoryError.incompatibleSchema
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(maximumRows + 1))
        var entries: [ChatGPTDirectoryEntry] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let idPointer = sqlite3_column_text(statement, 0), let pathPointer = sqlite3_column_text(statement, 1) else {
                throw ChatGPTDirectoryError.invalidRecord
            }
            let vendorId = String(cString: idPointer)
            let path = String(cString: pathPointer)
            guard !vendorId.isEmpty, path.hasPrefix("/"), sqlite3_column_type(statement, 3) == SQLITE_INTEGER else {
                throw ChatGPTDirectoryError.invalidRecord
            }
            let identity = Data("\(runtimeId)\u{0}\(vendorId)".utf8)
            let digest = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
            entries.append(.init(sessionId: "ss_" + String(digest.prefix(32)), vendorSessionId: vendorId,
                title: sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? "ChatGPT",
                updatedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 3))),
                archived: sqlite3_column_int(statement, 4) != 0, rolloutURL: URL(fileURLWithPath: path)))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw result == SQLITE_BUSY || result == SQLITE_LOCKED ? ChatGPTDirectoryError.databaseBusy : ChatGPTDirectoryError.invalidRecord
        }
        return .init(entries: Array(entries.prefix(maximumRows)), indexState: entries.count > maximumRows ? "partial" : "ready")
    }

    /// Recheck at use time; a cached path must not bypass a changed symlink.
    func historyURL(for entry: ChatGPTDirectoryEntry) throws -> URL {
        // Foundation can normalize /private/var back to the /var alias on macOS.
        // Descriptor walking needs actual POSIX paths, including those ancestors.
        let root = try canonicalURL(storageRoot)
        let file = try canonicalURL(entry.rolloutURL)
        guard root.path != "/", file.path.hasPrefix(root.path + "/"), file.pathExtension == "jsonl" else {
            throw ChatGPTDirectoryError.outsideStorageRoot
        }
        guard FileManager.default.fileExists(atPath: file.path) else { throw ChatGPTDirectoryError.sessionGone }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw ChatGPTDirectoryError.sessionGone }
        return file
    }

    func readHistory(for entry: ChatGPTDirectoryEntry, limit: Int = 50,
                     snapshotBytes: UInt64? = nil, beforeOffset: UInt64? = nil) throws -> RolloutHistoryWindow {
        let url = try historyURL(for: entry)
        // Walk the resolved absolute path from a pinned directory descriptor.
        // O_NOFOLLOW on every component prevents symlink swaps after validation.
        let components = url.pathComponents.filter { $0 != "/" }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw ChatGPTDirectoryError.unavailable }
        defer { if descriptor >= 0 { Darwin.close(descriptor) } }
        for (index, component) in components.enumerated() {
            let isFile = index == components.count - 1
            let next = openat(descriptor, component, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (isFile ? O_NONBLOCK : O_DIRECTORY))
            guard next >= 0 else {
                throw errno == ENOENT ? ChatGPTDirectoryError.sessionGone : ChatGPTDirectoryError.outsideStorageRoot
            }
            Darwin.close(descriptor)
            descriptor = next
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw ChatGPTDirectoryError.sessionGone }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        descriptor = -1
        defer { try? file.close() }
        return try ChatGPTRolloutHistory().read(file: file, expectedSessionID: entry.vendorSessionId,
            namespace: runtimeId, limit: limit, snapshotBytes: snapshotBytes, beforeOffset: beforeOffset)
    }

    private func canonicalURL(_ url: URL) throws -> URL {
        guard let resolved = realpath(url.path, nil) else { throw ChatGPTDirectoryError.sessionGone }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    private func threadColumns(_ database: OpaquePointer) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(threads)", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ChatGPTDirectoryError.incompatibleSchema
        }
        defer { sqlite3_finalize(statement) }
        var columns: Set<String> = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) { columns.insert(String(cString: name)) }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw ChatGPTDirectoryError.databaseBusy }
        return columns
    }
}
