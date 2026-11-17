import Foundation
import Testing
@testable import Tomo

@Suite("MobileConnectionKeyLabelTests")
@MainActor
struct MobileConnectionKeyLabelTests {
    private func deepSeek(keyLabel: String?) -> DeepSeekAPIConnection {
        DeepSeekAPIConnection(
            id: ConnectionID(rawValue: UUID()),
            label: "DeepSeek Key 1",
            credentialHandle: "ds",
            keySuffix: "4c2a",
            keyLabel: keyLabel,
            authenticationState: .connected,
            createdAt: Date()
        )
    }

    private func openCode(keyLabel: String?) -> OpenCodeAPIConnection {
        OpenCodeAPIConnection(
            id: ConnectionID(rawValue: UUID()),
            label: "OpenCode Go Key 1",
            plan: .go,
            credentialHandle: "go",
            keySuffix: "4b1c",
            keyLabel: keyLabel,
            authenticationState: .connected,
            createdAt: Date()
        )
    }

    private func json(_ payload: MobileConnectionPayload) throws -> [String: Any] {
        let data = try JSONEncoder().encode(payload)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("DeepSeek payload carries keyLabel when the alias is set")
    func deepSeekWithAlias() throws {
        let object = try json(MobileSyncManager.connectionPayload(for: deepSeek(keyLabel: "DSH")))
        #expect(object["keyLabel"] as? String == "DSH")
        #expect(object["keySuffix"] as? String == "4c2a")
    }

    @Test("DeepSeek payload omits keyLabel when no alias is set")
    func deepSeekWithoutAlias() throws {
        let object = try json(MobileSyncManager.connectionPayload(for: deepSeek(keyLabel: nil)))
        #expect(object["keyLabel"] == nil)
        #expect(object["keySuffix"] as? String == "4c2a")
    }

    @Test("OpenCode payload carries keyLabel when the alias is set")
    func openCodeWithAlias() throws {
        let object = try json(MobileSyncManager.connectionPayload(for: openCode(keyLabel: "Workspace")))
        #expect(object["keyLabel"] as? String == "Workspace")
    }

    @Test("OpenCode payload omits keyLabel when no alias is set")
    func openCodeWithoutAlias() throws {
        let object = try json(MobileSyncManager.connectionPayload(for: openCode(keyLabel: nil)))
        #expect(object["keyLabel"] == nil)
    }

    @Test("Blank aliases normalize to nil and long ones are trimmed")
    func normalization() {
        #expect(MultiAgentSettingsStore.normalizedKeyLabel("  ") == nil)
        #expect(MultiAgentSettingsStore.normalizedKeyLabel(" DSH ") == "DSH")
        #expect(MultiAgentSettingsStore.normalizedKeyLabel(String(repeating: "a", count: 40))?.count == 24)
    }

    @Test("Stored connections without keyLabel still decode")
    func legacyDecode() throws {
        let data = try JSONEncoder().encode(deepSeek(keyLabel: nil))
        let decoded = try JSONDecoder().decode(DeepSeekAPIConnection.self, from: data)
        #expect(decoded.keyLabel == nil)
        let roundTrip = try JSONDecoder().decode(
            DeepSeekAPIConnection.self,
            from: JSONEncoder().encode(deepSeek(keyLabel: "DSH"))
        )
        #expect(roundTrip.keyLabel == "DSH")
    }
}
