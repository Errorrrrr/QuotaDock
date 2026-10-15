import Foundation

/// Qwen's persisted /stats history is local usage, never a subscription allowance.
public struct QwenCLIUsageProvider: Sendable {
    public init() {}
    public func fetch(account: Account) async throws -> QuotaSnapshot {
        let home = try CLIProcess.directory(account.externalID, defaultPath: ProcessInfo.processInfo.environment["QWEN_HOME"] ?? "~/.qwen")
        // Require a real Qwen configuration; no credentials leave the selected directory.
        _ = try CLIQuotaSupport.object(CLIQuotaSupport.readFile(home + "/settings.json").0)
        let path = home + "/usage_record.jsonl"
        guard FileManager.default.fileExists(atPath: path) else {
            return .init(metrics: [], notice: "已读取 CLI 配置 · 暂无用量记录", usageSummary: "尚无已保存用量。Qwen 会在 /clear 时保存统计；套餐额度可手动补充。")
        }
        let (data, modified) = try CLIQuotaSupport.readFile(path)
        return try Self.parse(data: data, modified: modified)
    }

    static func parse(data: Data, modified: Date, now: Date = Date()) throws -> QuotaSnapshot {
        guard data.count <= CLIQuotaSupport.maximumBytes, let text = String(data: data, encoding: .utf8) else { throw CLIQuotaError.invalidData }
        var records: [String: [String: Any]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let record = try CLIQuotaSupport.object(Data(line.utf8))
            guard record["version"] as? Int == 1, let id = CLIQuotaSupport.text(record["sessionId"]) else { throw CLIQuotaError.invalidData }
            records[id] = record // official history semantics: last record wins for a session
        }
        var tokens = 0.0, requests = 0.0
        let start = Calendar.current.startOfDay(for: now).timeIntervalSince1970 * 1000
        for record in records.values {
            guard let timestamp = CLIQuotaSupport.number(record["timestamp"]), timestamp >= 0,
                  let models = record["models"] as? [String: [String: Any]] else { throw CLIQuotaError.invalidData }
            guard timestamp >= start, timestamp <= now.timeIntervalSince1970 * 1000 + 60_000 else { continue }
            for model in models.values {
                guard let count = CLIQuotaSupport.number(model["totalTokens"]), count >= 0,
                      let calls = CLIQuotaSupport.number(model["requests"]), calls >= 0 else { throw CLIQuotaError.invalidData }
                tokens += count; requests += calls
            }
        }
        guard tokens.isFinite, requests.isFinite else { throw CLIQuotaError.invalidData }
        return .init(metrics: [], fetchedAt: modified, notice: "本机用量 · 不提供剩余额度", usageSummary: "今日已保存统计：\(tokens.formatted(.number.precision(.fractionLength(0)))) tokens · \(requests.formatted(.number.precision(.fractionLength(0)))) 次请求。包含本目录各账号的历史，不含未保存会话；不是账号剩余额度。")
    }
}
