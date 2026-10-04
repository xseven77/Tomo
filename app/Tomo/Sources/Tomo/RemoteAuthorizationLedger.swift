import Foundation
import CryptoKit
import SQLite3

/// Trusted local approval and exchange metadata. Caller verifies cloud JWS and
/// DPoP before consume; this store rechecks current local authorization atomically.
actor RemoteAuthorizationLedger {
    struct Binding: Codable, Equatable, Sendable {
        let userId: String
        let deviceId: String
        let thumbprint: String
        let bindingRevision: Int
        var cloudBindingId: String?
        var localVersion: Int
        let scopes: [String]
        let resources: [RemoteCloudGrantVerifier.Resource]
        var revoked: Bool
    }
    struct Receipt: Codable, Equatable, Sendable {
        let accessId: String
        let grantId: String
        let userId: String
        let deviceId: String
        let cloudBindingId: String
        let bindingRevision: Int
        let localVersion: Int
        var expiresAt: Date
        let scopes: [String]
        let resources: [RemoteCloudGrantVerifier.Resource]
        let claimDigest: String
    }
    private let url: URL
    nonisolated let serverId: String
    private let maximumBindings: Int
    private let maximumReceipts: Int
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(databaseURL: URL, serverId: String, maximumBindings: Int = 1024, maximumReceipts: Int = 10000) throws {
        guard databaseURL.isFileURL, UUID(uuidString: serverId) != nil,
              (1...1024).contains(maximumBindings), (1...10000).contains(maximumReceipts) else { throw RemoteAccessError.invalidConfiguration }
        self.url = databaseURL; self.serverId = serverId
        self.maximumBindings = maximumBindings; self.maximumReceipts = maximumReceipts
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try Self.database(databaseURL) { db in
            let version = try Self.rows(db, "PRAGMA user_version").first?.first
            guard version == "0" || version == "1" else { throw RemoteAccessError.invalidConfiguration }
            try Self.execute(db, "CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY,value TEXT NOT NULL)")
            try Self.execute(db, "CREATE TABLE IF NOT EXISTS bindings (user TEXT NOT NULL,device TEXT NOT NULL,record TEXT NOT NULL,PRIMARY KEY(user,device))")
            try Self.execute(db, "CREATE TABLE IF NOT EXISTS receipts (grant_id TEXT PRIMARY KEY,expiry REAL NOT NULL,record TEXT NOT NULL)")
            try Self.execute(db, "CREATE INDEX IF NOT EXISTS receipt_expiry ON receipts(expiry)")
            if let previous = try Self.rows(db, "SELECT value FROM metadata WHERE key='server'").first?.first {
                guard previous == serverId else { throw RemoteAccessError.invalidConfiguration }
            } else { try Self.execute(db, "INSERT INTO metadata VALUES ('server',?)", [serverId]) }
            try Self.execute(db, "PRAGMA user_version=1")
        }
    }
    /// Local owner action only. Never accept this method's inputs directly from a phone.
    func approve(_ proposed: Binding, expectedLocalVersion: Int) throws -> Binding {
        guard !proposed.revoked, proposed.localVersion == 0,
              UUID(uuidString: proposed.userId) != nil, UUID(uuidString: proposed.deviceId) != nil,
              proposed.cloudBindingId.map({ UUID(uuidString: $0) != nil }) ?? true,
              RemoteJWTCodec.base64URL(proposed.thumbprint)?.count == 32, proposed.bindingRevision > 0,
              !proposed.scopes.isEmpty, Set(proposed.scopes).count == proposed.scopes.count,
              Set(proposed.scopes).isSubset(of: ["discovery", "session.read", "session.write", "session.approve"]),
              !proposed.resources.isEmpty, proposed.resources.count <= 128 else { throw RemoteAccessError.invalidConfiguration }
        // Resource decoder enforces the exact schema even for trusted callers.
        _ = try JSONDecoder().decode([RemoteCloudGrantVerifier.Resource].self, from: JSONEncoder().encode(proposed.resources))
        return try Self.database(url) { db in
            let previous = try Self.binding(db, proposed.userId, proposed.deviceId)
            guard (previous?.localVersion ?? 0) == expectedLocalVersion, expectedLocalVersion < Int.max,
                  proposed.bindingRevision >= (previous?.bindingRevision ?? 0) else { throw RemoteAccessError.forbidden }
            if previous == nil {
                guard try Self.count(db, "SELECT COUNT(*) FROM bindings") < maximumBindings else { throw RemoteAccessError.unavailable }
            }
            var next = proposed
            if let previous, proposed.bindingRevision == previous.bindingRevision {
                guard !previous.revoked, proposed.thumbprint == previous.thumbprint,
                      proposed.cloudBindingId == nil || proposed.cloudBindingId == previous.cloudBindingId else {
                    throw RemoteAccessError.forbidden
                }
                next.cloudBindingId = previous.cloudBindingId
            }
            next.localVersion = expectedLocalVersion + 1
            try Self.save(db, next)
            return next
        }
    }
    /// Native owner projection only; never expose the full ACL over HTTP.
    func ownerBindings() throws -> [Binding] {
        try Self.database(url) { db in
            try Self.rows(db, "SELECT record FROM bindings ORDER BY user,device").map {
                guard let json = $0.first else { throw RemoteAccessError.unavailable }
                return try Self.decode(Binding.self, json)
            }
        }
    }
    func ownerBinding(userId: String, deviceId: String) throws -> Binding? {
        try Self.database(url) { try Self.binding($0, userId, deviceId) }
    }
    func revoke(userId: String, deviceId: String, expectedLocalVersion: Int) throws -> Binding {
        try Self.database(url) { db in
            guard var binding = try Self.binding(db, userId, deviceId) else { throw RemoteAccessError.forbidden }
            if binding.revoked { return binding }
            guard binding.localVersion == expectedLocalVersion, expectedLocalVersion < Int.max else { throw RemoteAccessError.forbidden }
            binding.revoked = true; binding.localVersion += 1
            try Self.save(db, binding)
            return binding
        }
    }
    func consume(_ claims: RemoteCloudGrantVerifier.Claims, now: Date = Date()) throws -> Receipt {
        guard claims.aud == serverId, now.timeIntervalSince1970.isFinite,
              Double(claims.nbf) <= now.timeIntervalSince1970, Double(claims.exp) > now.timeIntervalSince1970,
              claims.iat > 0, claims.exp > claims.iat, claims.exp - claims.iat <= 300 else { throw RemoteAccessError.unauthorized }
        return try Self.database(url) { db in
            let floor = try Self.rows(db, "SELECT value FROM metadata WHERE key='clock'").first?.first.flatMap(Double.init) ?? 0
            guard now.timeIntervalSince1970 >= floor,
                  var binding = try Self.binding(db, claims.sub, claims.deviceId), !binding.revoked,
                  binding.thumbprint == claims.cnf.jkt, binding.bindingRevision == claims.bindingRevision,
                  binding.cloudBindingId == nil || binding.cloudBindingId == claims.bindingId else { throw RemoteAccessError.unauthorized }
            let scopes = claims.scope.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            guard !scopes.isEmpty, Set(scopes).count == scopes.count,
                  Set(scopes).isSubset(of: Set(binding.scopes + ["server.identity"])),
                  scopes == ["server.identity"] ? claims.resources.isEmpty : !claims.resources.isEmpty,
                  claims.resources.allSatisfy({ binding.resources.contains($0) }) else { throw RemoteAccessError.forbidden }
            let digest = Self.digest(try Self.encode(claims))
            if let json = try Self.rows(db, "SELECT record FROM receipts WHERE grant_id=?", [claims.jti]).first?.first {
                let receipt = try Self.decode(Receipt.self, json)
                guard receipt.claimDigest == digest, receipt.localVersion == binding.localVersion, receipt.expiresAt > now else {
                    throw RemoteAccessError.unauthorized
                }
                try Self.execute(db, "INSERT OR REPLACE INTO metadata VALUES ('clock',?)", [String(now.timeIntervalSince1970)])
                return receipt
            }
            try Self.execute(db, "DELETE FROM receipts WHERE expiry<=?", [String(now.timeIntervalSince1970)])
            guard try Self.count(db, "SELECT COUNT(*) FROM receipts") < maximumReceipts else { throw RemoteAccessError.unavailable }
            let receipt = Receipt(accessId: UUID().uuidString, grantId: claims.jti, userId: claims.sub, deviceId: claims.deviceId,
                cloudBindingId: claims.bindingId, bindingRevision: claims.bindingRevision, localVersion: binding.localVersion,
                expiresAt: Date(timeIntervalSince1970: Double(claims.exp)), scopes: scopes, resources: claims.resources, claimDigest: digest)
            binding.cloudBindingId = claims.bindingId
            try Self.save(db, binding)
            try Self.execute(db, "INSERT INTO receipts VALUES (?,?,?)", [claims.jti, String(receipt.expiresAt.timeIntervalSince1970), try Self.encode(receipt)])
            try Self.execute(db, "INSERT OR REPLACE INTO metadata VALUES ('clock',?)", [String(now.timeIntervalSince1970)])
            return receipt
        }
    }
    /// Revalidate on every request / SSE frame. A captured receipt cannot outlive ACL changes.
    func validate(_ receipt: Receipt, now: Date = Date()) throws {
        try Self.database(url) { db in
            guard now.timeIntervalSince1970.isFinite, receipt.expiresAt > now,
                  let json = try Self.rows(db, "SELECT record FROM receipts WHERE grant_id=?", [receipt.grantId]).first?.first,
                  try Self.decode(Receipt.self, json) == receipt,
                  let binding = try Self.binding(db, receipt.userId, receipt.deviceId), !binding.revoked,
                  binding.localVersion == receipt.localVersion, binding.cloudBindingId == receipt.cloudBindingId,
                  binding.bindingRevision == receipt.bindingRevision else { throw RemoteAccessError.unauthorized }
            let floor = try Self.rows(db, "SELECT value FROM metadata WHERE key='clock'").first?.first.flatMap(Double.init) ?? 0
            guard now.timeIntervalSince1970 >= floor else { throw RemoteAccessError.unauthorized }
            try Self.execute(db, "INSERT OR REPLACE INTO metadata VALUES ('clock',?)", [String(now.timeIntervalSince1970)])
        }
    }
    /// Revoke one exchanged access without revoking the whole device binding.
    /// Keep its grant jti until the original expiry so exchange retries cannot revive it.
    func revokeReceipt(_ receipt: Receipt) throws {
        try Self.database(url) { db in
            guard let json = try Self.rows(db, "SELECT record FROM receipts WHERE grant_id=?", [receipt.grantId]).first?.first else {
                throw RemoteAccessError.unauthorized
            }
            var revoked = receipt
            revoked.expiresAt = Date(timeIntervalSince1970: 0)
            let existing = try Self.decode(Receipt.self, json)
            guard existing == receipt || existing == revoked else { throw RemoteAccessError.unauthorized }
            try Self.execute(db, "UPDATE receipts SET record=? WHERE grant_id=?", [try Self.encode(revoked), receipt.grantId])
        }
    }
    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T { try JSONDecoder().decode(type, from: Data(json.utf8)) }
    private static func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func binding(_ db: OpaquePointer, _ user: String, _ device: String) throws -> Binding? {
        guard let json = try rows(db, "SELECT record FROM bindings WHERE user=? AND device=?", [user, device]).first?.first else { return nil }
        return try decode(Binding.self, json)
    }
    private static func save(_ db: OpaquePointer, _ binding: Binding) throws {
        try execute(db, "INSERT OR REPLACE INTO bindings VALUES (?,?,?)", [binding.userId, binding.deviceId, try encode(binding)])
    }
    private static func count(_ db: OpaquePointer, _ sql: String) throws -> Int {
        guard let value = try rows(db, sql).first?.first, let count = Int(value) else { throw RemoteAccessError.unavailable }
        return count
    }
    private static func statement(_ db: OpaquePointer, _ sql: String, _ args: [String]) throws -> OpaquePointer {
        var value: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &value, nil) == SQLITE_OK, let value else { throw RemoteAccessError.unavailable }
        for (index, arg) in args.enumerated() {
            guard sqlite3_bind_text(value, Int32(index + 1), arg, -1, transient) == SQLITE_OK else { sqlite3_finalize(value); throw RemoteAccessError.unavailable }
        }
        return value
    }
    private static func execute(_ db: OpaquePointer, _ sql: String, _ args: [String] = []) throws {
        let value = try statement(db, sql, args); defer { sqlite3_finalize(value) }
        let status = sqlite3_step(value)
        guard status == SQLITE_DONE || (status == SQLITE_ROW && sql.hasPrefix("PRAGMA")) else { throw RemoteAccessError.unavailable }
    }
    private static func rows(_ db: OpaquePointer, _ sql: String, _ args: [String] = []) throws -> [[String]] {
        let value = try statement(db, sql, args); defer { sqlite3_finalize(value) }
        var output: [[String]] = []
        while true {
            let status = sqlite3_step(value)
            if status == SQLITE_DONE { return output }
            guard status == SQLITE_ROW else { throw RemoteAccessError.unavailable }
            output.append((0..<sqlite3_column_count(value)).map { index in
                sqlite3_column_text(value, index).map { String(cString: $0) } ?? ""
            })
        }
    }
    private static func database<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        if FileManager.default.fileExists(atPath: url.path) {
            guard try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else {
                throw RemoteAccessError.unavailable
            }
        }
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db = pointer else {
            if let pointer { sqlite3_close(pointer) }; throw RemoteAccessError.unavailable
        }
        defer { sqlite3_close(db) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        sqlite3_busy_timeout(db, 1000)
        try execute(db, "PRAGMA journal_mode=WAL"); try execute(db, "PRAGMA synchronous=FULL"); try execute(db, "BEGIN IMMEDIATE")
        do { let result = try body(db); try execute(db, "COMMIT"); return result }
        catch { try? execute(db, "ROLLBACK"); throw error }
    }
}
