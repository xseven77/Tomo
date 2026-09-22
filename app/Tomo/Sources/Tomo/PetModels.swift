import AppKit
import Foundation
import ImageIO

enum CodexPetSource: String, Sendable {
    case codexBuiltIn
    case custom

    var title: String {
        switch self {
        case .codexBuiltIn:
            "官方内置"
        case .custom:
            "自定义"
        }
    }
}

struct CodexPet: Identifiable, Hashable, Sendable {
    let id: String
    let assetID: String
    let displayName: String
    let description: String
    let source: CodexPetSource
    let spriteVersionNumber: Int
    let spritesheetURL: URL
    let rowCount: Int
}

struct CodexPetSelectionSync: Sendable {
    let configURL: URL

    init(configURL: URL? = nil) {
        self.configURL = configURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/config.toml")
    }

    func readSelectedPetID() -> String? {
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8),
              let codexID = selectedAvatarID(in: contents) else {
            return nil
        }
        return appPetID(fromCodexID: codexID)
    }

    @discardableResult
    func writeSelectedPetID(_ appPetID: String) throws -> Bool {
        let codexID = codexPetID(fromAppID: appPetID)
        let contents = try String(contentsOf: configURL, encoding: .utf8)
        let updated = updatingSelectedAvatarID(in: contents, to: codexID)
        guard updated != contents else { return false }
        try updated.write(to: configURL, atomically: true, encoding: .utf8)
        return true
    }

    func codexPetID(fromAppID appPetID: String) -> String {
        if appPetID.hasPrefix("builtin:") {
            return String(appPetID.dropFirst("builtin:".count))
        }
        return appPetID
    }

    func appPetID(fromCodexID codexID: String) -> String {
        codexID.hasPrefix("custom:") ? codexID : "builtin:\(codexID)"
    }

    func selectedAvatarID(in contents: String) -> String? {
        let lines = contents.components(separatedBy: .newlines)
        var isDesktopSection = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                isDesktopSection = trimmed == "[desktop]"
                continue
            }
            guard isDesktopSection,
                  let value = tomlStringValue(in: trimmed, key: "selected-avatar-id") else {
                continue
            }
            return value
        }
        return nil
    }

    func updatingSelectedAvatarID(in contents: String, to codexID: String) -> String {
        var lines = contents.components(separatedBy: .newlines)
        let hadTrailingNewline = contents.hasSuffix("\n")
        if hadTrailingNewline, lines.last == "" {
            lines.removeLast()
        }

        let escapedID = codexID
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let settingLine = "selected-avatar-id = \"\(escapedID)\""
        var desktopSectionIndex: Int?
        var desktopSectionEnd = lines.count

        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[") && trimmed.hasSuffix("]") else { continue }
            if desktopSectionIndex != nil {
                desktopSectionEnd = index
                break
            }
            if trimmed == "[desktop]" {
                desktopSectionIndex = index
            }
        }

        if let desktopSectionIndex {
            for index in (desktopSectionIndex + 1)..<desktopSectionEnd {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                if tomlStringValue(in: trimmed, key: "selected-avatar-id") != nil {
                    let indentation = String(lines[index].prefix { $0 == " " || $0 == "\t" })
                    lines[index] = indentation + settingLine
                    return lines.joined(separator: "\n") + (hadTrailingNewline ? "\n" : "")
                }
            }
            lines.insert(settingLine, at: desktopSectionIndex + 1)
        } else {
            if !lines.isEmpty, lines.last != "" {
                lines.append("")
            }
            lines.append("[desktop]")
            lines.append(settingLine)
        }

        return lines.joined(separator: "\n") + (hadTrailingNewline ? "\n" : "")
    }

    private func tomlStringValue(in line: String, key: String) -> String? {
        guard !line.hasPrefix("#"),
              let equalsIndex = line.firstIndex(of: "="),
              line[..<equalsIndex].trimmingCharacters(in: .whitespaces) == key else {
            return nil
        }
        let rawValue = line[line.index(after: equalsIndex)...]
            .trimmingCharacters(in: .whitespaces)
        guard rawValue.first == "\"",
              let closingQuote = rawValue.dropFirst().firstIndex(of: "\"") else {
            return nil
        }
        return String(rawValue[rawValue.index(after: rawValue.startIndex)..<closingQuote])
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}

@MainActor
final class CodexPetSelectionMonitor {
    private let configURL: URL
    private let debounceInterval: TimeInterval
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: CInt = -1
    private var debounceWorkItem: DispatchWorkItem?
    private var rearmWorkItem: DispatchWorkItem?

    init(
        configURL: URL? = nil,
        debounceInterval: TimeInterval = 0.3,
        onChange: @escaping () -> Void
    ) {
        self.configURL = configURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/config.toml")
        self.debounceInterval = debounceInterval
        self.onChange = onChange
    }

    func start() {
        guard source == nil else { return }
        installSource()
    }

    func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        rearmWorkItem?.cancel()
        rearmWorkItem = nil
        source?.cancel()
        source = nil
    }

    private func installSource() {
        guard source == nil else { return }
        let descriptor = open(configURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            scheduleRearm()
            return
        }

        fileDescriptor = descriptor
        let nextSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke],
            queue: .main
        )
        nextSource.setEventHandler { [weak self, weak nextSource] in
            guard let self, let nextSource else { return }
            let event = nextSource.data
            scheduleSync()
            if !event.intersection([.rename, .delete, .revoke]).isEmpty {
                source?.cancel()
                source = nil
                scheduleRearm()
            }
        }
        nextSource.setCancelHandler { [weak self] in
            guard let self else { return }
            if fileDescriptor >= 0 {
                close(fileDescriptor)
                fileDescriptor = -1
            }
        }
        source = nextSource
        nextSource.resume()
    }

    private func scheduleSync() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func scheduleRearm() {
        rearmWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            rearmWorkItem = nil
            installSource()
        }
        rearmWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }
}

enum CodexApplicationRestartError: LocalizedError {
    case applicationNotFound
    case terminationRejected
    case terminationTimedOut

    var errorDescription: String? {
        switch self {
        case .applicationNotFound:
            "未找到 Codex 应用"
        case .terminationRejected:
            "Codex 拒绝退出，请先保存当前工作后手动重启"
        case .terminationTimedOut:
            "等待 Codex 退出超时，请手动重启"
        }
    }
}

@MainActor
struct CodexApplicationController {
    static let bundleIdentifier = "com.openai.codex"

    private let applicationURLs: [URL]

    init(applicationURLs: [URL]? = nil) {
        if let applicationURLs {
            self.applicationURLs = applicationURLs
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.applicationURLs = [
                URL(fileURLWithPath: "/Applications/ChatGPT.app"),
                URL(fileURLWithPath: "/Applications/Codex.app"),
                home.appendingPathComponent("Applications/ChatGPT.app"),
                home.appendingPathComponent("Applications/Codex.app"),
            ]
        }
    }

    func restart() async throws {
        let runningApplication = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.bundleIdentifier)
            .first
        guard let applicationURL = runningApplication?.bundleURL ?? installedApplicationURL() else {
            throw CodexApplicationRestartError.applicationNotFound
        }

        if let runningApplication {
            guard runningApplication.terminate() else {
                throw CodexApplicationRestartError.terminationRejected
            }
            var didTerminate = runningApplication.isTerminated
            for _ in 0..<40 where !didTerminate {
                try await Task.sleep(for: .milliseconds(150))
                didTerminate = runningApplication.isTerminated
            }
            guard didTerminate else {
                throw CodexApplicationRestartError.terminationTimedOut
            }
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: configuration
        )
    }

    private func installedApplicationURL() -> URL? {
        applicationURLs.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Info.plist").path)
        }
    }
}

private struct CustomPetManifest: Codable {
    let id: String
    let displayName: String
    let description: String?
    let spriteVersionNumber: Int?
    let spritesheetPath: String
}

enum TomoPetInstaller {
    static let petID = "codexling"

    static func isInstalled(in petsRoot: URL = defaultPetsRoot) -> Bool {
        let directory = petsRoot.appendingPathComponent(petID, isDirectory: true)
        let manifestURL = directory.appendingPathComponent("pet.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(CustomPetManifest.self, from: data),
              manifest.id.lowercased() == petID else {
            return false
        }
        return FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(manifest.spritesheetPath).path
        )
    }

    static func install(into petsRoot: URL = defaultPetsRoot) throws {
        let fileManager = FileManager.default
        let destination = petsRoot.appendingPathComponent(petID, isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        guard let source = bundledPetDirectory() else {
            throw CocoaError(.fileNoSuchFile)
        }

        try fileManager.createDirectory(at: petsRoot, withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: destination)
    }

    static func bundledPetDirectory() -> URL? {
        CodexPetCatalog.bundledPetDirectory(for: petID)
    }

    private static var defaultPetsRoot: URL {
        CodexPetCatalog.defaultCodexPetsRoot
    }
}

struct CodexPetCatalog: Sendable {
    static var defaultCustomPetsRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("Tomo", isDirectory: true)
            .appendingPathComponent("Pets", isDirectory: true)
    }

    static var defaultCodexPetsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/pets", isDirectory: true)
    }

    static let builtInPetIDs: [String] = [
        "codexling", "codex", "dewey", "fireball", "hoots",
        "null-signal", "rocky", "seedy", "stacky", "bsod"
    ]

    static func isBuiltInPetID(_ id: String) -> Bool {
        let stripped = id.hasPrefix("builtin:") ? String(id.dropFirst("builtin:".count)) : id
        return builtInPetIDs.contains(stripped.lowercased())
    }

    let customPetsRoot: URL
    let bundledPetsRoot: URL?

    init(
        customPetsRoot: URL? = nil,
        bundledPetsRoot: URL? = nil
    ) {
        self.customPetsRoot = customPetsRoot ?? Self.defaultCustomPetsRoot
        self.bundledPetsRoot = bundledPetsRoot ?? Self.resolveBundledPetsRoot()
    }

    static func resolveBundledPetsRoot() -> URL? {
        if let url = Bundle.main.url(forResource: "pet", withExtension: "json", subdirectory: "Pets/Tomo")?
            .deletingLastPathComponent().deletingLastPathComponent() {
            return url
        }
        if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("Pets", isDirectory: true),
           FileManager.default.fileExists(atPath: resourceURL.path) {
            return resourceURL
        }
        let candidatePaths = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Pets", isDirectory: true),
            URL(fileURLWithPath: "Resources/Pets", isDirectory: true),
            URL(fileURLWithPath: "app/Tomo/Resources/Pets", isDirectory: true),
            URL(fileURLWithPath: "/Users/qiizo/code/Personal/Tomo/app/Tomo/Resources/Pets", isDirectory: true)
        ]
        for candidate in candidatePaths {
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func bundledPetDirectory(for id: String) -> URL? {
        guard let root = resolveBundledPetsRoot() else { return nil }
        let normalizedID = id.lowercased()
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        for dir in directories {
            let manifestURL = dir.appendingPathComponent("pet.json")
            if let data = try? Data(contentsOf: manifestURL),
               let manifest = try? JSONDecoder().decode(CustomPetManifest.self, from: data),
               manifest.id.lowercased() == normalizedID {
                return dir
            }
        }
        return nil
    }

    func discover() -> [CodexPet] {
        let builtIns = discoverBuiltInPets()
        let custom = discoverCustomPets()
        return (builtIns + custom).sorted {
            if $0.source != $1.source {
                return $0.source == .codexBuiltIn
            }
            if $0.source == .codexBuiltIn && $1.source == .codexBuiltIn {
                let index0 = Self.builtInPetIDs.firstIndex(of: $0.assetID.lowercased()) ?? 99
                let index1 = Self.builtInPetIDs.firstIndex(of: $1.assetID.lowercased()) ?? 99
                if index0 != index1 {
                    return index0 < index1
                }
            }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private func discoverBuiltInPets() -> [CodexPet] {
        guard let root = bundledPetsRoot,
              let directories = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        return directories.compactMap { directory in
            parsePet(in: directory, source: .codexBuiltIn, idPrefix: "builtin:")
        }
    }

    private func discoverCustomPets() -> [CodexPet] {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: customPetsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return directories.compactMap { directory in
            parsePet(in: directory, source: .custom, idPrefix: "custom:")
        }
    }

    private func parsePet(in directory: URL, source: CodexPetSource, idPrefix: String) -> CodexPet? {
        let manifestURL = directory.appendingPathComponent("pet.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(CustomPetManifest.self, from: data) else {
            return nil
        }

        let spritesheetURL = directory.appendingPathComponent(manifest.spritesheetPath)
        guard let dimensions = imageDimensions(at: spritesheetURL),
              dimensions.width == PetSpriteSheet.cellWidth * 8,
              dimensions.height % PetSpriteSheet.cellHeight == 0 else {
            return nil
        }

        let rowCount = dimensions.height / PetSpriteSheet.cellHeight
        guard rowCount >= 9 else { return nil }
        let version = manifest.spriteVersionNumber ?? (rowCount >= 11 ? 2 : 1)

        return CodexPet(
            id: "\(idPrefix)\(manifest.id)",
            assetID: manifest.id,
            displayName: manifest.displayName,
            description: manifest.description ?? (source == .codexBuiltIn ? "Tomo 官方内置 Pet" : "自定义 Pet"),
            source: source,
            spriteVersionNumber: version,
            spritesheetURL: spritesheetURL,
            rowCount: rowCount
        )
    }
}

@MainActor
final class PetBidirectionalSyncManager {
    static let shared = PetBidirectionalSyncManager()

    private let appSupportPetsRoot: URL
    private let codexPetsRoot: URL
    private let configURL: URL
    private let selectionSync: CodexPetSelectionSync
    private var isSyncing = false

    init(
        appSupportPetsRoot: URL? = nil,
        codexPetsRoot: URL? = nil,
        configURL: URL? = nil
    ) {
        self.appSupportPetsRoot = appSupportPetsRoot ?? CodexPetCatalog.defaultCustomPetsRoot
        self.codexPetsRoot = codexPetsRoot ?? CodexPetCatalog.defaultCodexPetsRoot
        self.configURL = configURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/config.toml")
        self.selectionSync = CodexPetSelectionSync(configURL: self.configURL)
    }

    /// Performs bidirectional synchronization between Tomo Application Support Pets and Codex Pets (~/.codex/pets).
    @discardableResult
    func performBidirectionalSync() -> (forwardCount: Int, reverseCount: Int) {
        guard !isSyncing else { return (0, 0) }
        isSyncing = true
        defer { isSyncing = false }

        let fm = FileManager.default
        let codexHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        guard fm.fileExists(atPath: codexHome.path) else {
            return (0, 0)
        }

        try? fm.createDirectory(at: appSupportPetsRoot, withIntermediateDirectories: true)
        try? fm.createDirectory(at: codexPetsRoot, withIntermediateDirectories: true)

        var reverseCount = 0
        var forwardCount = 0

        // 1. Reverse Sync: ~/.codex/pets -> ~/Library/Application Support/Tomo/Pets
        if let codexDirs = try? fm.contentsOfDirectory(
            at: codexPetsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for dir in codexDirs {
                let manifestURL = dir.appendingPathComponent("pet.json")
                guard let data = try? Data(contentsOf: manifestURL),
                      let manifest = try? JSONDecoder().decode(CustomPetManifest.self, from: data) else {
                    continue
                }
                let petID = manifest.id.lowercased()
                if CodexPetCatalog.isBuiltInPetID(petID) {
                    continue
                }
                let destDir = appSupportPetsRoot.appendingPathComponent(dir.lastPathComponent, isDirectory: true)
                if copyDirectoryIfDifferent(from: dir, to: destDir) {
                    reverseCount += 1
                }
            }
        }

        // 2. Forward Sync: ~/Library/Application Support/Tomo/Pets -> ~/.codex/pets
        if let appDirs = try? fm.contentsOfDirectory(
            at: appSupportPetsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for dir in appDirs {
                let manifestURL = dir.appendingPathComponent("pet.json")
                guard let data = try? Data(contentsOf: manifestURL),
                      let manifest = try? JSONDecoder().decode(CustomPetManifest.self, from: data) else {
                    continue
                }
                let petID = manifest.id.lowercased()
                if CodexPetCatalog.isBuiltInPetID(petID) && petID != "codexling" {
                    continue
                }
                let destDir = codexPetsRoot.appendingPathComponent(dir.lastPathComponent, isDirectory: true)
                if copyDirectoryIfDifferent(from: dir, to: destDir) {
                    forwardCount += 1
                }
            }
        }

        // 3. Sync bundled Tomo pet to ~/.codex/pets/codexling if missing
        if let bundledTomo = CodexPetCatalog.bundledPetDirectory(for: "codexling") {
            let destTomo = codexPetsRoot.appendingPathComponent("codexling", isDirectory: true)
            if copyDirectoryIfDifferent(from: bundledTomo, to: destTomo) {
                forwardCount += 1
            }
        }

        return (forwardCount, reverseCount)
    }

    private func copyDirectoryIfDifferent(from src: URL, to dest: URL) -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dest.path) {
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try fm.copyItem(at: src, to: dest)
                return true
            } catch {
                return false
            }
        }

        guard let srcFiles = try? fm.contentsOfDirectory(atPath: src.path) else { return false }
        var didChange = false
        for file in srcFiles where !file.hasPrefix(".") {
            let srcFile = src.appendingPathComponent(file)
            let destFile = dest.appendingPathComponent(file)
            if !fm.fileExists(atPath: destFile.path) {
                try? fm.copyItem(at: srcFile, to: destFile)
                didChange = true
            } else {
                let srcAttrs = try? fm.attributesOfItem(atPath: srcFile.path)
                let destAttrs = try? fm.attributesOfItem(atPath: destFile.path)
                let srcSize = srcAttrs?[.size] as? UInt64 ?? 0
                let destSize = destAttrs?[.size] as? UInt64 ?? 0
                if srcSize != destSize {
                    try? fm.removeItem(at: destFile)
                    try? fm.copyItem(at: srcFile, to: destFile)
                    didChange = true
                }
            }
        }
        return didChange
    }
}

private func imageDimensions(at url: URL) -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int else {
        return nil
    }
    return (width, height)
}

enum PetAnimationState: String, Sendable, CaseIterable {
    case idle
    case running
    case review
    case waiting
    case failed
    case waving
    case jumping

    static var idleInteractionCandidates: [PetAnimationState] {
        allCases.filter { $0 != .idle }
    }
}

struct PetAnimationFrame: Equatable, Sendable {
    let row: Int
    let column: Int
    let duration: TimeInterval
}

struct PetAnimationSequence: Equatable, Sendable {
    let frames: [PetAnimationFrame]
    let loopStartIndex: Int?
}

enum PetAnimationContract {
    private static let idle = frames(
        row: 0,
        durations: [280, 110, 110, 140, 140, 320]
    )

    static func sequence(
        for state: PetAnimationState,
        reducedMotion: Bool
    ) -> PetAnimationSequence {
        let stateFrames: [PetAnimationFrame] = switch state {
        case .idle:
            idle
        case .running:
            frames(row: 7, count: 6, duration: 120, finalDuration: 220)
        case .review:
            frames(row: 8, count: 6, duration: 150, finalDuration: 280)
        case .waiting:
            frames(row: 6, count: 6, duration: 150, finalDuration: 260)
        case .failed:
            frames(row: 5, count: 8, duration: 140, finalDuration: 240)
        case .waving:
            frames(row: 3, count: 4, duration: 140, finalDuration: 280)
        case .jumping:
            frames(row: 4, count: 5, duration: 140, finalDuration: 280)
        }

        if reducedMotion {
            return PetAnimationSequence(frames: [stateFrames[0]], loopStartIndex: nil)
        }

        let slowIdle = idle.map {
            PetAnimationFrame(row: $0.row, column: $0.column, duration: $0.duration * 6)
        }
        if state == .idle {
            return PetAnimationSequence(frames: slowIdle, loopStartIndex: 0)
        }

        let reaction = stateFrames + stateFrames + stateFrames
        return PetAnimationSequence(
            frames: reaction + slowIdle,
            loopStartIndex: reaction.count
        )
    }

    static func oneShotSequence(
        for state: PetAnimationState,
        reducedMotion: Bool
    ) -> PetAnimationSequence {
        let stateFrames: [PetAnimationFrame] = switch state {
        case .idle:
            idle
        case .running:
            frames(row: 7, count: 6, duration: 120, finalDuration: 220)
        case .review:
            frames(row: 8, count: 6, duration: 150, finalDuration: 280)
        case .waiting:
            frames(row: 6, count: 6, duration: 150, finalDuration: 260)
        case .failed:
            frames(row: 5, count: 8, duration: 140, finalDuration: 240)
        case .waving:
            frames(row: 3, count: 4, duration: 140, finalDuration: 280)
        case .jumping:
            frames(row: 4, count: 5, duration: 140, finalDuration: 280)
        }

        if reducedMotion {
            return PetAnimationSequence(frames: [stateFrames[0]], loopStartIndex: nil)
        }

        let reaction = stateFrames + stateFrames + stateFrames
        return PetAnimationSequence(frames: reaction, loopStartIndex: nil)
    }

    private static func frames(row: Int, durations: [Int]) -> [PetAnimationFrame] {
        durations.enumerated().map { column, duration in
            PetAnimationFrame(
                row: row,
                column: column,
                duration: TimeInterval(duration) / 1_000
            )
        }
    }

    private static func frames(
        row: Int,
        count: Int,
        duration: Int,
        finalDuration: Int
    ) -> [PetAnimationFrame] {
        frames(
            row: row,
            durations: (0..<count).map { $0 == count - 1 ? finalDuration : duration }
        )
    }
}

@MainActor
final class PetSpriteSheet {
    nonisolated static let cellWidth = 192
    nonisolated static let cellHeight = 208

    private let image: CGImage
    let rowCount: Int

    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == Self.cellWidth * 8,
              image.height % Self.cellHeight == 0 else {
            return nil
        }
        self.image = image
        rowCount = image.height / Self.cellHeight
    }

    func frame(row: Int, column: Int, displayHeight: CGFloat = 21) -> NSImage? {
        guard row >= 0, row < rowCount, column >= 0, column < 8 else { return nil }
        let cropRect = CGRect(
            x: column * Self.cellWidth,
            y: row * Self.cellHeight,
            width: Self.cellWidth,
            height: Self.cellHeight
        )
        guard let cropped = image.cropping(to: cropRect) else { return nil }
        let displayWidth = displayHeight * CGFloat(Self.cellWidth) / CGFloat(Self.cellHeight)
        return NSImage(cgImage: cropped, size: NSSize(width: displayWidth, height: displayHeight))
    }
}

@MainActor
final class PetAnimationPlayer {
    var onFrame: ((NSImage?) -> Void)?

    private var sheet: PetSpriteSheet?
    private var petID: String?
    private var state: PetAnimationState = .idle
    private var sequence = PetAnimationContract.sequence(for: .idle, reducedMotion: false)
    private var frameIndex = 0
    private var timer: Timer?
    private(set) var isPlayingOneShot = false
    private var oneShotCompletion: (() -> Void)?

    func setPet(_ pet: CodexPet?) {
        guard pet?.id != petID else { return }
        petID = pet?.id
        sheet = pet.flatMap { PetSpriteSheet(url: $0.spritesheetURL) }
        restart()
    }

    func setState(_ newState: PetAnimationState) {
        guard !isPlayingOneShot else { return }
        guard newState != state else { return }
        state = newState
        restart()
    }

    func playOneShot(_ action: PetAnimationState, onComplete: @escaping () -> Void) {
        guard action != .idle else { return }
        stop()
        isPlayingOneShot = true
        oneShotCompletion = onComplete
        state = action
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        sequence = PetAnimationContract.oneShotSequence(for: action, reducedMotion: reducedMotion)
        frameIndex = 0
        showCurrentFrame()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isPlayingOneShot = false
        oneShotCompletion = nil
    }

    private func restart() {
        stop()
        isPlayingOneShot = false
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        sequence = PetAnimationContract.sequence(for: state, reducedMotion: reducedMotion)
        frameIndex = 0
        showCurrentFrame()
    }

    private func finishOneShot() {
        isPlayingOneShot = false
        let completion = oneShotCompletion
        oneShotCompletion = nil
        completion?()
    }

    private func showCurrentFrame() {
        guard !sequence.frames.isEmpty else {
            onFrame?(nil)
            return
        }

        let frame = sequence.frames[frameIndex]
        onFrame?(sheet?.frame(row: frame.row, column: frame.column))
        guard sequence.frames.count > 1 else { return }

        timer = Timer.scheduledTimer(withTimeInterval: frame.duration, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.advance()
            }
        }
    }

    private func advance() {
        let next = frameIndex + 1
        if next < sequence.frames.count {
            frameIndex = next
        } else if isPlayingOneShot {
            finishOneShot()
            return
        } else if let loopStartIndex = sequence.loopStartIndex {
            frameIndex = loopStartIndex
        } else {
            return
        }
        showCurrentFrame()
    }
}
