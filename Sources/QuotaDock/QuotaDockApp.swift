import AppKit
import Combine
import QuotaDockCore

@main
enum QuotaDockApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var observation: AnyCancellable?
    private var store: AppStore!
    private var panelController: QuotaPanelController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        NSApp.applicationIconImage = AppBranding.icon(size: 128)
        store = AppStore(demo: CommandLine.arguments.contains("--demo"))
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = AppBranding.icon(size: 18, template: true)
                ?? NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "QuotaDock 账号额度")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover)
        }
        panelController = makePanelController()
        panelController.onSizeChange = { [weak self] size in self?.popover.contentSize = size }
        popover.behavior = .transient
        popover.contentViewController = panelController
        popover.contentSize = panelController.preferredPanelSize
        observation = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateTitle() }
        }
        updateTitle()
        store.startPolling()
        if CommandLine.arguments.contains("--preview") {
            DispatchQueue.main.async { [weak self] in self?.showQuotaPanel() }
        }
        else if CommandLine.arguments.contains("--settings") { showSettings() }
    }

    private func makePanelController() -> QuotaPanelController {
        QuotaPanelController(store: store, openSettings: { [weak self] in self?.showSettings() })
    }

    private func updateTitle() {
        let title = store.menuBarTitle
        statusItem.button?.title = title.isEmpty ? "" : " " + title
        statusItem.button?.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        statusItem.button?.setAccessibilityLabel(title.isEmpty ? "QuotaDock · 查看账号额度" : title)
        if let id = store.config.pinnedAccountID, let account = store.enabledAccounts.first(where: { $0.id == id }) {
            let metric = MenuBarMetricSelection.resolve(metrics: store.snapshots[id]?.metrics ?? [], selectedID: account.menuBarMetricID)
            let selection = metric?.label ?? (account.menuBarMetricID == nil ? "等待额度" : "已选额度暂未返回")
            statusItem.button?.toolTip = "\(store.tool(for: account)?.name ?? "") · \(store.accountName(for: account))\n菜单栏额度：\(selection)\n点击查看所有账号额度"
        } else {
            statusItem.button?.toolTip = "QuotaDock · 点击查看所有账号额度"
        }
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) }
        else { showQuotaPanel() }
    }

    @objc private func showQuotaPanel() {
        guard let button = statusItem.button else { return }
        panelController.reload()
        popover.contentSize = panelController.preferredPanelSize
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    @objc func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 660), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "QuotaDock"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 800, height: 600)
            window.contentViewController = ManagementController(store: store)
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func checkForUpdates() {
        popover.performClose(nil)
        UpdateController.shared.show()
    }

    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let application = NSMenu(title: "QuotaDock")
        let panel = NSMenuItem(title: "查看额度面板", action: #selector(showQuotaPanel), keyEquivalent: "1")
        panel.target = self
        application.addItem(panel)
        let settings = NSMenuItem(title: "打开控制台…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        application.addItem(settings)
        let updates = NSMenuItem(title: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        application.addItem(updates)
        application.addItem(.separator())
        application.addItem(withTitle: "退出 QuotaDock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = application
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApplication.shared.mainMenu = main
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Activation may produce a reopen event while the status-item popover
        // opens. Leave its state unchanged and suppress automatic window reopening.
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        UpdateController.shared.shouldAllowTermination ? .terminateNow : .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) { store.stopPolling() }
}
