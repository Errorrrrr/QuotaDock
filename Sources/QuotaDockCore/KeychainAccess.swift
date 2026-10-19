import Foundation
import Security

/// Legacy login-keychain ACL prompts are not reliably suppressed by LAContext.
/// Serialize all app-owned Security calls while changing the process-wide policy.
public enum KeychainAccess {
    private static let lock = NSRecursiveLock()

    public static func perform<T>(allowInteraction: Bool, _ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        // Explicit user operations retain the system's existing interaction policy.
        guard !allowInteraction else { return try operation() }
        var previous = DarwinBoolean(false)
        let readStatus = SecKeychainGetUserInteractionAllowed(&previous)
        guard readStatus == errSecSuccess else { throw AccessError(status: readStatus) }
        let status = SecKeychainSetUserInteractionAllowed(false)
        guard status == errSecSuccess else { throw AccessError(status: status) }
        defer { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return try operation()
    }

    private struct AccessError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "无法设置钥匙串后台访问模式（\(status)）。" }
    }
}
