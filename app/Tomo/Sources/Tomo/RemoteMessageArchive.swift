import Foundation
import SQLite3

/// Journal-private storage. Every call shares the journal's SQLite transaction;
/// callers still authorize the complete resource and principal on every page.
enum RemoteMessageArchive {
    struct Snapshot: Sendable {
        let token: UInt64
        let epoch: String
        let sequence: Int
        let revision: Int
        let count: Int
        let expires: Date
        var digest: String { "archive:\(epoch):\(revision)" }
    }

    static func create(_ db: OpaquePointer) throws {
        try execute(db, "CREATE TABLE IF NOT EXISTS remote_message_heads (ref TEXT PRIMARY KEY REFERENCES remote_session_streams(ref) ON DELETE CASCADE, count INTEGER NOT NULL, revision INTEGER NOT NULL)")
        try execute(db, "CREATE TABLE IF NOT EXISTS remote_messages (ref TEXT NOT NULL REFERENCES remote_session_streams(ref) ON DELETE CASCADE, message TEXT NOT NULL, ordinal INTEGER NOT NULL, turn TEXT, content BLOB NOT NULL, PRIMARY KEY(ref,message), UNIQUE(ref,ordinal))")
        try execute(db, "CREATE INDEX IF NOT EXISTS remote_messages_turn ON remote_messages(ref,turn,ordinal)")
        try execute(db, "CREATE TABLE IF NOT EXISTS remote_message_snapshots (token INTEGER PRIMARY KEY, ref TEXT NOT NULL REFERENCES remote_session_streams(ref) ON DELETE CASCADE, epoch TEXT NOT NULL, sequence INTEGER NOT NULL, revision INTEGER NOT NULL, count INTEGER NOT NULL, expires REAL NOT NULL)")
        try execute(db, "CREATE INDEX IF NOT EXISTS remote_message_snapshots_ref ON remote_message_snapshots(ref,revision)")
        try execute(db, "CREATE TABLE IF NOT EXISTS remote_message_versions (snapshot INTEGER NOT NULL REFERENCES remote_message_snapshots(token) ON DELETE CASCADE, message TEXT NOT NULL, content BLOB NOT NULL, PRIMARY KEY(snapshot,message))")
    }

    static func reset(_ db: OpaquePointer, ref: String, messages: [RemoteHistoryMessage]) throws {
        try execute(db, "DELETE FROM remote_message_snapshots WHERE ref=?", [.text(ref)])
        try execute(db, "DELETE FROM remote_messages WHERE ref=?", [.text(ref)])
        for (ordinal, message) in messages.enumerated() {
            try execute(db, "INSERT INTO remote_messages VALUES(?,?,?,?,?)", [.text(ref), .text(message.messageId),
                .int(ordinal), message.turnId.map(Value.text) ?? .null, .blob(try encoded(message))])
        }
        try execute(db, "INSERT INTO remote_message_heads VALUES(?,?,0) ON CONFLICT(ref) DO UPDATE SET count=excluded.count,revision=0",
            [.text(ref), .int(messages.count)])
    }

    static func message(_ db: OpaquePointer, ref: String, id: String) throws -> RemoteHistoryMessage? {
        let rows = try query(db, "SELECT content FROM remote_messages WHERE ref=? AND message=?", [.text(ref), .text(id)])
        guard let value = rows.first else { return nil }
        return try JSONDecoder().decode(RemoteHistoryMessage.self, from: value[0].data)
    }

    /// Save the old text at most once per snapshot, not once per streaming token.
    /// Appends need no copy: snapshot count excludes their new ordinals.
    static func put(_ db: OpaquePointer, ref: String, message: RemoteHistoryMessage, now: Date) throws {
        let head = try head(db, ref: ref)
        guard head.revision < 9_007_199_254_740_991, head.count < 9_007_199_254_740_991 else { throw RemoteJournalError.limitExceeded }
        let rows = try query(db, "SELECT ordinal,content FROM remote_messages WHERE ref=? AND message=?", [.text(ref), .text(message.messageId)])
        let data = try encoded(message)
        if let previous = rows.first {
            if previous[1].data == data { return }
            try execute(db, "INSERT OR IGNORE INTO remote_message_versions(snapshot,message,content) SELECT token,?,? FROM remote_message_snapshots WHERE ref=? AND count>? AND expires>?",
                [.text(message.messageId), .blob(previous[1].data), .text(ref), .int(previous[0].integer), .real(now.timeIntervalSince1970)])
            try execute(db, "UPDATE remote_messages SET content=? WHERE ref=? AND message=?", [.blob(data), .text(ref), .text(message.messageId)])
        } else {
            try execute(db, "INSERT INTO remote_messages VALUES(?,?,?,?,?)", [.text(ref), .text(message.messageId), .int(head.count),
                message.turnId.map(Value.text) ?? .null, .blob(data)])
        }
        try execute(db, "UPDATE remote_message_heads SET count=?,revision=? WHERE ref=?",
            [.int(head.count + (rows.isEmpty ? 1 : 0)), .int(head.revision + 1), .text(ref)])
        try prune(db, ref: ref, now: now)
    }

    static func capture(_ db: OpaquePointer, ref: String, epoch: String, sequence: Int, now: Date) throws -> Snapshot {
        try prune(db, ref: ref, now: now)
        let head = try head(db, ref: ref)
        if let row = try query(db, "SELECT token,epoch,sequence,revision,count,expires FROM remote_message_snapshots WHERE ref=? AND epoch=? AND revision=? LIMIT 1",
            [.text(ref), .text(epoch), .int(head.revision)]).first { return try snapshot(row) }
        let existing = try query(db, "SELECT token FROM remote_message_snapshots WHERE ref=? ORDER BY expires,token", [.text(ref)])
        for row in existing.prefix(max(0, existing.count - 3)) {
            try execute(db, "DELETE FROM remote_message_snapshots WHERE token=?", [.int(row[0].integer)])
        }
        var token: UInt64
        repeat { token = UInt64.random(in: 1...9_007_199_254_740_991) }
        while !(try query(db, "SELECT token FROM remote_message_snapshots WHERE token=?", [.int(Int(token))])).isEmpty
        let value = Snapshot(token: token, epoch: epoch, sequence: sequence, revision: head.revision, count: head.count,
            expires: now.addingTimeInterval(300))
        try execute(db, "INSERT INTO remote_message_snapshots VALUES(?,?,?,?,?,?,?)", [.int(Int(token)), .text(ref), .text(epoch),
            .int(sequence), .int(head.revision), .int(head.count), .real(value.expires.timeIntervalSince1970)])
        return value
    }

    static func window(_ db: OpaquePointer, ref: String, snapshot saved: Snapshot, before: UInt64?, limit: Int,
                       retainingTurn: String?, maximumBytes: Int, now: Date) throws -> RolloutHistoryWindow {
        guard (1...100).contains(limit), maximumBytes > 0,
              let row = try query(db, "SELECT token,epoch,sequence,revision,count,expires FROM remote_message_snapshots WHERE token=? AND ref=?",
                [.int(Int(saved.token)), .text(ref)]).first else { throw RolloutHistoryError.snapshotChanged }
        let snapshot = try snapshot(row)
        guard snapshot.epoch == saved.epoch, snapshot.revision == saved.revision, snapshot.count == saved.count, snapshot.expires > now else {
            throw RolloutHistoryError.snapshotChanged
        }
        let boundary = before ?? UInt64(snapshot.count)
        guard boundary <= UInt64(snapshot.count) else { throw RolloutHistoryError.invalidWindow }
        var count = min(limit, Int(boundary)), activeCount = 0
        if before == nil, let retainingTurn,
           let first = try query(db, "SELECT ordinal FROM remote_messages WHERE ref=? AND turn=? AND ordinal<? ORDER BY ordinal LIMIT 1",
                [.text(ref), .text(retainingTurn), .int(Int(boundary))]).first {
            activeCount = Int(boundary) - first[0].integer
            count = max(count, activeCount)
            guard count <= 1000 else { throw RemoteJournalError.limitExceeded }
        }
        let stmt = try statement(db, "SELECT m.ordinal,length(COALESCE(v.content,m.content)),COALESCE(v.content,m.content) FROM remote_messages m LEFT JOIN remote_message_versions v ON v.snapshot=? AND v.message=m.message WHERE m.ref=? AND m.ordinal<? ORDER BY m.ordinal DESC LIMIT ?",
            [.int(Int(saved.token)), .text(ref), .int(Int(boundary)), .int(count)])
        defer { sqlite3_finalize(stmt) }
        var messages: [RemoteHistoryMessage] = [], bytes = 2, start = Int(boundary), step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            let size = Int(sqlite3_column_int64(stmt, 1))
            guard size > 0 else { throw RemoteJournalError.invalidProjection }
            if size + bytes + (messages.isEmpty ? 0 : 1) > maximumBytes {
                guard !messages.isEmpty, messages.count >= activeCount else { throw RemoteJournalError.limitExceeded }
                break
            }
            guard let raw = sqlite3_column_blob(stmt, 2), Int(sqlite3_column_bytes(stmt, 2)) == size,
                  Int(sqlite3_column_int64(stmt, 0)) == start - 1 else { throw RemoteJournalError.invalidProjection }
            messages.append(try JSONDecoder().decode(RemoteHistoryMessage.self, from: Data(bytes: raw, count: size)))
            bytes += size + (messages.count == 1 ? 0 : 1); start -= 1
            step = sqlite3_step(stmt)
        }
        guard step == SQLITE_DONE || step == SQLITE_ROW else { throw RemoteJournalError.unavailable }
        guard !messages.isEmpty || boundary == 0 else { throw RemoteJournalError.invalidProjection }
        return .init(messages: Array(messages.reversed()), snapshotBytes: saved.token,
            olderBeforeOffset: start > 0 ? UInt64(start) : nil, unsupportedContentCount: 0, snapshotDigest: saved.digest)
    }

    private static func head(_ db: OpaquePointer, ref: String) throws -> (count: Int, revision: Int) {
        guard let row = try query(db, "SELECT count,revision FROM remote_message_heads WHERE ref=?", [.text(ref)]).first,
              row[0].integer >= 0, row[1].integer >= 0 else { throw RemoteJournalError.invalidProjection }
        return (row[0].integer, row[1].integer)
    }
    private static func snapshot(_ row: [Value]) throws -> Snapshot {
        guard (1...9_007_199_254_740_991).contains(row[0].integer), !row[1].string.isEmpty,
              row[2].integer >= 0, row[3].integer >= 0, row[4].integer >= 0, row[5].double.isFinite else {
            throw RemoteJournalError.invalidProjection
        }
        return .init(token: UInt64(row[0].integer), epoch: row[1].string, sequence: row[2].integer,
            revision: row[3].integer, count: row[4].integer, expires: Date(timeIntervalSince1970: row[5].double))
    }
    private static func prune(_ db: OpaquePointer, ref: String, now: Date) throws {
        try execute(db, "DELETE FROM remote_message_snapshots WHERE expires<=?", [.real(now.timeIntervalSince1970)])
        // Bound copy-on-write storage. Eviction expires a cursor explicitly;
        // it never returns a newer revision under an older snapshot handle.
        while (try query(db, "SELECT COALESCE(SUM(length(v.content)),0) FROM remote_message_versions v JOIN remote_message_snapshots s ON s.token=v.snapshot WHERE s.ref=?", [.text(ref)]).first?[0].integer ?? 0) > 8 * 1024 * 1024 {
            try execute(db, "DELETE FROM remote_message_snapshots WHERE token=(SELECT token FROM remote_message_snapshots WHERE ref=? ORDER BY expires,token LIMIT 1)", [.text(ref)])
        }
    }
    private static func encoded(_ message: RemoteHistoryMessage) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(message)
    }

    private enum Value {
        case int(Int), text(String), blob(Data), real(Double), null
        var integer: Int { if case .int(let v) = self { return v }; return -1 }
        var string: String { if case .text(let v) = self { return v }; return "" }
        var data: Data { if case .blob(let v) = self { return v }; return Data() }
        var double: Double { if case .real(let v) = self { return v }; return .nan }
    }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static func statement(_ db: OpaquePointer, _ sql: String, _ bindings: [Value]) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK, let stmt = result else { throw RemoteJournalError.unavailable }
        do {
            for (i, value) in bindings.enumerated() {
                let slot = Int32(i + 1), status: Int32
                switch value {
                case .int(let value): status = sqlite3_bind_int64(stmt, slot, Int64(value))
                case .text(let value): status = sqlite3_bind_text(stmt, slot, value, -1, transient)
                case .blob(let value): status = value.withUnsafeBytes { sqlite3_bind_blob(stmt, slot, $0.baseAddress, Int32(value.count), transient) }
                case .real(let value): status = sqlite3_bind_double(stmt, slot, value)
                case .null: status = sqlite3_bind_null(stmt, slot)
                }
                guard status == SQLITE_OK else { throw RemoteJournalError.unavailable }
            }
            return stmt
        } catch { sqlite3_finalize(stmt); throw error }
    }
    private static func execute(_ db: OpaquePointer, _ sql: String, _ values: [Value] = []) throws {
        let stmt = try statement(db, sql, values); defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw RemoteJournalError.unavailable }
    }
    private static func query(_ db: OpaquePointer, _ sql: String, _ values: [Value] = []) throws -> [[Value]] {
        let stmt = try statement(db, sql, values); defer { sqlite3_finalize(stmt) }
        var rows: [[Value]] = [], step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            var row: [Value] = []
            for i in 0..<sqlite3_column_count(stmt) {
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row.append(.int(Int(sqlite3_column_int64(stmt, i))))
                case SQLITE_FLOAT: row.append(.real(sqlite3_column_double(stmt, i)))
                case SQLITE_TEXT: row.append(.text(String(cString: sqlite3_column_text(stmt, i))))
                case SQLITE_BLOB:
                    if let raw = sqlite3_column_blob(stmt, i) { row.append(.blob(Data(bytes: raw, count: Int(sqlite3_column_bytes(stmt, i))))) }
                    else { row.append(.blob(Data())) }
                default: row.append(.null)
                }
            }
            rows.append(row); step = sqlite3_step(stmt)
        }
        guard step == SQLITE_DONE else { throw RemoteJournalError.unavailable }
        return rows
    }
}
