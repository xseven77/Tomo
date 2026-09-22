import Foundation
import SwiftUI

// MARK: - Range & Filter Types

public enum GatewayDateRange: String, CaseIterable, Identifiable {
    case last10Minutes = "近 10 分钟"
    case today = "今天"
    case yesterday = "昨天"
    case last7Days = "近 7 天"
    case last30Days = "近 30 天"
    case custom = "自定义"

    public var id: String { rawValue }

    public var shortLabel: String {
        switch self {
        case .last10Minutes: "10分"
        case .today: "今天"
        case .yesterday: "昨天"
        case .last7Days: "7天"
        case .last30Days: "30天"
        case .custom: "自定义"
        }
    }

    public func calculateTimestamps(customStart: Date? = nil, customEnd: Date? = nil) -> (from: Int64, to: Int64) {
        let calendar = Calendar.current
        let now = Date()
        switch self {
        case .last10Minutes:
            let to = Int64(now.timeIntervalSince1970 * 1000)
            let from = to - (10 * 60 * 1000)
            return (from, to)
        case .today:
            let startOfToday = calendar.startOfDay(for: now)
            let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday)!.addingTimeInterval(-1)
            return (Int64(startOfToday.timeIntervalSince1970 * 1000), Int64(endOfToday.timeIntervalSince1970 * 1000))
        case .yesterday:
            let startOfToday = calendar.startOfDay(for: now)
            let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
            let endOfYesterday = startOfToday.addingTimeInterval(-1)
            return (Int64(startOfYesterday.timeIntervalSince1970 * 1000), Int64(endOfYesterday.timeIntervalSince1970 * 1000))
        case .last7Days:
            let startOfToday = calendar.startOfDay(for: now)
            let startOf7DaysAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday)!
            let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday)!.addingTimeInterval(-1)
            return (Int64(startOf7DaysAgo.timeIntervalSince1970 * 1000), Int64(endOfToday.timeIntervalSince1970 * 1000))
        case .last30Days:
            let startOfToday = calendar.startOfDay(for: now)
            let startOf30DaysAgo = calendar.date(byAdding: .day, value: -29, to: startOfToday)!
            let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday)!.addingTimeInterval(-1)
            return (Int64(startOf30DaysAgo.timeIntervalSince1970 * 1000), Int64(endOfToday.timeIntervalSince1970 * 1000))
        case .custom:
            let start = customStart ?? calendar.date(byAdding: .hour, value: -1, to: now) ?? now
            let end = customEnd ?? now
            let from = Int64(start.timeIntervalSince1970 * 1000)
            let to = Int64(end.timeIntervalSince1970 * 1000)
            return (min(from, to), max(from, to))
        }
    }
}

public enum GatewayMetricTab: String, CaseIterable, Identifiable {
    case tokens = "Tokens"
    case requests = "请求量"
    case latency = "延迟"

    public var id: String { rawValue }
}

public enum GatewayBreakdownDimension: String, CaseIterable, Identifiable {
    case agent = "Agent"
    case provider = "供应商"
    case account = "账号"
    case model = "模型"

    public var id: String { rawValue }

    public var apiDimension: String {
        switch self {
        case .agent: "agent"
        case .provider: "provider"
        case .account: "account"
        case .model: "model"
        }
    }
}

// MARK: - Server Response Models

public struct GatewayTelemetrySummary: Codable {
    public let from: Int64
    public let to: Int64
    public let timezoneOffsetMinutes: Int32
    public let collectionStartedAt: Int64?
    public let totalRequests: Int64
    public let successfulRequests: Int64
    public let failedRequests: Int64
    public let successRate: Double
    public let totalTokens: Int64
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cacheReadTokens: Int64
    public let cacheWriteTokens: Int64
    public let actualTokensRatio: Double
    public let estimatedTokensRatio: Double
    public let averageLatencyMs: Double
    public let p50LatencyMs: Int64
    public let p95LatencyMs: Int64
    public let p50TtftMs: Int64
    public let p95TtftMs: Int64
    public let toolCallsCount: Int64

    public var totalInputTokens: Int64 { inputTokens }
    public var totalOutputTokens: Int64 { outputTokens }
    public var actualTokens: Int64 { Int64(Double(totalTokens) * actualTokensRatio) }
    public var estimatedTokens: Int64 { Int64(Double(totalTokens) * estimatedTokensRatio) }
    public var averageTtftMs: Double { Double(p50TtftMs) }
    public var actualTokenRatio: Double { actualTokensRatio }
    public var estimatedCostCny: Double { 0.0 }

    public static var zero: GatewayTelemetrySummary {
        GatewayTelemetrySummary(
            from: 0,
            to: 0,
            timezoneOffsetMinutes: 0,
            collectionStartedAt: nil,
            totalRequests: 0,
            successfulRequests: 0,
            failedRequests: 0,
            successRate: 1.0,
            totalTokens: 0,
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            actualTokensRatio: 1.0,
            estimatedTokensRatio: 0.0,
            averageLatencyMs: 0,
            p50LatencyMs: 0,
            p95LatencyMs: 0,
            p50TtftMs: 0,
            p95TtftMs: 0,
            toolCallsCount: 0
        )
    }
}

public struct GatewayTimeseriesBucket: Codable, Identifiable {
    public var id: String { "\(bucketStart)_\(bucketLabel)" }
    public let bucketStart: Int64
    public let bucketLabel: String
    public let totalTokens: Int64
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cacheReadTokens: Int64
    public let actualRatio: Double
    public let requestsCount: Int64
    public let successCount: Int64
    public let errorCount: Int64
    public let avgLatencyMs: Double
    public let p50TtftMs: Int64
    public let p95TtftMs: Int64

    public var totalRequests: Int64 { requestsCount }
    public var successfulRequests: Int64 { successCount }
    public var failedRequests: Int64 { errorCount }
    public var avgTtftMs: Double { Double(p50TtftMs) }
}

public struct GatewayTimeseriesResponse: Codable {
    public let interval: String
    public let metric: String
    public let buckets: [GatewayTimeseriesBucket]
}

public struct GatewayBreakdownItem: Codable, Identifiable {
    public var id: String { name }
    public let name: String
    public let requestsCount: Int64
    public let totalTokens: Int64
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cacheReadTokens: Int64
    public let errorCount: Int64
    public let avgLatencyMs: Double
    public let avgTtftMs: Double
    public let percentage: Double

    public var key: String { name }
    public var totalRequests: Int64 { requestsCount }
    public var successfulRequests: Int64 { max(0, requestsCount - errorCount) }
    public var failedRequests: Int64 { errorCount }
    public var successRate: Double {
        guard requestsCount > 0 else { return 1.0 }
        return Double(successfulRequests) / Double(requestsCount)
    }
}

public struct GatewayBreakdownResponse: Codable {
    public let dimension: String
    public let items: [GatewayBreakdownItem]
}

public struct GatewayTelemetryEventDetail: Codable, Identifiable {
    public let id: String
    public let timestamp: Int64
    public let agent: String
    public let ingressProtocol: String
    public let provider: String
    public let account: String
    public let modelAlias: String
    public let targetModel: String
    public let inputTokens: Int64?
    public let outputTokens: Int64?
    public let cacheReadTokens: Int64?
    public let cacheWriteTokens: Int64?
    public let totalTokens: Int64?
    public let latencyMs: Int64
    public let ttftMs: Int64?
    public let statusCode: Int64
    public let status: String
    public let errorCategory: String?
    public let fidelity: String
    public let isStream: Bool
    public let toolCallsCount: Int64
    public let estimatedCost: Double?
    public let currency: String?

    public var requestId: String { id }
    public var isSuccess: Bool {
        status == "success" || statusCode == 200
    }
    public var errorMessage: String? { errorCategory }

    public var formattedTime: String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000.0)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    public var formattedDateTime: String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000.0)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

public struct GatewayRequestsResponse: Codable {
    public let total: Int64
    public let limit: Int
    public let offset: Int
    public let items: [GatewayTelemetryEventDetail]
}

// MARK: - Gateway Request Column Display Settings

public enum GatewayRequestColumn: String, CaseIterable, Identifiable, Codable, Sendable {
    case time = "time"
    case id = "id"
    case agent = "agent"
    case ingressProtocol = "ingressProtocol"
    case provider = "provider"
    case account = "account"
    case targetModel = "targetModel"
    case stream = "stream"
    case tokens = "tokens"
    case cacheTokens = "cacheTokens"
    case tools = "tools"
    case cost = "cost"
    case ttft = "ttft"
    case latency = "latency"
    case fidelity = "fidelity"
    case status = "status"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .time: return "时间"
        case .id: return "请求 ID"
        case .agent: return "来源 Agent"
        case .ingressProtocol: return "接入协议"
        case .provider: return "供应商"
        case .account: return "路由账号"
        case .targetModel: return "目标模型"
        case .stream: return "模式"
        case .tokens: return "Token (入/出)"
        case .cacheTokens: return "缓存 Token"
        case .tools: return "工具调用"
        case .cost: return "预估费用"
        case .ttft: return "TTFT"
        case .latency: return "延迟"
        case .fidelity: return "保真度"
        case .status: return "状态"
        }
    }

    public var subtitle: String {
        switch self {
        case .time: return "请求发起的本地完整时间戳 (yyyy-MM-dd HH:mm:ss)"
        case .id: return "链路唯一请求标识符 (点击可复制)"
        case .agent: return "发起请求的客户端 (Cursor, Claude Code 等)"
        case .ingressProtocol: return "入向服务协议 (OpenAI Chat, Messages 等)"
        case .provider: return "实际执行调用的模型供应商"
        case .account: return "账号池中被调度的具体认证账号"
        case .targetModel: return "上游实际调用的目标模型名称"
        case .stream: return "SSE 流式输出或单次同步请求"
        case .tokens: return "输入与输出 Token 统计用量"
        case .cacheTokens: return "Prompt Caching 命中读写 Token"
        case .tools: return "Agent Function / Tool Call 触发次数"
        case .cost: return "单次请求预估产生的美金费用"
        case .ttft: return "首字生成延迟 (Time To First Token)"
        case .latency: return "全链路请求往返总耗时"
        case .fidelity: return "Token 用量为实际官方值或启发估算值"
        case .status: return "HTTP 响应状态码及错误信息"
        }
    }

    public var category: GatewayColumnCategory {
        switch self {
        case .time, .id, .agent, .ingressProtocol:
            return .basic
        case .provider, .account, .targetModel, .stream:
            return .routing
        case .tokens, .cacheTokens, .tools, .cost:
            return .usage
        case .ttft, .latency, .fidelity, .status:
            return .performance
        }
    }

    public var minWidth: CGFloat {
        switch self {
        case .time: return 130
        case .id: return 68
        case .agent: return 70
        case .ingressProtocol: return 75
        case .provider: return 75
        case .account: return 70
        case .targetModel: return 120
        case .stream: return 42
        case .tokens: return 78
        case .cacheTokens: return 65
        case .tools: return 46
        case .cost: return 54
        case .ttft: return 46
        case .latency: return 46
        case .fidelity: return 42
        case .status: return 50
        }
    }

    public var flexWeight: CGFloat {
        switch self {
        case .targetModel: return 3.5
        case .agent: return 1.2
        case .ingressProtocol: return 1.0
        case .provider: return 1.0
        case .account: return 1.0
        case .tokens: return 0.8
        case .cacheTokens: return 0.6
        case .id: return 0.4
        case .time, .stream, .tools, .cost, .ttft, .latency, .fidelity, .status:
            return 0.0
        }
    }

    public var maxWidth: CGFloat {
        switch self {
        case .time: return 145
        case .id: return 84
        case .agent: return 120
        case .ingressProtocol: return 110
        case .provider: return 120
        case .account: return 110
        case .targetModel: return .infinity
        case .stream: return 48
        case .tokens: return 120
        case .cacheTokens: return 90
        case .tools: return 56
        case .cost: return 70
        case .ttft: return 56
        case .latency: return 56
        case .fidelity: return 48
        case .status: return 58
        }
    }

    public var alignment: Alignment {
        switch self {
        case .time, .id, .agent, .ingressProtocol, .provider, .account, .targetModel:
            return .leading
        case .stream, .tools, .fidelity:
            return .center
        case .tokens, .cacheTokens, .cost, .ttft, .latency, .status:
            return .trailing
        }
    }

    public static let defaultColumns: [GatewayRequestColumn] = [
        .time,
        .agent,
        .ingressProtocol,
        .targetModel,
        .tokens,
        .ttft,
        .latency,
        .fidelity,
        .status
    ]
}

public enum GatewayColumnCategory: String, CaseIterable, Identifiable, Sendable {
    case basic = "基础链路"
    case routing = "路由与模型"
    case usage = "Token 与成本"
    case performance = "性能与质量"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .basic: return "network"
        case .routing: return "arrow.triangle.branch"
        case .usage: return "gauge.with.needle"
        case .performance: return "waveform.path.ecg"
        }
    }

    public var columns: [GatewayRequestColumn] {
        GatewayRequestColumn.allCases.filter { $0.category == self }
    }
}

// MARK: - Token 活动热力图与用量分析数据模型

public struct GatewayHeatmapCell: Identifiable, Sendable {
    public let id: String
    public let date: Date
    public let dayString: String // "yyyy-MM-dd"
    public let monthLabel: String // "8月" or empty
    public let totalTokens: Int64
    public let requestsCount: Int64
    public let level: Int // 0..4

    public init(id: String, date: Date, dayString: String, monthLabel: String, totalTokens: Int64, requestsCount: Int64, level: Int) {
        self.id = id
        self.date = date
        self.dayString = dayString
        self.monthLabel = monthLabel
        self.totalTokens = totalTokens
        self.requestsCount = requestsCount
        self.level = level
    }
}

public struct GatewayHeatmapSummary: Sendable {
    public let totalTokens: Int64
    public let peakTokens: Int64
    public let peakDay: String
    public let longestSessionDurationText: String
    public let currentStreakDays: Int
    public let maxStreakDays: Int
    public let activeDaysCount: Int

    public static var zero: GatewayHeatmapSummary {
        GatewayHeatmapSummary(
            totalTokens: 0,
            peakTokens: 0,
            peakDay: "--",
            longestSessionDurationText: "--",
            currentStreakDays: 0,
            maxStreakDays: 0,
            activeDaysCount: 0
        )
    }
}

public struct GatewayModelTimeseriesPoint: Identifiable, Sendable {
    public var id: String { "\(date.timeIntervalSince1970)_\(groupKey)" }
    public let date: Date
    public let dateLabel: String
    public let groupKey: String
    public let count: Int
    public let tokens: Int64

    public init(date: Date, dateLabel: String, groupKey: String, count: Int, tokens: Int64) {
        self.date = date
        self.dateLabel = dateLabel
        self.groupKey = groupKey
        self.count = count
        self.tokens = tokens
    }
}

public struct GatewayTokenComposition: Sendable {
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cacheReadTokens: Int64
    public let totalTokens: Int64

    public var inputPercentage: Double {
        totalTokens > 0 ? (Double(inputTokens) / Double(totalTokens)) * 100.0 : 0
    }
    public var outputPercentage: Double {
        totalTokens > 0 ? (Double(outputTokens) / Double(totalTokens)) * 100.0 : 0
    }

    public static var zero: GatewayTokenComposition {
        GatewayTokenComposition(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, totalTokens: 0)
    }

    public init(inputTokens: Int64, outputTokens: Int64, cacheReadTokens: Int64, totalTokens: Int64) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.totalTokens = totalTokens
    }
}

public struct GatewayModelRankingItem: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let tokens: Int64
    public let turns: Int
    public let percentage: Double

    public init(name: String, tokens: Int64, turns: Int, percentage: Double) {
        self.name = name
        self.tokens = tokens
        self.turns = turns
        self.percentage = percentage
    }
}

public struct GatewayLatencyRankingItem: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let avgTtftMs: Int
    public let avgTotalLatencyMs: Int
    public let count: Int

    public init(name: String, avgTtftMs: Int, avgTotalLatencyMs: Int, count: Int) {
        self.name = name
        self.avgTtftMs = avgTtftMs
        self.avgTotalLatencyMs = avgTotalLatencyMs
        self.count = count
    }
}

public struct GatewayClientRankingItem: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let tokens: Int64
    public let turns: Int
    public let percentage: Double

    public init(name: String, tokens: Int64, turns: Int, percentage: Double) {
        self.name = name
        self.tokens = tokens
        self.turns = turns
        self.percentage = percentage
    }
}

public enum GatewayAnalyticsGrouping: String, CaseIterable, Identifiable, Sendable {
    case model = "model"
    case provider = "provider"
    case account = "account"
    case surface = "surface"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .model: return "By model"
        case .provider: return "By provider"
        case .account: return "By account"
        case .surface: return "By surface"
        }
    }

    public var chartHeroTitle: String {
        switch self {
        case .model: return "模型交互轮次"
        case .provider: return "供应商调用轮次"
        case .account: return "账号调用轮次"
        case .surface: return "客户端会话轮次"
        }
    }
}

public enum GatewayAnalyticsMetricMode: String, CaseIterable, Identifiable, Sendable {
    case tokens = "Tokens"
    case turns = "轮次"

    public var id: String { rawValue }
}

public enum GatewayAnalyticsChartStyle: String, CaseIterable, Identifiable, Sendable {
    case area = "面积曲线"
    case bars = "堆叠柱状"

    public var id: String { rawValue }

    public var title: String { rawValue }

    public var icon: String {
        switch self {
        case .area: return "waveform.path.ecg"
        case .bars: return "chart.bar.fill"
        }
    }
}

public enum GatewayAnalyticsRankingDimension: String, CaseIterable, Identifiable, Sendable {
    case model = "模型"
    case provider = "供应商"
    case account = "账号"

    public var id: String { rawValue }
}

public struct GatewayProviderRankingItem: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let tokens: Int64
    public let turns: Int
    public let percentage: Double
    public let accountsCount: Int

    public init(name: String, tokens: Int64, turns: Int, percentage: Double, accountsCount: Int) {
        self.name = name
        self.tokens = tokens
        self.turns = turns
        self.percentage = percentage
        self.accountsCount = accountsCount
    }
}

public struct GatewayAccountRankingItem: Identifiable, Sendable {
    public var id: String { "\(provider)-\(name)" }
    public let name: String
    public let provider: String
    public let tokens: Int64
    public let turns: Int
    public let percentage: Double

    public init(name: String, provider: String, tokens: Int64, turns: Int, percentage: Double) {
        self.name = name
        self.provider = provider
        self.tokens = tokens
        self.turns = turns
        self.percentage = percentage
    }
}


