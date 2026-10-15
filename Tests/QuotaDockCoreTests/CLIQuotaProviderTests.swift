import XCTest
@testable import QuotaDockCore

final class CLIQuotaProviderTests: XCTestCase {
    private func json(_ value: String) -> Data { Data(value.utf8) }

    func testAntigravityUsesRemainingFractionAndProfile() throws {
        let data = json(#"{"product":"antigravity","quota":{"gemini-weekly":{"remaining_fraction":0.75,"reset_time":"2099-01-01T00:00:00Z"},"model-a":{"remaining_fraction":0}},"email":"test@example.com","plan_tier":"Pro","context_window":{"remaining_percentage":99}}"#)
        let now = Date()
        let result = try AntigravitySnapshotProvider.parse(data: data, modifiedAt: now)
        XCTAssertEqual(result.metrics.count, 2)
        XCTAssertEqual(result.metrics[0].used, 25)
        XCTAssertEqual(result.metrics[1].remaining, 0)
        XCTAssertEqual(result.planName, "Pro")
        XCTAssertEqual(result.accountEmail, "test@example.com")
        XCTAssertNil(result.accountName) // Never substitute an email for a nickname.
        XCTAssertEqual(result.fetchedAt, now)
    }

    func testAntigravityRejectsInvalidStaleAndExpiredData() throws {
        for value in ["true", "-0.1", "1.1", "\"0.5\""] {
            let data = json("{\"product\":\"antigravity\",\"quota\":{\"a\":{\"remaining_fraction\":\(value)}}}")
            XCTAssertThrowsError(try AntigravitySnapshotProvider.parse(data: data, modifiedAt: Date()))
        }
        let valid = json(#"{"product":"antigravity","quota":{"a":{"remaining_fraction":0.5}}}"#)
        XCTAssertThrowsError(try AntigravitySnapshotProvider.parse(data: valid, modifiedAt: Date().addingTimeInterval(-86_401)))
        XCTAssertThrowsError(try AntigravitySnapshotProvider.parse(data: json(#"{"product":"antigravity","quota":{"a":{"remaining_fraction":0.5,"reset_time":"2020-01-01T00:00:00Z"}}}"#), modifiedAt: Date()))
        XCTAssertThrowsError(try AntigravitySnapshotProvider.parse(data: json(#"{"product":"gemini","quota":{"a":{"remaining_fraction":0.5}}}"#), modifiedAt: Date()))
        XCTAssertThrowsError(try AntigravitySnapshotProvider.parse(data: json(#"{"product":"antigravity","quota":{}}"#), modifiedAt: Date()))
    }

    func testKimiWindowsAndPurchasedWalletAreSeparate() throws {
        let data = json(#"{"code":0,"data":{"kind":"ok","quota":{"usages":{"limit5h":{"usedRatio":0.2},"limit7d":{"usedRatio":1,"resetAt":"2099-01-01T00:00:00.123Z"}},"extraUsage":{"balanceCents":1234,"currency":"CNY","totalCents":5000}}}}"#)
        let snapshot = try KimiCLIQuotaProvider.parseUsage(data: data)
        XCTAssertEqual(snapshot.metrics.count, 3)
        XCTAssertEqual(snapshot.metrics[0].remainingPercent, 80)
        XCTAssertEqual(snapshot.metrics[1].remainingPercent, 0)
        XCTAssertEqual(snapshot.metrics[2].remainingBalance, 12.34)
        XCTAssertEqual(snapshot.metrics[2].category, .purchased)
        XCTAssertEqual(snapshot.metrics[2].unit, "CNY")
    }

    func testKimiErrorsDoNotBecomeZeroUsage() {
        for payload in [
            #"{"code":40101,"data":{"kind":"ok"}}"#,
            #"{"code":0,"data":{"kind":"error","message":"secret"}}"#,
            #"{"code":0,"data":{"kind":"ok","quota":{"usages":{}}}}"#,
            #"{"code":0,"data":{"kind":"ok","quota":{"usages":{"limit5h":{"usedRatio":true}}}}}"#,
            #"{"code":0,"data":{"kind":"ok","quota":{"usages":{},"extraUsage":{"balanceCents":-1,"currency":"CNY"}}}}"#
        ] { XCTAssertThrowsError(try KimiCLIQuotaProvider.parseUsage(data: json(payload))) }
    }

    func testKimiOnlyAcceptsExplicitLoopbackOrigins() throws {
        XCTAssertEqual(try KimiCLIQuotaProvider.origin("http://127.0.0.1:58627").port, 58627)
        XCTAssertEqual(try KimiCLIQuotaProvider.origin("http://[::1]:58628").port, 58628)
        for url in ["http://127.0.0.1", "http://localhost:1234", "http://127.0.0.1.evil.com:1", "https://example.com", "http://127.0.0.1:1/#token=secret", "http://user:secret@127.0.0.1:1", "http://127.0.0.1:1/api", "http://127.0.0.1:1?token=secret"] {
            XCTAssertThrowsError(try KimiCLIQuotaProvider.origin(url), url)
        }
    }

    func testKimiFetchReadsIdentityAndRetainsQuotaOnProfileError() async throws {
        let provider = KimiCLIQuotaProvider { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer local-test")
            XCTAssertEqual(request.url?.host, "127.0.0.1")
            if request.url?.path.hasSuffix("userinfo") == true {
                return Data(#"{"code":0,"data":{"kind":"ok","userInfo":{"nickname":"Test","email":"test@example.com","userLevelName":"Plan"}}}"#.utf8)
            }
            XCTAssertEqual(request.url?.path, "/api/v1/oauth/usage")
            return Data(#"{"code":0,"data":{"kind":"ok","quota":{"usages":{"limit5h":{"usedRatio":0.5}}}}}"#.utf8)
        }
        let account = Account(toolID: UUID(), name: "Alias", externalID: "http://127.0.0.1:58627")
        let snapshot = try await provider.fetch(account: account, token: "local-test")
        XCTAssertEqual(snapshot.accountName, "Test")
        XCTAssertEqual(snapshot.planName, "Plan")
        let fallback = KimiCLIQuotaProvider { request in
            if request.url?.path.hasSuffix("userinfo") == true { throw CLIQuotaError.upstream }
            return Data(#"{"code":0,"data":{"kind":"ok","quota":{"usages":{"limit5h":{"usedRatio":0.5}}}}}"#.utf8)
        }
        let result = try await fallback.fetch(account: account, token: "local-test")
        XCTAssertEqual(result.metrics.count, 1)
        XCTAssertNil(result.accountName)
    }

    func testGLMHostAllowlistAndAuthenticationMatchOfficialPlugin() throws {
        for host in ["api.z.ai", "open.bigmodel.cn", "dev.bigmodel.cn"] {
            let data = json("{\"env\":{\"ANTHROPIC_BASE_URL\":\"https://\(host)/api/anthropic\",\"ANTHROPIC_AUTH_TOKEN\":\"test-token\"}}")
            let request = try GLMCLIQuotaProvider.makeRequest(settings: data)
            XCTAssertEqual(request.url?.absoluteString, "https://\(host)/api/monitor/usage/quota/limit")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "test-token")
        }
        for base in ["https://api.z.ai.evil.com/api/anthropic", "http://api.z.ai/api/anthropic", "https://api.z.ai:444/api/anthropic", "https://user@api.z.ai/api/anthropic", "https://proxy.example.com/api/anthropic"] {
            let data = json("{\"env\":{\"ANTHROPIC_BASE_URL\":\"\(base)\",\"ANTHROPIC_AUTH_TOKEN\":\"test-token\"}}")
            XCTAssertThrowsError(try GLMCLIQuotaProvider.makeRequest(settings: data))
        }
    }

    func testGLMOnlyParsesKnownQuotaTypes() throws {
        let snapshot = try GLMCLIQuotaProvider.parse(data: json(#"{"code":200,"success":true,"data":{"limits":[{"type":"TOKENS_LIMIT","percentage":35},{"type":"TIME_LIMIT","percentage":20},{"type":"NEW_LIMIT","percentage":99}]}}"#))
        XCTAssertEqual(snapshot.metrics.count, 2)
        XCTAssertEqual(snapshot.metrics[0].remainingPercent, 65)
        XCTAssertEqual(snapshot.metrics[1].label, "每月 MCP 额度")
        for data in [#"{"success":false,"data":{"limits":[]}}"#, #"{"data":{"limits":[{"type":"TOKENS_LIMIT","percentage":true}]}}"#, #"{"data":{"limits":[]}}"#] {
            XCTAssertThrowsError(try GLMCLIQuotaProvider.parse(data: json(data)))
        }
    }

    func testProviderMenusStayScopedToTheirBrands() {
        XCTAssertEqual(ToolDefinition(name: "Antigravity").availableProviders.first, .antigravityCLI)
        XCTAssertEqual(ToolDefinition(name: "Kimi").availableProviders.first, .kimiCLI)
        XCTAssertEqual(ToolDefinition(name: "智谱 GLM").availableProviders.first, .glmCLI)
        XCTAssertFalse(ToolDefinition(name: "Claude").availableProviders.contains(.glmCLI))
        XCTAssertFalse(ToolDefinition(name: "Gemini").availableProviders.contains(.antigravitySnapshot))
    }
}
