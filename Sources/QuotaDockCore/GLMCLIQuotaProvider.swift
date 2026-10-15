import Foundation

/// Uses the same quota endpoint as Z.ai's official Claude Code usage-query plugin.
/// Does not launch an agent or execute arbitrary plugin code.
public struct GLMCLIQuotaProvider: Sendable {
    private let load: @Sendable (URLRequest) async throws -> Data
    public init() { load = { try await HTTPQuotaProvider.fetchData(request: $0) } }
    init(load: @escaping @Sendable (URLRequest) async throws -> Data) { self.load = load }

    public func fetch(account: Account) async throws -> QuotaSnapshot {
        try Task.checkCancellation()
        let (data, _) = try CLIQuotaSupport.readFile(account.externalID)
        let request = try Self.makeRequest(settings: data)
        return try Self.parse(data: await load(request))
    }

    public static func makeRequest(settings: Data) throws -> URLRequest {
        let root = try CLIQuotaSupport.object(settings)
        guard let env = root["env"] as? [String: Any], let base = env["ANTHROPIC_BASE_URL"] as? String,
              let c = URLComponents(string: base), c.scheme == "https",
              ["api.z.ai", "open.bigmodel.cn", "dev.bigmodel.cn"].contains(c.host ?? ""),
              c.port == nil || c.port == 443, c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.path == "/api/anthropic" || c.path == "/api/anthropic/",
              let token = env["ANTHROPIC_AUTH_TOKEN"] as? String, !token.isEmpty,
              !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: "https://" + c.host! + "/api/monitor/usage/quota/limit") else { throw CLIQuotaError.invalidGLMConfiguration }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    public static func parse(data: Data, fetchedAt: Date = Date()) throws -> QuotaSnapshot {
        let root = try CLIQuotaSupport.object(data)
        if let success = root["success"] as? Bool, !success { throw CLIQuotaError.upstream }
        if let code = root["code"], CLIQuotaSupport.number(code) != 200 && CLIQuotaSupport.number(code) != 0 { throw CLIQuotaError.upstream }
        guard let body = root["data"] as? [String: Any], let limits = body["limits"] as? [[String: Any]] else { throw CLIQuotaError.invalidData }
        var metrics: [QuotaMetric] = []
        for item in limits {
            guard let type = item["type"] as? String else { throw CLIQuotaError.invalidData }
            // Only the two types defined by the official plugin have known semantics.
            guard ["TOKENS_LIMIT", "TIME_LIMIT"].contains(type) else { continue }
            guard let used = CLIQuotaSupport.number(item["percentage"]), (0...100).contains(used),
                  !metrics.contains(where: { $0.id == "glm-" + type }) else { throw CLIQuotaError.invalidData }
            metrics.append(.init(id: "glm-" + type, label: type == "TOKENS_LIMIT" ? "5 小时额度" : "每月 MCP 额度",
                                 used: used, total: 100, category: .subscription))
        }
        guard !metrics.isEmpty else { throw CLIQuotaError.noQuota }
        return .init(metrics: metrics, fetchedAt: fetchedAt)
    }
}
