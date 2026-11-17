import Foundation
import Testing
@testable import Tomo

struct RemoteHostConfigurationTests {
    @Test func exportsOnlyPublicNativeHostFields() throws {
        let id = UUID()
        let text = try RemoteHostConfiguration.encode(serverId: id, name: "工作电脑",
            endpoint: #require(URL(string: "https://desktop.example.test:9443")),
            scopes: ["session.read", "discovery"], runtimes: [.init(agentId: "agent.chatgpt", runtimeId: "rt_live")])
        let value = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(Set(value.keys) == ["version", "hosts"])
        #expect(value["version"] as? Int == 1)
        let hosts = try #require(value["hosts"] as? [[String: Any]])
        #expect(hosts.count == 1)
        let host = try #require(hosts.first)
        #expect(Set(host.keys) == ["id", "name", "endpoint", "scopes", "resources"])
        #expect(host["id"] as? String == id.uuidString.lowercased())
        #expect(host["scopes"] as? [String] == ["discovery", "session.read"])
        #expect(host["resources"] as? [[String: String]] == [["kind": "runtime", "agentId": "agent.chatgpt", "runtimeId": "rt_live"]])
    }

    @Test func exportsExplicitHTTPAndHTTPSOriginsWithoutChangingAuthority() throws {
        for endpoint in ["http://192.168.10.7:58350", "http://desktop.test", "http://desktop.test:443", "https://desktop.test:80"] {
            let text = try RemoteHostConfiguration.encode(serverId: UUID(), name: "Desktop", endpoint: #require(URL(string: endpoint)),
                scopes: ["discovery"], runtimes: [.init(agentId: "agent.chatgpt", runtimeId: "rt_live")])
            let value = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            let host = try #require((value["hosts"] as? [[String: Any]])?.first)
            #expect(host["endpoint"] as? String == endpoint)
            #expect(host["scopes"] as? [String] == ["discovery"])
        }
    }

    @Test func rejectsUnsafeOriginsAndUnboundedResources() throws {
        func encode(_ endpoint: String = "https://desktop.test", name: String = "Desktop",
                    scopes: [String] = ["discovery"], runtimes: [RemoteHostConfiguration.Runtime] = [.init(agentId: "agent.chatgpt", runtimeId: "rt_live")]) throws -> String {
            try RemoteHostConfiguration.encode(serverId: UUID(), name: name, endpoint: #require(URL(string: endpoint)), scopes: scopes, runtimes: runtimes)
        }
        for endpoint in ["ftp://desktop.test", "https://user@desktop.test", "https://desktop.test/path", "https://desktop.test?token=x", "https://desktop.test#x", "https://desktop.test:0"] {
            #expect(throws: (any Error).self) { try encode(endpoint) }
        }
        #expect(throws: (any Error).self) { try encode(name: "Desktop\u{85}") }
        #expect(throws: (any Error).self) { try encode(scopes: ["*"]) }
        #expect(throws: (any Error).self) { try encode(scopes: ["discovery", "discovery"]) }
        #expect(throws: (any Error).self) { try encode(runtimes: []) }
        #expect(throws: (any Error).self) { try encode(runtimes: [.init(agentId: "agent.chatgpt", runtimeId: "*")]) }
        #expect(throws: (any Error).self) { try encode(runtimes: Array(repeating: .init(agentId: "agent.chatgpt", runtimeId: "rt_live"), count: 2)) }
    }
}
