import Foundation

public struct OriCLIQuotaProvider: Sendable {
    private let load: @Sendable (URLRequest) async throws -> Data
    public init() { load = { try await HTTPQuotaProvider.fetchData(request: $0) } }
    init(load: @escaping @Sendable (URLRequest) async throws -> Data) { self.load = load }

    public func fetch(account: Account) async throws -> QuotaSnapshot {
        let path: String
        if !account.externalID.isEmpty { path = account.externalID }
        else {
            let primary = ("~/.ori/credentials.json" as NSString).expandingTildeInPath
            path = FileManager.default.fileExists(atPath: primary) ? primary : "~/.openrouter/credentials.json"
        }
        let token = try Self.credential(CLIQuotaSupport.readFile(path).0)
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        return try Self.parse(try await load(request))
    }

    static func credential(_ data: Data) throws -> String {
        let record = try CLIQuotaSupport.object(data)
        // Respect logout and encrypted/OIDC markers; never recover a stale embedded key.
        if let storage = record["storage"] as? String {
            guard storage == "plaintext", record["version"] as? Int == 1 else { throw OriCLIError.protectedStore }
        } else if record["version"] != nil { throw CLIQuotaError.invalidData }
        guard let key = CLIQuotaSupport.text(record["key"], limit: 4096), key.hasPrefix("sk-or-"),
              !key.contains(" ") else { throw CLIQuotaError.invalidData }
        return key
    }

    static func parse(_ data: Data) throws -> QuotaSnapshot {
        let root = try CLIQuotaSupport.object(data)
        guard let key = root["data"] as? [String: Any] else { throw CLIQuotaError.invalidData }
        var metrics: [QuotaMetric] = []
        if let remaining = CLIQuotaSupport.number(key["limit_remaining"]) {
            guard remaining >= 0 else { throw CLIQuotaError.invalidData }
            metrics.append(.init(id: "ori-key-limit", label: "密钥可用额度", used: 0, total: 0, unit: "USD", remainingBalance: remaining, category: .custom))
        } else if !(key["limit_remaining"] is NSNull) { throw CLIQuotaError.invalidData }
        let usage = CLIQuotaSupport.number(key["usage"])
        // A key without a cap is NOT an account with unlimited credits.
        return .init(metrics: metrics, notice: metrics.isEmpty ? "CLI 已连接 · 密钥未设额度上限" : nil,
            usageSummary: usage.flatMap { $0 >= 0 ? "此密钥累计消耗 \($0.formatted()) USD。密钥限额不代表账户余额；账户余额需 Management API Key。" : nil })
    }
}

enum OriCLIError: Error, LocalizedError {
    case protectedStore
    var errorDescription: String? { "此 Ori 登录使用加密/OIDC 存储或已退出。当前支持 CLI 明文登录记录；受保护登录暂不能读取余额，可使用官方 API 接入。" }
}
