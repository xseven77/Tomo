import Foundation

/// The listener selects its grant authority at startup. A request cannot choose
/// a different issuer or inject verification keys.
protocol RemoteGrantVerifier: Sendable {
    func verify(_ token: String, now: Date) async throws -> RemoteCloudGrantVerifier.Claims
}

extension RemoteCloudGrantVerifier: RemoteGrantVerifier {}

protocol RemoteBindingIdentityVerifier: Sendable {
    func verifyBindingIdentity(_ token: String, now: Date) async throws -> RemoteCloudGrantVerifier.BindingIdentity
}
extension RemoteCloudGrantVerifier: RemoteBindingIdentityVerifier {}
