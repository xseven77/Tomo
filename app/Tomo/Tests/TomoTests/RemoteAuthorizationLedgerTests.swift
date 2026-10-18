import XCTest
@testable import Tomo

@MainActor
final class RemoteAuthorizationLedgerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let server = "11111111-1111-4111-8111-111111111111"
    private let user = "22222222-2222-4222-8222-222222222222"
    private let device = "33333333-3333-4333-8333-333333333333"
    private let cloudBinding = "44444444-4444-4444-8444-444444444444"
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("remote-ledger-\(UUID().uuidString)/ledger.sqlite")
    }
    private func claims(_ changes: [String: Any] = [:]) throws -> RemoteCloudGrantVerifier.Claims {
        let values: [String: Any] = ["iss": "https://accounts.example.test", "aud": server, "sub": user,
            "deviceId": device, "cnf": ["jkt": String(repeating: "A", count: 43)], "bindingId": cloudBinding,
            "bindingRevision": 1, "entitlementVersion": 0, "scope": "discovery session.read",
            "resources": [["kind": "runtime", "agentId": "chatgpt", "runtimeId": "runtime-1"]],
            "iat": 1_800_000_000, "nbf": 1_800_000_000, "exp": 1_800_000_300,
            "jti": "55555555-5555-4555-8555-555555555555"]
        return try JSONDecoder().decode(RemoteCloudGrantVerifier.Claims.self,
            from: JSONSerialization.data(withJSONObject: values.merging(changes) { _, new in new }))
    }
    private func binding(revision: Int = 1, deviceId: String? = nil) throws -> RemoteAuthorizationLedger.Binding {
        .init(userId: user, deviceId: deviceId ?? device, thumbprint: String(repeating: "A", count: 43),
            bindingRevision: revision, cloudBindingId: nil, localVersion: 0,
            scopes: ["discovery", "session.read"], resources: try claims().resources, revoked: false)
    }
    private func denied(_ work: () async throws -> Void, error expected: RemoteAccessError = .unauthorized) async {
        do { try await work(); XCTFail("Unexpected authorization") }
        catch { XCTAssertEqual(error as? RemoteAccessError, expected) }
    }
    func testReceiptSurvivesRestartAndRetryDoesNotExtendExpiry() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try RemoteAuthorizationLedger(databaseURL: url, serverId: server)
        _ = try await first.approve(binding(), expectedLocalVersion: 0)
        let receipt = try await first.consume(claims(), now: now)
        let reopened = try RemoteAuthorizationLedger(databaseURL: url, serverId: server)
        let retry = try await reopened.consume(claims(), now: now.addingTimeInterval(10))
        XCTAssertEqual(receipt, retry)
        XCTAssertEqual(receipt.expiresAt, now.addingTimeInterval(300))
        try await reopened.validate(receipt, now: now.addingTimeInterval(11))
        await denied { try await reopened.validate(receipt, now: self.now.addingTimeInterval(300)) }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(try RemoteAuthorizationLedger(databaseURL: url, serverId: UUID().uuidString))
        try await reopened.validate(receipt, now: now.addingTimeInterval(12))
    }
    func testRevocationPersistsAndRequiresNewCloudRevisionToReapprove() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = try RemoteAuthorizationLedger(databaseURL: url, serverId: server)
        _ = try await ledger.approve(binding(), expectedLocalVersion: 0)
        let receipt = try await ledger.consume(claims(), now: now)
        let revoked = try await ledger.revoke(userId: user, deviceId: device, expectedLocalVersion: 1)
        XCTAssertEqual(revoked.localVersion, 2)
        let reopened = try RemoteAuthorizationLedger(databaseURL: url, serverId: server)
        await denied { try await reopened.validate(receipt, now: self.now) }
        await denied { _ = try await reopened.consume(self.claims(), now: self.now) }
        await denied({ _ = try await reopened.approve(self.binding(), expectedLocalVersion: 2) }, error: .forbidden)
        let approved = try await reopened.approve(binding(revision: 2), expectedLocalVersion: 2)
        XCTAssertEqual(approved.localVersion, 3)
        await denied { _ = try await reopened.consume(self.claims(), now: self.now) }
        let updated = try await reopened.consume(claims(["bindingRevision": 2, "jti": UUID().uuidString]), now: now)
        try await reopened.validate(updated, now: now)
    }
    func testLocalEditInvalidatesOldReceiptAndKeepsPinnedCloudBinding() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = try RemoteAuthorizationLedger(databaseURL: url, serverId: server)
        _ = try await ledger.approve(binding(), expectedLocalVersion: 0)
        let receipt = try await ledger.consume(claims(), now: now)
        let edited = try await ledger.approve(binding(), expectedLocalVersion: 1)
        XCTAssertEqual(edited.cloudBindingId, cloudBinding)
        await denied { try await ledger.validate(receipt, now: self.now) }
        await denied { _ = try await ledger.consume(self.claims(), now: self.now) }
        await denied { _ = try await ledger.consume(self.claims(["bindingId": UUID().uuidString, "jti": UUID().uuidString]), now: self.now) }
        let new = try await ledger.consume(claims(["jti": UUID().uuidString]), now: now)
        XCTAssertEqual(new.localVersion, 2)
        await denied({ _ = try await ledger.approve(self.binding(), expectedLocalVersion: 1) }, error: .forbidden)
    }
    func testIdentityScopeAndResourceCannotExpand() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = try RemoteAuthorizationLedger(databaseURL: url, serverId: server)
        _ = try await ledger.approve(binding(), expectedLocalVersion: 0)
        for change: [String: Any] in [["aud": UUID().uuidString], ["sub": UUID().uuidString],
            ["deviceId": UUID().uuidString], ["cnf": ["jkt": String(repeating: "B", count: 43)]], ["bindingRevision": 2]] {
            await denied { _ = try await ledger.consume(self.claims(change), now: self.now) }
        }
        for change: [String: Any] in [["scope": "session.write"], ["scope": "session.read session.read"],
            ["resources": [["kind": "runtime", "agentId": "chatgpt", "runtimeId": "runtime-2"]]], ["resources": []]] {
            await denied({ _ = try await ledger.consume(self.claims(change), now: self.now) }, error: .forbidden)
        }
        let identity = try await ledger.consume(claims(["scope": "server.identity", "resources": []]), now: now)
        XCTAssertEqual(identity.scopes, ["server.identity"])
        await denied { _ = try await ledger.consume(self.claims(), now: self.now) }
    }
    func testCapacityPreservesLiveReceiptsAndClockCannotGoBackwards() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = try RemoteAuthorizationLedger(databaseURL: url, serverId: server, maximumReceipts: 1)
        _ = try await ledger.approve(binding(), expectedLocalVersion: 0)
        let receipt = try await ledger.consume(claims(), now: now)
        await denied({ _ = try await ledger.consume(self.claims(["jti": UUID().uuidString]), now: self.now) }, error: .unavailable)
        try await ledger.validate(receipt, now: now.addingTimeInterval(10))
        let reopened = try RemoteAuthorizationLedger(databaseURL: url, serverId: server, maximumReceipts: 1)
        await denied { _ = try await reopened.consume(self.claims(), now: self.now) }
        let later = now.addingTimeInterval(301)
        let new = try await reopened.consume(claims(["iat": 1_800_000_301, "nbf": 1_800_000_301,
            "exp": 1_800_000_601, "jti": UUID().uuidString]), now: later)
        try await reopened.validate(new, now: later)
        await denied { try await reopened.validate(receipt, now: self.now.addingTimeInterval(20)) }
    }
    func testConcurrentSeparateActorsConsumeExactlyOnce() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let one = try RemoteAuthorizationLedger(databaseURL: url, serverId: server)
        let two = try RemoteAuthorizationLedger(databaseURL: url, serverId: server)
        _ = try await one.approve(binding(), expectedLocalVersion: 0)
        let payload = try claims(), date = now
        let receipts = try await withThrowingTaskGroup(of: RemoteAuthorizationLedger.Receipt.self) { group in
            for index in 0..<8 { group.addTask { try await (index.isMultiple(of: 2) ? one : two).consume(payload, now: date) } }
            var result: [RemoteAuthorizationLedger.Receipt] = []
            for try await receipt in group { result.append(receipt) }
            return result
        }
        XCTAssertEqual(receipts.count, 8)
        XCTAssertEqual(Set(receipts.map(\.accessId)).count, 1)
    }
    func testLiveClockChecksRemainValidAcrossConcurrentActors() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let one = try RemoteAuthorizationLedger(databaseURL: url, serverId: server)
        let two = try RemoteAuthorizationLedger(databaseURL: url, serverId: server)
        _ = try await one.approve(binding(), expectedLocalVersion: 0)
        let seconds = Int(Date().timeIntervalSince1970) - 1
        let payload = try claims(["iat": seconds, "nbf": seconds, "exp": seconds + 300])
        let receipt = try await one.consume(payload)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<128 {
                group.addTask {
                    let ledger = index.isMultiple(of: 2) ? one : two
                    _ = try await ledger.consume(payload)
                    try await ledger.validate(receipt)
                }
            }
            try await group.waitForAll()
        }
        // Explicit injection still rejects rollback; live checks sample after
        // actor and SQLite waits rather than at the caller's request start.
        await denied { try await one.validate(receipt, now: Date(timeIntervalSince1970: Double(seconds))) }
        try await two.validate(receipt)
        _ = try await one.revoke(userId: user, deviceId: device, expectedLocalVersion: 1)
        await denied { try await two.validate(receipt) }
    }
    func testRevokedBindingCountsTowardsBoundedCapacity() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = try RemoteAuthorizationLedger(databaseURL: url, serverId: server, maximumBindings: 1)
        _ = try await ledger.approve(binding(), expectedLocalVersion: 0)
        _ = try await ledger.revoke(userId: user, deviceId: device, expectedLocalVersion: 1)
        await denied({ _ = try await ledger.approve(self.binding(deviceId: UUID().uuidString), expectedLocalVersion: 0) }, error: .unavailable)
        _ = try await ledger.approve(binding(revision: 2), expectedLocalVersion: 2)
    }
    func testRevokedAccessCannotBeExchangedAgainAfterRestart() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = try RemoteAuthorizationLedger(databaseURL: url, serverId: server)
        _ = try await ledger.approve(binding(), expectedLocalVersion: 0)
        let receipt = try await ledger.consume(claims(), now: now)
        try await ledger.revokeReceipt(receipt)
        try await ledger.revokeReceipt(receipt)
        let reopened = try RemoteAuthorizationLedger(databaseURL: url, serverId: server)
        await denied { try await reopened.validate(receipt, now: self.now.addingTimeInterval(1)) }
        await denied { _ = try await reopened.consume(self.claims(), now: self.now.addingTimeInterval(1)) }
        // Revoking one access preserves the device binding for a fresh cloud grant.
        _ = try await reopened.consume(claims(["jti": UUID().uuidString]), now: now.addingTimeInterval(1))
    }
}
