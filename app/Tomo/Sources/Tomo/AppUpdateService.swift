import AppKit
import Foundation
import Observation

enum AppUpdatePhase: Equatable {
    case idle
    case checking
    case upToDate
    case available
    case downloading
    case installing
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .installing:
            true
        default:
            false
        }
    }
}

struct AppReleaseInfo: Equatable {
    let tagName: String
    let version: String
    let name: String
    let releaseNotes: String
    let htmlURL: URL
    let downloadURL: URL
    let assetName: String
    let assetSize: Int64
}

@MainActor
@Observable
final class AppUpdateController {
    private enum Constants {
        static let repo = "xseven77/Tomo"
        static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        static let releasesPageURL = URL(string: "https://github.com/\(repo)/releases")!
    }

    private(set) var phase: AppUpdatePhase = .idle
    private(set) var latestRelease: AppReleaseInfo?
    private(set) var downloadProgress: Double = 0
    private(set) var lastCheckedAt: Date?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// 设置页「应用」区块副标题：与主标题版本号配合，覆盖检查 / 下载 / 安装全链路。
    var settingsStatusLine: String {
        switch phase {
        case .idle:
            if let lastCheckedAt {
                return "上次检查于 \(UsageDateFormat.display(lastCheckedAt))，可再次检查"
            }
            return "通过 GitHub Releases 检查并安装新版本"
        case .checking:
            return "正在连接 GitHub Releases…"
        case .upToDate:
            if let lastCheckedAt {
                return "已是最新版本（\(UsageDateFormat.display(lastCheckedAt)) 检查）"
            }
            return "已是最新版本"
        case .available:
            if let latestRelease {
                return "发现新版本 \(latestRelease.version)，可下载并安装"
            }
            return "发现新版本，可下载并安装"
        case .downloading:
            let percent = Int((downloadProgress * 100).rounded())
            if let latestRelease {
                return "正在下载 \(latestRelease.version)… \(percent)%"
            }
            return "正在下载安装包… \(percent)%"
        case .installing:
            return "正在安装，完成后将自动重启"
        case .failed(let message):
            return message
        }
    }

    var settingsPrimaryActionTitle: String {
        switch phase {
        case .checking:
            "检查中…"
        case .available:
            "下载并安装"
        case .downloading:
            "下载中…"
        case .installing:
            "安装中…"
        case .failed:
            "重新检查"
        default:
            "检查更新"
        }
    }

    func openReleasesPage() {
        NSWorkspace.shared.open(Constants.releasesPageURL)
    }

    func checkForUpdates() {
        guard !phase.isBusy else { return }

        phase = .checking
        latestRelease = nil
        downloadProgress = 0

        Task { [weak self] in
            guard let self else { return }
            do {
                let release = try await self.fetchLatestRelease()
                self.lastCheckedAt = Date()
                self.latestRelease = release

                if Self.compareVersions(release.version, self.currentVersion) > 0 {
                    self.phase = .available
                } else {
                    self.phase = .upToDate
                }
            } catch {
                self.phase = .failed(Self.checkFailureMessage(for: error))
            }
        }
    }

    func downloadAndInstall() {
        guard case .available = phase, let release = latestRelease else { return }
        guard !phase.isBusy else { return }

        phase = .downloading
        downloadProgress = 0

        Task { [weak self] in
            guard let self else { return }
            do {
                let dmgURL = try await self.downloadDMG(from: release)
                self.phase = .installing
                try await self.installFromDMG(at: dmgURL, expectedAppName: "Tomo.app")
                self.relaunchAfterInstall()
            } catch {
                self.phase = .failed(Self.installFailureMessage(for: error))
            }
        }
    }

    private static func checkFailureMessage(for error: Error) -> String {
        if let updateError = error as? AppUpdateError, let detail = updateError.errorDescription {
            return "检查失败：\(detail)"
        }
        return "检查失败：\(error.localizedDescription)"
    }

    private static func installFailureMessage(for error: Error) -> String {
        if let updateError = error as? AppUpdateError, let detail = updateError.errorDescription {
            return "更新失败：\(detail)"
        }
        return "更新失败：\(error.localizedDescription)"
    }

    private func fetchLatestRelease() async throws -> AppReleaseInfo {
        var request = URLRequest(url: Constants.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.codexlingExternal.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppUpdateError.network
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AppUpdateError.httpStatus(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(GitHubLatestReleaseDTO.self, from: data)
        let version = Self.normalizeVersion(decoded.tagName)
        guard let htmlURL = URL(string: decoded.htmlURL) else {
            throw AppUpdateError.invalidRelease
        }

        let dmgAsset = decoded.assets.first { asset in
            let name = asset.name.lowercased()
            return name.hasSuffix(".dmg") && name.contains("codex")
        } ?? decoded.assets.first { $0.name.lowercased().hasSuffix(".dmg") }

        guard let dmgAsset, let downloadURL = URL(string: dmgAsset.browserDownloadURL) else {
            throw AppUpdateError.missingDMG
        }

        return AppReleaseInfo(
            tagName: decoded.tagName,
            version: version,
            name: decoded.name ?? decoded.tagName,
            releaseNotes: decoded.body ?? "",
            htmlURL: htmlURL,
            downloadURL: downloadURL,
            assetName: dmgAsset.name,
            assetSize: dmgAsset.size
        )
    }

    private func downloadDMG(from release: AppReleaseInfo) async throws -> URL {
        let downloads = FileManager.default.temporaryDirectory
            .appendingPathComponent("TomoUpdates", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)

        let destination = downloads.appendingPathComponent(release.assetName)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        downloadProgress = 0.02
        let tempURL = try await DownloadProgressSession.download(
            from: release.downloadURL,
            expectedSize: release.assetSize
        ) { [weak self] fraction in
            Task { @MainActor in
                self?.downloadProgress = min(max(fraction, 0.02), 0.99)
            }
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
        downloadProgress = 1
        return destination
    }

    private func installFromDMG(at dmgURL: URL, expectedAppName: String) async throws {
        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("TomoMount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        defer {
            _ = try? runProcess("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet", "-force"])
            try? FileManager.default.removeItem(at: mountPoint)
        }

        try runProcess("/usr/bin/hdiutil", [
            "attach", dmgURL.path,
            "-nobrowse",
            "-readonly",
            "-mountpoint", mountPoint.path
        ])

        let mountedApp = mountPoint.appendingPathComponent(expectedAppName)
        guard FileManager.default.fileExists(atPath: mountedApp.path) else {
            throw AppUpdateError.missingAppInDMG
        }

        let currentAppURL = Bundle.main.bundleURL
        let installTarget: URL
        if currentAppURL.pathExtension == "app" {
            installTarget = currentAppURL
        } else {
            installTarget = URL(fileURLWithPath: "/Applications/Tomo.app")
        }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tomo-update.app", isDirectory: true)
        if FileManager.default.fileExists(atPath: staging.path) {
            try FileManager.default.removeItem(at: staging)
        }

        try FileManager.default.copyItem(at: mountedApp, to: staging)

        // Replace the running app after quit via a short shell helper.
        let script = """
        #!/bin/bash
        set -euo pipefail
        sleep 1
        /usr/bin/ditto "$1" "$2"
        /usr/bin/xattr -dr com.apple.quarantine "$2" || true
        /usr/bin/open "$2"
        /bin/rm -rf "$1"
        """

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexling-install-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, staging.path, installTarget.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private func relaunchAfterInstall() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
    }

    private func runProcess(_ launchPath: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let stderr = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppUpdateError.shellFailed(message?.isEmpty == false ? message! : launchPath)
        }
    }

    static func normalizeVersion(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("v") {
            value.removeFirst()
        }
        return value
    }

    /// Returns 1 if lhs > rhs, -1 if lhs < rhs, 0 if equal.
    static func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        let left = normalizeVersion(lhs).split(separator: ".").compactMap { Int($0) }
        let right = normalizeVersion(rhs).split(separator: ".").compactMap { Int($0) }
        let count = max(left.count, right.count)
        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l > r { return 1 }
            if l < r { return -1 }
        }
        return 0
    }
}

enum AppUpdateError: LocalizedError {
    case network
    case httpStatus(Int)
    case invalidRelease
    case missingDMG
    case missingAppInDMG
    case shellFailed(String)

    var errorDescription: String? {
        switch self {
        case .network:
            "无法连接网络，请稍后重试"
        case .httpStatus(let code):
            "GitHub 返回错误（HTTP \(code)），请稍后重试"
        case .invalidRelease:
            "无法解析 Release 信息"
        case .missingDMG:
            "Release 中未找到 DMG 安装包"
        case .missingAppInDMG:
            "安装包中未找到 Tomo.app"
        case .shellFailed(let detail):
            detail
        }
    }
}

private struct GitHubLatestReleaseDTO: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: String
    let assets: [GitHubAssetDTO]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case assets
    }
}

private struct GitHubAssetDTO: Decodable {
    let name: String
    let size: Int64
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case size
        case browserDownloadURL = "browser_download_url"
    }
}

private final class DownloadProgressSession: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private let onProgress: @Sendable (Double) -> Void
    private let expectedSize: Int64
    private var session: URLSession?

    private init(expectedSize: Int64, onProgress: @escaping @Sendable (Double) -> Void) {
        self.expectedSize = expectedSize
        self.onProgress = onProgress
    }

    static func download(
        from url: URL,
        expectedSize: Int64,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let bridge = DownloadProgressSession(expectedSize: expectedSize, onProgress: onProgress)
            bridge.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.applyTomoExternalProxy()
            let session = URLSession(configuration: configuration, delegate: bridge, delegateQueue: nil)
            bridge.session = session
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : max(expectedSize, 1)
        onProgress(Double(totalBytesWritten) / Double(total))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("codexling-dl-\(UUID().uuidString).dmg")
            if FileManager.default.fileExists(atPath: temp.path) {
                try FileManager.default.removeItem(at: temp)
            }
            try FileManager.default.copyItem(at: location, to: temp)
            finish(.success(temp))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
        session?.finishTasksAndInvalidate()
        session = nil
    }
}
