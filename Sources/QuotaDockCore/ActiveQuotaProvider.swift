import Foundation

/// Explicitly configured, same-account snapshots are a fallback, never a new observation.
public enum ActiveQuotaProvider {
    public static func fetch(provider: ProviderKind, account: Account) async throws -> QuotaSnapshot {
        try await withFallback(provider: provider, account: account) {
            switch provider {
            case .claudeOAuth: return try await ClaudeOAuthQuotaProvider().fetch(account: account)
            case .antigravityCLI: return try await AntigravityCLIQuotaProvider().fetch(account: account)
            default: throw CLIQuotaError.invalidData
            }
        }
    }

    static func withFallback(provider: ProviderKind, account: Account,
                             primary: () async throws -> QuotaSnapshot) async throws -> QuotaSnapshot {
        do { return try await primary() }
        catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            guard let path = account.fallbackSnapshotPath, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw error }
            let originalError = error
            var backup = account
            backup.externalID = path
            var result: QuotaSnapshot
            do {
                switch provider {
                case .claudeOAuth: result = try await ClaudeSnapshotProvider().fetch(account: backup)
                case .antigravityCLI: result = try await AntigravitySnapshotProvider().fetch(account: backup)
                default: throw CLIQuotaError.invalidData
                }
            } catch is CancellationError { throw CancellationError() }
            catch { throw originalError }
            try Task.checkCancellation()
            result.notice = "备用快照 · " + result.fetchedAt.formatted(date: .abbreviated, time: .shortened) + " · " + originalError.localizedDescription
            return result
        }
    }
}
