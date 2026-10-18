import Foundation

enum PhoneConversationExecutable {
    /// Known local installations only. No shell, download, or caller-supplied
    /// network path is involved in the one-switch conversation setup.
    static func locate(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                       applications: URL = URL(fileURLWithPath: "/Applications"),
                       bins: [URL] = [URL(fileURLWithPath: "/opt/homebrew/bin/codex"), URL(fileURLWithPath: "/usr/local/bin/codex")]) throws -> URL {
        // GUI launches do not inherit a shell's Node/NVM PATH. Prefer the
        // self-contained app runtime over npm's executable node wrapper.
        let candidates = [applications, home.appendingPathComponent("Applications")].flatMap { root in
                [root.appendingPathComponent("Codex.app/Contents/Resources/codex"),
                 root.appendingPathComponent("ChatGPT.app/Contents/Resources/codex-cli/bin/codex")]
            } + bins + [home.appendingPathComponent(".local/bin/codex")]
        for candidate in candidates {
            let file = candidate.resolvingSymlinksInPath().standardizedFileURL
            if file.isFileURL, (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
               FileManager.default.isExecutableFile(atPath: file.path) {return file}
        }
        throw CodexAccountRuntimeError.codexNotInstalled
    }
}
