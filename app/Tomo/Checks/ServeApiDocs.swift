import Foundation

/// Development-only executable serving the exact exported site with the
/// production Swift listener. The desktop app uses bundled resources instead.
@main struct ServeApiDocs {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2 else {throw NSError(domain:"docs-preview",code:1,userInfo:[NSLocalizedDescriptionKey:"Expected exported site directory"])}
        let server=try ApiDocsServer(directory:URL(fileURLWithPath:CommandLine.arguments[1]),port:58351)
        server.onStatus={status in print("Documentation listener: \(status)")}
        server.start()
        while !Task.isCancelled {try await Task.sleep(for:.seconds(30))}
        server.stop()
    }
}
