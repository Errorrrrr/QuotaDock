import XCTest
@testable import QuotaDockCore

final class AntigravityDesktopTests: XCTestCase {
    private static let status = Data(#"{"userStatus":{"name":"Ada","email":"ada@example.com","userTier":{"name":"Google AI Pro","availableCredits":[{"creditType":"GOOGLE_ONE_AI"}]}}}"#.utf8)
    private static let quota = Data(#"{"response":{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-5h","window":"5h","remainingFraction":0.75}]},{"displayName":"Claude and GPT models","buckets":[{"bucketId":"3p-weekly","window":"weekly","remainingFraction":0}]}]}}"#.utf8)

    func testProfileAndProtoZeroCreditAreRecognized() throws {
        let identity = try AntigravityDesktopQuotaProvider.identity(Self.status)
        XCTAssertEqual(identity.name, "Ada")
        XCTAssertEqual(identity.plan, "Google AI Pro")
        XCTAssertEqual(identity.credits?.remainingBalance, 0)
        XCTAssertEqual(identity.credits?.id, "agy-credits")
    }

    func testMissingUnknownAndMalformedCreditsStayUnknown() throws {
        for records in ["[]", #"[{"creditType":"OTHER"}]"#, #"[{"creditType":"GOOGLE_ONE_AI","creditAmount":-1}]"#, #"[{"creditType":"GOOGLE_ONE_AI","creditAmount":true}]"#, #"[{"creditType":"GOOGLE_ONE_AI","creditAmount":"NaN"}]"#, #"[{"creditType":"GOOGLE_ONE_AI","creditAmount":1.2}]"#, #"[{"creditType":"GOOGLE_ONE_AI"},{"creditType":"GOOGLE_ONE_AI"}]"#] {
            let data = Data("{\"userStatus\":{\"email\":\"a@example.com\",\"userTier\":{\"availableCredits\":\(records)}}}".utf8)
            XCTAssertNil(try AntigravityDesktopQuotaProvider.identity(data).credits)
        }
        let data = Data(#"{"userStatus":{"email":"a@example.com","userTier":{"availableCredits":[{"creditType":"GOOGLE_ONE_AI","creditAmount":"1250"}]}}}"#.utf8)
        XCTAssertEqual(try AntigravityDesktopQuotaProvider.identity(data).credits?.remainingBalance, 1250)
    }

    func testQuotaWindowsUseStableIDsAndMissingFractionIsNotZero() throws {
        let snapshot = try AntigravityDesktopQuotaProvider.parseQuota(Self.quota)
        XCTAssertEqual(snapshot.metrics.map(\.id), ["agy-gemini-5h", "agy-3p-weekly"])
        XCTAssertEqual(snapshot.metrics.map(\.remainingPercent), [75, 0])
        let text = String(decoding: Self.quota, as: UTF8.self)
        for malformed in [text.replacingOccurrences(of: ",\"remainingFraction\":0.75", with: ""), text.replacingOccurrences(of: "0.75", with: "true"), text.replacingOccurrences(of: "0.75", with: "1.1"), text.replacingOccurrences(of: "3p-weekly", with: "gemini-5h")] {
            XCTAssertThrowsError(try AntigravityDesktopQuotaProvider.parseQuota(Data(malformed.utf8)))
        }
    }

    func testFetchCombinesOnlyOneDesktopAccount() async throws {
        let provider = AntigravityDesktopQuotaProvider(read: { method in method == .status ? Self.status : Self.quota })
        let result = try await provider.fetch(account: .init(toolID: UUID(), name: "Alias"))
        XCTAssertEqual(result.planName, "Google AI Pro")
        XCTAssertEqual(result.metrics.count, 3)
        XCTAssertNil(result.notice)
        do { _ = try await provider.fetch(account: .init(toolID: UUID(), name: "Alias", externalID: "/other")); XCTFail() }
        catch CLIQuotaError.invalidData {}
    }

    func testAccountSwitchDuringQueryDiscardsResult() async throws {
        actor Reads {
            var count = 0
            func next(_ method: AntigravityDesktopQuotaProvider.Method) -> Data {
                if method == .quota { return AntigravityDesktopTests.quota }
                count += 1
                return count == 1 ? AntigravityDesktopTests.status : Data(#"{"userStatus":{"email":"different@example.com"}}"#.utf8)
            }
        }
        let reads = Reads()
        let provider = AntigravityDesktopQuotaProvider(read: { await reads.next($0) })
        do { _ = try await provider.fetch(account: .init(toolID: UUID(), name: "Alias")); XCTFail() }
        catch AntigravityDesktopError.accountChanged {}
    }

    func testCancellationPropagates() async throws {
        let provider = AntigravityDesktopQuotaProvider(read: { _ in throw CancellationError() })
        do { _ = try await provider.fetch(account: .init(toolID: UUID(), name: "Alias")); XCTFail() }
        catch is CancellationError {}
    }

    func testDiscoveryRestrictsProcessAndPorts() throws {
        let path = "/Applications/Antigravity.app/Contents/Resources/bin/language_server"
        XCTAssertTrue(AntigravityDesktopQuotaProvider.allowedExecutable(path))
        XCTAssertFalse(AntigravityDesktopQuotaProvider.allowedExecutable("/tmp/Antigravity.app/Contents/Resources/bin/language_server"))
        XCTAssertEqual(try AntigravityDesktopQuotaProvider.sessionToken(command: path + " --standalone --csrf_token fixture", executable: path), "fixture")
        for command in [path + " --csrf_token fixture", path + " --standalone --csrf_token one --csrf_token two", "/tmp/fake --standalone --csrf_token fixture"] {
            XCTAssertThrowsError(try AntigravityDesktopQuotaProvider.sessionToken(command: command, executable: path))
        }
        XCTAssertEqual(AntigravityDesktopQuotaProvider.ports("p123\nn127.0.0.1:1234\nn127.0.0.1:1234\nn*:2345\nn192.168.1.2:3456\nn127.0.0.1:65536"), [1234])
    }

    func testDesktopIsSelectableWithoutRemovingCLI() throws {
        let tool = ToolDefinition(name: "Antigravity", provider: .antigravityDesktop)
        XCTAssertEqual(tool.availableProviders.first, .antigravityDesktop)
        XCTAssertTrue(tool.availableProviders.contains(.antigravityCLI))
        XCTAssertTrue(tool.provider.supportsDefaultLogin)
        XCTAssertEqual(try JSONDecoder().decode(ToolDefinition.self, from: JSONEncoder().encode(tool)), tool)
    }

    func testLiveDesktopReadOnly() async throws {
        guard ProcessInfo.processInfo.environment["QUOTADOCK_LIVE_ANTIGRAVITY_DESKTOP"] == "1" else { throw XCTSkip("Opt-in local desktop query") }
        let snapshot = try await AntigravityDesktopQuotaProvider().fetch(account: .init(toolID: UUID(), name: "Live"))
        // Do not print account identity, session material or raw response bodies.
        XCTAssertNotNil(snapshot.accountName)
        XCTAssertNotNil(snapshot.planName)
        XCTAssertNotNil(snapshot.metrics.first(where: { $0.id == "agy-credits" })?.remainingBalance)
        XCTAssertFalse(snapshot.metrics.filter { $0.category == .subscription }.isEmpty)
        XCTAssertNil(snapshot.notice)
    }
}
