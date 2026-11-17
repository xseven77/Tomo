import Foundation

/// Local owner configuration only. This type is deliberately not Codable and
/// cannot be supplied through any remote route or development grant.
struct ChatGPTLocalRuntimeConfiguration: Sendable {
    let executable: URL
    let home: URL
    let journalURL: URL
    let runtimeId: String
}

enum ChatGPTLocalRuntime {
    /// Starts a dedicated account-scoped vendor process. It observes only the
    /// threads explicitly resumed on this process, not another desktop/TUI's
    /// live execution merely because they share a storage directory.
    static func launch(configuration: ChatGPTLocalRuntimeConfiguration, service: RemoteSessionService,
                       environment suppliedEnvironment: [String: String] = ProcessInfo.processInfo.environment) async throws -> ChatGPTRuntimeCoordinator {
        let home = configuration.home.resolvingSymlinksInPath().standardizedFileURL
        let executable = configuration.executable.resolvingSymlinksInPath().standardizedFileURL
        guard home.isFileURL, executable.isFileURL, configuration.journalURL.isFileURL,
              try home.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
              try executable.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
              FileManager.default.isExecutableFile(atPath: executable.path),
              !configuration.runtimeId.isEmpty, configuration.runtimeId.utf8.count <= 256,
              !configuration.runtimeId.contains("\0") else { throw ChatGPTRuntimeError.invalidConfiguration }
        let journal = try RemoteSessionJournal(databaseURL: configuration.journalURL)
        var environment = suppliedEnvironment
        environment["CODEX_HOME"] = home.path
        let transport = try AgentStdioRPC(executable: executable, arguments: ["app-server", "--stdio"], environment: environment, directory: home)
        do {
            let runtime = try ChatGPTRuntimeCoordinator(serverId: service.serverId, runtimeId: configuration.runtimeId,
                channel: transport.channel, journal: journal, service: service, stopTransport: {await transport.stop()})
            try await runtime.start()
            return runtime
        } catch {
            await transport.stop()
            throw error
        }
    }
}
