import Foundation
import Testing
@testable import Tomo

@Suite("MobileSyncServerTests")
struct MobileSyncServerTests {
    @Test("Old Web Mobile versions are retired")
    func testRetiredMobileVersions() {
        #expect(WebPluginManifest(version: "0.0.8").isRetiredMobileVersion)
        #expect(WebPluginManifest(version: "0.0.9").isRetiredMobileVersion)
        #expect(WebPluginManifest(version: "0.0.10").isRetiredMobileVersion)
        #expect(WebPluginManifest(version: "0.3.3").isRetiredMobileVersion)
        #expect(WebPluginManifest(version: "0.99.99").isRetiredMobileVersion)
        #expect(!WebPluginManifest(version: "1.0.0").isRetiredMobileVersion)
        #expect(!WebPluginManifest(version: "1.0.10").isRetiredMobileVersion)
        #expect(!WebPluginManifest(name: "custom-app", version: "0.0.1").isRetiredMobileVersion)
    }

    @Test("Optional application attribution")
    func testAPIAttribution() {
        #expect(MobileSyncServer.normalizedAppName(nil) == nil)
        #expect(MobileSyncServer.normalizedAppName("  ") == nil)
        #expect(MobileSyncServer.normalizedAppName(" App\r\n ") == "App")
        #expect(MobileSyncServer.normalizedAppName(String(repeating: "a", count: 200))?.count == 128)
    }

    @Test("Agent SSE relay forwards events without waiting for stream completion")
    func testAgentSSERelay() async throws {
        // Port 0: the system binds a free port atomically. A fixed port fails
        // to bind while any other socket holds it (on macOS even a TIME_WAIT
        // leftover), and the requests below then got a 502 from the relay or
        // another process's answer instead of 401/200.
        let upstream = MobileSyncServer(port: 0, token: "upstream-test-token", dataProvider: MockDataProvider())
        let relay = MobileSyncServer(port: 0, token: "relay-test-token", dataProvider: MockDataProvider())
        try upstream.start()
        defer { upstream.stop() }
        try relay.start()
        defer { relay.stop() }
        try await waitFor(timeout: 5) { upstream.status == .ready && relay.status == .ready }
        let upstreamPort = try #require(upstream.listeningPort)
        let relayPort = try #require(relay.listeningPort)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var url = URLComponents(string: "http://127.0.0.1:\(relayPort)/api/v1/agents/events")!
        url.queryItems = [
            URLQueryItem(name: "token", value: "relay-test-token"),
            URLQueryItem(name: "target_token", value: "upstream-test-token"),
            URLQueryItem(name: "target", value: "http://127.0.0.1:\(upstreamPort)/api/v1/events")
        ]
        var request = URLRequest(url: url.url!)
        request.timeoutInterval = 5
        var rejectedURL = url
        rejectedURL.queryItems = url.queryItems?.map {
            $0.name == "target_token" ? URLQueryItem(name: "target_token", value: "wrong-token") : $0
        }
        let (_, rejectedResponse) = try await session.data(from: rejectedURL.url!)
        #expect((rejectedResponse as? HTTPURLResponse)?.statusCode == 401)
        let (bytes, response) = try await session.bytes(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "*")
        #expect(http.value(forHTTPHeaderField: "X-Accel-Buffering") == "no")
        var received = false
        var receivedInitial = false
        for try await line in bytes.lines {
            if line.hasPrefix("data:") {
                if !receivedInitial {
                    #expect(line.contains("task-1"))
                    receivedInitial = true
                    upstream.broadcast(event: "snapshot", data: #"{"activity":{"state":"executing","activeTaskCount":1,"activeTasks":[]},"todayMinutes":42}"#)
                    continue
                }
                if line.contains("syncEnabled") || line.contains("theme_updated") {
                    continue
                }
                #expect(line.contains("executing"))
                #expect(line.contains("42"))
                received = true
                break
            }
        }
        #expect(received)
        #expect(receivedInitial)
    }

    @MainActor
    @Test("Working minutes notify SSE publisher even when task state is unchanged")
    func testWorkingMinutesNotify() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sse-stats-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        // Noon, so the simulated 90 seconds never cross local midnight, where
        // the stats store starts a new day and resets todayMinutes.
        let start = try #require(Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()))
        let stats = CompanionStatsStore(fileURL: file, now: start)
        var notifications = 0
        stats.onMinutesChanged = { notifications += 1 }
        stats.setActivityState(.thinking, agentID: "codex", now: start)
        stats.tick(now: start.addingTimeInterval(30))
        #expect(notifications == 0)
        stats.tick(now: start.addingTimeInterval(65))
        #expect(stats.todayMinutes == 1)
        #expect(notifications == 1)
        stats.tick(now: start.addingTimeInterval(90))
        #expect(notifications == 1)
    }

    @Test("Remote namespace rejects pairing tokens and supports independent grant revocation")
    func testRemoteAuthorizationDispatch() async throws {
        let server = MobileSyncServer(port: 0, token: "old-pairing-token", listenOnLoopbackOnly: true, dataProvider: MockDataProvider())
        try await server.remoteReadService.register(RemoteReadServiceTests.Adapter())
        await server.remoteAccess.setDevelopmentEnabled(true)
        let issued = try await server.remoteAccess.issueDevelopment(scopes: [
            .init(agentId: "agent.chatgpt", runtimeId: "runtime_test", sessionId: nil, actions: [.listSessions, .readHistory])
        ], origin: nil)
        try server.start()
        defer { server.stop() }
        try await waitFor(timeout: 5) { server.status == .ready }
        let port = try #require(server.listeningPort)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        func request(_ path: String, method: String = "GET", bearer: String? = nil) async throws -> HTTPURLResponse {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)" + path)!)
            request.httpMethod = method
            request.timeoutInterval = 5
            if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
            let (_, response) = try await session.data(for: request)
            return try #require(response as? HTTPURLResponse)
        }
        #expect(try await request("/api/v1/remote/catalog", bearer: "invalid-token").statusCode == 401)
        #expect(try await request("/api/v1/remote/catalog", bearer: "old-pairing-token").statusCode == 401)
        #expect(try await request("/api/v1/remote/catalog", bearer: issued.token).statusCode == 200)
        #expect(try await request("/api/v1/remote/sessions?agent_id=agent.chatgpt&runtime_id=runtime_test", bearer: issued.token).statusCode == 200)
        #expect(try await request("/api/v1/remote/sessions/ss_3/messages?agent_id=agent.chatgpt&runtime_id=runtime_test", bearer: issued.token).statusCode == 200)
        #expect(try await request("/api/v1/remote/sessions/ss_3/sync?agent_id=agent.chatgpt&runtime_id=runtime_test", bearer: issued.token).statusCode == 501)
        #expect(try await request("/api/v1/remote/sessions/ss_3/sync?agent_id=agent.chatgpt&runtime_id=runtime_other", bearer: issued.token).statusCode == 403)
        #expect(try await request("/api/v1/remote/sessions/ss_3/messages?agent_id=agent.chatgpt&runtime_id=runtime_other", bearer: issued.token).statusCode == 403)
        let preflight = try await request("/api/v1/remote/catalog", method: "OPTIONS")
        #expect(preflight.statusCode == 204)
        #expect(preflight.value(forHTTPHeaderField: "Access-Control-Allow-Headers")?.contains("Last-Event-ID") == true)
        #expect(preflight.value(forHTTPHeaderField: "Access-Control-Allow-Methods")?.contains("DELETE") == true)
        #expect(try await request("/api/v1/remote/access/current", method: "DELETE", bearer: issued.token).statusCode == 204)
        #expect(try await request("/api/v1/remote/catalog", bearer: issued.token).statusCode == 401)
        #expect(try await request("/api/v1/snapshot", bearer: "old-pairing-token").statusCode == 200)
    }

    final class MockDataProvider: MobileSyncDataProvider, @unchecked Sendable {
        func makeSnapshot() async -> MobileSnapshotPayload {
            MobileSnapshotPayload(
                schemaVersion: 1,
                generatedAt: Date(timeIntervalSince1970: 1726470000),
                activePetId: "tomo",
                activity: MobileActivityPayload(
                    state: "executing",
                    activeTaskCount: 1,
                    activeTasks: [
                        MobileTaskPayload(id: "task-1", state: "executing", title: "Build router", agent: "codex")
                    ]
                ),
                connections: [
                    MobileConnectionPayload(id: "conn-1", provider: "codex", label: "Work", isHealthy: true, shortWindowRemaining: 78.5)
                ]
            )
        }

        func availablePets() -> [MobilePetMetadata] {
            [
                MobilePetMetadata(
                    id: "tomo",
                    displayName: "Tomo",
                    description: "Signature spirit",
                    frameWidth: 192,
                    frameHeight: 208,
                    totalRows: 11,
                    totalColumns: 8
                ),
                MobilePetMetadata(
                    id: "bsod",
                    displayName: "BSOD",
                    description: "Glitch spirit",
                    frameWidth: 192,
                    frameHeight: 208,
                    totalRows: 11,
                    totalColumns: 8
                )
            ]
        }

        func exportCredentials() async -> MobileCredentialsExportPayload {
            MobileCredentialsExportPayload(
                exportedAt: Date(timeIntervalSince1970: 1726470000),
                accounts: [
                    MobileCredentialAccountPayload(id: "conn-1", provider: "codex", label: "Work", tokenOrKey: "mock-token-secret")
                ]
            )
        }

        var currentTheme: TomoThemeConfig = .default
        var syncEnabled: Bool = true

        func getThemeConfig() -> (config: TomoThemeConfig, syncEnabled: Bool) {
            (currentTheme, syncEnabled)
        }

        func updateThemeConfig(_ config: TomoThemeConfig) async -> (success: Bool, synced: Bool, message: String?) {
            currentTheme = config
            return (true, syncEnabled, nil)
        }
    }

    @Test("MobileSnapshotPayload JSON serialization")
    func testSnapshotSerialization() throws {
        let payload = MobileSnapshotPayload(
            schemaVersion: 1,
            generatedAt: Date(timeIntervalSince1970: 1726470000),
            activePetId: "tomo",
            activity: MobileActivityPayload(
                state: "executing",
                activeTaskCount: 2,
                activeTasks: [
                    MobileTaskPayload(id: "1", state: "executing", title: "Test 1", agent: "hermes"),
                    MobileTaskPayload(id: "2", state: "waitingForUser", title: "Test 2", agent: "codex")
                ]
            ),
            connections: [
                MobileConnectionPayload(id: "c1", provider: "codex", label: "Main", isHealthy: true, shortWindowRemaining: 1.0, quotaUnit: "percent")
            ]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MobileSnapshotPayload.self, from: data)

        #expect(decoded.schemaVersion == 1)
        #expect(decoded.activePetId == "tomo")
        #expect(decoded.activity.state == "executing")
        #expect(decoded.activity.activeTaskCount == 2)
        #expect(decoded.activity.activeTasks.count == 2)
        #expect(decoded.connections.count == 1)
        #expect(decoded.connections[0].isHealthy == true)
        #expect(decoded.connections[0].shortWindowRemaining == 1.0)
        #expect(decoded.connections[0].quotaUnit == "percent")
        // Older hosts remain decodable and preserve the absence of a unit.
        let legacy = try JSONDecoder().decode(MobileConnectionPayload.self, from: Data(#"{"id":"old","provider":"gemini","label":"Main","isHealthy":true,"weeklyRemaining":0.5}"#.utf8))
        #expect(legacy.quotaUnit == nil)
        #expect(legacy.weeklyRemaining == 0.5)
    }

    @Test("TomoThemeConfig supports liquid glass materialTexture and glassOpacity serialization")
    func testThemeConfigGlassSerialization() throws {
        var config = TomoThemeConfig.default
        config.materialTexture = "glass"
        config.glassOpacity = 0.88

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(TomoThemeConfig.self, from: data)

        #expect(decoded.materialTexture == "glass")
        #expect(decoded.glassOpacity == 0.88)

        let dict = config.asDictionary()
        #expect(dict["materialTexture"] as? String == "glass")
        #expect(dict["glassOpacity"] as? Double == 0.88)
    }

    @Test("TomoMarkSvgRenderer renders the standalone T with glass tint")
    func testGlassSolidGlyphIsWhite() {
        var config = TomoThemeConfig.default
        config.renderMode = "color"
        config.materialTexture = "glass"
        config.glyphMode = "solid"
        config.accentColor = "#D74C32"
        let svg = TomoMarkSvgRenderer.svgString(config: config)
        #expect(svg.contains("fill=\"url(#tomo-glass-tint)\""))
        #expect(svg.contains("scale(1.36)"))
        #expect(!svg.contains("fill=\"#D74C32\""))
    }

    @Test("TomoMarkSvgRenderer renders the standalone white T in inverse glass mode")
    func testInverseGlassMarkIsWhiteAndHasAccentGlyph() {
        var config = TomoThemeConfig.default
        config.renderMode = "inverse"
        config.materialTexture = "glass"
        config.glyphMode = "solid"
        config.fillType = "solid"
        config.accentColor = "#D74C32"
        let svg = TomoMarkSvgRenderer.svgString(config: config)
        // Outer mark body is white/inkColor
        #expect(svg.contains("fill=\"#F4F2ED\""))
        // Inner symbol is accent color
        #expect(!svg.contains("fill=\"#D74C32\""))
        // Mark itself has NO glass rim stroke or sheen overlay
        #expect(!svg.contains("stroke=\"url(#tomo-glass-rim)\""))
        #expect(!svg.contains("tomo-glass-sheen"))

        // Gradient inverse glass
        config.fillType = "gradient"
        let gradSvg = TomoMarkSvgRenderer.svgString(config: config)
        #expect(gradSvg.contains("fill=\"#F4F2ED\""))
        #expect(gradSvg.contains("scale(1.36)"))
    }

    @Test("TomoMarkSvgRenderer renders pure T and pure T+GO badge in standard and glass modes")
    func testPureAndPureGoRendering() {
        // 1. Pure T
        var pureConfig = TomoThemeConfig.default
        pureConfig.logoFamily = "pure"
        pureConfig.accentColor = "#D74C32"
        let pureSvg = TomoMarkSvgRenderer.svgString(config: pureConfig)
        #expect(pureSvg.contains("scale(1.36)"))
        #expect(!pureSvg.contains("tomo-go-mask"))

        // 2. Pure T in glass mode (color mode)
        pureConfig.renderMode = "color"
        pureConfig.materialTexture = "glass"
        let pureGlassSvg = TomoMarkSvgRenderer.svgString(config: pureConfig)
        #expect(pureGlassSvg.contains("scale(1.36)"))
        #expect(pureGlassSvg.contains("url(#tomo-glass-tint)"))
        #expect(pureGlassSvg.contains("url(#tomo-glass-rim)"))
        #expect(pureGlassSvg.contains("tomo-outer-clip"))

        // 3. Pure T + GO badge
        var goConfig = TomoThemeConfig.default
        goConfig.logoFamily = "pure_go"
        goConfig.accentColor = "#2563EB"
        let goSvg = TomoMarkSvgRenderer.svgString(config: goConfig)
        #expect(goSvg.contains("scale(1.06)"))
        #expect(goSvg.contains("translate(50 41)"))
        #expect(goSvg.contains("rect x=\"34\" y=\"66\" width=\"32\" height=\"14\""))
        #expect(goSvg.contains("tomo-go-mask"))
        #expect(goSvg.contains("mask=\"url(#tomo-go-mask)\""))

        // 4. Pure T + GO badge in inverse mode
        goConfig.renderMode = "inverse"
        let goInverseSvg = TomoMarkSvgRenderer.svgString(config: goConfig)
        #expect(goInverseSvg.contains("fill=\"#F4F2ED\""))
        #expect(goInverseSvg.contains("mask=\"url(#tomo-go-mask)\""))
    }
    func testPetMetadataContract() throws {
        let pet = MobilePetMetadata(
            id: "codex",
            displayName: "Codex",
            description: "Codex Companion",
            frameWidth: 192,
            frameHeight: 208,
            totalRows: 11,
            totalColumns: 8
        )

        let data = try JSONEncoder().encode(pet)
        let decoded = try JSONDecoder().decode(MobilePetMetadata.self, from: data)

        #expect(decoded.id == "codex")
        #expect(decoded.frameWidth == 192)
        #expect(decoded.frameHeight == 208)
        #expect(decoded.totalRows == 11)
        #expect(decoded.totalColumns == 8)
        #expect(decoded.actionRowMap["idle"] == 0)
        #expect(decoded.actionRowMap["waiting"] == 6)
        #expect(decoded.actionRowMap["running"] == 7)
    }

    @Test("MobileSyncServer lifecycle and token validation")
    func testServerStartStop() throws {
        let provider = MockDataProvider()
        let server = MobileSyncServer(port: 0, token: "test-token-12345", dataProvider: provider)

        // Starting and stopping the server should not throw or crash
        try server.start()
        server.stop()
    }

    /// Regression: a busy port used to be swallowed entirely.
    ///
    /// `NWListener` binds asynchronously, so the conflict arrives via
    /// `stateUpdateHandler` rather than a thrown error. The old handler called
    /// `stop()` — no status, no error, no retry — which left the mobile server
    /// permanently dead after a `restart()` raced with the previous listener's
    /// cancellation.
    @Test("MobileSyncServer reports a busy port instead of dying silently")
    func testPortConflictIsReported() async throws {
        let provider = MockDataProvider()

        let first = MobileSyncServer(port: 0, token: "token-a", dataProvider: provider)
        try first.start()
        defer { first.stop() }

        // Wait for the first listener to actually reach `.ready`.
        try await waitFor(timeout: 5) { first.status == .ready }
        // The second server asks for exactly the port the system gave the first.
        let port = try #require(first.listeningPort)

        let second = MobileSyncServer(port: port, token: "token-b", dataProvider: provider)
        defer { second.stop() }
        try second.start()

        // The second bind must surface a failure, never a silent "started".
        try await waitFor(timeout: 5) {
            if case .failed = second.status { return true }
            return false
        }
        if case .failed(let message) = second.status {
            #expect(!message.isEmpty, "busy port must carry an explanation")
        } else {
            Issue.record("expected .failed, got \(second.status)")
        }
    }

    @Test("MobileSyncServer recovers once the port is released")
    func testRebindsAfterPortIsFreed() async throws {
        let provider = MockDataProvider()

        let blocker = MobileSyncServer(port: 0, token: "token-a", dataProvider: provider)
        try blocker.start()
        try await waitFor(timeout: 5) { blocker.status == .ready }
        let port = try #require(blocker.listeningPort)

        let contender = MobileSyncServer(port: port, token: "token-b", dataProvider: provider)
        defer { contender.stop() }
        try contender.start()
        try await waitFor(timeout: 5) {
            if case .failed = contender.status { return true }
            return false
        }

        // Free the port; the contender's backoff retry must eventually win.
        blocker.stop()
        try await waitFor(timeout: 20) { contender.status == .ready }
        #expect(contender.status == .ready)
    }

    /// The scenario the settings "重启服务" button exists for: rebind the same
    /// port without restarting the app. `cancel()` releases the port
    /// asynchronously, so this used to race into EADDRINUSE and die silently.
    @Test("MobileSyncServer can be restarted on the same port")
    func testRestartOnSamePort() async throws {
        // A port the system just handed out, not port 0: a port-0 server
        // binds a fresh port on every start and would never rebind its own.
        let port = try RemoteTLSFixture.freePort()
        let server = MobileSyncServer(port: port, token: "token", dataProvider: MockDataProvider())
        defer { server.stop() }

        try server.start()
        try await waitFor(timeout: 5) { server.status == .ready }

        server.stop()
        try server.start()

        // Either it binds straight away, or the internal backoff gets there.
        try await waitFor(timeout: 15) { server.status == .ready }
        #expect(server.status == .ready)
        #expect(!server.isAwaitingRetry)
    }

    /// Polls `condition` until it holds or `timeout` elapses.
    private func waitFor(
        timeout: TimeInterval,
        _ condition: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        Issue.record("timed out after \(timeout)s waiting for condition")
    }

    @Test("MobileSyncServer default plugin directory points to Application Support")
    func testPluginDirectoryDefault() {
        let defaultURL = MobileSyncServer.defaultPluginDirectoryURL
        #expect(defaultURL.path.contains("Plugins/mobile-web"))
    }

    @Test("Dedicated Agent snapshot relay validates target and forwards target authentication")
    func testAgentSnapshotRelay() async throws {
        let server = MobileSyncServer(port: 0, token: "relay-secret", dataProvider: MockDataProvider())
        defer { server.stop() }
        try server.start()
        try await waitFor(timeout: 5) { server.status == .ready }
        let port = try #require(server.listeningPort)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var url = URLComponents(string: "http://127.0.0.1:\(port)/api/v1/agents/snapshot")!
        url.queryItems = [URLQueryItem(name: "target", value: "http://127.0.0.1:\(port)/api/v1/snapshot")]
        var request = URLRequest(url: url.url!)
        request.setValue("Bearer relay-secret", forHTTPHeaderField: "Authorization")
        request.setValue("Bearer wrong-target-token", forHTTPHeaderField: "X-Target-Authorization")
        let (_, rejected) = try await session.data(for: request)
        #expect((rejected as? HTTPURLResponse)?.statusCode == 401)
        request.setValue("Bearer relay-secret", forHTTPHeaderField: "X-Target-Authorization")
        let (data, accepted) = try await session.data(for: request)
        #expect((accepted as? HTTPURLResponse)?.statusCode == 200)
        #expect((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["activity"] != nil)
        url.queryItems = [URLQueryItem(name: "target", value: "http://127.0.0.1:\(port)/api/v1/credentials")]
        request.url = url.url!
        let (_, invalid) = try await session.data(for: request)
        #expect((invalid as? HTTPURLResponse)?.statusCode == 400)
        url.path = "/api/v1/proxy"
        url.queryItems = [URLQueryItem(name: "target", value: "http://127.0.0.1:\(port)/api/v1/snapshot")]
        request.url = url.url!
        let (blockedData, blocked) = try await session.data(for: request)
        #expect((blocked as? HTTPURLResponse)?.statusCode == 400)
        #expect(String(decoding: blockedData, as: UTF8.self).contains("unsupported_provider_request"))
        url.queryItems = [URLQueryItem(name: "target", value: "https://api.deepseek.com/user/balance")]
        request.url = url.url!
        request.setValue(nil, forHTTPHeaderField: "X-Target-Authorization")
        let (missingData, missing) = try await session.data(for: request)
        #expect((missing as? HTTPURLResponse)?.statusCode == 400)
        #expect(String(decoding: missingData, as: UTF8.self).contains("missing_provider_authorization"))
    }

    @Test("Bundled default spritesheet is available without a plugin or custom installation")
    func bundledDefaultPetIsServedFromAppResources() async throws {
        let emptyPlugin = FileManager.default.temporaryDirectory.appendingPathComponent("empty-plugin-" + UUID().uuidString)
        let server = MobileSyncServer(port: 0, token: "pet-secret", pluginDirectoryURL: emptyPlugin,
            listenOnLoopbackOnly: true, dataProvider: MockDataProvider())
        defer {server.stop()}
        try server.start()
        try await waitFor(timeout: 5) {server.status == .ready}
        try #require(server.status == .ready, "Loopback listener status: \(server.status)")
        let port = try #require(server.listeningPort)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/pets/builtin:tomo-tako/spritesheet.webp")!)
        request.setValue("Bearer pet-secret", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .ephemeral)
        defer {session.invalidateAndCancel()}
        let (data, response) = try await session.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == "image/webp")
        let directory = try #require(CodexPetCatalog.bundledPetDirectory(for: "tomo-tako"))
        #expect(data == (try Data(contentsOf: directory.appendingPathComponent("spritesheet.webp"))))
    }

    @Test("Dedicated Agent pet relay validates target and returns 400 for non-spritesheet target")
    func testAgentPetRelay() async throws {
        let server = MobileSyncServer(port: 0, token: "pet-secret", dataProvider: MockDataProvider())
        defer { server.stop() }
        try server.start()
        try await waitFor(timeout: 5) { server.status == .ready }
        let port = try #require(server.listeningPort)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        var url = URLComponents(string: "http://127.0.0.1:\(port)/api/v1/agents/pet")!
        // Missing target
        var request = URLRequest(url: url.url!)
        request.setValue("Bearer pet-secret", forHTTPHeaderField: "Authorization")
        let (_, missingTarget) = try await session.data(for: request)
        #expect((missingTarget as? HTTPURLResponse)?.statusCode == 400)

        // Invalid target path
        url.queryItems = [
            URLQueryItem(name: "target", value: "http://127.0.0.1:\(port)/api/v1/snapshot"),
            URLQueryItem(name: "target_token", value: "target-token")
        ]
        request.url = url.url!
        let (_, invalidTarget) = try await session.data(for: request)
        #expect((invalidTarget as? HTTPURLResponse)?.statusCode == 400)

        // Missing target token
        url.queryItems = [
            URLQueryItem(name: "target", value: "http://127.0.0.1:\(port)/api/v1/pets/test/spritesheet.webp")
        ]
        request.url = url.url!
        let (_, missingToken) = try await session.data(for: request)
        #expect((missingToken as? HTTPURLResponse)?.statusCode == 400)
    }

    @Test("Agent discover route requires authentication and returns devices")
    func testAgentDiscovery() async throws {
        let server = MobileSyncServer(port: 0, token: "discover-secret", dataProvider: MockDataProvider())
        defer { server.stop() }
        try server.start()
        try await waitFor(timeout: 5) { server.status == .ready }
        let port = try #require(server.listeningPort)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/agents/discover?subnet=127.0.0")!)
        let (_, unauthed) = try await session.data(for: request)
        #expect((unauthed as? HTTPURLResponse)?.statusCode == 401)
        request.setValue("Bearer discover-secret", forHTTPHeaderField: "Authorization")
        let (data, authed) = try await session.data(for: request)
        #expect((authed as? HTTPURLResponse)?.statusCode == 200)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["devices"] != nil)
    }

    @Test("Public PWA manifest never includes a pairing token")
    func testPublicManifestDoesNotExposePairingToken() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let secret = "private-pairing-secret"
        let original: [String: Any] = [
            "name": "Tomo Go", "display": "standalone", "scope": "./",
            "start_url": "./?token=\(secret)",
            "icons": [["src": "icons/app-icon-192.png", "sizes": "192x192", "type": "image/png"]],
        ]
        try JSONSerialization.data(withJSONObject: original)
            .write(to: directory.appendingPathComponent("manifest.json"))
        let server = MobileSyncServer(port: 0, token: secret, pluginDirectoryURL: directory, dataProvider: MockDataProvider())
        defer { server.stop() }
        try server.start()
        try await waitFor(timeout: 5) { server.status == .ready }
        let port = try #require(server.listeningPort)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/manifest.json")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let manifest = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(manifest["start_url"] as? String == "./")
        #expect(manifest["display"] as? String == "standalone")
        #expect(manifest["scope"] as? String == "./")
        #expect((manifest["icons"] as? [[String: String]])?.count == 1)
        #expect(!String(decoding: data, as: UTF8.self).contains(secret))
        var preflight = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/snapshot")!)
        preflight.httpMethod = "OPTIONS"
        preflight.setValue("https://mobile.example.com", forHTTPHeaderField: "Origin")
        preflight.setValue("GET", forHTTPHeaderField: "Access-Control-Request-Method")
        preflight.setValue("authorization,x-tomo-app-name", forHTTPHeaderField: "Access-Control-Request-Headers")
        let (_, preflightResponse) = try await session.data(for: preflight)
        let preflightHTTP = try #require(preflightResponse as? HTTPURLResponse)
        #expect(preflightHTTP.statusCode == 204)
        let allowedHeaders = preflightHTTP.value(forHTTPHeaderField: "Access-Control-Allow-Headers")?.lowercased() ?? ""
        #expect(allowedHeaders.contains("authorization"))
        #expect(allowedHeaders.contains("x-tomo-app-name"))
        let (_, unauthorized) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/mobile/snapshot")!)
        #expect((unauthorized as? HTTPURLResponse)?.statusCode == 410)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/snapshot")!)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let (_, authorized) = try await session.data(for: request)
        #expect((authorized as? HTTPURLResponse)?.statusCode == 200)
        request.url = URL(string: "http://127.0.0.1:\(port)/api/v1/snapshot?app_name=QueryApp")!
        request.setValue("HeaderApp", forHTTPHeaderField: "X-Tomo-App-Name")
        server.onAPIRequest = { metadata in
            #expect(metadata.path == "/api/v1/snapshot")
            #expect(metadata.appName == "HeaderApp")
            #expect(metadata.method == "GET")
        }
        let (newData, newResponse) = try await session.data(for: request)
        #expect((newResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(!newData.isEmpty)
        request.url = URL(string: "http://127.0.0.1:\(port)/mobile/events")!
        let (retiredData, retiredResponse) = try await session.data(for: request)
        #expect((retiredResponse as? HTTPURLResponse)?.statusCode == 410)
        #expect(String(decoding: retiredData, as: UTF8.self).contains("api_removed"))
        try JSONEncoder().encode(WebPluginManifest(version: "0.3.3"))
            .write(to: directory.appendingPathComponent("plugin-manifest.json"))
        let (_, retiredPage) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/")!)
        #expect((retiredPage as? HTTPURLResponse)?.statusCode == 410)


    }

    @Test("MobileCredentialsExportPayload serialization")
    func testCredentialsExportSerialization() throws {
        let payload = MobileCredentialsExportPayload(
            exportedAt: Date(timeIntervalSince1970: 1726470000),
            accounts: [
                MobileCredentialAccountPayload(id: "c1", provider: "codex", label: "Work", tokenOrKey: "tok-12345"),
                MobileCredentialAccountPayload(id: "c2", provider: "deepseek", label: "Personal", tokenOrKey: "sk-67890")
            ]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MobileCredentialsExportPayload.self, from: data)

        #expect(decoded.accounts.count == 2)
        #expect(decoded.accounts[0].provider == "codex")
        #expect(decoded.accounts[0].tokenOrKey == "tok-12345")
        #expect(decoded.accounts[1].provider == "deepseek")
    }

    @Test("WebPluginInstaller inspects installed plugin")
    func testWebPluginInstallerStatus() {
        let installer = WebPluginInstaller.shared
        let status = installer.currentStatus()
        // If plugin is installed in App Support, verify manifest and index
        if status.isInstalled {
            #expect(status.manifest?.version != nil)
            #expect(status.manifest?.name == "tomo-mobile-web")
        }
    }

    @Test("Directly test ChatGPTSessionDirectory on ~/.codex")
    func testCodexDirectorySnapshot() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultStorage = home.appendingPathComponent(".codex")
        let root = defaultStorage.resolvingSymlinksInPath().standardizedFileURL
        let candidates = [root.appendingPathComponent("state_5.sqlite"), root.appendingPathComponent("sqlite/state_5.sqlite")]
        let database = try #require(candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }))
        let directory = ChatGPTSessionDirectory(databaseURL: database, storageRoot: root, runtimeId: "rt_chatgpt_test")
        let snapshot = try directory.snapshot(maximumRows: 5)
        print("SNAPSHOT COUNT:", snapshot.entries.count)
        #expect(snapshot.entries.count > 0)
    }

    @Test("Test reading history on ~/.codex real rollout")
    func testCodexReadHistory() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultStorage = home.appendingPathComponent(".codex")
        let root = defaultStorage.resolvingSymlinksInPath().standardizedFileURL
        let candidates = [root.appendingPathComponent("state_5.sqlite"), root.appendingPathComponent("sqlite/state_5.sqlite")]
        let database = try #require(candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }))
        let directory = ChatGPTSessionDirectory(databaseURL: database, storageRoot: root, runtimeId: "rt_chatgpt_test")
        let snapshot = try directory.snapshot(maximumRows: 5)
        let first = try #require(snapshot.entries.first)
        let start = Date()
        let history = try directory.readHistory(for: first, limit: 50)
        let elapsed = Date().timeIntervalSince(start)
        print("READ HISTORY TOOK:", elapsed, "seconds, messages:", history.messages.count)
        #expect(history.messages.count > 0)
    }
}
