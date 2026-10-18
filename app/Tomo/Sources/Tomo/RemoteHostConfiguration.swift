import Foundation

/// Public connection information only; copying never issues a grant or approval.
enum RemoteHostConfiguration {
    struct Runtime: Sendable { let agentId: String, runtimeId: String }
    static func encode(serverId: UUID, name: String, endpoint: URL, scopes: [String], runtimes: [Runtime],
                       localIdentity: RemoteLocalGrantAuthority.Identity? = nil) throws -> String {
        guard RemoteEndpoint.valid(endpoint),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.unicodeScalars.count <= 80,
              !name.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }),
              !scopes.isEmpty, Set(scopes).count == scopes.count,
              Set(scopes).isSubset(of: ["discovery", "session.read", "session.write", "session.approve"]),
              !runtimes.isEmpty, runtimes.count <= 128,
              Set(runtimes.map { $0.agentId + ":" + $0.runtimeId }).count == runtimes.count,
              runtimes.allSatisfy({ $0.agentId.range(of: "^[a-z][a-z0-9._-]{0,127}$", options: .regularExpression) != nil &&
                $0.runtimeId.range(of: "^[A-Za-z0-9_-]{1,160}$", options: .regularExpression) != nil }) else { throw CocoaError(.coderInvalidValue) }
        var host: [String: Any] = ["id": serverId.uuidString.lowercased(), "name": name,
            "endpoint": endpoint.absoluteString, "scopes": scopes.sorted(),
            "resources": runtimes.map { ["kind": "runtime", "agentId": $0.agentId, "runtimeId": $0.runtimeId] }]
        if let localIdentity {
            guard localIdentity.serverId == serverId else { throw CocoaError(.coderInvalidValue) }
            host["authorization"] = ["kind": "local", "publicKeyPem": localIdentity.publicKeyPem]
        }
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "hosts": [host]], options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        guard data.count <= 128 * 1024 else { throw CocoaError(.coderInvalidValue) }
        return String(decoding: data, as: UTF8.self)
    }
}
