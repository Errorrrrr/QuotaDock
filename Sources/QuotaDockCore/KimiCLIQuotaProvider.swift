import Foundation

/// Kimi Code's documented local server. OAuth remains owned by the official CLI.
public struct KimiCLIQuotaProvider: Sendable {
    private let load: @Sendable (URLRequest) async throws -> Data
    public init() { load = { try await HTTPQuotaProvider.fetchData(request: $0) } }
    init(load: @escaping @Sendable (URLRequest) async throws -> Data) { self.load = load }

    public static func origin(_ input: String) throws -> URL {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = URLComponents(string: value), c.scheme == "http",
              ["127.0.0.1", "[::1]", "::1"].contains(c.host ?? ""),
              let port = c.port, (1...65535).contains(port),
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.path.isEmpty || c.path == "/", let url = c.url else { throw CLIQuotaError.invalidLocalURL }
        return url
    }

    public func fetch(account: Account, token: String?) async throws -> QuotaSnapshot {
        let base = try Self.origin(account.externalID)
        guard let token, !token.isEmpty else { throw CLIQuotaError.missingToken }
        guard !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw QuotaProviderError.invalidHeader }
        func request(_ path: String) -> URLRequest {
            var request = URLRequest(url: base.appendingPathComponent("api/v1/oauth/" + path), timeoutInterval: 20)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            return request
        }
        // Sequential identity read avoids mixing two simultaneous upstream refreshes.
        let usage = try await load(request("usage"))
        var snapshot = try Self.parseUsage(data: usage)
        try Task.checkCancellation()
        if let profile = try? await load(request("userinfo")), let info = try? Self.payload(profile)["userInfo"] as? [String: Any] {
            snapshot.accountName = CLIQuotaSupport.text(info["nickname"])
            snapshot.accountEmail = CLIQuotaSupport.text(info["email"], limit: 254)
            snapshot.planName = CLIQuotaSupport.text(info["userLevelName"])
        }
        try Task.checkCancellation()
        return snapshot
    }

    static func payload(_ data: Data) throws -> [String: Any] {
        let root = try CLIQuotaSupport.object(data)
        guard CLIQuotaSupport.number(root["code"]) == 0,
              let payload = root["data"] as? [String: Any], payload["kind"] as? String == "ok" else { throw CLIQuotaError.upstream }
        return payload
    }

    public static func parseUsage(data: Data, fetchedAt: Date = Date()) throws -> QuotaSnapshot {
        let payload = try payload(data)
        guard let quota = payload["quota"] as? [String: Any], let usages = quota["usages"] as? [String: Any] else { throw CLIQuotaError.invalidData }
        var metrics: [QuotaMetric] = []
        for (key, label) in [("limit5h", "5 小时额度"), ("limit7d", "每周额度"), ("monthTotal", "每月总额度"), ("monthCode", "每月代码额度")] {
            guard let raw = usages[key], !(raw is NSNull) else { continue }
            guard let window = raw as? [String: Any], let used = CLIQuotaSupport.number(window["usedRatio"]), (0...1).contains(used) else { throw CLIQuotaError.invalidData }
            metrics.append(.init(id: "kimi-" + key, label: label, used: used * 100, total: 100,
                                 resetsAt: try CLIQuotaSupport.date(window["resetAt"]), category: .subscription))
        }
        if let extra = quota["extraUsage"], !(extra is NSNull) {
            guard let wallet = extra as? [String: Any], let cents = CLIQuotaSupport.number(wallet["balanceCents"]), cents >= 0,
                  let currency = CLIQuotaSupport.text(wallet["currency"], limit: 8) else { throw CLIQuotaError.invalidData }
            metrics.append(.init(id: "kimi-extra", label: "加购余额", used: 0, total: 0, unit: currency,
                                 remainingBalance: cents / 100, category: .purchased))
        }
        guard !metrics.isEmpty else { throw CLIQuotaError.noQuota }
        return .init(metrics: metrics, fetchedAt: fetchedAt)
    }
}
