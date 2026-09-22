import Foundation
import XCTest
@testable import Tomo

final class AgentHookManagerTests: XCTestCase {
    func testIntegrationStatusesListsFourSessionReadAgents() {
        let manager = AgentHookManager(homeDirectory: FileManager.default.temporaryDirectory)
        let statuses = manager.integrationStatuses()

        XCTAssertEqual(statuses.map(\.name), ["Codex", "Deepseek Harness", "Hermes", "Antigravity", "Pi"])
        XCTAssertEqual(
            statuses.map(\.detail),
            ["App Server · 本地活动", "Session JSONL · 会话读取", "Gateway JSON-RPC · 会话读取", "Transcript JSONL · 本地活动", "Session JSONL · 会话读取"]
        )
    }

    func testActivityArbitrationPrefersWaitingThenFailureThenActivity() {
        let now = Date()
        let result = AgentActivityArbitrator.preferred([
            AgentActivityCandidate(state: .thinking, updatedAt: now.addingTimeInterval(20)),
            AgentActivityCandidate(state: .failed, updatedAt: now.addingTimeInterval(10)),
            AgentActivityCandidate(state: .waitingForUser, updatedAt: now),
        ])
        XCTAssertEqual(result?.state, .waitingForUser)
    }

    func testHookEventReducerLetsWaitingAgentWinAndKeepsAllActiveTasks() {
        let now = Date()
        var reducer = AgentEventActivityReducer()
        reducer.ingest(NormalizedAgentEvent(
            agentID: .hermes,
            surfaceID: .hermesCLI,
            sessionID: "hermes-session",
            event: .toolStarted,
            timestamp: now
        ))
        reducer.ingest(NormalizedAgentEvent(
            agentID: .deepseekHarness,
            surfaceID: .deepseekHarnessCLI,
            sessionID: "dsh-session",
            event: .permissionRequested,
            timestamp: now.addingTimeInterval(1)
        ))

        let snapshot = reducer.mergedSnapshot(base: .unavailable, now: now.addingTimeInterval(2))
        XCTAssertEqual(snapshot.state, .waitingForUser)
        XCTAssertEqual(snapshot.threadTitle, "Deepseek Harness · CLI")
        XCTAssertEqual(snapshot.activeTaskCount, 2)
        XCTAssertEqual(Set(snapshot.activeTasks.map(\.title)), ["Hermes · CLI", "Deepseek Harness · CLI"])
        XCTAssertEqual(Set(snapshot.localAgentTasks.map(\.title)), ["Hermes · CLI", "Deepseek Harness · CLI"])
    }

    func testHookEventReducerKeepsIdleAgentInPetLocalSummaryOnly() {
        let now = Date()
        var reducer = AgentEventActivityReducer()
        reducer.ingest(NormalizedAgentEvent(
            agentID: .hermes,
            surfaceID: .hermesCLI,
            sessionID: "hermes-session",
            event: .sessionStarted,
            timestamp: now
        ))

        let snapshot = reducer.mergedSnapshot(base: .unavailable, now: now.addingTimeInterval(1))
        XCTAssertTrue(snapshot.activeTasks.isEmpty)
        XCTAssertEqual(snapshot.activeTaskCount, 0)
        XCTAssertEqual(snapshot.localAgentTasks.map(\.title), ["Hermes · CLI"])
        XCTAssertEqual(snapshot.localAgentTasks.first?.state, .idle)
    }

    func testBridgeWireFormatDecodesStringIdentifiers() throws {
        let connectionID = UUID()
        let json = """
        {"schemaVersion":1,"agentID":"agent.hermes","surfaceID":"surface.hermes-cli","connectionID":"\(connectionID.uuidString)","sessionID":"session-1","event":"permission.requested","timestamp":"2026-08-10T12:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let event = try decoder.decode(NormalizedAgentEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.agentID, .hermes)
        XCTAssertEqual(event.surfaceID, .hermesCLI)
        XCTAssertEqual(event.connectionID?.rawValue, connectionID)
        XCTAssertEqual(event.event, .permissionRequested)
    }

    func testCodexAppServerCapabilityGateRequiresAllUsedMethods() {
        let probe = CodexAppServerCapabilityProbe()
        let supported = probe.inspect(schemaData: Data(
            #"{"methods":["initialize","account/read","account/rateLimits/read","thread/list"]}"#.utf8
        ))
        XCTAssertTrue(supported.supported)

        let unsupported = probe.inspect(schemaData: Data(#"{"methods":["initialize","account/read"]}"#.utf8))
        XCTAssertFalse(unsupported.supported)
        XCTAssertEqual(Set(unsupported.missingMethods), ["account/rateLimits/read", "thread/list"])
    }

    func testCodexAppServerParsesAccountAndRateLimitFixture() throws {
        let account: [String: Any] = [
            "id": 2,
            "result": [
                "account": ["type": "chatgpt", "email": "work@example.com", "planType": "team"],
                "requiresOpenaiAuth": true,
            ],
        ]
        let limits: [String: Any] = [
            "id": 3,
            "result": [
                "rateLimits": [
                    "primary": ["usedPercent": 18, "windowDurationMins": 300, "resetsAt": 1_800_000_000],
                    "secondary": ["usedPercent": 24, "windowDurationMins": 10_080, "resetsAt": 1_800_100_000],
                ],
            ],
        ]
        let snapshot = try CodexAppServerSnapshotParser().parse(
            accountResponse: account,
            rateLimitResponse: limits
        )
        XCTAssertEqual(snapshot.email, "work@example.com")
        XCTAssertEqual(snapshot.planType, "team")
        XCTAssertEqual(snapshot.primary?.remainingPercent, 82)
        XCTAssertEqual(snapshot.secondary?.remainingPercent, 76)
    }

    func testHookEventReducerExpiresCompletionAndRemovesEndedSession() {
        let now = Date()
        var reducer = AgentEventActivityReducer()
        let completed = NormalizedAgentEvent(
            agentID: .deepseekHarness,
            surfaceID: .deepseekHarnessCLI,
            sessionID: "dsh-session",
            event: .turnCompleted,
            timestamp: now
        )
        reducer.ingest(completed)
        XCTAssertEqual(reducer.mergedSnapshot(base: .unavailable, now: now).state, .completed)
        XCTAssertEqual(
            reducer.mergedSnapshot(base: .unavailable, now: now.addingTimeInterval(16)).state,
            .unavailable
        )

        reducer.ingest(NormalizedAgentEvent(
            agentID: .hermes,
            surfaceID: .hermesCLI,
            sessionID: "ended",
            event: .toolStarted,
            timestamp: now
        ))
        reducer.ingest(NormalizedAgentEvent(
            agentID: .hermes,
            surfaceID: .hermesCLI,
            sessionID: "ended",
            event: .sessionEnded,
            timestamp: now.addingTimeInterval(1)
        ))
        XCTAssertEqual(reducer.mergedSnapshot(base: .unavailable, now: now.addingTimeInterval(2)).state, .unavailable)
    }

    func testCodexRuntimeCreatesSeparateFileCredentialHomes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexling-runtime-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = CodexAccountRuntimeManager(runtimesRoot: root)
        let work = try manager.createAccount(label: "Work")
        let personal = try manager.createAccount(label: "Personal")

        XCTAssertNotEqual(work.id, personal.id)
        XCTAssertNotEqual(work.relativeHomeDirectory, personal.relativeHomeDirectory)
        let workConfig = try String(contentsOf: manager.homeURL(for: work).appendingPathComponent("config.toml"), encoding: .utf8)
        let personalConfig = try String(contentsOf: manager.homeURL(for: personal).appendingPathComponent("config.toml"), encoding: .utf8)
        XCTAssertEqual(workConfig, "cli_auth_credentials_store = \"file\"\n")
        XCTAssertEqual(personalConfig, workConfig)

        let token = CodexOAuthToken(
            accessToken: "work-access",
            refreshToken: "work-refresh",
            idToken: "work-id",
            expiresAt: Date().addingTimeInterval(3_600),
            email: "work@example.com",
            displayName: "Work"
        )
        let workTokenStore = CodexOAuthTokenStore(fileURL: try manager.oauthTokenURL(for: work))
        let personalTokenStore = CodexOAuthTokenStore(fileURL: try manager.oauthTokenURL(for: personal))
        workTokenStore.save(token)

        let loadedToken = try XCTUnwrap(workTokenStore.load())
        XCTAssertEqual(loadedToken.accessToken, token.accessToken)
        XCTAssertEqual(loadedToken.refreshToken, token.refreshToken)
        XCTAssertEqual(loadedToken.idToken, token.idToken)
        XCTAssertEqual(loadedToken.email, token.email)
        XCTAssertEqual(loadedToken.displayName, token.displayName)
        XCTAssertEqual(loadedToken.expiresAt.timeIntervalSince1970, token.expiresAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertFalse(personalTokenStore.hasStoredToken())
    }

    func testConnectionRegistryRoundTripsDatesAndAccountScopedBalance() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexling-registry-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ConnectionRegistryStorage(fileURL: root.appendingPathComponent("connections.json"))
        let id = ConnectionID(rawValue: UUID())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = ConnectionRegistrySnapshot(
            codexAccounts: [],
            deepSeekConnections: [
                DeepSeekAPIConnection(
                    id: id,
                    label: "Personal Key",
                    credentialHandle: "opaque-handle",
                    keySuffix: "7A2F",
                    authenticationState: .connected,
                    balance: ProviderBalanceSnapshot(
                        connectionID: id,
                        providerID: .deepSeek,
                        scope: .account,
                        currency: "CNY",
                        total: Decimal(string: "42.80")!,
                        granted: Decimal(string: "4.80")!,
                        toppedUp: Decimal(string: "38.00")!,
                        fetchedAt: now
                    ),
                    createdAt: now
                ),
            ]
        )
        try storage.save(snapshot)

        let loaded = storage.load()
        XCTAssertEqual(loaded.deepSeekConnections.count, 1)
        XCTAssertEqual(loaded.deepSeekConnections[0].balance?.scope, .account)
        XCTAssertEqual(loaded.deepSeekConnections[0].balance?.total, Decimal(string: "42.80"))
        XCTAssertEqual(loaded.deepSeekConnections[0].createdAt, now)
    }

    func testAgentInstallGuideCatalogProvidesCompleteGuidesForAllAgents() {
        let agentIDs: [AgentID] = [.codex, .deepseekHarness, .hermes, .antigravity, .pi]
        for id in agentIDs {
            let guide = AgentInstallGuideCatalog.guide(for: id)
            XCTAssertFalse(guide.name.isEmpty, "Name should not be empty for \(id)")
            XCTAssertFalse(guide.tagline.isEmpty, "Tagline should not be empty for \(id)")
            XCTAssertFalse(guide.summary.isEmpty, "Summary should not be empty for \(id)")
            XCTAssertFalse(guide.methods.isEmpty, "Methods should not be empty for \(id)")
        }
    }

    func testHermesAndPiInstallGuideConfigurations() {
        let hermesGuide = AgentInstallGuideCatalog.guide(for: .hermes)
        XCTAssertEqual(hermesGuide.documentationURLString, "https://github.com/NousResearch/hermes-agent")
        XCTAssertEqual(hermesGuide.methods.count, 1)
        XCTAssertEqual(hermesGuide.methods.first?.command, "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash")

        let piGuide = AgentInstallGuideCatalog.guide(for: .pi)
        XCTAssertEqual(piGuide.documentationURLString, "https://pi.dev/")
        XCTAssertEqual(piGuide.methods.count, 1)
        XCTAssertEqual(piGuide.methods.first?.command, "curl -fsSL https://pi.dev/install.sh | sh")
    }

    func testAgentIntegrationStatusGuideAndInstalledProperties() {
        var status = AgentIntegrationStatus(
            id: .hermes,
            name: "Hermes",
            priority: 2,
            cliInstalled: false,
            desktopInstalled: false,
            detail: "Gateway JSON-RPC · 会话读取"
        )
        XCTAssertFalse(status.isInstalled)
        XCTAssertEqual(status.guide.name, "Hermes")

        status.cliInstalled = true
        XCTAssertTrue(status.isInstalled)

        status.cliInstalled = false
        status.environmentConfigured = true
        XCTAssertTrue(status.isInstalled)
    }

    func testIntegrationStatusesDetectsDSHViaNVMAndDataDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentHookManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 模拟未安装时：
        let managerEmpty = AgentHookManager(homeDirectory: tempDir, allowShellFallback: false)
        let emptyDSH = try XCTUnwrap(managerEmpty.integrationStatuses().first(where: { $0.id == .deepseekHarness }))
        XCTAssertFalse(emptyDSH.isInstalled)

        // 模拟通过 NVM 安装：~/.nvm/versions/node/v24.15.0/bin/dsh
        let nvmBin = tempDir.appendingPathComponent(".nvm/versions/node/v24.15.0/bin")
        try FileManager.default.createDirectory(at: nvmBin, withIntermediateDirectories: true)
        let fakeDSH = nvmBin.appendingPathComponent("dsh")
        FileManager.default.createFile(atPath: fakeDSH.path, contents: Data("#!/bin/sh\nexit 0".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeDSH.path)

        let managerWithCLI = AgentHookManager(homeDirectory: tempDir, allowShellFallback: false)
        let dshWithCLI = try XCTUnwrap(managerWithCLI.integrationStatuses().first(where: { $0.id == .deepseekHarness }))
        XCTAssertTrue(dshWithCLI.cliInstalled)
        XCTAssertTrue(dshWithCLI.isInstalled)

        // 模拟通过 ~/.dsh 数据目录感知：
        try FileManager.default.removeItem(at: tempDir.appendingPathComponent(".nvm"))
        let dshDataDir = tempDir.appendingPathComponent(".dsh")
        try FileManager.default.createDirectory(at: dshDataDir, withIntermediateDirectories: true)

        let managerWithData = AgentHookManager(homeDirectory: tempDir, allowShellFallback: false)
        let dshWithData = try XCTUnwrap(managerWithData.integrationStatuses().first(where: { $0.id == .deepseekHarness }))
        XCTAssertTrue(dshWithData.environmentConfigured)
        XCTAssertTrue(dshWithData.isInstalled)
    }
}
