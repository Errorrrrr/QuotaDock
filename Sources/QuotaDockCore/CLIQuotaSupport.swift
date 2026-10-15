import Foundation
import CoreFoundation

enum CLIQuotaError: Error, LocalizedError {
    case invalidData, noQuota, missingFile, stale, invalidLocalURL, missingToken, invalidGLMConfiguration, upstream
    var errorDescription: String? {
        switch self {
        case .invalidData: return "CLI 额度数据格式不受支持，请检查 CLI 版本与接入说明。"
        case .noQuota: return "CLI 暂未返回账号额度；缺失数据不会当作剩余 100%。"
        case .missingFile: return "无法读取配置或快照文件，请检查路径并先完成 CLI 接入。"
        case .stale: return "额度快照已过期，请在对应 CLI 中更新额度。"
        case .invalidLocalURL: return "Kimi 本地服务地址仅支持 http://127.0.0.1:端口 或 http://[::1]:端口，不可包含路径、凭据或查询参数。"
        case .missingToken: return "请填写 Kimi 本地服务启动时提供的访问 Token。"
        case .invalidGLMConfiguration: return "请选择 GLM 账号的 Claude Code settings.json，env 中需配置官方 ANTHROPIC_BASE_URL 和 ANTHROPIC_AUTH_TOKEN。"
        case .upstream: return "CLI 服务未能返回额度，请检查登录状态、套餐权限和版本。"
        }
    }
}

enum CLIQuotaSupport {
    static let maximumBytes = 1_048_576

    static func readFile(_ path: String) throws -> (Data, Date) {
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"),
              let attrs = try? FileManager.default.attributesOfItem(atPath: expanded),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let modified = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? NSNumber else { throw CLIQuotaError.missingFile }
        guard size.intValue <= maximumBytes else { throw CLIQuotaError.invalidData }
        guard let file = FileHandle(forReadingAtPath: expanded) else { throw CLIQuotaError.missingFile }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: maximumBytes + 1), data.count <= maximumBytes else { throw CLIQuotaError.invalidData }
        return (data, modified)
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= maximumBytes,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw CLIQuotaError.invalidData }
        return root
    }

    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }

    static func text(_ value: Any?, limit: Int = 120) -> String? {
        guard let value = value as? String else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= limit,
              !cleaned.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return cleaned
    }

    static func date(_ value: Any?) throws -> Date? {
        guard let value, !(value is NSNull) else { return nil }
        guard let string = value as? String else { throw CLIQuotaError.invalidData }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = format.date(from: string) { return date }
        format.formatOptions = [.withInternetDateTime]
        guard let date = format.date(from: string) else { throw CLIQuotaError.invalidData }
        return date
    }
}
