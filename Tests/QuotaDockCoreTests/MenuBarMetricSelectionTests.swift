import XCTest
@testable import QuotaDockCore

final class MenuBarMetricSelectionTests: XCTestCase {
    private let metrics: [QuotaMetric] = [
        .init(id: "5h", label: "5 小时", used: 20, total: 100, category: .subscription),
        .init(id: "week", label: "每周", used: 60, total: 100, category: .subscription),
        .init(id: "credits", label: "积分", used: 0, total: 0, unit: "点", remainingBalance: 500, category: .balance)
    ]

    func testAutomaticKeepsLowestSubscriptionWindow() {
        XCTAssertEqual(MenuBarMetricSelection.resolve(metrics: metrics, selectedID: nil)?.id, "week")
    }
    func testExplicitChoiceOverridesAutomaticIncludingBalances() {
        XCTAssertEqual(MenuBarMetricSelection.resolve(metrics: metrics, selectedID: "5h")?.remainingPercent, 80)
        XCTAssertEqual(MenuBarMetricSelection.resolve(metrics: metrics, selectedID: "credits")?.remainingBalance, 500)
        XCTAssertEqual(MenuBarMetricSelection.resolve(metrics: metrics.reversed(), selectedID: "5h")?.id, "5h")
    }
    func testMissingSelectedWindowDoesNotSilentlySwitch() {
        XCTAssertNil(MenuBarMetricSelection.resolve(metrics: metrics, selectedID: "missing"))
        XCTAssertNil(MenuBarMetricSelection.resolve(metrics: [], selectedID: "5h"))
        XCTAssertEqual(MenuBarMetricSelection.resolve(metrics: metrics, selectedID: "5h")?.id, "5h")
    }
    func testSelectionPersistsPerAccountAndOldConfigurationsStayAutomatic() throws {
        let account = Account(toolID: UUID(), name: "Alias", menuBarMetricID: "credits")
        let encoded = try JSONEncoder().encode(account)
        XCTAssertEqual(try JSONDecoder().decode(Account.self, from: encoded).menuBarMetricID, "credits")
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        old.removeValue(forKey: "menuBarMetricID")
        let legacy = try JSONDecoder().decode(Account.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(legacy.menuBarMetricID)
    }
}
