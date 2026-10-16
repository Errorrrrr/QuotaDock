import AppKit
import QuotaDockCore

@MainActor
final class UpdateController: NSObject, NSWindowDelegate {
    static let shared = UpdateController()
    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.7" }
    private var window: NSWindow?
    private var task: Task<Void, Never>?
    private let status = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let retry = NSButton(title: "重新检查", target: nil, action: nil)
    private let download = NSButton(title: "下载并安装", target: nil, action: nil)
    private var release: AppRelease?
    private let progress = NSProgressIndicator()
    private let progressText = NSTextField(labelWithString: "")
    private let cancel = NSButton(title: "取消下载", target: nil, action: nil)
    private var isUpdating = false
    private var isInstalling = false
    private var isRestarting = false

    var shouldAllowTermination: Bool {
        if isRestarting { return true }
        if isUpdating {
            if !isInstalling { task?.cancel() }
            window?.makeKeyAndOrderFront(nil)
            return false
        }
        return true
    }

    func show() {
        if window == nil { makeWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard task == nil else { return }
        check()
    }

    private func makeWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "QuotaDock 更新"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let root = NSStackView()
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 16
        root.translatesAutoresizingMaskIntoConstraints = false
        status.font = .systemFont(ofSize: 17, weight: .semibold)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 6
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        let heading = NSStackView(views: [spinner, status]); heading.spacing = 10
        retry.target = self; retry.action = #selector(check)
        download.target = self; download.action = #selector(installUpdate)
        let releases = NSButton(title: "发布页面", target: self, action: #selector(openReleases))
        cancel.target = self; cancel.action = #selector(cancelUpdate); cancel.isHidden = true
        progress.style = .bar; progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 100
        progress.isHidden = true; progressText.isHidden = true
        progressText.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        progressText.textColor = .secondaryLabelColor
        let buttons = NSStackView(views: [releases, retry, cancel, download]); buttons.spacing = 10
        [heading, detail, progress, progressText, NSView(), buttons].forEach { root.addArrangedSubview($0) }
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -24),
            detail.widthAnchor.constraint(equalTo: root.widthAnchor),
            progress.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])
        window.center(); self.window = window
    }

    @objc private func check() {
        guard task == nil else { return }
        progress.isHidden = true; progressText.isHidden = true
        release = nil; download.isHidden = true; retry.isEnabled = false
        status.stringValue = "正在检查更新…"
        detail.stringValue = "当前版本 \(Self.currentVersion)"
        spinner.startAnimation(nil)
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil; self.spinner.stopAnimation(nil); self.retry.isEnabled = true }
            do {
                let result = try await AppUpdateProvider().check(currentVersion: Self.currentVersion)
                try Task.checkCancellation()
                if let result {
                    self.release = result
                    self.status.stringValue = "发现新版本 \(result.version)"
                    let system = ProcessInfo.processInfo.operatingSystemVersion
                    let supportedOS = try ReleaseVersion("\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)") >= ReleaseVersion(result.minimumSystemVersion)
                    #if arch(arm64)
                    let arch = "arm64"
                    #else
                    let arch = "x86_64"
                    #endif
                    let compatible = supportedOS && [arch, "universal"].contains(result.architecture)
                    self.download.isHidden = !compatible
                    self.detail.stringValue = "当前版本 \(Self.currentVersion)\n\(result.notes)\n" + (compatible ? "点击后将在应用内下载并安装，完成后自动重启。账号配置保留。" : "此安装包不适用于当前 Mac，请查看发布页面。")
                } else {
                    self.status.stringValue = "当前已是最新版本"
                    self.detail.stringValue = "QuotaDock \(Self.currentVersion)\n未发现更新的正式版本。"
                }
            } catch is CancellationError { }
            catch {
                self.status.stringValue = "检查更新失败"
                self.detail.stringValue = error.localizedDescription
            }
        }
    }
    @objc private func cancelUpdate() { if !isInstalling { task?.cancel() } }

    @objc private func installUpdate() {
        guard task == nil, let release else { return }
        do { try AppUpdateInstaller.validateTarget(Bundle.main.bundleURL) }
        catch { status.stringValue = "暂时无法安装"; detail.stringValue = error.localizedDescription; return }
        isUpdating = true; isInstalling = false
        retry.isEnabled = false; download.isHidden = true; cancel.isHidden = false
        progress.isHidden = false; progress.isIndeterminate = true; progress.startAnimation(nil)
        progressText.isHidden = false; progressText.stringValue = "正在连接发布服务器…"
        status.stringValue = "正在下载更新…"
        detail.stringValue = "QuotaDock \(release.version) · 账号配置将保留\n下载完成后自动安装并重新启动。"
        task = Task { [weak self] in
            guard let self else { return }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("QuotaDock-download-" + UUID().uuidString)
            var staging: URL?
            var handedOff = false
            defer {
                try? FileManager.default.removeItem(at: folder)
                if !handedOff, let staging { try? FileManager.default.removeItem(at: staging) }
                self.task = nil; self.isUpdating = false; self.isInstalling = false
                self.retry.isEnabled = true; self.cancel.isHidden = true
                self.progress.stopAnimation(nil)
                if !handedOff { self.download.isHidden = false }
            }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let sums = AppUpdateDownload(destination: folder.appendingPathComponent("SHA256SUMS"), maximumBytes: 64 * 1024) { _, _ in }
                let sumsURL = release.downloadURL.deletingLastPathComponent().appendingPathComponent("SHA256SUMS")
                let sumsFile = try await sums.fetch(sumsURL)
                let expected = try AppUpdateInstaller.checksum(String(contentsOf: sumsFile), filename: release.downloadURL.lastPathComponent)
                let transfer = AppUpdateDownload(destination: folder.appendingPathComponent("update.zip"), maximumBytes: AppUpdateInstaller.maximumPackageBytes) { [weak self] received, total in
                    Task { @MainActor [weak self] in
                        guard let self, self.isUpdating, !self.isInstalling, self.task?.isCancelled != true else { return }
                        self.progress.isIndeterminate = total <= 0
                        let receivedText = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
                        if total > 0 {
                            let percent = min(100, Double(received) / Double(total) * 100)
                            self.progress.doubleValue = percent
                            self.progressText.stringValue = "\(Int(percent))% · \(receivedText) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
                        } else { self.progressText.stringValue = "已下载 \(receivedText)" }
                    }
                }
                let archive = try await transfer.fetch(release.downloadURL)
                try Task.checkCancellation()
                self.isInstalling = true; self.cancel.isHidden = true
                self.status.stringValue = "正在校验并准备安装…"
                self.progress.isIndeterminate = true; self.progress.startAnimation(nil)
                self.progressText.stringValue = "校验 SHA256、版本、架构和应用签名"
                let target = Bundle.main.bundleURL
                let preparation = Task.detached {
                    try AppUpdateInstaller.verifyChecksum(file: archive, expected: expected)
                    return try AppUpdateInstaller.prepare(archive: archive, target: target, version: release.version)
                }
                staging = try await withTaskCancellationHandler(operation: { try await preparation.value }, onCancel: { preparation.cancel() })
                try Task.checkCancellation()
                guard let staging else { throw UpdateInstallError.failed("安装准备未完成。") }
                let helper = staging.appendingPathComponent("QuotaDockUpdater")
                try FileManager.default.copyItem(at: target.appendingPathComponent("Contents/Helpers/QuotaDockUpdater"), to: helper)
                let process = Process(); process.executableURL = helper
                let id = String(staging.lastPathComponent.dropFirst(".QuotaDock-update-".count))
                process.arguments = [target.path, release.version, id, String(ProcessInfo.processInfo.processIdentifier)]
                if CommandLine.arguments.contains("--demo") { process.arguments?.append("--demo") }
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run()
                for _ in 0..<100 {
                    if FileManager.default.fileExists(atPath: staging.appendingPathComponent("helper-ready").path) { break }
                    if !process.isRunning { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                guard process.isRunning, FileManager.default.fileExists(atPath: staging.appendingPathComponent("helper-ready").path) else {
                    if process.isRunning { process.terminate() }
                    throw UpdateInstallError.failed("安装程序未能启动，当前应用未修改。")
                }
                try? FileManager.default.removeItem(at: folder)
                handedOff = true; self.isRestarting = true
                self.status.stringValue = "正在安装并重启…"
                NSApp.terminate(nil)
            } catch is CancellationError {
                self.status.stringValue = "已取消更新"; self.detail.stringValue = "当前应用和账号配置未修改，可以重新下载。"
                self.progress.isHidden = true; self.progressText.isHidden = true
            } catch {
                self.status.stringValue = "更新未完成"; self.detail.stringValue = error.localizedDescription
                self.progress.isHidden = true; self.progressText.isHidden = true
            }
        }
    }
    @objc private func openReleases() { NSWorkspace.shared.open(release?.releaseURL ?? AppUpdateProvider.releasesURL) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !isInstalling }
    func windowWillClose(_ notification: Notification) { task?.cancel() }
}
