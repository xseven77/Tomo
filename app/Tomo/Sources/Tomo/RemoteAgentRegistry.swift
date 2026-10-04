import Foundation

/// Wire metadata is supplied by trusted adapters, never by a remote client.
struct RemoteAgentDescriptor: Codable, Equatable, Sendable {
    struct Surface: Codable, Equatable, Sendable {
        let id: String
        let kind: String
        let label: String
    }
    struct Brand: Codable, Equatable, Sendable {
        let iconAssetId: String?
        let fallbackGlyph: String
    }
    let agentId: String
    let displayName: String
    let adapterId: String
    let adapterVersion: String
    let descriptorSchemaVersion: Int
    let supportedApiMajors: [Int]
    let supportedEventMajors: [Int]
    let supportedContentMajors: [Int]
    let surfaces: [Surface]
    let brand: Brand
    let possibleActions: [String]
    let inputTypes: [String]
    let outputTypes: [String]
    let requiredClientFeatures: [String]
    let discoveryMode: String
    let minRemoteApiVersion: Int

    func validate() throws {
        func validID(_ value: String) -> Bool {
            value.count <= 128 && value.range(of: "^[a-z][a-z0-9._-]*$", options: .regularExpression) != nil
        }
        let actions = Set(RemoteAction.allCases.map(\.rawValue))
        let input = Set(["text"])
        let output = Set(["text", "toolSummary", "approval", "question", "error"])
        guard validID(agentId), validID(adapterId), !displayName.isEmpty, displayName.count <= 100,
              adapterVersion.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil,
              descriptorSchemaVersion == 1, minRemoteApiVersion == 1,
              [supportedApiMajors, supportedEventMajors, supportedContentMajors].allSatisfy({
                  !$0.isEmpty && $0.count <= 8 && $0.allSatisfy { $0 > 0 } && Set($0).count == $0.count
              }),
              !surfaces.isEmpty, surfaces.count <= 16, Set(surfaces.map(\.id)).count == surfaces.count,
              surfaces.allSatisfy({ validID($0.id) && ["cli", "desktop", "ide", "web"].contains($0.kind) && !$0.label.isEmpty }),
              brand.iconAssetId.map(validID) ?? true,
              ["terminal", "chat", "sparkles"].contains(brand.fallbackGlyph),
              possibleActions.count <= actions.count, Set(possibleActions).count == possibleActions.count,
              Set(possibleActions).isSubset(of: actions), Set(inputTypes).isSubset(of: input),
              Set(outputTypes).isSubset(of: output), requiredClientFeatures.count <= 32,
              requiredClientFeatures.allSatisfy(validID),
              ["registered-paths", "vendor-api", "local-storage"].contains(discoveryMode)
        else { throw RemoteRegistryError.invalidDescriptor(agentId) }
    }
}

enum RemoteAction: String, CaseIterable, Codable, Sendable {
    case listSessions = "sessions.list"
    case readHistory = "history.read"
    case sendMessage = "message.send"
    case interrupt = "turn.interrupt"
    case resume = "session.resume"
    case approve = "approval.respond"
    case answer = "question.answer"
    case create = "session.create"
    case fork = "session.fork"
}

struct RemoteClientCapabilities: Codable, Equatable, Sendable {
    let descriptorMajors: [Int]
    let apiMajors: [Int]
    let eventMajors: [Int]
    let contentMajors: [Int]
    let clientFeatures: [String]

    static let v1 = Self(descriptorMajors: [1], apiMajors: [1], eventMajors: [1], contentMajors: [1], clientFeatures: [])
    func normalized() throws -> Self {
        guard [descriptorMajors, apiMajors, eventMajors, contentMajors].allSatisfy({
            !$0.isEmpty && $0.count <= 8 && Set($0).count == $0.count && $0.allSatisfy { (1...1000).contains($0) }
        }), clientFeatures.count <= 32, Set(clientFeatures).count == clientFeatures.count,
        clientFeatures.allSatisfy({ $0.range(of: "^[a-z][a-z0-9._-]{0,127}$", options: .regularExpression) != nil }) else {
            throw RemoteReadError.invalidRequest
        }
        return Self(descriptorMajors: descriptorMajors.sorted(), apiMajors: apiMajors.sorted(), eventMajors: eventMajors.sorted(),
            contentMajors: contentMajors.sorted(), clientFeatures: clientFeatures.sorted())
    }
    func negotiatedProtocol() throws -> RemoteNegotiatedProtocol {
        guard apiMajors.contains(1), eventMajors.contains(1), contentMajors.contains(1) else { throw RemoteAccessError.protocolIncompatible }
        return .init(apiMajor: 1, eventMajor: 1, contentMajor: 1)
    }
}

struct RemoteNegotiatedProtocol: Codable, Equatable, Sendable {
    let apiMajor: Int
    let eventMajor: Int
    let contentMajor: Int
}

enum RemoteRegistryError: Error, Equatable {
    case invalidDescriptor(String)
    case duplicateAgent(String)
}

/// This registry owns protocol metadata. Runtime discovery/session adapters and
/// resource authorization consume it; metadata alone never grants an action.
actor RemoteAgentRegistry {
    struct CatalogItem: Codable, Equatable, Sendable {
        let agentId: String
        let displayName: String
        let status: String
        let unavailableReason: String?
        let descriptor: RemoteAgentDescriptor?
        let negotiatedProtocol: RemoteNegotiatedProtocol?
    }
    struct Catalog: Codable, Equatable, Sendable {
        let catalogRevision: UInt64
        let items: [CatalogItem]
    }
    private var descriptors: [String: RemoteAgentDescriptor] = [:]
    private var revision: UInt64 = 0

    func register(_ descriptor: RemoteAgentDescriptor) throws {
        try descriptor.validate()
        guard descriptors[descriptor.agentId] == nil else {
            throw RemoteRegistryError.duplicateAgent(descriptor.agentId)
        }
        descriptors[descriptor.agentId] = descriptor
        revision += 1
    }

    func unregister(agentId: String) {
        if descriptors.removeValue(forKey: agentId) != nil { revision += 1 }
    }

    /// IDs are filtered by the independent permission layer before projection.
    /// No default wildcard: new resources require an explicit owner scope.
    func catalog(client: RemoteClientCapabilities, authorizedAgentIDs: Set<String>) -> Catalog {
        let items = descriptors.values.filter { authorizedAgentIDs.contains($0.agentId) }
            .sorted { $0.agentId < $1.agentId }.map { descriptor in
                func highest(_ ours: [Int], _ theirs: [Int]) -> Int? {
                    // Remote API v1 is the only desktop protocol implemented.
                    Set(ours).intersection(theirs).intersection([1]).max()
                }
                guard client.descriptorMajors.contains(descriptor.descriptorSchemaVersion),
                      Set(descriptor.requiredClientFeatures).isSubset(of: Set(client.clientFeatures)),
                      let api = highest(descriptor.supportedApiMajors, client.apiMajors),
                      let event = highest(descriptor.supportedEventMajors, client.eventMajors),
                      let content = highest(descriptor.supportedContentMajors, client.contentMajors)
                else {
                    return CatalogItem(agentId: descriptor.agentId, displayName: descriptor.displayName,
                        status: "incompatible", unavailableReason: "protocol_incompatible",
                        descriptor: nil, negotiatedProtocol: nil)
                }
                return CatalogItem(agentId: descriptor.agentId, displayName: descriptor.displayName,
                    status: "registered", unavailableReason: nil, descriptor: descriptor,
                    negotiatedProtocol: RemoteNegotiatedProtocol(apiMajor: api, eventMajor: event, contentMajor: content))
            }
        return Catalog(catalogRevision: revision, items: items)
    }

    /// Potential capability, current runtime state and permission are separate.
    static func allowedActions(descriptor: RemoteAgentDescriptor, runtimeActions: Set<String>,
                               sessionActions: Set<String>, authorizedActions: Set<String>) -> [String] {
        Set(descriptor.possibleActions).intersection(runtimeActions)
            .intersection(sessionActions).intersection(authorizedActions).sorted()
    }
}
