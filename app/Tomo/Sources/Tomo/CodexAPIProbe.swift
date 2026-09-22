import Foundation

/// 登录后抓取 ChatGPT 相关 JSON 并落盘，用于验证 wham 是否含订阅字段、以及探测 subscriptions 等端点。
enum CodexAPIProbe {
    private static let enabledDefaultsKey = "codexling.debug.apiProbeEnabled"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["CODEXLING_API_PROBE"] == "1"
            || UserDefaults.standard.bool(forKey: enabledDefaultsKey)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledDefaultsKey)
    }

    static var outputRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Tomo/api-probes", isDirectory: true)
        return base
    }

    struct HTTPRecord: Encodable {
        let name: String
        let method: String
        let url: String
        let statusCode: Int
        let capturedAt: String
        let error: String?
        let subscriptionFieldHits: [FieldHit]
    }

    struct FieldHit: Encodable {
        let jsonPath: String
        let valuePreview: String
    }

    struct SessionManifest: Encodable {
        let capturedAt: String
        let accountIDPresent: Bool
        let accountIDSuffix: String?
        let endpoints: [HTTPRecord]
        let whamUsageTopLevelKeys: [String]
        let recommendation: String
    }

    struct ProbeHTTPResult: Sendable {
        let statusCode: Int
        let bodyJSON: Data?
        let error: String?
    }

    /// 探测 wham + 订阅相关端点，写入 `~/Library/Application Support/Tomo/api-probes/<timestamp>/`。
    static func recordSession(
        accountID: String?,
        usagePayloadJSON: Data,
        resetCreditsPayloadJSON: Data?,
        fetchProbe: @Sendable (URL, String?) async -> ProbeHTTPResult
    ) async throws -> URL {
        let usagePayload = try JSONSerialization.jsonObject(with: usagePayloadJSON)
        let resetCreditsPayload = resetCreditsPayloadJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let sessionDir = outputRoot.appendingPathComponent(stamp, isDirectory: true)
        let latestDir = outputRoot.appendingPathComponent("latest", isDirectory: true)

        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: latestDir.path) {
            try FileManager.default.removeItem(at: latestDir)
        }
        try FileManager.default.createDirectory(at: latestDir, withIntermediateDirectories: true)

        let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        let resetURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
        let subscriptionsBase = URL(string: "https://chatgpt.com/backend-api/subscriptions")!
        let accountsCheckURL = URL(string: "https://chatgpt.com/backend-api/accounts/check/v4-2023-04-27")!

        try writeJSON(usagePayload, name: "wham-usage", to: sessionDir)
        try writeJSON(usagePayload, name: "wham-usage", to: latestDir)
        if let resetCreditsPayload {
            try writeJSON(resetCreditsPayload, name: "wham-rate-limit-reset-credits", to: sessionDir)
            try writeJSON(resetCreditsPayload, name: "wham-rate-limit-reset-credits", to: latestDir)
        } else if let resetCreditsPayloadJSON {
            try resetCreditsPayloadJSON.write(
                to: sessionDir.appendingPathComponent("wham-rate-limit-reset-credits.json"),
                options: .atomic
            )
        }

        let usageHits = scanSubscriptionRelatedFields(in: usagePayload)
        let resetHits = resetCreditsPayload.map { scanSubscriptionRelatedFields(in: $0) } ?? []

        var subscriptionsURL = subscriptionsBase
        if let accountID, !accountID.isEmpty {
            var components = URLComponents(url: subscriptionsBase, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "account_id", value: accountID)]
            subscriptionsURL = components.url ?? subscriptionsBase
        }

        let probeTargets: [(name: String, url: URL)] = [
            ("subscriptions", subscriptionsURL),
            ("accounts-check-v4", accountsCheckURL),
            ("wham-usage-live", usageURL),
            ("wham-reset-credits-live", resetURL),
        ]

        var records: [HTTPRecord] = [
            HTTPRecord(
                name: "wham-usage-cached",
                method: "GET",
                url: usageURL.absoluteString,
                statusCode: 200,
                capturedAt: stamp,
                error: nil,
                subscriptionFieldHits: usageHits
            ),
        ]

        if !resetHits.isEmpty {
            records.append(
                HTTPRecord(
                    name: "wham-reset-credits-cached",
                    method: "GET",
                    url: resetURL.absoluteString,
                    statusCode: 200,
                    capturedAt: stamp,
                    error: nil,
                    subscriptionFieldHits: resetHits
                )
            )
        }

        for target in probeTargets {
            let result = await fetchProbe(target.url, accountID)
            let bodyObject = result.bodyJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) }
            let hits = bodyObject.map { scanSubscriptionRelatedFields(in: $0) } ?? []
            try writeProbeBody(result.bodyJSON, name: target.name, statusCode: result.statusCode, to: sessionDir)
            try writeProbeBody(result.bodyJSON, name: target.name, statusCode: result.statusCode, to: latestDir)

            records.append(
                HTTPRecord(
                    name: target.name,
                    method: "GET",
                    url: target.url.absoluteString,
                    statusCode: result.statusCode,
                    capturedAt: stamp,
                    error: result.error,
                    subscriptionFieldHits: hits
                )
            )
        }

        let whamKeys = (usagePayload as? [String: Any]).map { Array($0.keys.sorted()) } ?? []
        let hasWhamSubscriptionExpiry = usageHits.contains {
            $0.jsonPath.lowercased().contains("active_until")
                || $0.jsonPath.lowercased().contains("subscription")
                || $0.jsonPath.lowercased().contains("entitlement")
        }

        let subscriptionsOK = records.first { $0.name == "subscriptions" }?.statusCode == 200
        let subscriptionsHasActiveUntil = records
            .first { $0.name == "subscriptions" }?
            .subscriptionFieldHits
            .contains { $0.jsonPath.contains("active_until") } ?? false

        let recommendation: String
        if hasWhamSubscriptionExpiry {
            recommendation = "wham/usage 已出现订阅相关字段，优先扩展 TomoParser 从 wham 读取。"
        } else if subscriptionsOK == true && subscriptionsHasActiveUntil {
            recommendation = "wham 不含会员到期；建议在 OAuth 同源下增加 GET /backend-api/subscriptions（account_id）解析 active_until。"
        } else if subscriptionsOK == true {
            recommendation = "subscriptions 可访问但未发现 active_until，需对照落盘 JSON 确认字段名（如 entitlement.expires_at）。"
        } else {
            recommendation = "subscriptions 探测未成功（非 200 或需 account_id）。请对照 manifest 与浏览器 Network 订阅页请求。"
        }

        let manifest = SessionManifest(
            capturedAt: stamp,
            accountIDPresent: !(accountID ?? "").isEmpty,
            accountIDSuffix: accountID.map { String($0.suffix(min(6, $0.count))) },
            endpoints: records,
            whamUsageTopLevelKeys: whamKeys,
            recommendation: recommendation
        )

        try writeEncodable(manifest, name: "manifest", to: sessionDir)
        try writeEncodable(manifest, name: "manifest", to: latestDir)

        return sessionDir
    }

    static func scanSubscriptionRelatedFields(in value: Any, path: String = "") -> [FieldHit] {
        var hits: [FieldHit] = []
        let keywords = [
            "subscription", "active_until", "activeUntil", "expires_at", "expiresAt",
            "entitlement", "will_renew", "willRenew", "plan_type", "planType",
            "billing", "renewal", "membership",
        ]

        if let dict = value as? [String: Any] {
            for (key, nested) in dict {
                let nextPath = path.isEmpty ? key : "\(path).\(key)"
                let keyLower = key.lowercased()
                if keywords.contains(where: { keyLower.contains($0.lowercased()) }) {
                    hits.append(FieldHit(jsonPath: nextPath, valuePreview: previewValue(nested)))
                }
                hits.append(contentsOf: scanSubscriptionRelatedFields(in: nested, path: nextPath))
            }
        } else if let array = value as? [Any] {
            for (index, nested) in array.enumerated() {
                let nextPath = "\(path)[\(index)]"
                hits.append(contentsOf: scanSubscriptionRelatedFields(in: nested, path: nextPath))
            }
        }

        return hits
    }

    private static func previewValue(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if let string = value as? String {
            return String(string.prefix(120))
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        if value is [String: Any] { return "{…}" }
        if value is [Any] { return "[…]" }
        return String(describing: value).prefix(80).description
    }

    private static func writeJSON(_ object: Any, name: String, to directory: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("\(name).json"), options: .atomic)
    }

    private static func writeProbeBody(_ data: Data?, name: String, statusCode: Int, to directory: URL) throws {
        let fileName = "\(name)-\(statusCode).json"
        let url = directory.appendingPathComponent(fileName)
        if let data, !data.isEmpty {
            try data.write(to: url, options: .atomic)
        } else {
            try Data("""
            {"error":"empty_body"}
            """.utf8).write(to: url, options: .atomic)
        }
    }

    private static func writeEncodable<T: Encodable>(_ value: T, name: String, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: directory.appendingPathComponent("\(name).json"), options: .atomic)
    }
}
