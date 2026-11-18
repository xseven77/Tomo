import AppKit
import Foundation
import ImageIO

enum CodexPetSource: String, Sendable {
    case codexBuiltIn
    case tomoBuiltIn
    case custom

    var title: String {
        switch self {
        case .codexBuiltIn:
            "Codex 内置"
        case .tomoBuiltIn:
            "Tomo 内置"
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
    var spriteModifiedAt: Date? = nil
}

struct CodexPetSelectionSync: Sendable {
    let configURL: URL

    init(configURL: URL? = nil) {
        self.configURL = configURL
            ?? CodexPetCatalog.codexHome.appendingPathComponent("config.toml")
    }

    func readSelectedPetID() -> String? {
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8),
              let codexID = selectedAvatarID(in: contents), !codexID.isEmpty else {
            return nil
        }
        if codexID == "default" || codexID.hasPrefix("custom:") || codexID.hasPrefix("pet_") {
            return codexID
        }
        return "builtin:\(codexID)"
    }

    func writeSelection(_ id: String) throws {
        let value = try JSONEncoder().encode(id)
        let setting = "selected-avatar-id = " + String(decoding: value, as: UTF8.self)
        let existing: String
        do {
            existing = try String(contentsOf: configURL, encoding: .utf8)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            existing = ""
        }
        let newline = existing.contains("\r\n") ? "\r\n" : "\n"
        var lines = existing.components(separatedBy: newline)
        var desktop: Int?
        var insertion: Int?
        for index in lines.indices {
            let line = lines[index].components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                if desktop != nil { break }
                if line == "[desktop]" { desktop = index; insertion = index + 1 }
            } else if desktop != nil, line.components(separatedBy: "=").first?.trimmingCharacters(in: .whitespaces) == "selected-avatar-id" {
                lines[index] = setting
                insertion = nil
                break
            }
        }
        if let insertion {
            lines.insert(setting, at: insertion)
        } else if desktop == nil {
            lines.append(contentsOf: ["[desktop]", setting, ""])
        }
        try lines.joined(separator: newline).write(to: configURL, atomically: true, encoding: .utf8)
    }

    func selectedAvatarID(in contents: String) -> String? {
        let lines = contents.components(separatedBy: .newlines)
        var isDesktopSection = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                isDesktopSection = trimmed.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces) == "[desktop]"
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
    private var debounceWorkItem: DispatchWorkItem?
    private var pollTimer: Timer?

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
        guard pollTimer == nil else { return }
        installSource()
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.installSource()
                self?.onChange()
            }
        }
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        pollTimer?.invalidate()
        pollTimer = nil
        source?.cancel()
        source = nil
    }

    private func installSource() {
        guard source == nil else { return }
        let descriptor = open(configURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

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
                installSource()
            }
        }
        nextSource.setCancelHandler { close(descriptor) }
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

}

private struct CustomPetManifest: Codable {
    let id: String
    let displayName: String
    let description: String?
    let spriteVersionNumber: Int?
    let spritesheetPath: String
}

struct CodexPetCatalog: Sendable {
    static let defaultPetAssetID = "tomo"
    static let tomoPetAssetIDs = ["tomo", "tomo-v1", "tomo-codexling"]
    static let defaultPetID = "builtin:\(defaultPetAssetID)"
    static let retiredBuiltInPetIDs: Set<String> = ["codex", "codexling", "codeling"]

    static func migratedSelection(_ id: String) -> String {
        if id == "builtin:tomo-tako" || id == "custom:tomo-tako" { return "builtin:tomo-v1" }
        if id == "custom:tomo-v2" { return "builtin:tomo" }
        if let asset = tomoPetAssetIDs.first(where: { id == "custom:\($0)" }) { return "builtin:\(asset)" }
        let asset = id.hasPrefix("builtin:") ? String(id.dropFirst("builtin:".count)) : id
        return retiredBuiltInPetIDs.contains(asset.lowercased()) ? defaultPetID : id
    }
    static var defaultCustomPetsRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("Tomo", isDirectory: true)
            .appendingPathComponent("Pets", isDirectory: true)
    }

    static var codexHome: URL {
        if let path = ProcessInfo.processInfo.environment["CODEX_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    static let hiddenTomoIDs: Set<String> = ["tomo-v1", "tomo-codexling", "tomo-tako"]
    static let hiddenTomoNames: Set<String> = ["tomo v1", "tomo codexling", "tomo tako"]

    static var codexApplicationURL: URL? {
        let identifier = "com.openai.codex"
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier),
            URL(fileURLWithPath: "/Applications/Codex.app"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            home.appendingPathComponent("Applications/Codex.app"),
            home.appendingPathComponent("Applications/ChatGPT.app"),
        ]
        return candidates.compactMap { $0 }.first { Bundle(url: $0)?.bundleIdentifier == identifier }
    }

    let customPetsRoot: URL
    let bundledPetsRoot: URL?
    let codexPetsRoot: URL?

    init(customPetsRoot: URL? = nil, bundledPetsRoot: URL? = nil, codexPetsRoot: URL? = nil) {
        self.customPetsRoot = customPetsRoot ?? Self.defaultCustomPetsRoot
        self.bundledPetsRoot = bundledPetsRoot ?? Self.resolveBundledPetsRoot()
        self.codexPetsRoot = codexPetsRoot
    }

    static func resolveBundledPetsRoot() -> URL? {
        if let url = Bundle.main.url(forResource: "pet", withExtension: "json", subdirectory: "Pets/tomo")?
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

    func discover(codexBuiltIns: [CodexPet] = [], accountPets: [CodexPet] = []) -> [CodexPet] {
        let builtIns = pets(in: bundledPetsRoot, source: .tomoBuiltIn, prefix: "builtin:").filter { $0.id == Self.defaultPetID }
        let localCodexPets = pets(in: codexPetsRoot, source: .custom, prefix: "custom:")
        let localTomoPets = pets(in: customPetsRoot, source: .custom, prefix: "custom:")
            .filter { $0.assetID != Self.defaultPetAssetID }
        let custom = (accountPets + localCodexPets + localTomoPets).filter {
            !Self.hiddenTomoIDs.contains($0.assetID.lowercased()) &&
            !Self.hiddenTomoNames.contains($0.displayName.lowercased()) &&
            !(builtIns.contains { $0.id == Self.defaultPetID } && $0.assetID == Self.defaultPetAssetID)
        }
        var seen = Set<String>()
        return builtIns + codexBuiltIns + custom.filter { seen.insert($0.id).inserted }.sorted {
            let order = $0.displayName.localizedStandardCompare($1.displayName)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    private func pets(in root: URL?, source: CodexPetSource, prefix: String) -> [CodexPet] {
        guard let root,
              let directories = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
              ) else { return [] }
        return directories.sorted { $0.path < $1.path }.compactMap {
            parsePet(in: $0, source: source, idPrefix: prefix)
        }
    }

    private func parsePet(in directory: URL, source: CodexPetSource, idPrefix: String) -> CodexPet? {
        let manifestURL = directory.appendingPathComponent("pet.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(CustomPetManifest.self, from: data) else {
            return nil
        }

        let spritesheetURL = directory.appendingPathComponent(manifest.spritesheetPath).resolvingSymlinksInPath().standardizedFileURL
        let directoryPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        guard spritesheetURL.path.hasPrefix(directoryPath + "/"),
              let dimensions = imageDimensions(at: spritesheetURL),
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
            description: manifest.description ?? source.title,
            source: source,
            spriteVersionNumber: version,
            spritesheetURL: spritesheetURL,
            rowCount: rowCount,
            spriteModifiedAt: try? spritesheetURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        )
    }
}

func imageDimensions(at url: URL) -> (width: Int, height: Int)? {
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

enum PetDragDirection: Equatable {
    case left
    case right
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

    static func dragSequence(for direction: PetDragDirection, reducedMotion: Bool) -> PetAnimationSequence {
        let row = direction == .right ? 1 : 2
        let movement = frames(row: row, count: 8, duration: 90, finalDuration: 90)
        if reducedMotion {
            return PetAnimationSequence(frames: [movement[0]], loopStartIndex: nil)
        }
        return PetAnimationSequence(frames: movement, loopStartIndex: 0)
    }

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
        guard let cropped = frameImage(row: row, column: column) else { return nil }
        let displayWidth = displayHeight * CGFloat(Self.cellWidth) / CGFloat(Self.cellHeight)
        return NSImage(cgImage: cropped, size: NSSize(width: displayWidth, height: displayHeight))
    }

    func themeAccentHex() -> String? {
        // The first idle frame shows the pet without effects from its reactions.
        guard let idle = frameImage(row: 0, column: 0),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = Self.cellWidth / 4
        let height = Self.cellHeight / 4
        let bytesPerRow = width * 4
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ), let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }

        context.interpolationQuality = .medium
        context.setBlendMode(.copy)
        context.draw(idle, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Group shaded pixels by hue so one body color can span multiple shades.
        // Group near-neutral pixels by brightness to distinguish outlines from lighter fur.
        var buckets = Array(repeating: (count: 0, red: 0, green: 0, blue: 0), count: 16)
        for offset in stride(from: 0, to: bytesPerRow * height, by: 4) {
            let alpha = Int(pixels[offset + 3])
            guard alpha >= 224 else { continue }
            let red = Int(pixels[offset]) * 255 / alpha
            let green = Int(pixels[offset + 1]) * 255 / alpha
            let blue = Int(pixels[offset + 2]) * 255 / alpha
            let high = max(red, green, blue)
            let low = min(red, green, blue)
            let chroma = high - low
            let index: Int
            if chroma < 12 {
                index = 12 + (high + low) / 128
            } else {
                let hue: Double
                switch high {
                case red: hue = Double(green - blue) / Double(chroma)
                case green: hue = 2 + Double(blue - red) / Double(chroma)
                default: hue = 4 + Double(red - green) / Double(chroma)
                }
                index = Int((hue * 2).rounded() + 12) % 12
            }
            buckets[index].count += 1
            buckets[index].red += red
            buckets[index].green += green
            buckets[index].blue += blue
        }

        guard let body = buckets.max(by: { $0.count < $1.count }), body.count > 0 else { return nil }
        let hex = String(format: "#%02X%02X%02X", body.red / body.count, body.green / body.count, body.blue / body.count)
        let (hue, saturation, lightness) = TomoThemeConstants.hexToHsl(hex)
        // Keep muted colors as they are and compress only the more saturated portion.
        let themeSaturation = saturation - max(0, saturation - 30) * 0.75
        let themeLightness = min(56, max(38, lightness))
        return TomoThemeConstants.hslToHex(h: hue, s: themeSaturation, l: themeLightness)
    }

    private func frameImage(row: Int, column: Int) -> CGImage? {
        guard row >= 0, row < rowCount, column >= 0, column < 8 else { return nil }
        let cropRect = CGRect(
            x: column * Self.cellWidth,
            y: row * Self.cellHeight,
            width: Self.cellWidth,
            height: Self.cellHeight
        )
        return image.cropping(to: cropRect)
    }
}

@MainActor
final class PetAnimationPlayer {
    var onFrame: ((NSImage?) -> Void)?

    private var sheet: PetSpriteSheet?
    private var pet: CodexPet?
    private var state: PetAnimationState = .idle
    private var dragDirection: PetDragDirection?
    private var oneShotAction: PetAnimationState?
    private var sequence = PetAnimationContract.sequence(for: .idle, reducedMotion: false)
    private var frameIndex = 0
    private var timer: Timer?

    var isAnimatingDrag: Bool { dragDirection != nil }

    func setPet(_ pet: CodexPet?) {
        guard pet != self.pet else { return }
        self.pet = pet
        sheet = pet.flatMap { PetSpriteSheet(url: $0.spritesheetURL) }
        oneShotAction = nil
        restart()
    }

    func setState(_ newState: PetAnimationState) {
        guard newState != state else { return }
        state = newState
        guard dragDirection == nil, oneShotAction == nil else { return }
        restart()
    }

    func setDragDirection(_ direction: PetDragDirection?) {
        guard direction != dragDirection else { return }
        dragDirection = direction
        oneShotAction = nil
        restart()
    }

    func playOneShot(_ action: PetAnimationState) {
        guard action != .idle, dragDirection == nil else { return }
        oneShotAction = action
        restart()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        dragDirection = nil
        oneShotAction = nil
    }

    private func restart() {
        timer?.invalidate()
        timer = nil
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let dragDirection {
            sequence = PetAnimationContract.dragSequence(for: dragDirection, reducedMotion: reducedMotion)
        } else if let oneShotAction {
            sequence = PetAnimationContract.oneShotSequence(for: oneShotAction, reducedMotion: reducedMotion)
        } else {
            sequence = PetAnimationContract.sequence(for: state, reducedMotion: reducedMotion)
        }
        frameIndex = 0
        showCurrentFrame()
    }

    private func showCurrentFrame() {
        guard let sheet else {
            onFrame?(nil)
            return
        }

        let frame = sequence.frames[frameIndex]
        onFrame?(sheet.frame(row: frame.row, column: frame.column))
        guard sequence.frames.count > 1 || oneShotAction != nil else { return }

        let nextFrame = Timer(timeInterval: frame.duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.advance()
            }
        }
        timer = nextFrame
        RunLoop.main.add(nextFrame, forMode: .common)
    }

    private func advance() {
        let next = frameIndex + 1
        if next < sequence.frames.count {
            frameIndex = next
        } else if oneShotAction != nil {
            oneShotAction = nil
            restart()
            return
        } else if let loopStartIndex = sequence.loopStartIndex {
            frameIndex = loopStartIndex
        } else {
            return
        }
        showCurrentFrame()
    }
}
