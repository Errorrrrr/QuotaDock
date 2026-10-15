import XCTest
@testable import QuotaDockCore

final class ActiveQuotaProviderTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private let usage = #"{"status":"SUCCESS","num_turns":0,"conversation_id":"","usage":{"total_tokens":0},"command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"gemini-5h","window":"5h","remaining_fraction":0.75,"reset_time":"2099-01-01T00:00:00Z"}]},{"name":"Claude and GPT models","buckets":[{"id":"3p-weekly","window":"weekly","remaining_fraction":0}]}]}}}"#

    func testClaudeWindowsAndExtraSpendingCapAreSeparate() throws {
        let result = try ClaudeOAuthQuotaProvider.parse(data(#"{"five_hour":{"utilization":12,"resets_at":"2099-01-01T00:00:00Z"},"seven_day":{"utilization":75},"seven_day_sonnet":null,"extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1250}}"#))
        XCTAssertEqual(result.metrics.map(\.remainingPercent), [88, 25, 75])
        XCTAssertEqual(result.metrics.last?.total, 50)
        XCTAssertEqual(result.metrics.last?.used, 12.5)
        XCTAssertEqual(result.metrics.last?.unit, "USD")
        XCTAssertEqual(result.metrics.last?.category, .custom)
        XCTAssertNil(result.metrics.last?.remainingBalance)
        for value in ["true", "-1", "101", "null"] {
            XCTAssertThrowsError(try ClaudeOAuthQuotaProvider.parse(data("{\"five_hour\":{\"utilization\":\(value)}}")))
        }
        XCTAssertThrowsError(try ClaudeOAuthQuotaProvider.parse(data("{}")))
    }

    func testClaudeCredentialsRejectExpiryMissingScopeAndTokenInjection() throws {
        XCTAssertEqual(try ClaudeOAuthQuotaProvider.credential(data(#"{"claudeAiOauth":{"accessToken":"test","subscriptionType":"max","scopes":["user:profile"]}}"#)).plan, "Max")
        for json in [#"{"claudeAiOauth":{"accessToken":"test","expiresAt":1}}"#, #"{"claudeAiOauth":{"accessToken":"test","scopes":["user:inference"]}}"#, #"{"claudeAiOauth":{"accessToken":"test\nInjected"}}"#] {
            XCTAssertThrowsError(try ClaudeOAuthQuotaProvider.credential(data(json)))
        }
    }

    func testClaudeSelectedDirectoryNeverReadsDefaultKeychainAndProfileIsOptional() async throws {
        let dir = try directory()
        let auth = data(#"{"claudeAiOauth":{"accessToken":"selected-token","subscriptionType":"pro"}}"#)
        try auth.write(to: dir.appendingPathComponent(".credentials.json"))
        let expected = try ClaudeOAuthQuotaProvider.source(dir.path, environment: [:])
        XCTAssertNotEqual(expected.service, "Claude Code-credentials")
        XCTAssertEqual(try ClaudeOAuthQuotaProvider.source("", environment: ["CLAUDE_CONFIG_DIR":dir.path]).service, expected.service)
        let provider = ClaudeOAuthQuotaProvider(load: { request in
            XCTAssertEqual(request.url?.host, "api.anthropic.com")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer selected-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
            if request.url?.path.hasSuffix("profile") == true { throw CLIQuotaError.upstream }
            return Data(#"{"five_hour":{"utilization":20}}"#.utf8)
        }, readKeychain: { service in
            XCTAssertEqual(service, expected.service)
            return nil
        })
        let result = try await provider.fetch(account: .init(toolID: UUID(), name: "Alias", externalID: dir.path))
        XCTAssertEqual(result.metrics.first?.remainingPercent, 80)
        XCTAssertEqual(result.planName, "Pro")
        XCTAssertNil(result.accountName)
        XCTAssertNotNil(result.notice)
        let denied = ClaudeOAuthQuotaProvider(load: { _ in XCTFail("Must not request after denied credentials"); return Data() }, readKeychain: { _ in throw ClaudeOAuthError.keychainAccess })
        do { _ = try await denied.fetch(account: .init(toolID: UUID(), name: "Alias", externalID: dir.path)); XCTFail() }
        catch ClaudeOAuthError.keychainAccess {} // Don't silently use potentially stale file login.
    }

    func testClaudeProfileKeepsNameEmailAndPlanDistinct() async throws {
        let dir = try directory()
        let provider = ClaudeOAuthQuotaProvider(load: { request in
            if request.url?.path.hasSuffix("profile") == true {
                return Data(#"{"account":{"display_name":"Ada","email":"ada@example.com"},"organization":{"organization_type":"claude_team"}}"#.utf8)
            }
            return Data(#"{"seven_day":{"utilization":100}}"#.utf8)
        }, readKeychain: { _ in Data(#"{"claudeAiOauth":{"accessToken":"test"}}"#.utf8) })
        let result = try await provider.fetch(account: .init(toolID: UUID(), name: "Alias", externalID: dir.path))
        XCTAssertEqual(result.accountName, "Ada")
        XCTAssertEqual(result.accountEmail, "ada@example.com")
        XCTAssertEqual(result.planName, "Team")
    }

    func testClaudeRateLimitBacksOffWithoutRepeatedRequests() async throws {
        let dir = try directory()
        let account = Account(toolID: UUID(), name: "Alias", externalID: dir.path)
        let provider = ClaudeOAuthQuotaProvider(load: { _ in throw QuotaProviderError.httpStatus(429) }, readKeychain: { _ in Data(#"{"claudeAiOauth":{"accessToken":"test"}}"#.utf8) })
        do { _ = try await provider.fetch(account: account); XCTFail() } catch ClaudeOAuthError.throttled {}
        let blocked = ClaudeOAuthQuotaProvider(load: { _ in XCTFail("Repeated HTTP call during cooldown"); return Data() })
        do { _ = try await blocked.fetch(account: account); XCTFail() } catch ClaudeOAuthError.throttled {}
    }

    func testAntigravityParsesOnlyReadOnlyStructuredResults() throws {
        let result = try AntigravityCLIQuotaProvider.parseUsage(data(usage))
        XCTAssertEqual(result.metrics.map(\.remainingPercent), [75, 0])
        XCTAssertEqual(result.metrics.map(\.label), ["Gemini · 5 小时", "Claude/GPT · 每周"])
        XCTAssertThrowsError(try AntigravityCLIQuotaProvider.parseUsage(data(usage.replacingOccurrences(of: "\"num_turns\":0", with: "\"num_turns\":1"))))
        XCTAssertThrowsError(try AntigravityCLIQuotaProvider.parseUsage(data(usage.replacingOccurrences(of: "\"total_tokens\":0", with: "\"total_tokens\":1"))))
        XCTAssertThrowsError(try AntigravityCLIQuotaProvider.parseUsage(data(usage.replacingOccurrences(of: "\"remaining_fraction\":0.75", with: "\"remaining_fraction\":true"))))
        let credits = try AntigravityCLIQuotaProvider.parseCredits(data(#"{"status":"SUCCESS","num_turns":0,"command":{"name":"credits","data":{"remaining_credits":123}}}"#))
        XCTAssertEqual(credits.remainingBalance, 123)
        XCTAssertEqual(credits.category, .balance)
        XCTAssertNil(result.accountName)
    }

    func testAntigravityCreditsFailureDoesNotDiscardQuota() async throws {
        let fixture = data(usage)
        let provider = AntigravityCLIQuotaProvider { command in
            guard command == "usage" else { throw CLIProcessError.failed }
            return fixture
        }
        let result = try await provider.fetch(account: .init(toolID: UUID(), name: "Alias"))
        XCTAssertEqual(result.metrics.count, 2)
        XCTAssertNotNil(result.notice)
    }

    func testUnknownAntigravityBuildIsRejectedBeforePrintCommand() throws {
        let file = try directory().appendingPathComponent("agy")
        try data("#!/bin/sh\nexit 0\n").write(to: file)
        XCTAssertThrowsError(try AntigravityCLIQuotaProvider.requireReadOnlyCommands(file))
    }

    func testFallbackPreservesTimestampAndNeverSwallowsCancellation() async throws {
        let path = try directory().appendingPathComponent("snapshot.json")
        try data(#"{"rate_limits":{"five_hour":{"used_percentage":42}}}"#).write(to: path)
        let timestamp = Date().addingTimeInterval(-600)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: path.path)
        let account = Account(toolID: UUID(), name: "Alias", fallbackSnapshotPath: path.path)
        let snapshot = try await ActiveQuotaProvider.withFallback(provider: .claudeOAuth, account: account) { throw CLIQuotaError.upstream }
        XCTAssertEqual(snapshot.metrics.first?.used, 42)
        XCTAssertEqual(snapshot.fetchedAt.timeIntervalSince1970, timestamp.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertTrue(snapshot.notice?.contains("备用快照") == true)
        do { _ = try await ActiveQuotaProvider.withFallback(provider: .claudeOAuth, account: account) { throw CancellationError() }; XCTFail() }
        catch is CancellationError {}
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-90000)], ofItemAtPath: path.path)
        do { _ = try await ActiveQuotaProvider.withFallback(provider: .claudeOAuth, account: account) { throw ClaudeOAuthError.expired }; XCTFail() }
        catch ClaudeOAuthError.expired {}
    }

    func testClaudeSnapshotRejectsFutureAndElapsedWindow() throws {
        XCTAssertThrowsError(try ClaudeSnapshotProvider.parse(data: data(#"{"rate_limits":{"five_hour":{"used_percentage":0}}}"#), modifiedAt: Date().addingTimeInterval(300)))
        XCTAssertThrowsError(try ClaudeSnapshotProvider.parse(data: data(#"{"rate_limits":{"five_hour":{"used_percentage":0,"resets_at":1}}}"#), modifiedAt: Date()))
    }

    func testLiveAntigravityReadOnly() async throws {
        guard ProcessInfo.processInfo.environment["QUOTADOCK_LIVE_ANTIGRAVITY"] == "1" else { throw XCTSkip("Opt-in live account verification") }
        let result = try await AntigravityCLIQuotaProvider().fetch(account: .init(toolID: UUID(), name: "Live check"))
        XCTAssertFalse(result.metrics.isEmpty)
        XCTAssertTrue(result.metrics.contains { $0.id == "agy-credits" })
        XCTAssertFalse(result.accountName?.isEmpty ?? true)
        XCTAssertFalse(result.accountEmail?.isEmpty ?? true)
        if let plan = result.planName { XCTAssertTrue(["Google AI Pro", "Google AI Ultra"].contains(plan)) }
        else { XCTAssertTrue(result.notice?.contains("订阅套餐") == true) }
        print("Antigravity live check: quota, credits, nickname and email returned; subscription is explicit or marked unavailable; no private values logged.")
    }

    func testLiveClaudeOAuthReadOnly() async throws {
        guard ProcessInfo.processInfo.environment["QUOTADOCK_LIVE_CLAUDE"] == "1" else { throw XCTSkip("Opt-in live account verification") }
        let result = try await ClaudeOAuthQuotaProvider().fetch(account: .init(toolID: UUID(), name: "Live check"))
        XCTAssertFalse(result.metrics.isEmpty)
        print("Claude live check: quota returned; no credentials or identity logged.")
    }
}
