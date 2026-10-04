import XCTest
import Foundation
import Security
import Darwin
@testable import Tomo

/// Ephemeral synthetic identity. Import only to memory; never touch user keychains
/// or install roots. The client pins this cert and still validates the hostname.
struct RemoteTLSFixture {
    enum FixtureError: Error { case openssl(Int32), pkcs12(OSStatus), certificate(OSStatus) }
    let directory: URL
    let identity: RemoteTLSIdentity
    let certificate: SecCertificate

    init() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Memory-only PKCS12 import requires macOS 15") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tomo-tls-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let config = """
            [req]
            distinguished_name=dn
            x509_extensions=extensions
            prompt=no
            [dn]
            CN=Tomo synthetic test \(UUID().uuidString)
            [extensions]
            subjectAltName=IP:127.0.0.1,DNS:localhost
            basicConstraints=critical,CA:TRUE
            keyUsage=critical,digitalSignature,keyCertSign
            extendedKeyUsage=serverAuth
            """
            try config.write(to: directory.appendingPathComponent("openssl.cnf"), atomically: true, encoding: .utf8)
            func run(_ arguments: [String]) throws {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
                process.arguments = arguments; process.currentDirectoryURL = directory
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw FixtureError.openssl(process.terminationStatus) }
            }
            try run(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "key.pem"])
            try run(["req", "-new", "-x509", "-key", "key.pem", "-days", "1", "-set_serial", "0x" + UUID().uuidString.replacingOccurrences(of: "-", with: ""), "-config", "openssl.cnf", "-out", "cert.pem"])
            try run(["pkcs12", "-export", "-inkey", "key.pem", "-in", "cert.pem", "-out", "identity.p12", "-passout", "pass:synthetic-test-only"])
            let data = try Data(contentsOf: directory.appendingPathComponent("identity.p12"))
            var imported: CFArray?
            let options = [kSecImportExportPassphrase as String: "synthetic-test-only", kSecImportToMemoryOnly as String: true] as [String: Any]
            let importStatus = SecPKCS12Import(data as CFData, options as CFDictionary, &imported)
            guard importStatus == errSecSuccess,
                  let first = (imported as? [[String: Any]])?.first,
                  let value = first[kSecImportItemIdentity as String] else { throw FixtureError.pkcs12(importStatus) }
            let identity = value as! SecIdentity
            var certificate: SecCertificate?
            let copyStatus = SecIdentityCopyCertificate(identity, &certificate)
            guard copyStatus == errSecSuccess, let certificate else { throw FixtureError.certificate(copyStatus) }
            self.directory = directory; self.identity = RemoteTLSIdentity(value: identity); self.certificate = certificate
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration, delegate: PinnedTrust(certificate), delegateQueue: nil)
    }
    func taskDelegate() -> any URLSessionTaskDelegate { PinnedTrust(certificate) }
    private final class PinnedTrust: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let certificate: SecCertificate
        init(_ certificate: SecCertificate) { self.certificate = certificate }
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            urlSession(session, didReceive: challenge, completionHandler: completionHandler)
        }
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust,
                  SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, challenge.protectionSpace.host as CFString)) == errSecSuccess,
                  SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else {
                completionHandler(.cancelAuthenticationChallenge, nil); return
            }
            SecTrustSetNetworkFetchAllowed(trust, false)
            if SecTrustEvaluateWithError(trust, nil) { completionHandler(.useCredential, URLCredential(trust: trust)) }
            else { completionHandler(.cancelAuthenticationChallenge, nil) }
        }
    }
    static func freePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw RemoteAccessError.unavailable }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
        }
        guard bound == 0, read == 0 else { throw RemoteAccessError.unavailable }
        return UInt16(bigEndian: address.sin_port)
    }
}

final class RemoteHTTPSListenerTests: XCTestCase {
    func testParserPreservesDuplicateHeadersAndExactBody() throws {
        let body = Data([0, 255, 13, 10])
        var request = Data("POST /api/v1/remote/access/exchange?q=one HTTP/1.1\r\nHost: attacker.invalid\r\nDPoP: first\r\ndpop: second\r\nContent-Length: 4\r\n\r\n".utf8)
        request.append(body)
        let parsed = try RemoteHTTPSListener.parse(request)
        XCTAssertEqual(parsed.headers.filter { $0.0.lowercased() == "dpop" }.count, 2)
        XCTAssertEqual(parsed.body, body)
        XCTAssertEqual(parsed.query, ["q": "one"])
    }
    func testParserRejectsAmbiguousTargetsAndFraming() {
        for target in ["https://other.invalid/api/v1/remote/catalog", "//other.invalid/api/v1/remote/catalog",
                       "/api/v1/remote/%63atalog", "/api/v1/remote/catalog#fragment",
                       "/api/v1/remote/catalog?cursor=1&cursor=2", "/api/v1/remote/catalog?cursor=1&%63ursor=2"] {
            XCTAssertThrowsError(try RemoteHTTPSListener.parse(Data("GET \(target) HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)))
        }
        for wire in ["POST /api/v1/remote/catalog HTTP/1.1\r\nContent-Length: 5\r\n\r\nabc",
                     "POST /api/v1/remote/catalog HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 1\r\n\r\n",
                     "POST /api/v1/remote/catalog HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
                     "GET /api/v1/remote/catalog HTTP/1.1\r\n\r\nGET /api/v1/remote/catalog HTTP/1.1\r\n\r\n"] {
            XCTAssertThrowsError(try RemoteHTTPSListener.parse(Data(wire.utf8)))
        }
    }
}
