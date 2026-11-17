import Foundation
import Testing
@testable import Tomo

struct RemoteAccessInfoTests {
    @Test func accessReportsOnlyCurrentPrincipalAndPreservesSessionRestriction() async throws {
        let store = RemoteAccessStore()
        await store.setDevelopmentEnabled(true)
        let grant = try await store.issueDevelopment(scopes: [
            .init(agentId: "agent.chatgpt", runtimeId: "rt_real", sessionId: "ss_exact", actions: [.readHistory]),
            .init(agentId: "agent.other", runtimeId: "rt_other", sessionId: nil, actions: [.listSessions, .sendMessage])
        ], origin: nil)
        let service = RemoteReadService(serverId: "server-exact")
        let data = try await service.response(path: "/api/v1/remote/access", query: [:], principal: grant.principal)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["serverId", "expiresAt", "scopes"])
        #expect(object["serverId"] as? String == "server-exact")
        let scopes = try #require(object["scopes"] as? [[String: Any]])
        #expect(scopes.count == 2)
        #expect(scopes[0]["sessionId"] as? String == "ss_exact")
        #expect(scopes[0]["actions"] as? [String] == ["history.read"])
        #expect(scopes[1]["sessionId"] == nil)
        #expect(!String(decoding: data, as: UTF8.self).contains(grant.token))
        await #expect(throws: RemoteReadError.invalidRequest) {
            try await service.response(path: "/api/v1/remote/access", query: ["server_id": "another"], principal: grant.principal)
        }
        await store.revoke(grant.principal)
        await #expect(throws: RemoteAccessError.unauthorized) {try await store.validate(grant.principal)}
    }
    @Test func expandedWorkspaceIncludesAllInstancesAndEmptyCompatibilityActions() async throws {
        let scopes = (0..<1024).map { RemoteAccessStore.Scope(agentId: "agent.chatgpt", runtimeId: "rt_\($0)", sessionId: nil,
            actions: $0 == 0 ? [] : [.listSessions, .readHistory]) }
        let principal = RemoteAccessStore.Principal(id: UUID(), expiresAt: Date().addingTimeInterval(60), scopes: scopes, origin: nil, generation: 0)
        let data = try await RemoteReadService(serverId: "exact").response(path: "/api/v1/remote/access", query: [:], principal: principal)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try #require(object["scopes"] as? [[String: Any]])
        #expect(result.count == 1024)
        #expect(result[0]["actions"] as? [String] == [])
        #expect(data.count > 64 * 1024 && data.count <= 512 * 1024)
    }

}
