import Foundation
import Security
import QuotaDockCore

/// Each account owns one credential in QuotaDock's own keychain namespace.
/// Nothing in this store searches or modifies another application's credentials.
struct KeychainStore {
    private let service = "com.quotadock.credentials"

    func token(for accountID: UUID, allowInteraction: Bool = true) throws -> String? {
        var query = baseQuery(for: accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = try KeychainAccess.perform(allowInteraction: allowInteraction) {
            SecItemCopyMatching(query as CFDictionary, &result)
        }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(operation: "读取", status: status) }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw KeychainError(operation: "读取", status: errSecDecode)
        }
        return token
    }

    /// A nil or empty value explicitly removes the credential.
    func setToken(_ token: String?, for accountID: UUID) throws {
        let query = baseQuery(for: accountID)
        guard let token, !token.isEmpty else {
            let status = try KeychainAccess.perform(allowInteraction: true) { SecItemDelete(query as CFDictionary) }
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError(operation: "删除", status: status)
            }
            return
        }

        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8)]
        let updateStatus = try KeychainAccess.perform(allowInteraction: true) { SecItemUpdate(query as CFDictionary, attributes as CFDictionary) }
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError(operation: "更新", status: updateStatus)
        }
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = try KeychainAccess.perform(allowInteraction: true) { SecItemAdd(item as CFDictionary, nil) }
        guard addStatus == errSecSuccess else { throw KeychainError(operation: "保存", status: addStatus) }
    }

    private func baseQuery(for accountID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

private struct KeychainError: LocalizedError {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        if status == errSecInteractionNotAllowed { return "后台无法访问账号凭据，请在账号管理中重新保存 Key 以授权访问。" }
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "系统错误 \(status)"
        return "无法\(operation)账号凭据：\(detail)"
    }
}
