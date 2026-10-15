import AppKit
import Combine
import QuotaDockCore

@MainActor
final class ManagementController: NSViewController {
    private enum Section: String, CaseIterable {
        case overview = "额度总览", accounts = "账号管理", tools = "工具配置", preferences = "偏好设置"
        var symbol: String {
            switch self {
            case .overview: return "square.grid.2x2"
            case .accounts: return "person.2"
            case .tools: return "slider.horizontal.3"
            case .preferences: return "gearshape"
            }
        }
        var detail: String {
            switch self {
            case .overview: return "订阅额度、加购额度与余额分别展示。"
            case .accounts: return "同一工具的账号分别配置，凭据独立保存。"
            case .tools: return "选择已有接入方式，或配置自己的额度接口。"
            case .preferences: return "设置自动刷新、低额度提示和菜单栏展示。"
            }
        }
    }

    private let store: AppStore
    private var section: Section = .overview
    private var observation: AnyCancellable?
    private var updateScheduled = false
    private var lastConfiguration: AppConfiguration?
    private var lastDemoState: Bool?
    private var navButtons: [Section: ConsoleNavigationButton] = [:]
    private var presentedEditor: NSViewController?
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let headerActions = NSStackView()
    private let noticeStack = NSStackView()
    private let contentStack = ManagementDocumentStack()
    private let scrollView = NSScrollView()
    private let demoButton = ManagementActionButton(title: "浏览演示")
    private var intervalControl: NSPopUpButton?
    private var thresholdControl: NSSlider?
    private var thresholdValueLabel: NSTextField?
    private var pinnedControl: NSPopUpButton?

    init(store: AppStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 900, height: 640)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .followsWindowActiveState
        let sidebarContent = verticalStack(spacing: 5)
        let brand = horizontalStack(spacing: 10)
        let brandImage = NSImageView()
        brandImage.image = AppBranding.icon(size: 36)
        brandImage.widthAnchor.constraint(equalToConstant: 36).isActive = true
        brandImage.heightAnchor.constraint(equalToConstant: 36).isActive = true
        brand.addArrangedSubview(brandImage)
        let brandText = verticalStack(spacing: 3)
        brandText.addArrangedSubview(label("QuotaDock", size: 16, weight: .semibold))
        brandText.addArrangedSubview(label("账号与额度", size: 11, color: .secondaryLabelColor))
        brand.addArrangedSubview(brandText)
        sidebarContent.addArrangedSubview(brand)
        sidebarContent.setCustomSpacing(26, after: brand)
        for item in Section.allCases {
            if item == .preferences {
                let divider = NSBox()
                divider.boxType = .separator
                addFullWidth(divider, to: sidebarContent)
                sidebarContent.setCustomSpacing(10, after: divider)
            }
            let button = ConsoleNavigationButton(title: item.rawValue, symbol: item.symbol) { [weak self] in self?.select(item) }
            button.heightAnchor.constraint(equalToConstant: 36).isActive = true
            addFullWidth(button, to: sidebarContent)
            navButtons[item] = button
            if item == .tools { sidebarContent.setCustomSpacing(14, after: button) }
        }
        let sidebarSpacer = NSView()
        sidebarSpacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        sidebarContent.addArrangedSubview(sidebarSpacer)
        let localNote = label("本机存储 · 钥匙串保护", size: 11, color: .secondaryLabelColor)
        localNote.toolTip = "配置保存在本机，API 凭据按账号独立保存在系统钥匙串。"
        sidebarContent.addArrangedSubview(localNote)
        sidebarContent.setCustomSpacing(10, after: localNote)
        demoButton.handler = { [weak self] in self?.toggleDemo() }
        demoButton.controlSize = .small
        sidebarContent.addArrangedSubview(demoButton)
        let updates = ManagementActionButton(title: "检查更新…")
        updates.controlSize = .small
        updates.handler = { UpdateController.shared.show() }
        sidebarContent.addArrangedSubview(updates)
        sidebarContent.addArrangedSubview(label("版本 " + UpdateController.currentVersion, size: 10, color: .tertiaryLabelColor))
        sidebar.addSubview(sidebarContent)
        pin(sidebarContent, to: sidebar, inset: 16)

        let body = NSView()
        let heading = horizontalStack(spacing: 12)
        let titles = verticalStack(spacing: 7)
        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        titles.addArrangedSubview(titleLabel)
        titles.addArrangedSubview(subtitleLabel)
        heading.addArrangedSubview(titles)
        heading.addArrangedSubview(horizontalSpacer())
        headerActions.orientation = .horizontal
        headerActions.spacing = 8
        heading.addArrangedSubview(headerActions)
        noticeStack.orientation = .vertical
        noticeStack.alignment = .leading
        noticeStack.spacing = 8
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 0
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = contentStack
        let divider = NSBox()
        divider.boxType = .separator
        let footer = label("固定账号只改变菜单栏展示，不会切换其他应用的登录状态。", size: 10, color: .secondaryLabelColor)
        for child in [heading, noticeStack, scrollView, divider, footer] {
            child.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(child)
        }
        view.addSubview(sidebar)
        view.addSubview(body)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: view.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 204),
            body.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            body.topAnchor.constraint(equalTo: view.topAnchor),
            body.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            body.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            heading.topAnchor.constraint(equalTo: body.topAnchor, constant: 26),
            heading.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 26),
            heading.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -26),
            noticeStack.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 18),
            noticeStack.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            noticeStack.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: noticeStack.bottomAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: divider.topAnchor, constant: -12),
            divider.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -15),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
        ])
        render()
        observation = store.objectWillChange.sink { [weak self] _ in self?.scheduleUpdate() }
    }

    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            let configurationChanged = self.lastConfiguration != self.store.config || self.lastDemoState != self.store.isDemo
            // Background quota refreshes must not discard unsaved preferences.
            if self.section != .preferences || configurationChanged { self.render() }
            else { self.renderNotices() }
        }
    }

    private func select(_ newSection: Section) {
        section = newSection
        render()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func render() {
        guard isViewLoaded else { return }
        let previousScrollOrigin = scrollView.contentView.bounds.origin
        lastConfiguration = store.config
        lastDemoState = store.isDemo
        titleLabel.stringValue = section.rawValue
        subtitleLabel.stringValue = section.detail
        navButtons.forEach { item, button in
            button.isSelected = item == section
            switch item {
            case .accounts: button.badge = String(store.config.accounts.count)
            case .tools: button.badge = String(store.config.tools.count)
            default: button.badge = nil
            }
        }
        demoButton.title = store.isDemo ? "退出演示" : "浏览演示"
        clear(headerActions)
        clear(contentStack)
        intervalControl = nil
        thresholdControl = nil
        thresholdValueLabel = nil
        pinnedControl = nil
        renderNotices()
        switch section {
        case .overview:
            let refresh = actionButton(store.refreshing.isEmpty ? "立即刷新" : "读取中…") { [weak self] in
                guard let self else { return }
                Task { await self.store.refreshAll() }
            }
            refresh.isEnabled = store.refreshing.isEmpty
            headerActions.addArrangedSubview(refresh)
            headerActions.addArrangedSubview(addAccountButton())
            renderOverview()
        case .accounts:
            headerActions.addArrangedSubview(addAccountButton())
            renderAccounts()
        case .tools:
            headerActions.addArrangedSubview(presetPicker())
            renderTools()
        case .preferences:
            renderPreferences()
        }
        view.layoutSubtreeIfNeeded()
        let maximumY = max(0, contentStack.frame.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(maximumY, max(0, previousScrollOrigin.y))))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func renderNotices() {
        clear(noticeStack)
        if store.isDemo {
            let row = horizontalStack(spacing: 8)
            row.addArrangedSubview(label("演示模式 · 示例数据，仅供预览", size: 12, color: .systemOrange))
            row.addArrangedSubview(horizontalSpacer())
            row.addArrangedSubview(actionButton("退出演示") { [weak self] in self?.toggleDemo() })
            addFullWidth(row, to: noticeStack)
        }
        if let message = store.errorMessage {
            let row = horizontalStack(spacing: 8)
            let text = label(message, size: 11, color: .systemRed)
            text.maximumNumberOfLines = 4
            text.isSelectable = true
            row.addArrangedSubview(text)
            row.addArrangedSubview(actionButton("关闭提示") { [weak self] in self?.store.errorMessage = nil })
            addFullWidth(row, to: noticeStack)
        }
    }

    private func renderOverview() {
        let summary = "\(store.config.tools.count) 个工具    ·    \(store.enabledAccounts.count) 个启用账号    ·    每 \(Int(store.config.refreshInterval / 60)) 分钟刷新"
        addRow(label(summary, size: 12, color: .secondaryLabelColor), verticalPadding: 8)
        if store.config.accounts.isEmpty { renderWelcome(); return }
        for account in store.config.accounts {
            guard let tool = store.tool(for: account) else { continue }
            let row = verticalStack(spacing: 11)
            let heading = horizontalStack(spacing: 8)
            heading.addArrangedSubview(brandIcon(tool))
            heading.addArrangedSubview(label("\(tool.name) · \(store.accountName(for: account))", size: 13, weight: .semibold))
            if let plan = store.snapshots[account.id]?.planName {
                heading.addArrangedSubview(label(plan, size: 11, color: .secondaryLabelColor))
            }
            heading.addArrangedSubview(horizontalSpacer())
            if !account.isEnabled { heading.addArrangedSubview(label("已暂停", size: 11, color: .secondaryLabelColor)) }
            if store.refreshing.contains(account.id) {
                let progress = NSProgressIndicator()
                progress.style = .spinning
                progress.controlSize = .small
                progress.startAnimation(nil)
                heading.addArrangedSubview(progress)
            }
            let pinButton = actionButton(store.config.pinnedAccountID == account.id ? "取消固定" : "固定") { [weak self] in self?.togglePin(account) }
            pinButton.isEnabled = !store.isDemo && account.isEnabled
            heading.addArrangedSubview(pinButton)
            addFullWidth(heading, to: row)
            let metrics = store.snapshots[account.id]?.metrics ?? account.supplementalMetrics
            if metrics.isEmpty {
                row.addArrangedSubview(label(account.isEnabled ? (store.snapshots[account.id]?.notice ?? "等待首次读取额度") : "已暂停刷新", size: 11, color: .secondaryLabelColor))
            } else {
                addFullWidth(metricsTable(metrics, account: account), to: row)
            }
            if !metrics.isEmpty, let notice = store.snapshots[account.id]?.notice {
                let warning = label(notice, size: 11, color: .systemOrange)
                warning.maximumNumberOfLines = 3
                warning.lineBreakMode = .byWordWrapping
                addFullWidth(warning, to: row)
            }
            if let usage = store.snapshots[account.id]?.usageSummary {
                let summary = label(usage, size: 11, color: .secondaryLabelColor)
                summary.maximumNumberOfLines = 3
                summary.lineBreakMode = .byWordWrapping
                addFullWidth(summary, to: row)
            }
            if tool.provider == .manual {
                row.addArrangedSubview(label("手动记录", size: 10, color: .secondaryLabelColor))
            } else if let snapshot = store.snapshots[account.id] {
                row.addArrangedSubview(label("数据时间：\(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))", size: 10, color: .secondaryLabelColor))
            }
            if let error = store.errors[account.id] {
                row.addArrangedSubview(label(error, size: 11, color: .systemOrange))
                if store.snapshots[account.id] != nil {
                    row.addArrangedSubview(label("自动额度为上次成功读取的数据。", size: 10, color: .secondaryLabelColor))
                }
            }
            addRow(row)
        }
    }

    private func metricsTable(_ metrics: [QuotaMetric], account: Account) -> NSView {
        let table = verticalStack(spacing: 4)
        let header = horizontalStack(spacing: 12)
        let name = metricText("额度项目", size: 10, color: .secondaryLabelColor)
        header.addArrangedSubview(name)
        header.addArrangedSubview(horizontalSpacer())
        let remaining = metricText("剩余", size: 10, color: .secondaryLabelColor)
        remaining.alignment = .right
        remaining.widthAnchor.constraint(equalToConstant: 92).isActive = true
        header.addArrangedSubview(remaining)
        let reset = metricText("重置时间", size: 10, color: .secondaryLabelColor)
        reset.alignment = .right
        reset.widthAnchor.constraint(equalToConstant: 112).isActive = true
        header.addArrangedSubview(reset)
        addFullWidth(header, to: table)
        table.setCustomSpacing(8, after: header)

        let quotas = metrics.filter { !$0.isBalance && $0.category != .purchased }
        let balances = metrics.filter { $0.isBalance || $0.category == .purchased }
        for metric in quotas { addFullWidth(metricView(metric, account: account), to: table) }
        if !quotas.isEmpty && !balances.isEmpty {
            let divider = NSBox()
            divider.boxType = .separator
            addFullWidth(divider, to: table)
            table.setCustomSpacing(6, after: divider)
        }
        for metric in balances { addFullWidth(metricView(metric, account: account), to: table) }
        return table
    }

    private func metricText(_ text: String, size: CGFloat, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        field.toolTip = text
        return field
    }

    private func metricView(_ metric: QuotaMetric, account: Account) -> NSView {
        let row = horizontalStack(spacing: 12)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true
        let isSupplemental = account.supplementalMetrics.contains { $0.id == metric.id }
        let balance = metric.isBalance || metric.category == .purchased
        let annotation = (metric.category == .purchased ? " · 加购" : metric.isBalance ? " · 余额" : "") + (isSupplemental ? " · 手动" : "")
        let title = metricText(metric.label + annotation, size: 12)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(title)
        // Activate only after both views have a common ancestor.
        // Reserve identical columns on every row, including balance rows.
        title.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -(68 + 92 + 112 + 3 * 12)).isActive = true

        let low = !balance && !metric.isUnlimited && metric.remainingPercent <= store.config.lowQuotaThreshold
        let bar: NSView
        if balance || metric.isUnlimited { bar = NSView() }
        else {
            bar = OverviewQuotaBar(fraction: metric.remainingPercent / 100, low: low)
        }
        bar.widthAnchor.constraint(equalToConstant: 68).isActive = true
        bar.heightAnchor.constraint(equalToConstant: 5).isActive = true
        row.addArrangedSubview(bar)

        let value: String
        if metric.isUnlimited { value = "不限量" }
        else if balance { value = "\(number(metric.remaining)) \(metric.unit)" }
        else { value = "\(Int(metric.remainingPercent.rounded()))%" }
        let amount = metricText(value, size: 13, color: low ? .systemOrange : .labelColor)
        amount.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        amount.alignment = .right
        amount.widthAnchor.constraint(equalToConstant: 92).isActive = true
        amount.setAccessibilityLabel("剩余 \(value)")
        if !balance && !metric.isUnlimited && metric.unit != "%" {
            let quantity = "剩余 \(number(metric.remaining)) / \(number(metric.total)) \(metric.unit)"
            title.toolTip = metric.label + "\n" + quantity
            amount.toolTip = quantity
            amount.setAccessibilityLabel("剩余 \(value)，" + quantity)
        }
        row.addArrangedSubview(amount)

        let reset: NSTextField
        if let date = metric.resetsAt {
            let formatter = DateFormatter()
            formatter.dateFormat = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) ? "MM-dd HH:mm" : "yyyy-MM-dd HH:mm"
            reset = metricText(date > Date() ? formatter.string(from: date) : "等待更新", size: 11, color: .secondaryLabelColor)
            reset.toolTip = "重置：" + date.formatted(date: .complete, time: .shortened)
            reset.setAccessibilityLabel(reset.toolTip)
        } else {
            reset = metricText("—", size: 11, color: .tertiaryLabelColor)
            reset.toolTip = "未提供重置时间"
        }
        reset.alignment = .right
        reset.widthAnchor.constraint(equalToConstant: 112).isActive = true
        row.addArrangedSubview(reset)
        return row
    }

    private func renderAccounts() {
        if store.config.accounts.isEmpty { renderWelcome(); return }
        for account in store.config.accounts {
            guard let tool = store.tool(for: account) else { continue }
            let row = horizontalStack(spacing: 12)
            row.addArrangedSubview(brandIcon(tool))
            let labels = verticalStack(spacing: 5)
            let name = label("\(tool.name) · \(store.accountName(for: account))", size: 13, weight: .medium)
            name.setContentCompressionResistancePriority(.required, for: .vertical)
            name.setAccessibilityIdentifier("account-name-\(account.id.uuidString)")
            labels.addArrangedSubview(name)
            var details = [String]()
            if let email = store.snapshots[account.id]?.accountEmail { details.append(email) }
            if let plan = store.snapshots[account.id]?.planName { details.append("套餐：\(plan)") }
            if !account.subtitle.isEmpty { details.append(account.subtitle) }
            if details.isEmpty { details.append(tool.connectionTitle(for: tool.provider)) }
            labels.addArrangedSubview(label(details.joined(separator: " · "), size: 11, color: .secondaryLabelColor))
            row.addArrangedSubview(labels)
            row.addArrangedSubview(horizontalSpacer())
            row.addArrangedSubview(label(account.isEnabled ? "已启用" : "已暂停", size: 11, color: .secondaryLabelColor))
            let edit = actionButton("编辑") { [weak self] in self?.editAccount(account) }
            let delete = actionButton("删除") { [weak self] in self?.deleteAccount(account) }
            edit.isEnabled = !store.isDemo
            delete.isEnabled = !store.isDemo
            row.addArrangedSubview(edit)
            row.addArrangedSubview(delete)
            addRow(row)
        }
    }

    private func renderTools() {
        if store.config.tools.isEmpty { renderWelcome(); return }
        for tool in store.config.tools {
            let row = horizontalStack(spacing: 12)
            row.addArrangedSubview(brandIcon(tool))
            let labels = verticalStack(spacing: 5)
            labels.addArrangedSubview(label(tool.name, size: 13, weight: .medium))
            let accountCount = store.config.accounts.filter { $0.toolID == tool.id }.count
            labels.addArrangedSubview(label("\(tool.connectionTitle(for: tool.provider)) · \(accountCount) 个账号", size: 11, color: .secondaryLabelColor))
            row.addArrangedSubview(labels)
            row.addArrangedSubview(horizontalSpacer())
            let add = actionButton("添加账号") { [weak self] in self?.editAccount(Account(toolID: tool.id, name: "")) }
            let edit = actionButton("配置") { [weak self] in self?.editTool(tool) }
            let delete = actionButton("删除") { [weak self] in self?.deleteTool(tool) }
            for button in [add, edit, delete] { button.isEnabled = !store.isDemo; row.addArrangedSubview(button) }
            addRow(row)
        }
    }

    private func renderWelcome() {
        let welcome = verticalStack(spacing: 14)
        welcome.addArrangedSubview(label(store.config.tools.isEmpty ? "从第一个工具开始" : "添加你的第一个账号", size: 19, weight: .medium))
        welcome.addArrangedSubview(label("连接常用工具，同一工具可添加多个账号。\n订阅配额、加购额度和 API 余额各自展示。", size: 12, color: .secondaryLabelColor))
        let actions = horizontalStack(spacing: 10)
        actions.addArrangedSubview(presetPicker())
        if !store.config.tools.isEmpty { actions.addArrangedSubview(addAccountButton()) }
        actions.addArrangedSubview(actionButton("浏览演示") { [weak self] in self?.toggleDemo() })
        welcome.addArrangedSubview(actions)
        addRow(welcome, verticalPadding: 30)
    }

    private func renderPreferences() {
        let interval = NSPopUpButton()
        var intervals: [Double] = [60, 120, 300, 600, 900, 1800, 3600]
        if !intervals.contains(store.config.refreshInterval) { intervals.append(store.config.refreshInterval); intervals.sort() }
        for seconds in intervals {
            interval.addItem(withTitle: "每 \(number(seconds / 60)) 分钟")
            interval.lastItem?.representedObject = NSNumber(value: seconds)
        }
        interval.selectItem(at: intervals.firstIndex(of: store.config.refreshInterval) ?? 2)
        interval.isEnabled = !store.isDemo
        intervalControl = interval
        addRow(preferenceRow("自动刷新", control: interval))

        let threshold = NSSlider(value: store.config.lowQuotaThreshold, minValue: 0, maxValue: 100, target: self, action: #selector(thresholdChanged))
        threshold.isEnabled = !store.isDemo
        threshold.setAccessibilityLabel("低额度提示阈值")
        threshold.widthAnchor.constraint(equalToConstant: 210).isActive = true
        let thresholdValue = label("\(Int(store.config.lowQuotaThreshold))%", size: 12)
        thresholdValue.widthAnchor.constraint(equalToConstant: 42).isActive = true
        let thresholdRow = horizontalStack(spacing: 8)
        thresholdRow.addArrangedSubview(threshold)
        thresholdRow.addArrangedSubview(thresholdValue)
        thresholdControl = threshold
        thresholdValueLabel = thresholdValue
        addRow(preferenceRow("低额度提示", control: thresholdRow))

        let pinned = NSPopUpButton()
        pinned.addItem(withTitle: "仅显示图标")
        var choices = store.enabledAccounts
        if let id = store.config.pinnedAccountID, !choices.contains(where: { $0.id == id }),
           let paused = store.config.accounts.first(where: { $0.id == id }) { choices.append(paused) }
        for account in choices {
            pinned.addItem(withTitle: "\(store.tool(for: account)?.name ?? "") · \(store.accountName(for: account))\(account.isEnabled ? "" : "（已暂停）")")
            pinned.lastItem?.representedObject = account.id.uuidString
            if store.config.pinnedAccountID == account.id { pinned.selectItem(at: pinned.numberOfItems - 1) }
        }
        pinned.isEnabled = !store.isDemo
        pinned.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
        pinnedControl = pinned
        addRow(preferenceRow("菜单栏固定账号", control: pinned))
        addRow(label("低额度提示仅用于有总量的订阅或用量配额。加购额度与余额独立显示，不参与低额度百分比提醒。", size: 11, color: .secondaryLabelColor))
        let save = actionButton("保存设置") { [weak self] in self?.savePreferences() }
        save.bezelStyle = .rounded
        save.isEnabled = !store.isDemo
        let saveRow = horizontalStack(spacing: 0)
        saveRow.addArrangedSubview(save)
        saveRow.addArrangedSubview(horizontalSpacer())
        addRow(saveRow)
        let privacy = verticalStack(spacing: 9)
        privacy.addArrangedSubview(label("数据与隐私", size: 13, weight: .semibold))
        let text = label("配置：~/Library/Application Support/QuotaDock/config.json\n凭据：macOS 钥匙串，按账号隔离保存。\n不自动收集浏览器 Cookie，不上传账号配置。", size: 11, color: .secondaryLabelColor)
        text.isSelectable = true
        privacy.addArrangedSubview(text)
        addRow(privacy)
    }

    @objc private func thresholdChanged() {
        thresholdValueLabel?.stringValue = "\(Int(thresholdControl?.doubleValue.rounded() ?? 0))%"
    }

    private func savePreferences() {
        guard let interval = intervalControl?.selectedItem?.representedObject as? NSNumber,
              let threshold = thresholdControl else { return }
        let pin = (pinnedControl?.selectedItem?.representedObject as? String).flatMap(UUID.init(uuidString:))
        attempt {
            try store.updatePreferences(refreshInterval: interval.doubleValue, lowQuotaThreshold: threshold.doubleValue.rounded(), pinnedAccountID: pin)
        }
    }

    private func togglePin(_ account: Account) {
        attempt {
            try store.updatePreferences(refreshInterval: store.config.refreshInterval, lowQuotaThreshold: store.config.lowQuotaThreshold,
                pinnedAccountID: store.config.pinnedAccountID == account.id ? nil : account.id)
        }
    }

    private func toggleDemo() {
        store.setDemo(!store.isDemo)
        render()
    }

    private func addAccountButton() -> NSButton {
        let button = actionButton("添加账号") { [weak self] in
            guard let self else { return }
            guard let tool = self.store.config.tools.first else { self.select(.tools); return }
            self.editAccount(Account(toolID: tool.id, name: ""))
        }
        button.isEnabled = !store.isDemo
        return button
    }

    private func presetPicker() -> NSPopUpButton {
        let picker = NSPopUpButton(frame: .zero, pullsDown: true)
        picker.addItem(withTitle: "添加工具")
        picker.menu?.autoenablesItems = false
        for (index, preset) in PresetCatalog.items.enumerated() {
            let candidate = preset.makeTool()
            let exists = store.config.tools.contains { $0.representsSameTool(as: candidate) }
            let title = exists ? "\(preset.name) · 已添加" : "\(preset.name) · \(preset.method)"
            let item = NSMenuItem(title: title, action: #selector(addPreset(_:)), keyEquivalent: "")
            item.isEnabled = !exists
            item.target = self
            item.representedObject = NSNumber(value: index)
            picker.menu?.addItem(item)
        }
        picker.menu?.addItem(.separator())
        let custom = NSMenuItem(title: "自定义工具…", action: #selector(addPreset(_:)), keyEquivalent: "")
        custom.target = self
        custom.representedObject = NSNumber(value: -1)
        picker.menu?.addItem(custom)
        picker.isEnabled = !store.isDemo
        return picker
    }

    @objc private func addPreset(_ sender: NSMenuItem) {
        guard let index = (sender.representedObject as? NSNumber)?.intValue else { return }
        let candidate = index >= 0 && index < PresetCatalog.items.count ? PresetCatalog.items[index].makeTool() : ToolDefinition(name: "", provider: .httpJSON)
        // An already-open menu can become stale after configuration changes.
        if let existing = store.config.tools.first(where: { $0.representsSameTool(as: candidate) }) {
            editTool(existing)
        } else {
            editTool(candidate)
        }
    }

    private func editTool(_ tool: ToolDefinition) {
        guard !store.isDemo, presentedEditor == nil else { return }
        let editor = ToolEditorController(store: store, tool: tool) { [weak self] in self?.finishEditor() }
        presentedEditor = editor
        presentAsSheet(editor)
    }

    private func editAccount(_ account: Account) {
        guard !store.isDemo, presentedEditor == nil else { return }
        let editor = AccountEditorController(store: store, account: account) { [weak self] in self?.finishEditor() }
        presentedEditor = editor
        presentAsSheet(editor)
    }

    private func finishEditor() {
        if let editor = presentedEditor { dismiss(editor) }
        presentedEditor = nil
        render()
    }

    private func deleteAccount(_ account: Account) {
        confirmDeletion(title: "删除账号“\(store.accountName(for: account))”？", detail: "将删除 QuotaDock 中的账号记录与对应 API 凭据，不影响服务商账号或其他应用的登录状态。") { [weak self] in
            guard let self else { return }
            self.attempt { try self.store.deleteAccount(id: account.id) }
        }
    }

    private func deleteTool(_ tool: ToolDefinition) {
        let count = store.config.accounts.filter { $0.toolID == tool.id }.count
        confirmDeletion(title: "删除工具“\(tool.name)”？", detail: "将同时删除该工具下的 \(count) 个账号配置和对应 API 凭据。") { [weak self] in
            guard let self else { return }
            self.attempt { try self.store.deleteTool(id: tool.id) }
        }
    }

    private func confirmDeletion(title: String, detail: String, action: @escaping () -> Void) {
        guard !store.isDemo else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.buttons[1].keyEquivalent = "\u{1b}"
        if let window = view.window {
            alert.beginSheetModal(for: window) { response in if response == .alertFirstButtonReturn { action() } }
        } else if alert.runModal() == .alertFirstButtonReturn { action() }
    }

    private func attempt(_ action: () throws -> Void) {
        do { try action(); render() }
        catch { store.errorMessage = error.localizedDescription; renderNotices() }
    }

    private func preferenceRow(_ title: String, control: NSView) -> NSView {
        let row = horizontalStack(spacing: 16)
        let text = label(title, size: 12)
        text.widthAnchor.constraint(equalToConstant: 120).isActive = true
        row.addArrangedSubview(text)
        row.addArrangedSubview(control)
        row.addArrangedSubview(horizontalSpacer())
        return row
    }

    private func addRow(_ child: NSView, verticalPadding: CGFloat = 16) {
        let wrapper = NSView()
        child.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 2),
            child.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -2),
            child.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: verticalPadding),
            child.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -verticalPadding),
        ])
        addFullWidth(wrapper, to: contentStack)
        let separator = NSBox()
        separator.boxType = .separator
        addFullWidth(separator, to: contentStack)
    }

    private func addFullWidth(_ child: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(child)
        child.translatesAutoresizingMaskIntoConstraints = false
        child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func clear(_ stack: NSStackView) {
        for child in stack.arrangedSubviews { stack.removeArrangedSubview(child); child.removeFromSuperview() }
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func brandIcon(_ tool: ToolDefinition) -> NSImageView {
        let image = ToolBranding.makeView(for: tool, size: 22)
        image.widthAnchor.constraint(equalToConstant: 22).isActive = true
        image.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return image
    }

    private func verticalStack(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func horizontalStack(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    private func horizontalSpacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return spacer
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> ManagementActionButton {
        ManagementActionButton(title: title, handler: action)
    }

    private func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private func pin(_ child: NSView, to parent: NSView, inset: CGFloat) {
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset),
        ])
    }
}

@MainActor
private final class ManagementActionButton: NSButton {
    var handler: (() -> Void)?

    init(title: String, handler: (() -> Void)? = nil) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self
        action = #selector(invoke)
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler?() }
}

private final class ManagementDocumentStack: NSStackView {
    override var isFlipped: Bool { true }
}


/// Decorative progress only; the adjacent text exposes the exact remaining value.
@MainActor
private final class OverviewQuotaBar: NSView {
    private let fraction: Double
    private let low: Bool

    init(fraction: Double, low: Bool) {
        self.fraction = min(1, max(0, fraction))
        self.low = low
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2.5, yRadius: 2.5).fill()
        guard fraction > 0 else { return }
        (low ? NSColor.systemOrange : NSColor.systemTeal).setFill()
        let fill = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width * fraction, height: bounds.height)
        NSBezierPath(roundedRect: fill, xRadius: 2.5, yRadius: 2.5).fill()
    }
}
