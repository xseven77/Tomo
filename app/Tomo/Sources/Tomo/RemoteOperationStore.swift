import Foundation
import CryptoKit
import SQLite3

struct RemoteOperationOwner: Codable, Equatable, Sendable {
    let userId: String
    let deviceId: String
}
struct RemoteOperationRequest: Codable, Equatable, Sendable {
    let ref: RemoteSessionRef
    let executionEpoch: String
    let action: RemoteAction
    let body: AgentJSON
}
struct RemoteOperation: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {case accepted, dispatching, applied, rejected, unknown}
    let operationId: String
    let sessionId: String
    let clientMessageId: String?
    var state: State
    var turnId: String?
    var errorCode: String?
    let createdAt: Date
    var updatedAt: Date
    func responseData() throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
enum RemoteOperationError: Error, Equatable {
    case unavailable, incompatibleSchema, invalidRequest, keyConflict, notFound, staleDispatch, limitExceeded
}

/// Private durable command ledger. The router must authorize every call first;
/// this store neither grants access nor invokes a vendor. In particular accepted
/// is not applied, and an ambiguous dispatch can never be claimed a second time.
actor RemoteOperationStore {
    struct Observation: Sendable {
        let id: UUID
        /// Hints only. Read the durable row through the authorized service;
        /// never infer applied from a wakeup or automatically resend a command.
        let changes: AsyncThrowingStream<String, Error>
    }
    private struct Observer {
        let owner: RemoteOperationOwner
        let ref: RemoteSessionRef
        let actions: Set<RemoteAction>
        let continuation: AsyncThrowingStream<String, Error>.Continuation
    }
    struct Dispatch: Sendable {
        let operation: RemoteOperation
        let request: RemoteOperationRequest
        fileprivate let lease: UUID
    }
    private struct Record: Codable {
        let owner: RemoteOperationOwner
        let key: String
        let request: RemoteOperationRequest
        let digest: String
        var operation: RemoteOperation
        var lease: UUID?
    }
    private let databaseURL: URL
    private let maximumRecords: Int
    private var observers: [UUID: Observer] = [:]

    /// Trusted service only: it must verify identity, source and action scopes
    /// before subscribing and again before returning every queried receipt.
    /// This is process-local notification; GET remains recovery after restart.
    func observe(owner: RemoteOperationOwner, ref: RemoteSessionRef, actions: Set<RemoteAction>) throws -> Observation {
        guard observers.count < 64 else {throw RemoteOperationError.limitExceeded}
        guard [owner.userId, owner.deviceId, ref.serverId, ref.agentId, ref.runtimeId, ref.sessionId].allSatisfy(Self.validIdentifier),
              !actions.isEmpty, actions.isSubset(of: [.sendMessage, .interrupt, .approve, .answer]) else {
            throw RemoteOperationError.invalidRequest
        }
        let id = UUID()
        let pair = AsyncThrowingStream<String, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        pair.continuation.onTermination = { [weak self] _ in Task {await self?.removeObserver(id)} }
        observers[id] = .init(owner: owner, ref: ref, actions: actions, continuation: pair.continuation)
        return .init(id: id, changes: pair.stream)
    }
    func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)?.continuation.finish()
    }
    private func notify(_ record: Record) {
        notify(owner: record.owner, ref: record.request.ref, action: record.request.action, id: record.operation.operationId)
    }
    private func notify(owner: RemoteOperationOwner, ref: RemoteSessionRef, action: RemoteAction, id operationId: String) {
        var closed: [UUID] = []
        for (id, observer) in observers where observer.owner == owner && observer.ref == ref
            && observer.actions.contains(action) {
            switch observer.continuation.yield(operationId) {
            case .enqueued: break
            case .dropped:
                observer.continuation.finish(throwing: RemoteOperationError.limitExceeded); closed.append(id)
            case .terminated: closed.append(id)
            @unknown default:
                observer.continuation.finish(throwing: RemoteOperationError.unavailable); closed.append(id)
            }
        }
        for id in closed {observers.removeValue(forKey: id)}
    }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(databaseURL: URL, maximumRecords: Int = 10000) throws {
        guard databaseURL.isFileURL, (1...10000).contains(maximumRecords) else {throw RemoteOperationError.invalidRequest}
        self.databaseURL = databaseURL; self.maximumRecords = maximumRecords
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try Self.database(databaseURL) {db in
            let version = try Self.integer(db, "PRAGMA user_version")
            guard version == 0 || version == 1 else {throw RemoteOperationError.incompatibleSchema}
            try Self.execute(db, "CREATE TABLE IF NOT EXISTS operations (id TEXT PRIMARY KEY, namespace TEXT NOT NULL UNIQUE, ref TEXT NOT NULL, epoch TEXT NOT NULL, state TEXT NOT NULL, updated REAL NOT NULL, record BLOB NOT NULL)")
            try Self.execute(db, "CREATE INDEX IF NOT EXISTS operations_source ON operations(ref,epoch,state)")
            try Self.execute(db, "PRAGMA user_version=1")
        }
    }

    /// Current identity/scope checks must precede this call. Dedupe precedes the
    /// mutable control/revision check, so retries return the original operation.
    /// validateNew is synchronous; no upstream RPC may occur inside it.
    func accept(owner: RemoteOperationOwner, key: String, request: RemoteOperationRequest,
                now: Date = Date(), validateNew: @Sendable () throws -> Void) throws -> RemoteOperation {
        try validate(owner, key, request, now)
        let digest = try Self.hash(request), namespace = try Self.namespace(owner, request.ref, key)
        var changed: Record?
        let result = try Self.database(databaseURL) {db in
            if let prior = try Self.record(db, "SELECT record FROM operations WHERE namespace=?", [.text(namespace)]) {
                guard prior.digest == digest, prior.owner == owner, prior.request.ref == request.ref else {throw RemoteOperationError.keyConflict}
                return prior.operation
            }
            try validateNew()
            // Unknown and nonterminal records never expire. No deletion may turn
            // an ambiguous upstream dispatch into a new command.
            try Self.execute(db, "DELETE FROM operations WHERE state IN ('applied','rejected') AND updated<?", [.real(now.timeIntervalSince1970 - 86400)])
            guard try Self.integer(db, "SELECT COUNT(*) FROM operations") < maximumRecords else {throw RemoteOperationError.limitExceeded}
            let operation = RemoteOperation(operationId: "op_" + UUID().uuidString.lowercased(), sessionId: request.ref.sessionId,
                clientMessageId: Self.clientMessageId(request), state: .accepted, createdAt: now, updatedAt: now)
            let record = Record(owner: owner, key: key, request: request, digest: digest, operation: operation)
            try Self.execute(db, "INSERT INTO operations VALUES(?,?,?,?,?,?,?)", [.text(operation.operationId), .text(namespace),
                .text(try Self.hash(request.ref)), .text(request.executionEpoch), .text(operation.state.rawValue),
                .real(now.timeIntervalSince1970), .blob(try Self.encode(record))])
            changed = record
            return operation
        }
        if let changed {notify(changed)}
        return result
    }

    func byKey(owner: RemoteOperationOwner, ref: RemoteSessionRef, key: String) throws -> RemoteOperation {
        try Self.database(databaseURL) {db in
            guard let record = try Self.record(db, "SELECT record FROM operations WHERE namespace=?", [.text(try Self.namespace(owner, ref, key))]),
                  record.owner == owner, record.request.ref == ref else {throw RemoteOperationError.notFound}
            return record.operation
        }
    }
    /// Internal dedupe probe for an async service validator. It returns only
    /// persisted identity, never a dispatch payload or authorization decision.
    func existing(owner: RemoteOperationOwner, key: String, request: RemoteOperationRequest) throws -> RemoteOperation? {
        try validate(owner, key, request, Date())
        return try Self.database(databaseURL) {db in
            guard let record = try Self.record(db, "SELECT record FROM operations WHERE namespace=?", [.text(try Self.namespace(owner, request.ref, key))]) else {return nil}
            guard record.owner == owner, record.request.ref == request.ref, record.digest == (try Self.hash(request)) else {throw RemoteOperationError.keyConflict}
            return record.operation
        }
    }
    /// Private trusted dispatcher access, not a public query response.
    func request(id: String, owner: RemoteOperationOwner, ref: RemoteSessionRef) throws -> RemoteOperationRequest {
        try Self.database(databaseURL) {db in try owned(db, id, owner, ref).request}
    }
    /// Trusted service lookup to recover full source for an owner-scoped GET.
    /// The caller must still authorize that source/action before returning data.
    func request(id: String, owner: RemoteOperationOwner) throws -> RemoteOperationRequest {
        try Self.database(databaseURL) {db in
            guard let record = try Self.record(db, "SELECT record FROM operations WHERE id=?", [.text(id)]),
                  record.owner == owner else {throw RemoteOperationError.notFound}
            return record.request
        }
    }
    func isCurrent(_ dispatch: Dispatch) throws -> Bool {
        try Self.database(databaseURL) {db in
            guard let record = try Self.record(db, "SELECT record FROM operations WHERE id=?", [.text(dispatch.operation.operationId)]) else {return false}
            return record.request == dispatch.request && record.lease == dispatch.lease && record.operation.state == .dispatching
        }
    }
    func rejectAccepted(id: String, owner: RemoteOperationOwner, ref: RemoteSessionRef, errorCode: String,
                        now: Date = Date()) throws -> RemoteOperation {
        guard ["authorization_revoked", "control_changed", "dispatch_cancelled"].contains(errorCode), now.timeIntervalSince1970.isFinite else {throw RemoteOperationError.invalidRequest}
        var changed: Record?
        let result = try Self.database(databaseURL) {db in
            var record = try owned(db, id, owner, ref)
            if record.operation.state == .accepted {
                record.operation.state = .rejected; record.operation.errorCode = errorCode; record.operation.updatedAt = now
                try Self.save(db, record)
                changed = record
            }
            return record.operation
        }
        if let changed {notify(changed)}
        return result
    }
    func operation(id: String, owner: RemoteOperationOwner, ref: RemoteSessionRef) throws -> RemoteOperation {
        try Self.database(databaseURL) {db in try owned(db, id, owner, ref).operation}
    }

    /// Persist dispatching before returning the private payload to an adapter.
    /// Caller must revalidate current authorization, source and vendor control
    /// before sending. A nil result means it has already been claimed/resolved.
    func claim(id: String, owner: RemoteOperationOwner, ref: RemoteSessionRef, executionEpoch: String,
               now: Date = Date()) throws -> Dispatch? {
        guard now.timeIntervalSince1970.isFinite else {throw RemoteOperationError.invalidRequest}
        var changed: Record?
        let result: Dispatch? = try Self.database(databaseURL) {db in
            var record = try owned(db, id, owner, ref)
            guard record.operation.state == .accepted else {return nil}
            guard record.request.executionEpoch == executionEpoch else {
                record.operation.state = .rejected; record.operation.errorCode = "execution_changed"; record.operation.updatedAt = now
                try Self.save(db, record); changed = record; return nil
            }
            let lease = UUID()
            record.lease = lease; record.operation.state = .dispatching; record.operation.updatedAt = now
            try Self.save(db, record)
            changed = record
            return Dispatch(operation: record.operation, request: record.request, lease: lease)
        }
        if let changed {notify(changed)}
        return result
    }

    /// Applied means acknowledged by the vendor, not model completion. Unknown
    /// is terminal here: only an explicit vendor reconciliation layer may later
    /// resolve it; this ledger deliberately offers no automatic resend/reset.
    func finish(_ dispatch: Dispatch, state: RemoteOperation.State, turnId: String? = nil,
                errorCode: String? = nil, now: Date = Date()) throws -> RemoteOperation {
        guard [.applied, .rejected, .unknown].contains(state), now.timeIntervalSince1970.isFinite,
              turnId.map(Self.validIdentifier) ?? true,
              errorCode.map({["upstream_rejected", "authorization_revoked", "control_changed", "dispatch_cancelled", "dispatch_uncertain"].contains($0)}) ?? true else {throw RemoteOperationError.invalidRequest}
        guard state != .applied || errorCode == nil,
              state != .rejected || (turnId == nil && errorCode != nil && errorCode != "dispatch_uncertain"),
              state != .unknown || (turnId == nil && errorCode == "dispatch_uncertain") else {throw RemoteOperationError.invalidRequest}
        var changed: Record?
        let result = try Self.database(databaseURL) {db in
            guard var record = try Self.record(db, "SELECT record FROM operations WHERE id=?", [.text(dispatch.operation.operationId)]),
                  record.request == dispatch.request, record.lease == dispatch.lease, record.operation.state == .dispatching else {throw RemoteOperationError.staleDispatch}
            record.operation.state = state; record.operation.turnId = turnId; record.operation.errorCode = errorCode
            record.operation.updatedAt = now; record.lease = nil
            try Self.save(db, record); changed = record; return record.operation
        }
        if let changed {notify(changed)}
        return result
    }

    /// Trusted lifecycle call only after this execution is known stopped. Merely
    /// opening a second ledger does not claim that another process has crashed.
    func executionStopped(ref: RemoteSessionRef, executionEpoch: String, now: Date = Date()) throws {
        guard now.timeIntervalSince1970.isFinite else {throw RemoteOperationError.invalidRequest}
        var changed: [(RemoteOperationOwner, RemoteAction, String)] = []
        try Self.database(databaseURL) {db in
            let query = try Self.statement(db, "SELECT id FROM operations WHERE ref=? AND epoch=? AND state IN ('accepted','dispatching')",
                [.text(try Self.hash(ref)), .text(executionEpoch)])
            // Keep only IDs, not up to 10,000 private message bodies, while
            // recovering a stopped source. Load/update one record at a time.
            var ids: [String] = []
            do {
                var result = sqlite3_step(query)
                while result == SQLITE_ROW {
                    guard ids.count < 10000, let value = sqlite3_column_text(query, 0) else {throw RemoteOperationError.unavailable}
                    ids.append(String(cString: value)); result = sqlite3_step(query)
                }
                guard result == SQLITE_DONE else {throw RemoteOperationError.unavailable}
                sqlite3_finalize(query)
            } catch {sqlite3_finalize(query); throw error}
            for id in ids {
                guard var record = try Self.record(db, "SELECT record FROM operations WHERE id=?", [.text(id)]),
                      record.request.ref == ref, record.request.executionEpoch == executionEpoch else {throw RemoteOperationError.unavailable}
                record.operation.state = record.operation.state == .dispatching ? .unknown : .rejected
                record.operation.errorCode = record.operation.state == .unknown ? "dispatch_uncertain" : "execution_changed"
                record.operation.updatedAt = now; record.lease = nil
                try Self.save(db, record)
                changed.append((record.owner, record.request.action, record.operation.operationId))
            }
        }
        for (owner, action, id) in changed {notify(owner: owner, ref: ref, action: action, id: id)}
    }

    private func owned(_ db: OpaquePointer, _ id: String, _ owner: RemoteOperationOwner, _ ref: RemoteSessionRef) throws -> Record {
        guard let record = try Self.record(db, "SELECT record FROM operations WHERE id=?", [.text(id)]), record.owner == owner, record.request.ref == ref else {throw RemoteOperationError.notFound}
        return record
    }
    private func validate(_ owner: RemoteOperationOwner, _ key: String, _ request: RemoteOperationRequest, _ now: Date) throws {
        guard [owner.userId, owner.deviceId, request.ref.serverId, request.ref.agentId, request.ref.runtimeId,
               request.ref.sessionId, request.executionEpoch].allSatisfy(Self.validIdentifier),
              (16...128).contains(key.utf8.count), key.utf8.allSatisfy({(48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95}),
              [.sendMessage, .interrupt, .approve, .answer].contains(request.action),
              now.timeIntervalSince1970.isFinite else {throw RemoteOperationError.invalidRequest}
        if request.action == .sendMessage {
            guard let id = Self.clientMessageId(request), Self.validIdentifier(id) else {throw RemoteOperationError.invalidRequest}
        }
        guard try Self.encode(request).count <= 64 * 1024 else {throw RemoteOperationError.limitExceeded}
    }
    private static func validIdentifier(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 256 && !value.contains("\0") }
    private static func clientMessageId(_ request: RemoteOperationRequest) -> String? {
        guard case .object(let fields) = request.body, case .string(let id) = fields["clientMessageId"] else {return nil}
        return id
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)}
    private static func hash<T: Encodable>(_ value: T) throws -> String {SHA256.hash(data: try encode(value)).map {String(format: "%02x", $0)}.joined()}
    private static func namespace(_ owner: RemoteOperationOwner, _ ref: RemoteSessionRef, _ key: String) throws -> String {
        try hash([owner.userId, owner.deviceId, ref.serverId, ref.agentId, ref.runtimeId, ref.sessionId, key])
    }
    private static func save(_ db: OpaquePointer, _ record: Record) throws {
        try execute(db, "UPDATE operations SET state=?,updated=?,record=? WHERE id=?", [.text(record.operation.state.rawValue),
            .real(record.operation.updatedAt.timeIntervalSince1970), .blob(try encode(record)), .text(record.operation.operationId)])
    }
    private enum Binding {case text(String), blob(Data), real(Double)}
    private static func statement(_ db: OpaquePointer, _ sql: String, _ bindings: [Binding] = []) throws -> OpaquePointer {
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &pointer, nil) == SQLITE_OK, let pointer else {throw RemoteOperationError.unavailable}
        for (index, value) in bindings.enumerated() {
            let slot = Int32(index + 1), result: Int32
            switch value {
            case .text(let text): result = sqlite3_bind_text(pointer, slot, text, -1, transient)
            case .real(let value): result = sqlite3_bind_double(pointer, slot, value)
            case .blob(let bytes): result = bytes.withUnsafeBytes {sqlite3_bind_blob(pointer, slot, $0.baseAddress, Int32(bytes.count), transient)}
            }
            guard result == SQLITE_OK else {sqlite3_finalize(pointer); throw RemoteOperationError.unavailable}
        }
        return pointer
    }
    private static func execute(_ db: OpaquePointer, _ sql: String, _ bindings: [Binding] = []) throws {
        let statement = try statement(db, sql, bindings); defer {sqlite3_finalize(statement)}
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {result = sqlite3_step(statement)}
        guard result == SQLITE_DONE else {throw RemoteOperationError.unavailable}
    }
    private static func integer(_ db: OpaquePointer, _ sql: String) throws -> Int {
        let statement = try statement(db, sql); defer {sqlite3_finalize(statement)}
        guard sqlite3_step(statement) == SQLITE_ROW else {throw RemoteOperationError.unavailable}
        return Int(sqlite3_column_int64(statement, 0))
    }
    private static func decode(_ statement: OpaquePointer) throws -> Record {
        let size = Int(sqlite3_column_bytes(statement, 0))
        guard (1...128 * 1024).contains(size), let bytes = sqlite3_column_blob(statement, 0) else {throw RemoteOperationError.unavailable}
        return try JSONDecoder().decode(Record.self, from: Data(bytes: bytes, count: size))
    }
    private static func record(_ db: OpaquePointer, _ sql: String, _ bindings: [Binding]) throws -> Record? {
        let statement = try statement(db, sql, bindings); defer {sqlite3_finalize(statement)}
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE {return nil}
        guard result == SQLITE_ROW else {throw RemoteOperationError.unavailable}
        return try decode(statement)
    }
    private static func database<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db = pointer else {
            if let pointer {sqlite3_close(pointer)}; throw RemoteOperationError.unavailable
        }
        defer {sqlite3_close(db)}
        for path in [url.path, url.path + "-wal", url.path + "-shm"] where FileManager.default.fileExists(atPath: path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
        sqlite3_busy_timeout(db, 1000)
        try execute(db, "PRAGMA journal_mode=WAL"); try execute(db, "PRAGMA synchronous=FULL"); try execute(db, "BEGIN IMMEDIATE")
        do {let result = try body(db); try execute(db, "COMMIT"); return result}
        catch {try? execute(db, "ROLLBACK"); throw error}
    }
}
