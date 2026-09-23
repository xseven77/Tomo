import Foundation

// MARK: - Plugin Manifest Data Model

public struct WebPluginManifest: Codable, Equatable, Sendable {
    public let name: String
    public let version: String
    public let build: Int?
    public let minTomoVersion: String?
    public let description: String?
    public let author: String?
    public let entry: String?

    public var isRetiredMobileVersion: Bool {
        name == "tomo-mobile-web" && version.compare("0.0.9", options: .numeric) == .orderedAscending
    }

    public init(
        name: String = "tomo-mobile-web",
        version: String = "1.0.0",
        build: Int? = 1,
        minTomoVersion: String? = "0.7.3",
        description: String? = nil,
        author: String? = nil,
        entry: String? = "index.html"
    ) {
        self.name = name
        self.version = version
        self.build = build
        self.minTomoVersion = minTomoVersion
        self.description = description
        self.author = author
        self.entry = entry
    }
}

public struct WebPluginStatus: Equatable, Sendable {
    public let isInstalled: Bool
    public let manifest: WebPluginManifest?
    public let pluginDirectory: URL
    public let totalSizeBytes: Int64

    public var displayVersion: String {
        manifest?.version ?? "未知"
    }

    public var displaySizeString: String {
        ByteCountFormatter.string(fromByteCount: totalSizeBytes, countStyle: .file)
    }

    public init(
        isInstalled: Bool,
        manifest: WebPluginManifest?,
        pluginDirectory: URL,
        totalSizeBytes: Int64
    ) {
        self.isInstalled = isInstalled
        self.manifest = manifest
        self.pluginDirectory = pluginDirectory
        self.totalSizeBytes = totalSizeBytes
    }
}

// MARK: - Web Plugin Installer

public final class WebPluginInstaller: @unchecked Sendable {
    public static let shared = WebPluginInstaller()

    public static let defaultReleaseURL = URL(
        string: "https://github.com/xseven77/TomoGoWeb-release/releases/latest/download/mobile-web-plugin.zip"
    )!

    public static let latestReleaseAPIURL = URL(
        string: "https://api.github.com/repos/xseven77/TomoGoWeb-release/releases/latest"
    )!

    public struct RemoteReleaseInfo: Equatable, Sendable {
        public let tagName: String
        public let version: String
        public let downloadURL: URL
        public let hasUpdate: Bool
    }

    public func checkForUpdates() async throws -> RemoteReleaseInfo {
        var request = URLRequest(url: Self.latestReleaseAPIURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Tomo-Desktop", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "WebPluginInstaller", code: 4, userInfo: [NSLocalizedDescriptionKey: "查询远端版本失败: HTTP \(code)"])
        }

        struct ReleaseDTO: Decodable {
            let tagName: String
            let assets: [AssetDTO]

            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case assets
            }
        }
        struct AssetDTO: Decodable {
            let name: String
            let browserDownloadURL: String

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let dto = try JSONDecoder().decode(ReleaseDTO.self, from: data)
        let normalizedRemoteVer = dto.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        guard let zipAsset = dto.assets.first(where: { $0.name.hasSuffix(".zip") }),
              let downloadURL = URL(string: zipAsset.browserDownloadURL) else {
            throw NSError(domain: "WebPluginInstaller", code: 5, userInfo: [NSLocalizedDescriptionKey: "Release 中未找到插件 .zip 资产"])
        }

        let localVer = currentStatus().manifest?.version ?? "0.0.0"
        let hasUpdate = compareVersions(normalizedRemoteVer, localVer) > 0

        return RemoteReleaseInfo(
            tagName: dto.tagName,
            version: normalizedRemoteVer,
            downloadURL: downloadURL,
            hasUpdate: hasUpdate
        )
    }

    private func compareVersions(_ v1: String, _ v2: String) -> Int {
        let parts1 = v1.split(separator: ".").compactMap { Int($0) }
        let parts2 = v2.split(separator: ".").compactMap { Int($0) }
        let maxLen = max(parts1.count, parts2.count)
        for i in 0..<maxLen {
            let p1 = i < parts1.count ? parts1[i] : 0
            let p2 = i < parts2.count ? parts2[i] : 0
            if p1 != p2 { return p1 > p2 ? 1 : -1 }
        }
        return 0
    }

    public let pluginDirectory: URL
    private let fileManager = FileManager.default

    public init(pluginDirectory: URL = MobileSyncServer.defaultPluginDirectoryURL) {
        self.pluginDirectory = pluginDirectory
    }

    // MARK: - Status Checking

    public func currentStatus() -> WebPluginStatus {
        let indexFile = pluginDirectory.appendingPathComponent("index.html")
        guard fileManager.fileExists(atPath: indexFile.path) else {
            return WebPluginStatus(
                isInstalled: false,
                manifest: nil,
                pluginDirectory: pluginDirectory,
                totalSizeBytes: 0
            )
        }

        let manifestFile = pluginDirectory.appendingPathComponent("plugin-manifest.json")
        var manifest: WebPluginManifest?
        if let data = try? Data(contentsOf: manifestFile),
           let decoded = try? JSONDecoder().decode(WebPluginManifest.self, from: data) {
            manifest = decoded
        }

        let size = calculateDirectorySize(at: pluginDirectory)
        return WebPluginStatus(
            isInstalled: true,
            manifest: manifest,
            pluginDirectory: pluginDirectory,
            totalSizeBytes: size
        )
    }

    // MARK: - Installation

    public func install(fromLocalZip zipURL: URL) throws {
        let tempExtractDir = fileManager.temporaryDirectory.appendingPathComponent("tomo-plugin-\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempExtractDir, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: tempExtractDir)
        }

        // 1. 使用 /usr/bin/ditto 解压 zip
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-xk", zipURL.path, tempExtractDir.path]

        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorMsg = String(data: errorData, encoding: .utf8) ?? "ditto failed"
            throw NSError(domain: "WebPluginInstaller", code: 1, userInfo: [NSLocalizedDescriptionKey: "解压失败: \(errorMsg)"])
        }

        // 2. 探查有效资源根目录（若压缩包外层有单一文件夹包裹，则深入该层）
        let sourceDir = resolveSourceDirectory(in: tempExtractDir)
        let indexFile = sourceDir.appendingPathComponent("index.html")
        guard fileManager.fileExists(atPath: indexFile.path) else {
            throw NSError(domain: "WebPluginInstaller", code: 2, userInfo: [NSLocalizedDescriptionKey: "插件包中缺少 index.html，不是合法的 Web 插件"])
        }

        let manifestURL = sourceDir.appendingPathComponent("plugin-manifest.json")
        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONDecoder().decode(WebPluginManifest.self, from: data),
           manifest.isRetiredMobileVersion {
            throw NSError(domain: "WebPluginInstaller", code: 6, userInfo: [NSLocalizedDescriptionKey: "旧版 Web Mobile 已失效，请安装 0.0.9 或更新版本"])
        }

        // 3. 准备目标插件目录
        try fileManager.createDirectory(at: pluginDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: pluginDirectory.path) {
            try fileManager.removeItem(at: pluginDirectory)
        }

        // 4. 原子移动至正式插件目录
        try fileManager.moveItem(at: sourceDir, to: pluginDirectory)
    }

    public func downloadAndInstall(
        from remoteURL: URL = defaultReleaseURL,
        onProgress: (@Sendable (Double, Int64, Int64) -> Void)? = nil
    ) async throws {
        let delegate = DownloadProgressDelegate(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (tempDownloadedURL, response) = try await session.download(from: remoteURL)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(
                domain: "WebPluginInstaller",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "下载插件失败: HTTP 状态码 \(code)"]
            )
        }

        onProgress?(1.0, 1, 1)
        try install(fromLocalZip: tempDownloadedURL)
        try? fileManager.removeItem(at: tempDownloadedURL)
    }

    public func uninstall() throws {
        if fileManager.fileExists(atPath: pluginDirectory.path) {
            try fileManager.removeItem(at: pluginDirectory)
        }
    }

    // MARK: - Helpers

    private func resolveSourceDirectory(in directory: URL) -> URL {
        if fileManager.fileExists(atPath: directory.appendingPathComponent("index.html").path) {
            return directory
        }

        if let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles),
           contents.count == 1,
           let first = contents.first,
           (try? first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
           fileManager.fileExists(atPath: first.appendingPathComponent("index.html").path) {
            return first
        }

        return directory
    }

    private func calculateDirectorySize(at url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}

// MARK: - Download Progress Delegate

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: (@Sendable (Double, Int64, Int64) -> Void)?

    init(onProgress: (@Sendable (Double, Int64, Int64) -> Void)?) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = min(1.0, max(0.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        onProgress?(progress, totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Handled in async download(from:)
    }
}
