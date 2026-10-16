import Foundation

public enum UpdateInstallError: LocalizedError {
    case failed(String)
    public var errorDescription: String? { if case .failed(let message) = self { return message }; return nil }
}

/// A single-use, disk-backed download. All delegate state is serialized by URLSession.
public final class AppUpdateDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession?
    private var cancelled = false
    private var continuation: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?
    private let destination: URL
    private let maximumBytes: Int64
    private let progress: @Sendable (Int64, Int64) -> Void

    public init(destination: URL, maximumBytes: Int64, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination; self.maximumBytes = maximumBytes; self.progress = progress
    }

    public static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        return ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(url.host?.lowercased() ?? "")
    }

    public func fetch(_ url: URL) async throws -> URL {
        guard Self.allowed(url) else { throw UpdateInstallError.failed("更新下载地址不受信任。") }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpCookieStorage = nil
                configuration.urlCredentialStorage = nil
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.timeoutIntervalForRequest = 30
                configuration.timeoutIntervalForResource = 600
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                self.session = session
                lock.unlock()
                var request = URLRequest(url: url)
                request.setValue("QuotaDock-Updater", forHTTPHeaderField: "User-Agent")
                session.downloadTask(with: request).resume()
            }
        }, onCancel: { self.cancel() })
    }

    public func cancel() {
        lock.lock(); cancelled = true; let session = session; lock.unlock()
        session?.invalidateAndCancel()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, Self.allowed(url) else {
            result = .failure(UpdateInstallError.failed("更新下载被重定向到不受信任的地址。"))
            completionHandler(nil); return
        }
        var clean = URLRequest(url: url)
        clean.setValue("QuotaDock-Updater", forHTTPHeaderField: "User-Agent")
        completionHandler(clean)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= maximumBytes, totalBytesExpectedToWrite <= maximumBytes else {
            result = .failure(UpdateInstallError.failed("更新文件超出允许大小。")); downloadTask.cancel(); return
        }
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard result == nil else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
                  let url = response.url, Self.allowed(url),
                  (try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= maximumBytes else {
                throw UpdateInstallError.failed("更新文件下载失败，请稍后重试。")
            }
            try FileManager.default.moveItem(at: location, to: destination)
            result = .success(destination)
        } catch { result = .failure(error) }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = continuation; self.continuation = nil
        let cancelled = cancelled; self.session = nil
        lock.unlock()
        let outcome = result ?? .failure(error ?? UpdateInstallError.failed("下载未完成。"))
        if cancelled {
            try? FileManager.default.removeItem(at: destination)
            continuation?.resume(throwing: CancellationError())
        } else { continuation?.resume(with: outcome) }
        session.finishTasksAndInvalidate()
    }
}
