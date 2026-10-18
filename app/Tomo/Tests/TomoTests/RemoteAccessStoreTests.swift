import Foundation
import Testing
@testable import Tomo

struct RemoteAccessStoreTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var scope: RemoteAccessStore.Scope {
        .init(agentId: "agent.chatgpt", runtimeId: "runtime.personal", sessionId: nil,
              actions: [.listSessions, .readHistory])
    }

    @Test func disabledByDefaultAndLegacyCredentialsRejected() async throws {
        let store = RemoteAccessStore()
        await #expect(throws: RemoteAccessError.unavailable) {
            try await store.issueDevelopment(scopes: [scope], origin: nil, now: now)
        }
        await store.setDevelopmentEnabled(true)
        await #expect(throws: RemoteAccessError.unauthorized) {
            try await store.authenticate(authorization: "Bearer old-pairing-token", origin: nil, now: now)
        }
    }

    @Test func browserOriginAndResourceScopeAreExact() async throws {
        let store = RemoteAccessStore()
        await store.setDevelopmentEnabled(true)
        let issued = try await store.issueDevelopment(scopes: [scope], origin: "http://localhost:5198", now: now)
        let principal = try await store.authenticate(authorization: "Bearer " + issued.token,
            origin: "http://localhost:5198", now: now)
        #expect(principal.permits(agentId: "agent.chatgpt", runtimeId: "runtime.personal", sessionId: "session.one", action: .readHistory))
        #expect(!principal.permits(agentId: "agent.chatgpt", runtimeId: "runtime.work", sessionId: "session.one", action: .readHistory))
        #expect(!principal.permits(agentId: "agent.new", runtimeId: "runtime.personal", sessionId: "session.one", action: .readHistory))
        #expect(!principal.permits(agentId: "agent.chatgpt", runtimeId: "runtime.personal", sessionId: "session.one", action: .sendMessage))
        for origin in [nil, "http://127.0.0.1:5198", "http://localhost:5199", "http://localhost:5198.evil.test"] as [String?] {
            await #expect(throws: RemoteAccessError.forbidden) {
                try await store.authenticate(authorization: "Bearer " + issued.token, origin: origin, now: now)
            }
        }
    }

    @Test func expiryRevocationAndSwitchInvalidateCapturedPrincipals() async throws {
        let store = RemoteAccessStore()
        await store.setDevelopmentEnabled(true)
        let issued = try await store.issueDevelopment(scopes: [scope], origin: nil, now: now)
        try await store.validate(issued.principal, now: now.addingTimeInterval(299))
        await #expect(throws: RemoteAccessError.unauthorized) {
            try await store.validate(issued.principal, now: now.addingTimeInterval(300))
        }
        await store.revoke(issued.principal)
        await #expect(throws: RemoteAccessError.unauthorized) {
            try await store.validate(issued.principal, now: now)
        }
        let another = try await store.issueDevelopment(scopes: [scope], origin: nil, now: now)
        await store.setDevelopmentEnabled(false)
        await store.setDevelopmentEnabled(true)
        await #expect(throws: RemoteAccessError.unauthorized) {
            try await store.authenticate(authorization: "Bearer " + another.token, origin: nil, now: now)
        }
    }

    @Test func sessionScopeNeverAllowsListingOtherSessionsAndMalformedConfigFails() async throws {
        let store = RemoteAccessStore()
        await store.setDevelopmentEnabled(true)
        let limited = RemoteAccessStore.Scope(agentId: "agent.chatgpt", runtimeId: "runtime.personal", sessionId: "session.one", actions: [.readHistory])
        let issued = try await store.issueDevelopment(scopes: [limited], origin: nil, now: now)
        #expect(issued.principal.permits(agentId: limited.agentId, runtimeId: limited.runtimeId, sessionId: "session.one", action: .readHistory))
        #expect(!issued.principal.permits(agentId: limited.agentId, runtimeId: limited.runtimeId, sessionId: nil, action: .readHistory))
        for origin in ["null", "http://localhost:5198/", "http://user:pass@localhost:5198", "http://localhost:5198?token=x"] {
            await #expect(throws: RemoteAccessError.invalidConfiguration) {
                try await store.issueDevelopment(scopes: [scope], origin: origin, now: now)
            }
        }
        await #expect(throws: RemoteAccessError.invalidConfiguration) {
            try await store.issueDevelopment(scopes: [scope], origin: nil, lifetime: 301, now: now)
        }
    }
}
