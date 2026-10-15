import XCTest
@testable import QuotaDockCore

final class AntigravityProfileTests: XCTestCase {
    private static func record(subject: String = "user-1", method: String = "consumer", expiry: String = "2099-01-01T00:00:00Z") -> Data {
        let claims = Data("{\"iss\":\"https://accounts.google.com\",\"sub\":\"\(subject)\"}".utf8).base64EncodedString()
        return Data("{\"auth_method\":\"\(method)\",\"token\":{\"access_token\":\"test-token\",\"expiry\":\"\(expiry)\"},\"id_token\":\"header.\(claims).signature\"}".utf8)
    }
    func testKeyringFormatsAndInvalidLogin() throws {
        let raw = Self.record()
        let base64 = Data(("go-keyring-base64:" + raw.base64EncodedString()).utf8)
        let hex = Data(("go-keyring-encoded:" + raw.map { String(format: "%02x", $0) }.joined()).utf8)
        for data in [raw, base64, hex] {
            XCTAssertEqual(try AntigravityAccountProfileProvider.decode(data).subject, "user-1")
        }
        for data in [Self.record(method: "other"), Self.record(expiry: "2000-01-01T00:00:00Z"), Data("go-keyring-encoded:x".utf8)] {
            XCTAssertThrowsError(try AntigravityAccountProfileProvider.decode(data))
        }
    }
    func testAuthenticatedProfileAndPaidTierPrecedence() async throws {
        let provider = AntigravityAccountProfileProvider(load: { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            if request.httpMethod == "GET" {
                XCTAssertEqual(request.url?.absoluteString, "https://www.googleapis.com/oauth2/v2/userinfo")
                return Data(#"{"id":"user-1","name":"Ada","email":"ada@example.com"}"#.utf8)
            }
            XCTAssertEqual(request.url?.absoluteString, "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
            XCTAssertEqual(body?["mode"] as? String, "HEALTH_CHECK")
            return Data(#"{"currentTier":{"name":"Free"},"paidTier":{"name":"Google AI Pro"}}"#.utf8)
        }, read: { Self.record() })
        let profile = try await provider.fetch(provider.credential())
        XCTAssertEqual(profile.name, "Ada")
        XCTAssertEqual(profile.email, "ada@example.com")
        XCTAssertEqual(profile.plan, "Google AI Pro")
        XCTAssertNil(try AntigravityAccountProfileProvider.plan(Data(#"{"currentTier":{"name":"Free"},"paidTier":{}}"#.utf8)))
    }
    func testCodeAssistServiceTierIsNotAnAntigravitySubscription() throws {
        for json in [#"{"currentTier":{"id":"free-tier","name":"Gemini Code Assist for individuals"}}"#, #"{"currentTier":{"id":"standard-tier","name":"Standard"}}"#, #"{"currentTier":{"name":"Free"}}"#] {
            XCTAssertNil(try AntigravityAccountProfileProvider.plan(Data(json.utf8)))
        }
        XCTAssertEqual(try AntigravityAccountProfileProvider.plan(Data(#"{"paidTier":{"name":"Gemini Code Assist in Google One AI Pro"}}"#.utf8)), "Google AI Pro")
    }
    func testWrongSubjectRejectedAndPlanFailureKeepsIdentity() async throws {
        let mismatch = AntigravityAccountProfileProvider(load: { _ in Data(#"{"id":"other","name":"Wrong"}"#.utf8) }, read: { Self.record() })
        do { _ = try await mismatch.fetch(mismatch.credential()); XCTFail("Must reject another account") } catch {}
        let optional = AntigravityAccountProfileProvider(load: { request in
            guard request.httpMethod == "GET" else { throw CLIQuotaError.upstream }
            return Data(#"{"id":"user-1","name":"Ada"}"#.utf8)
        }, read: { Self.record() })
        let profile = try await optional.fetch(optional.credential())
        XCTAssertEqual(profile.name, "Ada")
        XCTAssertNil(profile.plan)
    }
    private static let usage = Data(#"{"status":"SUCCESS","num_turns":0,"command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"5h","window":"5h","remaining_fraction":0.8}]}]}}}"#.utf8)
    private static let credits = Data(#"{"status":"SUCCESS","num_turns":0,"command":{"name":"credits","data":{"remaining_credits":10}}}"#.utf8)
    func testProfileFailureKeepsQuota() async throws {
        let profile = AntigravityAccountProfileProvider(load: { _ in throw CLIQuotaError.upstream }, read: { Self.record() })
        let provider = AntigravityCLIQuotaProvider(command: { $0 == "usage" ? Self.usage : Self.credits }, profile: profile)
        let result = try await provider.fetch(account: .init(toolID: UUID(), name: "Alias"))
        XCTAssertEqual(result.metrics.count, 2)
        XCTAssertNil(result.accountName)
        XCTAssertNotNil(result.notice)
    }
    func testAccountChangeRejectsMixedResult() async throws {
        let records = Records()
        let profile = AntigravityAccountProfileProvider(load: { _ in XCTFail("Must reject changed login before fetching identity"); return Data() }, read: { records.next() })
        let provider = AntigravityCLIQuotaProvider(command: { $0 == "usage" ? Self.usage : Self.credits }, profile: profile)
        do { _ = try await provider.fetch(account: .init(toolID: UUID(), name: "Alias")); XCTFail("Must reject mixed accounts") }
        catch { XCTAssertTrue(error.localizedDescription.contains("登录账号发生变化")) }
    }
    private final class Records: @unchecked Sendable {
        let lock = NSLock()
        var count = 0
        func next() -> Data {
            lock.lock(); defer { lock.unlock() }
            count += 1
            return AntigravityProfileTests.record(subject: count == 1 ? "before" : "after")
        }
    }
}
