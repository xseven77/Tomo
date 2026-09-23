import AppKit
import CryptoKit
import Foundation
import Network
import Security

enum CodexUsageError: Equatable, LocalizedError {
    case noStoredToken
    case oauthCancelled
    case oauthCallbackInvalid
    case oauthTimedOut
    case tokenExchangeFailed(Int)
    case quotaUnavailable
    case invalidTokenResponse

    var errorDescription: String? {
        switch self {
        case .noStoredToken:
            "未登录"
        case .oauthCancelled:
            "OAuth 授权已取消"
        case .oauthCallbackInvalid:
            "OAuth 回调无效"
        case .oauthTimedOut:
            "OAuth 授权超时"
        case .tokenExchangeFailed(let status):
            "Token 交换失败：\(status)"
        case .quotaUnavailable:
            "Codex 用量接口暂不可用"
        case .invalidTokenResponse:
            "Token 响应无效"
        }
    }
}

actor CodexUsageService {
    private let authorizationURL = URL(string: "https://auth.openai.com/oauth/authorize")!
    private let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    private let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private let resetCreditsURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    private let subscriptionsURL = URL(string: "https://chatgpt.com/backend-api/subscriptions")!
    private let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private let redirectURI = "http://localhost:1455/auth/callback"
    private let scopes = ["openid", "email", "profile", "offline_access"]
    private let tokenStore: CodexOAuthTokenStore
    private var activeOAuthCallbackServer: OAuthCallbackServer?
    private var oauthCancellationRequested = false
    /// 这些接口经代理/VPN 访问时可能耗时 6–13s，20s 超时太紧，放宽到 60s。
    private static let requestTimeout: TimeInterval = 60

    init(tokenStore: CodexOAuthTokenStore = CodexOAuthTokenStore()) {
        self.tokenStore = tokenStore
    }

    func connectAndFetch(forceLogin: Bool = false) async throws -> CodexUsageSnapshot {
        let token = try await validToken(forceLogin: forceLogin)
        return try await fetchQuotaSnapshot(token: token)
    }

    func fetchWithStoredToken() async throws -> CodexUsageSnapshot {
        guard let token = tokenStore.load() else {
            throw CodexUsageError.noStoredToken
        }

        if token.expiresAt.timeIntervalSinceNow > 60 {
            return try await fetchQuotaSnapshot(token: token)
        }

        let refreshed = try await refreshToken(token)
        tokenStore.save(refreshed)
        return try await fetchQuotaSnapshot(token: refreshed)
    }

    /// 动态从官方接口获取当前授权账号下的全部可用模型列表
    /// Returns only the model IDs advertised by OpenAI for this account.
    ///
    /// Do not invent a compatibility list when discovery is unavailable: an
    /// invented ID can be displayed as usable and then be routed to an account
    /// that has never been granted access to it.
    func fetchAvailableModels() async throws -> [String] {
        let token = try await validToken(forceLogin: false)
        let accountID = readJWTClaim(token.accessToken, namespace: "https://api.openai.com/auth", claim: "chatgpt_account_id")
        let modelsURL = URL(string: "https://chatgpt.com/backend-api/models")!
        if let json = try? await fetchJSON(url: modelsURL, token: token.accessToken, accountID: accountID) as? [String: Any],
           let models = json["models"] as? [[String: Any]] {
            // An empty array is also an authoritative response: it means this
            // account currently has no exported models, not that we should
            // resurrect a guessed compatibility list.
            return models.compactMap { $0["slug"] as? String }.filter { !$0.isEmpty }
        }
        let standardURL = URL(string: "https://api.openai.com/v1/models")!
        if let json = try? await fetchJSON(url: standardURL, token: token.accessToken, accountID: accountID) as? [String: Any],
           let data = json["data"] as? [[String: Any]] {
            return data.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
        }
        throw CodexUsageError.quotaUnavailable
    }

    func disconnect() {
        tokenStore.clear()
    }

    /// 是否已成功落盘 OAuth token。OAuth 成功但额度抓取失败时，可据此判断
    /// 「已登录」而非「登录失败」。
    func hasStoredToken() -> Bool {
        tokenStore.hasStoredToken()
    }

    /// Stops the in-flight browser authorization wait immediately. The caller
    /// still owns the browser tab, but Tomo no longer accepts its callback.
    func cancelOAuthAuthorization() {
        if let activeOAuthCallbackServer {
            activeOAuthCallbackServer.cancel()
        } else {
            oauthCancellationRequested = true
        }
    }

    private func validToken(forceLogin: Bool) async throws -> CodexOAuthToken {
        if !forceLogin, let token = tokenStore.load() {
            if token.expiresAt.timeIntervalSinceNow > 60 {
                return token
            }

            if let refreshed = try? await refreshToken(token) {
                tokenStore.save(refreshed)
                return refreshed
            }
        }

        let token = try await startOAuth(forceLogin: forceLogin)
        tokenStore.save(token)
        return token
    }

    private func startOAuth(forceLogin: Bool) async throws -> CodexOAuthToken {
        if oauthCancellationRequested {
            oauthCancellationRequested = false
            throw CodexUsageError.oauthCancelled
        }
        let state = randomBase64URL(byteCount: 24)
        let verifier = randomBase64URL(byteCount: 32)
        let challenge = sha256Base64URL(verifier)
        let callbackServer = OAuthCallbackServer(expectedState: state)
        activeOAuthCallbackServer = callbackServer
        defer {
            if activeOAuthCallbackServer === callbackServer {
                activeOAuthCallbackServer = nil
            }
            oauthCancellationRequested = false
        }

        var components = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        if forceLogin {
            components.queryItems?.append(URLQueryItem(name: "prompt", value: "login"))
        }

        guard let url = components.url else {
            throw CodexUsageError.oauthCallbackInvalid
        }

        let codeTask = Task {
            try await callbackServer.waitForCode(timeoutSeconds: 90)
        }

        await MainActor.run {
            _ = NSWorkspace.shared.open(url)
        }

        do {
            let code = try await codeTask.value
            return try await exchangeCodeForToken(code: code, verifier: verifier)
        } catch {
            callbackServer.cancel()
            throw error
        }
    }

    private func exchangeCodeForToken(code: String, verifier: String) async throws -> CodexOAuthToken {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier
        ])

        let (data, response) = try await URLSession.tomoExternal.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexUsageError.invalidTokenResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw CodexUsageError.tokenExchangeFailed(httpResponse.statusCode)
        }

        let payload = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let expiresIn = payload.expiresIn else {
            throw CodexUsageError.invalidTokenResponse
        }

        return CodexOAuthToken(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            idToken: payload.idToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
            email: readProfileEmail(from: payload.idToken),
            displayName: readProfileName(from: payload.idToken)
        )
    }

    private func refreshToken(_ token: CodexOAuthToken) async throws -> CodexOAuthToken {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": token.refreshToken
        ])

        let (data, response) = try await URLSession.tomoExternal.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw CodexUsageError.invalidTokenResponse
        }

        let payload = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let expiresIn = payload.expiresIn else {
            throw CodexUsageError.invalidTokenResponse
        }

        return CodexOAuthToken(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken.isEmpty ? token.refreshToken : payload.refreshToken,
            idToken: payload.idToken ?? token.idToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
            email: readProfileEmail(from: payload.idToken ?? token.idToken) ?? token.email,
            displayName: readProfileName(from: payload.idToken ?? token.idToken) ?? token.displayName
        )
    }

    private func fetchQuotaSnapshot(token: CodexOAuthToken) async throws -> CodexUsageSnapshot {
        let accountID = readJWTClaim(token.accessToken, namespace: "https://api.openai.com/auth", claim: "chatgpt_account_id")
        let usagePayload = try await fetchJSON(url: usageURL, token: token.accessToken, accountID: accountID)
        let resetPayload = try? await fetchJSON(url: resetCreditsURL, token: token.accessToken, accountID: accountID)
        if CodexAPIProbe.isEnabled {
            _ = try? await recordAPIProbeSession(
                token: token,
                accountID: accountID,
                usagePayload: usagePayload,
                resetCreditsPayload: resetPayload
            )
        }
        let quota = TomoParser().parse(
            usagePayload: usagePayload,
            resetCreditsPayload: resetPayload,
            email: token.email,
            accountName: token.displayName
        )

        guard (quota.shortWindow?.total ?? 0) > 0 || quota.weekly.total > 0 else {
            throw CodexUsageError.quotaUnavailable
        }

        var snapshot = quota
        if let accountID, !accountID.isEmpty,
           let subscriptionPayload = try? await fetchSubscriptionsPayload(
               token: token.accessToken,
               accountID: accountID
           ) {
            let subscription = TomoParser().parseSubscription(subscriptionPayload)
            snapshot.subscriptionActiveUntilISO = subscription.activeUntilISO
            snapshot.subscriptionWillRenew = subscription.willRenew
        }

        return snapshot
    }

    private func fetchSubscriptionsPayload(token: String, accountID: String) async throws -> Any {
        var components = URLComponents(url: subscriptionsURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "account_id", value: accountID)]
        guard let url = components.url else {
            throw CodexUsageError.quotaUnavailable
        }
        return try await fetchChatGPTBackendJSON(url: url, token: token, accountID: accountID, wham: false)
    }

    private func fetchChatGPTBackendJSON(
        url: URL,
        token: String,
        accountID: String?,
        wham: Bool
    ) async throws -> Any {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Tomo/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("https://chatgpt.com/", forHTTPHeaderField: "Origin")
        request.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        if wham {
            request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
            request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        }
        if let accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await URLSession.tomoExternal.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw CodexUsageError.quotaUnavailable
        }

        return try JSONSerialization.jsonObject(with: data)
    }

    /// 使用 Keychain 中已有 OAuth token 抓取 wham + 订阅相关端点并落盘（不写入 token）。
    func runChatGPTAPIProbe() async throws -> URL {
        let token = try await tokenForProbe()
        let accountID = readJWTClaim(token.accessToken, namespace: "https://api.openai.com/auth", claim: "chatgpt_account_id")
        let usagePayload = try await fetchJSON(url: usageURL, token: token.accessToken, accountID: accountID)
        let resetPayload = try? await fetchJSON(url: resetCreditsURL, token: token.accessToken, accountID: accountID)
        return try await recordAPIProbeSession(
            token: token,
            accountID: accountID,
            usagePayload: usagePayload,
            resetCreditsPayload: resetPayload
        )
    }

    private func tokenForProbe() async throws -> CodexOAuthToken {
        guard var token = tokenStore.load() else {
            throw CodexUsageError.noStoredToken
        }
        if token.expiresAt.timeIntervalSinceNow <= 60 {
            token = try await refreshToken(token)
            tokenStore.save(token)
        }
        return token
    }

    private func recordAPIProbeSession(
        token: CodexOAuthToken,
        accountID: String?,
        usagePayload: Any,
        resetCreditsPayload: Any?
    ) async throws -> URL {
        let usageData = try JSONSerialization.data(withJSONObject: usagePayload, options: [.sortedKeys])
        let resetData: Data?
        if let resetCreditsPayload {
            resetData = try JSONSerialization.data(withJSONObject: resetCreditsPayload, options: [.sortedKeys])
        } else {
            resetData = nil
        }
        let accessToken = token.accessToken
        return try await CodexAPIProbe.recordSession(
            accountID: accountID,
            usagePayloadJSON: usageData,
            resetCreditsPayloadJSON: resetData
        ) { url, accountID in
            await self.fetchProbeJSON(url: url, token: accessToken, accountID: accountID)
        }
    }

    private func fetchProbeJSON(
        url: URL,
        token: String,
        accountID: String?
    ) async -> CodexAPIProbe.ProbeHTTPResult {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Tomo/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("https://chatgpt.com/", forHTTPHeaderField: "Origin")
        request.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        if url.path.contains("/wham/") {
            request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
            request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        }
        if let accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        do {
            let (data, response) = try await URLSession.tomoExternal.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return CodexAPIProbe.ProbeHTTPResult(statusCode: 0, bodyJSON: nil, error: "无 HTTP 响应")
            }
            if httpResponse.statusCode != 200 {
                let snippet = String(data: data.prefix(240), encoding: .utf8) ?? ""
                return CodexAPIProbe.ProbeHTTPResult(
                    statusCode: httpResponse.statusCode,
                    bodyJSON: data.isEmpty ? nil : data,
                    error: "HTTP \(httpResponse.statusCode) \(snippet)"
                )
            }
            return CodexAPIProbe.ProbeHTTPResult(statusCode: httpResponse.statusCode, bodyJSON: data, error: nil)
        } catch {
            return CodexAPIProbe.ProbeHTTPResult(statusCode: 0, bodyJSON: nil, error: error.localizedDescription)
        }
    }

    private func fetchJSON(url: URL, token: String, accountID: String?) async throws -> Any {
        try await fetchChatGPTBackendJSON(url: url, token: token, accountID: accountID, wham: true)
    }
}

struct TomoParser {
    func parse(usagePayload: Any, resetCreditsPayload: Any?, email: String?, accountName: String?) -> CodexUsageSnapshot {
        let root = usagePayload as? [String: Any] ?? [:]
        let usage = root["usage"] as? [String: Any] ?? root
        let limitWindows = (usage["limits"] as? [Any] ?? []).compactMap(readQuotaWindow)
        let rateLimitWindows = readRateLimitWindows(from: root) + readRateLimitWindows(from: usage)
        let primary = rateLimitWindows.first { $0.role == .primary }
            ?? limitWindows.first { $0.code == "5h" }
        let weekly = rateLimitWindows.first { $0.role == .secondary }
            ?? limitWindows.first { $0.code == "7d" }
        let resetCards = readResetCards(from: resetCreditsPayload) ?? readResetCards(from: root) ?? []
        let planName = (root["plan_type"] as? String) ?? (root["planType"] as? String) ?? "Codex"

        return CodexUsageSnapshot(
            accountName: accountName ?? readAccountName(root),
            accountEmail: email ?? "OpenAI 账号",
            workspaceName: readWorkspaceName(root) ?? "ChatGPT",
            planName: planName,
            shortWindow: primary.map(toUsageWindow),
            weekly: toUsageWindow(weekly, label: "周额度"),
            credits: CreditBalance(balance: resetCards.count, expiresAt: formatReset(resetCards.first?.expiresAt)),
            resetCoupons: resetCards.enumerated().map { index, card in
                ResetCoupon(
                    id: UUID(uuidString: stableUUIDSeed(card.id)) ?? UUID(),
                    name: "重置券",
                    count: 1,
                    expiresAt: formatReset(card.expiresAt),
                    source: card.profileUserID ?? "Codex",
                    title: card.title,
                    description: card.description,
                    grantedAt: card.grantedAt.map { formatReset($0) },
                    profileUserID: card.profileUserID,
                    profileImageURL: card.profileImageURL,
                    status: card.status,
                    resetType: card.resetType
                )
            },
            fetchedAt: Date(),
            refreshState: "成功",
            sourceURL: "https://chatgpt.com/backend-api/wham/usage"
        )
    }

    func parseSubscription(_ payload: Any) -> (activeUntilISO: String?, willRenew: Bool?) {
        guard let root = payload as? [String: Any] else {
            return (nil, nil)
        }
        let activeUntil = (root["active_until"] as? String) ?? (root["activeUntil"] as? String)
        let trimmed = activeUntil?.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeUntilISO = (trimmed?.isEmpty == false) ? trimmed : nil
        return (activeUntilISO, parseWillRenew(root["will_renew"] ?? root["willRenew"]))
    }

    private func parseWillRenew(_ value: Any?) -> Bool? {
        switch value {
        case let flag as Bool:
            return flag
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes":
                return true
            case "0", "false", "no":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private func readQuotaWindow(_ input: Any) -> ParsedQuotaWindow? {
        guard let object = input as? [String: Any] else { return nil }
        guard let code = object["window"] as? String, code == "5h" || code == "7d" else { return nil }
        guard let used = number(object["used"]), let limit = number(object["limit"]), limit > 0 else { return nil }

        return ParsedQuotaWindow(
            code: code,
            label: code == "5h" ? "5 小时" : "周额度",
            role: nil,
            used: used,
            limit: limit,
            percentUsed: (used / limit) * 100,
            resetAt: readDate(object["resetAt"] ?? object["reset_at"] ?? object["resets_at"])
                ?? readResetAfter(object["reset_after_seconds"] ?? object["reset_after"])
        )
    }

    private func readRateLimitWindows(from root: [String: Any]) -> [ParsedQuotaWindow] {
        guard let rateLimit = root["rate_limit"] as? [String: Any] else { return [] }

        return [
            readRateLimitWindow(rateLimit["primary_window"], role: .primary),
            readRateLimitWindow(rateLimit["secondary_window"], role: .secondary)
        ].compactMap { $0 }
    }

    private func readRateLimitWindow(_ input: Any?, role: ParsedQuotaWindow.Role) -> ParsedQuotaWindow? {
        guard let object = input as? [String: Any] else { return nil }
        let seconds = number(object["limit_window_seconds"]) ?? 0
        let code = role == .primary ? "primary" : "secondary"
        let usedPercent = number(object["used_percent"]) ?? 0

        return ParsedQuotaWindow(
            code: code,
            label: quotaWindowLabel(seconds: seconds, role: role),
            role: role,
            used: usedPercent,
            limit: 100,
            percentUsed: usedPercent,
            resetAt: readDate(object["reset_at"] ?? object["resets_at"])
                ?? readResetAfter(object["reset_after_seconds"] ?? object["reset_after"])
        )
    }

    private func readResetCards(from payload: Any?) -> [ParsedResetCard]? {
        guard let root = payload as? [String: Any] else { return nil }
        let sources = [root, root["usage"] as? [String: Any]].compactMap { $0 }

        for source in sources {
            let raw = source["credits"]
                ?? source["renewal_credits"]
                ?? source["renewalCredits"]
                ?? source["reset_credits"]
                ?? source["resetCredits"]
                ?? source["bonus_credits"]
                ?? source["bonusCredits"]
                ?? source["gift_credits"]
                ?? source["giftCredits"]
                ?? source["data"]

            guard let items = raw as? [Any] else { continue }
            let cards = items.enumerated().compactMap { index, item in
                readResetCard(item, fallbackID: "card-\(index)")
            }
            .filter { isAvailableResetCard($0) }
            .sorted { $0.expiresAt < $1.expiresAt }

            return cards
        }

        return nil
    }

    private func readResetCard(_ input: Any, fallbackID: String) -> ParsedResetCard? {
        guard let object = input as? [String: Any] else { return nil }
        guard let expiresAt = readDate(object["expires_at"] ?? object["expiresAt"] ?? object["expires"] ?? object["expiry"]) else {
            return nil
        }

        let id = (object["id"] as? String)
            ?? (object["credit_id"] as? String)
            ?? (object["creditId"] as? String)
            ?? (object["reset_credit_id"] as? String)
            ?? (object["resetCreditId"] as? String)
            ?? fallbackID
        let status = (object["status"] as? String) ?? (object["state"] as? String)
        let grantedAt = readDate(object["granted_at"] ?? object["grantedAt"])
        let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = (object["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let profileUserID = (object["profile_user_id"] as? String) ?? (object["profileUserId"] as? String)
        let profileImageURL = (object["profile_image_url"] as? String) ?? (object["profileImageUrl"] as? String)
        let resetType = (object["reset_type"] as? String) ?? (object["resetType"] as? String)

        return ParsedResetCard(
            id: id,
            expiresAt: expiresAt,
            grantedAt: grantedAt,
            status: status,
            title: title?.isEmpty == false ? title : nil,
            description: description?.isEmpty == false ? description : nil,
            profileUserID: profileUserID,
            profileImageURL: profileImageURL,
            resetType: resetType
        )
    }

    private func isAvailableResetCard(_ card: ParsedResetCard) -> Bool {
        let parser = ISO8601DateFormatter()
        guard let expiry = parser.date(from: card.expiresAt), expiry > Date() else {
            return false
        }

        let status = card.status?.lowercased()
        return status == nil || !["redeemed", "used", "consumed", "expired", "unavailable"].contains(status!)
    }

    private func toUsageWindow(_ window: ParsedQuotaWindow) -> UsageWindow {
        toUsageWindow(window, label: window.label)
    }

    private func toUsageWindow(_ window: ParsedQuotaWindow?, label: String) -> UsageWindow {
        guard let window else {
            return UsageWindow(label: label, remaining: 0, total: 0, resetsAt: "未知")
        }

        let remaining = max(0, Int((window.limit - window.used).rounded()))
        let total = max(1, Int(window.limit.rounded()))
        return UsageWindow(
            label: label,
            remaining: remaining,
            total: total,
            resetsAt: formatReset(window.resetAt)
        )
    }

    private func quotaWindowLabel(seconds: Double, role: ParsedQuotaWindow.Role) -> String {
        guard seconds > 0 else {
            return role == .primary ? "主额度" : "次级额度"
        }

        if abs(seconds - 18_000) <= 60 {
            return "5 小时"
        }
        if abs(seconds - 604_800) <= 3_600 {
            return "周额度"
        }
        if seconds.truncatingRemainder(dividingBy: 86_400) == 0 {
            return "\(Int(seconds / 86_400)) 天"
        }
        if seconds.truncatingRemainder(dividingBy: 3_600) == 0 {
            return "\(Int(seconds / 3_600)) 小时"
        }
        return role == .primary ? "主额度" : "次级额度"
    }

    private func readWorkspaceName(_ root: [String: Any]) -> String? {
        (root["workspace_name"] as? String)
            ?? (root["workspaceName"] as? String)
            ?? ((root["workspace"] as? [String: Any])?["name"] as? String)
    }

    private func readAccountName(_ root: [String: Any]) -> String? {
        (root["account_name"] as? String)
            ?? (root["accountName"] as? String)
            ?? (root["user_name"] as? String)
            ?? (root["userName"] as? String)
            ?? ((root["account"] as? [String: Any])?["name"] as? String)
            ?? ((root["user"] as? [String: Any])?["name"] as? String)
    }

    private func number(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private func readDate(_ value: Any?) -> String? {
        if let number = number(value), number > 0 {
            let seconds = number > 10_000_000_000 ? number / 1000 : number
            return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
        }

        if let string = value as? String {
            let isoFormatter = ISO8601DateFormatter()
            if let date = isoFormatter.date(from: string) {
                return isoFormatter.string(from: date)
            }

            let fallback = DateFormatter()
            fallback.locale = Locale(identifier: "en_US_POSIX")
            fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
            if let date = fallback.date(from: string) {
                return isoFormatter.string(from: date)
            }
        }

        return nil
    }

    private func readResetAfter(_ value: Any?) -> String? {
        guard let seconds = number(value), seconds > 0 else { return nil }
        return ISO8601DateFormatter().string(from: Date().addingTimeInterval(seconds))
    }

    private func formatReset(_ isoString: String?) -> String {
        guard let isoString, let date = ISO8601DateFormatter().date(from: isoString) else {
            return "未知"
        }

        return UsageDateFormat.display(date)
    }

    private func stableUUIDSeed(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
    }
}

struct ParsedQuotaWindow {
    enum Role {
        case primary
        case secondary
    }

    let code: String
    let label: String
    let role: Role?
    let used: Double
    let limit: Double
    let percentUsed: Double
    let resetAt: String?
}

struct ParsedResetCard {
    let id: String
    let expiresAt: String
    let grantedAt: String?
    let status: String?
    let title: String?
    let description: String?
    let profileUserID: String?
    let profileImageURL: String?
    let resetType: String?
}

struct CodexOAuthToken: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var idToken: String?
    var expiresAt: Date
    var email: String?
    var displayName: String?
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let idToken: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresIn = "expires_in"
    }
}

struct CodexOAuthTokenStore: Sendable {
    private let scopedFileURL: URL?

    init(fileURL: URL? = nil) {
        scopedFileURL = fileURL
    }

    private var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private var fileURL: URL {
        if let scopedFileURL { return scopedFileURL }
        return supportDirectory
            .appendingPathComponent("Tomo", isDirectory: true)
            .appendingPathComponent("oauth_token.json")
    }

    private var legacyFileURL: URL {
        supportDirectory
            .appendingPathComponent("CodexLight", isDirectory: true)
            .appendingPathComponent("oauth_token.json")
    }

    func hasStoredToken() -> Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
            || (scopedFileURL == nil && FileManager.default.fileExists(atPath: legacyFileURL.path))
    }

    func load() -> CodexOAuthToken? {
        if let token = loadFromFile() {
            return token
        }

        if scopedFileURL == nil, let token = loadFromFile(at: legacyFileURL) {
            save(token)
            return token
        }

        if scopedFileURL == nil, let legacyToken = CodexOAuthLegacyKeychain().load() {
            save(legacyToken)
            CodexOAuthLegacyKeychain().clear()
            return legacyToken
        }

        return nil
    }

    func save(_ token: CodexOAuthToken) {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(token)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            // Token persistence failures should not block showing fresh usage data.
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        if scopedFileURL == nil {
            try? FileManager.default.removeItem(at: legacyFileURL)
            CodexOAuthLegacyKeychain().clear()
        }
    }

    private func loadFromFile() -> CodexOAuthToken? {
        loadFromFile(at: fileURL)
    }

    private func loadFromFile(at url: URL) -> CodexOAuthToken? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CodexOAuthToken.self, from: data)
    }
}

/// One-time migration path for tokens saved before local file storage.
private struct CodexOAuthLegacyKeychain: Sendable {
    private let service = "com.qiizo.codex-light"
    private let account = "codexOAuth"

    func load() -> CodexOAuthToken? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CodexOAuthToken.self, from: data)
    }

    func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

final class OAuthCallbackServer: @unchecked Sendable {
    private let expectedState: String
    private let stateLock = NSLock()
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?

    init(expectedState: String) {
        self.expectedState = expectedState
    }

    func waitForCode(timeoutSeconds: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            stateLock.lock()
            self.continuation = continuation
            stateLock.unlock()
            startListener()

            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                self?.finish(.failure(CodexUsageError.oauthTimedOut))
            }
        }
    }

    func cancel() {
        finish(.failure(CodexUsageError.oauthCancelled))
    }

    private func startListener() {
        do {
            let port = NWEndpoint.Port(rawValue: 1455)!
            let listener = try NWListener(using: .tcp, on: port)
            stateLock.lock()
            guard continuation != nil else {
                stateLock.unlock()
                listener.cancel()
                return
            }
            self.listener = listener
            stateLock.unlock()
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    self?.finish(.failure(error))
                }
            }
            listener.start(queue: .global())
        } catch {
            finish(.failure(error))
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                self?.send("Bad request", status: 400, on: connection)
                self?.finish(.failure(CodexUsageError.oauthCallbackInvalid))
                return
            }

            let firstLine = request.components(separatedBy: "\r\n").first ?? ""
            let path = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let components = URLComponents(string: "http://localhost:1455\(path)")

            guard components?.path == "/auth/callback" else {
                self.send("Not found", status: 404, on: connection)
                return
            }

            let code = components?.queryItems?.first { $0.name == "code" }?.value
            let state = components?.queryItems?.first { $0.name == "state" }?.value
            let error = components?.queryItems?.first { $0.name == "error" }?.value

            if let error {
                self.sendPage(.error("授权失败：\(error)"), status: 400, on: connection)
                self.finish(.failure(CodexUsageError.oauthCallbackInvalid))
            } else if let code, state == self.expectedState {
                self.sendPage(.success, status: 200, on: connection)
                self.finish(.success(code))
            } else {
                self.sendPage(.error("OAuth 回调无效，请返回应用重新登录。"), status: 400, on: connection)
                self.finish(.failure(CodexUsageError.oauthCallbackInvalid))
            }
        }
    }

    private enum OAuthCallbackPage {
        case success
        case error(String)

        var html: String {
            switch self {
            case .success:
                OAuthCallbackHTML.success(provider: .codex)
            case .error(let message):
                OAuthCallbackHTML.error(message: htmlEscape(message))
            }
        }
    }

    private func sendPage(_ page: OAuthCallbackPage, status: Int, on connection: NWConnection) {
        let html = page.html
        let statusText = status == 200 ? "OK" : "Error"
        let response = """
        HTTP/1.1 \(status) \(statusText)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(html.utf8.count)\r
        Connection: close\r
        \r
        \(html)
        """

        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func send(_ body: String, status: Int, on connection: NWConnection) {
        sendPage(.error(body), status: status, on: connection)
    }

    private func finish(_ result: Result<String, Error>) {
        stateLock.lock()
        guard let continuation else {
            stateLock.unlock()
            return
        }
        self.continuation = nil
        let listener = listener
        self.listener = nil
        stateLock.unlock()
        listener?.cancel()

        switch result {
        case .success(let code):
            continuation.resume(returning: code)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

enum OAuthCallbackProvider {
    case codex
    case gemini

    var assetDirectory: String {
        switch self {
        case .codex: "codex"
        case .gemini: "google-gemini"
        }
    }

    var pageTitle: String {
        switch self {
        case .codex: "Codex 连接成功 · Tomo"
        case .gemini: "Gemini 连接成功 · Tomo"
        }
    }

    var subtitle: String {
        switch self {
        case .codex: "Tomo 已连接你的 OpenAI Codex 账号。"
        case .gemini: "Tomo 已连接你的 Google Gemini 账号。"
        }
    }

    var hint: String {
        switch self {
        case .codex: "你可以关闭此页面，返回菜单栏查看 5 小时额度、周额度和重置券。"
        case .gemini: "你可以关闭此页面，返回 Tomo 查看 5 小时额度、周额度和可用模型。"
        }
    }
}

enum OAuthCallbackHTML {
    static func success(provider: OAuthCallbackProvider) -> String {
        let logoSource = brandLogoDataURL(provider: provider)
        return """
    <!doctype html>
    <html lang="zh-CN">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>\(provider.pageTitle)</title>
      <style>
        :root {
          color-scheme: light;
          --ink: #171717;
          --muted: #3d4350;
          --line: rgba(23, 23, 23, 0.14);
          --surface: #f8f9fb;
        }
        * { box-sizing: border-box; }
        body {
          margin: 0;
          padding: 96px 24px 24px;
          font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;
          color: var(--ink);
          background: #f3f5f8;
        }
        .card {
          width: min(420px, 100%);
          margin: 0 auto;
          padding: 34px 28px 28px;
          border: 1px solid var(--line);
          border-radius: 18px;
          background: rgba(255, 255, 255, 0.88);
          box-shadow: 0 18px 50px rgba(40, 33, 20, 0.12);
          text-align: center;
        }
        .brand-badge {
          width: 64px;
          height: 64px;
          margin: 0 auto 16px;
          padding: 6px;
          border: 1px solid var(--line);
          border-radius: 16px;
          background: #fff;
          display: grid;
          place-items: center;
          box-shadow: 0 8px 20px rgba(23, 23, 23, 0.08);
        }
        .brand-badge img { width: 100%; height: 100%; object-fit: contain; border-radius: 11px; }
        h1 {
          margin: 0 0 8px;
          font-size: 24px;
          line-height: 1.2;
          letter-spacing: -0.02em;
        }
        .subtitle {
          margin: 0;
          color: var(--muted);
          font-size: 15px;
          line-height: 1.6;
        }
        .hint {
          margin: 18px 0 0;
          padding: 12px 14px;
          border-radius: 10px;
          background: var(--surface);
          border: 1px solid var(--line);
          color: var(--muted);
          font-size: 13px;
          line-height: 1.5;
        }
      </style>
    </head>
    <body>
      <main class="card">
        <div class="brand-badge" aria-hidden="true">
          <img src="\(logoSource)" alt="" />
        </div>
        <h1>连接成功</h1>
        <p class="subtitle">\(provider.subtitle)</p>
        <p class="hint">\(provider.hint)</p>
      </main>
    </body>
    </html>
    """
    }

    private static func brandLogoDataURL(provider: OAuthCallbackProvider) -> String {
        let url = Bundle.main.resourceURL?
            .appendingPathComponent("BrandAssets/catalog", isDirectory: true)
            .appendingPathComponent(provider.assetDirectory, isDirectory: true)
            .appendingPathComponent("app-icon.png")
        guard let url, let data = try? Data(contentsOf: url) else {
            // 仅用于未打包的开发运行；正式 App 会从 BrandAssets 嵌入官方图标。
            return "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'%3E%3Crect width='64' height='64' rx='14' fill='%23f3f5f8'/%3E%3Cpath d='M20 32h24M32 20v24' stroke='%23171717' stroke-width='4' stroke-linecap='round'/%3E%3C/svg%3E"
        }
        return "data:image/png;base64,\(data.base64EncodedString())"
    }

    static func error(message: String) -> String {
        """
        <!doctype html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <title>连接失败 · Tomo</title>
          <style>
            :root {
              color-scheme: light;
              --ink: #171717;
              --muted: #3d4350;
              --line: rgba(23, 23, 23, 0.14);
              --red: #e1382b;
              --surface: #f8f9fb;
            }
            * { box-sizing: border-box; }
            body {
              margin: 0;
              padding: 96px 24px 24px;
              font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;
              color: var(--ink);
              background: #f3f5f8;
            }
            .card {
              width: min(420px, 100%);
              margin: 0 auto;
              padding: 32px 28px;
              border: 1px solid var(--line);
              border-radius: 18px;
              background: rgba(255, 255, 255, 0.88);
              box-shadow: 0 18px 50px rgba(40, 33, 20, 0.12);
              text-align: center;
            }
            .error-badge {
              width: 56px;
              height: 56px;
              margin: 0 auto 16px;
              border-radius: 999px;
              background: rgba(225, 56, 43, 0.10);
              display: grid;
              place-items: center;
              font-size: 28px;
              line-height: 1;
              color: var(--red);
            }
            h1 { margin: 0 0 8px; font-size: 24px; }
            p {
              margin: 0;
              color: var(--muted);
              font-size: 15px;
              line-height: 1.6;
            }
            .message {
              margin-top: 16px;
              padding: 12px 14px;
              border-radius: 10px;
              background: var(--surface);
              border: 1px solid var(--line);
              font-size: 13px;
              text-align: left;
              word-break: break-word;
            }
          </style>
        </head>
        <body>
          <main class="card">
            <div class="error-badge" aria-hidden="true">!</div>
            <h1>连接失败</h1>
            <p>请返回 Tomo 重新尝试登录。</p>
            <p class="message">\(message)</p>
          </main>
        </body>
        </html>
        """
    }
}

private func htmlEscape(_ text: String) -> String {
    text
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}

private func formBody(_ fields: [String: String]) -> Data {
    let body = fields
        .map { key, value in
            "\(urlEncode(key))=\(urlEncode(value))"
        }
        .joined(separator: "&")
    return Data(body.utf8)
}

private func randomBase64URL(byteCount: Int) -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
    return base64URL(Data(bytes))
}

private func sha256Base64URL(_ value: String) -> String {
    let digest = SHA256.hash(data: Data(value.utf8))
    return base64URL(Data(digest))
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func urlEncode(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
}

private func readProfileEmail(from token: String?) -> String? {
    readJWTClaim(token, claim: "email")
        ?? readJWTClaim(token, namespace: "https://api.openai.com/profile", claim: "email")
}

private func readProfileName(from token: String?) -> String? {
    readJWTClaim(token, claim: "name")
        ?? readJWTClaim(token, claim: "preferred_username")
        ?? readJWTClaim(token, claim: "nickname")
        ?? readJWTClaim(token, namespace: "https://api.openai.com/profile", claim: "name")
        ?? readJWTClaim(token, namespace: "https://api.openai.com/profile", claim: "preferred_username")
}

private func readJWTClaim(_ token: String?, namespace: String? = nil, claim: String) -> String? {
    guard let token else { return nil }
    let pieces = token.split(separator: ".")
    guard pieces.count >= 2 else { return nil }

    var payload = String(pieces[1])
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")

    while payload.count % 4 != 0 {
        payload.append("=")
    }

    guard let data = Data(base64Encoded: payload),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return nil
    }

    if let namespace {
        return (json[namespace] as? [String: Any])?[claim] as? String
    }

    return json[claim] as? String
}
