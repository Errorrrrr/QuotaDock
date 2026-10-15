import Foundation

/// Uses the account selected by its CLI auth.json and the CLI's DashboardService schema.
public struct CursorCLIQuotaProvider: Sendable {
    private let load: @Sendable (URLRequest) async throws -> Data
    public init() { load = { try await HTTPQuotaProvider.fetchData(request: $0) } }
    init(load: @escaping @Sendable (URLRequest) async throws -> Data) { self.load = load }

    public func fetch(account: Account) async throws -> QuotaSnapshot {
        let path = account.externalID.isEmpty ? "~/.cursor/auth.json" : account.externalID
        let auth = try CLIQuotaSupport.object(CLIQuotaSupport.readFile(path).0)
        guard let token = CLIQuotaSupport.text(auth["accessToken"], limit: 16384) else { throw CLIQuotaError.upstream }
        func request(_ method: String) -> URLRequest {
            var request = URLRequest(url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/" + method)!)
            request.httpMethod = "POST"
            request.httpBody = Data("{}".utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            return request
        }
        let quota = try await load(request("GetUsageLimitStatusAndActiveGrants"))
        let identity = try? await load(request("GetMe"))
        return try Self.parse(quota: quota, identity: identity)
    }

    static func parse(quota: Data, identity: Data?, now: Date = Date()) throws -> QuotaSnapshot {
        let root = try CLIQuotaSupport.object(quota)
        guard root["usageLimitPolicyStatus"] is [String: Any] || root["activeGrants"] is [[String: Any]] else { throw CLIQuotaError.invalidData }
        let grants = root["activeGrants"] as? [[String: Any]] ?? []
        var metrics: [QuotaMetric] = []
        for grant in grants where grant["showInClient"] as? Bool == true {
            guard let id = CLIQuotaSupport.text(grant["grantId"]),
                  let remaining = Self.protobufNumber(grant["remainingCents"] ?? "0"), remaining >= 0,
                  let total = Self.protobufNumber(grant["totalCents"] ?? "0"), total >= remaining,
                  let expires = Self.protobufNumber(grant["expiresAtMs"] ?? "0"), expires >= 0, expires <= 4_102_444_800_000 else { throw CLIQuotaError.invalidData }
            let reset = expires == 0 ? nil : Date(timeIntervalSince1970: expires / 1000)
            if let reset, reset <= now { continue }
            // Grant types are server-defined. Do not guess purchased/subscription classification.
            metrics.append(.init(id: "cursor-" + id, label: CLIQuotaSupport.text(grant["campaignName"]) ?? "可用额度", used: (total - remaining) / 100, total: total / 100, unit: "USD", resetsAt: reset, remainingBalance: remaining / 100, category: .balance))
        }
        let profile = identity.flatMap { try? CLIQuotaSupport.object($0) } ?? [:]
        let name = [CLIQuotaSupport.text(profile["firstName"]), CLIQuotaSupport.text(profile["lastName"])].compactMap { $0 }.joined(separator: " ")
        return .init(metrics: metrics, accountName: name.isEmpty ? nil : name, accountEmail: CLIQuotaSupport.text(profile["email"], limit: 320),
            notice: metrics.isEmpty ? "已连接 CLI · 服务端未提供可展示额度" : nil)
    }

    private static func protobufNumber(_ value: Any?) -> Double? {
        if let string = value as? String, let number = Double(string), number.isFinite { return number }
        return CLIQuotaSupport.number(value)
    }
}
