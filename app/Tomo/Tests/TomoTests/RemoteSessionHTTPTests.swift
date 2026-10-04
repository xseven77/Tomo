import Foundation
import Testing
@testable import Tomo

struct RemoteSessionHTTPTests {
    @Test func idleClientCancellationReleasesTheFeedWithoutWaitingForHeartbeat() async throws {
        let server = MobileSyncServer(port: 59435, token: "old", listenOnLoopbackOnly: true, dataProvider: MobileSyncServerTests.MockDataProvider())
        defer {server.stop()}
        let url = try location(); defer {try? FileManager.default.removeItem(at: url.deletingLastPathComponent())}
        let journal = try RemoteSessionJournal(databaseURL: url)
        let (_, issued, initial) = try await prepare(server, journal: journal)
        let client = URLSession(configuration: .ephemeral)
        let (_, response) = try await client.bytes(for: request(59435, path: "events", token: issued.token, cursor: initial.eventCursor))
        #expect((response as? HTTPURLResponse)?.statusCode == 200 && server.remoteStreamCount == 1)
        let started = ContinuousClock.now
        client.invalidateAndCancel()
        try await wait {server.remoteStreamCount == 0}
        #expect(started.duration(to: ContinuousClock.now) < .seconds(3))
    }
    private func location() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("remote-http-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("events.sqlite")
    }
    private var baseline: RemoteSessionProjection {
        .init(control: .init(executionEpoch: "process", controlRevision: 1, state: "running", controlMode: "readOnly", currentTurnId: "turn", allowedActions: ["history.read"]),
              messages: [.init(messageId: "message", turnId: "turn", messageRevision: 1, role: "assistant", createdAt: "2026-10-03T00:00:00Z", status: "streaming",
                               content: [.init(partId: "text", type: "text", text: "base")])], pendingRequests: [], olderHistoryCursor: nil, hasOlder: false,
              activities: [.init(activityId: "opaque-activity", turnId: "turn", activityRevision: 1, kind: "command",
                                 status: "running", createdAt: "2026-10-03T00:00:00Z")])
    }
    private func wait(_ condition: @escaping @Sendable () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AgentRPCError.timedOut
    }
    private func request(_ port: UInt16, path: String, token: String, cursor: String? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/remote/sessions/session/\(path)")!)
        request.timeoutInterval = 5
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let cursor { request.setValue(cursor, forHTTPHeaderField: "Last-Event-ID") }
        return request
    }
    private func prepare(_ server: MobileSyncServer, journal: RemoteSessionJournal) async throws -> (RemoteSessionRef, RemoteAccessStore.Issued, RemoteJournalSync) {
        let serverId = await server.remoteSessionService.serverId
        let ref = RemoteSessionRef(serverId: serverId, agentId: "agent.chatgpt", runtimeId: "runtime", sessionId: "session")
        let sync = try await journal.replace(ref: ref, projection: baseline)
        try await server.remoteSessionService.register(ref: ref, journal: journal)
        await server.remoteAccess.setDevelopmentEnabled(true)
        let issued = try await server.remoteAccess.issueDevelopment(scopes: [.init(agentId: ref.agentId, runtimeId: ref.runtimeId, sessionId: ref.sessionId, actions: [.readHistory])], origin: nil)
        try server.start(); try await wait { server.status == .ready }
        return (ref, issued, sync)
    }

    @Test func realHTTPSyncReplayLiveEventsAndRevocationUseIndependentAuthorization() async throws {
        let port: UInt16 = 59430
        let server = MobileSyncServer(port: port, token: "old-pairing", listenOnLoopbackOnly: true, dataProvider: MobileSyncServerTests.MockDataProvider())
        defer { server.stop() }
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = try RemoteSessionJournal(databaseURL: url)
        let (ref, issued, initial) = try await prepare(server, journal: journal)
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let (_, old) = try await session.data(for: request(port, path: "sync", token: "old-pairing"))
        #expect((old as? HTTPURLResponse)?.statusCode == 401)
        let (syncData, syncHTTP) = try await session.data(for: request(port, path: "sync", token: issued.token))
        #expect((syncHTTP as? HTTPURLResponse)?.statusCode == 200)
        let json = try #require(JSONSerialization.jsonObject(with: syncData) as? [String: Any])
        #expect(json["eventCursor"] as? String == initial.eventCursor)
        #expect(json["sequence"] as? Int == 0)
        #expect(json["olderHistoryCursor"] is NSNull)
        let activities = try #require(json["activities"] as? [[String: Any]])
        #expect(activities.count == 1 && activities[0]["kind"] as? String == "command")
        _ = try await journal.append(ref: ref, mutation: .delta(messageId: "message", partId: "text", revision: 2, text: " replay"))
        let (bytes, response) = try await session.bytes(for: request(port, path: "events", token: issued.token, cursor: initial.eventCursor))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == "text/event-stream")
        var count = 0, token = ""
        for try await line in bytes.lines {
            if line.hasPrefix("id: ") { token = String(line.dropFirst(4)) }
            guard line.hasPrefix("data: ") else { continue }
            let event = try JSONDecoder().decode(RemoteJournalEvent.self, from: Data(line.dropFirst(6).utf8))
            #expect(event.sequence == count + 1 && event.streamEpoch == initial.streamEpoch && !token.isEmpty)
            count += 1
            if count == 1 {
                #expect(event.type == "message.delta")
                _ = try await journal.append(ref: ref, mutation: .activity(.init(activityId: "opaque-activity", turnId: "turn",
                    activityRevision: 2, kind: "command", status: "completed", createdAt: "2026-10-03T00:00:00Z")))
            } else if count == 2 {
                #expect(event.type == "activity.updated")
                _ = try await journal.append(ref: ref, mutation: .delta(messageId: "message", partId: "text", revision: 3, text: " live"))
            } else if count == 3 {
                #expect(event.type == "message.delta")
                await server.remoteAccess.revoke(issued.principal)
            } else {
                #expect(event.type == "access.revoked")
                break
            }
        }
        #expect(count == 4)
        try await wait { server.remoteStreamCount == 0 }
        let (_, denied) = try await session.data(for: request(port, path: "sync", token: issued.token))
        #expect((denied as? HTTPURLResponse)?.statusCode == 401)
    }

    @Test func staleAndConflictingCursorsRejectBeforeStreamHeadersAndScopeIsExact() async throws {
        let port: UInt16 = 59431
        let server = MobileSyncServer(port: port, token: "old", listenOnLoopbackOnly: true, dataProvider: MobileSyncServerTests.MockDataProvider())
        defer { server.stop() }
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = try RemoteSessionJournal(databaseURL: url)
        let (ref, issued, initial) = try await prepare(server, journal: journal)
        _ = try await journal.replace(ref: ref, projection: baseline)
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let (_, stale) = try await session.data(for: request(port, path: "events", token: issued.token, cursor: initial.eventCursor))
        #expect((stale as? HTTPURLResponse)?.statusCode == 409)
        var conflict = request(port, path: "events?after=different", token: issued.token, cursor: initial.eventCursor)
        let (_, bad) = try await session.data(for: conflict)
        #expect((bad as? HTTPURLResponse)?.statusCode == 400)
        conflict = request(port, path: "sync?agent_id=agent.chatgpt&runtime_id=other", token: issued.token)
        let (_, forbidden) = try await session.data(for: conflict)
        #expect((forbidden as? HTTPURLResponse)?.statusCode == 403)
        let other = try await server.remoteAccess.issueDevelopment(scopes: [.init(agentId: ref.agentId, runtimeId: ref.runtimeId, sessionId: "other", actions: [.readHistory])], origin: nil)
        let (_, scope) = try await session.data(for: request(port, path: "sync", token: other.token))
        #expect((scope as? HTTPURLResponse)?.statusCode == 403)
        #expect(server.remoteStreamCount == 0)
    }

    @Test func idleStreamCatchesNewEventsAndLogRebuildForcesResync() async throws {
        let port: UInt16 = 59432
        let server = MobileSyncServer(port: port, token: "old", listenOnLoopbackOnly: true, dataProvider: MobileSyncServerTests.MockDataProvider())
        defer { server.stop() }
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = try RemoteSessionJournal(databaseURL: url)
        let (ref, issued, initial) = try await prepare(server, journal: journal)
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request(port, path: "events", token: issued.token, cursor: initial.eventCursor))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        _ = try await journal.append(ref: ref, mutation: .delta(messageId: "message", partId: "text", revision: 2, text: " new"))
        var count = 0
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let event = try JSONDecoder().decode(RemoteJournalEvent.self, from: Data(line.dropFirst(6).utf8))
            count += 1
            if count == 1 {
                #expect(event.type == "message.delta" && event.sequence == 1)
                _ = try await journal.replace(ref: ref, projection: baseline)
            } else { #expect(event.type == "sync.required" && event.sequence == 2); break }
        }
        #expect(count == 2)
        try await wait { server.remoteStreamCount == 0 }
    }

    @Test func idleAuthorizationExpiryClosesStreamAndUnpublishedWriteCapabilitiesStayDisabled() async throws {
        let port: UInt16 = 59433
        let server = MobileSyncServer(port: port, token: "old", listenOnLoopbackOnly: true, dataProvider: MobileSyncServerTests.MockDataProvider())
        defer { server.stop() }
        let url = try location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = try RemoteSessionJournal(databaseURL: url)
        let (ref, issued, _) = try await prepare(server, journal: journal)
        var live = baseline
        live.control = .init(executionEpoch: "process", controlRevision: 2, state: "running", controlMode: "live", currentTurnId: "turn", allowedActions: ["history.read", "message.send"])
        let initial = try await journal.replace(ref: ref, projection: live)
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let (data, _) = try await session.data(for: request(port, path: "sync", token: issued.token))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["controlMode"] as? String == "readOnly")
        #expect(json["allowedActions"] as? [String] == ["history.read"])
        let short = try await server.remoteAccess.issueDevelopment(scopes: issued.principal.scopes, origin: nil, lifetime: 0.5)
        let (bytes, response) = try await session.bytes(for: request(port, path: "events", token: short.token, cursor: initial.eventCursor))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        var received = false
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let event = try JSONDecoder().decode(RemoteJournalEvent.self, from: Data(line.dropFirst(6).utf8))
            #expect(event.type == "access.revoked" && event.sequence == 1)
            received = true; break
        }
        #expect(received)
        try await wait { server.remoteStreamCount == 0 }
    }
}
