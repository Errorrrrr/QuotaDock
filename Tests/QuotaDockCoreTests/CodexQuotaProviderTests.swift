import XCTest
@testable import QuotaDockCore

final class CodexQuotaProviderTests: XCTestCase {
    func testMultiBucketViewOverridesLegacyAndPreservesReset() throws {
        let result = try CodexQuotaProvider.decodeRateLimits(Data(#"{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":23,"windowDurationMins":300,"resetsAt":1792058400},"secondary":{"usedPercent":41,"windowDurationMins":10080}},"review":{"limitName":"审查","primary":{"usedPercent":2,"windowDurationMins":60}}}}"#.utf8))
        XCTAssertEqual(result.metrics.map(\.used), [23, 41, 2])
        XCTAssertEqual(result.metrics.map(\.remainingPercent), [77, 59, 98])
        XCTAssertEqual(result.metrics[0].resetsAt, Date(timeIntervalSince1970: 1792058400))
        XCTAssertEqual(result.metrics.map(\.label), ["codex · 5 小时额度", "codex · 每周额度", "审查 · 1 小时额度"])
    }

    func testMissingQuotaIsNotReportedAsZero() {
        for json in [#"{}"#, #"{"rateLimits":null}"#, #"{"rateLimits":{"primary":null,"secondary":null}}"#] {
            XCTAssertThrowsError(try CodexQuotaProvider.decodeRateLimits(Data(json.utf8))) {
                XCTAssertEqual($0 as? CodexQuotaError, .noQuota)
            }
        }
    }

    func testNegativeUsageIsRejectedAndOveragePreserved() throws {
        XCTAssertThrowsError(try CodexQuotaProvider.decodeRateLimits(Data(#"{"rateLimits":{"primary":{"usedPercent":-1}}}"#.utf8)))
        let result = try CodexQuotaProvider.decodeRateLimits(Data(#"{"rateLimits":{"primary":{"usedPercent":110}}}"#.utf8))
        XCTAssertEqual(result.metrics[0].used, 110)
        XCTAssertEqual(result.metrics[0].remaining, 0)
    }

    func testResetDatesRejectNonpositiveMillisecondsAndExtremeValues() throws {
        for reset in ["0", "-1", "1792058400000", "4102444801", "1e300"] {
            let json = "{\"rateLimits\":{\"primary\":{\"usedPercent\":10,\"resetsAt\":\(reset)}}}"
            XCTAssertThrowsError(try CodexQuotaProvider.decodeRateLimits(Data(json.utf8))) {
                XCTAssertEqual($0 as? CodexQuotaError, .invalidResponse)
            }
        }
        let result = try CodexQuotaProvider.decodeRateLimits(Data(#"{"rateLimits":{"primary":{"usedPercent":10,"resetsAt":4102444800}}}"#.utf8))
        XCTAssertEqual(result.metrics[0].resetsAt, Date(timeIntervalSince1970: 4_102_444_800))
    }

    func testSubscriptionWindowsAndPurchasedCreditsRemainSeparate() throws {
        let result = try CodexQuotaProvider.decodeRateLimits(Data(#"{"rateLimits":{"primary":{"usedPercent":23,"windowDurationMins":300},"secondary":{"usedPercent":41,"windowDurationMins":10080},"credits":{"hasCredits":true,"unlimited":false,"balance":"125.75"}}}"#.utf8))
        XCTAssertEqual(result.metrics.count, 3)
        XCTAssertEqual(result.metrics.map(\.category), [.subscription, .subscription, .purchased])
        XCTAssertEqual(result.metrics[0].remainingPercent, 77)
        XCTAssertEqual(result.metrics[1].label, "每周额度")
        XCTAssertEqual(result.metrics[2].remainingBalance, 125.75)
        XCTAssertTrue(result.metrics[2].isBalance)
        XCTAssertEqual(result.metrics[2].unit, "点数")
        XCTAssertEqual(result.metrics[2].total, 0)
        XCTAssertEqual(result.metrics[2].id, "codex.credits")
    }

    func testCreditsOnlyAndExplicitZeroAreValid() throws {
        for (hasCredits, amount) in [(true, "8.5"), (false, "0")] {
            let json = "{\"rateLimits\":{\"credits\":{\"hasCredits\":\(hasCredits),\"unlimited\":false,\"balance\":\"\(amount)\"}}}"
            let result = try CodexQuotaProvider.decodeRateLimits(Data(json.utf8))
            XCTAssertEqual(result.metrics.count, 1)
            XCTAssertEqual(result.metrics[0].remainingBalance, Double(amount))
            XCTAssertEqual(result.metrics[0].category, .purchased)
        }
    }

    func testUnknownCreditBalanceDoesNotBecomeZero() throws {
        for balance in ["", ",\"balance\":null"] {
            let credits = "\"credits\":{\"hasCredits\":true,\"unlimited\":false\(balance)}"
            let onlyCredits = "{\"rateLimits\":{\(credits)}}"
            XCTAssertThrowsError(try CodexQuotaProvider.decodeRateLimits(Data(onlyCredits.utf8))) {
                XCTAssertEqual($0 as? CodexQuotaError, .noQuota)
            }
            let withWindow = "{\"rateLimits\":{\"primary\":{\"usedPercent\":10},\(credits)}}"
            let result = try CodexQuotaProvider.decodeRateLimits(Data(withWindow.utf8))
            XCTAssertEqual(result.metrics.count, 1)
            XCTAssertFalse(result.metrics[0].isBalance)
        }
    }

    func testUnlimitedCreditsAreNotReportedAsNumericZero() throws {
        let result = try CodexQuotaProvider.decodeRateLimits(Data(#"{"rateLimits":{"credits":{"hasCredits":true,"unlimited":true,"balance":null}}}"#.utf8))
        let credit = try XCTUnwrap(result.metrics.first)
        XCTAssertEqual(result.metrics.count, 1)
        XCTAssertTrue(credit.isUnlimited)
        XCTAssertTrue(credit.isBalance)
        XCTAssertNil(credit.remainingBalance)
        XCTAssertEqual(credit.category, .purchased)
        XCTAssertEqual(credit.unit, "点数")
    }

    func testInvalidCreditBalancesAreRejected() {
        for balance in [#""-1""#, #""NaN""#, #""Infinity""#, #""1e999""#, #""""#, #""unknown""#, "8.5", "true"] {
            let json = "{\"rateLimits\":{\"credits\":{\"hasCredits\":true,\"unlimited\":false,\"balance\":\(balance)}}}"
            XCTAssertThrowsError(try CodexQuotaProvider.decodeRateLimits(Data(json.utf8))) {
                XCTAssertEqual($0 as? CodexQuotaError, .invalidResponse)
            }
        }
        XCTAssertThrowsError(try CodexQuotaProvider.decodeRateLimits(Data(#"{"rateLimits":{"credits":{"hasCredits":false,"unlimited":false,"balance":"10"}}}"#.utf8)))
    }

    func testCreditBucketsAreLabeledAndLegacyCreditIsNotDuplicated() throws {
        let result = try CodexQuotaProvider.decodeRateLimits(Data(#"{"rateLimits":{"limitId":"codex","credits":{"hasCredits":true,"unlimited":false,"balance":"50"}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":10},"credits":{"hasCredits":true,"unlimited":false,"balance":"50"}},"review":{"limitName":"审查","credits":{"hasCredits":true,"unlimited":false,"balance":"50"}}}}"#.utf8))
        let credits = result.metrics.filter(\.isBalance)
        XCTAssertEqual(credits.count, 2)
        XCTAssertEqual(credits.map(\.id), ["codex.credits", "review.credits"])
        XCTAssertEqual(credits.map(\.label), ["codex · 额外额度", "审查 · 额外额度"])
        XCTAssertEqual(credits.map(\.remainingBalance), [50, 50])
        XCTAssertEqual(result.metrics.count, 3)
    }

    func testCLIHandshakeUsesConfiguredHomeAndNeverStartsLoginOrTurn() async throws {
        let fixture = try makeCLI("""
        IFS= read -r first
        case "$first" in *'"method":"initialize"'*) ;; *) exit 12 ;; esac
        printf '%s\\n' '{"id":1,"result":{"userAgent":"fixture"}}'
        IFS= read -r second
        case "$second" in *'"method":"initialized"'*) ;; *) exit 13 ;; esac
        IFS= read -r third
        case "$third" in *'"method":"account/rateLimits/read"'*) ;; *) exit 14 ;; esac
        IFS= read -r fourth
        case "$fourth" in *'"method":"account/read"'*) ;; *) exit 16 ;; esac
        case "$fourth" in *'"refreshToken":false'*) ;; *) exit 17 ;; esac
        printf '%s\\n' '{"id":3,"result":{"account":{"type":"chatgpt","email":"person@example.com","planType":"pro"}}}'
        printf '%s' "$CODEX_HOME" > "$CODEX_HOME/observed-home"
        printf '%s\\n' 'private diagnostic must not be forwarded' >&2
        printf '%s\\n' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":17,"windowDurationMins":300}}}}'
        while IFS= read -r extra; do exit 15; done
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let result = try await CodexQuotaProvider(executableURL: fixture.executable, timeout: 2).fetch(account: fixture.account)
        XCTAssertEqual(result.metrics[0].remainingPercent, 83)
        XCTAssertEqual(result.accountEmail, "person@example.com")
        XCTAssertNil(result.accountName)
        XCTAssertEqual(result.planName, "Pro")
        XCTAssertEqual(try String(contentsOf: fixture.directory.appendingPathComponent("observed-home")), fixture.directory.path)
    }

    func testCLITimeoutIsBounded() async throws {
        let fixture = try makeCLI("while IFS= read -r line; do :; done")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let start = Date()
        do {
            _ = try await CodexQuotaProvider(executableURL: fixture.executable, timeout: 0.1).fetch(account: fixture.account)
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? CodexQuotaError, .timedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testServerErrorsNeverExposeReturnedMessage() async throws {
        let fixture = try makeCLI("""
        IFS= read -r line
        printf '%s\\n' '{"id":1,"error":{"code":403,"message":"secret-token-fixture"}}'
        while IFS= read -r line; do :; done
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        do {
            _ = try await CodexQuotaProvider(executableURL: fixture.executable, timeout: 2).fetch(account: fixture.account)
            XCTFail("Expected request failure")
        } catch {
            XCTAssertEqual(error as? CodexQuotaError, .requestFailed)
            XCTAssertFalse(error.localizedDescription.contains("secret-token-fixture"))
        }
    }

    func testQuotaSurvivesUnavailableIdentity() async throws {
        for identity in [#"{"id":3,"error":{"code":-32601,"message":"unavailable"}}"#,
                         #"{"id":3,"result":{"account":null}}"#] {
            let fixture = try makeCLI("""
            IFS= read -r line
            printf '%s\\n' '{"id":1,"result":{}}'
            IFS= read -r line
            IFS= read -r line
            IFS= read -r line
            printf '%s\\n' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":7}}}}'
            printf '%s\\n' '\(identity)'
            while IFS= read -r extra; do exit 15; done
            """)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let result = try await CodexQuotaProvider(executableURL: fixture.executable, timeout: 2).fetch(account: fixture.account)
            XCTAssertEqual(result.metrics.first?.remainingPercent, 93)
            XCTAssertNil(result.accountName)
        }
    }

    func testAccountMetadataRejectsOtherAuthModesAndMalformedNames() {
        let valid = CodexQuotaProvider.decodeAccount(Data(#"{"account":{"type":"chatgpt","email":"  member@example.com  ","planType":"plus"}}"#.utf8))
        XCTAssertEqual(valid.email, "member@example.com")
        XCTAssertEqual(valid.plan, "Plus")
        for json in [#"{}"#, #"{"account":null}"#, #"{"account":{"type":"apiKey","email":"not-an-account"}}"#,
                     #"{"account":{"type":"chatgpt","email":"bad\nname","planType":"unknown"}}"#,
                     #"{"account":{"type":"chatgpt","email":null,"planType":"unknown"}}"#] {
            let identity = CodexQuotaProvider.decodeAccount(Data(json.utf8))
            XCTAssertNil(identity.email)
            XCTAssertNil(identity.plan)
        }
    }

    func testSnapshotMetadataIsOptionalForLegacyData() throws {
        let original = QuotaSnapshot(metrics: [], accountName: "Personal", accountEmail: "person@example.com", planName: "Pro")
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(QuotaSnapshot.self, from: data), original)
        let legacy = try JSONDecoder().decode(QuotaSnapshot.self, from: Data(#"{"metrics":[],"fetchedAt":0}"#.utf8))
        XCTAssertNil(legacy.accountName)
        XCTAssertNil(legacy.accountEmail)
        XCTAssertNil(legacy.planName)
    }

    func testLocalNicknameRequiresMatchingOfficialAccountEmail() throws {
        let auth = try displayAuth(name: "小明", email: "person@example.com")
        XCTAssertEqual(CodexQuotaProvider.localDisplayName(authData: auth, expectedEmail: "PERSON@example.com"), "小明")
        XCTAssertNil(CodexQuotaProvider.localDisplayName(authData: auth, expectedEmail: "other@example.com"))
        let malformed = try displayAuth(name: "bad\nname", email: "person@example.com")
        XCTAssertNil(CodexQuotaProvider.localDisplayName(authData: malformed, expectedEmail: "person@example.com"))
        for data in [Data("{}".utf8), Data("invalid".utf8), Data(repeating: 32, count: 1_048_577)] {
            XCTAssertNil(CodexQuotaProvider.localDisplayName(authData: data, expectedEmail: "person@example.com"))
        }
    }

    func testFetchReadsOnlyNicknameFromMatchingAccountHome() async throws {
        let fixture = try makeCLI("""
        IFS= read -r line
        printf '%s\\n' '{"id":1,"result":{}}'
        IFS= read -r line
        IFS= read -r line
        IFS= read -r line
        printf '%s\\n' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":7}}}}'
        printf '%s\\n' '{"id":3,"result":{"account":{"type":"chatgpt","email":"person@example.com","planType":"plus"}}}'
        while IFS= read -r extra; do exit 15; done
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try displayAuth(name: "小明", email: "person@example.com").write(to: fixture.directory.appendingPathComponent("auth.json"))
        let result = try await CodexQuotaProvider(executableURL: fixture.executable, timeout: 2).fetch(account: fixture.account)
        XCTAssertEqual(result.accountName, "小明")
        XCTAssertEqual(result.accountEmail, "person@example.com")
        XCTAssertEqual(result.planName, "Plus")
        XCTAssertFalse(String(data: try JSONEncoder().encode(result), encoding: .utf8)!.contains("fake-signature"))
    }

    private func displayAuth(name: String, email: String) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: ["name": name, "email": email])
            .base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try JSONSerialization.data(withJSONObject: ["tokens": ["id_token": "header.\(payload).fake-signature"]])
    }

    private func makeCLI(_ body: String) throws -> (directory: URL, executable: URL, account: Account) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuotaDock-CodexTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("codex-fixture")
        try ("#!/bin/sh\n" + body + "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (directory, executable, Account(toolID: UUID(), name: "Fixture", externalID: directory.path))
    }
}
