import Foundation

/// Official agy statusLine payload; never reads authentication storage.
public struct AntigravitySnapshotProvider: Sendable {
    public init() {}

    public func fetch(account: Account) async throws -> QuotaSnapshot {
        try Task.checkCancellation()
        let (data, modified) = try CLIQuotaSupport.readFile(account.externalID)
        return try Self.parse(data: data, modifiedAt: modified)
    }

    public static func parse(data: Data, modifiedAt: Date, now: Date = Date()) throws -> QuotaSnapshot {
        guard now.timeIntervalSince(modifiedAt) <= 86_400, modifiedAt.timeIntervalSince(now) <= 60 else { throw CLIQuotaError.stale }
        let root = try CLIQuotaSupport.object(data)
        guard root["product"] as? String == "antigravity" else { throw CLIQuotaError.invalidData }
        guard let quota = root["quota"] as? [String: Any], !quota.isEmpty else { throw CLIQuotaError.noQuota }
        var metrics: [QuotaMetric] = []
        for key in quota.keys.sorted() {
            guard let label = CLIQuotaSupport.text(key), let window = quota[key] as? [String: Any],
                  let remaining = CLIQuotaSupport.number(window["remaining_fraction"]), (0...1).contains(remaining) else { throw CLIQuotaError.invalidData }
            let reset = try CLIQuotaSupport.date(window["reset_time"])
            // An elapsed reset does not prove a fresh allowance. Wait for a new CLI observation.
            if let reset, reset <= now { continue }
            metrics.append(.init(id: "antigravity-" + key, label: label, used: (1 - remaining) * 100,
                                 total: 100, resetsAt: reset, category: .subscription))
        }
        guard !metrics.isEmpty else { throw CLIQuotaError.stale }
        return .init(metrics: metrics, fetchedAt: modifiedAt,
                     accountEmail: CLIQuotaSupport.text(root["email"], limit: 254),
                     planName: CLIQuotaSupport.text(root["plan_tier"]))
    }
}
