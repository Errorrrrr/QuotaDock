import Foundation
import Security
import LocalAuthentication

/// Optional display metadata for agy's consumer OAuth login. Never refreshes or
/// persists credentials, and never reads the IDE or another Google application's login.
struct AntigravityAccountProfileProvider: Sendable {
    struct Credential: Sendable {
        let token: String
        let subject: String
    }
    struct Profile: Sendable {
        var name: String?
        var email: String?
        var plan: String?
    }
    let load: @Sendable (URLRequest) async throws -> Data
    let read: @Sendable () throws -> Data
    init() {
        load = { try await HTTPQuotaProvider.fetchData(request: $0) }
        read = { try Self.keychainData() }
    }
    init(load: @escaping @Sendable (URLRequest) async throws -> Data, read: @escaping @Sendable () throws -> Data) {
        self.load = load; self.read = read
    }

    func credential() async throws -> Credential {
        let read = self.read
        let data = try await Task.detached(priority: .utility) { try read() }.value
        try Task.checkCancellation()
        return try Self.decode(data)
    }

    static func keychainData() throws -> Data {
        let context = LAContext()
        context.interactionNotAllowed = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword, kSecAttrService: "gemini", kSecAttrAccount: "antigravity",
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne, kSecUseAuthenticationContext: context
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, data.count <= CLIQuotaSupport.maximumBytes else { throw CLIQuotaError.missingFile }
        return data
    }

    static func decode(_ data: Data, now: Date = Date()) throws -> Credential {
        guard data.count <= CLIQuotaSupport.maximumBytes else { throw CLIQuotaError.invalidData }
        var decoded = data
        if let text = String(data: data, encoding: .utf8) {
            if text.hasPrefix("go-keyring-base64:") {
                guard let value = Data(base64Encoded: String(text.dropFirst("go-keyring-base64:".count))) else { throw CLIQuotaError.invalidData }
                decoded = value
            } else if text.hasPrefix("go-keyring-encoded:") {
                let hex = Array(text.dropFirst("go-keyring-encoded:".count))
                guard hex.count % 2 == 0 else { throw CLIQuotaError.invalidData }
                decoded = Data()
                for index in stride(from: 0, to: hex.count, by: 2) {
                    guard let byte = UInt8(String(hex[index...index + 1]), radix: 16) else { throw CLIQuotaError.invalidData }
                    decoded.append(byte)
                }
            }
        }
        let record = try CLIQuotaSupport.object(decoded)
        guard record["auth_method"] as? String == "consumer",
              let token = record["token"] as? [String: Any],
              let bearer = CLIQuotaSupport.text(token["access_token"], limit: 16384),
              let expiry = try CLIQuotaSupport.date(token["expiry"]), expiry > now,
              let jwt = CLIQuotaSupport.text(record["id_token"], limit: 16384) else { throw CLIQuotaError.invalidData }
        let pieces = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3 else { throw CLIQuotaError.invalidData }
        var payload = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let claimsData = Data(base64Encoded: payload) else { throw CLIQuotaError.invalidData }
        let claims = try CLIQuotaSupport.object(claimsData)
        guard ["https://accounts.google.com", "accounts.google.com"].contains(claims["iss"] as? String ?? ""),
              let subject = CLIQuotaSupport.text(claims["sub"]) else { throw CLIQuotaError.invalidData }
        // The unverified ID-token claim is only a continuity hint. Display data
        // must come from Google's authenticated userinfo response with the same ID.
        return .init(token: bearer, subject: subject)
    }

    func fetch(_ credential: Credential) async throws -> Profile {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
        request.httpMethod = "GET"
        request.setValue("Bearer " + credential.token, forHTTPHeaderField: "Authorization")
        let user = try CLIQuotaSupport.object(await load(request))
        guard CLIQuotaSupport.text(user["id"]) == credential.subject else { throw CLIQuotaError.invalidData }
        var profile = Profile(name: CLIQuotaSupport.text(user["name"]), email: CLIQuotaSupport.text(user["email"], limit: 254))
        request.url = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"mode":"HEALTH_CHECK","metadata":{"ideType":"IDE_UNSPECIFIED","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}"#.utf8)
        do { profile.plan = try Self.plan(await load(request)) }
        catch is CancellationError { throw CancellationError() }
        catch { /* Optional plan failure must not discard authenticated identity. */ }
        return profile
    }

    static func plan(_ data: Data) throws -> String? {
        let root = try CLIQuotaSupport.object(data)
        // An API free tier can coexist with a paid Google AI subscription.
        // Prefer the paid tier; never infer Free when a paid tier is incomplete.
        let tier = root["paidTier"] as? [String: Any] ?? root["currentTier"] as? [String: Any]
        guard let name = CLIQuotaSupport.text(tier?["name"])?.lowercased() else { return nil }
        // Code Assist service tiers (including free-tier/standard-tier) do not
        // establish an Antigravity subscription. Only explicit subscription names qualify.
        switch name {
        case "google ai pro", "google one ai pro", "gemini code assist in google one ai pro": return "Google AI Pro"
        case "google ai ultra", "google one ai ultra", "gemini code assist in google one ai ultra": return "Google AI Ultra"
        default: return nil
        }
    }
}
