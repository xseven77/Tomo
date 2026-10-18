import Foundation
import SQLite3

/// Opens another app's SQLite database without writing anything next to it.
///
/// A read-only connection to a WAL database needs the owner's `-shm` file. Codex removes
/// `-wal`/`-shm` when it quits, and the first read then fails with SQLITE_CANTOPEN.
/// No `-shm` means no live writer, so the checkpointed main file is read as immutable.
enum ReadOnlySQLite {
    static func open(_ url: URL) -> OpaquePointer? {
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        if let database = connect(url.path, flags: flags) {
            guard sqlite3_exec(database, "PRAGMA schema_version", nil, nil, nil) == SQLITE_CANTOPEN else { return database }
            sqlite3_close(database)
        }
        guard !FileManager.default.fileExists(atPath: url.path + "-shm") else { return nil }
        var uri = URLComponents()
        uri.scheme = "file"
        uri.path = url.path
        uri.queryItems = [URLQueryItem(name: "immutable", value: "1")]
        guard let filename = uri.string else { return nil }
        return connect(filename, flags: flags | SQLITE_OPEN_URI)
    }

    private static func connect(_ filename: String, flags: Int32) -> OpaquePointer? {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(filename, &connection, flags, nil) == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }
            return nil
        }
        return connection
    }
}
