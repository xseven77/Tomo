import Foundation
import Testing
@testable import Tomo

@Suite("MobileSyncServerTests")
struct MobileSyncServerTests {
    @Test("Old Web Mobile versions are retired")
    func testRetiredMobileVersions() {
        #expect(WebPluginManifest(version: "0.0.8").isRetiredMobileVersion)
        #expect(!WebPluginManifest(version: "0.0.9").isRetiredMobileVersion)
        #expect(!WebPluginManifest(version: "0.0.10").isRetiredMobileVersion)
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
        let upstream = MobileSyncServer(port: 59391, token: "upstream-test-token", dataProvider: MockDataProvider())
        let relay = MobileSyncServer(port: 59392, token: "relay-test-token", dataProvider: MockDataProvider())
        try upstream.start()
        defer { upstream.stop() }
        try relay.start()
        defer { relay.stop() }
        try await waitFor(timeout: 5) { upstream.status == .ready && relay.status == .ready }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var url = URLComponents(string: "http://127.0.0.1:59392/api/v1/agents/events")!
        url.queryItems = [
            URLQueryItem(name: "token", value: "relay-test-token"),
            URLQueryItem(name: "target_token", value: "upstream-test-token"),
            URLQueryItem(name: "target", value: "http://127.0.0.1:59391/api/v1/events")
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
    func testWorkingMinutesNotify() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sse-stats-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let start = Date()
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

    final class MockDataProvider: MobileSyncDataProvider, @unchecked Sendable {
        func makeSnapshot() async -> MobileSnapshotPayload {
            MobileSnapshotPayload(
                schemaVersion: 1,
                generatedAt: Date(timeIntervalSince1970: 1726470000),
                activePetId: "codexling",
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
                    id: "codexling",
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
    }

    @Test("MobileSnapshotPayload JSON serialization")
    func testSnapshotSerialization() throws {
        let payload = MobileSnapshotPayload(
            schemaVersion: 1,
            generatedAt: Date(timeIntervalSince1970: 1726470000),
            activePetId: "codexling",
            activity: MobileActivityPayload(
                state: "executing",
                activeTaskCount: 2,
                activeTasks: [
                    MobileTaskPayload(id: "1", state: "executing", title: "Test 1", agent: "hermes"),
                    MobileTaskPayload(id: "2", state: "waitingForUser", title: "Test 2", agent: "codex")
                ]
            ),
            connections: [
                MobileConnectionPayload(id: "c1", provider: "codex", label: "Main", isHealthy: true, shortWindowRemaining: 65.0)
            ]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MobileSnapshotPayload.self, from: data)

        #expect(decoded.schemaVersion == 1)
        #expect(decoded.activePetId == "codexling")
        #expect(decoded.activity.state == "executing")
        #expect(decoded.activity.activeTaskCount == 2)
        #expect(decoded.activity.activeTasks.count == 2)
        #expect(decoded.connections.count == 1)
        #expect(decoded.connections[0].isHealthy == true)
    }

    @Test("MobilePetMetadata contract matches 11x8 spritesheet spec")
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
        let server = MobileSyncServer(port: 59351, token: "test-token-12345", dataProvider: provider)

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
        let port: UInt16 = 59377
        let provider = MockDataProvider()

        let first = MobileSyncServer(port: port, token: "token-a", dataProvider: provider)
        try first.start()
        defer { first.stop() }

        // Wait for the first listener to actually reach `.ready`.
        try await waitFor(timeout: 5) { first.status == .ready }

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
        let port: UInt16 = 59378
        let provider = MockDataProvider()

        let blocker = MobileSyncServer(port: port, token: "token-a", dataProvider: provider)
        try blocker.start()
        try await waitFor(timeout: 5) { blocker.status == .ready }

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
        let port: UInt16 = 59379
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
        let server = MobileSyncServer(port: 59419, token: "relay-secret", dataProvider: MockDataProvider())
        defer { server.stop() }
        try server.start()
        try await waitFor(timeout: 5) { server.status == .ready }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var url = URLComponents(string: "http://127.0.0.1:59419/api/v1/agents/snapshot")!
        url.queryItems = [URLQueryItem(name: "target", value: "http://127.0.0.1:59419/api/v1/snapshot")]
        var request = URLRequest(url: url.url!)
        request.setValue("Bearer relay-secret", forHTTPHeaderField: "Authorization")
        request.setValue("Bearer wrong-target-token", forHTTPHeaderField: "X-Target-Authorization")
        let (_, rejected) = try await session.data(for: request)
        #expect((rejected as? HTTPURLResponse)?.statusCode == 401)
        request.setValue("Bearer relay-secret", forHTTPHeaderField: "X-Target-Authorization")
        let (data, accepted) = try await session.data(for: request)
        #expect((accepted as? HTTPURLResponse)?.statusCode == 200)
        #expect((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["activity"] != nil)
        url.queryItems = [URLQueryItem(name: "target", value: "http://127.0.0.1:59419/api/v1/credentials")]
        request.url = url.url!
        let (_, invalid) = try await session.data(for: request)
        #expect((invalid as? HTTPURLResponse)?.statusCode == 400)
        url.path = "/api/v1/proxy"
        url.queryItems = [URLQueryItem(name: "target", value: "http://127.0.0.1:59419/api/v1/snapshot")]
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

    @Test("Dedicated Agent pet relay validates target and returns 400 for non-spritesheet target")
    func testAgentPetRelay() async throws {
        let server = MobileSyncServer(port: 59424, token: "pet-secret", dataProvider: MockDataProvider())
        defer { server.stop() }
        try server.start()
        try await waitFor(timeout: 5) { server.status == .ready }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        var url = URLComponents(string: "http://127.0.0.1:59424/api/v1/agents/pet")!
        // Missing target
        var request = URLRequest(url: url.url!)
        request.setValue("Bearer pet-secret", forHTTPHeaderField: "Authorization")
        let (_, missingTarget) = try await session.data(for: request)
        #expect((missingTarget as? HTTPURLResponse)?.statusCode == 400)

        // Invalid target path
        url.queryItems = [
            URLQueryItem(name: "target", value: "http://127.0.0.1:59424/api/v1/snapshot"),
            URLQueryItem(name: "target_token", value: "target-token")
        ]
        request.url = url.url!
        let (_, invalidTarget) = try await session.data(for: request)
        #expect((invalidTarget as? HTTPURLResponse)?.statusCode == 400)

        // Missing target token
        url.queryItems = [
            URLQueryItem(name: "target", value: "http://127.0.0.1:59424/api/v1/pets/test/spritesheet.webp")
        ]
        request.url = url.url!
        let (_, missingToken) = try await session.data(for: request)
        #expect((missingToken as? HTTPURLResponse)?.statusCode == 400)
    }

    @Test("Agent discover route requires authentication and returns devices")
    func testAgentDiscovery() async throws {
        let server = MobileSyncServer(port: 59420, token: "discover-secret", dataProvider: MockDataProvider())
        defer { server.stop() }
        try server.start()
        try await waitFor(timeout: 5) { server.status == .ready }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:59420/api/v1/agents/discover?subnet=127.0.0")!)
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
        let port: UInt16 = 59386
        let server = MobileSyncServer(port: port, token: secret, pluginDirectoryURL: directory, dataProvider: MockDataProvider())
        defer { server.stop() }
        try server.start()
        try await waitFor(timeout: 5) { server.status == .ready }
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
        try JSONEncoder().encode(WebPluginManifest(version: "0.0.8"))
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
            #expect(status.manifest?.name == "codexling-mobile-web")
        }
    }
}
