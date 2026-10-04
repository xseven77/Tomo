import Foundation

@main struct DocsCheck {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tomo-docs-check-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {try? FileManager.default.removeItem(at: root)}
        try Data("<h1>Docs fixture</h1>".utf8).write(to: root.appendingPathComponent("index.html"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("_next/static"), withIntermediateDirectories: true)
        try Data("console.log('fixture');".utf8).write(to: root.appendingPathComponent("_next/static/test.js"))
        try Data("secret".utf8).write(to: root.appendingPathComponent("local.plist"))
        let assets = try ApiDocsAssets(directory: root)
        precondition(assets.asset(for: "/")?.mime == "text/html; charset=utf-8")
        precondition(assets.asset(for: "/?test=1") != nil)
        precondition(assets.asset(for: "/_next/static/test.js")?.immutable == true)
        precondition(assets.asset(for: "/local.plist") == nil)
        for path in ["/../index.html", "/%2e%2e/index.html", "/%252e%252e/index.html", "/a\\b", "//index.html", "/api/v1/credentials", "/api/v1/remote/access", "/index.html#x", "/%00"] {precondition(assets.asset(for: path) == nil)}
        try Data("changed".utf8).write(to: root.appendingPathComponent("index.html"))
        precondition(String(data: assets.asset(for: "/")!.data, encoding:.utf8) == "<h1>Docs fixture</h1>")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("escape.html").path, withDestinationPath: "/etc/hosts")
        do { _ = try ApiDocsAssets(directory: root); fatalError("symlink accepted") } catch ApiDocsAssets.Failure.invalidSite {}
        try FileManager.default.removeItem(at: root.appendingPathComponent("escape.html"))
        let server = try ApiDocsServer(directory: root, port: 59351)
        var running = false, failure: String?
        server.onStatus = {status in if status == .running {running = true}; if case .failed(let reason) = status {failure=reason}}
        server.start(); defer {server.stop()}
        for _ in 0..<100 {if running || failure != nil {break}; try await Task.sleep(for:.milliseconds(20))}
        guard running else {throw NSError(domain:"docs-check",code:1,userInfo:[NSLocalizedDescriptionKey:failure ?? "listener did not become ready"])}
        let session = URLSession(configuration:.ephemeral); defer {session.invalidateAndCancel()}
        let base = "http://127.0.0.1:59351"
        let (data,response) = try await session.data(from: URL(string:base + "/")!)
        precondition((response as? HTTPURLResponse)?.statusCode == 200 && String(data:data,encoding:.utf8) == "changed")
        var head = URLRequest(url:URL(string:base + "/")!); head.httpMethod="HEAD"
        let (headData,headResponse) = try await session.data(for:head)
        precondition(headData.isEmpty && (headResponse as? HTTPURLResponse)?.value(forHTTPHeaderField:"Content-Length") == "7")
        var missing = head; missing.url = URL(string:base + "/api/v1/credentials")!
        let (missingData,missingResponse) = try await session.data(for:missing)
        precondition(missingData.isEmpty && (missingResponse as? HTTPURLResponse)?.statusCode == 404)
        var post = URLRequest(url:URL(string:base + "/")!); post.httpMethod="POST"
        let (_,postResponse) = try await session.data(for:post)
        precondition((postResponse as? HTTPURLResponse)?.statusCode == 405)
        print("Docs assets and actual loopback GET/HEAD/404/405 checks passed")
    }
}
