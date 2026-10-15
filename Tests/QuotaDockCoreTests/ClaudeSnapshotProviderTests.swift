import XCTest
@testable import QuotaDockCore

final class ClaudeSnapshotProviderTests: XCTestCase {
    private func parse(_ json: String, modifiedAt: Date = Date()) throws -> QuotaSnapshot {
        try ClaudeSnapshotProvider.parse(data: Data(json.utf8), modifiedAt: modifiedAt)
    }

    func testBothWindowsAndFileModificationTimestamp() throws {
        let modifiedAt = Date().addingTimeInterval(-60)
        let result = try parse(#"{"rate_limits":{"five_hour":{"used_percentage":25,"resets_at":4070908800},"seven_day":{"used_percentage":82,"resets_at":4071513600}}}"#, modifiedAt: modifiedAt)
        XCTAssertEqual(result.metrics.count, 2)
        XCTAssertEqual(result.metrics.map(\.used), [25, 82])
        XCTAssertEqual(result.metrics.map(\.total), [100, 100])
        XCTAssertEqual(result.metrics.map(\.remainingPercent), [75, 18])
        XCTAssertEqual(result.metrics[0].resetsAt, Date(timeIntervalSince1970: 4070908800))
        XCTAssertEqual(result.metrics[1].resetsAt, Date(timeIntervalSince1970: 4071513600))
        XCTAssertEqual(result.fetchedAt, modifiedAt)
        XCTAssertTrue(result.metrics.allSatisfy(\.isValid))
    }

    func testSingleWindowAndOptionalReset() throws {
        let fiveHour = try parse(#"{"rate_limits":{"five_hour":{"used_percentage":0}}}"#)
        XCTAssertEqual(fiveHour.metrics.count, 1)
        XCTAssertEqual(fiveHour.metrics[0].remainingPercent, 100)
        XCTAssertNil(fiveHour.metrics[0].resetsAt)
        let weekly = try parse(#"{"rate_limits":{"seven_day":{"used_percentage":100}}}"#)
        XCTAssertEqual(weekly.metrics.count, 1)
        XCTAssertEqual(weekly.metrics[0].remainingPercent, 0)
    }

    func testMissingRateLimitsDoNotDisplayAsUnusedAllowance() {
        for json in ["{}", #"{"rate_limits":{}}"#, #"{"rate_limits":null}"#, #"{"cost":{"total_cost_usd":0}}"#] {
            XCTAssertThrowsError(try parse(json), json)
        }
    }

    func testInvalidWindowValuesAreRejected() {
        let invalid = [
            #"{"rate_limits":{"five_hour":{"used_percentage":-1}}}"#,
            #"{"rate_limits":{"five_hour":{"used_percentage":101}}}"#,
            #"{"rate_limits":{"five_hour":{"used_percentage":"NaN"}}}"#,
            #"{"rate_limits":{"five_hour":{"used_percentage":"Infinity"}}}"#,
            #"{"rate_limits":{"five_hour":{"used_percentage":true}}}"#,
            #"{"rate_limits":{"five_hour":{"used_percentage":null}}}"#,
            #"{"rate_limits":{"five_hour":{}}}"#,
            #"{"rate_limits":{"five_hour":"unavailable"}}"#,
            #"{"rate_limits":{"five_hour":{"used_percentage":10},"seven_day":{"used_percentage":-1}}}"#
        ]
        for json in invalid { XCTAssertThrowsError(try parse(json), json) }
    }

    func testInvalidResetAndMalformedJSONAreRejected() {
        for reset in ["-1", "true", #""NaN""#, #""tomorrow""#] {
            let json = #"{"rate_limits":{"five_hour":{"used_percentage":20,"resets_at":\#(reset)}}}"#
            XCTAssertThrowsError(try parse(json), json)
        }
        XCTAssertThrowsError(try parse("not JSON"))
    }

    func testExpiredSnapshotsAndOversizedDataAreRejected() {
        let data = Data(#"{"rate_limits":{"five_hour":{"used_percentage":20}}}"#.utf8)
        XCTAssertThrowsError(try ClaudeSnapshotProvider.parse(data: data, modifiedAt: Date().addingTimeInterval(-25 * 60 * 60)))
        XCTAssertThrowsError(try ClaudeSnapshotProvider.parse(data: Data(repeating: 32, count: 1_024 * 1_024 + 1), modifiedAt: Date()))
    }
}
