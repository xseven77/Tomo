import XCTest
import CryptoKit
@testable import Tomo

private final class ServerIdentityMemory: RemoteServerIdentityStorage, @unchecked Sendable {
    private let lock = NSLock()
    var data: Data?
    var unavailable = false
    var insertions = 0
    var competingWinner: Data?
    func load() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if unavailable { throw RemoteServerIdentityError.storageUnavailable }; return data
    }
    func insertIfAbsent(_ candidate: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if unavailable { throw RemoteServerIdentityError.storageUnavailable }
        if let competingWinner { data = competingWinner; self.competingWinner = nil; return false }
        guard data == nil else { return false }; data = candidate; insertions += 1; return true
    }
}

final class RemoteServerIdentityTests: XCTestCase {
    let challenge = "11111111-1111-4111-8111-111111111111"
    let session = "22222222-2222-4222-8222-222222222222"
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    var input: String { "TomoServer/server-registration/v1\n\(challenge)\n\(session)\n" + String(repeating: "A", count: 43) }

    func testRestartAndCompetingCreatorsKeepSameIdentity() async throws {
        let storage = ServerIdentityMemory()
        let first = try await RemoteServerIdentity(storage: storage).publicIdentity()
        let restarted = try await RemoteServerIdentity(storage: storage).publicIdentity()
        XCTAssertEqual(first, restarted); XCTAssertEqual(storage.insertions, 1)
        let race = ServerIdentityMemory(), winner = P256.Signing.PrivateKey()
        race.competingWinner = Data([1]) + winner.rawRepresentation
        let result = try await RemoteServerIdentity(storage: race).publicIdentity()
        XCTAssertEqual(result.keyThumbprint, try RemoteBindingApproval.thumbprint(winner.publicKey))
        XCTAssertEqual(race.insertions, 0)
    }

    func testDERProofVerifiesExactServerChallenge() async throws {
        let identity = RemoteServerIdentity(storage: ServerIdentityMemory())
        let proof = try await identity.registrationProof(signingInput: input, challengeId: challenge,
            sessionId: session, algorithm: "ES256", expiresAt: now.addingTimeInterval(300), now: now)
        let key = try P256.Signing.PublicKey(pemRepresentation: proof.publicKeyPem)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: XCTUnwrap(Data(base64Encoded: proof.signature)))
        XCTAssertTrue(key.isValidSignature(signature, for: Data(input.utf8)))
        XCTAssertFalse(key.isValidSignature(signature, for: Data((input + "changed").utf8)))
        XCTAssertEqual(proof.keyThumbprint, try RemoteBindingApproval.thumbprint(key))
        // Optional public-only interop fixture. Never includes private key bytes.
        if let path = ProcessInfo.processInfo.environment["TOMO_SERVER_IDENTITY_INTEROP_OUTPUT"] {
            let payload: [String: Any] = ["signingInput": input, "publicKeyPem": proof.publicKeyPem,
                "signature": proof.signature, "keyThumbprint": proof.keyThumbprint]
            try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
    }

    func testCorruptAndUnavailableStorageNeverReplaced() async throws {
        for data in [Data(), Data([2]) + Data(repeating: 1, count: 32), Data([1, 0])] {
            let storage = ServerIdentityMemory(); storage.data = data
            do { _ = try await RemoteServerIdentity(storage: storage).publicIdentity(); XCTFail("Corruption accepted") }
            catch { XCTAssertEqual(error as? RemoteServerIdentityError, .corruptIdentity) }
            XCTAssertEqual(storage.data, data); XCTAssertEqual(storage.insertions, 0)
        }
        let storage = ServerIdentityMemory(); storage.unavailable = true
        do { _ = try await RemoteServerIdentity(storage: storage).publicIdentity(); XCTFail("Unavailable accepted") }
        catch { XCTAssertEqual(error as? RemoteServerIdentityError, .storageUnavailable) }
        XCTAssertEqual(storage.insertions, 0)
    }

    func testApprovalFactoryRequiresRegisteredPersistentKey() async throws {
        let serverId = "33333333-3333-4333-8333-333333333333"
        let cloudKey = P256.Signing.PrivateKey(), bytes = cloudKey.publicKey.x963Representation
        func encoded(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let jwk = ["kty": "EC", "crv": "P-256", "x": encoded(bytes.subdata(in: 1..<33)),
                   "y": encoded(bytes.subdata(in: 33..<65)), "alg": "ES256", "use": "sig", "kid": "cloud"]
        let cloud = try await RemoteCloudGrantVerifier.configured(jwks: JSONSerialization.data(withJSONObject: ["keys": [jwk]]),
            issuer: "https://cloud.example.test", serverId: serverId, trustedUntil: now.addingTimeInterval(300), now: now)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = try RemoteAuthorizationLedger(databaseURL: directory.appendingPathComponent("ledger.sqlite"), serverId: serverId)
        let storage = ServerIdentityMemory(), signer = RemoteServerIdentity(storage: storage)
        let identity = try await signer.publicIdentity()
        _ = try await RemoteServerIdentity(storage: storage).bindingApproval(cloud: cloud, ledger: ledger,
            serverId: serverId, issuer: "https://cloud.example.test", registeredThumbprint: identity.keyThumbprint)
        do {
            _ = try await signer.bindingApproval(cloud: cloud, ledger: ledger, serverId: serverId,
                issuer: "https://cloud.example.test", registeredThumbprint: RemoteBindingApproval.thumbprint(cloudKey.publicKey))
            XCTFail("Foreign registered key accepted")
        } catch { XCTAssertEqual(error as? RemoteAccessError, .invalidConfiguration) }
        XCTAssertEqual(storage.insertions, 1)
    }

    func testWrongNamespaceSessionNonceAlgorithmAndDeadlineCannotSign() async throws {
        let storage = ServerIdentityMemory(), signer = RemoteServerIdentity(storage: ServerIdentityMemory())
        let invalidInputs = [input.replacingOccurrences(of: "server-registration", with: "device-registration"),
            input.replacingOccurrences(of: session, with: challenge), input + "\n",
            input.dropLast() + "B"]
        for text in invalidInputs {
            do { _ = try await signer.registrationProof(signingInput: String(text), challengeId: challenge,
                sessionId: session, algorithm: "ES256", expiresAt: now.addingTimeInterval(300), now: now); XCTFail("Invalid input signed") }
            catch { XCTAssertEqual(error as? RemoteServerIdentityError, .invalidChallenge) }
        }
        for (algorithm, expiry) in [("RS256", now.addingTimeInterval(300)), ("ES256", now), ("ES256", now.addingTimeInterval(302))] {
            do { _ = try await RemoteServerIdentity(storage: storage).registrationProof(signingInput: input, challengeId: challenge,
                sessionId: session, algorithm: algorithm, expiresAt: expiry, now: now); XCTFail("Invalid deadline/algorithm signed") }
            catch { XCTAssertEqual(error as? RemoteServerIdentityError, .invalidChallenge) }
        }
        XCTAssertEqual(storage.insertions, 0)
    }
}
