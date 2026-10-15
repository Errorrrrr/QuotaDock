import Foundation
import Darwin

/// Bounded, noninteractive CLI transport. Never invokes a shell or exposes stderr.
enum CLIProcessError: Error, LocalizedError {
    case missing, launch, timeout, failed, invalid
    var errorDescription: String? {
        switch self {
        case .missing: return "未找到对应 CLI，请先安装并完成登录。"
        case .launch: return "无法启动 CLI，请检查安装与执行权限。"
        case .timeout: return "CLI 读取超时，请检查网络或登录状态。"
        case .failed: return "CLI 未能返回数据，请检查版本和当前账号登录状态。"
        case .invalid: return "CLI 返回格式不受支持，请检查版本与接入说明。"
        }
    }
}

enum CLIProcess {
    static func executable(_ names: [String]) throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + [home + "/.local/bin", home + "/.local/npm/bin", home + "/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        for name in names {
            for path in paths where path.hasPrefix("/") {
                let url = URL(fileURLWithPath: path).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: url.path) { return url }
            }
        }
        throw CLIProcessError.missing
    }

    static func directory(_ requested: String, defaultPath: String) throws -> String {
        let path = ((requested.isEmpty ? defaultPath : requested) as NSString).expandingTildeInPath
        var directory: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else { throw CLIQuotaError.missingFile }
        return path
    }

    static func environment(removing keys: [String] = []) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in keys { env.removeValue(forKey: key) }
        env["NO_COLOR"] = "1"
        return env
    }
}

final class CLIReadSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "QuotaDock.CLIReadSession")
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private let lock = NSLock()
    private var closed = false, completed = false, cancelled = false
    private var continuation: CheckedContinuation<[Data], Error>?
    private var buffer = Data(), received = 0
    private var replies: [Data] = []
    private let methods: [String]
    private let timeout: TimeInterval
    private let requiredReplies: Int
    private var timer: DispatchWorkItem?

    init(executable: URL, arguments: [String], environment: [String: String], methods: [String] = [], requiredReplies: Int? = nil, timeout: TimeInterval = 25) {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        self.methods = methods
        self.requiredReplies = requiredReplies ?? methods.count
        self.timeout = timeout
    }

    func run() async throws -> [Data] {
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

    private func start(_ continuation: CheckedContinuation<[Data], Error>) {
        self.continuation = continuation
        guard !cancelled else { finish(.failure(CancellationError())); return }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            self.lock.lock()
            guard !self.closed else { self.lock.unlock(); return }
            let data = handle.availableData
            self.lock.unlock()
            self.queue.async { self.receive(data) }
        }
        do {
            try process.run()
            let timer = DispatchWorkItem { [weak self] in self?.finishPartial(or: .timeout) }
            self.timer = timer
            queue.asyncAfter(deadline: .now() + max(0.05, timeout), execute: timer)
            if methods.isEmpty { try input.fileHandleForWriting.close() }
            else { try sendNext() }
        } catch { finish(.failure(CLIProcessError.launch)) }
    }

    private func receive(_ data: Data) {
        guard !completed else { return }
        if data.isEmpty {
            if methods.isEmpty {
                // EOF can precede Process termination notification by a few milliseconds.
                process.terminationHandler = { [weak self] process in
                    guard let self else { return }
                    self.queue.async { self.finish(process.terminationStatus == 0 ? .success([self.buffer]) : .failure(CLIProcessError.failed)) }
                }
                if !process.isRunning { finish(process.terminationStatus == 0 ? .success([buffer]) : .failure(CLIProcessError.failed)) }
            } else { finishPartial(or: .failed) }
            return
        }
        received += data.count
        guard received <= CLIQuotaSupport.maximumBytes else { finish(.failure(CLIProcessError.invalid)); return }
        buffer.append(data)
        guard !methods.isEmpty else { return }
        do {
            while let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                guard headerEnd.lowerBound <= 4096, let header = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else { throw CLIProcessError.invalid }
                let lengths = header.components(separatedBy: "\r\n").filter { $0.lowercased().hasPrefix("content-length:") }
                guard lengths.count == 1, let size = Int(lengths[0].dropFirst(15).trimmingCharacters(in: .whitespaces)), size > 0, size <= CLIQuotaSupport.maximumBytes else { throw CLIProcessError.invalid }
                let start = headerEnd.upperBound
                guard buffer.count >= start + size else { return }
                let body = Data(buffer[start..<(start + size)])
                buffer.removeSubrange(..<(start + size))
                let message = try CLIQuotaSupport.object(body)
                guard message["id"] as? Int == replies.count + 1 else { continue }
                if message["error"] != nil {
                    guard replies.count >= requiredReplies else { throw CLIProcessError.failed }
                    replies.append(Data("{}".utf8))
                } else {
                    guard let result = message["result"] as? [String: Any] else { throw CLIProcessError.invalid }
                    replies.append(try JSONSerialization.data(withJSONObject: result))
                }
                if replies.count == methods.count { finish(.success(replies)); return }
                try sendNext()
            }
            if buffer.count > 4096, buffer.range(of: Data("\r\n\r\n".utf8)) == nil { throw CLIProcessError.invalid }
        } catch { finish(.failure(error is CLIProcessError ? error : CLIProcessError.invalid)) }
    }

    private func finishPartial(or error: CLIProcessError) {
        if !methods.isEmpty, replies.count >= requiredReplies {
            finish(.success(replies + Array(repeating: Data("{}".utf8), count: methods.count - replies.count)))
        } else { finish(.failure(error)) }
    }

    private func sendNext() throws {
        let message: [String: Any] = ["jsonrpc": "2.0", "id": replies.count + 1, "method": methods[replies.count], "params": [String: String]()]
        let body = try JSONSerialization.data(withJSONObject: message)
        var frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        frame.append(body)
        try input.fileHandleForWriting.write(contentsOf: frame)
    }

    private func finish(_ result: Result<[Data], Error>) {
        guard !completed else { return }
        completed = true
        timer?.cancel(); timer = nil
        process.terminationHandler = nil
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close(); try? input.fileHandleForReading.close()
        lock.lock(); closed = true; try? output.fileHandleForReading.close(); lock.unlock()
        try? output.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            let process = process
            queue.asyncAfter(deadline: .now() + 0.5) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        }
        let saved = continuation; continuation = nil
        saved?.resume(with: result)
    }
}
