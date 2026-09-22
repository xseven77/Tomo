import Darwin
import Foundation

private let maximumPayloadBytes = 8 * 1024

private struct Arguments {
    var agentID: String?
    var surfaceID: String?
    var connectionID: String?
    var vendorEvent: String?
    var socketPath: String?

    init(_ values: [String]) {
        var index = 1
        while index + 1 < values.count {
            let value = values[index + 1]
            switch values[index] {
            case "--agent": agentID = value
            case "--surface": surfaceID = value
            case "--connection": connectionID = value
            case "--event": vendorEvent = value
            case "--socket": socketPath = value
            default: break
            }
            index += 2
        }
    }
}

private func firstString(_ object: [String: Any], keys: [String]) -> String? {
    for key in keys {
        if let value = object[key] as? String, !value.isEmpty, value.utf8.count <= 256 {
            return value
        }
    }
    return nil
}

private func normalizedEvent(_ vendorEvent: String) -> String {
    switch vendorEvent.lowercased() {
    case "sessionstart", "on_session_start": "session.started"
    case "userpromptsubmit", "pre_llm_call": "prompt.submitted"
    case "pretooluse", "pre_tool_call": "tool.started"
    case "permissionrequest", "pre_approval_request": "permission.requested"
    case "posttooluse", "post_tool_call", "post_approval_response": "tool.finished"
    case "stop", "taskcompleted", "on_session_end": "turn.completed"
    case "sessionend", "on_session_finalize": "session.ended"
    case "posttoolusefailure", "stopfailure": "failed"
    default: "prompt.submitted"
    }
}

private func toolCategory(_ toolName: String?) -> String? {
    guard let name = toolName?.lowercased() else { return nil }
    if name.contains("read") || name.contains("search") || name.contains("find") { return "reading" }
    if name.contains("write") || name.contains("edit") || name.contains("patch") { return "writing" }
    if name.contains("bash") || name.contains("shell") || name.contains("terminal") { return "shell" }
    if name.contains("web") || name.contains("http") || name.contains("fetch") { return "network" }
    return "other"
}

private func sanitizedOutcome(_ object: [String: Any]) -> String? {
    let candidate = firstString(object, keys: ["outcome", "status", "choice", "turn_exit_reason"])?
        .lowercased()
    guard let candidate else { return nil }
    let allowed = Set(["ok", "completed", "failed", "interrupted", "denied", "deny", "timeout", "cancelled", "blocked"])
    return allowed.contains(candidate) ? candidate : nil
}

private func sendDatagram(_ data: Data, socketPath: String) {
    guard socketPath.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else { return }
    let descriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
    guard descriptor >= 0 else { return }
    defer { close(descriptor) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { pathPointer in
            socketPath.withCString { source in
                strlcpy(pathPointer, source, pathCapacity)
            }
        }
    }

    withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                _ = sendto(
                    descriptor,
                    baseAddress,
                    data.count,
                    0,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
    }
}

private let arguments = Arguments(CommandLine.arguments)
guard let agentID = arguments.agentID,
      let surfaceID = arguments.surfaceID,
      let vendorEvent = arguments.vendorEvent else {
    exit(0)
}

let input = FileHandle.standardInput.readDataToEndOfFile()
guard input.count <= maximumPayloadBytes else { exit(0) }
let vendorObject = ((try? JSONSerialization.jsonObject(with: input)) as? [String: Any]) ?? [:]
let event: [String: Any?] = [
    "schemaVersion": 1,
    "agentID": agentID,
    "surfaceID": surfaceID,
    "connectionID": arguments.connectionID,
    "sessionID": firstString(vendorObject, keys: ["session_id", "sessionId", "sessionID", "session_key"]),
    "turnID": firstString(vendorObject, keys: ["turn_id", "turnId", "turnID"]),
    "event": normalizedEvent(vendorEvent),
    "toolCategory": toolCategory(firstString(vendorObject, keys: ["tool_name", "toolName"])),
    "outcome": sanitizedOutcome(vendorObject),
    "timestamp": ISO8601DateFormatter().string(from: Date()),
]
let compact = event.compactMapValues { $0 }
guard let output = try? JSONSerialization.data(withJSONObject: compact), output.count <= maximumPayloadBytes else {
    exit(0)
}

let defaultSocket = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Tomo/agent-events.sock").path
sendDatagram(output, socketPath: arguments.socketPath ?? defaultSocket)
exit(0)
