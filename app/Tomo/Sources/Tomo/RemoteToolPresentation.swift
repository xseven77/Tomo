import Foundation

/// Explicit user-visible text only. Never serialize the upstream item/arguments,
/// hidden reasoning, resource blobs, process IDs or private callback identities.
struct RemoteToolPresentation: Codable, Equatable, Sendable {
    struct Block: Codable, Equatable, Sendable {
        let label: String
        let text: String
    }
    let title: String
    let blocks: [Block]
    let truncated: Bool

    var valid: Bool {
        !title.isEmpty && title.utf8.count <= 512 && !title.contains("\0")
            && blocks.count <= 32 && blocks.allSatisfy {
                !$0.label.isEmpty && $0.label.utf8.count <= 256 && !$0.label.contains("\0") && !$0.text.contains("\0")
            } && ((try? JSONEncoder().encode(self).count).map { $0 <= 32 * 1024 } ?? false)
    }

    static let commandOutputLabel = "输出（stdout / stderr 合并）"

    /// Bound the actual presentation, not the input event. Metadata precedes long
    /// output so exit status is still visible when that output is truncated.
    static func bounded(title: String, blocks input: [Block], truncated initial: Bool = false) -> Self {
        var blocks: [Block] = [], bytes = 0, truncated = initial
        for block in input {
            guard blocks.count < 32, bytes < 16 * 1024 else { truncated = true; break }
            let clean = block.text.replacingOccurrences(of: "\0", with: "�")
            var prefix = Data(clean.utf8.prefix(16 * 1024 - bytes))
            while String(data: prefix, encoding: .utf8) == nil { prefix.removeLast() }
            bytes += prefix.count
            truncated = truncated || prefix.count < clean.utf8.count
            blocks.append(.init(label: block.label, text: String(decoding: prefix, as: UTF8.self)))
        }
        var result = Self(title: title, blocks: blocks, truncated: truncated)
        // Control-character escaping can expand JSON beyond the UTF-8 text size.
        while !result.valid, !blocks.isEmpty {
            let last = blocks.removeLast()
            if last.text.utf8.count > 64 {
                blocks.append(.init(label: last.label, text: String(last.text.prefix(last.text.count / 2))))
            }
            result = .init(title: title, blocks: blocks, truncated: true)
        }
        return result
    }

    func appendingCommandOutput(_ delta: String) -> Self {
        // Once the prefix is full, keep it stable until an authoritative full
        // item arrives. Do not generate a revision for every discarded chunk.
        guard !truncated, !delta.isEmpty else { return self }
        var blocks = self.blocks
        if let index = blocks.firstIndex(where: { $0.label == Self.commandOutputLabel }) {
            blocks[index] = .init(label: Self.commandOutputLabel, text: blocks[index].text + delta)
        } else { blocks.append(.init(label: Self.commandOutputLabel, text: delta)) }
        return Self.bounded(title: title, blocks: blocks)
    }

    /// Keep a bounded transcript window, identically on desktop and RN replay.
    /// Older activities retain their identity/status; their detail is unavailable.
    static func compact(_ activities: [RemoteToolActivity]) -> [RemoteToolActivity] {
        activities.enumerated().map { index, activity in
            guard index < activities.count - 16, activity.presentation != nil else { return activity }
            return .init(activityId: activity.activityId, turnId: activity.turnId, activityRevision: activity.activityRevision,
                kind: activity.kind, status: activity.status, createdAt: activity.createdAt)
        }
    }
}

extension ChatGPTEventProjector {
    /// Audited against the installed v2 ThreadItem schema. Text is inert in RN.
    /// Unknown JSON, MCP arguments/structuredContent and image data are omitted.
    func toolPresentation(_ item: [String: AgentJSON], type: String, previous: RemoteToolPresentation? = nil, completed: Bool = false) -> RemoteToolPresentation? {
        guard let text = toolText(item, type: type, previous: previous, completed: completed) else { return nil }
        let result = RemoteToolPresentation.bounded(title: text.title, blocks: text.blocks, truncated: text.truncated)
        return result.valid ? result : nil
    }

    func toolResultText(_ item: [String: AgentJSON], type: String, previous: RemoteToolPresentation? = nil) -> RemoteToolResultText? {
        guard let text = toolText(item, type: type, previous: previous, completed: true) else { return nil }
        return .init(title: text.title, blocks: text.blocks, truncated: text.truncated)
    }

    private func toolText(_ item: [String: AgentJSON], type: String, previous: RemoteToolPresentation?, completed: Bool)
        -> (title: String, blocks: [RemoteToolPresentation.Block], truncated: Bool)? {
        var blocks: [RemoteToolPresentation.Block] = [], truncated = false
        func add(_ label: String, _ value: AgentJSON?) {
            guard case .string(let text) = value, !text.isEmpty else { return }
            blocks.append(.init(label: label, text: text))
        }
        func number(_ label: String, _ value: AgentJSON?) {
            if case .integer(let n) = value, (-9_007_199_254_740_991...9_007_199_254_740_991).contains(n) {
                add(label, .string(String(n)))
            }
        }
        let title: String
        switch type {
        case "commandExecution":
            title = "执行命令"
            add("命令", item["command"]); add("工作目录", item["cwd"])
            number("退出码", item["exitCode"]); number("耗时（毫秒）", item["durationMs"])
            if case .string = item["aggregatedOutput"] {
                // An explicit empty result also replaces the streamed preview.
                add(RemoteToolPresentation.commandOutputLabel, item["aggregatedOutput"])
            } else if let old = previous?.blocks.first(where: { $0.label == RemoteToolPresentation.commandOutputLabel }) {
                add(old.label, .string(old.text))
                // Missing final aggregate cannot establish complete output.
                truncated = completed || previous?.truncated == true
            } else if completed {
                truncated = true // no aggregate was supplied; absence is not an empty output
            }
        case "fileChange":
            title = "修改文件"
            if case .array(let changes) = item["changes"] {
                for value in changes {
                    guard case .object(let change) = value else { continue }
                    add("文件", change["path"])
                    if case .object(let kind) = change["kind"] {
                        add("修改类型", kind["type"]); add("移动至", kind["move_path"])
                    }
                    add("差异", change["diff"])
                }
            }
        case "mcpToolCall", "dynamicToolCall":
            title = type == "mcpToolCall" ? "调用 MCP 工具" : "调用工具"
            add("服务器", item["server"]); add("工具", item["tool"])
            let content: AgentJSON?
            if case .object(let result) = item["result"] { content = result["content"] }
            else { content = item["contentItems"] }
            if case .array(let items) = content {
                for value in items {
                    if case .object(let part) = value, part["type"] == .string("text") || part["type"] == .string("inputText") {
                        add("结果", part["text"])
                    } else { add("其他内容", .string("此内容暂不支持预览")) }
                }
            }
            if case .object(let error) = item["error"] { add("错误", error["message"]) }
            number("耗时（毫秒）", item["durationMs"])
        case "collabAgentToolCall":
            title = "子任务协作"
            let actions = ["spawnAgent": "分派子任务", "sendInput": "继续子任务", "resumeAgent": "恢复子任务",
                           "wait": "等待子任务", "closeAgent": "关闭子任务", "sendMessage": "向子任务发消息",
                           "followupTask": "继续子任务", "interruptAgent": "中断子任务", "listAgents": "查看子任务"]
            let statuses = ["pendingInit": "待启动", "running": "进行中", "interrupted": "已中断",
                            "completed": "已完成", "errored": "已失败", "shutdown": "已关闭", "notFound": "不可用"]
            guard case .string(let tool) = item["tool"], let action = actions[tool],
                  case .object(let states) = item["agentsStates"],
                  case .array(let receivers) = item["receiverThreadIds"] else { return nil }
            add("操作", .string(action))
            // Routing identities establish a stable local order only. They and
            // the input prompt never become presentation or archive contents.
            var seen = Set<String>(), ordered: [String] = []
            for value in receivers {
                if case .string(let id) = value, seen.insert(id).inserted { ordered.append(id) }
            }
            for id in states.keys.sorted() where seen.insert(id).inserted { ordered.append(id) }
            for (index, id) in ordered.enumerated() {
                let label = "子任务 \(index + 1)"
                guard case .object(let state) = states[id], case .string(let status) = state["status"],
                      let statusText = statuses[status] else {
                    add(label, .string("状态暂不可用")); continue
                }
                let text: String
                if case .string(let message) = state["message"], !message.isEmpty { text = message }
                else { text = statusText }
                add(label + " · " + statusText, .string(text))
            }
        case "webSearch":
            var queries = Set<String>()
            func query(_ value: AgentJSON?) {
                if case .string(let text) = value, !text.isEmpty, queries.insert(text).inserted {
                    add("查询", .string(text))
                }
            }
            query(item["query"])
            if case .object(let action) = item["action"] {
                switch action["type"] {
                case .string("search"):
                    title = "搜索网页"
                    query(action["query"])
                    if case .array(let values) = action["queries"] { for value in values { query(value) } }
                case .string("openPage"):
                    title = "打开网页"
                    add("网页", action["url"])
                case .string("findInPage"):
                    title = "页内查找"
                    add("网页", action["url"]); add("查找内容", action["pattern"])
                case .string("other"):
                    title = "网页操作"
                    add("操作", .string("其他网页操作"))
                default:
                    title = "搜索网页"
                    add("操作", .string("此搜索操作暂不支持显示。")); truncated = true
                }
            } else {
                title = "搜索网页"
                if let action = item["action"], action != .null {
                    add("操作", .string("此搜索操作暂不支持显示。")); truncated = true
                }
            }
            // URLs and patterns are optional in the schema. Retain the known
            // operation even when the upstream item supplies no detail text.
            if blocks.isEmpty { add("操作", .string(title)) }
            // This CLI schema intentionally leaves results as arbitrary JSON.
            // Do not guess a result shape or serialize unvalidated nested data.
            if let results = item["results"], results != .null {
                let hasContent: Bool
                if case .array(let values) = results { hasContent = !values.isEmpty }
                else { hasContent = true }
                if hasContent {
                    add("结果", .string("此版本暂不支持显示结构化搜索结果。")); truncated = true
                }
            }
        case "imageView": title = "查看图片"; add("文件", item["path"])
        case "imageGeneration": title = "生成图片"; add("保存位置", item["savedPath"])
        default: return nil
        }
        if blocks.isEmpty { return nil }
        return (title, blocks, truncated)
    }
}
