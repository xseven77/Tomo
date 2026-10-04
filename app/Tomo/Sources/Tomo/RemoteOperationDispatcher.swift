import Foundation

/// Shared admission errors so new vendor adapters use the same HTTP contract.
enum RemoteCommandError: Error, Equatable {
    case invalidInput, unsupportedAction, controlChanged, sessionBusy, unsafeStart, executionChanged
}

enum RemoteCommandOutcome: Sendable {
    /// turnId is already a public opaque ID, mapped by the trusted adapter.
    case applied(turnId: String?)
    case rejected
    case uncertain
}

/// Implemented by a trusted source adapter, never by arbitrary HTTP RPC input.
protocol RemoteCommandAdapter: Sendable {
    /// Read-only admission checks. Definite local errors use RemoteCommandError.
    func validate(_ request: RemoteOperationRequest) async throws
    func apply(_ request: RemoteOperationRequest) async throws -> RemoteCommandOutcome
}

/// Runs accepted commands without promising upstream exactly-once. Authorization
/// must check current user/device, VIP, action scope and local source ACL; adapter
/// validation must check ownership/epoch/control/request revision and busy state.
/// External Agent state still requires vendor-side conditional validation.
actor RemoteOperationDispatcher {
    typealias Authorization = @Sendable (RemoteOperationOwner, RemoteOperationRequest) async throws -> Void
    private let store: RemoteOperationStore
    private let adapter: any RemoteCommandAdapter
    private let authorize: Authorization
    private var running = Set<String>()

    init(store: RemoteOperationStore, adapter: any RemoteCommandAdapter, authorize: @escaping Authorization) {
        self.store = store; self.adapter = adapter; self.authorize = authorize
    }

    func submit(owner: RemoteOperationOwner, key: String, request: RemoteOperationRequest) async throws -> RemoteOperation {
        try await authorize(owner, request)
        if let prior = try await store.existing(owner: owner, key: key, request: request) {return prior}
        do {try await adapter.validate(request)}
        catch {
            // Another submit may have committed while this async validation was
            // waiting. Restore dedupe/conflict precedence before returning error.
            try await authorize(owner, request)
            if let prior = try await store.existing(owner: owner, key: key, request: request) {return prior}
            throw error
        }
        try await authorize(owner, request)
        return try await store.accept(owner: owner, key: key, request: request) {}
    }

    /// Called by the local command scheduler. Submission itself never starts a
    /// vendor action. Retries can inspect the original operation; only accepted
    /// records can acquire a dispatch lease.
    func execute(id: String, owner: RemoteOperationOwner, ref: RemoteSessionRef, executionEpoch: String) async throws -> RemoteOperation {
        let request = try await store.request(id: id, owner: owner, ref: ref)
        // Check before returning an existing operation or inspecting its state.
        do {try await authorize(owner, request)}
        catch {
            _ = try await store.rejectAccepted(id: id, owner: owner, ref: ref, errorCode: "authorization_revoked")
            throw error
        }
        if running.contains(id) {return try await store.operation(id: id, owner: owner, ref: ref)}
        guard running.count < 32 else {throw RemoteOperationError.limitExceeded}
        running.insert(id); defer {running.remove(id)}
        let current = try await store.operation(id: id, owner: owner, ref: ref)
        guard current.state == .accepted else {return current}
        do {
            try Task.checkCancellation()
            try await adapter.validate(request)
        } catch {
            return try await store.rejectAccepted(id: id, owner: owner, ref: ref,
                errorCode: error is CancellationError ? "dispatch_cancelled" : "control_changed")
        }
        guard let dispatch = try await store.claim(id: id, owner: owner, ref: ref, executionEpoch: executionEpoch) else {
            return try await store.operation(id: id, owner: owner, ref: ref)
        }
        // Both checks run after durable claim; neither may invoke the vendor.
        // Their failure is a definite rejection because apply was never entered.
        do {try await adapter.validate(request); try Task.checkCancellation()}
        catch {return try await store.finish(dispatch, state: .rejected,
            errorCode: error is CancellationError ? "dispatch_cancelled" : "control_changed")}
        guard try await store.isCurrent(dispatch) else {
            return try await store.operation(id: id, owner: owner, ref: ref)
        }
        // Validation can suspend. Recheck authorization after it, immediately
        // before entering the vendor call, so revocation during preflight wins.
        do {try await authorize(owner, request)}
        catch {return try await store.finish(dispatch, state: .rejected, errorCode: "authorization_revoked")}
        guard try await store.isCurrent(dispatch) else {
            return try await store.operation(id: id, owner: owner, ref: ref)
        }
        do {try Task.checkCancellation()}
        catch {return try await store.finish(dispatch, state: .rejected, errorCode: "dispatch_cancelled")}

        let outcome: RemoteCommandOutcome
        do {outcome = try await adapter.apply(request)}
        catch {
            // Once entered, a transport error or cancellation does not prove
            // whether the Agent accepted the action. Never automatically resend.
            return try await store.finish(dispatch, state: .unknown, errorCode: "dispatch_uncertain")
        }
        switch outcome {
        case .applied(let turnId):
            if let turnId, turnId.isEmpty || turnId.utf8.count > 256 || turnId.contains("\0") {
                return try await store.finish(dispatch, state: .unknown, errorCode: "dispatch_uncertain")
            }
            return try await store.finish(dispatch, state: .applied, turnId: turnId)
        case .rejected: return try await store.finish(dispatch, state: .rejected, errorCode: "upstream_rejected")
        case .uncertain: return try await store.finish(dispatch, state: .unknown, errorCode: "dispatch_uncertain")
        }
    }
}
