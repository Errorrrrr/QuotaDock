import XCTest
import CryptoKit
@testable import QuotaDockCore

final class AppUpdateInstallerTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func app(at url: URL, version: String) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.copyItem(at: project.appendingPathComponent(".build/debug/QuotaDockUpdater"), to: url.appendingPathComponent("Contents/MacOS/QuotaDock"))
        let plist: [String: Any] = ["CFBundleIdentifier": "com.quotadock.app", "CFBundleExecutable": "QuotaDock", "CFBundleShortVersionString": version,
                                   "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "14.0"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        try AppUpdateInstaller.command("/usr/bin/codesign", ["--force", "--sign", "-", url.path])
    }

    func testChecksumSelectsExactZIPAndRejectsDuplicateOrCorruption() throws {
        let root = try temporary(), zip = root.appendingPathComponent("test.zip")
        let bytes = Data("package fixture".utf8); try bytes.write(to: zip)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let entry = hash + "  test.zip\n"
        XCTAssertEqual(try AppUpdateInstaller.checksum(entry + hash + "  test.dmg\n", filename: "test.zip"), hash)
        XCTAssertThrowsError(try AppUpdateInstaller.checksum(entry + entry, filename: "test.zip"))
        XCTAssertThrowsError(try AppUpdateInstaller.checksum(entry, filename: "other.zip"))
        XCTAssertThrowsError(try AppUpdateInstaller.checksum("bad  test.zip", filename: "test.zip"))
        try AppUpdateInstaller.verifyChecksum(file: zip, expected: hash)
        try Data("corrupted".utf8).write(to: zip)
        XCTAssertThrowsError(try AppUpdateInstaller.verifyChecksum(file: zip, expected: hash))
    }

    func testRedirectsStayOnHTTPSGitHubAssetHosts() {
        for url in ["https://github.com/a", "https://release-assets.githubusercontent.com/a?sig=fixture", "https://objects.githubusercontent.com/a"] {
            XCTAssertTrue(AppUpdateDownload.allowed(URL(string: url)!))
        }
        for url in ["http://github.com/a", "https://github.com.evil.example/a", "https://user:pass@github.com/a", "https://github.com:444/a", "file:///tmp/a"] {
            XCTAssertFalse(AppUpdateDownload.allowed(URL(string: url)!))
        }
    }

    func testCancelledBeforeDownloadMakesNoRequest() async throws {
        let root = try temporary()
        let downloader = AppUpdateDownload(destination: root.appendingPathComponent("update.zip"), maximumBytes: 10) { _, _ in }
        downloader.cancel()
        do { _ = try await downloader.fetch(URL(string: "https://github.com/unused")!); XCTFail() }
        catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("update.zip").path))
    }

    func testArchiveRejectsTraversalAndForeignRoots() throws {
        try AppUpdateInstaller.validateArchivePaths("QuotaDock.app/\nQuotaDock.app/Contents/Info.plist\n__MACOSX/QuotaDock.app/._Contents\n")
        for listing in ["", "/QuotaDock.app/a", "QuotaDock.app/../../config.json", "QuotaDock.app/./a", "evil.app/a", "QuotaDock.app/Contents\\escape"] {
            XCTAssertThrowsError(try AppUpdateInstaller.validateArchivePaths(listing), listing)
        }
    }

    func testAtomicInstallRollbackAndFailureLeaveConfigurationUntouched() throws {
        let root = try temporary()
        let current = root.appendingPathComponent("QuotaDock.app"), staged = root.appendingPathComponent("staged.app")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: current.appendingPathComponent("version"))
        try Data("new".utf8).write(to: staged.appendingPathComponent("version"))
        let config = root.appendingPathComponent("config.json"); let data = Data("account preferences fixture".utf8)
        try data.write(to: config)
        try AppUpdateInstaller.swap(staged, current)
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("version")), "new")
        try AppUpdateInstaller.swap(staged, current)
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("version")), "old")
        XCTAssertThrowsError(try AppUpdateInstaller.swap(root.appendingPathComponent("missing"), current))
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("version")), "old")
        XCTAssertEqual(try Data(contentsOf: config), data)
    }

    func testVerifiedPackageStagesWithoutReplacingRunningApp() throws {
        let root = try temporary()
        let current = root.appendingPathComponent("QuotaDock.app")
        let source = root.appendingPathComponent("release/QuotaDock.app")
        try app(at: current, version: "1.0.0"); try app(at: source, version: "1.1.0")
        let zip = root.appendingPathComponent("release.zip")
        try AppUpdateInstaller.command("/usr/bin/ditto", ["-c", "-k", "--keepParent", source.path, zip.path])
        let stage = try AppUpdateInstaller.prepare(archive: zip, target: current, version: "1.1.0")
        try AppUpdateInstaller.validateBundle(stage.appendingPathComponent("QuotaDock.app"), version: "1.1.0")
        try AppUpdateInstaller.validateBundle(current, version: "1.0.0")
        XCTAssertThrowsError(try AppUpdateInstaller.prepare(archive: zip, target: current, version: "2.0.0"))
        let link = root.appendingPathComponent("linked.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: current)
        XCTAssertThrowsError(try AppUpdateInstaller.validateTarget(link))
        try Data("tampered".utf8).write(to: stage.appendingPathComponent("QuotaDock.app/Contents/MacOS/QuotaDock"))
        XCTAssertThrowsError(try AppUpdateInstaller.validateBundle(stage.appendingPathComponent("QuotaDock.app"), version: "1.1.0"))
    }

    func testArchiveWithSymlinkIsRejectedBeforeExtraction() throws {
        let root = try temporary(), current = root.appendingPathComponent("QuotaDock.app")
        let source = root.appendingPathComponent("release/QuotaDock.app")
        try app(at: current, version: "1.0.0"); try app(at: source, version: "1.1.0")
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("escape"), withDestinationURL: root)
        let zip = root.appendingPathComponent("release.zip")
        try AppUpdateInstaller.command("/usr/bin/ditto", ["-c", "-k", "--keepParent", source.path, zip.path])
        XCTAssertThrowsError(try AppUpdateInstaller.prepare(archive: zip, target: current, version: "1.1.0"))
        try AppUpdateInstaller.validateBundle(current, version: "1.0.0")
    }
    func testLiveReleaseDownloadAndVerification() async throws {
        guard ProcessInfo.processInfo.environment["QUOTADOCK_LIVE_UPDATE_TEST"] == "1" else {
            throw XCTSkip("Set QUOTADOCK_LIVE_UPDATE_TEST=1 for anonymous GitHub download verification")
        }
        let root = try temporary()
        let optionalRelease = try await AppUpdateProvider().check(currentVersion: "0.0.0")
        let release = try XCTUnwrap(optionalRelease)
        let sums = AppUpdateDownload(destination: root.appendingPathComponent("SHA256SUMS"), maximumBytes: 64 * 1024) { _, _ in }
        let sumsFile = try await sums.fetch(release.downloadURL.deletingLastPathComponent().appendingPathComponent("SHA256SUMS"))
        let digest = try AppUpdateInstaller.checksum(String(contentsOf: sumsFile), filename: release.downloadURL.lastPathComponent)
        let download = AppUpdateDownload(destination: root.appendingPathComponent("release.zip"), maximumBytes: AppUpdateInstaller.maximumPackageBytes) { received, total in
            XCTAssertGreaterThan(received, 0)
            if total > 0 { XCTAssertLessThanOrEqual(received, total) }
        }
        let zip = try await download.fetch(release.downloadURL)
        try AppUpdateInstaller.verifyChecksum(file: zip, expected: digest)
        let current = root.appendingPathComponent("QuotaDock.app")
        try app(at: current, version: "0.0.0")
        let stage = try AppUpdateInstaller.prepare(archive: zip, target: current, version: release.version)
        try AppUpdateInstaller.validateBundle(stage.appendingPathComponent("QuotaDock.app"), version: release.version)
        try AppUpdateInstaller.validateBundle(current, version: "0.0.0")
    }

    func testRelaunchSessionUsesCanonicalDirectoryPath() throws {
        let parent = try temporary(), target = parent.appendingPathComponent("QuotaDock.app", isDirectory: true)
        let id = UUID().uuidString
        let root = parent.appendingPathComponent(".QuotaDock-update-" + id, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        XCTAssertEqual(AppUpdateInstaller.sessionRoot(target: target, id: id)?.path, root.path)
        XCTAssertNil(AppUpdateInstaller.sessionRoot(target: target, id: "../../invalid"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        XCTAssertNil(AppUpdateInstaller.sessionRoot(target: target, id: id))
    }

}
