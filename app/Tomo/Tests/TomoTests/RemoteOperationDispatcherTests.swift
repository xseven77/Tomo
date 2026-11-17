import Foundation
import Testing
@testable import Tomo

private enum DispatchTestError: Error {case denied, invalid, transport}

private actor DispatchAuthorization {
    var allowed = true
    func revoke() {allowed = false}
    func check() throws {if !allowed {throw DispatchTestError.denied}}
}

private actor DispatchAdapter: RemoteCommandAdapter {
    var validations = 0
    var applications = 0
    var invalid = false
    var transportFailure = false
    var result: RemoteCommandOutcome = .applied(turnId: "public-turn")
    var pauseAt: Int?
    private var paused: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func configure(invalid: Bool = false, transportFailure: Bool = false, result: RemoteCommandOutcome = .applied(turnId: "public-turn"), pauseAt: Int? = nil) {
        self.invalid = invalid; self.transportFailure = transportFailure
        self.result = result; self.pauseAt = pauseAt
    }
    func validate(_ request: RemoteOperationRequest) async throws {
        validations += 1
        if validations == pauseAt {
            await withCheckedContinuation {continuation in
                paused = continuation
                let waiting = observers; observers.removeAll()
                waiting.forEach {$0.resume()}
            }
        }
        if invalid {throw DispatchTestError.invalid}
    }
    func waitForPause() async {
        if paused != nil {return}
        await withCheckedContinuation {observers.append($0)}
    }
    func release() {paused?.resume(); paused = nil}
    func apply(_ request: RemoteOperationRequest) async throws -> RemoteCommandOutcome {
        applications += 1
        if transportFailure {throw DispatchTestError.transport}
        return result
    }
}

struct RemoteOperationDispatcherTests {
    private let owner = RemoteOperationOwner(userId: "user", deviceId: "device")
    private let ref = RemoteSessionRef(serverId: "server", agentId: "agent.chatgpt", runtimeId: "runtime", sessionId: "session")
    private let key = "dispatcher-key-123456"
    private func request(text: String = "hello") -> RemoteOperationRequest {
        .init(ref: ref, executionEpoch: "execution", action: .sendMessage,
            body: .object(["clientMessageId": .string("client"), "text": .string(text)]))
    }
    private func location() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tomo-dispatch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("operations.sqlite")
    }
    private func dispatcher(_ store: RemoteOperationStore, _ adapter: DispatchAdapter, _ auth: DispatchAuthorization) -> RemoteOperationDispatcher {
        RemoteOperationDispatcher(store: store, adapter: adapter) {_, _ in try await auth.check()}
    }

    @Test func submissionIsDurableWithoutDispatchAndRetriesRequireCurrentAuthorization() async throws {
        let url = try location(); defer {try? FileManager.default.removeItem(at: url.deletingLastPathComponent())}
        let store = try RemoteOperationStore(databaseURL: url), adapter = DispatchAdapter(), auth = DispatchAuthorization()
        let service = dispatcher(store, adapter, auth)
        let first = try await service.submit(owner: owner, key: key, request: request())
        #expect(first.state == .accepted)
        #expect(await adapter.applications == 0)
        await adapter.configure(invalid: true)
        #expect(try await service.submit(owner: owner, key: key, request: request()) == first)
        await #expect(throws: RemoteOperationError.keyConflict) {try await service.submit(owner: owner, key: key, request: request(text: "changed"))}
        await auth.revoke()
        await #expect(throws: DispatchTestError.denied) {try await service.submit(owner: owner, key: key, request: request())}
        await #expect(throws: DispatchTestError.denied) {try await service.execute(id: first.operationId, owner: owner, ref: ref, executionEpoch: "execution")}
        #expect(try await store.operation(id: first.operationId, owner: owner, ref: ref).errorCode == "authorization_revoked")
    }

    @Test func concurrentCommitWinsOverSuspendedMutableValidationFailure() async throws {
        let url = try location(); defer {try? FileManager.default.removeItem(at: url.deletingLastPathComponent())}
        let store = try RemoteOperationStore(databaseURL: url), adapter = DispatchAdapter(), auth = DispatchAuthorization()
        await adapter.configure(invalid: true, pauseAt: 1)
        let service = dispatcher(store, adapter, auth)
        let pending = Task {try await service.submit(owner: owner, key: key, request: request())}
        await adapter.waitForPause()
        let other = try RemoteOperationStore(databaseURL: url)
        let first = try await other.accept(owner: owner, key: key, request: request()) {}
        await adapter.release()
        #expect(try await pending.value == first)
        #expect(await adapter.applications == 0)
    }

    @Test func revocationDuringFinalValidationRejectsBeforeCallingVendor() async throws {
        let url = try location(); defer {try? FileManager.default.removeItem(at: url.deletingLastPathComponent())}
        let store = try RemoteOperationStore(databaseURL: url), adapter = DispatchAdapter(), auth = DispatchAuthorization()
        let service = dispatcher(store, adapter, auth)
        let first = try await service.submit(owner: owner, key: key, request: request())
        await adapter.configure(pauseAt: 3)
        let pending = Task {try await service.execute(id: first.operationId, owner: owner, ref: ref, executionEpoch: "execution")}
        await adapter.waitForPause()
        #expect(try await store.operation(id: first.operationId, owner: owner, ref: ref).state == .dispatching)
        await auth.revoke(); await adapter.release()
        let result = try await pending.value
        #expect(result.state == .rejected && result.errorCode == "authorization_revoked")
        #expect(await adapter.applications == 0)
    }

    @Test func knownExecutionStopInvalidatesLeaseBeforeVendorCall() async throws {
        let url = try location(); defer {try? FileManager.default.removeItem(at: url.deletingLastPathComponent())}
        let store = try RemoteOperationStore(databaseURL: url), adapter = DispatchAdapter(), auth = DispatchAuthorization()
        let service = dispatcher(store, adapter, auth)
        let first = try await service.submit(owner: owner, key: key, request: request())
        await adapter.configure(pauseAt: 3)
        let pending = Task {try await service.execute(id: first.operationId, owner: owner, ref: ref, executionEpoch: "execution")}
        await adapter.waitForPause()
        try await store.executionStopped(ref: ref, executionEpoch: "execution")
        await adapter.release()
        #expect(try await pending.value.state == .unknown)
        #expect(await adapter.applications == 0)
    }

    @Test func concurrentDispatchersClaimOnceAndTerminalRetryNeverResends() async throws {
        let url = try location(); defer {try? FileManager.default.removeItem(at: url.deletingLastPathComponent())}
        let store = try RemoteOperationStore(databaseURL: url), adapter = DispatchAdapter(), auth = DispatchAuthorization()
        let first = dispatcher(store, adapter, auth)
        let operation = try await first.submit(owner: owner, key: key, request: request())
        let second = dispatcher(try RemoteOperationStore(databaseURL: url), adapter, auth)
        async let a = first.execute(id: operation.operationId, owner: owner, ref: ref, executionEpoch: "execution")
        async let b = second.execute(id: operation.operationId, owner: owner, ref: ref, executionEpoch: "execution")
        _ = try await [a, b]
        let finished = try await second.execute(id: operation.operationId, owner: owner, ref: ref, executionEpoch: "execution")
        #expect(finished.state == .applied && finished.turnId == "public-turn")
        #expect(await adapter.applications == 1)
    }

    @Test func uncertainAndDefiniteRejectionRemainDistinctAfterRestart() async throws {
        for fails in [true, false] {
            let url = try location(); defer {try? FileManager.default.removeItem(at: url.deletingLastPathComponent())}
            let store = try RemoteOperationStore(databaseURL: url), adapter = DispatchAdapter(), auth = DispatchAuthorization()
            await adapter.configure(transportFailure: fails, result: .rejected)
            let service = dispatcher(store, adapter, auth)
            let first = try await service.submit(owner: owner, key: key, request: request())
            let result = try await service.execute(id: first.operationId, owner: owner, ref: ref, executionEpoch: "execution")
            #expect(result.state == (fails ? .unknown : .rejected))
            #expect(result.errorCode == (fails ? "dispatch_uncertain" : "upstream_rejected"))
            let restarted = dispatcher(try RemoteOperationStore(databaseURL: url), adapter, auth)
            #expect(try await restarted.execute(id: first.operationId, owner: owner, ref: ref, executionEpoch: "execution") == result)
            #expect(await adapter.applications == 1)
        }
    }

    @Test func cancelledPreflightAndChangedControlNeverEnterVendor() async throws {
        for cancelled in [true, false] {
            let url = try location(); defer {try? FileManager.default.removeItem(at: url.deletingLastPathComponent())}
            let store = try RemoteOperationStore(databaseURL: url), adapter = DispatchAdapter(), auth = DispatchAuthorization()
            let service = dispatcher(store, adapter, auth)
            let first = try await service.submit(owner: owner, key: key, request: request())
            await adapter.configure(pauseAt: 3)
            let pending = Task {try await service.execute(id: first.operationId, owner: owner, ref: ref, executionEpoch: "execution")}
            await adapter.waitForPause()
            if cancelled {pending.cancel()}
            else {await adapter.configure(invalid: true)}
            await adapter.release()
            let result = try await pending.value
            #expect(result.state == .rejected)
            #expect(result.errorCode == (cancelled ? "dispatch_cancelled" : "control_changed"))
            #expect(await adapter.applications == 0)
        }
    }

    @Test func concurrentChangedBodyConflictWinsOverValidationError() async throws {
        let url = try location(); defer {try? FileManager.default.removeItem(at: url.deletingLastPathComponent())}
        let store = try RemoteOperationStore(databaseURL: url), adapter = DispatchAdapter(), auth = DispatchAuthorization()
        await adapter.configure(invalid: true, pauseAt: 1)
        let service = dispatcher(store, adapter, auth)
        let pending = Task {try await service.submit(owner: owner, key: key, request: request())}
        await adapter.waitForPause()
        _ = try await store.accept(owner: owner, key: key, request: request(text: "different")) {}
        await adapter.release()
        await #expect(throws: RemoteOperationError.keyConflict) {try await pending.value}
        #expect(await adapter.applications == 0)
    }
}
