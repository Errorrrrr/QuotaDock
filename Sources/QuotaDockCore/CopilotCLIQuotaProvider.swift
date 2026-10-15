import Foundation

public struct CopilotCLIQuotaProvider: Sendable {
    public init() {}
    public func fetch(account: Account) async throws -> QuotaSnapshot {
        let home = try CLIProcess.directory(account.externalID, defaultPath: ProcessInfo.processInfo.environment["COPILOT_HOME"] ?? "~/.copilot")
        var environment = CLIProcess.environment(removing: ["GH_TOKEN", "GITHUB_TOKEN", "COPILOT_GITHUB_TOKEN"])
        environment["COPILOT_HOME"] = home
        let replies = try await CLIReadSession(executable: CLIProcess.executable(["copilot"]),
            arguments: ["--headless", "--no-auto-update", "--stdio"], environment: environment,
            methods: ["account.getQuota", "auth.getStatus"], requiredReplies: 1).run()
        return try Self.parse(quota: replies[0], identity: replies[1])
    }

    static func parse(quota: Data, identity: Data) throws -> QuotaSnapshot {
        let root = try CLIQuotaSupport.object(quota)
        guard let buckets = root["quotaSnapshots"] as? [String: [String: Any]] else { throw CLIQuotaError.invalidData }
        var metrics: [QuotaMetric] = []
        let labels = ["premium_interactions": "高级请求", "chat": "聊天请求", "completions": "代码补全"]
        for key in buckets.keys.sorted() {
            let bucket = buckets[key]!
            let label = labels[key] ?? CLIQuotaSupport.text(key) ?? "额度"
            let reset = try CLIQuotaSupport.date(bucket["resetDate"])
            guard let unlimited = bucket["isUnlimitedEntitlement"] as? Bool else { throw CLIQuotaError.invalidData }
            if unlimited {
                metrics.append(.init(id: "copilot-" + key, label: label, used: 0, total: 0, unit: "次", resetsAt: reset, category: .subscription, isUnlimited: true))
            } else {
                guard let remaining = CLIQuotaSupport.number(bucket["remainingPercentage"]), (0...100).contains(remaining) else { throw CLIQuotaError.invalidData }
                metrics.append(.init(id: "copilot-" + key, label: label, used: 100 - remaining, total: 100, resetsAt: reset, category: .subscription))
            }
        }
        guard !metrics.isEmpty else { throw CLIQuotaError.noQuota }
        let profile = try CLIQuotaSupport.object(identity)
        return .init(metrics: metrics, accountName: CLIQuotaSupport.text(profile["login"] ?? profile["activeLogin"]), planName: CLIQuotaSupport.text(profile["copilotPlan"]))
    }
}
