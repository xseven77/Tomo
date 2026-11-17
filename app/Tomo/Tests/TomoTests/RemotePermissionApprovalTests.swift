import Foundation
import Testing
@testable import Tomo

struct RemotePermissionApprovalTests {
    private var profile: AgentJSON {
        .object(["fileSystem": .object([
            "entries": .array([
                .object(["access": .string("read"), "path": .object(["type": .string("special"), "value": .object(["kind": .string("root")])])]),
                .object(["access": .string("write"), "path": .object(["type": .string("glob_pattern"), "pattern": .string("/workspace/**/*.ts")])]),
                .object(["access": .string("deny"), "path": .object(["type": .string("path"), "path": .string("/workspace/secrets")])])
            ]), "globScanMaxDepth": .integer(5), "read": .array([.string("/compat/read")]), "write": .array([.string("/compat/write")])]),
            "network": .object(["enabled": .bool(true)])])
    }
    private func map(_ permissions: AgentJSON, extra: [String: AgentJSON] = [:]) throws -> ChatGPTMappedServerRequest {
        let ref = RemoteSessionRef(serverId: "server", agentId: "agent.chatgpt", runtimeId: "runtime", sessionId: "session")
        let projector = ChatGPTEventProjector(ref: ref, vendorThreadId: "private-thread")
        let control = RemoteSessionControl(executionEpoch: "execution", controlRevision: 1, state: "running", controlMode: "live",
            currentTurnId: projector.identifier("turn", "private-turn"), allowedActions: ["approval.respond"])
        var params: [String: AgentJSON] = ["threadId": .string("private-thread"), "turnId": .string("private-turn"),
            "itemId": .string("private-item"), "startedAtMs": .integer(1), "cwd": .string("/workspace"),
            "environmentId": .string("environment_a"), "reason": .string("编译与验证🐾"), "permissions": permissions]
        params.merge(extra) { _, new in new }
        return try ChatGPTServerRequestMapper.map(id: .string("private-callback"), method: "item/permissions/requestApproval",
            params: .object(params), projector: projector, control: control)
    }
    @Test func exactProfilesAndFiniteScopesRoundTripWithoutDroppingExclusionsOrCompatibilityFields() throws {
        let mapped = try map(profile)
        #expect(mapped.request.validContent)
        #expect(mapped.request.allowedDecisions == ["accept", "acceptForSession", "decline"])
        #expect(mapped.request.permissionApproval?.permissions.fileSystem?.entries?.count == 3)
        for (decision, scope) in [("accept", "turn"), ("acceptForSession", "session")] {
            #expect(try mapped.approvalResponse(decision: decision) == .object(["permissions": profile, "scope": .string(scope)]))
        }
        #expect(try mapped.approvalResponse(decision: "decline") == .object(["permissions": .object([:]), "scope": .string("turn")]))
        for decision in ["cancel", "acceptWithExecpolicyAmendment", "unknown"] {
            #expect(throws: ChatGPTServerRequestError.invalidAnswer) { try mapped.approvalResponse(decision: decision) }
        }
        let encoded = try JSONEncoder().encode(mapped.request)
        #expect(try JSONDecoder().decode(RemotePendingRequest.self, from: encoded) == mapped.request)
        let json = String(decoding: encoded, as: UTF8.self)
        for value in ["private-thread", "private-turn", "private-item", "private-callback", "strictAutoReview"] { #expect(!json.contains(value)) }
    }
    @Test func everyKnownSpecialPathAndNetworkStateRetainsItsMeaning() throws {
        for kind in ["root", "minimal", "project_roots", "tmpdir", "slash_tmp"] {
            var value: [String: AgentJSON] = ["kind": .string(kind)]
            if kind == "project_roots" { value["subpath"] = .string("") }
            let raw = AgentJSON.object(["fileSystem": .object(["entries": .array([.object([
                "access": .string("write"), "path": .object(["type": .string("special"), "value": .object(value)])])])])])
            #expect(try map(raw).approvalResponse(decision: "accept") == .object(["permissions": raw, "scope": .string("turn")]))
        }
        for enabled in [AgentJSON.bool(false), .bool(true), .null] {
            let mapped = try map(.object(["network": .object(["enabled": enabled])]))
            let expected: AgentJSON = .object(["network": enabled == .null ? .object([:]) : .object(["enabled": enabled])])
            #expect(try mapped.approvalResponse(decision: "accept") == .object(["permissions": expected, "scope": .string("turn")]))
        }
        for raw in [AgentJSON.object([:]), .object(["fileSystem": .null, "network": .null]),
                    .object(["fileSystem": .object(["entries": .array([]), "write": .array([.string("/not-effective")])])])] {
            #expect(try map(raw).request.validContent)
        }
    }
    @Test func unknownSpecialRangeRemainsVisibleButCannotBeGranted() throws {
        let raw = AgentJSON.object(["fileSystem": .object(["entries": .array([.object(["access": .string("write"),
            "path": .object(["type": .string("special"), "value": .object(["kind": .string("unknown"),
                "path": .string(":future-scope"), "subpath": .string("config")])])])])])])
        let mapped = try map(raw)
        #expect(mapped.request.permissionApproval?.permissions.hasUnknownRange == true)
        #expect(mapped.request.allowedDecisions == ["decline"])
        #expect(throws: ChatGPTServerRequestError.invalidAnswer) { try mapped.approvalResponse(decision: "acceptForSession") }
        #expect(try mapped.approvalResponse(decision: "decline") == .object(["permissions": .object([:]), "scope": .string("turn")]))
    }
    @Test func malformedOversizedOrAdditionalScopeCannotBeSilentlyApproved() throws {
        let invalid: [AgentJSON] = [
            .object(["hiddenScope": .bool(true)]), .object(["network": .object(["domains": .array([])])]),
            .object(["network": .object(["enabled": .integer(1)])]),
            .object(["fileSystem": .object(["globScanMaxDepth": .integer(0)])]),
            .object(["fileSystem": .object(["globScanMaxDepth": .integer(9_007_199_254_740_991)])]),
            .object(["fileSystem": .object(["read": .array([.string("/bad\0path")])])]),
            .object(["fileSystem": .object(["read": .array([.string(String(repeating: "🐾", count: 1025))])])]),
            .object(["fileSystem": .object(["read": .array(Array(repeating: .string("/path"), count: 129))])]),
            .object(["fileSystem": .object(["entries": .array([]), "hiddenScope": .bool(true)])]),
            .object(["fileSystem": .object(["entries": .array([.object(["access": .string("execute"),
                "path": .object(["type": .string("path"), "path": .string("/path")])])])])]),
            .object(["fileSystem": .object(["entries": .array([.object(["access": .string("read"),
                "path": .object(["type": .string("path"), "path": .string("/path"), "pattern": .string("/**")])])])])])
        ]
        for raw in invalid { #expect(throws: ChatGPTServerRequestError.invalidRequest) { try map(raw) } }
        for patch: [String: AgentJSON] in [["hiddenScope": .bool(true)], ["turnId": .string("another")],
            ["cwd": .string("")], ["environmentId": .string(String(repeating: "a", count: 257))]] {
            #expect(throws: ChatGPTServerRequestError.invalidRequest) { try map(profile, extra: patch) }
        }
        let large = AgentJSON.object(["fileSystem": .object(["write": .array(Array(repeating: .string(String(repeating: "a", count: 4096)), count: 128))])])
        #expect(throws: ChatGPTServerRequestError.invalidRequest) { try map(large) }
    }
}
