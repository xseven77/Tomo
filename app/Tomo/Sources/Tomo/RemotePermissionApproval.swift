import Foundation

/// Complete, finite permission impact. These are reviewable scopes, never a
/// mobile-selected RPC body. Optional values retain the protocol's unspecified
/// semantics; in particular network.enabled=nil must not become false.
struct RemoteSpecialPermissionPath: Codable, Equatable, Sendable {
    let kind: String
    let path: String?
    let subpath: String?
    var valid: Bool {
        switch kind {
        case "root", "minimal", "tmpdir", "slash_tmp": return path == nil && subpath == nil
        case "project_roots": return path == nil && (subpath.map { permissionText($0, empty: true) } ?? true)
        case "unknown": return path.map { permissionText($0) } == true && (subpath.map { permissionText($0, empty: true) } ?? true)
        default: return false
        }
    }
}

struct RemotePermissionPath: Codable, Equatable, Sendable {
    let type: String
    let path: String?
    let pattern: String?
    let value: RemoteSpecialPermissionPath?
    var valid: Bool {
        switch type {
        case "path": return path.map { permissionText($0) } == true && pattern == nil && value == nil
        case "glob_pattern": return pattern.map { permissionText($0) } == true && path == nil && value == nil
        case "special": return value?.valid == true && path == nil && pattern == nil
        default: return false
        }
    }
}

struct RemoteFilePermissionEntry: Codable, Equatable, Sendable {
    let access: String
    let path: RemotePermissionPath
    var valid: Bool { ["read", "write", "deny"].contains(access) && path.valid }
}

struct RemoteFileSystemPermissions: Codable, Equatable, Sendable {
    let entries: [RemoteFilePermissionEntry]?
    let globScanMaxDepth: Int?
    let read: [String]?
    let write: [String]?
    var valid: Bool {
        (entries?.count ?? 0) + (read?.count ?? 0) + (write?.count ?? 0) <= 128
            && (entries?.allSatisfy(\.valid) ?? true)
            && (read?.allSatisfy { permissionText($0) } ?? true) && (write?.allSatisfy { permissionText($0) } ?? true)
            && (globScanMaxDepth.map { (1..<9_007_199_254_740_991).contains($0) } ?? true)
    }
}
struct RemoteNetworkPermissions: Codable, Equatable, Sendable { let enabled: Bool? }
struct RemotePermissionProfile: Codable, Equatable, Sendable {
    let fileSystem: RemoteFileSystemPermissions?
    let network: RemoteNetworkPermissions?
    var valid: Bool { fileSystem?.valid ?? true }
    var hasUnknownRange: Bool {
        fileSystem?.entries?.contains { $0.path.value?.kind == "unknown" } ?? false
    }
}
struct RemotePermissionApproval: Codable, Equatable, Sendable {
    let cwd: String
    let environmentId: String?
    let reason: String?
    let permissions: RemotePermissionProfile
    var valid: Bool {
        permissionText(cwd) && (environmentId.map { permissionText($0, limit: 256) } ?? true)
            && (reason.map { permissionText($0, empty: true, limit: 16_384) } ?? true) && permissions.valid
            && ((try? JSONEncoder().encode(self).count) ?? Int.max) <= 512 * 1024
    }

    /// Validate every raw field before Codable decoding, including otherwise
    /// ignored keys. Never drop an unknown scope and approve the remaining part.
    static func profile(_ raw: AgentJSON) throws -> RemotePermissionProfile {
        func object(_ raw: AgentJSON, allowed: Set<String>, required: Set<String> = []) throws -> [String: AgentJSON] {
            guard case .object(let fields) = raw, Set(fields.keys).isSubset(of: allowed), required.isSubset(of: Set(fields.keys)) else {
                throw ChatGPTServerRequestError.invalidRequest
            }
            return fields
        }
        func present(_ value: AgentJSON?) -> AgentJSON? { value == .null ? nil : value }
        let fields = try object(raw, allowed: ["fileSystem", "network"])
        if let network = present(fields["network"]) { _ = try object(network, allowed: ["enabled"]) }
        if let filesystem = present(fields["fileSystem"]) {
            let fs = try object(filesystem, allowed: ["entries", "globScanMaxDepth", "read", "write"])
            if let entries = present(fs["entries"]) {
                guard case .array(let values) = entries, values.count <= 128 else { throw ChatGPTServerRequestError.invalidRequest }
                for rawEntry in values {
                    let entry = try object(rawEntry, allowed: ["access", "path"], required: ["access", "path"])
                    guard let rawPath = entry["path"], case .object(let path) = rawPath, case .string(let type) = path["type"] else {
                        throw ChatGPTServerRequestError.invalidRequest
                    }
                    switch type {
                    case "path": _ = try object(rawPath, allowed: ["type", "path"], required: ["type", "path"])
                    case "glob_pattern": _ = try object(rawPath, allowed: ["type", "pattern"], required: ["type", "pattern"])
                    case "special":
                        _ = try object(rawPath, allowed: ["type", "value"], required: ["type", "value"])
                        guard let special = path["value"], case .object(let scope) = special, case .string(let kind) = scope["kind"] else {
                            throw ChatGPTServerRequestError.invalidRequest
                        }
                        switch kind {
                        case "root", "minimal", "tmpdir", "slash_tmp": _ = try object(special, allowed: ["kind"], required: ["kind"])
                        case "project_roots": _ = try object(special, allowed: ["kind", "subpath"], required: ["kind"])
                        case "unknown": _ = try object(special, allowed: ["kind", "path", "subpath"], required: ["kind", "path"])
                        default: throw ChatGPTServerRequestError.unsupported
                        }
                    default: throw ChatGPTServerRequestError.unsupported
                    }
                }
            }
        }
        let data = try JSONEncoder().encode(raw)
        guard data.count <= 512 * 1024 else { throw ChatGPTServerRequestError.invalidRequest }
        let result: RemotePermissionProfile
        do { result = try JSONDecoder().decode(RemotePermissionProfile.self, from: data) }
        catch { throw ChatGPTServerRequestError.invalidRequest }
        guard result.valid else { throw ChatGPTServerRequestError.invalidRequest }
        return result
    }
}

private func permissionText(_ value: String, empty: Bool = false, limit: Int = 4096) -> Bool {
    (empty || !value.isEmpty) && value.utf8.count <= limit && !value.contains("\0")
}
