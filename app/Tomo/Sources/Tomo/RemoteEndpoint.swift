import Foundation
import Network

enum RemoteEndpoint {
    static func valid(_ endpoint: URL) -> Bool {
        guard let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme, ["http", "https"].contains(scheme),
              parts.host?.isEmpty == false, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/" else { return false }
        return (1...65535).contains(parts.port ?? (scheme == "http" ? 80 : 443))
    }
    static func port(_ endpoint: URL) -> Int { endpoint.port ?? (endpoint.scheme == "http" ? 80 : 443) }

    /// A loopback URL must not accidentally create an all-interface listener.
    static func loopbackBindHost(_ endpoint: URL) -> NWEndpoint.Host? {
        guard let host = endpoint.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) else { return nil }
        if host == "localhost" || host == "localhost." { return .ipv4(.loopback) }
        if let address = IPv4Address(host), address.rawValue.first == 127 { return .ipv4(address) }
        if let address = IPv6Address(host) {
            let bytes = Array(address.rawValue)
            if bytes == Array(IPv6Address.loopback.rawValue) ||
                (bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 255 && bytes[11] == 255 && bytes[12] == 127) {
                return .ipv6(address)
            }
        }
        return nil
    }
}
