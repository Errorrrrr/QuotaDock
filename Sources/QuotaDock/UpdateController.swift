import AppKit
import QuotaDockCore

@MainActor
final class UpdateController: NSObject, NSWindowDelegate {
    static let shared = UpdateController()
    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.2" }
    private var window: NSWindow?
    private var task: Task<Void, Never>?
    private let status = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let retry = NSButton(title: "重新检查", target: nil, action: nil)
    private let download = NSButton(title: "下载更新", target: nil, action: nil)
    private var release: AppRelease?

    func show() {
        if window == nil { makeWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard task == nil else { return }
        check()
    }

    private func makeWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 250), styleMask: [.titled, .closable], backing: .buffered, defer: false)
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
        download.target = self; download.action = #selector(openDownload)
        let releases = NSButton(title: "发布页面", target: self, action: #selector(openReleases))
        let buttons = NSStackView(views: [releases, retry, download]); buttons.spacing = 10
        [heading, detail, NSView(), buttons].forEach { root.addArrangedSubview($0) }
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -24),
            detail.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])
        window.center(); self.window = window
    }

    @objc private func check() {
        guard task == nil else { return }
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
                    self.detail.stringValue = "当前版本 \(Self.currentVersion)\n\(result.notes)\n" + (compatible ? "下载后退出应用，再替换安装。" : "此安装包不适用于当前 Mac，请查看发布页面。")
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
    @objc private func openDownload() { if let release { NSWorkspace.shared.open(release.downloadURL) } }
    @objc private func openReleases() { NSWorkspace.shared.open(release?.releaseURL ?? AppUpdateProvider.releasesURL) }
    func windowWillClose(_ notification: Notification) { task?.cancel() }
}
