import AppKit
import Combine
import QuotaDockCore

@MainActor
final class QuotaPanelController: NSViewController {
    var onSizeChange: ((NSSize) -> Void)?
    var preferredPanelSize: NSSize {
        if !isViewLoaded { _ = view }
        return panelSize
    }

    private let store: AppStore
    private let openSettings: () -> Void
    private var observation: AnyCancellable?
    private var selectedToolID: UUID?
    private var panelSize = NSSize(width: 360, height: 240)
    private var scrollView: NSScrollView?
    private var filterButton: NSPopUpButton?

    init(store: AppStore, openSettings: @escaping () -> Void) {
        self.store = store
        self.openSettings = openSettings
        super.init(nibName: nil, bundle: nil)
        observation = store.objectWillChange.sink { [weak self] _ in
            // Published values are committed after objectWillChange is emitted.
            DispatchQueue.main.async { [weak self] in self?.reload() }
        }
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = QDPanelFlippedView(frame: NSRect(origin: .zero, size: panelSize))
        reload()
    }

    func reload() {
        guard isViewLoaded else { loadView(); return }
        if let selectedToolID, !store.config.tools.contains(where: { $0.id == selectedToolID }) {
            self.selectedToolID = nil
        }
        let previousOffset = scrollView?.contentView.bounds.origin.y ?? 0
        let accounts = store.enabledAccounts.filter { selectedToolID == nil || $0.toolID == selectedToolID }
        let rows = accounts.map(makeAccountRow)
        let contentHeight: CGFloat = rows.isEmpty ? 126 : rows.reduce(0) { $0 + $1.frame.height }
        let showsFilter = store.config.tools.count > 1
        let filterHeight: CGFloat = showsFilter ? 28 : 0
        let bannerHeight: CGFloat = store.isDemo ? 25 : 0
        let errorBannerHeight: CGFloat = store.errorMessage == nil ? 0 : 24
        let topHeight: CGFloat = 40 + filterHeight + bannerHeight + errorBannerHeight
        let footerHeight: CGFloat = 30
        let scrollHeight = min(520 - topHeight - footerHeight, contentHeight)
        let newSize = NSSize(width: 360, height: topHeight + scrollHeight + footerHeight)
        let sizeChanged = panelSize != newSize
        panelSize = newSize
        preferredContentSize = newSize
        view.subviews.forEach { $0.removeFromSuperview() }

        let header = QDPanelFlippedView()
        header.autoresizesSubviews = false
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: topHeight)
        ])
        buildHeader(in: header)
        if showsFilter { buildFilter(y: 38, in: header) }
        if store.isDemo { buildDemoBanner(y: 38 + filterHeight, in: header) }
        if let error = store.errorMessage {
            let warning = label("配置异常 · \(error)", size: 10, color: .systemOrange)
            warning.frame = NSRect(x: 15, y: 40 + filterHeight + bannerHeight, width: 331, height: 18)
            warning.toolTip = error
            header.addSubview(warning)
        }

        let scroll = NSScrollView(frame: NSRect(x: 12, y: topHeight, width: 336, height: scrollHeight))
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let document = QDPanelFlippedView(frame: NSRect(x: 0, y: 0, width: 336, height: contentHeight))
        if rows.isEmpty {
            buildEmptyState(in: document)
        } else {
            var y: CGFloat = 0
            for row in rows {
                row.setFrameOrigin(NSPoint(x: 0, y: y))
                document.addSubview(row)
                y += row.frame.height
            }
        }
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -footerHeight)
        ])
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(previousOffset, max(0, contentHeight - scrollHeight))))
        scroll.reflectScrolledClipView(scroll.contentView)
        scrollView = scroll
        let footer = QDPanelFlippedView()
        footer.autoresizesSubviews = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(footer)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: footerHeight)
        ])
        buildFooter(y: 0, accounts: accounts, in: footer)
        if sizeChanged { onSizeChange?(newSize) }
    }

    private func buildHeader(in container: NSView) {
        let title = label("QuotaDock", size: 14, weight: .semibold)
        title.frame = NSRect(x: 14, y: 10, width: 180, height: 20)
        container.addSubview(title)
        let refresh = iconButton("arrow.clockwise", tooltip: "刷新所有账号") { [weak self] in
            guard let self else { return }
            Task { await self.store.refreshAll() }
        }
        refresh.frame = NSRect(x: 232, y: 6, width: 27, height: 26)
        refresh.isEnabled = store.refreshing.isEmpty
        container.addSubview(refresh)
        let manage = textButton("打开控制台") { [weak self] in self?.openSettings() }
        manage.frame = NSRect(x: 264, y: 6, width: 84, height: 26)
        container.addSubview(manage)
    }

    private func buildFilter(y: CGFloat, in container: NSView) {
        let popup = NSPopUpButton(frame: NSRect(x: 11, y: y, width: 338, height: 24), pullsDown: false)
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 11)
        popup.addItem(withTitle: "全部工具 · \(store.enabledAccounts.count) 个账号")
        for tool in store.config.tools {
            let count = store.enabledAccounts.filter { $0.toolID == tool.id }.count
            popup.addItem(withTitle: "\(tool.name) · \(count) 个账号")
            popup.lastItem?.representedObject = tool.id.uuidString
            if tool.id == selectedToolID { popup.select(popup.lastItem) }
        }
        popup.target = self
        popup.action = #selector(filterChanged(_:))
        popup.setAccessibilityLabel("筛选工具")
        container.addSubview(popup)
        filterButton = popup
    }

    private func buildDemoBanner(y: CGFloat, in container: NSView) {
        let text = label("演示数据 · 不代表真实额度", size: 10, color: .systemOrange)
        text.frame = NSRect(x: 15, y: y + 3, width: 240, height: 17)
        container.addSubview(text)
        let exit = textButton("退出演示") { [weak self] in self?.store.setDemo(false) }
        exit.font = .systemFont(ofSize: 10)
        exit.frame = NSRect(x: 282, y: y, width: 65, height: 22)
        container.addSubview(exit)
    }

    private func makeAccountRow(_ account: Account) -> NSView {
        let tool = store.tool(for: account)
        let snapshot = store.snapshots[account.id]
        let metrics = snapshot?.metrics ?? ((tool?.provider == .manual ? account.manualMetrics : []) + account.supplementalMetrics)
        let error = store.errors[account.id]
        let notice = metrics.isEmpty ? nil : snapshot?.notice
        let rowHeight: CGFloat = 26 + CGFloat(max(1, metrics.count)) * 20 + 6 + (error == nil && notice == nil ? 0 : 19)
        let row = QDPanelFlippedView(frame: NSRect(x: 0, y: 0, width: 336, height: rowHeight))

        let image = ToolBranding.makeView(for: tool)
        image.frame = NSRect(x: 1, y: 3, width: 20, height: 20)
        row.addSubview(image)
        let accountTitle = "\(tool?.name ?? "未配置工具") · \(store.accountName(for: account))"
        let title = label(accountTitle, size: 11, weight: .semibold)
        let source = store.isDemo ? "演示" : (tool?.provider == .manual ? "手动" : nil)
        // This row uses frames. An unconstrained NSStackView rewrites its own
        // frame during layout; reserve the name's width explicitly instead.
        let titleHeight = ceil(title.intrinsicContentSize.height)
        title.frame = NSRect(x: 27, y: (26 - titleHeight) / 2,
                             width: source == nil ? 249 : 219, height: titleHeight)
        title.setAccessibilityIdentifier("account-name-\(account.id.uuidString)")
        row.addSubview(title)
        let updated: String
        if store.refreshing.contains(account.id) {
            updated = "正在更新…"
        } else if let snapshot {
            updated = tool?.provider == .manual ? "手动记录" : "数据时间：\(fullDate(snapshot.fetchedAt))"
        } else {
            updated = "等待首次更新"
        }
        title.toolTip = [accountTitle, store.snapshots[account.id]?.accountEmail ?? "", account.subtitle, updated].filter { !$0.isEmpty }.joined(separator: "\n")
        if let source {
            let badge = label(source, size: 9, color: store.isDemo ? .systemOrange : .secondaryLabelColor)
            badge.frame = NSRect(x: 248, y: 6, width: 28, height: 15)
            row.addSubview(badge)
        }

        let refresh = iconButton("arrow.clockwise", tooltip: "刷新此账号 · \(updated)") { [weak self] in
            guard let self else { return }
            Task { await self.store.refresh(accountID: account.id) }
        }
        refresh.frame = NSRect(x: 279, y: 1, width: 23, height: 23)
        refresh.isEnabled = !store.refreshing.contains(account.id)
        row.addSubview(refresh)
        let isPinned = store.config.pinnedAccountID == account.id
        let hasChoice = metrics.count > 1 || account.menuBarMetricID != nil
        let pin = iconButton(isPinned ? "pin.fill" : "pin", tooltip: hasChoice ? "选择菜单栏显示额度" : (isPinned ? "取消菜单栏固定" : "在菜单栏显示此账号")) {}
        pin.onClick = { [weak self, weak pin] in
            guard let self, let pin else { return }
            if hasChoice { self.showMetricMenu(account: account, metrics: metrics, anchor: pin) }
            else { self.togglePin(account.id) }
        }
        pin.contentTintColor = isPinned ? .controlAccentColor : .secondaryLabelColor
        pin.frame = NSRect(x: 307, y: 1, width: 23, height: 23)
        row.addSubview(pin)

        let supplementalIDs = Set(account.supplementalMetrics.map(\.id))
        if metrics.isEmpty {
            let empty = label(store.refreshing.contains(account.id) ? "正在获取额度…" : (store.snapshots[account.id]?.notice ?? "尚未获取额度"), size: 11, color: .secondaryLabelColor)
            empty.frame = NSRect(x: 2, y: 27, width: 320, height: 18)
            row.addSubview(empty)
        } else {
            for (index, metric) in metrics.enumerated() {
                let metricView = makeMetricRow(metric, isManualSupplement: supplementalIDs.contains(metric.id))
                metricView.setFrameOrigin(NSPoint(x: 0, y: 26 + CGFloat(index) * 20))
                row.addSubview(metricView)
            }
        }

        let bottomY = 26 + CGFloat(max(1, metrics.count)) * 20
        if let error {
            let prefix = snapshot == nil ? "获取失败" : "更新失败，显示上次数据"
            let warning = label("\(prefix) · \(error)", size: 10, color: .systemOrange)
            warning.frame = NSRect(x: 2, y: bottomY + 1, width: 327, height: 17)
            warning.toolTip = "\(prefix)\n\(error)"
            row.addSubview(warning)
        }
        if error == nil, let notice {
            let warning = label(notice, size: 10, color: .systemOrange)
            warning.frame = NSRect(x: 2, y: bottomY + 1, width: 327, height: 17)
            warning.toolTip = notice
            row.addSubview(warning)
        }
        row.addSubview(separator(frame: NSRect(x: 0, y: rowHeight - 1, width: 336, height: 1)))
        return row
    }

    private func makeMetricRow(_ metric: QuotaMetric, isManualSupplement: Bool) -> NSView {
        let row = QDPanelFlippedView(frame: NSRect(x: 0, y: 0, width: 336, height: 20))
        var metricName = metric.label
        if metric.category == .purchased, !metricName.contains("加购") { metricName = "加购 · \(metricName)" }
        if isManualSupplement { metricName = "手动 · \(metricName)" }
        let name = label(metricName, size: 10, color: .secondaryLabelColor)
        name.frame = NSRect(x: 2, y: 3, width: 100, height: 16)
        name.toolTip = "\(metric.category.displayName) · \(metricName)"
        row.addSubview(name)

        let low = !metric.isBalance && metric.category != .purchased && metric.remainingPercent <= store.config.lowQuotaThreshold
        let isAmount = metric.isBalance || metric.category == .purchased
        let value: String
        if metric.isUnlimited {
            value = "不限量"
        } else if metric.isBalance || metric.category == .purchased {
            value = "\(number(metric.remaining)) \(metric.unit)"
        } else {
            value = "\(Int(metric.remainingPercent.rounded()))%"
        }
        if !metric.isBalance && metric.category != .purchased {
            let progress = NSProgressIndicator(frame: NSRect(x: 108, y: 9, width: 42, height: 5))
            progress.style = .bar
            progress.controlSize = .mini
            progress.isIndeterminate = false
            progress.minValue = 0
            progress.maxValue = 100
            progress.doubleValue = metric.remainingPercent
            progress.toolTip = "剩余 \(number(metric.remaining)) / \(number(metric.total)) \(metric.unit)"
            progress.setAccessibilityLabel("\(metric.label)剩余额度")
            row.addSubview(progress)
        }
        let amount = label(metric.isUnlimited ? value : "\(value) 剩余", size: 12, weight: .medium, color: low ? .systemOrange : .labelColor)
        amount.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        amount.alignment = .right
        amount.frame = NSRect(x: isAmount ? 106 : 153, y: 2, width: isAmount ? 126 : 79, height: 18)
        amount.toolTip = metric.isUnlimited ? "此项不限量" : (metric.isBalance ? "可用余额：\(value)" : "已用 \(number(metric.used)) / 总额 \(number(metric.total)) \(metric.unit)；剩余 \(number(metric.remaining)) \(metric.unit)")
        row.addSubview(amount)
        if let reset = metric.resetsAt {
            let resetLabel = label(resetText(reset), size: 10, color: .tertiaryLabelColor)
            resetLabel.alignment = .right
            resetLabel.frame = NSRect(x: 239, y: 4, width: 90, height: 15)
            resetLabel.toolTip = "重置时间：\(fullDate(reset))"
            row.addSubview(resetLabel)
        }
        return row
    }

    private func buildEmptyState(in container: NSView) {
        let title = label(store.enabledAccounts.isEmpty ? "还没有账号" : "此工具暂无启用账号", size: 12, weight: .medium)
        title.alignment = .center
        title.frame = NSRect(x: 10, y: 16, width: 316, height: 22)
        container.addSubview(title)
        let detail = label("在控制台中添加工具和账号", size: 11, color: .secondaryLabelColor)
        detail.alignment = .center
        detail.frame = NSRect(x: 10, y: 42, width: 316, height: 20)
        container.addSubview(detail)
        let manage = textButton("打开控制台") { [weak self] in self?.openSettings() }
        manage.frame = NSRect(x: 81, y: 77, width: 88, height: 26)
        container.addSubview(manage)
        let demo = textButton(store.isDemo ? "退出演示" : "查看演示") { [weak self] in
            guard let self else { return }
            self.store.setDemo(!self.store.isDemo)
        }
        demo.frame = NSRect(x: 174, y: 77, width: 80, height: 26)
        container.addSubview(demo)
    }

    private func buildFooter(y: CGFloat, accounts: [Account], in container: NSView) {
        let count = accounts.filter { account in
            store.snapshots[account.id]?.metrics.contains {
                !$0.isBalance && $0.category != .purchased && $0.remainingPercent <= store.config.lowQuotaThreshold
            } ?? false
        }.count
        let text = count == 0 ? "\(accounts.count) 个账号" : "\(accounts.count) 个账号 · \(count) 个额度偏低"
        let summary = label(text, size: 10, color: count == 0 ? .secondaryLabelColor : .systemOrange)
        summary.frame = NSRect(x: 15, y: y + 7, width: 260, height: 16)
        container.addSubview(summary)
        let quit = textButton("退出") { NSApplication.shared.terminate(nil) }
        quit.frame = NSRect(x: 303, y: y + 2, width: 44, height: 25)
        container.addSubview(quit)
    }

    private func showMetricMenu(account: Account, metrics: [QuotaMetric], anchor: NSView) {
        let menu = NSMenu(title: "菜单栏显示额度")
        let automatic = NSMenuItem(title: "自动 · 剩余最少的窗口", action: #selector(selectMetric(_:)), keyEquivalent: "")
        automatic.target = self
        automatic.representedObject = ["accountID": account.id.uuidString]
        automatic.state = account.menuBarMetricID == nil ? .on : .off
        automatic.isEnabled = !store.isDemo
        menu.addItem(automatic)
        menu.addItem(.separator())
        for metric in metrics {
            let item = NSMenuItem(title: metric.label, action: #selector(selectMetric(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ["accountID": account.id.uuidString, "metricID": metric.id]
            item.state = account.menuBarMetricID == metric.id ? .on : .off
            item.isEnabled = !store.isDemo
            menu.addItem(item)
        }
        if let selected = account.menuBarMetricID, !metrics.contains(where: { $0.id == selected }) {
            let missing = NSMenuItem(title: "已选额度暂未返回", action: nil, keyEquivalent: "")
            missing.state = .on
            menu.addItem(missing)
        }
        if store.config.pinnedAccountID == account.id {
            menu.addItem(.separator())
            let unpin = NSMenuItem(title: "取消菜单栏固定", action: #selector(unpinMetric(_:)), keyEquivalent: "")
            unpin.target = self
            unpin.representedObject = account.id
            unpin.isEnabled = !store.isDemo
            menu.addItem(unpin)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY), in: anchor)
    }

    @objc private func selectMetric(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let raw = info["accountID"], let id = UUID(uuidString: raw) else { return }
        do { try store.selectMenuBarMetric(accountID: id, metricID: info["metricID"]) }
        catch { store.errorMessage = error.localizedDescription }
    }

    @objc private func unpinMetric(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { togglePin(id) }
    }

    private func togglePin(_ accountID: UUID) {
        do {
            try store.updatePreferences(refreshInterval: store.config.refreshInterval, lowQuotaThreshold: store.config.lowQuotaThreshold,
                                        pinnedAccountID: store.config.pinnedAccountID == accountID ? nil : accountID)
        } catch {
            store.errorMessage = error.localizedDescription
            let alert = NSAlert(error: error)
            if let window = view.window { alert.beginSheetModal(for: window) }
            else { alert.runModal() }
        }
    }

    @objc private func filterChanged(_ sender: NSPopUpButton) {
        selectedToolID = (sender.selectedItem?.representedObject as? String).flatMap(UUID.init(uuidString:))
        scrollView?.contentView.scroll(to: .zero)
        reload()
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.isSelectable = false
        return field
    }

    private func textButton(_ title: String, action: @escaping () -> Void) -> QDPanelActionButton {
        let button = QDPanelActionButton(title: title, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        return button
    }

    private func iconButton(_ symbol: String, tooltip: String, action: @escaping () -> Void) -> QDPanelActionButton {
        let button = QDPanelActionButton(title: "", action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        button.bezelStyle = .recessed
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        return button
    }

    private func separator(frame: NSRect) -> NSBox {
        let separator = NSBox(frame: frame)
        separator.boxType = .separator
        return separator
    }

    private func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private func fullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private func resetText(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        if seconds <= 0 { return "待重置" }
        if seconds >= 86_400 { return "\(Int(ceil(seconds / 86_400))) 天后重置" }
        if seconds >= 3_600 { return "\(Int(ceil(seconds / 3_600))) 小时后重置" }
        return "\(max(1, Int(ceil(seconds / 60)))) 分后重置"
    }
}

@MainActor
private final class QDPanelFlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class QDPanelActionButton: NSButton {
    var onClick: () -> Void

    init(title: String, action: @escaping () -> Void) {
        onClick = action
        super.init(frame: .zero)
        self.title = title
        target = self
        self.action = #selector(invokeAction)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func invokeAction() { onClick() }
}
