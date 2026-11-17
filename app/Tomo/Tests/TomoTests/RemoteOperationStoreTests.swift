import Foundation
import Testing
@testable import Tomo

struct RemoteOperationStoreTests {
    @Test func committedChangesAreScopedAndDuplicatesAndFailuresNeverNotify() async throws {
        let url = try location(); defer {try? FileManager.default.removeItem(at: url.deletingLastPathComponent())}
        let store = try RemoteOperationStore(databaseURL: url)
        let matching = try await store.observe(owner: owner, ref: ref, actions: [.sendMessage])
        let wrongDevice = try await store.observe(owner: .init(userId: owner.userId, deviceId: "other"), ref: ref, actions: [.sendMessage])
        let wrongSource = try await store.observe(owner: owner,
            ref: .init(serverId: "other", agentId: ref.agentId, runtimeId: ref.runtimeId, sessionId: ref.sessionId), actions: [.sendMessage])
        let wrongAction = try await store.observe(owner: owner, ref: ref, actions: [.interrupt])
        var stream = matching.changes.makeAsyncIterator()
        let accepted = try await store.accept(owner: owner, key: key, request: request()) {}
        #expect(try await stream.next() == accepted.operationId)
        // A separate connection proves the hint follows COMMIT, not just INSERT.
        let disk = try RemoteOperationStore(databaseURL: url)
        #expect(try await disk.operation(id: accepted.operationId, owner: owner, ref: ref).state == .accepted)
        _ = try await store.accept(owner: owner, key: key, request: request()) {throw RemoteOperationError.invalidRequest}
        await #expect(throws: RemoteOperationError.keyConflict) {try await store.accept(owner: owner, key: key, request: request(text: "conflict")) {}}
        let claimed = try #require(try await store.claim(id: accepted.operationId, owner: owner, ref: ref, executionEpoch: "execution"))
        #expect(try await stream.next() == accepted.operationId)
        _ = try await store.finish(claimed, state: .applied)
        #expect(try await stream.next() == accepted.operationId)
        #expect(try await disk.operation(id: accepted.operationId, owner: owner, ref: ref).state == .applied)
        for observation in [matching, wrongDevice, wrongSource, wrongAction] {await store.removeObserver(observation.id)}
        #expect(try await stream.next() == nil)
        for observation in [wrongDevice, wrongSource, wrongAction] {
            var iterator = observation.changes.makeAsyncIterator()
            #expect(try await iterator.next() == nil)
        }
    }

    @Test func stoppedExecutionNotifiesAfterBothRowsCommitAndOverflowIsExplicit() async throws {
        let url = try location(); defer {try? FileManager.default.removeItem(at: url.deletingLastPathComponent())}
        let store = try RemoteOperationStore(databaseURL: url)
        let first = try await store.accept(owner: owner, key: key, request: request()) {}
        let second = try await store.accept(owner: owner, key: key + "_waiting", request: request()) {}
        _ = try await store.claim(id: first.operationId, owner: owner, ref: ref, executionEpoch: "execution")
        let observation = try await store.observe(owner: owner, ref: ref, actions: [.sendMessage])
        try await store.executionStopped(ref: ref, executionEpoch: "execution")
        #expect(try await store.operation(id: first.operationId, owner: owner, ref: ref).state == .unknown)
        #expect(try await store.operation(id: second.operationId, owner: owner, ref: ref).state == .rejected)
        await store.removeObserver(observation.id)
        var notified: [String] = []
        for try await id in observation.changes {notified.append(id)}
        #expect(Set(notified) == [first.operationId, second.operationId])
        let slow = try await store.observe(owner: owner, ref: ref, actions: [.sendMessage])
        for index in 0..<129 {_ = try await store.accept(owner: owner, key: key + "_" + String(index), request: request()) {}}
        var count = 0
        do {
            for try await _ in slow.changes {count += 1}
            Issue.record("Overflow must force receipt recovery")
        } catch RemoteOperationError.limitExceeded {}
        #expect(count == 128)
        #expect(try await store.byKey(owner: owner, ref: ref, key: key + "_128").state == .accepted)
        await store.removeObserver(slow.id)
    }

    private let owner = RemoteOperationOwner(userId: "user", deviceId: "phone")
    private let ref = RemoteSessionRef(serverId: "server", agentId: "agent.chatgpt", runtimeId: "runtime", sessionId: "session")
    private let key = "message-key-123456789"
    private func request(text: String = "private message", epoch: String = "execution") -> RemoteOperationRequest {
        .init(ref: ref, executionEpoch: epoch, action: .sendMessage,
            body: .object(["clientMessageId": .string("client-message"), "expectedControlRevision": .integer(1), "text": .string(text)]))
    }
    private func location() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tomo-operations-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("operations.sqlite")
    }

    @Test func duplicateReturnsPersistedIdentityBeforeMutableValidationAndConflictsOnChangedBody() async throws {
        let url = try location(); defer {try? FileManager.default.removeItem(at: url.deletingLastPathComponent())}
        let store = try RemoteOperationStore(databaseURL: url)
        let first = try await store.accept(owner: owner, key: key, request: request()) {}
        let restarted = try RemoteOperationStore(databaseURL: url)
        let retry = try await restarted.accept(owner: owner, key: key, request: request()) {throw RemoteOperationError.invalidRequest}
        #expect(retry == first && retry.state == .accepted)
        await #expect(throws: RemoteOperationError.keyConflict) {try await restarted.accept(owner: owner, key: key, request: request(text: "changed")) {}}
        #expect(try await restarted.byKey(owner: owner, ref: ref, key: key).operationId == first.operationId)
        let wire = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
        #expect(first.clientMessageId == "client-message")
        #expect(!wire.contains("private message") && !wire.contains(key) && !wire.contains("phone"))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func concurrentConnectionsAcceptAndClaimOnlyOnce() async throws {
        let url = try location(); defer {try? FileManager.default.removeItem(at: url.deletingLastPathComponent())}
        let first = try RemoteOperationStore(databaseURL: url), second = try RemoteOperationStore(databaseURL: url)
        let results = try await withThrowingTaskGroup(of: RemoteOperation.self) {group in
            for index in 0..<40 {
                group.addTask {try await (index % 2 == 0 ? first : second).accept(owner: owner, key: key, request: request()) {}}
            }
            var values: [RemoteOperation] = []
            for try await result in group {values.append(result)}
            return values
        }
        #expect(Set(results.map(\.operationId)).count == 1)
        let operation = try #require(results.first)
        async let a = first.claim(id: operation.operationId, owner: owner, ref: ref, executionEpoch: "execution")
        async let b = second.claim(id: operation.operationId, owner: owner, ref: ref, executionEpoch: "execution")
        let claims = try await [a, b]
        #expect(claims.compactMap {$0}.count == 1)
        let dispatch = try #require(claims.compactMap {$0}.first)
        let result = try await first.finish(dispatch, state: .applied, turnId: "opaque-turn")
        #expect(result.state == .applied && result.turnId == "opaque-turn")
        await #expect(throws: RemoteOperationError.staleDispatch) {try await second.finish(dispatch, state: .applied)}
    }

    @Test func identitiesAndFullSourcesCannotReadEachOthersOperations() async throws {
        let url = try location(); defer {try? FileManager.default.removeItem(at: url.deletingLastPathComponent())}
        let store = try RemoteOperationStore(databaseURL: url)
        let first = try await store.accept(owner: owner, key: key, request: request()) {}
        let other = RemoteOperationOwner(userId: "user", deviceId: "other-phone")
        let second = try await store.accept(owner: other, key: key, request: request()) {}
        #expect(second.operationId != first.operationId)
        await #expect(throws: RemoteOperationError.notFound) {try await store.operation(id: first.operationId, owner: other, ref: ref)}
        let otherRef = RemoteSessionRef(serverId: "server", agentId: "agent.chatgpt", runtimeId: "other-runtime", sessionId: "session")
        await #expect(throws: RemoteOperationError.notFound) {try await store.operation(id: first.operationId, owner: owner, ref: otherRef)}
        await #expect(throws: RemoteOperationError.notFound) {try await store.byKey(owner: owner, ref: otherRef, key: key)}
    }

    @Test func interruptedDispatchBecomesUnknownAndCannotBeAutomaticallyReclaimedOrExpired() async throws {
        let url = try location(); defer {try? FileManager.default.removeItem(at: url.deletingLastPathComponent())}
        let store = try RemoteOperationStore(databaseURL: url, maximumRecords: 2)
        let now = Date(timeIntervalSince1970: 100000)
        let first = try await store.accept(owner: owner, key: key, request: request(), now: now) {}
        let pending = try await store.accept(owner: owner, key: key + "_pending", request: request(), now: now) {}
        let dispatch = try #require(try await store.claim(id: first.operationId, owner: owner, ref: ref, executionEpoch: "execution", now: now))
        let restarted = try RemoteOperationStore(databaseURL: url, maximumRecords: 2)
        #expect(try await restarted.operation(id: first.operationId, owner: owner, ref: ref).state == .dispatching)
        try await restarted.executionStopped(ref: ref, executionEpoch: "execution", now: now)
        #expect(try await restarted.operation(id: first.operationId, owner: owner, ref: ref).state == .unknown)
        #expect(try await restarted.operation(id: pending.operationId, owner: owner, ref: ref).state == .rejected)
        #expect(try await restarted.claim(id: first.operationId, owner: owner, ref: ref, executionEpoch: "execution") == nil)
        await #expect(throws: RemoteOperationError.staleDispatch) {try await store.finish(dispatch, state: .applied)}
        _ = try await restarted.accept(owner: owner, key: key + "_new", request: request(), now: now.addingTimeInterval(86401)) {}
        let old = try await restarted.accept(owner: owner, key: key, request: request(), now: now.addingTimeInterval(999999)) {throw RemoteOperationError.invalidRequest}
        #expect(old.operationId == first.operationId && old.state == .unknown)
    }

    @Test func terminalDedupeIsRetainedForAtLeastOneDayAndCapacityFailsExplicitly() async throws {
        let url = try location(); defer {try? FileManager.default.removeItem(at: url.deletingLastPathComponent())}
        let store = try RemoteOperationStore(databaseURL: url, maximumRecords: 1), now = Date(timeIntervalSince1970: 100000)
        let first = try await store.accept(owner: owner, key: key, request: request(), now: now) {}
        let dispatch = try #require(try await store.claim(id: first.operationId, owner: owner, ref: ref, executionEpoch: "execution", now: now))
        _ = try await store.finish(dispatch, state: .applied, now: now)
        await #expect(throws: RemoteOperationError.limitExceeded) {try await store.accept(owner: owner, key: key + "_new", request: request(), now: now.addingTimeInterval(3600)) {}}
        #expect(try await store.byKey(owner: owner, ref: ref, key: key).operationId == first.operationId)
        _ = try await store.accept(owner: owner, key: key + "_new", request: request(), now: now.addingTimeInterval(86401)) {}
        await #expect(throws: RemoteOperationError.notFound) {try await store.byKey(owner: owner, ref: ref, key: key)}
    }

    @Test func invalidKeysPayloadsAndFailedValidationCannotPersistAnAcceptance() async throws {
        let url = try location(); defer {try? FileManager.default.removeItem(at: url.deletingLastPathComponent())}
        let store = try RemoteOperationStore(databaseURL: url)
        for value in ["short", "contains / punctuation", String(repeating: "a", count: 129)] {
            await #expect(throws: RemoteOperationError.invalidRequest) {try await store.accept(owner: owner, key: value, request: request()) {}}
        }
        await #expect(throws: RemoteOperationError.limitExceeded) {try await store.accept(owner: owner, key: key, request: request(text: String(repeating: "x", count: 65536))) {}}
        await #expect(throws: RemoteOperationError.invalidRequest) {try await store.accept(owner: owner, key: key, request: request()) {throw RemoteOperationError.invalidRequest}}
        await #expect(throws: RemoteOperationError.notFound) {try await store.byKey(owner: owner, ref: ref, key: key)}
    }

    @Test func sourceAndEpochRecoveryCannotInvalidateAnotherExecutionOrAcceptALateResult() async throws {
        let url = try location(); defer {try? FileManager.default.removeItem(at: url.deletingLastPathComponent())}
        let store = try RemoteOperationStore(databaseURL: url)
        let first = try await store.accept(owner: owner, key: key, request: request()) {}
        let other = try await store.accept(owner: owner, key: key + "_other", request: request(epoch: "new-execution")) {}
        let dispatch = try #require(try await store.claim(id: first.operationId, owner: owner, ref: ref, executionEpoch: "execution"))
        let otherRef = RemoteSessionRef(serverId: "other-server", agentId: ref.agentId, runtimeId: ref.runtimeId, sessionId: ref.sessionId)
        try await store.executionStopped(ref: otherRef, executionEpoch: "execution")
        #expect(try await store.operation(id: first.operationId, owner: owner, ref: ref).state == .dispatching)
        try await store.executionStopped(ref: ref, executionEpoch: "execution")
        #expect(try await store.operation(id: other.operationId, owner: owner, ref: ref).state == .accepted)
        await #expect(throws: RemoteOperationError.staleDispatch) {try await store.finish(dispatch, state: .applied)}
        #expect(try await store.claim(id: other.operationId, owner: owner, ref: ref, executionEpoch: "wrong-execution") == nil)
        let rejected = try await store.byKey(owner: owner, ref: ref, key: key + "_other")
        #expect(rejected.state == .rejected && rejected.errorCode == "execution_changed")
    }

    @Test func payloadOrderIsCanonicalAndContradictoryOutcomesAreRejected() async throws {
        let url = try location(); defer {try? FileManager.default.removeItem(at: url.deletingLastPathComponent())}
        let store = try RemoteOperationStore(databaseURL: url)
        let bodyA: AgentJSON = .object(["clientMessageId": .string("client-message"), "input": .object(["b": .integer(2), "a": .integer(1)])])
        let bodyB: AgentJSON = .object(["input": .object(["a": .integer(1), "b": .integer(2)]), "clientMessageId": .string("client-message")])
        let a = RemoteOperationRequest(ref: ref, executionEpoch: "execution", action: .sendMessage, body: bodyA)
        let b = RemoteOperationRequest(ref: ref, executionEpoch: "execution", action: .sendMessage, body: bodyB)
        let first = try await store.accept(owner: owner, key: key, request: a) {}
        #expect(try await store.accept(owner: owner, key: key, request: b) {} == first)
        let dispatch = try #require(try await store.claim(id: first.operationId, owner: owner, ref: ref, executionEpoch: "execution"))
        await #expect(throws: RemoteOperationError.invalidRequest) {try await store.finish(dispatch, state: .applied, errorCode: "dispatch_uncertain")}
        await #expect(throws: RemoteOperationError.invalidRequest) {try await store.finish(dispatch, state: .unknown)}
        await #expect(throws: RemoteOperationError.invalidRequest) {try await store.finish(dispatch, state: .rejected, turnId: "turn", errorCode: "upstream_rejected")}
        #expect(try await store.operation(id: first.operationId, owner: owner, ref: ref).state == .dispatching)
        let terminal = try await store.finish(dispatch, state: .unknown, errorCode: "dispatch_uncertain")
        #expect(terminal.state == .unknown)
    }
}
