import Foundation

/// Reads the explicitly selected Harness credential store, without merging ambient API keys.
public struct DeepSeekCLIQuotaProvider: Sendable {
    private let load: @Sendable (URLRequest) async throws -> Data
    public init() { load = { try await HTTPQuotaProvider.fetchData(request: $0) } }
    init(load: @escaping @Sendable (URLRequest) async throws -> Data) { self.load = load }

    public func fetch(account: Account) async throws -> QuotaSnapshot {
        let home = try CLIProcess.directory(account.externalID, defaultPath: ProcessInfo.processInfo.environment["DSH_HOME"] ?? "~/.dsh")
        let managed = home + "/.credentials.yaml"
        var token: String?
        if FileManager.default.fileExists(atPath: managed) {
            let attrs = try FileManager.default.attributesOfItem(atPath: managed)
            guard let mode = attrs[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0 else { throw DeepSeekCLIError.permissions }
            token = try Self.credential(CLIQuotaSupport.readFile(managed).0, separator: ":")
        }
        let dotenv = home + "/.env"
        if token == nil, FileManager.default.fileExists(atPath: dotenv) {
            token = try Self.credential(CLIQuotaSupport.readFile(dotenv).0, separator: "=")
        }
        guard let token else { throw DeepSeekCLIError.missingKey }
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        return try Self.parse(try await load(request))
    }

    /// Deliberately accepts only flat scalar credentials, never YAML tags, aliases or interpolation.
    static func credential(_ data: Data, separator: Character) throws -> String? {
        guard let text = String(data: data, encoding: .utf8) else { throw CLIQuotaError.invalidData }
        let lines = text.split(whereSeparator: \.isNewline)
        let versioned = separator == ":" && lines.contains { $0.hasPrefix("version:") }
        if versioned {
            let versions = lines.filter { $0.hasPrefix("version:") }
            guard versions.count == 1, versions[0].dropFirst(8).trimmingCharacters(in: .whitespaces) == "1" else { throw CLIQuotaError.invalidData }
        }
        var found: String?
        var section = ""
        var refsIndent: Int?
        for line in lines {
            guard !line.hasPrefix("\t"), let split = line.firstIndex(of: separator) else { continue }
            let indent = line.prefix(while: { $0 == " " }).count
            let key = line[..<split].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
            if separator == ":", indent == 0 {
                section = key
                refsIndent = nil
            } else if versioned, section == "refs", refsIndent == nil {
                refsIndent = indent
            }
            if separator == ":" {
                if versioned { guard section == "refs", indent == refsIndent else { continue } }
                else { guard indent == 0 else { continue } }
            }
            guard key == "DEEPSEEK_API_KEY" || (separator == "=" && key == "export DEEPSEEK_API_KEY") else { continue }
            guard found == nil else { throw CLIQuotaError.invalidData }
            var value = line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") {
                guard let decoded = try? JSONDecoder().decode(String.self, from: Data(value.utf8)) else { throw CLIQuotaError.invalidData }
                value = decoded
            } else if value.hasPrefix("'") && value.hasSuffix("'") {
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            }
            guard value.hasPrefix("sk-"), value.count <= 4096, value.count > 3,
                  value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-.")).contains($0) }) else { throw CLIQuotaError.invalidData }
            found = value
        }
        return found
    }

    static func parse(_ data: Data) throws -> QuotaSnapshot {
        let root = try CLIQuotaSupport.object(data)
        guard let balances = root["balance_infos"] as? [[String: Any]], !balances.isEmpty else { throw CLIQuotaError.invalidData }
        let metrics = try balances.enumerated().map { index, balance -> QuotaMetric in
            guard let currency = CLIQuotaSupport.text(balance["currency"]), ["CNY", "USD"].contains(currency),
                  let text = balance["total_balance"] as? String, let amount = Double(text), amount.isFinite, amount >= 0 else { throw CLIQuotaError.invalidData }
            return .init(id: "dsh-balance-\(index)", label: "API 余额", used: 0, total: 0, unit: currency, remainingBalance: amount, category: .balance)
        }
        return .init(metrics: metrics)
    }
}

enum DeepSeekCLIError: Error, LocalizedError {
    case permissions, missingKey
    var errorDescription: String? {
        switch self {
        case .permissions: return "Harness 凭据文件必须仅当前用户可读写（chmod 600）。"
        case .missingKey: return "此 Harness 目录没有 DEEPSEEK_API_KEY。当前支持 CLI API Key 账号；浏览器登录账号的余额协议尚未验证。"
        }
    }
}
