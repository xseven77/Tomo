import Foundation

/// Private vendor history acquisition. All pages are bounded and kept behind
/// the pump's event checkpoint; this does not create a vendor subscription.
struct ChatGPTBaselineReader {
    let channel: AgentRPCChannel

    /// Only for a freshly acknowledged ephemeral thread on its creating
    /// process, before any turn/start. Installed CLI rejects includeTurns=true
    /// for ephemeral threads, while the empty metadata read is available.
    func readFreshEphemeral(threadId: String) async throws -> AgentJSON {
        let response = try await channel.request(method: "thread/read", params: .object([
            "threadId": .string(threadId), "includeTurns": .bool(false)]))
        guard case .object(let result) = response, case .object(var thread) = result["thread"],
              thread["id"] == .string(threadId), thread["ephemeral"] == .bool(true),
              thread["path"] == .null, case .object(let status) = thread["status"],
              status["type"] == .string("idle") || status["type"] == .string("notLoaded"),
              thread["turns"] == nil || thread["turns"] == .array([]),
              thread["historyMode"] == nil || thread["historyMode"] == .null || thread["historyMode"] == .string("legacy") else {
            throw ChatGPTBaselineError.invalidThread
        }
        thread["turns"] = .array([])
        return .object(["thread": .object(thread)])
    }

    /// Called only after this process's successful persistent thread/start and
    /// before any turn. The vendor cannot page an unmaterialized empty thread.
    func readFreshPersistent(threadId: String) async throws -> AgentJSON {
        let response = try await channel.request(method: "thread/read", params: .object([
            "threadId": .string(threadId), "includeTurns": .bool(false)]))
        guard case .object(let result) = response, case .object(var thread) = result["thread"],
              thread["id"] == .string(threadId), thread["ephemeral"] == .bool(false),
              case .string(let path) = thread["path"], path.hasPrefix("/"),
              case .object(let status) = thread["status"], status["type"] == .string("idle"),
              thread["turns"] == nil || thread["turns"] == .array([]),
              thread["historyMode"] == nil || thread["historyMode"] == .null || thread["historyMode"] == .string("legacy")
                || thread["historyMode"] == .string("paginated") else {throw ChatGPTBaselineError.invalidThread}
        thread["turns"] = .array([]); thread["historyMode"] = .string("legacy")
        return .object(["thread": .object(thread)])
    }

    func read(threadId: String) async throws -> AgentJSON {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        func request(_ method: String, _ params: AgentJSON) async throws -> AgentJSON {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw AgentRPCError.timedOut }
            return try await channel.request(method: method, params: params, timeout: min(.seconds(15), remaining))
        }
        let initial = try await request("thread/read", .object([
            "threadId": .string(threadId), "includeTurns": .bool(false)]))
        guard case .object(let result) = initial, case .object(var thread) = result["thread"],
              thread["id"] == .string(threadId) else { throw ChatGPTBaselineError.invalidThread }
        guard thread["historyMode"] == .string("paginated") else {
            guard thread["historyMode"] == nil || thread["historyMode"] == .null || thread["historyMode"] == .string("legacy") else {
                throw ChatGPTBaselineError.incompleteHistory
            }
            return try await request("thread/read", .object([
                "threadId": .string(threadId), "includeTurns": .bool(true)]))
        }

        var turns: [AgentJSON] = [], cursors = Set<String>(), turnIDs = Set<String>()
        var cursor: String?, bytes = try JSONEncoder().encode(initial).count
        guard bytes <= 8 * 1024 * 1024 else { throw ChatGPTBaselineError.limitExceeded }
        for pageNumber in 0..<100 {
            try Task.checkCancellation()
            var params: [String: AgentJSON] = ["threadId": .string(threadId), "itemsView": .string("full"),
                "sortDirection": .string("asc"), "limit": .integer(50)]
            if let cursor { params["cursor"] = .string(cursor) }
            let response = try await request("thread/turns/list", .object(params))
            bytes += try JSONEncoder().encode(response).count
            guard bytes <= 8 * 1024 * 1024 else { throw ChatGPTBaselineError.limitExceeded }
            guard case .object(let page) = response, case .array(let data) = page["data"], data.count <= 50 else {
                throw ChatGPTBaselineError.incompleteHistory
            }
            for value in data {
                guard case .object(let turn) = value, case .string(let id) = turn["id"],
                      !id.isEmpty, id.utf8.count <= 256, !id.contains("\0"), turnIDs.insert(id).inserted,
                      turn["itemsView"] == .string("full"), case .array = turn["items"] else {
                    throw ChatGPTBaselineError.incompleteHistory
                }
                turns.append(value)
                guard turns.count <= 1000 else { throw ChatGPTBaselineError.limitExceeded }
            }
            if let next = page["nextCursor"], next != .null {
                guard case .string(let token) = next, !token.isEmpty, token.utf8.count <= 4096,
                      !token.contains("\0"), !data.isEmpty, cursors.insert(token).inserted else {
                    throw ChatGPTBaselineError.incompleteHistory
                }
                cursor = token
                if pageNumber == 99 { throw ChatGPTBaselineError.limitExceeded }
                continue
            }
            // Metadata is checked again after traversal. The caller also checks
            // queued notifications before publishing, so a changed live source
            // cannot turn partial pages into an authoritative baseline.
            let final = try await request("thread/read", .object([
                "threadId": .string(threadId), "includeTurns": .bool(false)]))
            bytes += try JSONEncoder().encode(final).count
            guard bytes <= 8 * 1024 * 1024 else { throw ChatGPTBaselineError.limitExceeded }
            guard case .object(let finalResult) = final, case .object(let latest) = finalResult["thread"],
                  ["id", "createdAt", "updatedAt", "status", "historyMode"].allSatisfy({ latest[$0] == thread[$0] }) else {
                throw ChatGPTEventPumpError.baselineChanged
            }
            thread["turns"] = .array(turns)
            // Only an exhausted, validated traversal may enter the existing
            // full-history importer. Never normalize the vendor's partial read.
            thread["historyMode"] = .string("legacy")
            return .object(["thread": .object(thread)])
        }
        throw ChatGPTBaselineError.limitExceeded
    }
}
