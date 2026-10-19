import AppKit
import Combine
import Darwin
import Foundation
import QuotaDockCore

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var config = AppConfiguration()
    @Published private(set) var snapshots: [UUID: QuotaSnapshot] = [:]
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var refreshing: Set<UUID> = []
    @Published var errorMessage: String?
    @Published private(set) var isDemo = false

    private let keychain = KeychainStore()
    private var configurationIsWritable = true
    private var lastKnownGoodConfiguration: AppConfiguration?
    private var lastConfigurationData: Data?
    private var refreshTasks: [UUID: Task<Void, Never>] = [:]
    private var requestIDs: [UUID: UUID] = [:]
    private var pollingTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    init(demo: Bool = false) {
        if demo {
            isDemo = true
            config = Self.demoConfiguration()
            seedManualSnapshots()
        } else {
            loadConfiguration()
        }
    }

    deinit {
        pollingTask?.cancel()
        refreshTasks.values.forEach { $0.cancel() }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    var enabledAccounts: [Account] { config.accounts.filter(\.isEnabled) }

    func tool(for account: Account) -> ToolDefinition? {
        config.tools.first { $0.id == account.toolID }
    }

    func accountName(for account: Account) -> String {
        snapshots[account.id]?.accountName ?? account.name
    }

    var menuBarTitle: String {
        guard let pinnedAccountID = config.pinnedAccountID,
              let account = enabledAccounts.first(where: { $0.id == pinnedAccountID }),
              let tool = tool(for: account) else { return "" }
        let metrics = snapshots[account.id]?.metrics ?? []
        let metric = MenuBarMetricSelection.resolve(metrics: metrics, selectedID: account.menuBarMetricID)
        let value: String
        if let metric, metric.isUnlimited {
            value = "不限量"
        } else if let metric, metric.isBalance || metric.category == .purchased {
            value = "\(metric.remaining.formatted(.number.precision(.fractionLength(0...2)))) \(metric.unit)"
        } else if let metric {
            value = "\(Int(metric.remainingPercent.rounded()))%"
        } else {
            value = "—"
        }
        let suffix = errors[account.id] != nil ? " !" : ""
        let fullName = accountName(for: account)
        let name = fullName.count > 16 ? "\(fullName.prefix(15))…" : fullName
        return "\(tool.name) · \(name) \(value)\(suffix)\(isDemo ? " · 演示" : "")"
    }

    var lowQuotaAccountCount: Int {
        enabledAccounts.filter { account in
            snapshots[account.id]?.metrics.contains {
                !$0.isBalance && $0.category != .purchased && $0.remainingPercent <= config.lowQuotaThreshold
            } ?? false
        }.count
    }

    func refreshAll() async {
        let accountIDs = enabledAccounts.map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for accountID in accountIDs {
                group.addTask { await self.refresh(accountID: accountID) }
            }
        }
    }

    /// Concurrent requests for one account share a task. A replacement or deletion
    /// invalidates its request ID so a late response can never restore stale data.
    func refresh(accountID: UUID) async {
        if let existing = refreshTasks[accountID] {
            await existing.value
            return
        }
        guard let account = config.accounts.first(where: { $0.id == accountID && $0.isEnabled }),
              let tool = tool(for: account) else { return }
        guard tool.availableProviders.contains(tool.provider) else {
            errors[accountID] = "此工具的接入方式不匹配，请在工具配置中重新选择。"
            snapshots.removeValue(forKey: accountID)
            return
        }
        if tool.provider == .manual {
            // Loading/re-saving a manual entry changes its timestamp; polling does not.
            let combinedMetrics = account.manualMetrics + account.supplementalMetrics
            if snapshots[accountID]?.metrics != combinedMetrics {
                snapshots[accountID] = QuotaSnapshot(metrics: combinedMetrics)
            }
            errors.removeValue(forKey: accountID)
            return
        }
        guard !isDemo else { return }

        let requestID = UUID()
        requestIDs[accountID] = requestID
        refreshing.insert(accountID)
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.requestIDs[accountID] == requestID {
                    self.requestIDs.removeValue(forKey: accountID)
                    self.refreshTasks.removeValue(forKey: accountID)
                    self.refreshing.remove(accountID)
                }
            }
            var credential: String?
            do {
                try Task.checkCancellation()
                let result: QuotaSnapshot
                switch tool.provider {
                case .manual:
                    return
                case .httpJSON:
                    credential = try self.keychain.token(for: accountID, allowInteraction: false)
                    result = try await HTTPQuotaProvider().fetch(tool: tool, account: account, token: credential)
                case .codexCLI, .claudeOAuth, .antigravityCLI, .antigravityDesktop, .copilotCLI, .cursorCLI, .qwenCLI, .oriCLI, .deepseekCLI:
                    if tool.provider == .deepseekCLI { credential = try self.keychain.token(for: accountID, allowInteraction: false) }
                    result = try await LocalAccountConnection.fetch(provider: tool.provider, account: account, token: credential)
                case .claudeSnapshot:
                    result = try await ClaudeSnapshotProvider().fetch(account: account)
                case .antigravitySnapshot:
                    result = try await AntigravitySnapshotProvider().fetch(account: account)
                case .kimiCLI:
                    credential = try self.keychain.token(for: accountID, allowInteraction: false)
                    result = try await KimiCLIQuotaProvider().fetch(account: account, token: credential)
                case .glmCLI:
                    result = try await GLMCLIQuotaProvider().fetch(account: account)
                }
                guard self.acceptsResult(account: account, tool: tool, requestID: requestID) else { return }
                self.snapshots[accountID] = try self.appendingSupplementalMetrics(to: result, account: account)
                self.errors.removeValue(forKey: accountID)
            } catch is CancellationError {
                // Intentional cancellation is not a provider failure.
            } catch {
                guard self.acceptsResult(account: account, tool: tool, requestID: requestID) else { return }
                var message = error.localizedDescription
                if let credential, !credential.isEmpty {
                    message = message.replacingOccurrences(of: credential, with: "[已隐藏]")
                }
                self.errors[accountID] = message
                // Keep the last successful snapshot while showing its separate error.
            }
        }
        refreshTasks[accountID] = task
        await task.value
    }

    func saveTool(_ tool: ToolDefinition) throws {
        if let existing = config.toolPreventingSave(tool) {
            throw StoreError.invalidConfiguration("已添加工具“\(existing.name)”，无需重复添加。请在该工具下添加账号。")
        }
        guard tool.availableProviders.contains(tool.provider) else {
            throw StoreError.invalidConfiguration("此工具不支持所选接入方式，请重新配置工具。")
        }
        var updated = config
        var credentialChanges: [(UUID, String?)] = []
        if let index = updated.tools.firstIndex(where: { $0.id == tool.id }) {
            let previous = updated.tools[index]
            if previous.provider != tool.provider || credentialOrigin(for: previous.http.endpoint) != credentialOrigin(for: tool.http.endpoint) {
                // Never send an existing service's token to a newly configured
                // origin. Same-origin path/header edits preserve credentials.
                credentialChanges = updated.accounts.filter { $0.toolID == tool.id }.map { ($0.id, nil) }
            }
            updated.tools[index] = tool
        } else {
            updated.tools.append(tool)
        }
        try commit(updated, credentialChanges: credentialChanges)
        for account in config.accounts where account.toolID == tool.id {
            invalidate(accountID: account.id, clearSnapshot: true)
            scheduleRefresh(accountID: account.id)
        }
    }

    /// nil preserves the existing token; an empty string removes it; a non-empty
    /// string replaces it. Credentials are stored only in the system keychain.
    func saveAccount(_ account: Account, token: String?, initialSnapshot: QuotaSnapshot? = nil) throws {
        var updated = config
        if let index = updated.accounts.firstIndex(where: { $0.id == account.id }) {
            guard updated.accounts[index].toolID == account.toolID else {
                throw StoreError.invalidConfiguration("已有账号不能更换所属工具，以免将凭据发送给其他服务。请在目标工具下新建账号。")
            }
            updated.accounts[index] = account
        } else {
            updated.accounts.append(account)
        }
        var changes: [(UUID, String?)] = token.map { [(account.id, $0.isEmpty ? nil : $0)] } ?? []
        if tool(for: account)?.provider == .kimiCLI {
            _ = try KimiCLIQuotaProvider.origin(account.externalID)
            if let previous = config.accounts.first(where: { $0.id == account.id }),
               credentialOrigin(for: previous.externalID) != credentialOrigin(for: account.externalID), token == nil {
                // A local service on a different port can belong to another account/application.
                changes = [(account.id, nil)]
            }
        }
        let combined = try initialSnapshot.map { try appendingSupplementalMetrics(to: $0, account: account) }
        try commit(updated, credentialChanges: changes)
        invalidate(accountID: account.id, clearSnapshot: true)
        if let combined { snapshots[account.id] = combined }
        else { scheduleRefresh(accountID: account.id) }
    }

    /// Resolve the selected local login before saving. Failed/cancelled discovery
    /// leaves configuration untouched; success reuses the first fetched snapshot.
    func connectLocalAccount(_ account: Account, token: String? = nil) async throws {
        guard !isDemo, let tool = tool(for: account), tool.provider.supportsDefaultLogin,
              !config.accounts.contains(where: { $0.id == account.id }) else {
            throw StoreError.invalidConfiguration("请选择支持读取本机登录的工具。")
        }
        var candidate = config
        candidate.accounts.append(account)
        try validate(candidate)
        let selectedToken = tool.provider == .deepseekCLI ? token : nil
        let snapshot = try await LocalAccountConnection.fetch(provider: tool.provider, account: account, token: selectedToken)
        try Task.checkCancellation()
        guard !isDemo, self.tool(for: account) == tool else {
            throw StoreError.invalidConfiguration("工具配置已变化，请重新添加账号。")
        }
        try saveAccount(account, token: selectedToken, initialSnapshot: snapshot)
    }

    func selectMenuBarMetric(accountID: UUID, metricID: String?) throws {
        guard let index = config.accounts.firstIndex(where: { $0.id == accountID }) else { return }
        var updated = config
        updated.accounts[index].menuBarMetricID = metricID
        updated.pinnedAccountID = accountID
        // Presentation-only change: preserve the snapshot and any in-flight query.
        try commit(updated, credentialChanges: [])
    }

    func deleteTool(id: UUID) throws {
        let accountIDs = config.accounts.filter { $0.toolID == id }.map(\.id)
        var updated = config
        updated.tools.removeAll { $0.id == id }
        updated.accounts.removeAll { $0.toolID == id }
        if let pinned = updated.pinnedAccountID, accountIDs.contains(pinned) { updated.pinnedAccountID = nil }
        try commit(updated, credentialChanges: accountIDs.map { ($0, nil) })
        accountIDs.forEach { invalidate(accountID: $0, clearSnapshot: true) }
    }

    func deleteAccount(id: UUID) throws {
        var updated = config
        updated.accounts.removeAll { $0.id == id }
        if updated.pinnedAccountID == id { updated.pinnedAccountID = nil }
        try commit(updated, credentialChanges: [(id, nil)])
        invalidate(accountID: id, clearSnapshot: true)
    }

    func updatePreferences(refreshInterval: Double, lowQuotaThreshold: Double, pinnedAccountID: UUID?) throws {
        var updated = config
        updated.refreshInterval = refreshInterval
        updated.lowQuotaThreshold = lowQuotaThreshold
        updated.pinnedAccountID = pinnedAccountID
        try commit(updated)
        if pollingTask != nil {
            stopPolling()
            startPolling()
        }
    }

    func setDemo(_ enabled: Bool) {
        guard enabled != isDemo else { return }
        let wasPolling = pollingTask != nil
        stopPolling()
        cancelAllRefreshes()
        snapshots = [:]
        errors = [:]
        errorMessage = nil
        isDemo = enabled
        if enabled {
            config = Self.demoConfiguration()
            seedManualSnapshots()
        } else {
            loadConfiguration()
        }
        if wasPolling { startPolling() }
    }

    func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            await self?.refreshAll()
            while !Task.isCancelled {
                guard let interval = self?.config.refreshInterval else { return }
                do { try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) }
                catch { return }
                guard !Task.isCancelled else { return }
                await self?.refreshAll()
            }
        }
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.refreshAll() }
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    private func acceptsResult(account: Account, tool: ToolDefinition, requestID: UUID) -> Bool {
        var expected = account
        let current = config.accounts.first(where: { $0.id == account.id })
        expected.menuBarMetricID = current?.menuBarMetricID
        return !Task.isCancelled && !isDemo && requestIDs[account.id] == requestID
            && current == expected
            && config.tools.first(where: { $0.id == tool.id }) == tool
    }

    private func scheduleRefresh(accountID: UUID) {
        Task { [weak self] in await self?.refresh(accountID: accountID) }
    }

    private func invalidate(accountID: UUID, clearSnapshot: Bool) {
        requestIDs.removeValue(forKey: accountID)
        refreshTasks.removeValue(forKey: accountID)?.cancel()
        refreshing.remove(accountID)
        errors.removeValue(forKey: accountID)
        if clearSnapshot { snapshots.removeValue(forKey: accountID) }
    }

    private func cancelAllRefreshes() {
        requestIDs.removeAll()
        refreshTasks.values.forEach { $0.cancel() }
        refreshTasks.removeAll()
        refreshing.removeAll()
    }

    private func credentialOrigin(for endpoint: String) -> String? {
        guard let components = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "{accountId}", with: "validation-account")),
              let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased() else { return nil }
        let effectivePort = components.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : -1)
        return "\(scheme)://\(host):\(effectivePort)"
    }

    private var configurationURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuotaDock", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    private func loadConfiguration() {
        configurationIsWritable = true
        let url = configurationURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            config = AppConfiguration()
            lastKnownGoodConfiguration = config
            lastConfigurationData = nil
            return
        }
        do {
            let properties = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            guard properties.isSymbolicLink != true, (properties.fileSize ?? 0) <= 2_000_000 else {
                throw StoreError.invalidConfiguration("配置文件类型或大小不受支持。")
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let data = try Data(contentsOf: url)
            let loaded = try decoder.decode(AppConfiguration.self, from: data)
            try validate(loaded)
            config = loaded
            lastKnownGoodConfiguration = loaded
            lastConfigurationData = data
            seedManualSnapshots()
        } catch {
            configurationIsWritable = false
            config = lastKnownGoodConfiguration ?? AppConfiguration()
            seedManualSnapshots()
            errorMessage = "无法读取配置，原文件已保留，保存功能暂不可用。请检查 \(url.path)。\n\(error.localizedDescription)"
        }
    }

    private func seedManualSnapshots() {
        for account in enabledAccounts where tool(for: account)?.provider == .manual {
            snapshots[account.id] = QuotaSnapshot(metrics: account.manualMetrics + account.supplementalMetrics)
        }
    }

    private func appendingSupplementalMetrics(to snapshot: QuotaSnapshot, account: Account) throws -> QuotaSnapshot {
        let combined = snapshot.metrics + account.supplementalMetrics
        guard Set(combined.map(\.id)).count == combined.count,
              combined.allSatisfy(\.isValid) else {
            throw StoreError.invalidConfiguration("自动额度与手动加购额度的标识冲突，或含有无效数值；请修改加购额度后重试。")
        }
        return QuotaSnapshot(metrics: combined, fetchedAt: snapshot.fetchedAt, accountName: snapshot.accountName, accountEmail: snapshot.accountEmail, planName: snapshot.planName, notice: snapshot.notice, usageSummary: snapshot.usageSummary)
    }

    /// A failed file write restores any credential changes. No in-memory config is
    /// published until both keychain mutations and the atomic disk commit succeed.
    private func commit(_ updated: AppConfiguration, credentialChanges: [(UUID, String?)] = []) throws {
        guard !isDemo else { throw StoreError.demoIsReadOnly }
        guard configurationIsWritable else { throw StoreError.configurationIsReadOnly }
        try validate(updated)
        try verifyDiskUnchanged()
        var previousCredentials: [(UUID, String?)] = []
        do {
            for (accountID, newValue) in credentialChanges {
                let previous = try keychain.token(for: accountID)
                try keychain.setToken(newValue, for: accountID)
                previousCredentials.append((accountID, previous))
            }
            try persist(updated)
        } catch {
            var rollbackFailed = false
            for (accountID, previous) in previousCredentials.reversed() {
                do { try keychain.setToken(previous, for: accountID) }
                catch { rollbackFailed = true }
            }
            if rollbackFailed { throw StoreError.credentialRollbackFailed }
            throw error
        }
        config = updated
        lastKnownGoodConfiguration = updated
    }

    private func persist(_ configuration: AppConfiguration) throws {
        let destination = configurationURL
        let directory = destination.deletingLastPathComponent()
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.path) {
            let properties = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard properties.isDirectory == true, properties.isSymbolicLink != true else {
                throw StoreError.invalidConfiguration("配置目录必须是普通文件夹。")
            }
        } else {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(configuration)
        let temporary = directory.appendingPathComponent(".config-\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: temporary) }
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw StoreError.invalidConfiguration("无法创建配置临时文件。")
        }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        try handle.synchronize()
        // A keychain permission prompt may have yielded time for another process
        // to edit the file, so check the disk version again at the commit point.
        try verifyDiskUnchanged()
        guard rename(temporary.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        lastConfigurationData = data
    }

    private func verifyDiskUnchanged() throws {
        let url = configurationURL
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !exists, lastConfigurationData == nil { return }
        guard exists, let lastConfigurationData else { throw StoreError.configurationChangedExternally }
        let properties = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard properties.isSymbolicLink != true, (properties.fileSize ?? 0) <= 2_000_000,
              try Data(contentsOf: url) == lastConfigurationData else {
            throw StoreError.configurationChangedExternally
        }
    }

    private func validate(_ configuration: AppConfiguration) throws {
        guard configuration.schemaVersion == 1 else { throw StoreError.invalidConfiguration("配置版本不受支持。") }
        guard configuration.refreshInterval.isFinite, (60...3600).contains(configuration.refreshInterval),
              configuration.lowQuotaThreshold.isFinite, (0...100).contains(configuration.lowQuotaThreshold) else {
            throw StoreError.invalidConfiguration("刷新间隔应为 60–3600 秒，低额度提醒阈值应为 0–100%。")
        }
        let toolIDs = Set(configuration.tools.map(\.id))
        let accountIDs = Set(configuration.accounts.map(\.id))
        guard toolIDs.count == configuration.tools.count, accountIDs.count == configuration.accounts.count else {
            throw StoreError.invalidConfiguration("工具或账号标识重复。")
        }
        guard configuration.tools.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              configuration.accounts.allSatisfy({
                  toolIDs.contains($0.toolID) && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && $0.manualMetrics.allSatisfy(\.isValid) && $0.supplementalMetrics.allSatisfy(\.isValid)
              }) else {
            throw StoreError.invalidConfiguration("工具和账号名称不能为空，账号必须关联有效工具，额度必须是有效的非负数。")
        }
        if let pinned = configuration.pinnedAccountID, !accountIDs.contains(pinned) {
            throw StoreError.invalidConfiguration("菜单栏固定的账号不存在。")
        }
        for tool in configuration.tools where tool.provider == .httpJSON {
            let mappings = tool.http.mappings
            guard !mappings.isEmpty, Set(mappings.map(\.id)).count == mappings.count else {
                throw StoreError.invalidConfiguration("JSON 接口至少需要一个额度窗口，且窗口标识不能重复。")
            }
            for mapping in mappings {
                guard !mapping.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw StoreError.invalidConfiguration("额度窗口名称不能为空。")
                }
                let hasRemaining = !mapping.remainingPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                switch mapping.kind {
                case .quota:
                    guard !mapping.totalPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          hasRemaining || !mapping.usedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw StoreError.invalidConfiguration("配额窗口需要总量路径，以及已用路径或剩余路径。")
                    }
                case .balance:
                    guard hasRemaining else { throw StoreError.invalidConfiguration("余额窗口需要填写余额路径。") }
                }
            }
            // Validate syntax only. This neither reads credentials nor issues a request.
            _ = try HTTPQuotaProvider.makeRequest(configuration: tool.http,
                account: Account(toolID: tool.id, name: "配置校验", externalID: "validation-account"),
                token: "quotadock-validation-placeholder")
        }
        for account in configuration.accounts where configuration.tools.first(where: { $0.id == account.toolID })?.provider == .manual {
            guard !account.manualMetrics.isEmpty,
                  Set(account.manualMetrics.map(\.id)).count == account.manualMetrics.count,
                  account.manualMetrics.allSatisfy({
                      !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          && !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  }) else {
                throw StoreError.invalidConfiguration("手动账号至少需要一个额度窗口，窗口名称不能为空，标识不能为空或重复。")
            }
        }
        for account in configuration.accounts {
            let supplementalIDs = Set(account.supplementalMetrics.map(\.id))
            var primaryIDs = Set(account.manualMetrics.map(\.id))
            if let tool = configuration.tools.first(where: { $0.id == account.toolID }) {
                switch tool.provider {
                case .httpJSON: primaryIDs.formUnion(tool.http.mappings.map { $0.id.uuidString })
                case .claudeSnapshot, .claudeOAuth: primaryIDs.formUnion(["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus", "extra_usage"])
                case .manual, .codexCLI, .antigravityCLI, .antigravityDesktop, .antigravitySnapshot, .kimiCLI, .glmCLI, .copilotCLI, .cursorCLI, .qwenCLI, .oriCLI, .deepseekCLI: break
                }
            }
            guard supplementalIDs.count == account.supplementalMetrics.count,
                  supplementalIDs.isDisjoint(with: primaryIDs),
                  account.supplementalMetrics.allSatisfy({
                      !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          && !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          && $0.isValid
                  }) else {
                throw StoreError.invalidConfiguration("加购额度必须使用独立且不重复的标识，名称不能为空，数值必须为有限非负数。")
            }
        }
        let activeAntigravity = configuration.accounts.filter { account in
            configuration.tools.first(where: { $0.id == account.toolID })?.provider == .antigravityCLI
        }
        guard activeAntigravity.count <= 1, activeAntigravity.allSatisfy({ $0.externalID.isEmpty }) else {
            throw StoreError.invalidConfiguration("Antigravity 自动查询跟随当前 CLI 登录，仅可添加一个账号；独立多账号请使用各自的快照接入。")
        }
        let desktopAccounts = configuration.accounts.filter { account in
            configuration.tools.first(where: { $0.id == account.toolID })?.provider == .antigravityDesktop
        }
        guard desktopAccounts.count <= 1, desktopAccounts.allSatisfy({ $0.externalID.isEmpty }) else {
            throw StoreError.invalidConfiguration("Antigravity 桌面查询跟随当前桌面登录，仅可添加一个账号。")
        }
        var claudeHomes = Set<String>()
        for account in configuration.accounts where configuration.tools.first(where: { $0.id == account.toolID })?.provider == .claudeOAuth {
            let path = account.externalID.isEmpty ? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? NSHomeDirectory() + "/.claude" : account.externalID
            let normalized = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
            guard claudeHomes.insert(normalized).inserted else {
                throw StoreError.invalidConfiguration("同一个 Claude 配置目录只能添加一个账号；多账号需分别在独立 CLAUDE_CONFIG_DIR 中登录。")
            }
        }
        var codexHomes = Set<String>()
        for account in configuration.accounts where configuration.tools.first(where: { $0.id == account.toolID })?.provider == .codexCLI {
            let requestedHome = account.externalID.trimmingCharacters(in: .whitespacesAndNewlines)
            let home = requestedHome.isEmpty
                ? ProcessInfo.processInfo.environment["CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
                : requestedHome
            let normalized = URL(fileURLWithPath: (home as NSString).expandingTildeInPath)
                .standardizedFileURL.resolvingSymlinksInPath().path
            guard codexHomes.insert(normalized).inserted else {
                throw StoreError.invalidConfiguration("同一个 Codex 配置目录只能添加一个账号。留空路径也指向默认目录；多账号需要各自独立且已登录的 CODEX_HOME 目录。")
            }
        }
    }

    private static func demoConfiguration() -> AppConfiguration {
        let codex = ToolDefinition(name: "Codex", symbol: "terminal", colorHex: "137B67")
        let claude = ToolDefinition(name: "Claude", symbol: "sun.max", colorHex: "C67D56")
        let antigravity = ToolDefinition(name: "Antigravity", symbol: "sparkles", colorHex: "497BE8", brandID: "antigravity")
        let accounts = [
            Account(toolID: codex.id, name: "工作账号", subtitle: "演示数据 · 手动记录", manualMetrics: [
                QuotaMetric(id: "session", label: "5 小时额度", used: 28, total: 100, resetsAt: Date().addingTimeInterval(7200), category: .subscription),
                QuotaMetric(id: "weekly", label: "每周额度", used: 46, total: 100, resetsAt: Date().addingTimeInterval(259200), category: .subscription),
            ], supplementalMetrics: [
                QuotaMetric(id: "supplemental-credits", label: "加购额度", used: 0, total: 0, unit: "点", remainingBalance: 120, category: .purchased),
            ]),
            Account(toolID: codex.id, name: "个人账号", subtitle: "演示数据 · 手动记录", manualMetrics: [
                QuotaMetric(id: "session", label: "5 小时额度", used: 88, total: 100, resetsAt: Date().addingTimeInterval(3600), category: .subscription),
            ]),
            Account(toolID: claude.id, name: "设计工作室", subtitle: "演示数据 · 手动记录", manualMetrics: [
                QuotaMetric(id: "session", label: "5 小时额度", used: 38, total: 100, resetsAt: Date().addingTimeInterval(10800), category: .subscription),
                QuotaMetric(id: "weekly", label: "每周额度", used: 61, total: 100, resetsAt: Date().addingTimeInterval(345600), category: .subscription),
            ]),
            Account(toolID: antigravity.id, name: "日常探索", subtitle: "演示数据 · 手动记录", manualMetrics: [
                QuotaMetric(id: "requests", label: "今日请求", used: 240, total: 1500, unit: "次"),
            ]),
        ]
        return AppConfiguration(tools: [codex, claude, antigravity], accounts: accounts, pinnedAccountID: accounts.first?.id)
    }
}

private enum StoreError: LocalizedError {
    case demoIsReadOnly
    case configurationIsReadOnly
    case configurationChangedExternally
    case credentialRollbackFailed
    case invalidConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .demoIsReadOnly: return "演示模式只供预览，请先退出演示再修改真实配置。"
        case .configurationIsReadOnly: return "配置读取失败，原文件受到保护。请先修复配置文件并重新启动应用。"
        case .configurationChangedExternally: return "配置文件已被其他程序修改或删除，为避免覆盖，当前修改未保存。请重新启动应用后再编辑。"
        case .credentialRollbackFailed: return "保存失败，且钥匙串恢复未完成。配置文件未更新，请检查账号凭据后重试。"
        case .invalidConfiguration(let message): return message
        }
    }
}
