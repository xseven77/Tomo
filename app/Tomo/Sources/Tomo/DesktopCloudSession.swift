import Foundation
import CryptoKit
import Security

enum DesktopCloudError: Error, Equatable {
    case invalidConfiguration, invalidRequest, invalidResponse, storageUnavailable, signedOut, busy, staleResponse
    case rejected(String)
}

protocol DesktopCloudStorage: Sendable {
    func load() throws -> Data?
    func save(_ value: Data?) throws
}

struct KeychainDesktopCloudStorage: DesktopCloudStorage {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.qiizo.tomo.cloud",
         kSecAttrAccount as String: "owner_session_v1", kSecAttrSynchronizable as String: false]
    }
    func load() throws -> Data? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = TomoKeychain.copyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw DesktopCloudError.storageUnavailable }
        return data
    }
    func save(_ data: Data?) throws {
        guard let data else {
            let status = TomoKeychain.delete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw DesktopCloudError.storageUnavailable }
            return
        }
        let status = TomoKeychain.update(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw DesktopCloudError.storageUnavailable }
        var q = query; q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard TomoKeychain.add(q as CFDictionary, nil) == errSecSuccess else { throw DesktopCloudError.storageUnavailable }
    }
}

struct DesktopCloudReply: Sendable {
    let status: Int, body: Data
    let contentType: String
    let headers: [String: String]
    init(status: Int, body: Data, contentType: String, headers: [String: String] = [:]) {
        self.status = status; self.body = body; self.contentType = contentType; self.headers = headers
    }
}
protocol DesktopCloudHTTP: Sendable {
    func send(_ request: URLRequest) async throws -> DesktopCloudReply
}
private final class DesktopCloudRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
struct DesktopCloudURLSession: DesktopCloudHTTP {
    func send(_ request: URLRequest) async throws -> DesktopCloudReply {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: DesktopCloudRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.url == request.url else { throw DesktopCloudError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 65536 else { throw DesktopCloudError.invalidResponse }; data.append(byte)
        }
        return .init(status: response.statusCode, body: data, contentType: response.value(forHTTPHeaderField: "Content-Type") ?? "",
            headers: ["cache-control": response.value(forHTTPHeaderField: "Cache-Control") ?? "",
                      "age": response.value(forHTTPHeaderField: "Age") ?? "0"])
    }
}

/// One trusted issuer, owned exclusively by native desktop Settings/lifecycle.
actor DesktopCloudSession {
    struct Summary: Sendable, Equatable { let sessionId: UUID, userId: UUID; let expiresAt: Date }
    struct RegisteredServer: Sendable, Equatable {
        let id: UUID, userId: UUID, sessionId: UUID
        let name: String, keyThumbprint: String
        let verifiedAt: Date
    }
    private struct Credential: Codable {
        let issuer: String, accessToken: String, refreshToken: String
        let sessionId: UUID, userId: UUID
        let accessExpiresAt: Date, sessionExpiresAt: Date
        var summary: Summary { .init(sessionId: sessionId, userId: userId, expiresAt: sessionExpiresAt) }
    }
    private struct Challenge { let id: UUID, verifier: String; let expiresAt: Date }
    private let endpoint: URL, storage: any DesktopCloudStorage, http: any DesktopCloudHTTP
    private let identity: RemoteServerIdentity
    private let clock: @Sendable () -> Date
    private var credential: Credential?, challenge: Challenge?, registered: RegisteredServer?
    private var generation: UInt64 = 0, inFlight: UInt64?

    init(endpoint: URL, storage: any DesktopCloudStorage = KeychainDesktopCloudStorage(),
         http: any DesktopCloudHTTP = DesktopCloudURLSession(), identity: RemoteServerIdentity = RemoteServerIdentity(),
         clock: @escaping @Sendable () -> Date = { Date() }) throws {
        guard let c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false), c.scheme == "https",
              c.host?.isEmpty == false, c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.path.isEmpty || c.path == "/", (1...65535).contains(c.port ?? 443) else { throw DesktopCloudError.invalidConfiguration }
        self.endpoint = endpoint; self.storage = storage; self.http = http; self.identity = identity; self.clock = clock
        if let data = try storage.load() {
            guard let saved = try? JSONDecoder().decode(Credential.self, from: data), saved.issuer == endpoint.absoluteString,
                  Self.token(saved.accessToken, "tomo_a_"), Self.token(saved.refreshToken, "tomo_r_"),
                  saved.accessExpiresAt <= saved.sessionExpiresAt, saved.sessionExpiresAt > clock() else { try storage.save(nil); return }
            credential = saved
        }
    }
    func summary() -> Summary? { guard let credential, credential.sessionExpiresAt > clock() else { return nil }; return credential.summary }
    func trustedIssuer() -> URL { endpoint }
    func registeredServer() -> RegisteredServer? {
        guard let active = credential, active.sessionExpiresAt > clock(), active.accessExpiresAt > clock(),
              registered?.sessionId == active.sessionId else { return nil }; return registered
    }
    func beginLogin(email: String) async throws {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.utf8.count <= 254, email.contains("@"), !email.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw DesktopCloudError.invalidRequest }
        let lease = try admit(); defer { release(lease) }; challenge = nil
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw DesktopCloudError.invalidRequest }
        let verifier = Self.encoded(Data(bytes))
        let result = try await request("auth/challenges", body: ["email": email,
            "codeChallenge": Self.encoded(Data(SHA256.hash(data: Data(verifier.utf8))))], status: 202)
        try live(lease)
        guard Set(result.keys) == ["challengeId", "expiresAt"], let id = Self.uuid(result["challengeId"]),
              let expiry = Self.date(result["expiresAt"]), expiry > clock(), expiry <= clock().addingTimeInterval(601) else { throw DesktopCloudError.invalidResponse }
        challenge = .init(id: id, verifier: verifier, expiresAt: expiry)
    }
    func completeLogin(code: String) async throws -> Summary {
        guard code.range(of: "^[0-9]{6}$", options: .regularExpression) != nil,
              let challenge, challenge.expiresAt > clock() else { throw DesktopCloudError.invalidRequest }
        let lease = try admit(); defer { release(lease) }; self.challenge = nil
        let result = try await request("auth/exchange", body: ["challengeId": challenge.id.uuidString.lowercased(),
            "code": code, "codeVerifier": challenge.verifier], status: 200)
        let next = try decode(result)
        try await install(next, lease: lease)
        return next.summary
    }
    func currentSession() async throws -> Summary? {
        guard let previous = credential else { return nil }
        if previous.sessionExpiresAt <= clock() { try clear(); return nil }
        if previous.accessExpiresAt > clock().addingTimeInterval(30) { return previous.summary }
        let lease = try admit(); defer { release(lease) }; try clear()
        let result = try await request("auth/refresh", body: ["refreshToken": previous.refreshToken], status: 200)
        let next = try decode(result)
        guard next.sessionId == previous.sessionId, next.userId == previous.userId,
              next.sessionExpiresAt == previous.sessionExpiresAt, next.accessToken != previous.accessToken,
              next.refreshToken != previous.refreshToken else { throw DesktopCloudError.invalidResponse }
        try await install(next, lease: lease); return next.summary
    }
    func registerServer(name: String) async throws -> RegisteredServer {
        guard !name.isEmpty, name == name.trimmingCharacters(in: .whitespacesAndNewlines), name.count <= 80,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw DesktopCloudError.invalidRequest }
        guard try await currentSession() != nil, let active = credential else { throw DesktopCloudError.signedOut }
        let lease = try admit(); defer { release(lease) }
        do {
            let challenge = try await request("servers/registration-challenges", body: [:], status: 201, token: active.accessToken)
            try live(lease, active: active)
            guard Set(challenge.keys) == ["challengeId", "expiresAt", "algorithm", "signingInput"],
                  let id = Self.uuid(challenge["challengeId"]), let expiry = Self.date(challenge["expiresAt"]),
                  let algorithm = challenge["algorithm"] as? String, let input = challenge["signingInput"] as? String else { throw DesktopCloudError.invalidResponse }
            let proof = try await identity.registrationProof(signingInput: input, challengeId: id.uuidString.lowercased(),
                sessionId: active.sessionId.uuidString.lowercased(), algorithm: algorithm, expiresAt: expiry, now: clock())
            try live(lease, active: active)
            guard expiry > clock() else { throw DesktopCloudError.invalidResponse }
            let value = try await request("servers", body: ["challengeId": id.uuidString.lowercased(), "name": name,
                "publicKeyPem": proof.publicKeyPem, "signature": proof.signature], status: 201, token: active.accessToken)
            try live(lease, active: active)
            guard Set(value.keys) == ["serverId", "name", "keyThumbprint", "verifiedAt", "revokedAt"],
                  let serverId = Self.uuid(value["serverId"]), value["name"] as? String == name,
                  value["keyThumbprint"] as? String == proof.keyThumbprint, value["revokedAt"] is NSNull,
                  let verified = Self.date(value["verifiedAt"]), verified > clock().addingTimeInterval(-301),
                  verified <= clock().addingTimeInterval(30) else { throw DesktopCloudError.invalidResponse }
            let result = RegisteredServer(id: serverId, userId: active.userId, sessionId: active.sessionId,
                name: name, keyThumbprint: proof.keyThumbprint, verifiedAt: verified)
            registered = result; return result
        } catch DesktopCloudError.rejected(let code) {
            try live(lease)
            if ["session_revoked", "auth_required", "access_expired"].contains(code) { try clear() }
            throw DesktopCloudError.rejected(code)
        }
    }
    func logout() async throws {
        let previous = credential; generation &+= 1; challenge = nil
        do { try clear() }
        catch {
            if let previous, previous.accessExpiresAt > clock() {
                _ = try? await request("auth/logout", body: [:], status: 204, token: previous.accessToken)
            }
            throw error
        }
        if let previous, previous.accessExpiresAt > clock() {
            _ = try await request("auth/logout", body: [:], status: 204, token: previous.accessToken)
        }
    }
    private func install(_ next: Credential, lease: UInt64) async throws {
        do { try live(lease) } catch {
            _ = try? await request("auth/logout", body: [:], status: 204, token: next.accessToken); throw error
        }
        do { try storage.save(JSONEncoder().encode(next)) }
        catch {
            _ = try? await request("auth/logout", body: [:], status: 204, token: next.accessToken)
            throw error
        }
        credential = next; registered = nil
    }
    private func clear() throws { credential = nil; registered = nil; try storage.save(nil) }
    private func admit() throws -> UInt64 {
        guard inFlight == nil else { throw DesktopCloudError.busy }
        generation &+= 1; inFlight = generation; return generation
    }
    private func release(_ lease: UInt64) { if inFlight == lease { inFlight = nil } }
    private func live(_ lease: UInt64, active: Credential? = nil) throws {
        try Task.checkCancellation()
        guard generation == lease, inFlight == lease else { throw DesktopCloudError.staleResponse }
        if let active {
            guard credential?.sessionId == active.sessionId, credential?.userId == active.userId,
                  active.accessExpiresAt > clock(), active.sessionExpiresAt > clock() else { throw DesktopCloudError.signedOut }
        }
    }
    private func request(_ path: String, body: [String: Any], status: Int, token: String? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint.appendingPathComponent("api/v1/" + path), timeoutInterval: 30)
        request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Accept"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let reply = try await http.send(request)
        guard reply.body.count <= 65536 else { throw DesktopCloudError.invalidResponse }
        if status == 204, reply.status == 204, reply.body.isEmpty { return [:] }
        guard reply.contentType.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json",
              let value = try? JSONSerialization.jsonObject(with: reply.body) as? [String: Any] else { throw DesktopCloudError.invalidResponse }
        guard reply.status == status else {
            guard let code = value["code"] as? String, code.range(of: "^[a-z_]{1,64}$", options: .regularExpression) != nil else { throw DesktopCloudError.invalidResponse }
            throw DesktopCloudError.rejected(code)
        }; return value
    }
    private func decode(_ value: [String: Any]) throws -> Credential {
        guard Set(value.keys) == ["tokenType", "userId", "sessionId", "accessToken", "refreshToken", "accessExpiresAt", "sessionExpiresAt"],
              value["tokenType"] as? String == "Bearer", let user = Self.uuid(value["userId"]), let session = Self.uuid(value["sessionId"]),
              let access = value["accessToken"] as? String, Self.token(access, "tomo_a_"),
              let refresh = value["refreshToken"] as? String, Self.token(refresh, "tomo_r_"),
              let accessExpiry = Self.date(value["accessExpiresAt"]), let expiry = Self.date(value["sessionExpiresAt"]),
              accessExpiry > clock(), accessExpiry <= clock().addingTimeInterval(901), accessExpiry <= expiry,
              expiry > clock(), expiry <= clock().addingTimeInterval(31 * 86400) else { throw DesktopCloudError.invalidResponse }
        return .init(issuer: endpoint.absoluteString, accessToken: access, refreshToken: refresh,
            sessionId: session, userId: user, accessExpiresAt: accessExpiry, sessionExpiresAt: expiry)
    }
    private static func token(_ value: String, _ prefix: String) -> Bool { value.range(of: "^" + prefix + "[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil }
    private static func uuid(_ value: Any?) -> UUID? { (value as? String).flatMap(UUID.init(uuidString:)) }
    private static func date(_ value: Any?) -> Date? { (value as? String).flatMap { ISO8601DateFormatter().date(from: $0) } }
    private static func encoded(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
