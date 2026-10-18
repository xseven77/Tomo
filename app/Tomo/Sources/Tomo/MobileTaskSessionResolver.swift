import Foundation

/// Match activity provenance to an owner-registered directory, never a display name.
enum MobileTaskSessionResolver {
    struct Source: Sendable {
        let id: String
        let serverId: String
        let directories: [ChatGPTSessionDirectory]
    }

    static func resolve(tasks: [CodexTaskActivity], source: Source) throws -> [String: MobileSessionReference] {
        var result: [String: MobileSessionReference] = [:]
        var ambiguous = Set<String>()
        for directory in source.directories {
            for (key, reference) in try resolve(tasks: tasks, directory: directory, serverId: source.serverId) {
                if let previous = result[key], previous != reference { ambiguous.insert(key) }
                result[key] = reference
            }
        }
        for key in ambiguous { result.removeValue(forKey: key) }
        return result
    }

    static func key(_ task: CodexTaskActivity) -> String? {
        guard let database = task.sessionSourceDatabaseURL else { return nil }
        return database.resolvingSymlinksInPath().standardizedFileURL.path + "\0" + task.id
    }

    static func resolve(tasks: [CodexTaskActivity], directory: ChatGPTSessionDirectory,
                        serverId: String) throws -> [String: MobileSessionReference] {
        let database = directory.databaseURL.resolvingSymlinksInPath().standardizedFileURL
        let matching = tasks.filter {
            $0.sessionSourceDatabaseURL?.resolvingSymlinksInPath().standardizedFileURL == database
        }
        guard !serverId.isEmpty, !matching.isEmpty else { return [:] }
        let entries = try directory.snapshot().entries
        let indexed = Dictionary(entries.filter { !$0.archived }.map { ($0.vendorSessionId, $0.sessionId) },
                                 uniquingKeysWith: { first, _ in first })
        var references: [String: MobileSessionReference] = [:]
        for task in matching {
            guard let key = key(task), let sessionId = indexed[task.id] else { continue }
            references[key] = .init(serverId: serverId, agentId: "agent.chatgpt",
                                    runtimeId: directory.runtimeId, sessionId: sessionId)
        }
        return references
    }
}
