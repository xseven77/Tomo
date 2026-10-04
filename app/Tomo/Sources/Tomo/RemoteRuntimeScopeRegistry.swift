import Foundation
import Darwin

/// Local registration boundary. Neither HTTP parameters nor cloud assertions
/// may register a workspace/runtime or declare its isolation provenance.
actor RemoteRuntimeScopeRegistry {
    struct Workspace: Sendable {
        let id: String
        let root: URL
        fileprivate let device: dev_t
        fileprivate let inode: ino_t
    }
    private struct Runtime {
        let lease: UUID
        let agentId: String
        let runtimeId: String
        let workspaceId: String?
        let actions: Set<RemoteAction>
        let descriptor: RemoteAgentDescriptor
    }
    private var workspaces: [String: Workspace] = [:]
    private var retiredWorkspaceIDs = Set<String>()
    private var runtimes: [String: Runtime] = [:]
    struct OwnerRuntime: Sendable, Identifiable {
        let agentId: String, runtimeId: String, label: String
        let actions: Set<RemoteAction>
        var id: String { agentId + ":" + runtimeId }
        func resource() throws -> RemoteCloudGrantVerifier.Resource {
            try JSONDecoder().decode(RemoteCloudGrantVerifier.Resource.self, from: JSONSerialization.data(withJSONObject:
                ["kind": "runtime", "agentId": agentId, "runtimeId": runtimeId]))
        }
    }
    func ownerRuntimes() throws -> [OwnerRuntime] {
        try runtimes.values.map { runtime in
            if let id = runtime.workspaceId {
                guard let workspace = workspaces[id] else { throw RemoteAccessError.unauthorized }
                try Self.validate(workspace)
            }
            return OwnerRuntime(agentId: runtime.agentId, runtimeId: runtime.runtimeId,
                label: runtime.descriptor.displayName, actions: runtime.actions)
        }.sorted { $0.id < $1.id }
    }

    /// Owner-approved canonical project root. Keep paths local; grants contain only id.
    func registerWorkspace(id: String, root: URL) throws -> Workspace {
        guard Self.validID(id), root.isFileURL else { throw RemoteAccessError.invalidConfiguration }
        guard !retiredWorkspaceIDs.contains(id) else { throw RemoteAccessError.forbidden }
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        let identity = try Self.identity(canonical)
        guard canonical.path != "/" else { throw RemoteAccessError.invalidConfiguration }
        if let previous = workspaces[id] {
            guard previous.root == canonical, previous.device == identity.st_dev, previous.inode == identity.st_ino else {
                throw RemoteAccessError.forbidden
            }
            return previous
        }
        guard workspaces.count + retiredWorkspaceIDs.count < 128 else { throw RemoteAccessError.unavailable }
        let workspace = Workspace(id: id, root: canonical, device: identity.st_dev, inode: identity.st_ino)
        workspaces[id] = workspace
        return workspace
    }
    func unregisterWorkspace(id: String) {
        if workspaces.removeValue(forKey: id) != nil { retiredWorkspaceIDs.insert(id) }
        runtimes = runtimes.filter { $0.value.workspaceId != id }
    }
    /// Pass workspace only for an adapter that guarantees ALL of this runtime's
    /// sessions belong to this isolated project. A host-wide vendor history index
    /// must pass nil even if its database happens to live under a project path.
    @discardableResult
    func register(descriptor: RemoteAgentDescriptor, runtimeId: String, workspace: Workspace? = nil, actions: Set<RemoteAction>? = nil) throws -> UUID {
        try descriptor.validate()
        let possible = Set(descriptor.possibleActions.compactMap(RemoteAction.init(rawValue:)))
        let actions = actions ?? possible
        guard !actions.isEmpty, actions.isSubset(of: possible) else { throw RemoteAccessError.invalidConfiguration }
        guard Self.validID(runtimeId) else { throw RemoteAccessError.invalidConfiguration }
        let key = Self.key(descriptor.agentId, runtimeId)
        guard runtimes[key] == nil else { throw RemoteReadError.duplicateRuntime }
        if let workspace {
            guard let current = workspaces[workspace.id], current.root == workspace.root,
                  current.device == workspace.device, current.inode == workspace.inode else { throw RemoteAccessError.forbidden }
            try Self.validate(current)
        }
        guard runtimes.count < 1024 else { throw RemoteAccessError.unavailable }
        let lease = UUID()
        runtimes[key] = Runtime(lease: lease, agentId: descriptor.agentId, runtimeId: runtimeId,
            workspaceId: workspace?.id, actions: actions, descriptor: descriptor)
        return lease
    }
    func unregister(agentId: String, runtimeId: String, lease: UUID) {
        let key = Self.key(agentId, runtimeId)
        if runtimes[key]?.lease == lease { runtimes.removeValue(forKey: key) }
    }
    /// Current exact resources only. Missing/replaced workspace roots fail closed;
    /// future compatible adapters inherit only explicitly granted registered policy.
    func resolve(_ resources: [RemoteCloudGrantVerifier.Resource], actions: Set<RemoteAction>, client: RemoteClientCapabilities? = nil) throws -> [RemoteAccessStore.Scope] {
        guard resources.count <= 128 else { throw RemoteAccessError.invalidConfiguration }
        var selected = Set<String>()
        for resource in resources {
            switch resource.kind {
            case "runtime":
                guard let agent = resource.agentId, let runtime = resource.runtimeId else { throw RemoteAccessError.invalidConfiguration }
                selected.insert(Self.key(agent, runtime))
            case "workspace":
                guard resource.agentPolicy == "registered", let id = resource.workspaceId else { throw RemoteAccessError.invalidConfiguration }
                guard let workspace = workspaces[id] else { continue }
                try Self.validate(workspace)
                selected.formUnion(runtimes.filter { $0.value.workspaceId == id }.keys)
            default: throw RemoteAccessError.invalidConfiguration
            }
        }
        return try selected.compactMap { key in
            guard let runtime = runtimes[key] else { return nil }
            if let id = runtime.workspaceId {
                guard let workspace = workspaces[id] else { throw RemoteAccessError.unauthorized }
                try Self.validate(workspace)
            }
            let permitted = runtime.actions.intersection(actions)
            guard !permitted.isEmpty else { return nil }
            if let client {
                let descriptor = runtime.descriptor
                let compatible = client.descriptorMajors.contains(descriptor.descriptorSchemaVersion) &&
                    Set(descriptor.requiredClientFeatures).isSubset(of: Set(client.clientFeatures)) &&
                    descriptor.supportedApiMajors.contains(1) && descriptor.supportedEventMajors.contains(1) && descriptor.supportedContentMajors.contains(1)
                if !compatible {
                    return RemoteAccessStore.Scope(agentId: runtime.agentId, runtimeId: runtime.runtimeId, sessionId: nil, actions: [])
                }
            }
            return RemoteAccessStore.Scope(agentId: runtime.agentId, runtimeId: runtime.runtimeId, sessionId: nil, actions: permitted)
        }.sorted { ($0.agentId, $0.runtimeId) < ($1.agentId, $1.runtimeId) }
    }
    private static func key(_ agent: String, _ runtime: String) -> String { agent + "\0" + runtime }
    private static func validID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{1,160}$", options: .regularExpression) != nil
    }
    private static func identity(_ url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw RemoteAccessError.unauthorized }
        return info
    }
    private static func validate(_ workspace: Workspace) throws {
        // Reject ancestor symlink changes as well as replacing the root itself.
        guard workspace.root.resolvingSymlinksInPath().standardizedFileURL == workspace.root else { throw RemoteAccessError.unauthorized }
        let info = try identity(workspace.root)
        guard info.st_dev == workspace.device, info.st_ino == workspace.inode else { throw RemoteAccessError.unauthorized }
    }
}
