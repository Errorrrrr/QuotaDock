import AppKit
import QuotaDockCore

@MainActor
final class ToolEditorController: NSViewController {
    private let store: AppStore
    private var tool: ToolDefinition
    private let onComplete: () -> Void
    private let nameField = NSTextField(string: "")
    private let providerPicker = NSPopUpButton()
    private var availableProviders: [ProviderKind] = []
    private let advancedButton = NSButton(checkboxWithTitle: "高级接口设置", target: nil, action: nil)
    private let endpointField = NSTextField(string: "")
    private let headerField = NSTextField(string: "")
    private let prefixField = NSTextField(string: "")
    private let helpLabel = EditorForm.note("")
    private let errorLabel = EditorForm.errorLabel()
    private let httpContent = EditorForm.column()
    private let mappingStack = EditorForm.column()
    private var mappingRows: [MappingEditorRow] = []

    init(store: AppStore, tool: ToolDefinition, onComplete: @escaping () -> Void) {
        self.store = store
        self.tool = tool
        self.tool.brandID = tool.resolvedBrandID
        self.onComplete = onComplete
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        nameField.stringValue = tool.name
        nameField.placeholderString = "例如：Codex / DeepSeek"
        availableProviders = tool.availableProviders
        providerPicker.addItems(withTitles: availableProviders.map { tool.connectionTitle(for: $0) })
        providerPicker.selectItem(at: availableProviders.firstIndex(of: tool.provider) ?? 0)
        providerPicker.target = self
        providerPicker.action = #selector(providerChanged)
        endpointField.stringValue = tool.http.endpoint
        endpointField.placeholderString = "https://api.example.com/usage/{accountId}"
        headerField.stringValue = tool.http.authHeader
        prefixField.stringValue = tool.http.authPrefix

        let content = EditorForm.column()
        EditorForm.add(EditorForm.row("工具名称", nameField), to: content)
        EditorForm.add(EditorForm.row("接入方式", providerPicker), to: content)
        EditorForm.add(helpLabel, to: content)
        if !availableProviders.contains(tool.provider) {
            EditorForm.add(EditorForm.note("原接入方式不适用于此工具。请选择上方可用方式，保存后生效。"), to: content)
        }
        if let cli = PresetCatalog.cliInformation(for: tool) {
            EditorForm.add(EditorForm.group(cli.title, EditorForm.note(cli.detail)), to: content)
        }
        advancedButton.target = self
        advancedButton.action = #selector(updateHTTPVisibility)
        advancedButton.state = tool.hasOfficialHTTPPreset ? .off : .on
        EditorForm.add(advancedButton, to: content, stretch: false)

        let request = EditorForm.column()
        EditorForm.add(EditorForm.row("HTTPS 接口地址", endpointField), to: request)
        EditorForm.add(EditorForm.row("认证请求头", headerField), to: request)
        EditorForm.add(EditorForm.row("认证前缀", prefixField), to: request)
        EditorForm.add(EditorForm.note("仅发送 GET 请求。认证前缀请保留尾部空格，例如“Bearer ”。密钥在账号中分别设置，请勿放进 URL。{accountId} 会替换为接口账号标识。"), to: request)
        if store.config.tools.contains(where: { $0.id == tool.id }) {
            EditorForm.add(EditorForm.note("修改接口主机、协议或端口后，此工具各账号的旧凭据会被清除，需重新填写。"), to: request)
        }
        EditorForm.add(EditorForm.group("请求设置", request), to: httpContent)

        for mapping in tool.http.mappings { addMapping(mapping) }
        if mappingRows.isEmpty { addMapping(.init()) }
        let mappingContent = EditorForm.column()
        EditorForm.add(mappingStack, to: mappingContent)
        EditorForm.add(EditorActionButton("添加额度窗口") { [weak self] in self?.addMapping(.init(label: "新窗口")) }, to: mappingContent, stretch: false)
        EditorForm.add(EditorForm.note("JSON 路径用点分隔，数组使用数字下标，例如 data.limits.0.used。支持数字字符串；重置时间支持 ISO 8601 或 Unix 时间。余额只有剩余数值，不会与套餐百分比合并。"), to: mappingContent)
        EditorForm.add(EditorForm.group("JSON 字段映射", mappingContent), to: httpContent)
        EditorForm.add(httpContent, to: content)

        let title = store.config.tools.contains(where: { $0.id == tool.id }) ? "配置工具" : "添加工具"
        view = EditorForm.sheet(title: title, content: content, error: errorLabel,
            saveTitle: "保存工具", cancel: { [weak self] in self?.onComplete() }, save: { [weak self] in self?.save() })
        preferredContentSize = NSSize(width: 610, height: 650)
        providerChanged()
    }

    @objc private func providerChanged() {
        let index = providerPicker.indexOfSelectedItem
        guard availableProviders.indices.contains(index) else { return }
        tool.provider = availableProviders[index]
        updateHTTPVisibility()
        helpLabel.stringValue = PresetCatalog.explanation(for: tool.provider)
    }

    @objc private func updateHTTPVisibility() {
        advancedButton.isHidden = tool.provider != .httpJSON || !tool.hasOfficialHTTPPreset
        httpContent.isHidden = tool.provider != .httpJSON || (tool.hasOfficialHTTPPreset && advancedButton.state != .on)
    }

    private func addMapping(_ mapping: QuotaMapping) {
        let row = MappingEditorRow(mapping: mapping)
        row.onRemove = { [weak self, weak row] in
            guard let self, let row, self.mappingRows.count > 1 else { return }
            self.mappingRows.removeAll { $0 === row }
            self.mappingStack.removeArrangedSubview(row)
            row.removeFromSuperview()
            self.updateMappingRemoval()
        }
        mappingRows.append(row)
        EditorForm.add(row, to: mappingStack)
        updateMappingRemoval()
    }

    private func updateMappingRemoval() {
        mappingRows.forEach { $0.removeButton.isEnabled = mappingRows.count > 1 }
    }

    private func save() {
        view.window?.makeFirstResponder(nil)
        do {
            var updated = tool
            updated.brandID = ToolBranding.brandID(for: tool)
            updated.name = try EditorForm.required(nameField.stringValue, label: "工具名称")
            updated.http.endpoint = endpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.http.authHeader = headerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.http.authPrefix = prefixField.stringValue
            if updated.provider == .httpJSON {
                updated.http.mappings = try mappingRows.map { try $0.value() }
            }
            try store.saveTool(updated)
            onComplete()
        } catch { EditorForm.show(error, in: errorLabel) }
    }
}

@MainActor
final class AccountEditorController: NSViewController {
    private let store: AppStore
    private var account: Account
    private let onComplete: () -> Void
    private let isExisting: Bool
    private let availableTools: [ToolDefinition]
    private let advancedContent = EditorForm.column()
    private let quickNote = EditorForm.note("")
    private let advancedButton = NSButton(title: "高级设置…", target: nil, action: nil)
    private let activity = EditorForm.note("")
    private var connectionTask: Task<Void, Never>?
    private var primaryButton: NSButton?
    private var advancedExpanded = false
    private let toolPicker = NSPopUpButton()
    private let menuBarMetricPicker = NSPopUpButton()
    private let nameField = NSTextField(string: "")
    private let subtitleField = NSTextField(string: "")
    private let enabledButton = NSButton(checkboxWithTitle: "启用自动刷新与菜单栏展示", target: nil, action: nil)
    private let externalField = NSTextField(string: "")
    private let fallbackField = NSTextField(string: "")
    private var fallbackRow: NSView?
    private let externalLabel = NSTextField(labelWithString: "")
    private let providerNote = EditorForm.note("")
    private let tokenField = NSSecureTextField(string: "")
    private let tokenLabel = NSTextField(labelWithString: "API 密钥 / Token")
    private let removeTokenButton = NSButton(checkboxWithTitle: "移除已保存的凭据", target: nil, action: nil)
    private let credentials = EditorForm.column()
    private let credentialNote = EditorForm.note("")
    private let manualContent = EditorForm.column()
    private let manualStack = EditorForm.column()
    private let supplementalStack = EditorForm.column()
    private let errorLabel = EditorForm.errorLabel()
    private var externalRow: NSView?
    private var manualRows: [MetricEditorRow] = []
    private var supplementalRows: [MetricEditorRow] = []

    init(store: AppStore, account: Account, onComplete: @escaping () -> Void) {
        self.store = store
        self.account = account
        self.onComplete = onComplete
        self.isExisting = store.config.accounts.contains { $0.id == account.id }
        self.availableTools = store.config.tools
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var selectedTool: ToolDefinition? {
        availableTools.first { $0.id == account.toolID }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        connectionTask?.cancel()
    }

    override func loadView() {
        toolPicker.addItems(withTitles: availableTools.map(\.name))
        if let index = availableTools.firstIndex(where: { $0.id == account.toolID }) {
            toolPicker.selectItem(at: index)
        } else if let first = availableTools.first {
            account.toolID = first.id
            toolPicker.selectItem(at: 0)
        }
        toolPicker.isEnabled = !isExisting
        toolPicker.target = self
        toolPicker.action = #selector(toolChanged)
        nameField.stringValue = account.name
        nameField.placeholderString = "例如：个人账号 / 工作账号"
        subtitleField.stringValue = account.subtitle
        subtitleField.placeholderString = "例如：Pro · 团队 A"
        enabledButton.state = account.isEnabled ? .on : .off
        externalField.stringValue = account.externalID
        fallbackField.stringValue = account.fallbackSnapshotPath ?? ""
        fallbackField.placeholderString = "可选：同一账号的 statusLine JSON 文件"
        tokenField.placeholderString = "留空保留已有凭据"
        tokenField.toolTip = "凭据仅保存在系统钥匙串，不显示已保存的内容。"
        removeTokenButton.target = self
        removeTokenButton.action = #selector(removeTokenChanged)

        let content = EditorForm.column()
        EditorForm.add(EditorForm.row("所属工具", toolPicker), to: content)
        EditorForm.add(quickNote, to: content)
        advancedButton.bezelStyle = .recessed
        advancedButton.target = self
        advancedButton.action = #selector(toggleAdvanced)
        EditorForm.add(advancedButton, to: content, stretch: false)
        EditorForm.add(advancedContent, to: content)
        EditorForm.add(activity, to: content)
        activity.isHidden = true
        EditorForm.add(EditorForm.row("账号别名（可选）", nameField), to: advancedContent)
        if let snapshot = store.snapshots[account.id] {
            let identity = [snapshot.accountName, snapshot.accountEmail].compactMap { $0 }.joined(separator: " · ")
            if !identity.isEmpty { EditorForm.add(EditorForm.row("已登录账号", EditorForm.note(identity)), to: advancedContent) }
        }
        EditorForm.add(EditorForm.note("支持读取账号信息的工具优先显示真实账号；读取不到时使用此别名。"), to: advancedContent)
        EditorForm.add(EditorForm.row("备注", subtitleField), to: advancedContent)
        EditorForm.add(enabledButton, to: advancedContent, stretch: false)
        EditorForm.add(EditorForm.row("菜单栏显示额度", menuBarMetricPicker), to: advancedContent)
        EditorForm.add(EditorForm.note("固定此账号后生效；也可在菜单栏弹窗点击图钉选择。已选额度暂未返回时显示 —。"), to: advancedContent)
        let identity = EditorForm.row(externalLabel, externalField)
        externalRow = identity
        EditorForm.add(identity, to: advancedContent)
        let fallback = EditorForm.row("备用快照路径", fallbackField)
        fallbackRow = fallback
        EditorForm.add(fallback, to: advancedContent)
        EditorForm.add(providerNote, to: advancedContent)
        EditorForm.add(EditorActionButton("打开 CLI 接入说明") {
            if let url = Bundle.main.resourceURL?.appendingPathComponent("Integration/CLI-CONNECTIONS.md"), FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.open(url)
            } else {
                let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                NSWorkspace.shared.open(source.appendingPathComponent("docs/CLI-CONNECTIONS.md"))
            }
        }, to: advancedContent, stretch: false)

        EditorForm.add(EditorForm.row(tokenLabel, tokenField), to: credentials)
        EditorForm.add(removeTokenButton, to: credentials, stretch: false)
        EditorForm.add(credentialNote, to: credentials)
        EditorForm.add(credentials, to: content)

        EditorForm.add(EditorForm.note("这是手动记录，不会自动获取服务商数据。"), to: manualContent)
        for metric in account.manualMetrics { addManual(metric) }
        if manualRows.isEmpty { addManual(.init(label: "额度", used: 0, total: 100)) }
        EditorForm.add(manualStack, to: manualContent)
        EditorForm.add(EditorActionButton("添加额度窗口") { [weak self] in
            self?.addManual(.init(label: "新窗口", used: 0, total: 100))
        }, to: manualContent, stretch: false)
        EditorForm.add(manualContent, to: advancedContent)

        let extras = EditorForm.column()
        EditorForm.add(EditorForm.note("服务未提供自动加购余额时，可单独记录。订阅与加购额度分别展示，不合并计算。已自动读取的余额无需重复添加。"), to: extras)
        for metric in account.supplementalMetrics { addSupplemental(metric) }
        EditorForm.add(supplementalStack, to: extras)
        EditorForm.add(EditorActionButton("添加加购额度") { [weak self] in
            self?.addSupplemental(.init(label: "加购额度", used: 0, total: 0, unit: "点数", remainingBalance: 0, category: .purchased))
        }, to: extras, stretch: false)
        EditorForm.add(EditorForm.group("额外购买额度 · 手动补充", extras), to: advancedContent)

        view = EditorForm.sheet(title: isExisting ? "编辑账号" : "添加账号", content: content, error: errorLabel,
            saveTitle: "保存账号", cancel: { [weak self] in
                self?.connectionTask?.cancel()
                self?.onComplete()
            }, save: { [weak self] in self?.save() }, configureSaveButton: { [weak self] in self?.primaryButton = $0 })
        preferredContentSize = NSSize(width: 610, height: 650)
        updateProviderFields()
    }

    @objc private func toggleAdvanced() {
        advancedExpanded.toggle()
        updatePresentation()
    }

    private func updatePresentation() {
        let quick = !isExisting && selectedTool?.provider.supportsDefaultLogin == true
        advancedButton.isHidden = !quick
        quickNote.isHidden = !quick
        advancedContent.isHidden = quick && !advancedExpanded
        advancedButton.title = advancedExpanded ? "收起高级设置" : "高级设置 · 其他账号 / 备用快照"
        quickNote.stringValue = selectedTool?.provider == .deepseekCLI
            ? "可直接填写 API Key，仅保存到 QuotaDock 钥匙串；未填写时读取本地 Harness 配置。"
            : selectedTool?.provider == .antigravityDesktop
            ? "请先打开并登录 Antigravity 桌面应用，点击即可读取账号、套餐和额度。"
            : selectedTool?.provider == .antigravityCLI
            ? "直接读取 Antigravity 当前登录账号，无需填写名称或凭据。"
            : "直接读取此工具已登录的账号，无需填写名称或凭据。其他账号可在高级设置中选择登录目录。"
        nameField.placeholderString = selectedTool?.provider.supportsDefaultLogin == true ? "留空使用识别到的账号名" : "可选：个人账号 / 工作账号"
        primaryButton?.title = quick ? "读取并添加" : (isExisting ? "保存账号" : "添加账号")
        preferredContentSize = NSSize(width: 610, height: quick && !advancedExpanded ? (selectedTool?.provider == .deepseekCLI ? 440 : 280) : 650)
    }

    @objc private func toolChanged() {
        guard !isExisting, availableTools.indices.contains(toolPicker.indexOfSelectedItem) else { return }
        let selected = availableTools[toolPicker.indexOfSelectedItem]
        if selected.id != account.toolID {
            advancedExpanded = false
            account.toolID = selected.id
            // A newly entered token or account identifier must not migrate to
            // another provider when its tool picker changes.
            externalField.stringValue = ""
            fallbackField.stringValue = ""
            tokenField.stringValue = ""
            removeTokenButton.state = .off
            tokenField.isEnabled = true
        }
        updateProviderFields()
    }

    @objc private func removeTokenChanged() {
        tokenField.isEnabled = removeTokenButton.state != .on
    }

    private func updateProviderFields() {
        guard let tool = selectedTool else {
            providerNote.stringValue = "请先添加一个工具，再配置账号。"
            credentials.isHidden = true
            manualContent.isHidden = true
            externalRow?.isHidden = true
            return
        }
        credentials.isHidden = ![.httpJSON, .kimiCLI, .deepseekCLI].contains(tool.provider)
        removeTokenButton.isHidden = !isExisting
        removeTokenButton.title = tool.provider == .deepseekCLI ? "移除已保存的 Key，改用本地 Harness" : "移除已保存的凭据"
        tokenField.placeholderString = tool.provider == .deepseekCLI
            ? (isExisting ? "留空保留已有 Key；未保存过则读取 Harness" : "可选：留空读取本地 Harness")
            : "留空保留已有凭据"
        manualContent.isHidden = tool.provider != .manual
        externalRow?.isHidden = [.manual, .antigravityCLI, .antigravityDesktop].contains(tool.provider)
        fallbackRow?.isHidden = ![.claudeOAuth, .antigravityCLI].contains(tool.provider)
        switch tool.provider {
        case .codexCLI:
            externalLabel.stringValue = "CODEX_HOME"
            externalField.placeholderString = "留空使用默认 ~/.codex"
            providerNote.stringValue = "读取 Codex CLI 已登录账号的额度。多账号需使用分别登录的 CODEX_HOME 目录；同一目录对应同一账号。本工具不会自动登录或切换账号。"
        case .claudeOAuth:
            externalLabel.stringValue = "CLAUDE_CONFIG_DIR"
            externalField.placeholderString = "留空读取 CLI 默认登录（通常 ~/.claude）"
            providerNote.stringValue = "复用此目录的 Claude OAuth 登录，自动查询额度；多账号需分别登录。可选同账号快照备用，需先配置桥接脚本。过期登录由官方 CLI 更新；后台不弹出钥匙串授权窗口。"
        case .antigravityDesktop:
            providerNote.stringValue = "跟随官方桌面应用当前登录，仅支持一个账号。只读查询昵称、套餐和额度，不读取钥匙串；本机会话令牌仅在内存使用，不保存、不输出。需保持桌面应用运行，不自动改用 CLI 登录。"
        case .antigravityCLI:
            providerNote.stringValue = "使用 agy 当前登录账号，定时只读查询额度及 AI Credits；不启动模型对话。跟随 CLI 登录切换，仅支持一个自动查询账号。独立多账号请使用快照接入，备用快照也必须对应当前账号。"
        case .claudeSnapshot:
            externalLabel.stringValue = "快照文件路径"
            externalField.placeholderString = "~/.local/share/quotadock/claude-personal.json"
            providerNote.stringValue = "使用随附 claude-statusline.py 保存 Claude Code 状态栏快照。每个账号应使用独立文件，仅在 Claude 会话更新时更新；配置方法见 README。"
        case .antigravitySnapshot:
            externalLabel.stringValue = "快照文件路径"
            externalField.placeholderString = "~/.local/share/quotadock/antigravity-personal.json"
            providerNote.stringValue = "使用随附 antigravity-statusline.py 保存 agy 官方状态栏快照，每个账号使用独立文件。只显示 CLI 实际返回的额度；配置示例见接入说明。"
        case .kimiCLI:
            externalLabel.stringValue = "CLI 本地服务地址"
            externalField.placeholderString = "http://127.0.0.1:58627"
            providerNote.stringValue = "先在对应账号运行 kimi web --no-open，填写启动时显示的地址。多个账号需分别登录和启动本地服务，不能只填写不同别名。"
            tokenLabel.stringValue = "本地服务 Token"
            tokenField.setAccessibilityLabel(tokenLabel.stringValue)
            credentialNote.stringValue = "填写启动时提供的 Token（不是 API Key），存入系统钥匙串，仅发送到填写的回环地址。地址或端口变更需重新填写。"
        case .copilotCLI:
            externalLabel.stringValue = "COPILOT_HOME"
            externalField.placeholderString = "留空使用默认 ~/.copilot"
            providerNote.stringValue = "使用官方 CLI 读取账号额度。多账号需选择各自已登录的配置目录；不启动模型会话。"
        case .cursorCLI:
            externalLabel.stringValue = "CLI 登录文件"
            externalField.placeholderString = "留空使用 ~/.cursor/auth.json"
            providerNote.stringValue = "读取此文件对应账号的服务端额度和姓名。多账号使用各自的 auth.json；登录过期时请在 Cursor CLI 重新登录。"
        case .qwenCLI:
            externalLabel.stringValue = "QWEN_HOME"
            externalField.placeholderString = "留空使用默认 ~/.qwen"
            providerNote.stringValue = "读取 settings.json 与已保存的本机用量。Qwen 未提供账号剩余额度；同目录历史可能跨账号，多账号应使用独立目录。"
        case .oriCLI:
            externalLabel.stringValue = "CLI 登录文件"
            externalField.placeholderString = "留空使用 ~/.ori/credentials.json"
            providerNote.stringValue = "使用 Ori 明文登录记录读取密钥限额，兼容旧版 ~/.openrouter/credentials.json。加密/OIDC 登录暂不支持；密钥限额不是账户余额。"
        case .deepseekCLI:
            externalLabel.stringValue = "DSH_HOME"
            externalField.placeholderString = "留空使用默认 ~/.dsh"
            providerNote.stringValue = "未保存 Key 时，从此目录的 .credentials.yaml 或 .env 读取凭据。仅只读访问，不修改 Harness 配置；暂不支持浏览器登录记录。"
            tokenLabel.stringValue = "DeepSeek API Key（可选）"
            tokenField.setAccessibilityLabel(tokenLabel.stringValue)
            credentialNote.stringValue = "填写后优先使用此 Key，仅保存到 QuotaDock 钥匙串并发送至 api.deepseek.com。各账号独立保存，不影响 Harness。"
        case .glmCLI:
            externalLabel.stringValue = "CLI 配置文件"
            externalField.placeholderString = "~/.claude-glm/settings.json"
            providerNote.stringValue = "选择已配置 GLM 的 Claude Code settings.json（env 内含 ANTHROPIC_BASE_URL 和 ANTHROPIC_AUTH_TOKEN）。仅向配置对应的智谱/Z.ai 官方主机查询套餐额度，不发送到自定义代理。多账号使用独立配置文件。"
        case .httpJSON:
            externalRow?.isHidden = !tool.http.endpoint.contains("{accountId}")
            tokenLabel.stringValue = tool.hasOfficialHTTPPreset ? (tool.resolvedBrandID == "openrouter" ? "Management API Key" : "DeepSeek API Key") : "API 密钥 / Token"
            externalLabel.stringValue = "接口账号标识"
            externalField.placeholderString = "可选，用于替换接口中的 {accountId}"
            providerNote.stringValue = "每个账号单独保存凭据；已有账号不能改到其他工具。"
            let host = URL(string: tool.http.endpoint)?.host ?? "配置的接口主机"
            credentialNote.stringValue = "凭据仅保存在系统钥匙串，请求将发送至 \(host)。" + (tool.resolvedBrandID == "openrouter" ? " 此余额接口需要 Management API Key，普通推理 API Key 不适用。" : "")
        case .manual:
            providerNote.stringValue = "可分别维护多个额度窗口，手动输入服务商显示的数值。"
        }
        externalField.setAccessibilityLabel(externalLabel.stringValue)
        updateMetricPicker()
        updatePresentation()
    }

    private func updateMetricPicker() {
        menuBarMetricPicker.removeAllItems()
        menuBarMetricPicker.addItem(withTitle: "自动 · 剩余最少的窗口")
        let metrics = store.snapshots[account.id]?.metrics
            ?? ((selectedTool?.provider == .manual ? account.manualMetrics : []) + account.supplementalMetrics)
        for metric in metrics {
            menuBarMetricPicker.addItem(withTitle: metric.label)
            menuBarMetricPicker.lastItem?.representedObject = metric.id
            if metric.id == account.menuBarMetricID { menuBarMetricPicker.select(menuBarMetricPicker.lastItem) }
        }
        if let selected = account.menuBarMetricID, !metrics.contains(where: { $0.id == selected }) {
            menuBarMetricPicker.addItem(withTitle: "已选额度（暂未返回）")
            menuBarMetricPicker.lastItem?.representedObject = selected
            menuBarMetricPicker.select(menuBarMetricPicker.lastItem)
        }
    }

    private func addManual(_ metric: QuotaMetric) {
        let row = MetricEditorRow(metric: metric, supplemental: false)
        row.onRemove = { [weak self, weak row] in
            guard let self, let row, self.manualRows.count > 1 else { return }
            self.manualRows.removeAll { $0 === row }
            self.manualStack.removeArrangedSubview(row)
            row.removeFromSuperview()
            self.manualRows.forEach { $0.removeButton.isEnabled = self.manualRows.count > 1 }
        }
        manualRows.append(row)
        EditorForm.add(row, to: manualStack)
        manualRows.forEach { $0.removeButton.isEnabled = manualRows.count > 1 }
    }

    private func addSupplemental(_ metric: QuotaMetric) {
        let row = MetricEditorRow(metric: metric, supplemental: true)
        row.onRemove = { [weak self, weak row] in
            guard let self, let row else { return }
            self.supplementalRows.removeAll { $0 === row }
            self.supplementalStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        supplementalRows.append(row)
        EditorForm.add(row, to: supplementalStack)
    }

    private func setAdvancedControlsEnabled(_ enabled: Bool) {
        func update(_ view: NSView) {
            if let control = view as? NSControl { control.isEnabled = enabled }
            view.subviews.forEach(update)
        }
        update(advancedContent)
        update(credentials)
        advancedButton.isEnabled = enabled
    }

    private func save() {
        guard connectionTask == nil else { return }
        view.window?.makeFirstResponder(nil)
        do {
            guard let tool = selectedTool else { throw EditorInputError.message("请先选择一个已配置的工具。") }
            var updated = account
            let alias = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if alias.isEmpty {
                let names = Set(store.config.accounts.filter { $0.toolID == tool.id }.map(\.name))
                var number = 1
                while names.contains("账号 \(number)") { number += 1 }
                updated.name = "账号 \(number)"
            } else { updated.name = alias }
            updated.subtitle = subtitleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.isEnabled = enabledButton.state == .on
            updated.menuBarMetricID = menuBarMetricPicker.selectedItem?.representedObject as? String
            updated.externalID = [.antigravityCLI, .antigravityDesktop].contains(tool.provider) ? "" : externalField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.fallbackSnapshotPath = [.claudeOAuth, .antigravityCLI].contains(tool.provider) ? fallbackField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            if tool.provider == .manual { updated.manualMetrics = try manualRows.map { try $0.value() } }
            updated.supplementalMetrics = try supplementalRows.map { try $0.value() }
            let token: String?
            if [.httpJSON, .kimiCLI, .deepseekCLI].contains(tool.provider) {
                token = removeTokenButton.state == .on ? "" : (tokenField.stringValue.isEmpty ? nil : tokenField.stringValue)
            } else {
                token = nil
            }
            if !isExisting && tool.provider.supportsDefaultLogin {
                errorLabel.isHidden = true
                activity.stringValue = "正在读取已登录账号和额度…"
                activity.isHidden = false
                primaryButton?.isEnabled = false
                toolPicker.isEnabled = false
                setAdvancedControlsEnabled(false)
                connectionTask = Task { [weak self] in
                    guard let self else { return }
                    defer {
                        self.connectionTask = nil
                        self.primaryButton?.isEnabled = true
                        self.toolPicker.isEnabled = !self.isExisting
                        self.setAdvancedControlsEnabled(true)
                        self.removeTokenChanged()
                        self.activity.isHidden = true
                    }
                    do {
                        try await self.store.connectLocalAccount(updated, token: token)
                        self.onComplete()
                    } catch is CancellationError {
                    } catch {
                        EditorForm.show(error, in: self.errorLabel)
                    }
                }
            } else {
                try store.saveAccount(updated, token: token)
                onComplete()
            }
        } catch { EditorForm.show(error, in: errorLabel) }
    }
}

@MainActor
private final class MappingEditorRow: NSView {
    private let mapping: QuotaMapping
    private let labelField: NSTextField
    private let kindPicker = NSPopUpButton()
    private let categoryPicker = NSPopUpButton()
    private let totalField: NSTextField
    private let usedField: NSTextField
    private let remainingField: NSTextField
    private let unitField: NSTextField
    private let unitPathField: NSTextField
    private let resetField: NSTextField
    private let quotaRows = EditorForm.column()
    private let remainingLabel = NSTextField(labelWithString: "")
    let removeButton = EditorActionButton("移除窗口") {}
    var onRemove: (() -> Void)?

    init(mapping: QuotaMapping) {
        self.mapping = mapping
        labelField = NSTextField(string: mapping.label)
        totalField = NSTextField(string: mapping.totalPath)
        usedField = NSTextField(string: mapping.usedPath)
        remainingField = NSTextField(string: mapping.remainingPath)
        unitField = NSTextField(string: mapping.unit)
        unitPathField = NSTextField(string: mapping.unitPath)
        resetField = NSTextField(string: mapping.resetPath)
        super.init(frame: .zero)
        let content = EditorForm.column()
        EditorForm.add(EditorForm.row("窗口名称", labelField), to: content)
        kindPicker.addItems(withTitles: MetricKind.allCases.map(\.displayName))
        kindPicker.selectItem(at: MetricKind.allCases.firstIndex(of: mapping.kind) ?? 0)
        kindPicker.target = self
        kindPicker.action = #selector(kindChanged)
        categoryPicker.addItems(withTitles: QuotaCategory.allCases.map(\.displayName))
        categoryPicker.selectItem(at: QuotaCategory.allCases.firstIndex(of: mapping.category) ?? 0)
        EditorForm.add(EditorForm.row("数值类型", kindPicker), to: content)
        EditorForm.add(EditorForm.row("额度归属", categoryPicker), to: content)
        EditorForm.add(EditorForm.row("总量路径", totalField), to: quotaRows)
        EditorForm.add(EditorForm.row("已用路径", usedField), to: quotaRows)
        EditorForm.add(quotaRows, to: content)
        EditorForm.add(EditorForm.row(remainingLabel, remainingField), to: content)
        EditorForm.add(EditorForm.row("单位", unitField), to: content)
        EditorForm.add(EditorForm.row("动态单位路径", unitPathField), to: content)
        unitPathField.placeholderString = "可选，例如 balance_infos.0.currency"
        EditorForm.add(EditorForm.row("重置时间路径", resetField), to: content)
        resetField.placeholderString = "可选"
        removeButton.handler = { [weak self] in self?.onRemove?() }
        EditorForm.add(removeButton, to: content, stretch: false)
        EditorForm.pin(EditorForm.group("额度窗口", content), inside: self)
        kindChanged()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func kindChanged() {
        let isBalance = MetricKind.allCases[kindPicker.indexOfSelectedItem] == .balance
        quotaRows.isHidden = isBalance
        remainingLabel.stringValue = isBalance ? "余额路径" : "剩余路径（可选）"
        remainingField.setAccessibilityLabel(remainingLabel.stringValue)
    }

    func value() throws -> QuotaMapping {
        var value = mapping
        value.label = try EditorForm.required(labelField.stringValue, label: "窗口名称")
        value.kind = MetricKind.allCases[kindPicker.indexOfSelectedItem]
        value.category = QuotaCategory.allCases[categoryPicker.indexOfSelectedItem]
        value.totalPath = totalField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        value.usedPath = usedField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        value.remainingPath = remainingField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        value.unit = unitField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        value.unitPath = unitPathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        value.resetPath = resetField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value
    }
}

@MainActor
private final class MetricEditorRow: NSView {
    private let original: QuotaMetric
    private let supplemental: Bool
    private let labelField: NSTextField
    private let usedField: NSTextField
    private let totalField: NSTextField
    private let balanceField: NSTextField
    private let unitField: NSTextField
    private let unlimitedButton = NSButton(checkboxWithTitle: "不限量", target: nil, action: nil)
    let removeButton = EditorActionButton("移除记录") {}
    var onRemove: (() -> Void)?

    init(metric: QuotaMetric, supplemental: Bool) {
        original = metric
        self.supplemental = supplemental
        labelField = NSTextField(string: metric.label)
        usedField = NSTextField(string: String(metric.used))
        totalField = NSTextField(string: String(metric.total))
        balanceField = NSTextField(string: metric.remainingBalance.map { String($0) } ?? "")
        unitField = NSTextField(string: metric.unit)
        super.init(frame: .zero)
        let content = EditorForm.column()
        EditorForm.add(EditorForm.row("名称", labelField), to: content)
        if supplemental || metric.isBalance {
            EditorForm.add(EditorForm.row("剩余数量 / 金额", balanceField), to: content)
            unlimitedButton.state = metric.isUnlimited ? .on : .off
            unlimitedButton.target = self
            unlimitedButton.action = #selector(unlimitedChanged)
            EditorForm.add(unlimitedButton, to: content, stretch: false)
            unlimitedChanged()
        } else {
            EditorForm.add(EditorForm.row("已用", usedField), to: content)
            EditorForm.add(EditorForm.row("总量", totalField), to: content)
        }
        EditorForm.add(EditorForm.row("单位", unitField), to: content)
        unitField.placeholderString = supplemental ? "点数 / 次 / CNY / USD" : "% / 次 / tokens"
        removeButton.handler = { [weak self] in self?.onRemove?() }
        EditorForm.add(removeButton, to: content, stretch: false)
        EditorForm.pin(EditorForm.group(supplemental ? "加购记录" : "手动额度", content), inside: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func unlimitedChanged() { balanceField.isEnabled = unlimitedButton.state != .on }

    func value() throws -> QuotaMetric {
        var metric = original
        metric.label = try EditorForm.required(labelField.stringValue, label: "额度名称")
        metric.unit = try EditorForm.required(unitField.stringValue, label: "单位")
        if supplemental || original.isBalance {
            metric.used = 0
            metric.total = 0
            metric.isUnlimited = unlimitedButton.state == .on
            metric.remainingBalance = metric.isUnlimited ? nil : try EditorForm.number(balanceField.stringValue, label: "\(metric.label)的剩余数量")
        } else {
            metric.used = try EditorForm.number(usedField.stringValue, label: "\(metric.label)的已用数量")
            metric.total = try EditorForm.number(totalField.stringValue, label: "\(metric.label)的总量")
        }
        if supplemental { metric.category = .purchased }
        return metric
    }
}

private enum EditorInputError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

@MainActor
private final class EditorActionButton: NSButton {
    var handler: () -> Void
    init(_ title: String, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self
        self.action = #selector(performAction)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func performAction() { handler() }
}

private final class EditorDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private enum EditorForm {
    static func column() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 12
        stack.detachesHiddenViews = true
        return stack
    }

    static func add(_ child: NSView, to stack: NSStackView, stretch: Bool = true) {
        child.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(child)
        if stretch { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }

    static func row(_ title: String, _ control: NSView) -> NSView {
        row(NSTextField(labelWithString: title), control)
    }

    static func row(_ label: NSTextField, _ control: NSView) -> NSView {
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: 124).isActive = true
        label.setAccessibilityElement(false)
        if let field = control as? NSTextField {
            field.font = .systemFont(ofSize: NSFont.systemFontSize)
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
        }
        control.setAccessibilityLabel(label.stringValue)
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    static func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    static func errorLabel() -> NSTextField {
        let label = note("")
        label.textColor = .systemRed
        label.isHidden = true
        return label
    }

    static func show(_ error: Error, in label: NSTextField) {
        label.stringValue = error.localizedDescription
        label.isHidden = false
        NSAccessibility.post(element: label, notification: .valueChanged)
    }

    static func group(_ title: String, _ content: NSView) -> NSView {
        // NSBox manages its contentView frame itself, so pinning a wrapping
        // label inside it does not give the outer stack a reliable height.
        // Keep the heading and body in the same Auto Layout sizing chain.
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        heading.setContentCompressionResistancePriority(.required, for: .vertical)
        let body = column()
        body.spacing = 8
        add(heading, to: body)
        add(content, to: body)
        let group = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        group.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: group.leadingAnchor, constant: 12),
            body.trailingAnchor.constraint(equalTo: group.trailingAnchor, constant: -12),
            body.topAnchor.constraint(equalTo: group.topAnchor, constant: 12),
            body.bottomAnchor.constraint(equalTo: group.bottomAnchor, constant: -12)
        ])
        return group
    }

    static func pin(_ child: NSView, inside parent: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor), child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.topAnchor.constraint(equalTo: parent.topAnchor), child.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        ])
    }

    static func sheet(title: String, content: NSStackView, error: NSTextField,
                      saveTitle: String, cancel: @escaping () -> Void, save: @escaping () -> Void,
                      configureSaveButton: ((NSButton) -> Void)? = nil) -> NSView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 610, height: 650))
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 18, weight: .semibold)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        let document = EditorDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16)
        ])
        let cancelButton = EditorActionButton("取消", action: cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        let saveButton = EditorActionButton(saveTitle, action: save)
        saveButton.keyEquivalent = "\r"
        configureSaveButton?(saveButton)
        let footer = NSStackView(views: [cancelButton, saveButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        let separator = NSBox()
        separator.boxType = .separator
        for child in [heading, scroll, error, separator, footer] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: error.topAnchor, constant: -8),
            error.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            error.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            separator.topAnchor.constraint(equalTo: error.bottomAnchor, constant: 12),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor), separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            footer.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        return root
    }

    static func required(_ value: String, label: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EditorInputError.message("请填写\(label)。") }
        return trimmed
    }

    static func number(_ value: String, label: String) throws -> Double {
        guard let number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)), number.isFinite, number >= 0 else {
            throw EditorInputError.message("\(label)必须是有效的非负数字，例如 25 或 25.5。")
        }
        return number
    }
}
