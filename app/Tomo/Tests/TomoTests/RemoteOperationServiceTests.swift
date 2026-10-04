import Foundation
import Testing
@testable import Tomo

private actor OperationServiceAdapter: RemoteCommandAdapter {
    var applications = 0
    func validate(_ request: RemoteOperationRequest) throws {}
    func apply(_ request: RemoteOperationRequest) -> RemoteCommandOutcome {
        applications += 1; return .applied(turnId: "public-turn")
    }
}
private actor OperationIdentityGate {
    let owner = RemoteOperationOwner(userId: "verified-user", deviceId: "verified-device")
    var denied = false
    var shouldPause = false
    var paused = false
    private var continuation: CheckedContinuation<Void, Never>?
    func configure(denied: Bool = false, pause: Bool = false) {self.denied = denied; shouldPause = pause}
    func resolve() async throws -> RemoteOperationOwner {
        if shouldPause {
            shouldPause = false
            await withCheckedContinuation {continuation = $0; paused = true}
        }
        if denied {throw RemoteAccessError.forbidden}
        return owner
    }
    func release() {continuation?.resume(); continuation = nil; paused = false}
}

struct RemoteOperationServiceTests {
    @Test func receiptSidebandDoesNotChangeHistoryAndRejectsOtherDevicesAndReadScopes() async throws {
        let url = try location(); defer {try? FileManager.default.removeItem(at: url.deletingLastPathComponent())}
        let store = try RemoteOperationStore(databaseURL: url), access = RemoteAccessStore()
        await access.setDevelopmentEnabled(true)
        let writer = try await credential(access, actions: [.readHistory, .interrupt]).principal
        let other = try await credential(access, actions: [.readHistory, .interrupt]).principal
        let reader = try await credential(access, actions: [.readHistory]).principal
        let operations = RemoteOperationService(serverId: ref.serverId, access: access, store: store) {
            .init(userId: "local", deviceId: $0.id.uuidString)
        }
        _ = try await operations.register(ref: ref, executionEpoch: "execution", actions: [.interrupt], adapter: OperationServiceAdapter())
        let journal = try RemoteSessionJournal(databaseURL: url.deletingLastPathComponent().appendingPathComponent("events.sqlite"))
        let baseline = try await journal.replace(ref: ref, projection: .init(control: .init(executionEpoch: "execution", controlRevision: 1,
            state: "running", controlMode: "live", currentTurnId: "public-turn", allowedActions: ["history.read", "turn.interrupt"]),
            messages: [], pendingRequests: [], olderHistoryCursor: nil, hasOlder: false))
        let sessions = RemoteSessionService(serverId: ref.serverId)
        let lease = try await sessions.register(ref: ref, journal: journal)
        try await sessions.publishCommands(sessionId: ref.sessionId, lease: lease, service: operations)
        let feed = try await sessions.open(sessionId: ref.sessionId, query: [:], cursor: baseline.eventCursor, principal: writer)
        let otherFeed = try await sessions.open(sessionId: ref.sessionId, query: [:], cursor: baseline.eventCursor, principal: other)
        let readFeed = try await sessions.open(sessionId: ref.sessionId, query: [:], cursor: baseline.eventCursor, principal: reader)
        let accepted = try await store.accept(owner: .init(userId: "local", deviceId: writer.id.uuidString), key: key, request: request) {}
        try await wait {
            // Reading IDs consumes the bounded hint queue; receipts stay durable.
            let ids = try await sessions.operationIDs(feed, principal: writer)
            return ids.contains(accepted.operationId)
        }
        #expect(try await sessions.operationIDs(otherFeed, principal: other).isEmpty)
        #expect(try await sessions.operationIDs(readFeed, principal: reader).isEmpty)
        let frame = try await sessions.operationFrame(id: accepted.operationId, feed: feed, principal: writer)
        let text = String(decoding: frame, as: UTF8.self)
        #expect(text.hasPrefix("id:\nevent: operation.updated\n"))
        #expect(!text.contains("sequence") && !text.contains("streamEpoch") && !text.contains(writer.id.uuidString) && !text.contains(key))
        #expect(try await journal.snapshot(ref: ref).eventCursor == baseline.eventCursor)
        await #expect(throws: RemoteOperationError.notFound) {try await sessions.operationFrame(id: accepted.operationId, feed: otherFeed, principal: other)}
        await #expect(throws: RemoteOperationError.notFound) {try await sessions.operationFrame(id: accepted.operationId, feed: feed, principal: reader)}
        await access.revoke(writer)
        await #expect(throws: RemoteAccessError.unauthorized) {try await sessions.operationFrame(id: accepted.operationId, feed: feed, principal: writer)}
        await sessions.close(feed); await sessions.close(otherFeed); await sessions.close(readFeed)
        await operations.shutdown()
    }

    @Test func observationRequiresWriteScopeAndEveryReceiptStillRequiresCurrentIdentity() async throws {
        let url = try location(); defer {try? FileManager.default.removeItem(at: url.deletingLastPathComponent())}
        let store = try RemoteOperationStore(databaseURL: url), access = RemoteAccessStore(), gate = OperationIdentityGate()
        await access.setDevelopmentEnabled(true)
        let writer = try await credential(access, actions: [.readHistory, .interrupt]).principal
        let reader = try await credential(access, actions: [.readHistory]).principal
        let service = RemoteOperationService(serverId: ref.serverId, access: access, store: store) {_ in try await gate.resolve()}
        _ = try await service.register(ref: ref, executionEpoch: "execution", actions: [.interrupt], adapter: OperationServiceAdapter())
        await #expect(throws: RemoteAccessError.forbidden) {try await service.observe(ref: ref, principal: reader)}
        let other = RemoteSessionRef(serverId: "other", agentId: ref.agentId, runtimeId: ref.runtimeId, sessionId: ref.sessionId)
        await #expect(throws: RemoteAccessError.forbidden) {try await service.observe(ref: other, principal: writer)}
        let observation = try await service.observe(ref: ref, principal: writer)
        var stream = observation.changes.makeAsyncIterator()
        let accepted = try await store.accept(owner: owner, key: key, request: request) {}
        #expect(try await stream.next() == accepted.operationId)
        let response = try await service.operation(id: accepted.operationId, query: [:], principal: writer)
        #expect(String(decoding: response, as: UTF8.self).contains("accepted"))
        // Membership/identity may change between a hint and the SSE frame.
        await gate.configure(denied: true)
        await #expect(throws: RemoteAccessError.forbidden) {try await service.operation(id: accepted.operationId, query: [:], principal: writer)}
        await service.shutdown()
        #expect(try await stream.next() == nil)
        await #expect(throws: RemoteReadError.unavailable) {try await service.observe(ref: ref, principal: writer)}
    }

    @Test func sessionCapabilitiesRequirePublishedDispatcherMatchingEpochAndCallerScope() async throws {
        let url = try location(); defer {try? FileManager.default.removeItem(at: url.deletingLastPathComponent())}
        let store = try RemoteOperationStore(databaseURL: url)
        let journal = try RemoteSessionJournal(databaseURL: url.deletingLastPathComponent().appendingPathComponent("journal.sqlite"))
        let access = RemoteAccessStore()
        await access.setDevelopmentEnabled(true)
        let controlPrincipal = try await credential(access, actions: [.readHistory, .interrupt]).principal
        let readPrincipal = try await credential(access, actions: [.readHistory]).principal
        let operations = RemoteOperationService(serverId: ref.serverId, access: access, store: store) {_ in owner}
        let sessions = RemoteSessionService(serverId: ref.serverId)
        func projection(_ epoch: String) -> RemoteSessionProjection {
            .init(control: .init(executionEpoch: epoch, controlRevision: 1, state: "running", controlMode: "live",
                currentTurnId: "public-turn", allowedActions: ["history.read", "turn.interrupt", "message.send"]),
                messages: [], pendingRequests: [], olderHistoryCursor: nil, hasOlder: false)
        }
        _ = try await journal.replace(ref: ref, projection: projection("execution"))
        let lease = try await sessions.register(ref: ref, journal: journal)
        func sync(_ principal: RemoteAccessStore.Principal) async throws -> RemoteSessionControl {
            let data = try await sessions.sync(sessionId: ref.sessionId, query: [:], principal: principal)
            return try JSONDecoder().decode(RemoteSessionControl.self, from: data)
        }
        #expect(try await sync(controlPrincipal).controlMode == "readOnly")
        _ = try await operations.register(ref: ref, executionEpoch: "execution", actions: [.interrupt], adapter: OperationServiceAdapter())
        #expect(try await sync(controlPrincipal).controlMode == "readOnly")
        await #expect(throws: RemoteReadError.notFound) {try await sessions.publishCommands(sessionId: ref.sessionId, lease: UUID(), service: operations)}
        try await sessions.publishCommands(sessionId: ref.sessionId, lease: lease, service: operations)
        let live = try await sync(controlPrincipal)
        #expect(live.controlMode == "live" && live.allowedActions == ["history.read", "turn.interrupt"])
        #expect(try await sync(readPrincipal).allowedActions == ["history.read"])
        let snapshot = try await journal.snapshot(ref: ref)
        let feed = try await sessions.open(sessionId: ref.sessionId, query: [:], cursor: snapshot.eventCursor, principal: controlPrincipal)
        let changed = RemoteSessionControl(executionEpoch: "execution", controlRevision: 2, state: "running", controlMode: "live",
            currentTurnId: "public-turn", allowedActions: ["history.read", "turn.interrupt", "message.send"])
        _ = try await journal.append(ref: ref, mutation: .control(changed))
        let replay = try await sessions.replay(feed, after: snapshot.eventCursor, principal: controlPrincipal)
        let record = try #require(replay.records.first)
        let liveFrame = try await sessions.frame(record, feed: feed, principal: controlPrincipal)
        let readFrame = try await sessions.frame(record, feed: feed, principal: readPrincipal)
        #expect(String(decoding: liveFrame, as: UTF8.self).contains("turn.interrupt"))
        #expect(!String(decoding: readFrame, as: UTF8.self).contains("turn.interrupt"))
        _ = try await journal.replace(ref: ref, projection: projection("replacement"))
        #expect(try await sync(controlPrincipal).controlMode == "readOnly")
        _ = try await journal.replace(ref: ref, projection: projection("execution"))
        operations.stopAccepting()
        #expect(try await sync(controlPrincipal).controlMode == "readOnly")
        let closedFrame = try await sessions.frame(record, feed: feed, principal: controlPrincipal)
        #expect(!String(decoding: closedFrame, as: UTF8.self).contains("turn.interrupt"))
        await sessions.close(feed)
        await operations.shutdown()
    }
    private let ref = RemoteSessionRef(serverId: "server", agentId: "agent.chatgpt", runtimeId: "runtime", sessionId: "session")
    private let owner = RemoteOperationOwner(userId: "verified-user", deviceId: "verified-device")
    private let key = "service-key-12345678"
    private var request: RemoteOperationRequest {
        .init(ref: ref, executionEpoch: "execution", action: .interrupt, body: .object(["turnId": .string("public-turn")]))
    }
    private var body: Data {get throws {
        try JSONEncoder().encode(AgentJSON.object(["executionEpoch": .string("execution"), "turnId": .string("public-turn")]))
    }}
    private func location() throws -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("operation-service-" + UUID().uuidString).appendingPathComponent("operations.sqlite")
    }
    private func wait(_ condition: @escaping @Sendable () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if try await condition() {return}
            try await Task.sleep(for: .milliseconds(5))
        }
        throw AgentRPCError.timedOut
    }
    private func credential(_ access: RemoteAccessStore, actions: Set<RemoteAction> = [.interrupt]) async throws -> RemoteAccessStore.Issued {
        try await access.issueDevelopment(scopes: [.init(agentId: ref.agentId, runtimeId: ref.runtimeId, sessionId: ref.sessionId, actions: actions)], origin: nil)
    }

    @Test func restartRetrySchedulesDurableAcceptanceAndQueriesRequireActionScope() async throws {
        let url = try location(); defer {try? FileManager.default.removeItem(at: url.deletingLastPathComponent())}
        let oldStore = try RemoteOperationStore(databaseURL: url)
        let original = try await oldStore.accept(owner: owner, key: key, request: request) {}
        let store = try RemoteOperationStore(databaseURL: url), access = RemoteAccessStore(), adapter = OperationServiceAdapter()
        await access.setDevelopmentEnabled(true)
        let issued = try await credential(access), readOnly = try await credential(access, actions: [.readHistory])
        let service = RemoteOperationService(serverId: ref.serverId, access: access, store: store) { _ in owner }
        _ = try await service.register(ref: ref, executionEpoch: "execution", actions: [.interrupt], adapter: adapter)
        let recovered = try await service.submit(sessionId: ref.sessionId, query: [:], action: .interrupt, key: key, body: body, principal: issued.principal)
        #expect(recovered.operationId == original.operationId)
        try await wait {try await store.operation(id: original.operationId, owner: owner, ref: ref).state == .applied}
        let result = try await service.operation(id: original.operationId, query: [:], principal: issued.principal)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(RemoteOperation.self, from: result).state == .applied)
        await #expect(throws: RemoteAccessError.forbidden) {try await service.operation(id: original.operationId, query: [:], principal: readOnly.principal)}
        await #expect(throws: RemoteAccessError.forbidden) {try await service.byKey(sessionId: ref.sessionId, key: key, query: [:], principal: readOnly.principal)}
        await #expect(throws: RemoteAccessError.forbidden) {try await service.operation(id: original.operationId, query: ["agent_id": ref.agentId, "runtime_id": "foreign"], principal: issued.principal)}
        let retry = try await service.submit(sessionId: ref.sessionId, query: [:], action: .interrupt, key: key, body: body, principal: issued.principal)
        #expect(retry.operationId == original.operationId && retry.state == .applied)
        #expect(await adapter.applications == 1)
        let unsupported = try await credential(access, actions: [.sendMessage])
        await #expect(throws: RemoteCommandError.unsupportedAction) {try await service.submit(sessionId: ref.sessionId, query: [:], action: .sendMessage,
            key: "unsupported-key-123456", body: body, principal: unsupported.principal)}
        await service.shutdown()
    }

    @Test func membershipVerifierDenialPrecedesDedupeQueriesAndInvalidBody() async throws {
        let url = try location(); defer {try? FileManager.default.removeItem(at: url.deletingLastPathComponent())}
        let store = try RemoteOperationStore(databaseURL: url), access = RemoteAccessStore(), gate = OperationIdentityGate(), adapter = OperationServiceAdapter()
        await access.setDevelopmentEnabled(true)
        let issued = try await credential(access)
        let original = try await store.accept(owner: owner, key: key, request: request) {}
        let service = RemoteOperationService(serverId: ref.serverId, access: access, store: store) {_ in try await gate.resolve()}
        _ = try await service.register(ref: ref, executionEpoch: "execution", actions: [.interrupt], adapter: adapter)
        await gate.configure(denied: true)
        await #expect(throws: RemoteAccessError.forbidden) {try await service.submit(sessionId: ref.sessionId, query: [:], action: .interrupt,
            key: key, body: Data("bad json".utf8), principal: issued.principal)}
        await #expect(throws: RemoteAccessError.forbidden) {try await service.operation(id: original.operationId, query: [:], principal: issued.principal)}
        await #expect(throws: RemoteAccessError.forbidden) {try await service.byKey(sessionId: ref.sessionId, key: key, query: [:], principal: issued.principal)}
        #expect(await adapter.applications == 0)
        await service.shutdown()
    }

    @Test func revocationDuringIdentityLookupCannotAcceptOrDispatch() async throws {
        let url = try location(); defer {try? FileManager.default.removeItem(at: url.deletingLastPathComponent())}
        let store = try RemoteOperationStore(databaseURL: url), access = RemoteAccessStore(), gate = OperationIdentityGate(), adapter = OperationServiceAdapter()
        await access.setDevelopmentEnabled(true)
        let issued = try await credential(access)
        let service = RemoteOperationService(serverId: ref.serverId, access: access, store: store) {_ in try await gate.resolve()}
        _ = try await service.register(ref: ref, executionEpoch: "execution", actions: [.interrupt], adapter: adapter)
        await gate.configure(pause: true)
        let pending = Task {try await service.submit(sessionId: ref.sessionId, query: [:], action: .interrupt, key: key, body: body, principal: issued.principal)}
        try await wait {await gate.paused}
        await access.revoke(issued.principal); await gate.release()
        await #expect(throws: RemoteAccessError.unauthorized) {try await pending.value}
        await #expect(throws: RemoteOperationError.notFound) {try await store.byKey(owner: owner, ref: ref, key: key)}
        #expect(await adapter.applications == 0)
        await service.shutdown()
    }

    @Test func synchronousShutdownGateStopsSuspendedAdmissionBeforeAsyncCleanup() async throws {
        let url = try location(); defer {try? FileManager.default.removeItem(at: url.deletingLastPathComponent())}
        let store = try RemoteOperationStore(databaseURL: url), access = RemoteAccessStore(), gate = OperationIdentityGate(), adapter = OperationServiceAdapter()
        await access.setDevelopmentEnabled(true)
        let issued = try await credential(access)
        let service = RemoteOperationService(serverId: ref.serverId, access: access, store: store) {_ in try await gate.resolve()}
        _ = try await service.register(ref: ref, executionEpoch: "execution", actions: [.interrupt], adapter: adapter)
        await gate.configure(pause: true)
        let pending = Task {try await service.submit(sessionId: ref.sessionId, query: [:], action: .interrupt, key: key, body: body, principal: issued.principal)}
        try await wait {await gate.paused}
        service.stopAccepting(); await gate.release()
        await #expect(throws: RemoteReadError.unavailable) {try await pending.value}
        await #expect(throws: RemoteOperationError.notFound) {try await store.byKey(owner: owner, ref: ref, key: key)}
        #expect(await adapter.applications == 0)
        await service.shutdown()
    }
}
