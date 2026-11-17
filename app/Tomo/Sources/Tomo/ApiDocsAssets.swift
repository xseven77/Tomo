import Foundation
import Darwin

/// Immutable, bounded snapshot of a built documentation site. No disk path is
/// ever constructed from an HTTP request, and no business API handler is shared.
struct ApiDocsAssets: Sendable {
    struct Asset: Sendable { let data: Data; let mime: String; let immutable: Bool }
    enum Failure: Error { case missingSite, invalidSite }
    private let files: [String: Asset]
    private static let types = ["html":"text/html; charset=utf-8", "css":"text/css; charset=utf-8", "js":"text/javascript; charset=utf-8",
        "json":"application/json; charset=utf-8", "txt":"text/plain; charset=utf-8", "svg":"image/svg+xml", "png":"image/png",
        "webp":"image/webp", "jpg":"image/jpeg", "jpeg":"image/jpeg", "ico":"image/x-icon", "woff":"font/woff", "woff2":"font/woff2"]

    init(directory: URL) throws {
        let manager = FileManager.default
        guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw Failure.invalidSite }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw Failure.missingSite }
        defer { close(rootFD) }
        guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let entries = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { throw Failure.missingSite }
        var files: [String: Asset] = [:], total = 0
        for case let file as URL in entries {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw Failure.invalidSite }
            guard values.isRegularFile == true else { continue }
            let resolved = file.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(root.path + "/") else { throw Failure.invalidSite }
            guard let mime = Self.types[file.pathExtension.lowercased()] else { continue }
            guard let size = values.fileSize, size <= 8 * 1024 * 1024, files.count < 4096 else { throw Failure.invalidSite }
            let path = String(resolved.path.dropFirst(root.path.count + 1))
            guard !path.contains("%"), !path.contains("\\"), !path.contains(where: { $0.asciiValue.map { $0 < 32 || $0 == 127 } ?? false }) else { throw Failure.invalidSite }
            let data = try Self.readFile(path, relativeTo: rootFD)
            total += data.count
            guard data.count <= 8 * 1024 * 1024, total <= 64 * 1024 * 1024 else { throw Failure.invalidSite }
            files[path] = Asset(data: data, mime: mime, immutable: path.hasPrefix("_next/static/"))
        }
        guard files["index.html"] != nil else { throw Failure.missingSite }
        self.files = files
    }

    /// openat pins each directory and refuses symlinks at every component,
    /// including a replacement made after enumeration checked its metadata.
    private static func readFile(_ path: String, relativeTo rootFD: Int32) throws -> Data {
        var directory = dup(rootFD)
        guard directory >= 0 else { throw Failure.invalidSite }
        defer { close(directory) }
        let parts = path.split(separator: "/").map(String.init)
        guard let leaf = parts.last, !parts.contains("."), !parts.contains("..") else { throw Failure.invalidSite }
        for component in parts.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw Failure.invalidSite }
            close(directory); directory = next
        }
        let file = openat(directory, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw Failure.invalidSite }
        defer { close(file) }
        var metadata = stat()
        guard fstat(file, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0, metadata.st_size <= 8 * 1024 * 1024 else { throw Failure.invalidSite }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = read(file, &buffer, buffer.count)
            if count == 0 { return result }
            if count < 0 { if errno == EINTR { continue }; throw Failure.invalidSite }
            guard result.count + count <= 8 * 1024 * 1024 else { throw Failure.invalidSite }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    func asset(for target: String) -> Asset? {
        guard target.utf8.count <= 4096, target.hasPrefix("/"), !target.hasPrefix("//"), !target.contains("#"),
              let decoded = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]).removingPercentEncoding,
              !decoded.contains("%"), !decoded.contains("\\"), !decoded.contains("//"),
              !decoded.contains(where: { $0.asciiValue.map { $0 < 32 || $0 == 127 } ?? false }) else { return nil }
        let components = decoded.split(separator: "/")
        guard !components.contains("."), !components.contains("..") else { return nil }
        let path = String(decoded.dropFirst())
        return files[path.isEmpty || path.hasSuffix("/") ? path + "index.html" : path]
    }
}
