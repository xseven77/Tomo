import XCTest
@testable import Tomo

extension XCTestCase {
    /// A fresh directory standing in for `~`, removed after the test.
    func makeTemporaryHome() -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tomo-home-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    /// A `GatewayStore` that cannot touch the developer's machine. Build every
    /// test store with this.
    ///
    /// The store's defaults read the user's Gateway token, account registry,
    /// model caches and Agent session stores, and `rotateAuthToken()` or a
    /// background catalog sync rewrites the API key and model list in the real
    /// `~/.hermes`, `~/.pi`, `~/.dsh`, `~/.codex` and `~/.cline`. Here all of
    /// them live in a temporary home instead (the Gateway settings and caches
    /// too, unless the test passes its own settings file). Hermes and Pi count
    /// as not installed, so their CLIs never run, and the Gateway is emulated
    /// by a supervisor of the store's own that reads the same settings file,
    /// as in the App.
    @MainActor
    func makeIsolatedGatewayStore(
        settingsStorage: GatewaySettingsStorage? = nil,
        dshConfigurator: DSHGatewayConfigurator? = nil,
        companionStatsStore: CompanionStatsStore? = nil
    ) -> GatewayStore {
        let home = makeTemporaryHome()
        let tomoSupport = home.appendingPathComponent("Library/Application Support/Tomo", isDirectory: true)
        let settingsStorage = settingsStorage
            ?? GatewaySettingsStorage(fileURL: tomoSupport.appendingPathComponent("gateway-settings.json"))
        let supervisor = GatewaySupervisor(reachesLoopbackGateway: false, settingsStorage: settingsStorage)
        addTeardownBlock { @MainActor in supervisor.stop() }
        // The store holds this weakly (in the App, AppDelegate owns it) and
        // falls back to the real companion_stats.json without it.
        let companionStatsStore = companionStatsStore
            ?? CompanionStatsStore(fileURL: tomoSupport.appendingPathComponent("companion_stats.json"))
        addTeardownBlock { @MainActor in withExtendedLifetime(companionStatsStore) {} }
        return GatewayStore(
            companionStatsStore: companionStatsStore,
            hermesConfigurator: HermesGatewayConfigurator(
                runner: MissingHermesCLI(),
                configURL: home.appendingPathComponent(".hermes/config.yaml")
            ),
            piConfigurator: PiGatewayConfigurator(
                runner: MissingPiCLI(),
                agentDirectory: home.appendingPathComponent(".pi/agent", isDirectory: true)
            ),
            dshConfigurator: dshConfigurator ?? DSHGatewayConfigurator(homeDirectory: home, environment: [:]),
            codexConfigurator: CodexGatewayConfigurator(
                codexHomeURL: home.appendingPathComponent(".codex", isDirectory: true),
                homeDirectory: home,
                allowShellFallback: false
            ),
            clineConfigurator: ClineGatewayConfigurator(
                clineHomeURL: home.appendingPathComponent(".cline", isDirectory: true),
                homeDirectory: home,
                allowShellFallback: false
            ),
            settingsStorage: settingsStorage,
            registryStorage: ConnectionRegistryStorage(
                fileURL: tomoSupport.appendingPathComponent("connections-v1.json")
            ),
            agentActivity: GatewayAgentActivityServices(
                antigravity: AntigravityActivityService(
                    antigravityRoot: home.appendingPathComponent(".gemini/antigravity", isDirectory: true)
                ),
                codex: CodexActivityService(
                    databaseURLs: [home.appendingPathComponent(".codex/state_5.sqlite")],
                    sessionIndexURLs: [home.appendingPathComponent(".codex/session_index.jsonl")]
                ),
                dsh: DSHActivityService(sessionsRoot: home.appendingPathComponent(".dsh/sessions", isDirectory: true)),
                hermes: HermesActivityService(databaseURL: home.appendingPathComponent(".hermes/state.db")),
                pi: PiActivityService(sessionsRoot: home.appendingPathComponent(".pi/agent/sessions", isDirectory: true)),
                cline: ClineActivityService(clineDataURL: home.appendingPathComponent(".cline/data", isDirectory: true))
            ),
            supervisor: supervisor
        )
    }
}

/// Hermes is not installed, so the configurator never starts its CLI (which
/// edits the real `~/.hermes/config.yaml` whatever `configURL` says).
private struct MissingHermesCLI: HermesCommandRunning {
    var isAvailable: Bool { false }
    var executableURL: URL? { nil }

    func run(arguments: [String]) throws -> HermesCommandResult {
        throw HermesGatewayConfigurationError.executableNotFound
    }
}

/// Pi is not installed, so the configurator never starts its CLI.
private struct MissingPiCLI: PiCommandRunning {
    var isAvailable: Bool { false }
    var executableURL: URL? { nil }

    func run(arguments: [String], agentDirectory: URL) throws -> PiCommandResult {
        throw PiGatewayConfigurationError.executableNotFound
    }
}
