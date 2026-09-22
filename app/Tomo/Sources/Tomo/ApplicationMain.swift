import AppKit
import CoreText

@main
enum TomoMain {
    // NSApplication.delegate is weak; keep a strong reference for app lifetime.
    @MainActor
    private static var appDelegate: AppDelegate?

    @MainActor
    static func main() async {
        migrateLegacyUserDataIfNeeded()

        if CommandLine.arguments.contains("--probe-chatgpt-apis") {
            await runChatGPTAPIProbeCLI()
            return
        }

        registerBundledFonts()

        let application = NSApplication.shared
        let delegate = AppDelegate()
        appDelegate = delegate
        application.delegate = delegate
        application.run()
    }

    /// Migrates user configuration, database, and pets from ~/Library/Application Support/Codexling
    /// to ~/Library/Application Support/Tomo on first launch.
    private static func migrateLegacyUserDataIfNeeded() {
        let fileManager = FileManager.default
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let legacyDir = appSupport.appendingPathComponent("Codexling", isDirectory: true)
        let tomoDir = appSupport.appendingPathComponent("Tomo", isDirectory: true)

        guard fileManager.fileExists(atPath: legacyDir.path) else { return }

        if !fileManager.fileExists(atPath: tomoDir.path) {
            do {
                try fileManager.createDirectory(at: tomoDir, withIntermediateDirectories: true)
                let items = try fileManager.contentsOfDirectory(atPath: legacyDir.path)
                for item in items {
                    let source = legacyDir.appendingPathComponent(item)
                    let dest = tomoDir.appendingPathComponent(item)
                    if !fileManager.fileExists(atPath: dest.path) {
                        try? fileManager.copyItem(at: source, to: dest)
                    }
                }
                NSLog("Successfully migrated legacy Codexling data to Tomo")
            } catch {
                NSLog("Failed to migrate legacy Codexling data: %@", error.localizedDescription)
            }
        }
    }

    /// Registers fonts bundled under `Contents/Resources/Fonts` so SwiftUI
    /// `Font.custom` can reference them by family name.
    @MainActor
    private static func registerBundledFonts() {
        guard let fontsURL = Bundle.main.resourceURL?
            .appendingPathComponent("Fonts", isDirectory: true) else { return }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: fontsURL, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.pathExtension.lowercased() == "ttf" {
            var error: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, &error)
        }
    }

    @MainActor
    private static func runChatGPTAPIProbeCLI() async {
        let service = CodexUsageService()
        do {
            let directory = try await service.runChatGPTAPIProbe()
            fputs("API 探测完成：\(directory.path)\n", stderr)
            fputs("摘要：\(directory.appendingPathComponent("manifest.json").path)\n", stderr)
            exit(0)
        } catch {
            fputs("API 探测失败：\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
