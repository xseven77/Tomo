import Foundation
import XCTest
@testable import Tomo

final class GeminiQuotaResponseTests: XCTestCase {
    func testVersionedDailyQuotaMatchesAntigravityFractionsAndResetTimes() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiQuotaFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = GeminiOAuthService(
            configuration: .init(clientID: "fixture-client", legacyClientSecret: nil), session: session)

        let snapshot = await service.fetchQuotaSnapshot(accessToken: "fixture-token")

        XCTAssertEqual(snapshot.quotaFetchState, "normal")
        XCTAssertEqual(snapshot.planName, "Google AI Pro")
        XCTAssertEqual(try XCTUnwrap(snapshot.geminiFiveHourRemaining), 0.95172447, accuracy: 0.00000001)
        XCTAssertEqual(try XCTUnwrap(snapshot.geminiWeeklyRemaining), 0.98477846, accuracy: 0.00000001)
        XCTAssertEqual(snapshot.geminiFiveHourResetDesc, "2026-10-21T11:59:35Z")
        XCTAssertEqual(snapshot.geminiWeeklyResetDesc, "2026-10-24T02:00:49Z")
        XCTAssertEqual(snapshot.claudeGptFiveHourRemaining, 0.9992)
        XCTAssertEqual(snapshot.claudeGptWeeklyRemaining, 0.9988224)
        XCTAssertEqual(snapshot.availableModels, ["gemini-example"])
    }

    func testModelValidationContinuesUsingDailyCatalog() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiQuotaFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = GeminiOAuthService(
            configuration: .init(clientID: "fixture-client", legacyClientSecret: nil), session: session)
        let models = try await service.validateModels(accessToken: "fixture-token")
        XCTAssertEqual(models, ["gemini-example"])
    }
}

private final class GeminiQuotaFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let body: String
        switch (url.host, url.lastPathComponent) {
        case ("daily-cloudcode-pa.googleapis.com", "v1internal:loadCodeAssist"):
            body = #"{"cloudaicompanionProject":"fixture-project","paidTier":{"id":"g1-pro-tier"}}"#
        case ("daily-cloudcode-pa.googleapis.com", "v1internal:retrieveUserQuotaSummary")
            where request.value(forHTTPHeaderField: "User-Agent") == "antigravity/2.23.1":
            // Live daily response matched against Antigravity on 2026-10-21.
            body = #"""
            {"groups":[
                {"displayName":"Gemini Models","buckets":[
                    {"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.98477846,"resetTime":"2026-10-24T02:00:49Z"},
                    {"bucketId":"gemini-5h","window":"5h","remainingFraction":0.95172447,"resetTime":"2026-10-21T11:59:35Z"}
                ]},
                {"displayName":"Claude and GPT models","buckets":[
                    {"bucketId":"3p-weekly","window":"weekly","remainingFraction":0.9988224},
                    {"bucketId":"3p-5h","window":"5h","remainingFraction":0.9992}
                ]}
            ]}
            """#
        case ("daily-cloudcode-pa.googleapis.com", "v1internal:retrieveUserQuotaSummary"):
            // The unversioned header succeeds but silently omits Gemini.
            body = #"""
            {"groups":[{"displayName":"Claude and GPT models","buckets":[
                {"bucketId":"3p-weekly","window":"weekly","remainingFraction":0.9988224},
                {"bucketId":"3p-5h","window":"5h","remainingFraction":0.9992}
            ]}]}
            """#
        case ("cloudcode-pa.googleapis.com", "v1internal:retrieveUserQuotaSummary"):
            // Wrong-host responses can look valid; assert values and resets,
            // not just HTTP 200 or the presence of both windows.
            body = #"""
            {"groups":[{"displayName":"Gemini Models","buckets":[
                {"bucketId":"gemini-weekly","window":"weekly","remainingFraction":1,"resetTime":"2026-10-28T06:50:34Z"},
                {"bucketId":"gemini-5h","window":"5h","remainingFraction":1,"resetTime":"2026-10-21T12:32:21Z"}
            ]}]}
            """#
        case ("daily-cloudcode-pa.googleapis.com", "v1internal:fetchAvailableModels"):
            // A model quota must never be interpreted as a weekly bucket.
            body = #"{"models":{"gemini-example":{"quotaInfo":{"remainingFraction":0.95}}}}"#
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
