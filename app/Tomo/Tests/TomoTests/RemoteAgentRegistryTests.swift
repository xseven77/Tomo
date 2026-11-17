import Foundation
import Testing
@testable import Tomo

struct RemoteAgentRegistryTests {
    private func descriptor(id: String = "agent.new-brand", features: [String] = [],
                            actions: [String] = ["sessions.list", "history.read", "message.send"],
                            icon: String? = "brand.new-brand", api: [Int] = [1]) -> RemoteAgentDescriptor {
        RemoteAgentDescriptor(agentId: id, displayName: "New Brand", adapterId: "tomo.adapter.new-brand",
            adapterVersion: "1.0.0", descriptorSchemaVersion: 1, supportedApiMajors: api,
            supportedEventMajors: [1], supportedContentMajors: [1],
            surfaces: [.init(id: "surface.new-brand-cli", kind: "cli", label: "CLI")],
            brand: .init(iconAssetId: icon, fallbackGlyph: "terminal"), possibleActions: actions,
            inputTypes: ["text"], outputTypes: ["text", "error"], requiredClientFeatures: features,
            discoveryMode: "registered-paths", minRemoteApiVersion: 1)
    }
    private var client: RemoteClientCapabilities {
        .init(descriptorMajors: [1], apiMajors: [1, 2], eventMajors: [1], contentMajors: [1], clientFeatures: [])
    }

    @Test func newBrandAppearsWithoutBuiltinCatalogChanges() async throws {
        let registry = RemoteAgentRegistry()
        try await registry.register(descriptor())
        let catalog = await registry.catalog(client: client, authorizedAgentIDs: ["agent.new-brand"])
        #expect(catalog.catalogRevision == 1)
        #expect(catalog.items.count == 1)
        #expect(catalog.items.first?.descriptor?.brand.iconAssetId == "brand.new-brand")
        #expect(catalog.items.first?.negotiatedProtocol?.apiMajor == 1)
        #expect(catalog.items.first?.status == "registered")
        let hidden = await registry.catalog(client: client, authorizedAgentIDs: [])
        #expect(hidden.items.isEmpty)
    }

    @Test func duplicateRegistrationDoesNotReplaceMetadataOrRevision() async throws {
        let registry = RemoteAgentRegistry()
        try await registry.register(descriptor())
        await #expect(throws: RemoteRegistryError.duplicateAgent("agent.new-brand")) {
            try await registry.register(descriptor(features: ["unknown.feature"]))
        }
        let catalog = await registry.catalog(client: client, authorizedAgentIDs: ["agent.new-brand"])
        #expect(catalog.catalogRevision == 1)
        #expect(catalog.items.first?.status == "registered")
    }

    @Test func incompatibleAdapterDoesNotHideCompatibleAdapterOrExposeFullDescriptor() async throws {
        let registry = RemoteAgentRegistry()
        try await registry.register(descriptor(id: "agent.good"))
        try await registry.register(descriptor(id: "agent.new", features: ["unimplemented.required"]))
        try await registry.register(descriptor(id: "agent.future", api: [2]))
        let catalog = await registry.catalog(client: client, authorizedAgentIDs: ["agent.good", "agent.new", "agent.future"])
        #expect(catalog.items.map(\.agentId) == ["agent.future", "agent.good", "agent.new"])
        #expect(catalog.items[1].status == "registered")
        #expect(catalog.items[0].descriptor == nil)
        #expect(catalog.items[2].descriptor == nil)
        #expect(catalog.items[2].unavailableReason == "protocol_incompatible")
    }

    @Test func malformedBrandIDAndUnknownActionCannotRegister() async throws {
        let registry = RemoteAgentRegistry()
        await #expect(throws: RemoteRegistryError.invalidDescriptor("agent.new-brand")) {
            try await registry.register(descriptor(icon: "https://example.test/icon.svg"))
        }
        await #expect(throws: RemoteRegistryError.invalidDescriptor("agent.new-brand")) {
            try await registry.register(descriptor(actions: ["arbitrary.rpc"]))
        }
        await #expect(throws: RemoteRegistryError.invalidDescriptor("../../other")) {
            try await registry.register(descriptor(id: "../../other"))
        }
        let catalog = await registry.catalog(client: client, authorizedAgentIDs: ["agent.new-brand"])
        #expect(catalog.catalogRevision == 0)
    }

    @Test func actionsRequireAllCapabilityAndPermissionLayers() throws {
        let result = RemoteAgentRegistry.allowedActions(descriptor: descriptor(),
            runtimeActions: ["sessions.list", "history.read", "message.send", "arbitrary.rpc"],
            sessionActions: ["sessions.list", "history.read"], authorizedActions: ["history.read", "message.send"])
        #expect(result == ["history.read"])
        #expect(RemoteAgentRegistry.allowedActions(descriptor: descriptor(), runtimeActions: ["message.send"],
            sessionActions: ["message.send"], authorizedActions: []).isEmpty)
    }

    @Test func unregistrationChangesRevisionOnlyForExistingAdapters() async throws {
        let registry = RemoteAgentRegistry()
        try await registry.register(descriptor())
        await registry.unregister(agentId: "unknown")
        await registry.unregister(agentId: "agent.new-brand")
        let catalog = await registry.catalog(client: client, authorizedAgentIDs: ["agent.new-brand"])
        #expect(catalog.catalogRevision == 2)
        #expect(catalog.items.isEmpty)
    }
}
