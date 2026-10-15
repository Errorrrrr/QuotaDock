import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Reads the official Codex app-server protocol without starting a model turn.
/// Each account's externalID is its CODEX_HOME; an empty value uses the CLI default.
/// Two entries with the same home refer to the same upstream account.
public struct CodexQuotaProvider: Sendable {
    private let executableOverride: URL?
    private let timeout: TimeInterval

    public init() {
        executableOverride = nil
        timeout = 20
    }

    init(executableURL: URL, timeout: TimeInterval = 20) {
        executableOverride = executableURL
        self.timeout = timeout
    }

    public func fetch(account: Account) async throws -> QuotaSnapshot {
        try Task.checkCancellation()
        let environment = ProcessInfo.processInfo.environment
        let executable = try executableOverride ?? Self.findExecutable(environment: environment)
        let requestedHome = account.externalID.trimmingCharacters(in: .whitespacesAndNewlines)
        let homePath = requestedHome.isEmpty
            ? environment["CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
            : requestedHome
        let expandedHome = (homePath as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard expandedHome.hasPrefix("/"),
              FileManager.default.fileExists(atPath: expandedHome, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw CodexQuotaError.invalidHome }

        var childEnvironment = environment
        childEnvironment["CODEX_HOME"] = expandedHome
        // A configured account must use its own CLI login, never an unrelated
        // token inherited from the process that launched QuotaDock.
        for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "CODEX_AUTH_TOKEN"] {
            childEnvironment.removeValue(forKey: key)
        }
        let session = CodexQuotaSession(executable: executable, environment: childEnvironment, timeout: timeout)
        let response = try await session.run()
        var snapshot = try Self.decodeRateLimits(response.rateLimits)
        if let data = response.account {
            let identity = Self.decodeAccount(data)
            snapshot.accountEmail = identity.email
            if let email = identity.email {
                snapshot.accountName = Self.readLocalDisplayName(home: expandedHome, expectedEmail: email)
            }
            snapshot.planName = identity.plan
        }
        return snapshot
    }

    static func decodeAccount(_ data: Data) -> (email: String?, plan: String?) {
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = response["account"] as? [String: Any], account["type"] as? String == "chatgpt" else { return (nil, nil) }
        func text(_ value: Any?) -> String? {
            guard let value = value as? String else { return nil }
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, cleaned.count <= 320,
                  cleaned.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            return cleaned
        }
        let plan = text(account["planType"])
        let names = ["free": "Free", "go": "Go", "plus": "Plus", "pro": "Pro", "prolite": "Pro Lite", "team": "Team", "business": "Business", "enterprise": "Enterprise", "edu": "Edu"]
        return (text(account["email"]), plan == "unknown" ? nil : plan.map { names[$0] ?? $0 })
    }

    /// The official account response has email/plan but no profile nickname.
    /// Read ONLY display metadata from this account's local ID token; never use
    /// these unverified claims for authentication or send them to another service.
    private static func readLocalDisplayName(home: String, expectedEmail: String) -> String? {
        let path = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("auth.json")
        guard let values = try? path.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true,
              let file = try? FileHandle(forReadingFrom: path) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 1_048_577), data.count <= 1_048_576 else { return nil }
        return localDisplayName(authData: data, expectedEmail: expectedEmail)
    }

    static func localDisplayName(authData: Data, expectedEmail: String) -> String? {
        guard authData.count <= 1_048_576,
              let auth = try? JSONDecoder().decode(CodexDisplayAuth.self, from: authData),
              let token = auth.tokens.idToken else { return nil }
        let pieces = token.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[1].count <= 65_536 else { return nil }
        var payload = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let bytes = Data(base64Encoded: payload),
              let profile = try? JSONDecoder().decode(CodexDisplayProfile.self, from: bytes),
              profile.email.caseInsensitiveCompare(expectedEmail) == .orderedSame else { return nil }
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80,
              name.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return name
    }

    private static func findExecutable(environment: [String: String]) throws -> URL {
        let searchPaths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
               "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        for directory in searchPaths where directory.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("codex")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw CodexQuotaError.cliNotFound
    }

    static func decodeRateLimits(_ data: Data) throws -> QuotaSnapshot {
        let response: CodexLimitsResponse
        do { response = try JSONDecoder().decode(CodexLimitsResponse.self, from: data) }
        catch { throw CodexQuotaError.invalidResponse }

        let buckets: [(String, CodexLimitBucket)]
        if let all = response.rateLimitsByLimitId, !all.isEmpty {
            buckets = all.keys.sorted().compactMap { key in all[key].map { (key, $0) } }
        } else if let bucket = response.rateLimits {
            buckets = [(bucket.limitId ?? "codex", bucket)]
        } else {
            throw CodexQuotaError.noQuota
        }

        var metrics: [QuotaMetric] = []
        for (key, bucket) in buckets {
            let prefix = buckets.count > 1 ? "\(bucket.limitName ?? key) · " : ""
            for (windowName, window) in [("primary", bucket.primary), ("secondary", bucket.secondary)] {
                guard let window else { continue }
                guard window.usedPercent.isFinite, window.usedPercent >= 0,
                      window.resetsAt?.isFinite != false else { throw CodexQuotaError.invalidResponse }
                // Reset timestamps are Unix seconds. Reject milliseconds and
                // extreme dates before they reach Foundation date formatters.
                if let reset = window.resetsAt, !(reset > 0 && reset <= 4_102_444_800) {
                    throw CodexQuotaError.invalidResponse
                }
                let label = prefix + Self.windowLabel(window.windowDurationMins, fallback: windowName)
                metrics.append(QuotaMetric(id: "\(key).\(windowName)", label: label,
                    used: window.usedPercent, total: 100, unit: "%",
                    resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) },
                    category: .subscription))
            }
            if let credits = bucket.credits {
                // Credits are additional usage units, not a percentage or USD.
                // The official schema declares balance as string|null and has
                // no currency field. Keep separate buckets separate; never sum.
                if credits.unlimited {
                    metrics.append(QuotaMetric(id: "\(key).credits", label: prefix + "额外额度",
                        used: 0, total: 0, unit: "点数", category: .purchased, isUnlimited: true))
                } else if let value = credits.balance {
                    guard let balance = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)),
                          balance.isFinite, balance >= 0,
                          credits.hasCredits || balance == 0 else { throw CodexQuotaError.invalidResponse }
                    metrics.append(QuotaMetric(id: "\(key).credits", label: prefix + "额外额度",
                        used: 0, total: 0, unit: "点数", remainingBalance: balance, category: .purchased))
                }
            }
        }
        guard !metrics.isEmpty else { throw CodexQuotaError.noQuota }
        return QuotaSnapshot(metrics: metrics)
    }

    private static func windowLabel(_ minutes: Int?, fallback: String) -> String {
        guard let minutes, minutes > 0 else { return fallback == "primary" ? "主要额度" : "次要额度" }
        if minutes == 10_080 { return "每周额度" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440) 天额度" }
        if minutes % 60 == 0 { return "\(minutes / 60) 小时额度" }
        return "\(minutes) 分钟额度"
    }
}

public enum CodexQuotaError: Error, LocalizedError, Equatable, Sendable {
    case cliNotFound, invalidHome, launchFailed, timedOut, connectionClosed, invalidResponse, noQuota, requestFailed

    public var errorDescription: String? {
        switch self {
        case .cliNotFound: return "未找到 Codex CLI。请先安装 Codex CLI，并使用 ChatGPT 账号登录。"
        case .invalidHome: return "Codex 配置目录不存在。请填写已登录账号使用的 CODEX_HOME 绝对路径。"
        case .launchFailed: return "无法启动 Codex CLI，请检查安装和执行权限。"
        case .timedOut: return "读取 Codex 额度超时，请检查网络后重试。"
        case .connectionClosed: return "Codex CLI 提前退出，请检查 CLI 版本和登录状态。"
        case .invalidResponse: return "Codex 返回的额度格式无法识别，请更新 CLI 后重试。"
        case .noQuota: return "此 Codex 账号暂未返回订阅额度或额外额度余额；API Key 用量不属于此额度。"
        case .requestFailed: return "Codex 未能返回额度。请确认该目录已使用 ChatGPT 账号登录，且 CLI 可以联网。"
        }
    }
}

private struct CodexDisplayAuth: Decodable {
    struct Tokens: Decodable {
        var idToken: String?
        enum CodingKeys: String, CodingKey { case idToken = "id_token" }
    }
    var tokens: Tokens
}

private struct CodexDisplayProfile: Decodable {
    var name: String
    var email: String
}

private struct CodexLimitsResponse: Decodable {
    var rateLimits: CodexLimitBucket?
    var rateLimitsByLimitId: [String: CodexLimitBucket]?
}

private struct CodexLimitBucket: Decodable {
    var limitId: String?
    var limitName: String?
    var primary: CodexLimitWindow?
    var secondary: CodexLimitWindow?
    var credits: CodexCredits?
}

private struct CodexCredits: Decodable {
    var hasCredits: Bool
    var unlimited: Bool
    var balance: String?
}

private struct CodexLimitWindow: Decodable {
    var usedPercent: Double
    var windowDurationMins: Int?
    var resetsAt: Double?
}

/// All mutable state and pipe writes are confined to queue. No server error
/// content or stderr is surfaced, because either may include credential data.
private struct CodexSessionResult: Sendable {
    let rateLimits: Data
    let account: Data?
}

private final class CodexQuotaSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "QuotaDock.CodexQuotaSession")
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let outputLock = NSLock()
    private var outputClosed = false
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<CodexSessionResult, Error>?
    private var buffer = Data()
    private var completed = false
    private var cancelled = false
    private var initialized = false
    private var rateLimits: Data?
    private var accountData: Data?
    private var accountReadFinished = false
    private var timeoutWork: DispatchWorkItem?

    init(executable: URL, environment: [String: String], timeout: TimeInterval) {
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        self.timeout = timeout
    }

    func run() async throws -> CodexSessionResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.start(continuation) }
            }
        } onCancel: {
            self.queue.async {
                self.cancelled = true
                if self.continuation != nil { self.finish(.failure(CancellationError())) }
            }
        }
    }

    private func start(_ continuation: CheckedContinuation<CodexSessionResult, Error>) {
        self.continuation = continuation
        if cancelled { finish(.failure(CancellationError())); return }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            self.outputLock.lock()
            guard !self.outputClosed else { self.outputLock.unlock(); return }
            // read(upToCount:) can wait for the requested byte count on a pipe;
            // availableData returns this readiness event's bytes immediately.
            let data = handle.availableData
            self.outputLock.unlock()
            self.queue.async { [weak self] in self?.receive(data) }
        }
        do {
            try process.run()
            let timeoutWork = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.finishQuotaIfAvailable(or: .timedOut)
            }
            self.timeoutWork = timeoutWork
            queue.asyncAfter(deadline: .now() + max(0.05, timeout), execute: timeoutWork)
            try send(["id": 1, "method": "initialize", "params": [
                "clientInfo": ["name": "quotadock", "title": "QuotaDock", "version": "0.1.0"]
            ]])
        } catch { finish(.failure(CodexQuotaError.launchFailed)) }
    }

    private func receive(_ data: Data) {
        guard !completed else { return }
        guard !data.isEmpty else { finishQuotaIfAvailable(or: .connectionClosed); return }
        buffer.append(data)
        guard buffer.count <= 1_048_576 else { finish(.failure(CodexQuotaError.invalidResponse)); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            do {
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw CodexQuotaError.invalidResponse
                }
                // Notifications and unrelated server requests have no matching id.
                guard let id = message["id"] as? Int, (1...3).contains(id) else { continue }
                // Identity is optional. Older CLIs may reject account/read, but
                // that must not discard a successful quota response.
                if id == 3, initialized {
                    accountReadFinished = true
                    if message["error"] == nil, let result = message["result"] as? [String: Any] {
                        accountData = try JSONSerialization.data(withJSONObject: result)
                    }
                    if let rateLimits { finish(.success(.init(rateLimits: rateLimits, account: accountData))); return }
                    continue
                }
                if message["error"] != nil { throw CodexQuotaError.requestFailed }
                guard let result = message["result"] as? [String: Any] else { throw CodexQuotaError.invalidResponse }
                if id == 1, !initialized {
                    initialized = true
                    try send(["method": "initialized", "params": [:]])
                    try send(["id": 2, "method": "account/rateLimits/read"])
                    try send(["id": 3, "method": "account/read", "params": ["refreshToken": false]])
                } else if id == 2, initialized {
                    rateLimits = try JSONSerialization.data(withJSONObject: result)
                    if accountReadFinished, let rateLimits {
                        finish(.success(.init(rateLimits: rateLimits, account: accountData)))
                        return
                    }
                }
            } catch {
                finish(.failure(error is CodexQuotaError ? error : CodexQuotaError.invalidResponse))
                return
            }
        }
    }

    private func finishQuotaIfAvailable(or error: CodexQuotaError) {
        if let rateLimits { finish(.success(.init(rateLimits: rateLimits, account: accountData))) }
        else { finish(.failure(error)) }
    }

    private func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func finish(_ result: Result<CodexSessionResult, Error>) {
        guard !completed else { return }
        completed = true
        timeoutWork?.cancel()
        timeoutWork = nil
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
        outputLock.lock()
        outputClosed = true
        try? output.fileHandleForReading.close()
        outputLock.unlock()
        try? output.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            // A hung CLI must not remain alive after a timeout or cancellation.
            let process = process
            queue.asyncAfter(deadline: .now() + 0.5) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        let saved = continuation
        continuation = nil
        saved?.resume(with: result)
    }
}
