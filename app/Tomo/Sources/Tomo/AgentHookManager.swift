import Foundation

struct AgentIntegrationStatus: Identifiable, Equatable, Sendable {
    let id: AgentID
    let name: String
    let priority: Int
    var cliInstalled: Bool
    var desktopInstalled: Bool
    var environmentConfigured: Bool
    var detail: String

    init(
        id: AgentID,
        name: String,
        priority: Int,
        cliInstalled: Bool,
        desktopInstalled: Bool,
        environmentConfigured: Bool = false,
        detail: String
    ) {
        self.id = id
        self.name = name
        self.priority = priority
        self.cliInstalled = cliInstalled
        self.desktopInstalled = desktopInstalled
        self.environmentConfigured = environmentConfigured
        self.detail = detail
    }

    var isInstalled: Bool {
        cliInstalled || desktopInstalled || environmentConfigured
    }

    var guide: AgentInstallGuide {
        AgentInstallGuideCatalog.guide(for: id)
    }
}

enum AgentInstallMethodKind: String, Sendable, Codable {
    case command
    case download
    case run
}

struct AgentInstallMethod: Identifiable, Sendable, Equatable {
    var id: String { title }
    let title: String
    let kind: AgentInstallMethodKind
    let command: String?
    let urlString: String?
    let note: String?
}

struct AgentInstallGuide: Sendable, Equatable {
    let agentID: AgentID
    let name: String
    let tagline: String
    let summary: String
    let integrationMechanism: String
    let methods: [AgentInstallMethod]
    let documentationURLString: String?
}

enum AgentInstallGuideCatalog {
    static func guide(for agentID: AgentID) -> AgentInstallGuide {
        switch agentID {
        case .codex:
            return AgentInstallGuide(
                agentID: .codex,
                name: "Codex",
                tagline: "OpenAI 官方代码智能助手与执行引擎",
                summary: "Codex 是 OpenAI 打造的代码生成与工程辅助工具，支持终端 CLI 与桌面交互环境。Tomo 通过本地 App Server 与活动日志自动接入，无需额外安装 Hook。",
                integrationMechanism: "通过本地 App Server 与活动日志（~/.codex/）自动感知会话与任务状态。",
                methods: [
                    AgentInstallMethod(
                        title: "Homebrew 安装 CLI (推荐)",
                        kind: .command,
                        command: "brew install codex",
                        urlString: nil,
                        note: "适合 macOS 终端用户快速安装。"
                    ),
                    AgentInstallMethod(
                        title: "npm 全局安装 CLI",
                        kind: .command,
                        command: "npm install -g @openai/codex",
                        urlString: nil,
                        note: "需要 Node.js 18+ 环境。"
                    ),
                    AgentInstallMethod(
                        title: "下载 macOS 桌面应用",
                        kind: .download,
                        command: nil,
                        urlString: "https://chatgpt.com/download",
                        note: "下载 ChatGPT / Codex macOS 客户端，登录后即可使用。"
                    )
                ],
                documentationURLString: "https://github.com/openai/codex"
            )

        case .deepseekHarness:
            return AgentInstallGuide(
                agentID: .deepseekHarness,
                name: "Deepseek Harness",
                tagline: "DeepSeek 官方代码智能评估与自动化 Harness",
                summary: "Deepseek Harness 是 DeepSeek 推出的轻量级代码任务执行与自动化评估工具。Tomo 实时解析本地 Session 日志，自动追踪会话与任务状态。",
                integrationMechanism: "通过读取 ~/.dsh/sessions 下的压缩会话 JSONL 实现无缝状态同步。",
                methods: [
                    AgentInstallMethod(
                        title: "npm 全局安装 (推荐)",
                        kind: .command,
                        command: "npm install -g @deepseek/harness",
                        urlString: nil,
                        note: "安装后将在终端提供 dsh 命令行工具。"
                    ),
                    AgentInstallMethod(
                        title: "npx 即开即用",
                        kind: .run,
                        command: "npx @deepseek/harness",
                        urlString: nil,
                        note: "无需全局安装，每次直接运行最新版本。"
                    ),
                    AgentInstallMethod(
                        title: "pnpm 全局安装",
                        kind: .command,
                        command: "pnpm add -g @deepseek/harness",
                        urlString: nil,
                        note: "使用 pnpm 包管理器全局安装。"
                    )
                ],
                documentationURLString: "https://github.com/deepseek-ai"
            )

        case .hermes:
            return AgentInstallGuide(
                agentID: .hermes,
                name: "Hermes",
                tagline: "自主 Coding Agent 与 Gateway 任务引擎",
                summary: "Hermes 是支持 Gateway JSON-RPC 远程通信与 Electron 桌面客户端的自主代码智能体。Tomo 通过本地 SQLite 状态库实时读取活跃任务。",
                integrationMechanism: "通过读取 ~/.hermes/state.db 数据库追踪会话与任务执行进度。",
                methods: [
                    AgentInstallMethod(
                        title: "官方一键脚本安装 (推荐)",
                        kind: .command,
                        command: "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash",
                        urlString: nil,
                        note: "自动配置 hermes 命令行工具与运行环境。"
                    )
                ],
                documentationURLString: "https://github.com/NousResearch/hermes-agent"
            )

        case .antigravity:
            return AgentInstallGuide(
                agentID: .antigravity,
                name: "Antigravity",
                tagline: "Google Antigravity 多智能体协同开发套件与 IDE",
                summary: "Google Antigravity 是面向多智能体协同的高阶开发工具与 IDE。Tomo 通过解析原子步骤日志（transcript.jsonl）实现精确到思考、执行与确认状态的同步。",
                integrationMechanism: "通过读取 ~/.gemini/antigravity/ 活跃会话流与任务索引自动接入。",
                methods: [
                    AgentInstallMethod(
                        title: "官方安装脚本 / CLI (推荐)",
                        kind: .command,
                        command: "curl -fsSL https://antigravity.google.com/install.sh | bash",
                        urlString: nil,
                        note: "安装后提供 agy 命令行工具与 agentapi 服务。"
                    ),
                    AgentInstallMethod(
                        title: "下载 Antigravity 桌面 IDE",
                        kind: .download,
                        command: nil,
                        urlString: "https://antigravity.google.com",
                        note: "下载 Antigravity.app 并安装至 /Applications/ 目录。"
                    )
                ],
                documentationURLString: "https://antigravity.google.com"
            )

        case .pi:
            return AgentInstallGuide(
                agentID: .pi,
                name: "Pi",
                tagline: "极简、快速且可扩展的开源 AI Coding Agent",
                summary: "Pi 是专为终端打造的高效开源编程智能体，内置 read、bash、edit、write 等工具。Tomo 实时解析本地 Session 日志，无侵入同步任务与活动状态。",
                integrationMechanism: "通过读取 ~/.pi/agent/sessions 下的会话 JSONL 实现无缝状态同步。",
                methods: [
                    AgentInstallMethod(
                        title: "官方一键脚本安装 (推荐)",
                        kind: .command,
                        command: "curl -fsSL https://pi.dev/install.sh | sh",
                        urlString: nil,
                        note: "自动下载并安装 pi 命令行工具与运行环境。"
                    )
                ],
                documentationURLString: "https://pi.dev/"
            )

        default:
            return AgentInstallGuide(
                agentID: agentID,
                name: agentID.rawValue,
                tagline: "Coding Agent 扩展",
                summary: "该 Agent 支持通过本地会话或配置文件与 Tomo 联动。",
                integrationMechanism: "通过本地会话读取接入。",
                methods: [],
                documentationURLString: nil
            )
        }
    }
}

/// 提供各 Agent 的接入状态（CLI/Desktop 探测 + 会话读取说明）。
///
/// 各 Agent 均通过会话读取接入，无需安装 Hook：
/// - Codex：App Server + 本地活动适配（内置）
/// - Deepseek Harness：读取 ~/.dsh/sessions 下的 session JSONL
/// - Hermes：Gateway JSON-RPC（session.list / session.active_list 等）
/// - Antigravity：读取 ~/.gemini/antigravity 下的 transcript JSONL
/// - Pi：读取 ~/.pi/agent/sessions 下的 session JSONL
struct AgentHookManager {
    let fileManager: FileManager
    let homeDirectory: URL
    let allowShellFallback: Bool

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        allowShellFallback: Bool = true
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.allowShellFallback = allowShellFallback
    }

    func integrationStatuses() -> [AgentIntegrationStatus] {
        BuiltInAgentCatalog.prioritized.map { descriptor in
            let cliInstalled = locateExecutable(for: descriptor.id) != nil
            let desktopInstalled = desktopApplicationExists(for: descriptor.id)
            let envConfigured = environmentConfigured(for: descriptor.id)
            return AgentIntegrationStatus(
                id: descriptor.id,
                name: descriptor.displayName,
                priority: descriptor.priority,
                cliInstalled: cliInstalled,
                desktopInstalled: desktopInstalled,
                environmentConfigured: envConfigured,
                detail: integrationDetail(for: descriptor.id)
            )
        }
    }

    private func environmentConfigured(for agentID: AgentID) -> Bool {
        switch agentID {
        case .deepseekHarness:
            // DSH 可通过 npx 或 CLI 运行；其配置与会话保存在 ~/.dsh 中
            return fileManager.fileExists(atPath: homeDirectory.appendingPathComponent(".dsh").path)
        case .codex:
            return fileManager.fileExists(atPath: homeDirectory.appendingPathComponent(".codex").path)
        case .hermes:
            return fileManager.fileExists(atPath: homeDirectory.appendingPathComponent(".hermes").path)
        case .antigravity:
            return fileManager.fileExists(atPath: homeDirectory.appendingPathComponent(".gemini/antigravity").path)
        case .pi:
            return fileManager.fileExists(atPath: homeDirectory.appendingPathComponent(".pi").path)
        default:
            return false
        }
    }

    private func candidatePrefixes() -> [String] {
        var prefixes = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            homeDirectory.appendingPathComponent(".local/bin").path,
            homeDirectory.appendingPathComponent("bin").path,
            homeDirectory.appendingPathComponent(".cargo/bin").path,
            homeDirectory.appendingPathComponent(".bun/bin").path,
            homeDirectory.appendingPathComponent("Library/pnpm").path,
            homeDirectory.appendingPathComponent(".local/share/pnpm").path,
            homeDirectory.appendingPathComponent(".volta/bin").path,
            homeDirectory.appendingPathComponent(".asdf/shims").path,
            homeDirectory.appendingPathComponent(".yarn/bin").path,
            homeDirectory.appendingPathComponent(".config/yarn/global/node_modules/.bin").path,
            homeDirectory.appendingPathComponent(".npm-global/bin").path,
            homeDirectory.appendingPathComponent(".npm/bin").path,
            homeDirectory.appendingPathComponent(".nvm/current/bin").path,
            homeDirectory.appendingPathComponent(".local/share/fnm/current/bin").path,
            homeDirectory.appendingPathComponent(".local/share/fnm/aliases/default/bin").path,
            homeDirectory.appendingPathComponent(".fnm/current/bin").path,
            homeDirectory.appendingPathComponent(".gemini/antigravity/bin").path,
        ]

        // 动态扫描 NVM 安装的所有 Node 版本 bin 目录（优先检测最新版本）
        let nvmVersionsRoot = homeDirectory.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let subdirs = try? fileManager.contentsOfDirectory(atPath: nvmVersionsRoot.path) {
            let sortedVersions = subdirs.sorted { $0.localizedStandardCompare($1) == .orderedDescending }
            for version in sortedVersions {
                let binDir = nvmVersionsRoot.appendingPathComponent(version).appendingPathComponent("bin").path
                prefixes.append(binDir)
            }
        }

        // 动态扫描 FNM 安装的所有 Node 版本 bin 目录
        let fnmVersionsRoots = [
            homeDirectory.appendingPathComponent(".local/share/fnm/versions", isDirectory: true),
            homeDirectory.appendingPathComponent(".fnm/versions", isDirectory: true),
        ]
        for root in fnmVersionsRoots {
            if let subdirs = try? fileManager.contentsOfDirectory(atPath: root.path) {
                let sorted = subdirs.sorted { $0.localizedStandardCompare($1) == .orderedDescending }
                for version in sorted {
                    let binDir = root.appendingPathComponent(version).appendingPathComponent("bin").path
                    prefixes.append(binDir)
                }
            }
        }

        // 动态扫描 ASDF 安装的所有 Node 版本 bin 目录
        let asdfNodeRoot = homeDirectory.appendingPathComponent(".asdf/installs/nodejs", isDirectory: true)
        if let subdirs = try? fileManager.contentsOfDirectory(atPath: asdfNodeRoot.path) {
            let sorted = subdirs.sorted { $0.localizedStandardCompare($1) == .orderedDescending }
            for version in sorted {
                let binDir = asdfNodeRoot.appendingPathComponent(version).appendingPathComponent("bin").path
                prefixes.append(binDir)
            }
        }

        return prefixes
    }

    func locateExecutable(for agentID: AgentID) -> URL? {
        if agentID == .antigravity {
            let candidate = homeDirectory.appendingPathComponent(".gemini/antigravity/bin/agentapi")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        let executable: String
        switch agentID {
        case .codex: executable = "codex"
        case .hermes: executable = "hermes"
        case .deepseekHarness: executable = "dsh"
        case .antigravity: executable = "agy"
        case .pi: executable = "pi"
        default: return nil
        }

        for prefix in candidatePrefixes() {
            let candidate = URL(fileURLWithPath: prefix).appendingPathComponent(executable)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        guard allowShellFallback else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "which \(executable) 2>/dev/null || type -p \(executable) 2>/dev/null"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let path = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              path.hasPrefix("/"),
              fileManager.isExecutableFile(atPath: path) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    private func desktopApplicationExists(for agentID: AgentID) -> Bool {
        let paths: [String]
        switch agentID {
        case .codex:
            paths = [
                "/Applications/ChatGPT.app",
                "/Applications/Codex.app",
                homeDirectory.appendingPathComponent("Applications/ChatGPT.app").path,
                homeDirectory.appendingPathComponent("Applications/Codex.app").path,
            ]
        case .hermes:
            paths = [
                "/Applications/Hermes.app",
                homeDirectory.appendingPathComponent("Applications/Hermes.app").path,
            ]
        case .antigravity:
            paths = [
                "/Applications/Antigravity.app",
                homeDirectory.appendingPathComponent("Applications/Antigravity.app").path,
            ]
        case .deepseekHarness, .pi:
            // Deepseek Harness 与 Pi 是 npm/npx 等分发的 CLI 工具，无独立 macOS .app。
            paths = []
        default:
            paths = []
        }
        return paths.contains { fileManager.fileExists(atPath: $0) }
    }

    private func integrationDetail(for agentID: AgentID) -> String {
        switch agentID {
        case .codex: "App Server · 本地活动"
        case .hermes: "Gateway JSON-RPC · 会话读取"
        case .deepseekHarness: "Session JSONL · 会话读取"
        case .antigravity: "Transcript JSONL · 本地活动"
        case .pi: "Session JSONL · 会话读取"
        default: ""
        }
    }
}
