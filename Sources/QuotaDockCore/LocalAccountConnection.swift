import Foundation

extension ProviderKind {
    /// Readers that can use an existing CLI login without a user-entered key or URL.
    public var supportsDefaultLogin: Bool {
        switch self {
        case .codexCLI, .claudeOAuth, .antigravityCLI, .antigravityDesktop, .copilotCLI, .cursorCLI, .qwenCLI, .oriCLI, .deepseekCLI: return true
        default: return false
        }
    }
}

public enum LocalAccountConnection {
    public static func fetch(provider: ProviderKind, account: Account, token: String? = nil) async throws -> QuotaSnapshot {
        switch provider {
        case .antigravityDesktop: return try await AntigravityDesktopQuotaProvider().fetch(account: account)
        case .codexCLI: return try await CodexQuotaProvider().fetch(account: account)
        case .claudeOAuth, .antigravityCLI: return try await ActiveQuotaProvider.fetch(provider: provider, account: account)
        case .copilotCLI: return try await CopilotCLIQuotaProvider().fetch(account: account)
        case .cursorCLI: return try await CursorCLIQuotaProvider().fetch(account: account)
        case .qwenCLI: return try await QwenCLIUsageProvider().fetch(account: account)
        case .oriCLI: return try await OriCLIQuotaProvider().fetch(account: account)
        case .deepseekCLI: return try await DeepSeekCLIQuotaProvider().fetch(account: account, token: token)
        default: throw CLIQuotaError.invalidData
        }
    }
}
