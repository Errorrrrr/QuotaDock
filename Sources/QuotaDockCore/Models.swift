import Foundation

public struct AppConfiguration: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var tools: [ToolDefinition]
    public var accounts: [Account]
    public var refreshInterval: Double
    public var lowQuotaThreshold: Double
    public var pinnedAccountID: UUID?

    public init(schemaVersion: Int = 1, tools: [ToolDefinition] = [], accounts: [Account] = [], refreshInterval: Double = 300, lowQuotaThreshold: Double = 20, pinnedAccountID: UUID? = nil) {
        self.schemaVersion = schemaVersion
        self.tools = tools
        self.accounts = accounts
        self.refreshInterval = refreshInterval
        self.lowQuotaThreshold = lowQuotaThreshold
        self.pinnedAccountID = pinnedAccountID
    }
}

public enum ProviderKind: String, Codable, CaseIterable, Sendable {
    case manual
    case httpJSON
    case codexCLI
    case claudeOAuth, antigravityCLI
    case claudeSnapshot
    case antigravitySnapshot
    case kimiCLI
    case glmCLI
    case copilotCLI, cursorCLI, qwenCLI, oriCLI, deepseekCLI

    public var displayName: String {
        switch self {
        case .manual: return "手动记录"
        case .httpJSON: return "JSON 接口"
        case .codexCLI: return "Codex CLI"
        case .claudeOAuth: return "Claude Code · 后台自动刷新"
        case .antigravityCLI: return "Antigravity CLI · 后台自动刷新"
        case .claudeSnapshot: return "Claude 本地快照 · 备用"
        case .antigravitySnapshot: return "Antigravity CLI 快照 · 备用"
        case .kimiCLI: return "Kimi Code CLI"
        case .glmCLI: return "GLM Coding Plan · CLI 配置"
        case .copilotCLI: return "GitHub Copilot CLI"
        case .cursorCLI: return "Cursor CLI"
        case .qwenCLI: return "Qwen Code CLI · 本机用量"
        case .oriCLI: return "Ori CLI · 密钥额度"
        case .deepseekCLI: return "DeepSeek Harness · API 余额"
        }
    }
}

public struct ToolDefinition: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var symbol: String
    public var colorHex: String
    public var provider: ProviderKind
    public var http: HTTPConfiguration
    /// Stable identity for bundled branding, independent of the editable name.
    /// Missing in legacy configurations; presentation may infer a fallback.
    public var brandID: String?

    public init(id: UUID = UUID(), name: String, symbol: String = "square.stack.3d.up", colorHex: String = "6C5CE7", provider: ProviderKind = .manual, http: HTTPConfiguration = .init(), brandID: String? = nil) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.colorHex = colorHex
        self.provider = provider
        self.http = http
        self.brandID = brandID
    }
}

public struct HTTPConfiguration: Codable, Equatable, Sendable {
    public var endpoint: String
    public var authHeader: String
    public var authPrefix: String
    public var mappings: [QuotaMapping]

    public init(endpoint: String = "", authHeader: String = "Authorization", authPrefix: String = "Bearer ", mappings: [QuotaMapping] = [.init()]) {
        self.endpoint = endpoint
        self.authHeader = authHeader
        self.authPrefix = authPrefix
        self.mappings = mappings
    }
}

public enum MetricKind: String, Codable, CaseIterable, Sendable {
    case quota
    case balance

    public var displayName: String {
        switch self {
        case .quota: return "用量额度"
        case .balance: return "账户余额"
        }
    }
}

/// Describes where an allowance comes from, independently of its numeric unit
/// or whether it is represented as a quota or a balance.
public enum QuotaCategory: String, Codable, CaseIterable, Sendable {
    case subscription
    case purchased
    case balance
    case custom

    public var displayName: String {
        switch self {
        case .subscription: return "套餐额度"
        case .purchased: return "加购额度"
        case .balance: return "账户余额"
        case .custom: return "自定义额度"
        }
    }
}

public struct QuotaMapping: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var label: String
    public var usedPath: String
    public var totalPath: String
    public var remainingPath: String
    public var resetPath: String
    public var unit: String
    public var kind: MetricKind
    public var unitPath: String
    public var category: QuotaCategory

    public init(id: UUID = UUID(), label: String = "额度", usedPath: String = "used", totalPath: String = "total", remainingPath: String = "", resetPath: String = "", unit: String = "%", kind: MetricKind = .quota, unitPath: String = "", category: QuotaCategory = .custom) {
        self.id = id
        self.label = label
        self.usedPath = usedPath
        self.totalPath = totalPath
        self.remainingPath = remainingPath
        self.resetPath = resetPath
        self.unit = unit
        self.kind = kind
        self.unitPath = unitPath
        self.category = category
    }

    private enum CodingKeys: String, CodingKey { case id, label, usedPath, totalPath, remainingPath, resetPath, unit, kind, unitPath, category }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(UUID.self, forKey: .id)
        self.label = try values.decode(String.self, forKey: .label)
        self.usedPath = try values.decode(String.self, forKey: .usedPath)
        self.totalPath = try values.decode(String.self, forKey: .totalPath)
        self.remainingPath = try values.decode(String.self, forKey: .remainingPath)
        self.resetPath = try values.decode(String.self, forKey: .resetPath)
        self.unit = try values.decode(String.self, forKey: .unit)
        self.kind = try values.decodeIfPresent(MetricKind.self, forKey: .kind) ?? .quota
        self.unitPath = try values.decodeIfPresent(String.self, forKey: .unitPath) ?? ""
        self.category = try values.decodeIfPresent(QuotaCategory.self, forKey: .category) ?? .custom
    }
}

public struct Account: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var toolID: UUID
    public var name: String
    public var subtitle: String
    public var externalID: String
    public var isEnabled: Bool
    public var manualMetrics: [QuotaMetric]
    public var supplementalMetrics: [QuotaMetric]
    public var fallbackSnapshotPath: String?
    public var menuBarMetricID: String?

    public init(id: UUID = UUID(), toolID: UUID, name: String, subtitle: String = "", externalID: String = "", isEnabled: Bool = true, manualMetrics: [QuotaMetric] = [.init(label: "额度", used: 0, total: 100)], supplementalMetrics: [QuotaMetric] = [], fallbackSnapshotPath: String? = nil, menuBarMetricID: String? = nil) {
        self.id = id
        self.toolID = toolID
        self.name = name
        self.subtitle = subtitle
        self.externalID = externalID
        self.isEnabled = isEnabled
        self.manualMetrics = manualMetrics
        self.supplementalMetrics = supplementalMetrics
        self.fallbackSnapshotPath = fallbackSnapshotPath
        self.menuBarMetricID = menuBarMetricID
    }

    private enum CodingKeys: String, CodingKey { case id, toolID, name, subtitle, externalID, isEnabled, manualMetrics, supplementalMetrics, fallbackSnapshotPath, menuBarMetricID }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(UUID.self, forKey: .id)
        self.toolID = try values.decode(UUID.self, forKey: .toolID)
        self.name = try values.decode(String.self, forKey: .name)
        self.subtitle = try values.decode(String.self, forKey: .subtitle)
        self.externalID = try values.decode(String.self, forKey: .externalID)
        self.isEnabled = try values.decode(Bool.self, forKey: .isEnabled)
        self.manualMetrics = try values.decode([QuotaMetric].self, forKey: .manualMetrics)
        self.supplementalMetrics = try values.decodeIfPresent([QuotaMetric].self, forKey: .supplementalMetrics) ?? []
        self.fallbackSnapshotPath = try values.decodeIfPresent(String.self, forKey: .fallbackSnapshotPath)
        self.menuBarMetricID = try values.decodeIfPresent(String.self, forKey: .menuBarMetricID)
    }
}

public struct QuotaMetric: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var used: Double
    public var total: Double
    public var unit: String
    public var resetsAt: Date?
    public var remainingBalance: Double?
    public var category: QuotaCategory
    public var isUnlimited: Bool

    public init(id: String = UUID().uuidString, label: String, used: Double, total: Double, unit: String = "%", resetsAt: Date? = nil, remainingBalance: Double? = nil, category: QuotaCategory = .custom, isUnlimited: Bool = false) {
        self.id = id
        self.label = label
        self.used = used
        self.total = total
        self.unit = unit
        self.resetsAt = resetsAt
        self.remainingBalance = remainingBalance
        self.category = category
        self.isUnlimited = isUnlimited
    }

    private enum CodingKeys: String, CodingKey { case id, label, used, total, unit, resetsAt, remainingBalance, category, isUnlimited }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(String.self, forKey: .id)
        self.label = try values.decode(String.self, forKey: .label)
        self.used = try values.decode(Double.self, forKey: .used)
        self.total = try values.decode(Double.self, forKey: .total)
        self.unit = try values.decode(String.self, forKey: .unit)
        self.resetsAt = try values.decodeIfPresent(Date.self, forKey: .resetsAt)
        self.remainingBalance = try values.decodeIfPresent(Double.self, forKey: .remainingBalance)
        self.category = try values.decodeIfPresent(QuotaCategory.self, forKey: .category) ?? .custom
        self.isUnlimited = try values.decodeIfPresent(Bool.self, forKey: .isUnlimited) ?? false
    }

    /// A zero-sized allowance is valid and displays as exhausted. Non-finite or
    /// negative values are invalid and must be rejected before persistence.
    public var isBalance: Bool { remainingBalance != nil || isUnlimited }

    public var isValid: Bool {
        guard used.isFinite, total.isFinite, used >= 0, total >= 0 else { return false }
        if let balance = remainingBalance { return balance.isFinite && balance >= 0 }
        return true
    }

    public var remaining: Double {
        guard isValid else { return 0 }
        return remainingBalance ?? max(0, total - used)
    }

    public var remainingFraction: Double {
        guard isValid, !isBalance, total > 0 else { return 0 }
        return min(1, max(0, remaining / total))
    }

    public var remainingPercent: Double { remainingFraction * 100 }
}

public struct QuotaSnapshot: Codable, Equatable, Sendable {
    public var metrics: [QuotaMetric]
    public var fetchedAt: Date
    /// Display metadata returned by the provider, never login credentials.
    public var accountName: String?
    public var accountEmail: String?
    public var planName: String?
    public var notice: String?
    public var usageSummary: String?

    public init(metrics: [QuotaMetric], fetchedAt: Date = Date(), accountName: String? = nil, accountEmail: String? = nil, planName: String? = nil, notice: String? = nil, usageSummary: String? = nil) {
        self.metrics = metrics
        self.fetchedAt = fetchedAt
        self.accountName = accountName
        self.accountEmail = accountEmail
        self.planName = planName
        self.notice = notice
        self.usageSummary = usageSummary
    }
}

public enum AccountSwitchCapability: Equatable, Sendable {
    case unsupported(reason: String)
    case available
}

/// Reserved for providers that can explicitly and safely activate an account.
/// Quota retrieval itself never changes credentials used by another application.
public protocol AccountSwitching: Sendable {
    func capability(for account: Account) -> AccountSwitchCapability
    func activate(_ account: Account) async throws
}

public enum AccountSwitchError: Error, LocalizedError, Sendable {
    case unsupported

    public var errorDescription: String? { "此工具尚不支持账号切换。" }
}

public struct UnsupportedAccountSwitcher: AccountSwitching {
    public init() {}
    public func capability(for account: Account) -> AccountSwitchCapability {
        .unsupported(reason: "账号切换将在后续版本按工具接入。")
    }
    public func activate(_ account: Account) async throws {
        throw AccountSwitchError.unsupported
    }
}


public enum MenuBarMetricSelection {
    public static func resolve(metrics: [QuotaMetric], selectedID: String?) -> QuotaMetric? {
        // An explicitly selected window can temporarily disappear (reset, provider
        // failure, snapshot fallback). Never silently substitute another allowance.
        if let selectedID { return metrics.first { $0.id == selectedID } }
        let subscriptions = metrics.filter { $0.category == .subscription && !$0.isBalance }
        let quotas = metrics.filter { $0.category != .purchased && !$0.isBalance }
        return subscriptions.min { $0.remainingFraction < $1.remainingFraction }
            ?? quotas.min { $0.remainingFraction < $1.remainingFraction }
            ?? metrics.first
    }
}
