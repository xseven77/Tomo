import Foundation
import Darwin

/// Utility for inspecting local network interfaces and resolving LAN IPv4 address.
public enum GatewayNetworkInfo: Sendable {
    /// Detects the primary local area network (LAN) IPv4 address of this machine.
    /// Prioritizes physical network adapters (en0, en1, etc.) over tunnels/bridges.
    public static func currentLANIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var en0IP: String?
        var enIPs: [String] = []
        var otherIPs: [String] = []

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee

            // Check for IPv4: AF_INET
            if addr.sa_family == UInt8(AF_INET) {
                // Interface must be UP, RUNNING and not LOOPBACK
                if (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING) &&
                   (flags & IFF_LOOPBACK) == 0 {
                    let name = String(cString: ptr.pointee.ifa_name)
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(
                        ptr.pointee.ifa_addr,
                        socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    ) == 0 {
                        let ip = hostname.withUnsafeBufferPointer { ptr in
                            ptr.baseAddress.map { String(cString: $0) } ?? ""
                        }
                        if ip != "127.0.0.1" && ip != "0.0.0.0" && !ip.isEmpty {
                            if name == "en0" {
                                en0IP = ip
                            } else if name.hasPrefix("en") {
                                enIPs.append(ip)
                            } else {
                                otherIPs.append(ip)
                            }
                        }
                    }
                }
            }
        }

        return en0IP ?? enIPs.first ?? otherIPs.first
    }
}
