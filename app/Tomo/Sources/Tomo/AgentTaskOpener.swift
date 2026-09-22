import Foundation
import AppKit

/// 打开任务所属 Agent 的共享路由：优先打开对应 session，其次打开 Agent 应用；
/// 都不支持时返回 false（调用方据此去掉点击与小箭头）。
///
/// 由「独立 Pet 任务条」、主窗口顶部任务卡、刘海展开态任务共用同一套逻辑，
/// 保证三处点击进入 Agent 应用的行为完全一致。
enum AgentTaskOpener {
    /// 是否支持打开该名称的 Agent（Codex / Antigravity）。
    static func canOpen(agentDisplayName: String) -> Bool {
        agentDisplayName == "Codex" || agentDisplayName == "Antigravity"
    }

    /// 便捷入口：由 CodexTaskActivity 判断是否可打开。
    static func canOpen(_ task: CodexTaskActivity) -> Bool {
        canOpen(agentDisplayName: task.agentDisplayName)
    }

    @discardableResult
    static func open(agentDisplayName: String, taskID: String?) -> Bool {
        switch agentDisplayName {
        case "Codex":
            let threadID = taskID ?? ""
            NSLog("[AgentTaskOpener] 打开 Codex 任务 id=%@", threadID)
            if let url = URL(string: "codex://threads/\(threadID)"),
               NSWorkspace.shared.open(url) {
                NSLog("[AgentTaskOpener] 深链已打开: %@", url.absoluteString)
                return true
            }
            let opened = openCodexApplication()
            NSLog("[AgentTaskOpener] 回退打开 ChatGPT.app: %@", opened ? "成功" : "失败")
            return opened
        case "Antigravity":
            return openAntigravityApplication()
        case "Hermes":
            return openHermes()
        case "Deepseek Harness":
            return openDeepseekHarness(taskID: taskID)
        default:
            return false
        }
    }

    /// 便捷入口：由 CodexTaskActivity 打开任务所属 Agent。
    @discardableResult
    static func open(_ task: CodexTaskActivity) -> Bool {
        open(agentDisplayName: task.agentDisplayName, taskID: task.id)
    }

    private static func openCodexApplication() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            URL(fileURLWithPath: "/Applications/Codex.app"),
            home.appendingPathComponent("Applications/ChatGPT.app"),
            home.appendingPathComponent("Applications/Codex.app"),
        ]
        guard let appURL = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Info.plist").path)
        }) else {
            NSLog("[AgentTaskOpener] 未找到 ChatGPT.app / Codex.app")
            return false
        }
        NSLog("[AgentTaskOpener] 打开应用: %@", appURL.path)
        return NSWorkspace.shared.open(appURL)
    }

    private static func openAntigravityApplication() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/Applications/Antigravity.app"),
            home.appendingPathComponent("Applications/Antigravity.app"),
        ]
        guard let appURL = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Info.plist").path)
        }) else {
            NSLog("[AgentTaskOpener] 未找到 Antigravity.app")
            return false
        }
        NSLog("[AgentTaskOpener] 打开应用: %@", appURL.path)
        return NSWorkspace.shared.open(appURL)
    }

    /// Hermes：启动 Electron 桌面应用（`hermes desktop`）。会话级深链不受支持，先打开 Agent。
    /// 暂未启用（canOpen 对 Hermes 返回 false）；待官方会话能力齐全后恢复。
    private static func openHermes() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/hermes").path,
            "/usr/local/bin/hermes",
            "/opt/homebrew/bin/hermes",
        ]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            NSLog("[AgentTaskOpener] 未找到 hermes 可执行文件")
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["desktop"]
        do {
            try process.run()
            NSLog("[AgentTaskOpener] 已启动 Hermes 桌面应用")
            return true
        } catch {
            NSLog("[AgentTaskOpener] 启动 Hermes 桌面应用失败: %@", error.localizedDescription)
            return false
        }
    }

    /// Deepseek Harness：打开本地 Web UI 的会话页（`http://127.0.0.1:3080/sessions/<id>`）。
    /// 暂未启用（canOpen 对 Deepseek Harness 返回 false）；待官方会话能力齐全后恢复。
    private static func openDeepseekHarness(taskID: String?) -> Bool {
        let sessionID = (taskID ?? "").replacingOccurrences(of: "dsh:", with: "")
        let base = "http://127.0.0.1:3080"
        if let url = URL(string: "\(base)/sessions/\(sessionID)"),
           NSWorkspace.shared.open(url) {
            NSLog("[AgentTaskOpener] 已打开 DSH 会话页: %@", url.absoluteString)
            return true
        }
        if let root = URL(string: base) {
            NSLog("[AgentTaskOpener] 回退打开 DSH 首页")
            return NSWorkspace.shared.open(root)
        }
        return false
    }
}
