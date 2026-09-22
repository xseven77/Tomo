import Foundation
import XCTest
@testable import Tomo

final class RelayNetworkTests: XCTestCase {
    func testProviderProxyOnlyAllowsInformationEndpoints() {
        XCTAssertTrue(ProviderProxyPolicy.allows(URL(string: "https://chatgpt.com/backend-api/subscriptions?account_id=123")!, method: "GET"))
        XCTAssertTrue(ProviderProxyPolicy.allows(URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!, method: "POST"))
        XCTAssertTrue(ProviderProxyPolicy.allows(URL(string: "https://api.deepseek.com/user/balance")!, method: "GET"))
        for value in ["http://api.deepseek.com/user/balance", "https://api.deepseek.com:8443/user/balance", "https://api.deepseek.com/api/v1/snapshot", "https://api.deepseek.com.evil.example/user/balance", "http://192.168.1.2:58350/api/v1/snapshot", "https://chatgpt.com/backend-api/conversation", "https://user:pass@api.deepseek.com/user/balance"] {
            XCTAssertFalse(ProviderProxyPolicy.allows(URL(string: value)!, method: "GET"), value)
        }
        XCTAssertFalse(ProviderProxyPolicy.allows(URL(string: "https://api.deepseek.com/user/balance")!, method: "POST"))
    }
    func testLANRelayBypassesExternalProxy() {
        for host in ["192.168.10.228", "10.1.2.3", "172.16.1.2", "172.31.2.3", "127.0.0.1", "localhost", "desktop.local"] {
            let url = URL(string: "http://\(host):58350/api/v1/snapshot")!
            XCTAssertTrue(URLSession.isLocalRelayTarget(url), host)
            XCTAssertTrue(URLSession.codexlingRelay(for: url).configuration.proxyConfigurations.isEmpty)
            XCTAssertEqual(URLSession.codexlingRelay(for: url).configuration.connectionProxyDictionary?.count, 0)
        }
        for host in ["172.15.1.2", "172.32.1.2", "192.169.1.2", "chatgpt.com", "www.googleapis.com", "[2001:4860:4860::8888]"] {
            XCTAssertFalse(URLSession.isLocalRelayTarget(URL(string: "https://\(host)/")!), host)
        }
    }
}
