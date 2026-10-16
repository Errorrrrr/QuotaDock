import Foundation
import CryptoKit
import Darwin

public enum AppUpdateInstaller {
    public static let bundleID = "com.quotadock.app"
    public static let maximumPackageBytes: Int64 = 200 * 1024 * 1024

    public static func checksum(_ text: String, filename: String) throws -> String {
        let matches = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2, String(fields[1]).trimmingCharacters(in: .whitespaces) == filename else { return nil }
            return String(fields[0]).lowercased()
        }
        guard matches.count == 1, let digest = matches.first, digest.count == 64,
              digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw UpdateInstallError.failed("发布校验文件缺失或格式无效，已停止安装。")
        }
        return digest
    }

    public static func verifyChecksum(file: URL, expected: String) throws {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation(); hash.update(data: data)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else {
            throw UpdateInstallError.failed("安装包 SHA256 校验失败，未修改当前应用。")
        }
    }

    public static func validateArchivePaths(_ listing: String) throws {
        let paths = listing.split(separator: "\n", omittingEmptySubsequences: true)
        guard !paths.isEmpty, paths.count < 20_000 else { throw UpdateInstallError.failed("安装包目录无效。") }
        for path in paths {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\r"),
                  !parts.contains(".."), !parts.contains("."),
                  parts.first == "QuotaDock.app" || parts.first == "__MACOSX" else {
                throw UpdateInstallError.failed("安装包包含不安全的路径。")
            }
        }
    }

    @discardableResult
    public static func command(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateInstallError.failed("更新文件验证或解压失败（\(URL(fileURLWithPath: executable).lastPathComponent)）。") }
        return String(decoding: data, as: UTF8.self)
    }

    public static func validateTarget(_ app: URL) throws {
        let path = app.standardizedFileURL
        guard path.pathExtension == "app", path.path == path.resolvingSymlinksInPath().path,
              !path.path.hasPrefix("/Volumes/"), !path.path.contains("/AppTranslocation/"),
              FileManager.default.isWritableFile(atPath: path.path),
              FileManager.default.isWritableFile(atPath: path.deletingLastPathComponent().path) else {
            throw UpdateInstallError.failed("当前应用位于只读或不可写目录。请先移到可写的 Applications 文件夹，再进行应用内更新。")
        }
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == bundleID else {
            throw UpdateInstallError.failed("当前应用位置无效，请从已安装的 QuotaDock 启动更新。")
        }
    }

    public static func validateBundle(_ app: URL, version: String) throws {
        guard let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              plist["CFBundleIdentifier"] as? String == bundleID,
              plist["CFBundleShortVersionString"] as? String == version,
              plist["CFBundleExecutable"] as? String == "QuotaDock",
              let minimum = plist["LSMinimumSystemVersion"] as? String else {
            throw UpdateInstallError.failed("安装包的应用标识或版本不匹配。")
        }
        let pieces = minimum.split(separator: "."); let normalized = pieces.count == 2 ? minimum + ".0" : minimum
        let os = ProcessInfo.processInfo.operatingSystemVersion
        guard try ReleaseVersion("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)") >= ReleaseVersion(normalized) else {
            throw UpdateInstallError.failed("新版本不支持当前 macOS。")
        }
        // Current releases contain no symlinks. Reject them before trusting bundle metadata or executable paths.
        guard let enumerator = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            throw UpdateInstallError.failed("无法读取更新应用。")
        }
        for case let file as URL in enumerator {
            if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw UpdateInstallError.failed("安装包包含不支持的符号链接。")
            }
        }
        let executable = app.appendingPathComponent("Contents/MacOS/QuotaDock")
        let architectures = try command("/usr/bin/lipo", ["-archs", executable.path]).split(whereSeparator: \.isWhitespace)
        #if arch(arm64)
        let architecture: Substring = "arm64"
        #else
        let architecture: Substring = "x86_64"
        #endif
        guard architectures.contains(architecture) else { throw UpdateInstallError.failed("安装包不支持当前 Mac 架构。") }
        try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    }

    /// Stage beside the installed bundle so the eventual replacement is an atomic same-volume swap.
    public static func prepare(archive: URL, target: URL, version: String) throws -> URL {
        try validateTarget(target)
        let paths = try command("/usr/bin/zipinfo", ["-1", archive.path])
        try validateArchivePaths(paths)
        let metadata = try command("/usr/bin/zipinfo", ["-l", archive.path])
        guard !metadata.split(separator: "\n").contains(where: { $0.hasPrefix("l") }),
              let totalLine = metadata.split(separator: "\n").last,
              let uncompressed = totalLine.components(separatedBy: ", ").dropFirst().first?.split(separator: " ").first,
              let size = Int64(uncompressed), size <= 500 * 1024 * 1024 else {
            throw UpdateInstallError.failed("安装包包含链接或解压大小异常。")
        }
        let root = target.deletingLastPathComponent().appendingPathComponent(".QuotaDock-update-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try Task.checkCancellation()
            try command("/usr/bin/ditto", ["-x", "-k", archive.path, root.path])
            let app = root.appendingPathComponent("QuotaDock.app")
            try validateBundle(app, version: version)
            try Task.checkCancellation()
            return root
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }

    /// Swapping again rolls back. The previous app stays in staging until a successful relaunch.
    public static func swap(_ staged: URL, _ target: URL) throws {
        guard renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, target.path, UInt32(RENAME_SWAP)) == 0 else {
            throw UpdateInstallError.failed("无法替换应用，旧版本仍保留。请检查目录权限和可用空间。")
        }
    }

    public static func sessionRoot(target: URL, id: String) -> URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        let root = target.deletingLastPathComponent().appendingPathComponent(".QuotaDock-update-" + id)
        guard root.path == root.resolvingSymlinksInPath().path,
              let attributes = try? FileManager.default.attributesOfItem(atPath: root.path),
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else { return nil }
        return root
    }
}
