import Foundation

public struct ReleaseVersion: Comparable, Sendable {
    private let parts: [Int]
    public init(_ value: String) throws {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces.allSatisfy({ !$0.isEmpty && $0.count <= 6 && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              pieces.allSatisfy({ $0.count == 1 || $0.first != "0" }) else { throw AppUpdateError.invalidManifest }
        parts = pieces.compactMap { Int($0) }
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

public struct AppRelease: Decodable, Sendable {
    public let version: String
    public let notes: String
    public let releaseURL: URL
    public let downloadURL: URL
    public let architecture: String
    public let minimumSystemVersion: String
}

public enum AppUpdateError: LocalizedError {
    case invalidManifest, unavailable, connection
    public var errorDescription: String? {
        switch self {
        case .invalidManifest: return "更新信息无效，请稍后重试或查看发布页面。"
        case .unavailable: return "暂未找到正式发布版本。"
        case .connection: return "无法连接更新服务，请检查网络后重试。"
        }
    }
}

public struct AppUpdateProvider: Sendable {
    public static let releasesURL = URL(string: "https://github.com/Errorrrrr/QuotaDock/releases")!
    public static let manifestURL = URL(string: "https://raw.githubusercontent.com/Errorrrrr/QuotaDock/main/update.json")!
    private let load: @Sendable (URLRequest) async throws -> Data
    public init() { load = { try await HTTPQuotaProvider.fetchData(request: $0) } }
    init(load: @escaping @Sendable (URLRequest) async throws -> Data) { self.load = load }

    public func check(currentVersion: String) async throws -> AppRelease? {
        let current = try ReleaseVersion(currentVersion)
        var request = URLRequest(url: Self.manifestURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("QuotaDock/" + currentVersion, forHTTPHeaderField: "User-Agent")
        let data: Data
        do { data = try await load(request) }
        catch is CancellationError { throw CancellationError() }
        catch QuotaProviderError.httpStatus(404) { throw AppUpdateError.unavailable }
        catch { throw AppUpdateError.connection }
        try Task.checkCancellation()
        let release = try Self.parse(data)
        return try ReleaseVersion(release.version) > current ? release : nil
    }

    public static func parse(_ data: Data) throws -> AppRelease {
        guard data.count <= 64 * 1024, let release = try? JSONDecoder().decode(AppRelease.self, from: data),
              release.notes.count <= 2000, ["arm64", "x86_64", "universal"].contains(release.architecture) else { throw AppUpdateError.invalidManifest }
        _ = try ReleaseVersion(release.version)
        _ = try ReleaseVersion(release.minimumSystemVersion)
        let base = "https://github.com/Errorrrrr/QuotaDock/releases/"
        // Only this repository's version-specific release and package may be opened.
        guard release.releaseURL.absoluteString == base + "tag/v" + release.version,
              release.downloadURL.absoluteString == base + "download/v" + release.version + "/QuotaDock-" + release.version + "-macOS-" + release.architecture + ".zip" else { throw AppUpdateError.invalidManifest }
        return release
    }
}
