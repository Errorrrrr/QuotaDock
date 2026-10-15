import Foundation
import CryptoKit
import Security
import LocalAuthentication

public enum ClaudeOAuthError: Error, LocalizedError {
    case loginRequired, keychainAccess, expired, scope, throttled
    public var errorDescription: String? {
        switch self {
        case .loginRequired: return "未找到此配置目录的 Claude OAuth 登录，请先在官方 CLI 登录。"
        case .keychainAccess: return "无法无交互读取 Claude 钥匙串，请检查系统授权；后台不会弹出授权窗口。"
        case .expired: return "Claude 登录已过期，请打开官方 CLI 更新登录后重试。"
        case .scope: return "此 Claude 登录缺少账号查询权限，请使用官方 CLI 完整登录，不能使用 setup-token。"
        case .throttled: return "Claude 查询受到限流，15 分钟后自动重试。"
        }
    }
}

/// Uses the same read-only OAuth endpoint as Claude Code /usage, not a model turn.
/// Credentials stay in Claude's storage. Refresh-token rotation belongs to Claude Code.
public struct ClaudeOAuthQuotaProvider: Sendable {
    private let load: @Sendable (URLRequest) async throws -> Data
    private let readKeychain: @Sendable (String) throws -> Data?
    public init() {
        load = { try await HTTPQuotaProvider.fetchData(request: $0) }
        readKeychain = { try Self.keychainData(service: $0) }
    }
    init(load: @escaping @Sendable (URLRequest) async throws -> Data,
         readKeychain: @escaping @Sendable (String) throws -> Data? = { _ in nil }) {
        self.load = load; self.readKeychain = readKeychain
    }

    public func fetch(account: Account) async throws -> QuotaSnapshot {
        try Task.checkCancellation()
        let source = try Self.source(account.externalID)
        try await ClaudeQueryCooldown.shared.check(source.service)
        let keychain = readKeychain
        let data = try await Task.detached(priority: .utility) {
            if let data = try keychain(source.service) { return data }
            guard let data = try? CLIQuotaSupport.readFile(source.directory + "/.credentials.json").0 else {
                throw ClaudeOAuthError.loginRequired
            }
            return data
        }.value
        try Task.checkCancellation()
        let credential = try Self.credential(data)
        let usage: Data
        do { usage = try await load(Self.request("usage", token: credential.token)) }
        catch QuotaProviderError.httpStatus(429) {
            await ClaudeQueryCooldown.shared.block(source.service)
            throw ClaudeOAuthError.throttled
        }
        catch QuotaProviderError.httpStatus(401) { throw ClaudeOAuthError.expired }
        catch QuotaProviderError.httpStatus(403) { throw ClaudeOAuthError.scope }
        var snapshot = try Self.parse(usage)
        snapshot.planName = credential.plan
        // Profile failure must not discard valid quota. Only the same bearer is used.
        do {
            let profile = try CLIQuotaSupport.object(await load(Self.request("profile", token: credential.token)))
            let identity = profile["account"] as? [String: Any]
            snapshot.accountName = CLIQuotaSupport.text(identity?["display_name"])
            snapshot.accountEmail = CLIQuotaSupport.text(identity?["email"], limit: 254)
            if let org = profile["organization"] as? [String: Any], let tier = CLIQuotaSupport.text(org["organization_type"]) {
                snapshot.planName = Self.planName(tier)
            }
        } catch is CancellationError { throw CancellationError() }
        catch { snapshot.notice = "额度已更新，账号资料暂不可用；显示账号别名。" }
        try Task.checkCancellation()
        return snapshot
    }

    static func source(_ requested: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> (directory: String, service: String) {
        let explicit = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        let configured = explicit.isEmpty ? environment["CLAUDE_CONFIG_DIR"] : explicit
        let directory = try CLIProcess.directory(configured ?? "", defaultPath: FileManager.default.homeDirectoryForCurrentUser.path + "/.claude").precomposedStringWithCanonicalMapping
        // Claude hashes the configured path, NOT a canonicalized/symlink-resolved path.
        let suffix = configured == nil ? "" : "-" + SHA256.hash(data: Data(directory.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8)
        return (directory, "Claude Code-credentials" + suffix)
    }

    static func keychainData(service: String) throws -> Data? {
        let context = LAContext()
        context.interactionNotAllowed = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: ProcessInfo.processInfo.environment["USER"] ?? NSUserName(),
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationContext: context
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= CLIQuotaSupport.maximumBytes else { throw ClaudeOAuthError.keychainAccess }
        return data
    }

    static func credential(_ data: Data, now: Date = Date()) throws -> (token: String, plan: String?) {
        let root = try CLIQuotaSupport.object(data)
        guard let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = CLIQuotaSupport.text(oauth["accessToken"], limit: 16384) else { throw ClaudeOAuthError.loginRequired }
        if let raw = oauth["expiresAt"], !(raw is NSNull) {
            guard let expiry = CLIQuotaSupport.number(raw), expiry / 1000 > now.timeIntervalSince1970 + 30 else { throw ClaudeOAuthError.expired }
        }
        if let scopes = oauth["scopes"] as? [String], !scopes.contains("user:profile") { throw ClaudeOAuthError.scope }
        return (token, CLIQuotaSupport.text(oauth["subscriptionType"]).map(planName))
    }

    private static func planName(_ value: String) -> String {
        switch value {
        case "max", "claude_max": return "Max"
        case "pro", "claude_pro": return "Pro"
        case "team", "claude_team": return "Team"
        case "enterprise", "claude_enterprise": return "Enterprise"
        default: return value
        }
    }

    static func request(_ resource: String, token: String) -> URLRequest {
        precondition(["usage", "profile"].contains(resource))
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/" + resource)!)
        request.httpMethod = "GET"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    public static func parse(_ data: Data) throws -> QuotaSnapshot {
        let root = try CLIQuotaSupport.object(data)
        var metrics: [QuotaMetric] = []
        for (key, label) in [("five_hour", "5 小时额度"), ("seven_day", "每周额度"), ("seven_day_sonnet", "Sonnet · 每周"), ("seven_day_opus", "Opus · 每周"), ("seven_day_oauth_apps", "OAuth 应用 · 每周")] {
            guard let value = root[key], !(value is NSNull) else { continue }
            guard let window = value as? [String: Any], let used = CLIQuotaSupport.number(window["utilization"]), (0...100).contains(used) else { throw CLIQuotaError.invalidData }
            metrics.append(.init(id: key, label: label, used: used, total: 100,
                                 resetsAt: try CLIQuotaSupport.date(window["resets_at"]), category: .subscription))
        }
        if let extra = root["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true,
           let limit = CLIQuotaSupport.number(extra["monthly_limit"]), let used = CLIQuotaSupport.number(extra["used_credits"]) {
            guard limit >= 0, used >= 0 else { throw CLIQuotaError.invalidData }
            // This is a spending cap in cents, not purchased credit or a cash balance.
            metrics.append(.init(id: "extra_usage", label: "额外用量月预算", used: used / 100, total: limit / 100, unit: "USD", category: .custom))
        }
        guard !metrics.isEmpty else { throw CLIQuotaError.noQuota }
        return .init(metrics: metrics)
    }
}

private actor ClaudeQueryCooldown {
    static let shared = ClaudeQueryCooldown()
    private var blockedUntil: [String: Date] = [:]
    func check(_ key: String) throws {
        if let until = blockedUntil[key], until > Date() { throw ClaudeOAuthError.throttled }
    }
    func block(_ key: String) { blockedUntil[key] = Date().addingTimeInterval(900) }
}
