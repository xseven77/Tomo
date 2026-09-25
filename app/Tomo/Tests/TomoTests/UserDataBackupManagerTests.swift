import Foundation
import XCTest
@testable import Tomo

final class UserDataBackupManagerTests: XCTestCase {
    private var tempDir: URL!
    private var userDefaultsSuite: String!
    private var testDefaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TomoBackupTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        userDefaultsSuite = "com.qiizo.tomo.backup.test.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: userDefaultsSuite)!
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        testDefaults.removePersistentDomain(forName: userDefaultsSuite)
        try super.tearDownWithError()
    }

    func testExportAndInspectBackupPackage() throws {
        let appSupportDir = tempDir.appendingPathComponent("AppSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)

        // 1. Create mock connections-v1.json
        let mockConnections = """
        {
          "schemaVersion": 1,
          "codexAccounts": [
            {
              "id": "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
              "label": "Test Codex",
              "relativeHomeDirectory": "test-codex-home",
              "authenticationState": "connected",
              "isEnabled": true,
              "createdAt": "2026-09-25T01:00:00Z"
            }
          ],
          "geminiConnections": [
            {
              "id": "A1B2C3D4-E5F6-7890-1234-56789ABCDEF0",
              "label": "Test Gemini",
              "credentialHandle": "gemini-handle-1",
              "authenticationState": "connected",
              "isEnabled": true,
              "createdAt": "2026-09-25T01:00:00Z"
            }
          ],
          "deepSeekConnections": [],
          "openCodeConnections": [],
          "connectionOrder": ["codex.e621e1f8-c36c-495a-93fc-0c247a3e6e5f"]
        }
        """
        try mockConnections.write(to: appSupportDir.appendingPathComponent("connections-v1.json"), atomically: true, encoding: .utf8)

        // 2. Create mock gateway-settings.json
        let mockGateway = """
        {
          "$schemaVersion": 2,
          "allowFailover": true,
          "authToken": "test-token"
        }
        """
        try mockGateway.write(to: appSupportDir.appendingPathComponent("gateway-settings.json"), atomically: true, encoding: .utf8)

        // 3. Create mock gemini_oauth token
        let oauthDir = appSupportDir.appendingPathComponent("gemini_oauth", isDirectory: true)
        try FileManager.default.createDirectory(at: oauthDir, withIntermediateDirectories: true)
        let tokenJson = "{\"accessToken\":\"access-123\",\"refreshToken\":\"refresh-456\"}"
        try tokenJson.write(to: oauthDir.appendingPathComponent("gemini-handle-1.json"), atomically: true, encoding: .utf8)

        // 4. Create mock Pet
        let petDir = appSupportDir.appendingPathComponent("Pets/test-cat", isDirectory: true)
        try FileManager.default.createDirectory(at: petDir, withIntermediateDirectories: true)
        try "{\"name\":\"Test Cat\"}".write(to: petDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try "dummy-image".data(using: .utf8)?.write(to: petDir.appendingPathComponent("spritesheet.webp"))

        // 5. Set user defaults
        testDefaults.set("light", forKey: "tomo.theme")
        testDefaults.set(7890, forKey: "tomo.networkProxyPort")
        let themeConfig = TomoThemeConfig(
            logoFamily: "circle",
            accentColor: "#007AFF",
            accentEndColor: "#3529FF"
        )
        let themeData = try JSONEncoder().encode(themeConfig)
        testDefaults.set(themeData, forKey: "tomo.themeConfig")

        // 6. Export
        let manager = UserDataBackupManager(
            fileManager: .default,
            appSupportURL: appSupportDir,
            defaults: testDefaults
        )
        let backupFile = tempDir.appendingPathComponent("test-backup.tomo")
        try manager.exportBackup(to: backupFile)

        XCTAssertTrue(FileManager.default.fileExists(atPath: backupFile.path))

        // 7. Inspect summary
        let summary = try manager.inspectBackup(from: backupFile)
        XCTAssertEqual(summary.codexAccountsCount, 1)
        XCTAssertEqual(summary.geminiAccountsCount, 1)
        XCTAssertEqual(summary.customPetsCount, 1)
        XCTAssertTrue(summary.hasGatewaySettings)
        XCTAssertEqual(summary.themeAccentColor, "#007AFF")
        XCTAssertEqual(summary.themeAccentEndColor, "#3529FF")
        XCTAssertEqual(summary.themeLogoFamily, "circle")
    }

    func testImportBackupPackageRestoresAllFilesAndDefaults() throws {
        // Prepare a backup package
        let sourceDir = tempDir.appendingPathComponent("SourceAppSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        let mockConn = """
        {
          "schemaVersion": 1,
          "codexAccounts": [],
          "geminiConnections": [],
          "deepSeekConnections": [
            {
              "id": "ds-1",
              "label": "DeepSeek Main",
              "apiKeyHandle": "ds-key-1",
              "isEnabled": true,
              "createdAt": "2026-09-25T01:00:00Z"
            }
          ],
          "openCodeConnections": [],
          "connectionOrder": ["deepseek.ds-1"]
        }
        """
        try mockConn.write(to: sourceDir.appendingPathComponent("connections-v1.json"), atomically: true, encoding: .utf8)

        let dsCredDir = sourceDir.appendingPathComponent("deepseek_credentials", isDirectory: true)
        try FileManager.default.createDirectory(at: dsCredDir, withIntermediateDirectories: true)
        try "sk-secret-test-key".write(to: dsCredDir.appendingPathComponent("ds-key-1.json"), atomically: true, encoding: .utf8)

        testDefaults.set("dark", forKey: "tomo.theme")
        testDefaults.set(true, forKey: "tomo.windowAlwaysOnTop")

        let sourceManager = UserDataBackupManager(
            fileManager: .default,
            appSupportURL: sourceDir,
            defaults: testDefaults
        )
        let package = try sourceManager.createBackupPackage()

        // Target restore directory & defaults
        let targetDir = tempDir.appendingPathComponent("TargetAppSupport", isDirectory: true)
        let targetSuite = "com.qiizo.tomo.backup.target.\(UUID().uuidString)"
        let targetDefaults = UserDefaults(suiteName: targetSuite)!
        defer { targetDefaults.removePersistentDomain(forName: targetSuite) }

        let targetManager = UserDataBackupManager(
            fileManager: .default,
            appSupportURL: targetDir,
            defaults: targetDefaults
        )
        try targetManager.importBackup(package: package)

        // Verify restored connections
        let restoredConnFile = targetDir.appendingPathComponent("connections-v1.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: restoredConnFile.path))
        let restoredConnStr = try String(contentsOf: restoredConnFile, encoding: .utf8)
        XCTAssertTrue(restoredConnStr.contains("DeepSeek Main"))

        // Verify restored deepseek credentials
        let restoredCredFile = targetDir.appendingPathComponent("deepseek_credentials/ds-key-1.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: restoredCredFile.path))
        let restoredKey = try String(contentsOf: restoredCredFile, encoding: .utf8)
        XCTAssertEqual(restoredKey, "sk-secret-test-key")

        // Verify restored defaults
        XCTAssertEqual(targetDefaults.string(forKey: "tomo.theme"), "dark")
        XCTAssertTrue(targetDefaults.bool(forKey: "tomo.windowAlwaysOnTop"))
    }
}
