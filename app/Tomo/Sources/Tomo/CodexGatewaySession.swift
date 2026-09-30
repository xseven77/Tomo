import Foundation
import SQLite3

struct CodexGatewaySession: Identifiable, Sendable {
    let id: String
    let title: String
    let cwd: String
    let provider: String
}

/// Read the existing local conversation index. Never rewrite rollout files or session metadata.
struct CodexGatewaySessionCatalog: Sendable {
    let homeURL: URL

    func load() throws -> [CodexGatewaySession] {
        let candidates = [homeURL.appendingPathComponent("state_5.sqlite"),
                          homeURL.appendingPathComponent("sqlite/state_5.sqlite")]
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return []
        }
        var database: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw SessionError.unreadableIndex
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1_000)
        var columns = Set<String>()
        var info: OpaquePointer?
        if sqlite3_prepare_v2(database, "PRAGMA table_info(threads)", -1, &info, nil) == SQLITE_OK, let info {
            while sqlite3_step(info) == SQLITE_ROW {
                if let text = sqlite3_column_text(info, 1) { columns.insert(String(cString: text)) }
            }
        }
        sqlite3_finalize(info)
        let cwd = columns.contains("cwd") ? "cwd" : "''"
        let provider = columns.contains("model_provider") ? "model_provider" : "''"
        let sourceFilter = columns.contains("thread_source")
            ? "AND COALESCE(thread_source, 'user') <> 'subagent'" : ""
        let sql = """
        SELECT id, title, \(cwd), \(provider) FROM threads
        WHERE archived = 0 \(sourceFilter) ORDER BY updated_at DESC LIMIT 100
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SessionError.unreadableIndex
        }
        defer { sqlite3_finalize(statement) }
        var sessions: [CodexGatewaySession] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            func string(_ column: Int32) -> String {
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            }
            let id = string(0)
            if UUID(uuidString: id) != nil {
                let title = string(1)
                sessions.append(CodexGatewaySession(id: id, title: title.isEmpty ? id : title,
                                                   cwd: string(2), provider: string(3)))
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw SessionError.unreadableIndex }
        return sessions
    }

    /// Explicit provider/model overrides resume the same thread through the supported CLI.
    /// No credentials appear in the copied command; they remain in the provider configuration.
    static func resumeCommand(session: CodexGatewaySession, model: String, homeURL: URL,
                              executable: String = "codex") -> String {
        let catalog = homeURL.appendingPathComponent("tomo_models.json").path
        let args = [executable, "resume", session.id, "--model", model,
                    "--config", "model_provider=\"tomo\"",
                    "--config", "model_catalog_json=\(CodexGatewayConfigurator.tomlString(catalog))"]
        let command = "CODEX_HOME=\(shellQuote(homeURL.path)) " + args.map(shellQuote).joined(separator: " ")
        return session.cwd.isEmpty ? command : "cd \(shellQuote(session.cwd)) && \(command)"
    }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    enum SessionError: LocalizedError {
        case unreadableIndex
        var errorDescription: String? { "无法读取 ChatGPT 会话索引，请确认客户端已经创建过本地会话。" }
    }
}
