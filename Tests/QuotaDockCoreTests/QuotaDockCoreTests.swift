import XCTest
@testable import QuotaDockCore

final class QuotaDockCoreTests: XCTestCase {
    private func parse(_ json: String, mappings: [QuotaMapping] = [.init()]) throws -> QuotaSnapshot {
        try HTTPQuotaProvider.parse(data: Data(json.utf8), mappings: mappings, fetchedAt: Date(timeIntervalSince1970: 100))
    }

    func testQuotaPercentAndClamping() {
        XCTAssertEqual(QuotaMetric(label: "5 小时", used: 25, total: 100).remainingPercent, 75)
        XCTAssertEqual(QuotaMetric(label: "超额", used: 150, total: 100).remaining, 0)
        XCTAssertEqual(QuotaMetric(label: "无额度", used: 0, total: 0).remainingPercent, 0)
        XCTAssertFalse(QuotaMetric(label: "非法", used: -.infinity, total: 100).isValid)
        XCTAssertEqual(QuotaMetric(label: "非法", used: 0, total: .nan).remainingFraction, 0)
    }

    func testMultipleWindowsAndArrayPaths() throws {
        let mappings = [
            QuotaMapping(label: "5 小时", usedPath: "limits.windows[0].used", totalPath: "limits.windows.0.total", resetPath: "limits.windows.0.reset"),
            QuotaMapping(label: "每周", usedPath: "", totalPath: "limits.windows.1.total", remainingPath: "limits.windows[1].left", resetPath: "limits.windows.1.reset")
        ]
        let result = try parse(#"{"limits":{"windows":[{"used":20,"total":100,"reset":"2026-10-15T10:00:00Z"},{"left":"180","total":"200","reset":1792058400000}]}}"#, mappings: mappings)
        XCTAssertEqual(result.metrics.map(\.remainingPercent), [80, 90])
        XCTAssertEqual(result.metrics.map(\.label), ["5 小时", "每周"])
        XCTAssertEqual(result.metrics.map(\.id), mappings.map { $0.id.uuidString })
        XCTAssertEqual(result.metrics[0].resetsAt, result.metrics[1].resetsAt)
        XCTAssertEqual(result.fetchedAt, Date(timeIntervalSince1970: 100))
    }

    func testBalanceDoesNotFabricateQuota() throws {
        let result = try parse(#"{"credit":{"amount":"18.35"}}"#, mappings: [.init(label: "余额", usedPath: "", totalPath: "", remainingPath: "credit.amount", unit: "CNY", kind: .balance, category: .balance)])
        let balance = try XCTUnwrap(result.metrics.first)
        XCTAssertTrue(balance.isBalance)
        XCTAssertTrue(balance.isValid)
        XCTAssertEqual(balance.remaining, 18.35, accuracy: 0.0001)
        XCTAssertEqual(balance.total, 0)
        XCTAssertEqual(balance.remainingPercent, 0)
        XCTAssertEqual(balance.category, .balance)
    }

    func testBalanceCurrencyComesFromResponseWithoutFallback() throws {
        let mapping = QuotaMapping(label: "余额", remainingPath: "balance_infos.0.total_balance", unit: "CNY", kind: .balance, unitPath: "balance_infos.0.currency")
        let result = try parse(#"{"balance_infos":[{"total_balance":"19.25","currency":"USD"}]}"#, mappings: [mapping])
        XCTAssertEqual(result.metrics.first?.unit, "USD")
        XCTAssertEqual(result.metrics.first?.remaining, 19.25)
        XCTAssertThrowsError(try parse(#"{"balance_infos":[{"total_balance":"19.25"}]}"#, mappings: [mapping]))
        XCTAssertThrowsError(try parse(#"{"balance_infos":[{"total_balance":"19.25","currency":123}]}"#, mappings: [mapping]))
    }

    func testInvalidNumericValuesAreRejected() {
        let invalid = [
            #"{"used":-1,"total":100}"#,
            #"{"used":1,"total":-100}"#,
            #"{"used":"NaN","total":100}"#,
            #"{"used":"inf","total":100}"#,
            #"{"used":true,"total":100}"#,
            #"{"used":1,"total":false}"#,
            #"{"used":null,"total":100}"#
        ]
        for json in invalid { XCTAssertThrowsError(try parse(json), json) }
        XCTAssertThrowsError(try parse(#"{"total":100,"left":101}"#, mappings: [.init(remainingPath: "left")]))
        XCTAssertThrowsError(try parse(#"{"left":-1}"#, mappings: [.init(remainingPath: "left", kind: .balance)]))
        XCTAssertThrowsError(try parse(#"{"left":"Infinity"}"#, mappings: [.init(remainingPath: "left", kind: .balance)]))
    }

    func testMissingPathsAndMalformedJSONFailClearly() {
        XCTAssertThrowsError(try parse(#"{"used":10}"#)) { error in
            XCTAssertEqual(error as? QuotaProviderError, .missingValue(label: "额度"))
        }
        XCTAssertThrowsError(try parse("<html>unauthorized</html>")) { error in
            XCTAssertEqual(error as? QuotaProviderError, .invalidJSON)
        }
        XCTAssertThrowsError(try parse(#"{"used":10,"total":100,"reset":"tomorrow"}"#, mappings: [.init(resetPath: "reset")]))
        XCTAssertThrowsError(try parse(#"{"used":10,"total":100}"#, mappings: []))
    }

    func testResponseSizeLimit() {
        XCTAssertThrowsError(try HTTPQuotaProvider.parse(data: Data(repeating: 32, count: HTTPQuotaProvider.maximumResponseBytes + 1), mappings: [.init()])) { error in
            XCTAssertEqual(error as? QuotaProviderError, .responseTooLarge)
        }
    }

    func testEndpointRequiresSecureTransportAndNoEmbeddedCredentials() throws {
        XCTAssertNoThrow(try HTTPQuotaProvider.endpointURL("https://example.com/quota", accountID: ""))
        XCTAssertNoThrow(try HTTPQuotaProvider.endpointURL("http://localhost:8080/quota", accountID: ""))
        XCTAssertNoThrow(try HTTPQuotaProvider.endpointURL("http://127.0.0.1/quota", accountID: ""))
        XCTAssertNoThrow(try HTTPQuotaProvider.endpointURL("http://[::1]/quota", accountID: ""))
        for endpoint in ["http://example.com/quota", "https://user:password@example.com", "file:///etc/passwd", "https://example.com/#token", "https://{accountId}.example.com", "", "https:///missing"] {
            XCTAssertThrowsError(try HTTPQuotaProvider.endpointURL(endpoint, accountID: "abc"), endpoint)
        }
    }

    func testAccountPlaceholderCannotInjectPathOrQuery() throws {
        let url = try HTTPQuotaProvider.endpointURL("https://example.com/accounts/{accountId}/quota?account={accountId}", accountID: "foo/bar?x=1&token=secret#fragment")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.count, 1)
        XCTAssertEqual(components.queryItems?.first?.value, "foo/bar?x=1&token=secret#fragment")
        XCTAssertNil(components.fragment)
        XCTAssertTrue(url.absoluteString.contains("foo%2Fbar%3Fx%3D1%26token%3Dsecret%23fragment"))
    }

    func testAuthenticationHeadersAndInjectionRejection() throws {
        let account = Account(toolID: UUID(), name: "账户", externalID: "account-1")
        let configuration = HTTPConfiguration(endpoint: "https://example.com/{accountId}")
        let request = try HTTPQuotaProvider.makeRequest(configuration: configuration, account: account, token: "test-secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/account-1")
        XCTAssertThrowsError(try HTTPQuotaProvider.makeRequest(configuration: configuration, account: account, token: "secret\r\nInjected: true"))
        var badConfiguration = configuration
        badConfiguration.authHeader = "Authorization\nX-Test"
        XCTAssertThrowsError(try HTTPQuotaProvider.makeRequest(configuration: badConfiguration, account: account, token: "secret"))
        badConfiguration.authHeader = "Host"
        XCTAssertThrowsError(try HTTPQuotaProvider.makeRequest(configuration: badConfiguration, account: account, token: "secret"))
    }

    func testConfigurationRoundTripMultipleAccountsAndKinds() throws {
        let tool = ToolDefinition(name: "服务", provider: .httpJSON, http: .init(endpoint: "https://example.com/quota", mappings: [.init(), .init(label: "余额", remainingPath: "balance", unit: "USD", kind: .balance)]))
        let first = Account(toolID: tool.id, name: "个人")
        let second = Account(toolID: tool.id, name: "工作", manualMetrics: [.init(label: "余额", used: 0, total: 0, unit: "USD", remainingBalance: 10, category: .balance)], supplementalMetrics: [.init(label: "加购包", used: 50, total: 200, unit: "次", category: .purchased)])
        let configuration = AppConfiguration(tools: [tool], accounts: [first, second], pinnedAccountID: second.id)
        let encoded = try JSONEncoder().encode(configuration)
        XCTAssertEqual(try JSONDecoder().decode(AppConfiguration.self, from: encoded), configuration)
        XCTAssertNotEqual(configuration.accounts[0].id, configuration.accounts[1].id)
    }

    func testToolBrandIdentitySurvivesRenameAndLegacyConfigDecodesWithoutIt() throws {
        var tool = ToolDefinition(name: "Codex", provider: .codexCLI, brandID: "codex")
        tool.name = "我的开发助手"
        let encoded = try JSONEncoder().encode(tool)
        let renamed = try JSONDecoder().decode(ToolDefinition.self, from: encoded)
        XCTAssertEqual(renamed, tool)
        XCTAssertEqual(renamed.brandID, "codex")

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "brandID")
        let restored = try JSONDecoder().decode(ToolDefinition.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(restored.brandID)
        tool.brandID = nil
        XCTAssertEqual(restored, tool)
    }

    func testOldMappingDefaultsToQuota() throws {
        let mapping = QuotaMapping()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(mapping)) as? [String: Any])
        object.removeValue(forKey: "kind")
        object.removeValue(forKey: "category")
        object.removeValue(forKey: "unitPath")
        let decoded = try JSONDecoder().decode(QuotaMapping.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.kind, .quota)
        XCTAssertEqual(decoded.category, .custom)
        XCTAssertEqual(decoded.unitPath, "")
    }

    func testLegacyMetricWithoutCategoryOrUnlimitedPreservesBalance() throws {
        let legacy = Data(#"{"id":"old-credit","label":"余额","used":0,"total":0,"unit":"USD","remainingBalance":12.5}"#.utf8)
        let metric = try JSONDecoder().decode(QuotaMetric.self, from: legacy)
        XCTAssertEqual(metric.id, "old-credit")
        XCTAssertEqual(metric.category, .custom)
        XCTAssertFalse(metric.isUnlimited)
        XCTAssertTrue(metric.isBalance)
        XCTAssertTrue(metric.isValid)
        XCTAssertEqual(metric.remaining, 12.5)
    }

    func testLegacyAccountWithoutSupplementsAndMetricCategoryStillDecodes() throws {
        let legacy = Data(#"{"id":"F12F4B71-E3AB-451C-AF99-58B7179B0879","toolID":"C91C6A70-B8D9-4D80-8C64-539A924CC1C8","name":"已有账号","subtitle":"个人","externalID":"old-id","isEnabled":true,"manualMetrics":[{"id":"old-quota","label":"额度","used":20,"total":100,"unit":"%"}]}"#.utf8)
        let account = try JSONDecoder().decode(Account.self, from: legacy)
        XCTAssertEqual(account.name, "已有账号")
        XCTAssertEqual(account.externalID, "old-id")
        XCTAssertTrue(account.supplementalMetrics.isEmpty)
        XCTAssertEqual(account.manualMetrics.count, 1)
        XCTAssertEqual(account.manualMetrics[0].remainingPercent, 80)
        XCTAssertEqual(account.manualMetrics[0].category, .custom)
        XCTAssertFalse(account.manualMetrics[0].isUnlimited)
    }

    func testSubscriptionAndPurchasedAllowancesRemainSeparateInSnapshot() throws {
        let mappings = [
            QuotaMapping(label: "额度", usedPath: "subscription.used", totalPath: "subscription.total", unit: "次", category: .subscription),
            QuotaMapping(label: "额度", usedPath: "purchased.used", totalPath: "purchased.total", unit: "次", category: .purchased)
        ]
        let result = try parse(#"{"subscription":{"used":20,"total":100},"purchased":{"used":150,"total":500}}"#, mappings: mappings)
        XCTAssertEqual(result.metrics.count, 2)
        XCTAssertEqual(result.metrics.map(\.category), [.subscription, .purchased])
        XCTAssertEqual(result.metrics.map(\.id), mappings.map { $0.id.uuidString })
        XCTAssertEqual(result.metrics.map(\.total), [100, 500])
        XCTAssertEqual(result.metrics.map(\.remaining), [80, 350])
    }

    func testUnlimitedAllowancePreservesItsMeaningThroughEncoding() throws {
        let unlimited = QuotaMetric(label: "加购点数", used: 0, total: 0, unit: "点数", category: .purchased, isUnlimited: true)
        XCTAssertTrue(unlimited.isValid)
        XCTAssertTrue(unlimited.isBalance)
        XCTAssertNil(unlimited.remainingBalance)
        XCTAssertEqual(unlimited.remainingPercent, 0)
        let decoded = try JSONDecoder().decode(QuotaMetric.self, from: JSONEncoder().encode(unlimited))
        XCTAssertEqual(decoded, unlimited)
        XCTAssertTrue(decoded.isUnlimited)
        XCTAssertFalse(QuotaMetric(label: "非法加购余额", used: 0, total: 0, remainingBalance: -1, category: .purchased).isValid)
        XCTAssertFalse(QuotaMetric(label: "非法不限量", used: .infinity, total: 0, isUnlimited: true).isValid)
    }

    func testAccountSwitchingIsExplicitlyUnsupported() async {
        let switcher = UnsupportedAccountSwitcher()
        let account = Account(toolID: UUID(), name: "测试")
        guard case .unsupported = switcher.capability(for: account) else { return XCTFail("Expected unsupported switching") }
        do {
            try await switcher.activate(account)
            XCTFail("Account switching must not run before a provider supports it")
        } catch {
            XCTAssertTrue(error is AccountSwitchError)
        }
    }
}
