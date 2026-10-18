import Foundation
import Testing
@testable import Tomo

struct CompanionSessionHostTests {
    private final class Provider: MobileSyncDataProvider, @unchecked Sendable {
        let base = MobileSyncServerTests.MockDataProvider()
        let configuration: String?
        private let lock = NSLock()
        private var count = 0
        var reads: Int { lock.withLock { count } }
        init(_ configuration: String?) { self.configuration = configuration }
        func sessionHostConfiguration() async -> String? {
            lock.withLock { count += 1 }; return configuration
        }
        func makeSnapshot() async -> MobileSnapshotPayload { await base.makeSnapshot() }
        func availablePets() -> [MobilePetMetadata] { base.availablePets() }
        func exportCredentials() async -> MobileCredentialsExportPayload { await base.exportCredentials() }
        func getThemeConfig() -> (config: TomoThemeConfig, syncEnabled: Bool) { base.getThemeConfig() }
        func updateThemeConfig(_ config: TomoThemeConfig) async -> (success: Bool, synced: Bool, message: String?) {
            await base.updateThemeConfig(config)
        }
    }

    @Test func pairedDescriptorDoesNotGrantAccessAndRequiresAuthenticationAndGET() async throws {
        let descriptor = try RemoteHostConfiguration.encode(serverId: UUID(), name: "Synthetic desktop",
            endpoint: URL(string: "http://127.0.0.1:58352")!, scopes: ["discovery", "session.read"],
            runtimes: [.init(agentId: "agent.chatgpt", runtimeId: "rt_synthetic")])
        let provider = Provider(descriptor)
        let port = try RemoteTLSFixture.freePort()
        let server = MobileSyncServer(port: port, token: "synthetic-pairing", listenOnLoopbackOnly: true, dataProvider: provider)
        try server.start(); defer { server.stop() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while server.status != .ready, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(server.status == .ready)
        let client = URLSession(configuration: .ephemeral); defer { client.invalidateAndCancel() }
        func request(_ path: String, token: String? = nil, method: String = "GET") async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)" + path)!)
            request.httpMethod = method; request.timeoutInterval = 5
            if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
            let (data, response) = try await client.data(for: request)
            return (data, try #require(response as? HTTPURLResponse))
        }
        let path = "/api/v1/companion/session-host"
        #expect(try await request(path).1.statusCode == 401)
        #expect(try await request(path, token: "wrong").1.statusCode == 401)
        #expect(try await request(path, token: "synthetic-pairing", method: "POST").1.statusCode == 405)
        #expect(provider.reads == 0)
        let (data, response) = try await request(path, token: "synthetic-pairing")
        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["version", "hosts"])
        let hosts = try #require(object["hosts"] as? [[String: Any]])
        #expect(Set(try #require(hosts.first).keys) == ["id", "name", "endpoint", "scopes", "resources"])
        #expect(provider.reads == 1)
        #expect(try await request("/api/v1/remote/catalog", token: "synthetic-pairing").1.statusCode == 401)
    }

    @Test func unavailableDescriptorHasNoSideEffect() async throws {
        let provider = Provider(nil), port = try RemoteTLSFixture.freePort()
        let server = MobileSyncServer(port: port, token: "synthetic-pairing", listenOnLoopbackOnly: true, dataProvider: provider)
        try server.start(); defer { server.stop() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while server.status != .ready, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(server.status == .ready)
        let client = URLSession(configuration: .ephemeral); defer { client.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/companion/session-host")!)
        request.setValue("Bearer synthetic-pairing", forHTTPHeaderField: "Authorization")
        let (data, response) = try await client.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
        let value = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(value == ["error": "session_service_unavailable"])
        #expect(provider.reads == 1)
    }
}
