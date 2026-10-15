import Foundation
import Darwin

public enum AntigravityDesktopError: LocalizedError {
    case notRunning, unavailable, accountChanged
    public var errorDescription: String? {
        switch self {
        case .notRunning: return "请先打开并登录 Antigravity 桌面应用。"
        case .unavailable: return "无法读取 Antigravity 桌面状态，请确认应用已启动并登录。"
        case .accountChanged: return "查询期间 Antigravity 桌面账号发生变化，请重新刷新。"
        }
    }
}

/// Talks only to the running official desktop server. Session material stays in memory.
public struct AntigravityDesktopQuotaProvider: Sendable {
    enum Method: String { case status = "GetUserStatus", quota = "RetrieveUserQuotaSummary" }
    struct Endpoint: Sendable {
        let pid: Int32
        let executable: String
        let ports: [Int]
        let csrf: String
    }
    private let connect: @Sendable () async throws -> (@Sendable (Method) async throws -> Data)
    public init() {
        connect = {
            let endpoint = try await Self.discover()
            // Probe only ports owned by this exact official process; the desktop
            // also has an HTTPS UI port, which rejects an HTTP RPC request.
            var selected: Int?
            for port in endpoint.ports {
                try Task.checkCancellation()
                do {
                    _ = try await Self.request(.status, endpoint: endpoint, port: port)
                    selected = port; break
                } catch is CancellationError { throw CancellationError() }
                catch { continue }
            }
            guard let port = selected else { throw AntigravityDesktopError.unavailable }
            return { method in try await Self.request(method, endpoint: endpoint, port: port) }
        }
    }
    init(read: @escaping @Sendable (Method) async throws -> Data) { connect = { read } }

    public func fetch(account: Account) async throws -> QuotaSnapshot {
        guard account.externalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CLIQuotaError.invalidData }
        let read = try await connect()
        let before = try Self.identity(await read(.status))
        let quota = try await read(.quota)
        let after = try Self.identity(await read(.status))
        guard before.email.caseInsensitiveCompare(after.email) == .orderedSame else { throw AntigravityDesktopError.accountChanged }
        var result = try Self.parseQuota(quota)
        result.accountName = after.name
        result.accountEmail = after.email
        result.planName = after.plan
        if let credits = after.credits { result.metrics.append(credits) }
        else { result.notice = "桌面应用未返回 AI Credits" }
        if after.plan == nil { result.notice = [result.notice, "桌面应用未返回套餐"].compactMap { $0 }.joined(separator: " · ") }
        try Task.checkCancellation()
        return result
    }

    struct Identity {
        let name: String?
        let email: String
        let plan: String?
        let credits: QuotaMetric?
    }
    static func identity(_ data: Data) throws -> Identity {
        let root = try CLIQuotaSupport.object(data)
        guard let user = root["userStatus"] as? [String: Any], let email = CLIQuotaSupport.text(user["email"], limit: 254) else { throw AntigravityDesktopError.unavailable }
        let tier = user["userTier"] as? [String: Any]
        var credits: QuotaMetric?
        if let all = tier?["availableCredits"] as? [[String: Any]] {
            let matches = all.filter { $0["creditType"] as? String == "GOOGLE_ONE_AI" }
            if matches.count == 1 {
                // Official proto3 Credits.credit_amount is a non-optional int64:
                // its omitted value is zero, but an absent credit record is unknown.
                let raw = matches[0]["creditAmount"] ?? 0
                let amount = (raw as? String).flatMap(Int64.init).map(Double.init) ?? CLIQuotaSupport.number(raw)
                if let value = amount, value.isFinite, value >= 0, value.rounded() == value {
                    credits = .init(id: "agy-credits", label: "AI Credits", used: 0, total: 0, unit: "点", remainingBalance: value, category: .balance)
                }
            }
        }
        return .init(name: CLIQuotaSupport.text(user["name"]), email: email, plan: CLIQuotaSupport.text(tier?["name"]), credits: credits)
    }

    static func parseQuota(_ data: Data) throws -> QuotaSnapshot {
        let root = try CLIQuotaSupport.object(data)
        guard let response = root["response"] as? [String: Any], let groups = response["groups"] as? [[String: Any]] else { throw CLIQuotaError.invalidData }
        var metrics: [QuotaMetric] = []
        for group in groups {
            guard let name = CLIQuotaSupport.text(group["displayName"]), let buckets = group["buckets"] as? [[String: Any]] else { throw CLIQuotaError.invalidData }
            let prefix = name == "Gemini Models" ? "Gemini" : name == "Claude and GPT models" ? "Claude/GPT" : name
            for bucket in buckets {
                if bucket["disabled"] as? Bool == true { continue }
                guard let id = CLIQuotaSupport.text(bucket["bucketId"]), let window = CLIQuotaSupport.text(bucket["window"]),
                      let remaining = CLIQuotaSupport.number(bucket["remainingFraction"]), (0...1).contains(remaining) else { throw CLIQuotaError.invalidData }
                // remainingFraction is a proto oneof: unlike credits, absence is unknown.
                metrics.append(.init(id: "agy-" + id, label: prefix + " · " + (window == "5h" ? "5 小时" : window == "weekly" ? "每周" : window), used: (1 - remaining) * 100, total: 100,
                                     resetsAt: try CLIQuotaSupport.date(bucket["resetTime"]), category: .subscription))
            }
        }
        guard !metrics.isEmpty, Set(metrics.map(\.id)).count == metrics.count else { throw CLIQuotaError.noQuota }
        return .init(metrics: metrics)
    }

    static func allowedExecutable(_ path: String) -> Bool {
        let suffix = "/Antigravity.app/Contents/Resources/bin/language_server"
        return path == "/Applications" + suffix || path == FileManager.default.homeDirectoryForCurrentUser.path + "/Applications" + suffix
    }
    private static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
    private static func run(_ executable: String, _ arguments: [String]) async throws -> String {
        let data = try await CLIReadSession(executable: URL(fileURLWithPath: executable), arguments: arguments, environment: ["PATH": "/usr/bin:/bin:/usr/sbin"], timeout: 5).run()
        guard let first = data.first, let text = String(data: first, encoding: .utf8) else { throw AntigravityDesktopError.unavailable }
        return text
    }
    static func sessionToken(command: String, executable: String) throws -> String {
        guard allowedExecutable(executable), command.hasPrefix(executable + " "), command.contains("--standalone") else { throw AntigravityDesktopError.unavailable }
        let expression = try NSRegularExpression(pattern: #"(?:^|\s)--csrf_token(?:=|\s+)([^\s]+)"#)
        let matches = expression.matches(in: command, range: NSRange(command.startIndex..., in: command))
        guard matches.count == 1, let range = Range(matches[0].range(at: 1), in: command), let token = CLIQuotaSupport.text(String(command[range]), limit: 4096) else { throw AntigravityDesktopError.unavailable }
        return token
    }
    static func ports(_ output: String) -> [Int] {
        Array(Set(output.split(separator: "\n").compactMap { line -> Int? in
            guard line.hasPrefix("n127.0.0.1:"), let port = Int(line.dropFirst("n127.0.0.1:".count)), (1...65535).contains(port) else { return nil }
            return port
        })).sorted()
    }
    private static func listeningPorts(_ pid: Int32) async throws -> [Int] {
        ports(try await run("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fn"]))
    }
    private static func discover() async throws -> Endpoint {
        let list: String
        do { list = try await run("/usr/bin/pgrep", ["-u", String(getuid()), "-x", "language_server"]) }
        catch is CancellationError { throw CancellationError() }
        catch { throw AntigravityDesktopError.notRunning }
        let pids = list.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }.filter { pid in executablePath(pid).map(allowedExecutable) == true }
        guard pids.count == 1, let pid = pids.first, let executable = executablePath(pid) else { throw AntigravityDesktopError.notRunning }
        let command = try await run("/bin/ps", ["-ww", "-p", String(pid), "-o", "command="]).trimmingCharacters(in: .whitespacesAndNewlines)
        let token = try sessionToken(command: command, executable: executable)
        let ports = try await listeningPorts(pid)
        guard !ports.isEmpty, ports.count <= 8 else { throw AntigravityDesktopError.unavailable }
        return .init(pid: pid, executable: executable, ports: ports, csrf: token)
    }
    private static func request(_ method: Method, endpoint: Endpoint, port: Int) async throws -> Data {
        guard executablePath(endpoint.pid) == endpoint.executable, try await listeningPorts(endpoint.pid).contains(port) else { throw AntigravityDesktopError.unavailable }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/" + method.rawValue)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(endpoint.csrf, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        request.httpBody = Data((method == .quota ? #"{"forceRefresh":true}"# : "{}").utf8)
        return try await HTTPQuotaProvider.fetchData(request: request)
    }
}
