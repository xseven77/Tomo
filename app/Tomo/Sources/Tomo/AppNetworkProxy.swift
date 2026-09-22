import Foundation
import Network

enum ProviderProxyPolicy {
    static func allows(_ url: URL, method: String) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.fragment == nil, url.port == nil || url.port == 443 else { return false }
        switch (url.host?.lowercased(), method, url.path) {
        case ("chatgpt.com", "GET", "/backend-api/wham/usage"),
             ("chatgpt.com", "GET", "/backend-api/subscriptions"),
             ("chatgpt.com", "GET", "/backend-api/wham/rate-limit-reset-credits"),
             ("daily-cloudcode-pa.googleapis.com", "POST", "/v1internal:loadCodeAssist"),
             ("daily-cloudcode-pa.googleapis.com", "POST", "/v1internal:retrieveUserQuotaSummary"),
             ("api.deepseek.com", "GET", "/user/balance"):
            return true
        default: return false
        }
    }
}

final class ProviderProxyRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward supplier credentials to a redirect destination.
        completionHandler(nil)
    }
}

enum AppNetworkProxyProtocol: String, CaseIterable, Identifiable {
    case socks5h
    case http

    var id: String { rawValue }
    var title: String { self == .socks5h ? "SOCKS5h（推荐）" : "HTTP" }
}

enum AppNetworkProxyDefaultsKey {
    static let enabled = "codexling.networkProxyEnabled"
    static let protocolName = "codexling.networkProxyProtocol"
    static let host = "codexling.networkProxyHost"
    static let port = "codexling.networkProxyPort"
}

struct AppNetworkProxyConfiguration: Equatable {
    private static let bypassHosts = [
        "localhost", "127.0.0.1", "::1", "*.local",
        "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16"
    ]

    var enabled: Bool
    var protocolName: AppNetworkProxyProtocol
    var host: String
    var port: Int

    static func load(from defaults: UserDefaults = .standard) -> Self {
        let rawProtocol = defaults.string(forKey: AppNetworkProxyDefaultsKey.protocolName)
        return Self(
            enabled: defaults.bool(forKey: AppNetworkProxyDefaultsKey.enabled),
            protocolName: rawProtocol.flatMap(AppNetworkProxyProtocol.init(rawValue:)) ?? .socks5h,
            host: defaults.string(forKey: AppNetworkProxyDefaultsKey.host) ?? "127.0.0.1",
            port: defaults.object(forKey: AppNetworkProxyDefaultsKey.port) as? Int ?? 7897
        )
    }

    var validatedHost: String? {
        let value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.contains(where: { $0.isWhitespace || $0 == "/" || $0 == ":" }) else {
            return nil
        }
        return value
    }

    var proxyURL: String? {
        guard enabled, let host = validatedHost, (1...65_535).contains(port) else { return nil }
        return "\(protocolName.rawValue)://\(host):\(port)"
    }

    var urlSessionProxyDictionary: [AnyHashable: Any] {
        guard enabled, let host = validatedHost, (1...65_535).contains(port) else { return [:] }
        switch protocolName {
        case .socks5h:
            return [
                "SOCKSEnable": 1,
                "SOCKSProxy": host,
                "SOCKSPort": port,
                "ExceptionsList": Self.bypassHosts,
                "ExcludeSimpleHostnames": 1
            ]
        case .http:
            return [
                "HTTPEnable": 1,
                "HTTPProxy": host,
                "HTTPPort": port,
                "HTTPSEnable": 1,
                "HTTPSProxy": host,
                "HTTPSPort": port,
                "ExceptionsList": Self.bypassHosts,
                "ExcludeSimpleHostnames": 1
            ]
        }
    }

    var urlSessionProxyConfiguration: ProxyConfiguration? {
        guard enabled, let host = validatedHost, (1...65_535).contains(port),
              let proxyPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return nil
        }
        let endpoint = NWEndpoint.hostPort(host: .init(host), port: proxyPort)
        var configuration: ProxyConfiguration
        switch protocolName {
        case .socks5h:
            configuration = ProxyConfiguration(socksv5Proxy: endpoint)
        case .http:
            configuration = ProxyConfiguration(httpCONNECTProxy: endpoint)
        }
        configuration.excludedDomains = ["localhost", "127.0.0.1", "*.local"]
        return configuration
    }

    func applying(to environment: [String: String]) -> [String: String] {
        var environment = environment
        guard let proxyURL else { return environment }
        let proxyKeys = [
            "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
            "http_proxy", "https_proxy", "all_proxy", "CODEXLING_GEMINI_PROXY"
        ]
        for key in proxyKeys { environment[key] = proxyURL }
        let noProxy = Self.bypassHosts.joined(separator: ",")
        environment["NO_PROXY"] = noProxy
        environment["no_proxy"] = noProxy
        return environment
    }
}

private final class TomoExternalSessionHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var session = TomoExternalSessionHolder.makeSession()

    func current() -> URLSession {
        lock.withLock { session }
    }

    func reload() {
        let replacement = Self.makeSession()
        let previous = lock.withLock {
            let previous = session
            session = replacement
            return previous
        }
        previous.finishTasksAndInvalidate()
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.applyTomoExternalProxy()
        return URLSession(configuration: configuration)
    }
}

extension URLSession {
    private static let codexlingExternalHolder = TomoExternalSessionHolder()

    private static let codexlingLocal: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.proxyConfigurations = []
        return URLSession(configuration: configuration)
    }()

    static func codexlingRelay(for target: URL) -> URLSession {
        isLocalRelayTarget(target) ? codexlingLocal : codexlingExternal
    }

    static func isLocalRelayTarget(_ target: URL) -> Bool {
        guard let host = target.host?.lowercased() else { return false }
        if host == "localhost" || host == "::1" || host == "[::1]" || host.hasSuffix(".local") || (!host.contains(".") && !host.contains(":")) { return true }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        return octets[0] == 10 || octets[0] == 127
            || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 169 && octets[1] == 254)
    }

    static var codexlingExternal: URLSession { codexlingExternalHolder.current() }
    static func reloadTomoExternalProxy() { codexlingExternalHolder.reload() }
}

extension URLSessionConfiguration {
    func applyTomoExternalProxy() {
        let proxy = AppNetworkProxyConfiguration.load()
        if let configuration = proxy.urlSessionProxyConfiguration {
            proxyConfigurations = [configuration]
        } else if proxy.enabled {
            connectionProxyDictionary = proxy.urlSessionProxyDictionary
        }
    }
}

enum AppNetworkProxyConnectivityTester {
    static func test(using proxy: AppNetworkProxyConfiguration) async -> String {
        guard proxy.enabled else { return "请先开启网络代理" }
        guard proxy.proxyURL != nil else { return "代理地址或端口无效" }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        if let proxyConfiguration = proxy.urlSessionProxyConfiguration {
            configuration.proxyConfigurations = [proxyConfiguration]
        } else {
            configuration.connectionProxyDictionary = proxy.urlSessionProxyDictionary
        }

        var request = URLRequest(url: URL(string: "https://www.gstatic.com/generate_204")!)
        request.timeoutInterval = 8
        do {
            let (_, response) = try await URLSession(configuration: configuration).data(for: request)
            guard let response = response as? HTTPURLResponse else {
                return "代理未返回有效的 HTTP 响应"
            }
            if (200..<400).contains(response.statusCode) {
                return "代理连通正常（HTTP \(response.statusCode)）"
            }
            return "代理已连接，但目标返回 HTTP \(response.statusCode)"
        } catch {
            return "代理连接失败：\(error.localizedDescription)"
        }
    }
}
