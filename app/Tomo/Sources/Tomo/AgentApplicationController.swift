import AppKit
import Darwin
import Foundation

enum AgentApplicationTarget: String, Sendable {
    case chatGPT, hermes, pi, cline

    var displayName: String {
        switch self {
        case .chatGPT: "ChatGPT"
        case .hermes: "Hermes"
        case .pi: "Pi"
        case .cline: "Cline"
        }
    }

    var bundleIdentifier: String? {
        switch self {
        case .chatGPT: "com.openai.codex"
        case .hermes: "com.nousresearch.hermes"
        case .cline: "bot.cline.app"
        case .pi: nil
        }
    }
}

enum AgentApplicationError: LocalizedError {
    case notInstalled(String)
    case terminationRejected(String)
    case terminationTimedOut(String)
    case terminalUnavailable
    case piStartTimedOut

    var errorDescription: String? {
        switch self {
        case .notInstalled(let name): "未找到 \(name) 软件，请先安装。"
        case .terminationRejected(let name): "\(name) 拒绝退出，请保存当前工作后重试。"
        case .terminationTimedOut(let name): "等待 \(name) 退出超时，请手动退出后重试。"
        case .terminalUnavailable: "无法打开系统终端。"
        case .piStartTimedOut: "等待 Pi 终端会话启动或重启超时，请查看终端中的提示。"
        }
    }
}

@MainActor
struct AgentApplicationController {
    func perform(_ target: AgentApplicationTarget, restart: Bool) async throws {
        if target == .pi {
            try await openPi(restart: restart)
            return
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleIdentifier!)
            .filter { !$0.isTerminated }
        let installed = await Task.detached(priority: .userInitiated) {
            Self.applicationCandidates(for: target).first {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Info.plist").path)
            }
        }.value
        guard let url = running.first?.bundleURL ?? installed
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleIdentifier!) else {
            throw AgentApplicationError.notInstalled(target.displayName)
        }

        if restart {
            for app in running {
                guard app.terminate() else { throw AgentApplicationError.terminationRejected(target.displayName) }
            }
            for _ in 0..<60 {
                if running.allSatisfy(\.isTerminated) { break }
                try await Task.sleep(for: .milliseconds(150))
            }
            guard running.allSatisfy(\.isTerminated) else {
                throw AgentApplicationError.terminationTimedOut(target.displayName)
            }
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    nonisolated static func applicationCandidates(for target: AgentApplicationTarget,
                                                  home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let names: [String]
        switch target {
        case .chatGPT: names = ["ChatGPT", "Codex"]
        case .hermes: names = ["Hermes"]
        case .cline: names = ["Cline"]
        case .pi: return []
        }
        var result = names.flatMap { name in
            [URL(fileURLWithPath: "/Applications/\(name).app"),
             home.appendingPathComponent("Applications/\(name).app")]
        }
        if target == .hermes {
            let hermesHome = ProcessInfo.processInfo.environment["HERMES_HOME"].map { URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".hermes")
            let release = hermesHome.appendingPathComponent("hermes-agent/apps/desktop/release")
            for directory in ["mac-arm64", "mac", "mac-x64"] {
                result.append(release.appendingPathComponent("\(directory)/Hermes.app"))
            }
        }
        return result
    }

    private func openPi(restart: Bool) async throws {
        let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        guard let terminal else { throw AgentApplicationError.terminalUnavailable }
        let session = PiApplicationSession()
        let existing = await Task.detached { session.activeLaunch() }.value
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let existing {
            if restart {
                try await Task.detached { try session.requestRestart(existing) }.value
                try await waitForPi(session, after: existing.generation)
            }
            _ = try await NSWorkspace.shared.openApplication(at: terminal, configuration: configuration)
            return
        }
        let script = try await Task.detached(priority: .userInitiated) { try session.prepareLaunch() }.value
        _ = try await NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: configuration)
        try await waitForPi(session, after: nil)
    }

    private func waitForPi(_ session: PiApplicationSession, after generation: String?) async throws {
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(150))
            let launch = await Task.detached { session.activeLaunch() }.value
            if let launch, generation == nil || launch.generation != generation { return }
        }
        throw AgentApplicationError.piStartTimedOut
    }
}

/// Pi requires a TTY. A dedicated .command launcher owns its child and restarts
/// it on SIGUSR1. Verify the unique launcher path before signalling any process.
struct PiApplicationSession: Sendable {
    struct Launch: Codable, Sendable {
        let scriptPath: String
        var pid: Int32 = 0
        var generation: String = ""
    }

    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tomo/AgentApplications/Pi")
    }

    private var recordURL: URL { directory.appendingPathComponent("launch.json") }
    private var pidURL: URL { directory.appendingPathComponent("launcher.pid") }
    private var readyURL: URL { directory.appendingPathComponent("generation") }

    func activeLaunch() -> Launch? {
        guard let data = try? Data(contentsOf: recordURL),
              var launch = try? JSONDecoder().decode(Launch.self, from: data),
              let pidText = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
              kill(pid, 0) == 0 else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-ww", "-p", String(pid), "-o", "command="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let command = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        guard process.terminationStatus == 0, command == "/bin/zsh \(launch.scriptPath)",
              let generation = try? String(contentsOf: readyURL, encoding: .utf8), !generation.isEmpty else { return nil }
        launch.pid = pid
        launch.generation = generation
        return launch
    }

    func requestRestart(_ launch: Launch) throws {
        guard let active = activeLaunch(), active.pid == launch.pid, active.scriptPath == launch.scriptPath else {
            throw AgentApplicationError.piStartTimedOut
        }
        guard kill(active.pid, SIGUSR1) == 0 else { throw AgentApplicationError.piStartTimedOut }
    }

    func prepareLaunch() throws -> URL {
        guard let executable = AgentHookManager().locateExecutable(for: .pi) else {
            throw AgentApplicationError.notInstalled("Pi")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        // Remove launchers from completed sessions, keeping the current generated files bounded.
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where file.pathExtension == "command" {
            try FileManager.default.removeItem(at: file)
        }
        for file in [pidURL, readyURL] { try? FileManager.default.removeItem(at: file) }
        let script = directory.appendingPathComponent("Pi-\(UUID().uuidString).command")
        try launcherScript(executable: executable.path).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        try JSONEncoder().encode(Launch(scriptPath: script.path)).write(to: recordURL, options: .atomic)
        return script
    }

    func launcherScript(executable: String) -> String {
        """
        #!/bin/zsh
        # This terminal owns only the Pi child it launches.
        umask 077
        cd \(Self.quote(FileManager.default.homeDirectoryForCurrentUser.path)) || exit 1
        tomo_pi_child=0
        tomo_pi_restart=0
        tomo_pi_generation=0
        tomo_pi_cleanup() {
          if (( tomo_pi_child > 0 )); then kill -TERM "$tomo_pi_child" 2>/dev/null; fi
          rm -f \(Self.quote(pidURL.path)) \(Self.quote(readyURL.path))
        }
        tomo_pi_relaunch() {
          tomo_pi_restart=1
          if (( tomo_pi_child > 0 )); then kill -TERM "$tomo_pi_child" 2>/dev/null; fi
        }
        trap tomo_pi_cleanup EXIT
        trap tomo_pi_relaunch USR1
        trap 'exit 0' TERM HUP
        printf '%s\\n' "$$" > \(Self.quote(pidURL.path))
        printf '\\033]0;Tomo · Pi\\007'
        while true; do
          tomo_pi_restart=0
          \(Self.quote(executable)) < /dev/tty &
          tomo_pi_child=$!
          (( tomo_pi_generation += 1 ))
          printf '%s\\n' "$tomo_pi_generation" > \(Self.quote(readyURL.path))
          wait "$tomo_pi_child"
          # A signal can interrupt wait before the child has actually exited.
          if (( tomo_pi_restart != 0 )); then wait "$tomo_pi_child" 2>/dev/null; fi
          tomo_pi_child=0
          if (( tomo_pi_restart == 0 )); then break; fi
        done
        """
    }

    private static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
