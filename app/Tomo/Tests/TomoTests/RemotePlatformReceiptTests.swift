import XCTest
import CryptoKit
@testable import Tomo

@MainActor
final class RemotePlatformReceiptTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let server = "11111111-1111-4111-8111-111111111111"
    private let grantId = "22222222-2222-4222-8222-222222222222"
    private let user = "33333333-3333-4333-8333-333333333333"
    private let device = "44444444-4444-4444-8444-444444444444"
    private let path = "/api/v1/remote/access/exchange/nonce"
    private func encoded(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"") }
    private func signed(_ key: P256.Signing.PrivateKey, type: String, claims: [String: Any], extra: [String: Any] = [:]) throws -> String {
        let header = ["alg":"ES256","typ":type,"kid":"cloud"].merging(extra) { _,new in new }
        let input = try encoded(JSONSerialization.data(withJSONObject:header)) + "." + encoded(JSONSerialization.data(withJSONObject:claims))
        return input + "." + encoded(try key.signature(for:Data(input.utf8)).rawRepresentation)
    }
    private func setup() async throws -> (RemoteCloudGrantVerifier,P256.Signing.PrivateKey,String,Data,[String:Any]) {
        let key = P256.Signing.PrivateKey(), raw = key.publicKey.x963Representation
        let jwk = ["kty":"EC","crv":"P-256","x":encoded(raw.subdata(in:1..<33)),"y":encoded(raw.subdata(in:33..<65)),"alg":"ES256","use":"sig","kid":"cloud"]
        let cloud = try await RemoteCloudGrantVerifier.configured(jwks:JSONSerialization.data(withJSONObject:["keys":[jwk]]),
            issuer:"https://accounts.example.test",serverId:server,trustedUntil:now.addingTimeInterval(120),now:now)
        let time = Int(now.timeIntervalSince1970), thumb = encoded(Data(repeating:1,count:32))
        let common: [String:Any] = ["iss":"https://accounts.example.test","aud":server,"sub":user,"deviceId":device,"cnf":["jkt":thumb],"iat":time,"nbf":time]
        let grantClaims = common.merging(["jti":grantId,"exp":time+300,"bindingId":UUID().uuidString,"bindingRevision":1,
            "entitlementVersion":1,"scope":"server.identity","resources":[String]()]) { _,new in new }
        let grant = try signed(key,type:"tomo-remote-grant+jwt",claims:grantClaims)
        let body = try JSONSerialization.data(withJSONObject:["grant":grant],options:[.sortedKeys])
        let bodyHash = encoded(Data(SHA256.hash(data:body)))
        let input = ["tomo-platform-http-v1",server,grantId,"POST",path,bodyHash].joined(separator:"\n")
        let claims = common.merging(["jti":UUID().uuidString,"exp":time+60,"grantId":grantId,
            "requestHash":encoded(Data(SHA256.hash(data:Data(input.utf8)))),"platform":"ios","environment":"production","version":"1","category":1]) { _,new in new }
        return (cloud,key,grant,body,claims)
    }
    private func request(_ body:Data, _ receipt:String, path:String?=nil, duplicate:Bool=false) -> RemoteProductionAccessRouter.Request {
        let headers = duplicate ? [("X-Tomo-Platform-Receipt",receipt),("x-tomo-platform-receipt",receipt)] : [("X-Tomo-Platform-Receipt",receipt)]
        return .init(method:"POST",path:path ?? self.path,query:[:],headers:headers,body:body)
    }
    private func denied(_ action: () async throws -> Void) async {
        do { try await action(); XCTFail("Untrusted platform receipt accepted") }
        catch { XCTAssertEqual(error as? RemoteAccessError,.forbidden) }
    }
    func testTrustedCloudSignatureAndExactHTTPBindingAreRequired() async throws {
        let (cloud,key,_,body,claims) = try await setup()
        let receipt = try signed(key,type:"tomo-platform-receipt+jwt",claims:claims)
        try await cloud.verifyPlatformRequest(request(body,receipt),now:now)
        await denied { try await cloud.verifyPlatformRequest(request(body,receipt,path:"/api/v1/remote/access/exchange"),now:now) }
        await denied { try await cloud.verifyPlatformRequest(request(body+Data(" ".utf8),receipt),now:now) }
        await denied { try await cloud.verifyPlatformRequest(request(body,receipt,duplicate:true),now:now) }
        await denied { try await cloud.verifyPlatformRequest(request(body,""),now:now) }
        let other = try signed(P256.Signing.PrivateKey(),type:"tomo-platform-receipt+jwt",claims:claims)
        await denied { try await cloud.verifyPlatformRequest(request(body,other),now:now) }
    }
    func testReceiptCannotChangeIdentityPlatformEnvironmentOrLifetime() async throws {
        let (cloud,key,_,body,claims) = try await setup()
        let patches: [[String:Any]] = [["aud":UUID().uuidString],["sub":UUID().uuidString],["deviceId":UUID().uuidString],
            ["grantId":UUID().uuidString],["cnf":["jkt":encoded(Data(repeating:2,count:32))]],
            ["environment":"development"],["platform":"web"],["requestHash":encoded(Data(repeating:3,count:32))],
            ["exp":Int(now.timeIntervalSince1970)+61],["iat":Int(now.timeIntervalSince1970)+1],
            ["category":7],["unexpected":"field"]]
        for patch in patches {
            let receipt = try signed(key,type:"tomo-platform-receipt+jwt",claims:claims.merging(patch) { _,new in new })
            await denied { try await cloud.verifyPlatformRequest(request(body,receipt),now:now) }
        }
        let receipt = try signed(key,type:"tomo-platform-receipt+jwt",claims:claims)
        await denied { try await cloud.verifyPlatformRequest(request(body,receipt),now:now.addingTimeInterval(60)) }
        await denied { try await cloud.verifyPlatformRequest(request(body,receipt),now:now.addingTimeInterval(120)) }
    }
    func testGrantTokenTypeAndUnconfiguredJWTKeyLocationsNeverEstablishPlatformTrust() async throws {
        let (cloud,key,grant,body,claims) = try await setup()
        await denied { try await cloud.verifyPlatformRequest(request(body,grant),now:now) }
        for extra in [["jku":"https://evil.test/jwks"],["x5u":"https://evil.test/key"]] {
            let receipt = try signed(key,type:"tomo-platform-receipt+jwt",claims:claims,extra:extra)
            await denied { try await cloud.verifyPlatformRequest(request(body,receipt),now:now) }
        }
    }
    func testAndroidReceiptRequiresDistinctProductionDevicePolicyAndExactBinding() async throws {
        let (cloud,key,_,body,ios) = try await setup()
        var android = ios
        android.removeValue(forKey: "category")
        android["platform"] = "android"
        android["version"] = "42"
        android["deviceIntegrity"] = "MEETS_DEVICE_INTEGRITY"
        let receipt = try signed(key,type:"tomo-platform-receipt+jwt",claims:android)
        try await cloud.verifyPlatformRequest(request(body,receipt),now:now)
        await denied { try await cloud.verifyPlatformRequest(request(body+Data(" ".utf8),receipt),now:now) }
        let patches: [[String: Any]] = [["deviceIntegrity":"MEETS_BASIC_INTEGRITY"], ["deviceIntegrity":"MEETS_VIRTUAL_INTEGRITY"],
            ["version":"0"], ["version":"042"], ["version":"2100000001"], ["version":"42\n"],
            ["category":1], ["environment":"development"], ["platform":"ios"], ["unexpected":"field"]]
        for patch in patches {
            let value = try signed(key,type:"tomo-platform-receipt+jwt",claims:android.merging(patch) { _,new in new })
            await denied { try await cloud.verifyPlatformRequest(request(body,value),now:now) }
        }
        var missing = android; missing.removeValue(forKey: "deviceIntegrity")
        let absent = try signed(key,type:"tomo-platform-receipt+jwt",claims:missing)
        await denied { try await cloud.verifyPlatformRequest(request(body,absent),now:now) }
    }
    func testActualRubyTokenSignerFixtureInteroperatesWithSwift() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "RemotePlatformReceiptRuby", withExtension: "json"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let time = Date(timeIntervalSince1970: try XCTUnwrap(fixture["now"] as? Double))
        let server = try XCTUnwrap(fixture["serverId"] as? String)
        let issuer = try XCTUnwrap(fixture["issuer"] as? String)
        let cloud = try await RemoteCloudGrantVerifier.configured(jwks: JSONSerialization.data(withJSONObject: fixture["jwks"]!),
            issuer: issuer, serverId: server, trustedUntil: time.addingTimeInterval(120), now: time)
        let body = Data(try XCTUnwrap(fixture["body"] as? String).utf8)
        let receipt = try XCTUnwrap(fixture["receipt"] as? String), path = try XCTUnwrap(fixture["path"] as? String)
        try await cloud.verifyPlatformRequest(request(body, receipt, path: path), now: time)
        await denied { try await cloud.verifyPlatformRequest(request(body + Data(" ".utf8), receipt, path: path), now: time) }
        await denied { try await cloud.verifyPlatformRequest(request(body, receipt, path: path), now: time.addingTimeInterval(60)) }
    }

}
