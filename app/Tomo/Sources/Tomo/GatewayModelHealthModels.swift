import Foundation

public struct GatewayModelHealthSummary: Codable, Sendable {
    public let total: Int
    public let available: Int
    public let unavailable: Int
    public let error: Int
    public let unchecked: Int
    public let skipped: Int
    /// 巡检是否被用户取消。网关（Rust）在 `finish_job` 写入的摘要里带该字段，
    /// 仅靠 `done < total` 猜取消会误判，因此这里显式解码。
    public let cancelled: Bool

    public init(
        total: Int = 0,
        available: Int = 0,
        unavailable: Int = 0,
        error: Int = 0,
        unchecked: Int = 0,
        skipped: Int = 0,
        cancelled: Bool = false
    ) {
        self.total = total
        self.available = available
        self.unavailable = unavailable
        self.error = error
        self.unchecked = unchecked
        self.skipped = skipped
        self.cancelled = cancelled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.total = (try? container.decode(Int.self, forKey: .total)) ?? 0
        self.available = (try? container.decode(Int.self, forKey: .available)) ?? 0
        self.unavailable = (try? container.decode(Int.self, forKey: .unavailable)) ?? 0
        self.error = (try? container.decode(Int.self, forKey: .error)) ?? 0
        self.unchecked = (try? container.decode(Int.self, forKey: .unchecked)) ?? 0
        self.skipped = (try? container.decode(Int.self, forKey: .skipped)) ?? 0
        self.cancelled = (try? container.decode(Bool.self, forKey: .cancelled)) ?? false
    }
}

public struct GatewayModelHealthItem: Codable, Identifiable, Sendable {
    public var id: String
    public let scopedId: String
    public let status: String // "available", "unavailable", "error", "skipped", "unchecked"
    public let reason: String?
    public let latencyMs: UInt64?
    public let checkedAt: Int64?
    public let retries: UInt32?
    public let exported: Bool

    public var isAvailable: Bool {
        status == "available"
    }

    public var isUnavailable: Bool {
        status == "unavailable"
    }

    public var isError: Bool {
        status == "error"
    }

    public var isUnchecked: Bool {
        status == "unchecked"
    }

    public var isSkipped: Bool {
        status == "skipped"
    }
}

public struct GatewayAccountHealth: Codable, Identifiable, Sendable {
    public var id: String { connectionId }
    public let provider: String
    public let providerName: String
    public let connectionId: String
    public let slug: String
    public let label: String
    public let checkedAt: Int64?
    public let summary: GatewayModelHealthSummary
    public let models: [GatewayModelHealthItem]
}

public struct GatewayModelCheckResult: Codable, Identifiable, Equatable, Sendable {
    public var id: String { scopedId }
    public let scopedId: String
    public let status: String
    public let reason: String?
    public let latencyMs: UInt64?
}

public struct GatewayModelCheckJobStatus: Codable, Sendable {
    public let running: Bool
    public let scope: String
    public let done: Int
    public let total: Int
    public let current: String
    public let results: [GatewayModelCheckResult]
    public let startedAt: Int64
    public let lastFinishedAt: Int64?
    public let lastSummary: GatewayModelHealthSummary?

    public init(
        running: Bool,
        scope: String,
        done: Int,
        total: Int,
        current: String,
        results: [GatewayModelCheckResult] = [],
        startedAt: Int64,
        lastFinishedAt: Int64? = nil,
        lastSummary: GatewayModelHealthSummary? = nil
    ) {
        self.running = running
        self.scope = scope
        self.done = done
        self.total = total
        self.current = current
        self.results = results
        self.startedAt = startedAt
        self.lastFinishedAt = lastFinishedAt
        self.lastSummary = lastSummary
    }

    enum CodingKeys: String, CodingKey {
        case running, scope, done, total, current, results, startedAt, lastFinishedAt, lastSummary
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        running = try container.decode(Bool.self, forKey: .running)
        scope = try container.decode(String.self, forKey: .scope)
        done = try container.decode(Int.self, forKey: .done)
        total = try container.decode(Int.self, forKey: .total)
        current = try container.decode(String.self, forKey: .current)
        results = try container.decodeIfPresent([GatewayModelCheckResult].self, forKey: .results) ?? []
        startedAt = try container.decode(Int64.self, forKey: .startedAt)
        lastFinishedAt = try container.decodeIfPresent(Int64.self, forKey: .lastFinishedAt)
        lastSummary = try container.decodeIfPresent(GatewayModelHealthSummary.self, forKey: .lastSummary)
    }
}

public struct GatewayModelHealthResponse: Codable, Sendable {
    public let lastFullCheckAt: Int64?
    public let summary: GatewayModelHealthSummary?
    public let accounts: [GatewayAccountHealth]
    public let job: GatewayModelCheckJobStatus?
}
