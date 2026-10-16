import AppKit
import QuotaDockCore
import Darwin

@main
struct QuotaDockUpdater {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in await install(); app.terminate(nil) }
        app.run()
    }

    @MainActor static func install() async {
        let args = CommandLine.arguments
        guard args.count == 5 || (args.count == 6 && args[5] == "--demo"), let pid = Int32(args[4]), pid > 1 else { return }
        let target = URL(fileURLWithPath: args[1]).standardizedFileURL
        let version = args[2], id = args[3]
        guard let root = AppUpdateInstaller.sessionRoot(target: target, id: id),
              URL(fileURLWithPath: args[0]).standardizedFileURL.deletingLastPathComponent().path == root.path else { return }
        let staged = root.appendingPathComponent("QuotaDock.app")
        #if DEBUG
        let isTest = ProcessInfo.processInfo.environment["QUOTADOCK_UPDATER_TEST"] == "1"
        #else
        let isTest = false
        #endif
        let label = NSTextField(labelWithString: "正在准备安装…")
        let progress = NSProgressIndicator(); progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 100
        let note = NSTextField(labelWithString: "账号配置将保留，完成后自动重启。")
        note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [label, progress, note]); stack.orientation = .vertical; stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 410, height: 145), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "QuotaDock 更新"; window.contentView = stack
        progress.widthAnchor.constraint(equalToConstant: 350).isActive = true
        window.center()
        if !isTest { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        var swapped = false
        var launched: NSRunningApplication?
        do {
            try AppUpdateInstaller.validateTarget(target)
            try AppUpdateInstaller.validateBundle(staged, version: version)
            try Data().write(to: root.appendingPathComponent("helper-ready"), options: .atomic)
            label.stringValue = "正在退出旧版本…"; progress.doubleValue = 20
            for _ in 0..<300 {
                if kill(pid, 0) != 0 && errno == ESRCH { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard kill(pid, 0) != 0 && errno == ESRCH else { throw UpdateInstallError.failed("旧版本未退出，已取消安装。") }
            label.stringValue = "正在安装新版本…"; progress.doubleValue = 50
            try AppUpdateInstaller.swap(staged, target); swapped = true
            label.stringValue = "正在重新启动…"; progress.doubleValue = 80
            var launchArguments: [String] = []
            if args.last == "--demo" { launchArguments.append("--demo") }
            launched = try await launch(target, arguments: launchArguments)
            // Use AppKit's actual launch completion, not a file receipt from a custom argument.
            // Keep the run loop free so NSRunningApplication state can update.
            guard launched?.processIdentifier != pid,
                  launched?.executableURL?.resolvingSymlinksInPath().path == target.appendingPathComponent("Contents/MacOS/QuotaDock").resolvingSymlinksInPath().path else {
                throw UpdateInstallError.failed("重启进程与更新应用不匹配。")
            }
            for _ in 0..<200 {
                if launched?.isFinishedLaunching == true { break }
                if launched?.isTerminated == true { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard launched?.isFinishedLaunching == true, launched?.isTerminated == false else {
                throw UpdateInstallError.failed("新版本未能完成启动。")
            }
            // Catch immediate startup crashes before discarding the previous bundle.
            try await Task.sleep(nanoseconds: 1_000_000_000)
            guard launched?.isTerminated == false else { throw UpdateInstallError.failed("新版本启动后意外退出。") }
            progress.doubleValue = 100
            try? FileManager.default.removeItem(at: root)
        } catch {
            var message = error.localizedDescription
            FileHandle.standardError.write(Data(("QuotaDock updater: " + message + "\n").utf8))
            if swapped {
                launched?.terminate()
                for _ in 0..<50 {
                    if launched?.isTerminated != false { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if launched?.isTerminated == false { launched?.forceTerminate() }
                do {
                    try AppUpdateInstaller.swap(staged, target); swapped = false
                    do {
                        _ = try await launch(target, arguments: args.last == "--demo" ? ["--demo"] : [])
                        message += "\n已恢复并重新打开旧版本。"
                    } catch { message += "\n已恢复旧版本，请手动重新打开 QuotaDock。" }
                } catch { message += "\n自动恢复未完成，旧版本保留在：\(staged.path)" }
            }
            if !swapped { try? FileManager.default.removeItem(at: root) }
            let alert = NSAlert(); alert.messageText = "更新未完成"; alert.informativeText = message
            alert.addButton(withTitle: "知道了"); if !isTest { alert.runModal() }
        }
        window.orderOut(nil)
    }

    @MainActor private static func launch(_ url: URL, arguments: [String]) async throws -> NSRunningApplication {
        let config = NSWorkspace.OpenConfiguration(); config.arguments = arguments; config.createsNewApplicationInstance = true; config.activates = false
        return try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: config) { application, error in
                if let application { continuation.resume(returning: application) }
                else { continuation.resume(throwing: error ?? UpdateInstallError.failed("无法启动更新后的应用。")) }
            }
        }
    }
}
