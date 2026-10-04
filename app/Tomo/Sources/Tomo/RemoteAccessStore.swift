import Foundation
import CryptoKit
import Security

enum RemoteAccessError: Error, Equatable {
    case invalidConfiguration
    case unavailable
    case unauthorized
    case forbidden
    case protocolIncompatible
}

/// Business streams depend on live authorization, independent of how a native
/// device or a locally authorized development browser obtained its principal.
protocol RemotePrincipalValidator: Sendable {
    func validate(_ principal: RemoteAccessStore.Principal, now: Date) async throws
}
extension RemotePrincipalValidator {
    func validate(_ principal: RemoteAccessStore.Principal) async throws {
        try await validate(principal, now: Date())
    }
}

/// Local owner-issued development credentials. Never accepts the mobile pairing
/// token, URL flags or a client claim of VIP membership. Production grant exchange
/// must be implemented separately before production credentials can be issued.
actor RemoteAccessStore: RemotePrincipalValidator {
    struct Scope: Equatable, Sendable {
        let agentId: String
        let runtimeId: String
        let sessionId: String?
        let actions: Set<RemoteAction>
    }
    struct Principal: Sendable {
        let id: UUID
        let expiresAt: Date
        let scopes: [Scope]
        let origin: String?
        let generation: UInt64
        let clientCapabilities: RemoteClientCapabilities?

        init(id: UUID, expiresAt: Date, scopes: [Scope], origin: String?, generation: UInt64,
             clientCapabilities: RemoteClientCapabilities? = nil) {
            self.id = id; self.expiresAt = expiresAt; self.scopes = scopes; self.origin = origin
            self.generation = generation; self.clientCapabilities = clientCapabilities
        }

        func permits(agentId: String, runtimeId: String, sessionId: String?, action: RemoteAction) -> Bool {
            scopes.contains { scope in
                scope.agentId == agentId && scope.runtimeId == runtimeId && scope.actions.contains(action)
                    && (scope.sessionId == nil || scope.sessionId == sessionId)
            }
        }
    }
    struct Issued: Sendable {
        let token: String
        let principal: Principal
    }
    private var enabled = false
    private var generation: UInt64 = 0
    private var credentials: [String: Principal] = [:]

    /// Called only by local owner settings. Toggling invalidates existing access.
    func setDevelopmentEnabled(_ value: Bool) {
        enabled = value
        generation += 1
        credentials.removeAll()
    }

    func issueDevelopment(scopes: [Scope], origin: String?, lifetime: TimeInterval = 300,
                          now: Date = Date()) throws -> Issued {
        guard enabled else { throw RemoteAccessError.unavailable }
        guard lifetime.isFinite, lifetime > 0, lifetime <= 300,
              !scopes.isEmpty, scopes.count <= 128,
              scopes.allSatisfy({ !$0.agentId.isEmpty && !$0.runtimeId.isEmpty && !$0.actions.isEmpty }),
              origin.map(Self.validOrigin) ?? true else { throw RemoteAccessError.invalidConfiguration }
        credentials = credentials.filter { $0.value.expiresAt > now }
        guard credentials.count < 128 else { throw RemoteAccessError.unavailable }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw RemoteAccessError.unavailable
        }
        let token = "tomo_remote_dev_" + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let principal = Principal(id: UUID(), expiresAt: now.addingTimeInterval(lifetime),
                                  scopes: scopes, origin: origin, generation: generation)
        credentials[Self.digest(token)] = principal
        return Issued(token: token, principal: principal)
    }

    func authenticate(authorization: String?, origin: String?, now: Date = Date()) throws -> Principal {
        guard let authorization, authorization.hasPrefix("Bearer ") else { throw RemoteAccessError.unauthorized }
        let token = String(authorization.dropFirst(7))
        guard !token.isEmpty, !token.contains(where: { $0.isWhitespace }),
              let principal = credentials[Self.digest(token)] else { throw RemoteAccessError.unauthorized }
        guard enabled, principal.generation == generation, principal.expiresAt > now else {
            credentials.removeValue(forKey: Self.digest(token))
            throw RemoteAccessError.unauthorized
        }
        // A browser credential cannot be replayed without its exact bound Origin.
        guard principal.origin == origin else { throw RemoteAccessError.forbidden }
        return principal
    }

    func validate(_ principal: Principal, now: Date = Date()) throws {
        guard enabled, principal.generation == generation, principal.expiresAt > now,
              credentials.values.contains(where: { $0.id == principal.id }) else {
            throw RemoteAccessError.unauthorized
        }
    }

    func revoke(_ principal: Principal) {
        credentials = credentials.filter { $0.value.id != principal.id }
    }

    private static func digest(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func validOrigin(_ value: String) -> Bool {
        guard let parts = URLComponents(string: value), let scheme = parts.scheme,
              ["http", "https"].contains(scheme), parts.host != nil,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty else { return false }
        return parts.url?.absoluteString == value
    }
}
