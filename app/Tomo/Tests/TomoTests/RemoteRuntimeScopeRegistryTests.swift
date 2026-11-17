import XCTest
@testable import Tomo

@MainActor
final class RemoteRuntimeScopeRegistryTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scope-registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func resource(_ values: [String: String]) throws -> RemoteCloudGrantVerifier.Resource {
        try JSONDecoder().decode(RemoteCloudGrantVerifier.Resource.self, from: JSONSerialization.data(withJSONObject: values))
    }
    private func workspaceResource(_ id: String) throws -> RemoteCloudGrantVerifier.Resource {
        try resource(["kind": "workspace", "workspaceId": id, "agentPolicy": "registered"])
    }
    private func descriptor(_ id: String = "agent.chatgpt") -> RemoteAgentDescriptor {
        .init(agentId: id, displayName: "Registered agent", adapterId: "adapter.test", adapterVersion: "1.0.0",
            descriptorSchemaVersion: 1, supportedApiMajors: [1], supportedEventMajors: [1], supportedContentMajors: [1],
            surfaces: [.init(id: "cli", kind: "cli", label: "CLI")], brand: .init(iconAssetId: nil, fallbackGlyph: "chat"),
            possibleActions: ["sessions.list", "history.read"], inputTypes: [], outputTypes: ["text"],
            requiredClientFeatures: [], discoveryMode: "registered-paths", minRemoteApiVersion: 1)
    }
    func testApprovedWorkspaceAutomaticallyIncludesNewAgentsAndExcludesHostWideRuntime() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = RemoteRuntimeScopeRegistry()
        let workspace = try await registry.registerWorkspace(id: "workspace_one", root: root)
        _ = try await registry.register(descriptor: descriptor(), runtimeId: "runtime_one", workspace: workspace)
        _ = try await registry.register(descriptor: descriptor(), runtimeId: "runtime_host")
        let resource = try workspaceResource(workspace.id)
        let before = try await registry.resolve([resource], actions: [.listSessions, .readHistory, .sendMessage])
        XCTAssertEqual(before.map(\.runtimeId), ["runtime_one"])
        XCTAssertEqual(before.first?.actions, [.listSessions, .readHistory])
        _ = try await registry.register(descriptor: descriptor("agent.new"), runtimeId: "runtime_new", workspace: workspace)
        let after = try await registry.resolve([resource], actions: [.readHistory])
        XCTAssertEqual(Set(after.map(\.agentId)), ["agent.chatgpt", "agent.new"])
        XCTAssertFalse(after.contains { $0.runtimeId == "runtime_host" })
    }
    func testStrictRuntimeCannotExpandAndDuplicateResourcesDeduplicate() async throws {
        let registry = RemoteRuntimeScopeRegistry()
        _ = try await registry.register(descriptor: descriptor(), runtimeId: "runtime_one")
        _ = try await registry.register(descriptor: descriptor("agent.other"), runtimeId: "runtime_two")
        let strict = try resource(["kind": "runtime", "agentId": "agent.chatgpt", "runtimeId": "runtime_one"])
        let scopes = try await registry.resolve([strict, strict], actions: [.readHistory])
        XCTAssertEqual(scopes.count, 1)
        XCTAssertEqual(scopes.first?.agentId, "agent.chatgpt")
        let unknown = try await registry.resolve([workspaceResource("unknown")], actions: [.readHistory])
        XCTAssertTrue(unknown.isEmpty)
        let write = try await registry.resolve([strict], actions: [.sendMessage])
        XCTAssertTrue(write.isEmpty)
    }
    func testStaleLeaseCannotRemoveReplacementRuntime() async throws {
        let registry = RemoteRuntimeScopeRegistry()
        let first = try await registry.register(descriptor: descriptor(), runtimeId: "runtime_one")
        await registry.unregister(agentId: "agent.chatgpt", runtimeId: "runtime_one", lease: first)
        let second = try await registry.register(descriptor: descriptor(), runtimeId: "runtime_one")
        await registry.unregister(agentId: "agent.chatgpt", runtimeId: "runtime_one", lease: first)
        let strict = try resource(["kind": "runtime", "agentId": "agent.chatgpt", "runtimeId": "runtime_one"])
        let present = try await registry.resolve([strict], actions: [.readHistory])
        XCTAssertEqual(present.count, 1)
        await registry.unregister(agentId: "agent.chatgpt", runtimeId: "runtime_one", lease: second)
        let absent = try await registry.resolve([strict], actions: [.readHistory])
        XCTAssertTrue(absent.isEmpty)
    }
    func testWorkspaceRootReplacementAndSymlinkCannotRetainApproval() async throws {
        let container = try root(); defer { try? FileManager.default.removeItem(at: container) }
        let project = container.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let registry = RemoteRuntimeScopeRegistry()
        let workspace = try await registry.registerWorkspace(id: "workspace_one", root: project)
        _ = try await registry.register(descriptor: descriptor(), runtimeId: "runtime_one", workspace: workspace)
        try FileManager.default.moveItem(at: project, to: container.appendingPathComponent("old"))
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        do { _ = try await registry.resolve([workspaceResource(workspace.id)], actions: [.readHistory]); XCTFail("Replaced root accepted") }
        catch { XCTAssertEqual(error as? RemoteAccessError, .unauthorized) }
        do { _ = try await registry.registerWorkspace(id: workspace.id, root: project); XCTFail("Approval silently replaced") }
        catch { XCTAssertEqual(error as? RemoteAccessError, .forbidden) }
        try FileManager.default.removeItem(at: project)
        try FileManager.default.createSymbolicLink(at: project, withDestinationURL: container.appendingPathComponent("old"))
        do { _ = try await registry.resolve([workspaceResource(workspace.id)], actions: [.readHistory]); XCTFail("Changed symlink accepted") }
        catch { XCTAssertEqual(error as? RemoteAccessError, .unauthorized) }
    }
    func testWorkspaceWithdrawalRemovesAssociatedRuntimeAndRejectsOldWorkspaceHandle() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = RemoteRuntimeScopeRegistry()
        let workspace = try await registry.registerWorkspace(id: "workspace_one", root: root)
        _ = try await registry.register(descriptor: descriptor(), runtimeId: "runtime_one", workspace: workspace)
        await registry.unregisterWorkspace(id: workspace.id)
        let scopes = try await registry.resolve([resource(["kind": "runtime", "agentId": "agent.chatgpt", "runtimeId": "runtime_one"])], actions: [.readHistory])
        XCTAssertTrue(scopes.isEmpty)
        do { _ = try await registry.register(descriptor: descriptor(), runtimeId: "runtime_two", workspace: workspace); XCTFail("Old workspace handle accepted") }
        catch { XCTAssertEqual(error as? RemoteAccessError, .forbidden) }
        do { _ = try await registry.registerWorkspace(id: workspace.id, root: root); XCTFail("Retired ID reused") }
        catch { XCTAssertEqual(error as? RemoteAccessError, .forbidden) }
    }
    func testReadServiceRegistrationAndWithdrawalUpdateAuthorizationRegistry() async throws {
        let registry = RemoteRuntimeScopeRegistry(), service = RemoteReadService(serverId: "test", authorizationRegistry: registry)
        try await service.register(RemoteReadServiceTests.Adapter())
        let strict = try resource(["kind": "runtime", "agentId": "agent.chatgpt", "runtimeId": "runtime_test"])
        let scopes = try await registry.resolve([strict], actions: [.readHistory])
        XCTAssertEqual(scopes.count, 1)
        await service.unregister(agentId: "agent.chatgpt", runtimeId: "runtime_test")
        let absent = try await registry.resolve([strict], actions: [.readHistory])
        XCTAssertTrue(absent.isEmpty)
        // Descriptor can be reused after the last runtime has gone away.
        try await service.register(RemoteReadServiceTests.Adapter())
        let restored = try await registry.resolve([strict], actions: [.readHistory])
        XCTAssertEqual(restored.count, 1)
    }
}
