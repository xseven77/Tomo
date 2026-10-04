import Foundation
import CryptoKit
import Security
import JWTKit

/// RFC 9449 proof checks; not an authorization decision or a replacement for TLS.
actor RemoteDPoPVerifier {
    struct Claims: JWTPayload {
        let jti: String
        let htm: String
        let htu: String
        let iat: Int
        let ath: String
        let nonce: String
        func verify(using algorithm: some JWTAlgorithm) async throws {
            guard iat > 0, !jti.isEmpty, jti.utf8.count <= 128, !jti.contains(where: { $0.isWhitespace }),
                  htu.utf8.count <= 2048, htm.utf8.count <= 16,
                  RemoteJWTCodec.base64URL(ath)?.count == 32,
                  RemoteJWTCodec.base64URL(nonce)?.count == 32 else { throw RemoteAccessError.unauthorized }
        }
    }
    private struct Nonce: Sendable { let thumbprint: String; let expiresAt: Date }
    private var nonces: [String: Nonce] = [:]
    private var replay: [String: Date] = [:]

    func challenge(thumbprint: String, expiresAt: Date, now: Date = Date()) throws -> String {
        guard RemoteJWTCodec.base64URL(thumbprint)?.count == 32, now.timeIntervalSince1970.isFinite, expiresAt > now else {
            throw RemoteAccessError.invalidConfiguration
        }
        prune(now)
        guard nonces.count < 1024 else { throw RemoteAccessError.unavailable }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw RemoteAccessError.unavailable }
        let value = Self.encode(Data(bytes))
        nonces[Self.digest(value)] = Nonce(thumbprint: thumbprint, expiresAt: min(expiresAt, now.addingTimeInterval(60)))
        return value
    }

    /// This resource-server profile always requires ath bound to the presented token.
    /// HTTP integration must reject duplicate DPoP headers before calling this method.
    func verify(_ proof: String, thumbprint: String, token: String, method: String, url: URL,
                now: Date = Date()) async throws {
        guard now.timeIntervalSince1970.isFinite, proof.utf8.count <= 8192,
              !token.isEmpty, token.utf8.count <= 32768, token.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }),
              method.range(of: "^[A-Z]{1,16}$", options: .regularExpression) != nil,
              let target = Self.targetURI(url, allowQuery: true) else { throw RemoteAccessError.unauthorized }
        let started = ContinuousClock.now
        prune(now)
        do {
            let parts = proof.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3, parts.allSatisfy({ RemoteJWTCodec.base64URL(String($0)) != nil }),
                  let headerData = RemoteJWTCodec.base64URL(String(parts[0])),
                  let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
                  Set(header.keys) == ["alg", "typ", "jwk"], header["alg"] as? String == "ES256", header["typ"] as? String == "dpop+jwt",
                  let key = header["jwk"] as? [String: String], Set(key.keys).isSubset(of: ["kty", "crv", "x", "y", "kid", "alg", "use"]),
                  key["kty"] == "EC", key["crv"] == "P-256", let x = key["x"], let y = key["y"],
                  RemoteJWTCodec.base64URL(x)?.count == 32, RemoteJWTCodec.base64URL(y)?.count == 32,
                  key["alg"].map({ $0 == "ES256" }) ?? true, key["use"].map({ $0 == "sig" }) ?? true,
                  key["kid"].map({ $0.utf8.count <= 80 }) ?? true else { throw RemoteAccessError.unauthorized }
            let canonical: [String: String] = ["crv": "P-256", "kty": "EC", "x": x, "y": y]
            let data = try JSONSerialization.data(withJSONObject: canonical, options: [.sortedKeys, .withoutEscapingSlashes])
            guard Self.encode(Data(SHA256.hash(data: data))) == thumbprint else { throw RemoteAccessError.unauthorized }
            let keys = JWTKeyCollection()
            let jwk = canonical.merging(["alg": "ES256", "use": "sig", "kid": "device"]) { _, value in value }
            try await keys.add(jwksJSON: String(decoding: JSONSerialization.data(withJSONObject: ["keys": [jwk]]), as: UTF8.self))
            let claims = try await keys.verify(proof, as: Claims.self)
            let elapsed = started.duration(to: .now).components
            let checkedAt = now.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
            guard abs(Double(claims.iat) - checkedAt.timeIntervalSince1970) <= 30,
                  claims.htm == method, let claimURL = URL(string: claims.htu),
                  Self.targetURI(claimURL, allowQuery: false) == target,
                  claims.ath == Self.digest(token),
                  let nonce = nonces[Self.digest(claims.nonce)], nonce.thumbprint == thumbprint, nonce.expiresAt > checkedAt else {
                throw RemoteAccessError.unauthorized
            }
            // Recheck after suspension: two concurrently verified copies cannot both pass.
            prune(checkedAt)
            let replayKey = Self.digest(thumbprint + "\n" + claims.jti)
            guard replay[replayKey] == nil else { throw RemoteAccessError.unauthorized }
            guard replay.count < 4096 else { throw RemoteAccessError.unavailable }
            replay[replayKey] = checkedAt.addingTimeInterval(60)
        } catch RemoteAccessError.unavailable { throw RemoteAccessError.unavailable }
        catch { throw RemoteAccessError.unauthorized }
    }
    func revoke(thumbprint: String) {
        nonces = nonces.filter { $0.value.thumbprint != thumbprint }
        // Keep recent replay identifiers until expiry, including on revocation.
    }
    private func prune(_ now: Date) {
        nonces = nonces.filter { $0.value.expiresAt > now }
        replay = replay.filter { $0.value > now }
    }
    private static func targetURI(_ url: URL, allowQuery: Bool) -> String? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              allowQuery || (parts.query == nil && parts.fragment == nil) else { return nil }
        parts.scheme = "https"; parts.host = host.lowercased()
        parts.query = nil; parts.fragment = nil
        if parts.port == 443 { parts.port = nil }
        if parts.path.isEmpty { parts.path = "/" }
        return parts.url?.absoluteString
    }
    private static func digest(_ text: String) -> String { encode(Data(SHA256.hash(data: Data(text.utf8)))) }
    private static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
