import Foundation

/// agy's built-in read-only print commands; no agent/model invocation.
public struct AntigravityCLIQuotaProvider: Sendable {
    private let profile: AntigravityAccountProfileProvider?
    private let command: @Sendable (String) async throws -> Data
    public init() {
        profile = AntigravityAccountProfileProvider()
        command = { name in
            let executable = try CLIProcess.executable(["agy"])
            try await Task.detached(priority: .utility) { try Self.requireReadOnlyCommands(executable) }.value
            try Task.checkCancellation()
            // Use the default CLI login, not unrelated ambient API/ADC/gateway credentials.
            let allowed = Set(["HOME", "PATH", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy", "SSL_CERT_FILE", "SSL_CERT_DIR"])
            var env = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
            env["NO_COLOR"] = "1"
            env["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true"
            let result = try await CLIReadSession(executable: executable,
                arguments: ["-p", "/" + name, "--output-format", "json", "--print-timeout", "20s"], environment: env).run()
            guard let data = result.first else { throw CLIProcessError.invalid }
            return data
        }
    }
    init(command: @escaping @Sendable (String) async throws -> Data, profile: AntigravityAccountProfileProvider? = nil) {
        self.command = command; self.profile = profile
    }

    public func fetch(account: Account) async throws -> QuotaSnapshot {
        try Task.checkCancellation()
        // No verified independent auth-profile selector is available in agy.
        guard account.externalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CLIQuotaError.invalidData }
        let before = try? await profile?.credential()
        var result = try Self.parseUsage(await command("usage"))
        do { result.metrics.append(try Self.parseCredits(await command("credits"))) }
        catch is CancellationError { throw CancellationError() }
        catch { result.notice = "订阅额度已更新，AI Credits 暂不可用。" }
        if let profile {
            do {
                let credential = try await profile.credential()
                if let before, before.subject != credential.subject { throw AntigravityIdentityError.changed }
                let identity = try await profile.fetch(credential)
                let latest = try await profile.credential()
                guard latest.subject == credential.subject else { throw AntigravityIdentityError.changed }
                result.accountName = identity.name
                result.accountEmail = identity.email
                result.planName = identity.plan
                if identity.plan == nil { result.notice = [result.notice, "未返回可识别的订阅套餐"].compactMap { $0 }.joined(separator: " · ") }
            } catch is CancellationError { throw CancellationError() }
            catch AntigravityIdentityError.changed { throw AntigravityIdentityError.changed }
            catch { result.notice = [result.notice, "账号资料暂不可用，显示别名"].compactMap { $0 }.joined(separator: " · ") }
        }
        try Task.checkCancellation()
        return result
    }

    // Older CLI builds may interpret -p input as a model prompt. Require the
    // dedicated read-only dispatcher before launching any print command. This
    // conservative check fails closed for wrappers/unknown builds; snapshot stays usable.
    static func requireReadOnlyCommands(_ executable: URL) throws {
        let values = try executable.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard (values.fileSize ?? 0) <= 256 * 1024 * 1024,
              let binary = try? Data(contentsOf: executable, options: .mappedIfSafe),
              binary.range(of: Data("/%s is answered by the CLI itself and is unavailable with --input-format stream-json; run it as its own --print /%s invocation".utf8)) != nil else {
            throw AntigravityCommandError.unsupported
        }
    }

    private static func payload(_ data: Data, name: String) throws -> [String: Any] {
        let root = try CLIQuotaSupport.object(data)
        guard root["status"] as? String == "SUCCESS", CLIQuotaSupport.number(root["num_turns"]) == 0,
              (root["conversation_id"] as? String ?? "").isEmpty,
              let command = root["command"] as? [String: Any], command["name"] as? String == name,
              let payload = command["data"] as? [String: Any] else { throw CLIProcessError.invalid }
        if let usage = root["usage"] as? [String: Any], let tokens = CLIQuotaSupport.number(usage["total_tokens"]), tokens != 0 { throw CLIProcessError.invalid }
        return payload
    }

    public static func parseUsage(_ data: Data) throws -> QuotaSnapshot {
        let payload = try payload(data, name: "usage")
        guard let groups = payload["groups"] as? [[String: Any]] else { throw CLIQuotaError.invalidData }
        var metrics: [QuotaMetric] = []
        for group in groups {
            guard let groupName = CLIQuotaSupport.text(group["name"]), let buckets = group["buckets"] as? [[String: Any]] else { throw CLIQuotaError.invalidData }
            let prefix = groupName == "Gemini Models" ? "Gemini" : groupName == "Claude and GPT models" ? "Claude/GPT" : groupName
            for bucket in buckets {
                guard let id = CLIQuotaSupport.text(bucket["id"]), let window = CLIQuotaSupport.text(bucket["window"]),
                      let remaining = CLIQuotaSupport.number(bucket["remaining_fraction"]), (0...1).contains(remaining) else { throw CLIQuotaError.invalidData }
                let label = prefix + " · " + (window == "5h" ? "5 小时" : window == "weekly" ? "每周" : window)
                metrics.append(.init(id: "agy-" + id, label: label, used: (1 - remaining) * 100, total: 100,
                                     resetsAt: try CLIQuotaSupport.date(bucket["reset_time"]), category: .subscription))
            }
        }
        guard !metrics.isEmpty, Set(metrics.map(\.id)).count == metrics.count else { throw CLIQuotaError.noQuota }
        return .init(metrics: metrics)
    }

    public static func parseCredits(_ data: Data) throws -> QuotaMetric {
        let payload = try payload(data, name: "credits")
        guard let credits = CLIQuotaSupport.number(payload["remaining_credits"]), credits >= 0 else { throw CLIQuotaError.invalidData }
        return .init(id: "agy-credits", label: "AI Credits", used: 0, total: 0, unit: "点", remainingBalance: credits, category: .balance)
    }
}

private enum AntigravityCommandError: LocalizedError {
    case unsupported
    var errorDescription: String? { "此 agy 安装无法确认支持只读额度查询，请更新官方 CLI；可继续使用快照备用。" }
}

private enum AntigravityIdentityError: LocalizedError {
    case changed
    var errorDescription: String? { "查询期间 Antigravity 登录账号发生变化，请重新刷新。" }
}
