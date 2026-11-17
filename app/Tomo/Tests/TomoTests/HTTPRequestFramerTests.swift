import Foundation
import Testing
@testable import Tomo

@Suite("Bounded HTTP request framing")
struct HTTPRequestFramerTests {
    @Test("Every byte boundary of a UTF-8 body waits for the complete request")
    func fragmentedBody() {
        let body = Data(#"{"text":"继续开发 👋"}"#.utf8)
        var request = Data("POST /api/v1/remote/sessions/a/messages HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        request.append(body)
        for offset in 0..<request.count {
            #expect(HTTPRequestFramer.inspect(Data(request.prefix(offset))) == .incomplete)
        }
        #expect(HTTPRequestFramer.inspect(request) == .complete(request))
    }

    @Test("GET requests without a body complete at the header terminator")
    func getRequest() {
        let request = Data("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
        #expect(HTTPRequestFramer.inspect(request) == .complete(request))
    }

    @Test("Conflicting lengths and transfer encodings cannot reach the router")
    func ambiguousFraming() {
        for headers in ["Content-Length: 1\r\nContent-Length: 2", "Content-Length: -1", "Content-Length: 1,2", "Content-Length: abc"] {
            let request = Data("POST /api HTTP/1.1\r\n\(headers)\r\n\r\n".utf8)
            #expect(HTTPRequestFramer.inspect(request) == .rejected(400))
        }
        #expect(HTTPRequestFramer.inspect(Data("POST /api HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) == .rejected(501))
    }

    @Test("Oversized headers/bodies and trailing pipelined data are rejected")
    func bounds() {
        #expect(HTTPRequestFramer.inspect(Data(repeating: 65, count: 16_385)) == .rejected(431))
        #expect(HTTPRequestFramer.inspect(Data("POST /api HTTP/1.1\r\nContent-Length: 1048577\r\n\r\n".utf8)) == .rejected(413))
        #expect(HTTPRequestFramer.inspect(Data("GET /health HTTP/1.1\r\n\r\nGET /health HTTP/1.1\r\n\r\n".utf8)) == .rejected(400))
    }
}
