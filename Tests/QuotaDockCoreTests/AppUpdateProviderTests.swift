import XCTest
@testable import QuotaDockCore


final class AppUpdateProviderTests: XCTestCase {
    private static func manifest(_ version: String = "0.2.0") -> Data {
        Data("""
        {"version":"\(version)","notes":"更新说明","architecture":"arm64","minimumSystemVersion":"14.0.0","releaseURL":"https://github.com/Errorrrrr/QuotaDock/releases/tag/v\(version)","downloadURL":"https://github.com/Errorrrrr/QuotaDock/releases/download/v\(version)/QuotaDock-\(version)-macOS-arm64.zip"}
        """.utf8)
    }
    func testVersionsCompareNumerically() throws {
        XCTAssertTrue(try ReleaseVersion("0.10.0") > ReleaseVersion("0.9.9"))
        XCTAssertTrue(try ReleaseVersion("1.0.0") > ReleaseVersion("0.99.99"))
        XCTAssertEqual(try ReleaseVersion("1.2.3"), try ReleaseVersion("1.2.3"))
        for version in ["", "1.0", "v1.0.0", "1.0.0-beta", "1.-1.0", "01.0.0", "99999999.0.0"] {
            XCTAssertThrowsError(try ReleaseVersion(version))
        }
    }
    func testNewSameAndOlderReleaseAndUnauthenticatedRequest() async throws {
        let provider = AppUpdateProvider(load: { request in
            XCTAssertEqual(request.url, AppUpdateProvider.manifestURL)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return Self.manifest()
        })
        let newer = try await provider.check(currentVersion: "0.1.0")
        XCTAssertEqual(newer?.version, "0.2.0")
        let same = try await provider.check(currentVersion: "0.2.0")
        XCTAssertNil(same)
        let older = try await provider.check(currentVersion: "0.3.0")
        XCTAssertNil(older)
    }
    func testOnlyExactReleaseAssetFromOwnRepositoryAccepted() throws {
        let text = String(decoding: Self.manifest(), as: UTF8.self)
        for changed in [text.replacingOccurrences(of: "github.com", with: "github.com.attacker.example"), text.replacingOccurrences(of: "Errorrrrr/QuotaDock", with: "other/repo"), text.replacingOccurrences(of: "https:", with: "http:"), text.replacingOccurrences(of: ".zip", with: ".zip?redirect=other")] {
            XCTAssertThrowsError(try AppUpdateProvider.parse(Data(changed.utf8)))
        }
        XCTAssertThrowsError(try AppUpdateProvider.parse(Data(repeating: 32, count: 65537)))
        XCTAssertThrowsError(try AppUpdateProvider.parse(Data("{}".utf8)))
    }
    func testFailureNeverClaimsCurrentAndCancellationIsPreserved() async throws {
        for error in [QuotaProviderError.httpStatus(404), .httpStatus(429), .connectionFailed] {
            let provider = AppUpdateProvider(load: { _ in throw error })
            do { _ = try await provider.check(currentVersion: "0.1.0"); XCTFail("Failure must not mean latest") }
            catch is AppUpdateError {} catch { XCTFail("Unexpected error") }
        }
        let cancelled = AppUpdateProvider(load: { _ in throw CancellationError() })
        do { _ = try await cancelled.check(currentVersion: "0.1.0"); XCTFail() } catch is CancellationError {}
    }
    func testPublishedManifestVersionOrdering() throws {
        let packageVersion = try ReleaseVersion("0.10.0")
        for (published, allowed) in [("0.9.9", true), ("0.10.0", true), ("0.10.1", false), ("1.0.0", false)] {
            let release = try AppUpdateProvider.parse(Self.manifest(published))
            XCTAssertEqual(try ReleaseVersion(release.version) <= packageVersion, allowed, published)
        }
    }
    func testManifestRejectsAssetFromDifferentVersion() throws {
        let text = String(decoding: Self.manifest("0.1.3"), as: UTF8.self)
        let changed = text.replacingOccurrences(of: "/download/v0.1.3/QuotaDock-0.1.3-", with: "/download/v0.1.2/QuotaDock-0.1.2-")
        XCTAssertThrowsError(try AppUpdateProvider.parse(Data(changed.utf8)))
    }
    func testPublishedManifestDoesNotExceedPackageVersion() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let release = try AppUpdateProvider.parse(Data(contentsOf: root.appendingPathComponent("update.json")))
        let version = try String(contentsOf: root.appendingPathComponent("VERSION")).trimmingCharacters(in: .whitespacesAndNewlines)
        // VERSION advances before release; update.json advances only after assets are published.
        XCTAssertLessThanOrEqual(try ReleaseVersion(release.version), try ReleaseVersion(version))
    }
}

