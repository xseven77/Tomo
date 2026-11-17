import Foundation
import Testing
@testable import Tomo

/// The phone's server card shows how many agents and sessions a desktop has; only a paired caller may see them.
struct HealthCountsTests {
    @Test func countsAreAbsentUntilAnAgentRegistersAndSkipArchivedSessions() async throws {
        let reads = RemoteReadService(serverId: "srv_test", sessionService: RemoteSessionService(serverId: "srv_test"))
        #expect(await reads.overviewCounts() == nil)
        try await reads.register(RemoteReadServiceTests.ArchivedAdapter())
        let counts = try #require(await reads.overviewCounts())
        #expect(counts.agents == 1 && counts.sessions == 2)
    }

    @Test func healthCarriesCountsOnlyForThePairingToken() async throws {
        let server = MobileSyncServer(port: 0, token: "pairing", listenOnLoopbackOnly: true, dataProvider: MobileSyncServerTests.MockDataProvider())
        defer { server.stop() }
        try await server.remoteReadService.register(RemoteReadServiceTests.ArchivedAdapter())
        try server.start()
        let port = try await waitForPort(server)
        let open = try await health(port, token: nil)
        #expect(open["status"] as? String == "ok" && open["agentCount"] == nil && open["sessionCount"] == nil)
        let wrong = try await health(port, token: "other")
        #expect(wrong["agentCount"] == nil && wrong["sessionCount"] == nil)
        let paired = try await health(port, token: "pairing")
        #expect(paired["agentCount"] as? Int == 1 && paired["sessionCount"] as? Int == 2)
    }

    private func waitForPort(_ server: MobileSyncServer) async throws -> UInt16 {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if let port = server.listeningPort { return port }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AgentRPCError.timedOut
    }

    private func health(_ port: UInt16, token: String?) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        request.timeoutInterval = 5
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
