import Foundation
import Testing
@testable import Tomo

@Suite("Independent offline API documentation") @MainActor
struct ApiDocsTests {
    private func fixture() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("tomo-api-docs-\(UUID())")
        try FileManager.default.createDirectory(at:root.appendingPathComponent("_next/static"),withIntermediateDirectories:true)
        try Data("Documentation".utf8).write(to:root.appendingPathComponent("index.html"))
        try Data("console.log('docs')".utf8).write(to:root.appendingPathComponent("_next/static/test.js"))
        try Data("private fixture".utf8).write(to:root.appendingPathComponent("credentials.plist"))
        return root
    }
    @Test func immutableSnapshotAndPathIsolation() throws {
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let assets=try ApiDocsAssets(directory:root)
        #expect(assets.asset(for:"/")?.mime=="text/html; charset=utf-8")
        #expect(assets.asset(for:"/_next/static/test.js")?.immutable==true)
        #expect(assets.asset(for:"/?search=token") != nil)
        for target in ["/../index.html","/%2e%2e/index.html","/%252e%252e/index.html","/a\\b","//index.html","/%00","/credentials.plist","/api/v1/credentials","/api/v1/remote/access"] {
            #expect(assets.asset(for:target)==nil)
        }
        try Data("mutated".utf8).write(to:root.appendingPathComponent("index.html"))
        #expect(assets.asset(for:"/")?.data==Data("Documentation".utf8))
    }
    @Test func rejectsSymlinksAndMissingEntry() throws {
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createSymbolicLink(atPath:root.appendingPathComponent("escape.html").path,withDestinationPath:"/etc/hosts")
        #expect(throws:ApiDocsAssets.Failure.invalidSite){try ApiDocsAssets(directory:root)}
        try FileManager.default.removeItem(at:root.appendingPathComponent("escape.html"))
        try FileManager.default.removeItem(at:root.appendingPathComponent("index.html"))
        #expect(throws:ApiDocsAssets.Failure.missingSite){try ApiDocsAssets(directory:root)}
    }
    @Test func actualLoopbackRequests() async throws {
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        // ApiDocsServer refuses port 0, so take a port the system just handed out.
        let port=try RemoteTLSFixture.freePort()
        let server=try ApiDocsServer(directory:root,port:port)
        var state=ApiDocsServer.Status.stopped;server.onStatus={state=$0};server.start();defer{server.stop()}
        for _ in 0..<200 {if state == .running {break};if case .failed = state {break};try await Task.sleep(for:.milliseconds(20))}
        #expect(state == .running);guard state == .running else{return}
        let session=URLSession(configuration:.ephemeral);defer{session.invalidateAndCancel()}
        let base="http://127.0.0.1:\(port)"
        let (data,response)=try await session.data(from:URL(string:base+"/")!)
        #expect(data==Data("Documentation".utf8));#expect((response as? HTTPURLResponse)?.statusCode==200)
        #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField:"Cache-Control")=="no-store")
        for route in ["/","/api/v1/credentials"] {
            var request=URLRequest(url:URL(string:base+route)!);request.httpMethod="HEAD"
            let (body,response)=try await session.data(for:request)
            #expect(body.isEmpty);#expect((response as? HTTPURLResponse)?.statusCode==(route=="/" ? 200:404))
        }
        var post=URLRequest(url:URL(string:base+"/")!);post.httpMethod="POST"
        let (_,postResponse)=try await session.data(for:post)
        #expect((postResponse as? HTTPURLResponse)?.statusCode==405)
        #expect((postResponse as? HTTPURLResponse)?.value(forHTTPHeaderField:"Allow")=="GET, HEAD")
        server.stop();#expect(state == .stopped)
    }
    @Test func occupiedPortDoesNotReplaceExistingService() async throws {
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let port=try RemoteTLSFixture.freePort()
        let first=try ApiDocsServer(directory:root,port:port)
        var firstState=ApiDocsServer.Status.stopped;first.onStatus={firstState=$0};first.start();defer{first.stop()}
        for _ in 0..<200 {if firstState == .running {break};try await Task.sleep(for:.milliseconds(20))}
        #expect(firstState == .running);guard firstState == .running else{return}
        let second=try ApiDocsServer(directory:root,port:port)
        var secondState=ApiDocsServer.Status.stopped;second.onStatus={secondState=$0};second.start();defer{second.stop()}
        for _ in 0..<850 {if case .failed = secondState {break};try await Task.sleep(for:.milliseconds(20))}
        guard case .failed = secondState else {Issue.record("Occupied port was not reported as a failure");return}
        let session=URLSession(configuration:.ephemeral);defer{session.invalidateAndCancel()}
        let (data,response)=try await session.data(from:URL(string:"http://127.0.0.1:\(port)/")!)
        #expect((response as? HTTPURLResponse)?.statusCode==200)
        #expect(data==Data("Documentation".utf8));#expect(firstState == .running)
    }

}
