import AppKit
import Foundation
import Security
import UniformTypeIdentifiers

// MARK: - Backup Package Models

public struct TomoBackupPackage: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public struct Metadata: Codable, Sendable {
        public let schemaVersion: Int
        public let appName: String
        public let appVersion: String
        public let appBuild: String
        public let createdAt: Date
        public let deviceName: String
        public let osVersion: String

        public init(
            schemaVersion: Int = TomoBackupPackage.currentSchemaVersion,
            appName: String = "Tomo",
            appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.1",
            appBuild: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1",
            createdAt: Date = Date(),
            deviceName: String = Host.current().localizedName ?? "Mac",
            osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
        ) {
            self.schemaVersion = schemaVersion
            self.appName = appName
            self.appVersion = appVersion
            self.appBuild = appBuild
            self.createdAt = createdAt
            self.deviceName = deviceName
            self.osVersion = osVersion
        }
    }

    public let metadata: Metadata

    /// 1. Plist-serialized UserDefaults containing all app preferences, themes, proxy, window positions
    public let userDefaultsPlistBase64: String

    /// 2. Raw JSON string of connections-v1.json
    public let connectionsJson: String?

    /// 3. Raw JSON string of gateway-settings.json
    public let gatewaySettingsJson: String?

    /// 4. DeepSeek & OpenCode credentials: [filename: contentString]
    public let deepSeekCredentials: [String: String]?
    public let openCodeCredentials: [String: String]?

    /// 5. Gemini OAuth tokens: [filename: contentString]
    public let geminiOAuthTokens: [String: String]?

    /// 6. Codex Runtimes: [relativeDirName: [filename: base64Content]]
    public let codexRuntimes: [String: [String: String]]?

    /// 7. Custom Pets: [petId: [filename: base64Content]]
    public let customPets: [String: [String: String]]?

    /// 8. Gateway Keychain secrets: [account: secret]
    public let gatewaySecrets: [String: String]?

    /// 9. Companion stats JSON string
    public let companionStatsJson: String?

    public init(
        metadata: Metadata = Metadata(),
        userDefaultsPlistBase64: String,
        connectionsJson: String?,
        gatewaySettingsJson: String?,
        deepSeekCredentials: [String: String]?,
        openCodeCredentials: [String: String]?,
        geminiOAuthTokens: [String: String]?,
        codexRuntimes: [String: [String: String]]?,
        customPets: [String: [String: String]]?,
        gatewaySecrets: [String: String]?,
        companionStatsJson: String?
    ) {
        self.metadata = metadata
        self.userDefaultsPlistBase64 = userDefaultsPlistBase64
        self.connectionsJson = connectionsJson
        self.gatewaySettingsJson = gatewaySettingsJson
        self.deepSeekCredentials = deepSeekCredentials
        self.openCodeCredentials = openCodeCredentials
        self.geminiOAuthTokens = geminiOAuthTokens
        self.codexRuntimes = codexRuntimes
        self.customPets = customPets
        self.gatewaySecrets = gatewaySecrets
        self.companionStatsJson = companionStatsJson
    }
}

// MARK: - Backup Summary Info

public struct BackupSummaryInfo: Identifiable, Sendable {
    public var id: String { metadata.createdAt.description }
    public let metadata: TomoBackupPackage.Metadata
    public let codexAccountsCount: Int
    public let geminiAccountsCount: Int
    public let deepSeekAccountsCount: Int
    public let openCodeAccountsCount: Int
    public let customPetsCount: Int
    public let hasGatewaySettings: Bool
    public let gatewaySecretsCount: Int
    public let themeAccentColor: String?
    public let themeAccentEndColor: String?
    public let themeLogoFamily: String?
    public let rawPackage: TomoBackupPackage
}

// MARK: - User Data Backup Manager

public final class UserDataBackupManager: @unchecked Sendable {
    public static let shared = UserDataBackupManager()

    private let fileManager: FileManager
    private let appSupportURL: URL
    private let defaults: UserDefaults

    public init(
        fileManager: FileManager = .default,
        appSupportURL: URL? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.fileManager = fileManager
        self.appSupportURL = appSupportURL ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tomo", isDirectory: true)
        self.defaults = defaults
    }

    // MARK: - Export

    public func createBackupPackage() throws -> TomoBackupPackage {
        // 1. Export UserDefaults (tomo.*, codexling.*, dashboard.*, gateway.*)
        let allDefaults = defaults.dictionaryRepresentation()
        let allowedPrefixes = ["tomo.", "codexling.", "dashboard.", "gateway."]
        var filteredDefaults: [String: Any] = [:]
        for (key, val) in allDefaults {
            if allowedPrefixes.contains(where: { key.hasPrefix($0) }) {
                filteredDefaults[key] = val
            }
        }
        let plistData = try PropertyListSerialization.data(fromPropertyList: filteredDefaults, format: .xml, options: 0)
        let userDefaultsPlistBase64 = plistData.base64EncodedString()

        // 2. connections-v1.json
        let connectionsURL = appSupportURL.appendingPathComponent("connections-v1.json")
        let connectionsJson = try? String(contentsOf: connectionsURL, encoding: .utf8)

        // 3. gateway-settings.json
        let gatewayURL = appSupportURL.appendingPathComponent("gateway-settings.json")
        let gatewaySettingsJson = try? String(contentsOf: gatewayURL, encoding: .utf8)

        // 4. deepseek_credentials
        let deepSeekDir = appSupportURL.appendingPathComponent("deepseek_credentials", isDirectory: true)
        let deepSeekCredentials = readStringDictionary(from: deepSeekDir)

        // 5. opencode_credentials
        let openCodeDir = appSupportURL.appendingPathComponent("opencode_credentials", isDirectory: true)
        let openCodeCredentials = readStringDictionary(from: openCodeDir)

        // 6. gemini_oauth
        let geminiOAuthDir = appSupportURL.appendingPathComponent("gemini_oauth", isDirectory: true)
        let geminiOAuthTokens = readStringDictionary(from: geminiOAuthDir)

        // 7. Codex runtimes
        let runtimesDir = appSupportURL.appendingPathComponent("Runtimes/Codex", isDirectory: true)
        var codexRuntimes: [String: [String: String]] = [:]
        if let subdirs = try? fileManager.contentsOfDirectory(at: runtimesDir, includingPropertiesForKeys: [.isDirectoryKey]) {
            for dir in subdirs {
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue {
                    let dirName = dir.lastPathComponent
                    if let files = readBase64Dictionary(from: dir) {
                        codexRuntimes[dirName] = files
                    }
                }
            }
        }

        // 8. Custom pets
        let petsDir = appSupportURL.appendingPathComponent("Pets", isDirectory: true)
        var customPets: [String: [String: String]] = [:]
        if let petFolders = try? fileManager.contentsOfDirectory(at: petsDir, includingPropertiesForKeys: [.isDirectoryKey]) {
            for folder in petFolders {
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue {
                    let petId = folder.lastPathComponent
                    if let files = readBase64Dictionary(from: folder) {
                        customPets[petId] = files
                    }
                }
            }
        }

        // 9. Gateway Keychain secrets
        let gatewaySecrets = exportGatewaySecrets()

        // 10. companion_stats.json
        let companionURL = appSupportURL.appendingPathComponent("companion_stats.json")
        let companionStatsJson = try? String(contentsOf: companionURL, encoding: .utf8)

        return TomoBackupPackage(
            userDefaultsPlistBase64: userDefaultsPlistBase64,
            connectionsJson: connectionsJson,
            gatewaySettingsJson: gatewaySettingsJson,
            deepSeekCredentials: deepSeekCredentials.isEmpty ? nil : deepSeekCredentials,
            openCodeCredentials: openCodeCredentials.isEmpty ? nil : openCodeCredentials,
            geminiOAuthTokens: geminiOAuthTokens.isEmpty ? nil : geminiOAuthTokens,
            codexRuntimes: codexRuntimes.isEmpty ? nil : codexRuntimes,
            customPets: customPets.isEmpty ? nil : customPets,
            gatewaySecrets: gatewaySecrets.isEmpty ? nil : gatewaySecrets,
            companionStatsJson: companionStatsJson
        )
    }

    public func exportBackup(to fileURL: URL) throws {
        let package = try createBackupPackage()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(package)
        try data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Inspect / Preview

    public func inspectBackup(from fileURL: URL) throws -> BackupSummaryInfo {
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let package = try decoder.decode(TomoBackupPackage.self, from: data)

        // Parse connection counts
        var codexCount = 0
        var geminiCount = 0
        var deepSeekCount = 0
        var openCodeCount = 0

        if let connStr = package.connectionsJson, let connData = connStr.data(using: .utf8) {
            if let dict = try? JSONSerialization.jsonObject(with: connData) as? [String: Any] {
                codexCount = (dict["codexAccounts"] as? [Any])?.count ?? 0
                geminiCount = (dict["geminiConnections"] as? [Any])?.count ?? 0
                deepSeekCount = (dict["deepSeekConnections"] as? [Any])?.count ?? 0
                openCodeCount = (dict["openCodeConnections"] as? [Any])?.count ?? 0
            }
        }

        // Parse theme preview from defaults plist
        var themeAccent: String?
        var themeAccentEnd: String?
        var themeLogoFamily: String?

        if let plistData = Data(base64Encoded: package.userDefaultsPlistBase64),
           let dict = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] {
            if let rawThemeData = dict["tomo.themeConfig"] as? Data,
               let cfg = try? JSONDecoder().decode(TomoThemeConfig.self, from: rawThemeData) {
                themeAccent = cfg.accentColor
                themeAccentEnd = cfg.accentEndColor
                themeLogoFamily = cfg.logoFamily
            }
        }

        return BackupSummaryInfo(
            metadata: package.metadata,
            codexAccountsCount: codexCount,
            geminiAccountsCount: geminiCount,
            deepSeekAccountsCount: deepSeekCount,
            openCodeAccountsCount: openCodeCount,
            customPetsCount: package.customPets?.count ?? 0,
            hasGatewaySettings: !(package.gatewaySettingsJson?.isEmpty ?? true),
            gatewaySecretsCount: package.gatewaySecrets?.count ?? 0,
            themeAccentColor: themeAccent,
            themeAccentEndColor: themeAccentEnd,
            themeLogoFamily: themeLogoFamily,
            rawPackage: package
        )
    }

    // MARK: - Import

    public func importBackup(package: TomoBackupPackage) throws {
        try fileManager.createDirectory(at: appSupportURL, withIntermediateDirectories: true)

        // 1. Restore connections-v1.json
        if let connectionsJson = package.connectionsJson, let data = connectionsJson.data(using: .utf8) {
            let file = appSupportURL.appendingPathComponent("connections-v1.json")
            try data.write(to: file, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }

        // 2. Restore gateway-settings.json
        if let gatewayJson = package.gatewaySettingsJson, let data = gatewayJson.data(using: .utf8) {
            let file = appSupportURL.appendingPathComponent("gateway-settings.json")
            try data.write(to: file, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }

        // 3. Restore deepseek_credentials
        if let deepSeek = package.deepSeekCredentials {
            let dir = appSupportURL.appendingPathComponent("deepseek_credentials", isDirectory: true)
            try restoreStringDictionary(deepSeek, to: dir)
        }

        // 4. Restore opencode_credentials
        if let openCode = package.openCodeCredentials {
            let dir = appSupportURL.appendingPathComponent("opencode_credentials", isDirectory: true)
            try restoreStringDictionary(openCode, to: dir)
        }

        // 5. Restore gemini_oauth
        if let gemini = package.geminiOAuthTokens {
            let dir = appSupportURL.appendingPathComponent("gemini_oauth", isDirectory: true)
            try restoreStringDictionary(gemini, to: dir)
        }

        // 6. Restore Codex Runtimes
        if let runtimes = package.codexRuntimes {
            let runtimesRoot = appSupportURL.appendingPathComponent("Runtimes/Codex", isDirectory: true)
            try fileManager.createDirectory(at: runtimesRoot, withIntermediateDirectories: true)
            for (dirName, files) in runtimes {
                guard !dirName.contains("/"), !dirName.contains("..") else { continue }
                let accountHome = runtimesRoot.appendingPathComponent(dirName, isDirectory: true)
                try fileManager.createDirectory(at: accountHome, withIntermediateDirectories: true)
                try restoreBase64Dictionary(files, to: accountHome)
            }
        }

        // 7. Restore Custom Pets
        if let pets = package.customPets {
            let petsRoot = appSupportURL.appendingPathComponent("Pets", isDirectory: true)
            try fileManager.createDirectory(at: petsRoot, withIntermediateDirectories: true)
            for (petId, files) in pets {
                guard !petId.contains("/"), !petId.contains("..") else { continue }
                let petHome = petsRoot.appendingPathComponent(petId, isDirectory: true)
                try fileManager.createDirectory(at: petHome, withIntermediateDirectories: true)
                try restoreBase64Dictionary(files, to: petHome)
            }
        }

        // 8. Restore Gateway Keychain secrets
        if let secrets = package.gatewaySecrets {
            for (account, secret) in secrets {
                try? GatewaySecretBroker.shared.saveSecret(secret, for: account)
            }
        }

        // 9. Restore companion_stats.json
        if let companionJson = package.companionStatsJson, let data = companionJson.data(using: .utf8) {
            let file = appSupportURL.appendingPathComponent("companion_stats.json")
            try? data.write(to: file, options: .atomic)
        }

        // 10. Restore UserDefaults
        if let plistData = Data(base64Encoded: package.userDefaultsPlistBase64),
           let dict = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] {
            for (key, val) in dict {
                defaults.set(val, forKey: key)
            }
            defaults.synchronize()
        }
    }

    // MARK: - Private Helpers

    private func readStringDictionary(from directoryURL: URL) -> [String: String] {
        var result: [String: String] = [:]
        guard let files = try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else {
            return result
        }
        for file in files where file.pathExtension.lowercased() == "json" {
            if let content = try? String(contentsOf: file, encoding: .utf8) {
                result[file.lastPathComponent] = content
            }
        }
        return result
    }

    private func restoreStringDictionary(_ dict: [String: String], to directoryURL: URL) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        for (filename, content) in dict {
            guard !filename.contains("/"), !filename.contains("..") else { continue }
            let fileURL = directoryURL.appendingPathComponent(filename)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }

    private func readBase64Dictionary(from directoryURL: URL) -> [String: String]? {
        guard let files = try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else {
            return nil
        }
        var result: [String: String] = [:]
        for file in files {
            guard !file.lastPathComponent.hasPrefix(".") else { continue }
            if let data = try? Data(contentsOf: file) {
                result[file.lastPathComponent] = data.base64EncodedString()
            }
        }
        return result
    }

    private func restoreBase64Dictionary(_ dict: [String: String], to directoryURL: URL) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        for (filename, base64) in dict {
            guard !filename.contains("/"), !filename.contains("..") else { continue }
            guard let data = Data(base64Encoded: base64) else { continue }
            let fileURL = directoryURL.appendingPathComponent(filename)
            try data.write(to: fileURL, options: .atomic)
            if filename.hasSuffix(".json") || filename.hasSuffix(".toml") {
                try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            }
        }
    }

    private func exportGatewaySecrets() -> [String: String] {
        var secrets: [String: String] = [:]
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.qiizo.tomo.gateway",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let items = result as? [[String: Any]] {
            for item in items {
                if let account = item[kSecAttrAccount as String] as? String,
                   let secret = GatewaySecretBroker.shared.retrieveSecret(for: account) {
                    secrets[account] = secret
                }
            }
        }
        return secrets
    }
}
