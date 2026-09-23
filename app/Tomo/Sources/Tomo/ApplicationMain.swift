import AppKit
import CoreText

@main
enum TomoMain {
    // NSApplication.delegate is weak; keep a strong reference for app lifetime.
    @MainActor
    private static var appDelegate: AppDelegate?

    @MainActor
    static func main() async {
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
