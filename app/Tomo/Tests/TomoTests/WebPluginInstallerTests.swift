import Foundation
import Testing
@testable import Tomo

@Suite("WebPluginInstaller migration")
struct WebPluginInstallerTests {
    @Test("Retired package does not replace the installed RN package")
    func rejectsRetiredPackageBeforeReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent("installed")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try Data("current RN page".utf8).write(to: installed.appendingPathComponent("index.html"))
        let zip = try package(version: "0.3.3", root: root)
        let installer = WebPluginInstaller(pluginDirectory: installed)

        do {
            try installer.install(fromLocalZip: zip)
            Issue.record("Retired Web Core package was accepted")
        } catch {
            #expect((error as NSError).domain == "WebPluginInstaller")
            #expect((error as NSError).code == 6)
        }
        #expect(try String(contentsOf: installed.appendingPathComponent("index.html"), encoding: .utf8) == "current RN page")
    }

    @Test("Current RN package can replace an older installation")
    func installsCurrentPackage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent("installed")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try Data("old page".utf8).write(to: installed.appendingPathComponent("index.html"))
        let zip = try package(version: "1.0.0", root: root)
        let installer = WebPluginInstaller(pluginDirectory: installed)

        try installer.install(fromLocalZip: zip)

        #expect(installer.currentStatus().displayVersion == "1.0.0")
        #expect(try String(contentsOf: installed.appendingPathComponent("index.html"), encoding: .utf8) == "new page")
    }

    private func package(version: String, root: URL) throws -> URL {
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("new page".utf8).write(to: source.appendingPathComponent("index.html"))
        try JSONEncoder().encode(WebPluginManifest(version: version))
            .write(to: source.appendingPathComponent("plugin-manifest.json"))
        let zip = root.appendingPathComponent("plugin.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", source.path, zip.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return zip
    }
}
