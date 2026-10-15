import Foundation
import CoreFoundation

public enum QuotaProviderError: Error, LocalizedError, Equatable, Sendable {
    case invalidEndpoint
    case insecureEndpoint
    case invalidHeader
    case missingMappings
    case invalidJSON
    case missingValue(label: String)
    case invalidMetric(label: String)
    case invalidReset(label: String)
    case invalidUnit(label: String)
    case httpStatus(Int)
    case responseTooLarge
    case redirectRejected
    case connectionFailed

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "接口地址无效；请使用不含用户名、密码或片段的完整地址。"
        case .insecureEndpoint: return "接口必须使用 HTTPS；仅本机回环地址允许 HTTP。"
        case .invalidHeader: return "认证请求头配置无效。"
        case .missingMappings: return "请至少配置一组额度字段。"
        case .invalidJSON: return "接口未返回有效的 JSON 数据。"
        case .missingValue(let label): return "未找到「\(label)」对应的额度字段。"
        case .invalidMetric(let label): return "「\(label)」额度必须是有限的非负数。"
        case .invalidReset(let label): return "「\(label)」重置时间格式无效。"
        case .invalidUnit(let label): return "「\(label)」单位字段不存在或格式无效。"
        case .httpStatus(let status): return "接口返回 HTTP \(status)，请检查地址、权限和认证信息。"
        case .responseTooLarge: return "接口响应超过 2 MB 限制。"
        case .redirectRejected: return "接口发生重定向；请配置最终的 HTTPS 地址。"
        case .connectionFailed: return "无法连接额度接口，请检查网络和接口配置。"
        }
    }
}

public struct HTTPQuotaProvider: Sendable {
    public static let maximumResponseBytes = 2 * 1_024 * 1_024

    public init() {}

    public func fetch(tool: ToolDefinition, account: Account, token: String?) async throws -> QuotaSnapshot {
        let request = try Self.makeRequest(configuration: tool.http, account: account, token: token)
        return try Self.parse(data: await Self.fetchData(request: request), mappings: tool.http.mappings)
    }

    static func fetchData(request: URLRequest) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        if ["127.0.0.1", "::1", "[::1]"].contains(request.url?.host ?? "") {
            configuration.connectionProxyDictionary = [:]
        }
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: RejectRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw QuotaProviderError.connectionFailed }
            if (300..<400).contains(http.statusCode) { throw QuotaProviderError.redirectRejected }
            guard (200..<300).contains(http.statusCode) else { throw QuotaProviderError.httpStatus(http.statusCode) }
            guard response.expectedContentLength <= Int64(Self.maximumResponseBytes) else {
                throw QuotaProviderError.responseTooLarge
            }
            var data = Data()
            data.reserveCapacity(min(Int(max(0, response.expectedContentLength)), Self.maximumResponseBytes))
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < Self.maximumResponseBytes else { throw QuotaProviderError.responseTooLarge }
                data.append(byte)
            }
            return data
        } catch let error as QuotaProviderError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            // Transport errors may contain URLs and credentials. Surface a fixed
            // message instead of exposing localizedDescription or response data.
            throw QuotaProviderError.connectionFailed
        }
    }

    public static func makeRequest(configuration: HTTPConfiguration, account: Account, token: String?) throws -> URLRequest {
        guard !configuration.mappings.isEmpty else { throw QuotaProviderError.missingMappings }
        let accountID = account.externalID.isEmpty ? account.id.uuidString : account.externalID
        let url = try endpointURL(configuration.endpoint, accountID: accountID)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty {
            let validHeaderCharacters = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
            let header = configuration.authHeader
            let value = configuration.authPrefix + token
            guard !header.isEmpty,
                  header.unicodeScalars.allSatisfy({ validHeaderCharacters.contains($0) }),
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !["host", "content-length", "transfer-encoding", "connection"].contains(header.lowercased()) else {
                throw QuotaProviderError.invalidHeader
            }
            request.setValue(value, forHTTPHeaderField: header)
        }
        return request
    }

    public static func endpointURL(_ endpoint: String, accountID: String) throws -> URL {
        let template = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let marker = "quotadock-account-placeholder"
        guard let templateComponents = URLComponents(string: template.replacingOccurrences(of: "{accountId}", with: marker)),
              let templateHost = templateComponents.host,
              !templateHost.lowercased().contains(marker),
              templateComponents.user == nil, templateComponents.password == nil,
              templateComponents.fragment == nil else { throw QuotaProviderError.invalidEndpoint }
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let encodedID = accountID.addingPercentEncoding(withAllowedCharacters: unreserved),
              let components = URLComponents(string: template.replacingOccurrences(of: "{accountId}", with: encodedID)),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil,
              let url = components.url else { throw QuotaProviderError.invalidEndpoint }
        let isLoopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard scheme == "https" || (scheme == "http" && isLoopback) else {
            throw QuotaProviderError.insecureEndpoint
        }
        return url
    }

    public static func parse(data: Data, mappings: [QuotaMapping], fetchedAt: Date = Date()) throws -> QuotaSnapshot {
        guard data.count <= maximumResponseBytes else { throw QuotaProviderError.responseTooLarge }
        guard !mappings.isEmpty else { throw QuotaProviderError.missingMappings }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { throw QuotaProviderError.invalidJSON }

        let metrics = try mappings.map { mapping -> QuotaMetric in
            let unit: String
            if !mapping.unitPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let rawUnit = value(at: mapping.unitPath, in: object) as? String,
                      !rawUnit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      rawUnit.count <= 24,
                      !rawUnit.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw QuotaProviderError.invalidUnit(label: mapping.label)
                }
                unit = rawUnit.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                unit = mapping.unit
            }
            var resetsAt: Date?
            if !mapping.resetPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let rawReset = value(at: mapping.resetPath, in: object), let date = resetDate(rawReset) else {
                    throw QuotaProviderError.invalidReset(label: mapping.label)
                }
                resetsAt = date
            }
            if mapping.kind == .balance {
                guard let balanceObject = value(at: mapping.remainingPath, in: object) else {
                    throw QuotaProviderError.missingValue(label: mapping.label)
                }
                guard let balance = number(balanceObject), balance.isFinite, balance >= 0 else {
                    throw QuotaProviderError.invalidMetric(label: mapping.label)
                }
                return QuotaMetric(id: mapping.id.uuidString, label: mapping.label, used: 0, total: 0, unit: unit, resetsAt: resetsAt, remainingBalance: balance, category: mapping.category)
            }
            guard let totalObject = value(at: mapping.totalPath, in: object) else {
                throw QuotaProviderError.missingValue(label: mapping.label)
            }
            guard let total = number(totalObject), total.isFinite, total >= 0 else {
                throw QuotaProviderError.invalidMetric(label: mapping.label)
            }
            let used: Double
            if !mapping.remainingPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let remainingObject = value(at: mapping.remainingPath, in: object) else {
                    throw QuotaProviderError.missingValue(label: mapping.label)
                }
                guard let remaining = number(remainingObject), remaining.isFinite, remaining >= 0, remaining <= total else {
                    throw QuotaProviderError.invalidMetric(label: mapping.label)
                }
                used = total - remaining
            } else {
                guard let usedObject = value(at: mapping.usedPath, in: object) else {
                    throw QuotaProviderError.missingValue(label: mapping.label)
                }
                guard let parsedUsed = number(usedObject), parsedUsed.isFinite, parsedUsed >= 0 else {
                    throw QuotaProviderError.invalidMetric(label: mapping.label)
                }
                used = parsedUsed
            }
            return QuotaMetric(id: mapping.id.uuidString, label: mapping.label, used: used, total: total, unit: unit, resetsAt: resetsAt, category: mapping.category)
        }
        return QuotaSnapshot(metrics: metrics, fetchedAt: fetchedAt)
    }

    private static func number(_ object: Any) -> Double? {
        if let number = object as? NSNumber {
            // JSON booleans also bridge to NSNumber; they are not quota values.
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.doubleValue
        }
        if let string = object as? String { return Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func value(at path: String, in object: Any) -> Any? {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[", with: ".")
            .replacingOccurrences(of: "]", with: "")
        guard !normalized.isEmpty else { return nil }
        let components = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty }) else { return nil }
        var current: Any = object
        for component in components {
            if let dictionary = current as? [String: Any], let next = dictionary[String(component)] {
                current = next
            } else if let array = current as? [Any], let index = Int(component), index >= 0, index < array.count {
                current = array[index]
            } else { return nil }
        }
        return current is NSNull ? nil : current
    }

    private static func resetDate(_ object: Any) -> Date? {
        if let timestamp = number(object) {
            guard timestamp.isFinite, timestamp >= 0 else { return nil }
            // Unix seconds and milliseconds are accepted. Reject dates past
            // year 9999 so malformed values cannot reach UI date formatters.
            let seconds = timestamp >= 100_000_000_000 ? timestamp / 1_000 : timestamp
            guard seconds <= 253_402_300_799 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        guard let string = object as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

private final class RejectRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
