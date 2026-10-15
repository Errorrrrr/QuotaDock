import Foundation
import CoreFoundation

public enum ClaudeSnapshotError: Error, LocalizedError {
    case missingPath, unreadable, tooLarge, stale, noLimits, invalid
    public var errorDescription: String? {
        switch self {
        case .missingPath: return "请设置 Claude 状态栏快照文件路径。"
        case .unreadable: return "无法读取 Claude 快照，请先在 Claude Code 中配置桥接脚本。"
        case .tooLarge: return "Claude 快照文件超过 1 MB。"
        case .stale: return "Claude 快照已超过 24 小时，请在对应 Claude 会话中更新。"
        case .noLimits: return "快照中暂未提供订阅额度；请在已登录的 Claude 会话中发送一条请求。"
        case .invalid: return "Claude 快照额度格式无效。"
        }
    }
}

public struct ClaudeSnapshotProvider: Sendable {
    public init() {}
    public func fetch(account: Account) async throws -> QuotaSnapshot {
        try Task.checkCancellation()
        guard !account.externalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClaudeSnapshotError.missingPath }
        let url = URL(fileURLWithPath: (account.externalID as NSString).expandingTildeInPath)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber else { throw ClaudeSnapshotError.unreadable }
        guard size.intValue <= 1_048_576 else { throw ClaudeSnapshotError.tooLarge }
        guard Date().timeIntervalSince(modified) <= 86_400 else { throw ClaudeSnapshotError.stale }
        guard let file = try? FileHandle(forReadingFrom: url) else { throw ClaudeSnapshotError.unreadable }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 1_048_577) else { throw ClaudeSnapshotError.unreadable }
        try Task.checkCancellation()
        return try Self.parse(data: data, modifiedAt: modified)
    }

    public static func parse(data: Data, modifiedAt: Date) throws -> QuotaSnapshot {
        guard data.count <= 1_048_576 else { throw ClaudeSnapshotError.tooLarge }
        guard Date().timeIntervalSince(modifiedAt) <= 86_400, modifiedAt.timeIntervalSinceNow <= 60 else { throw ClaudeSnapshotError.stale }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ClaudeSnapshotError.invalid }
        guard let limits = root["rate_limits"] as? [String: Any] else { throw ClaudeSnapshotError.noLimits }
        var metrics: [QuotaMetric] = []
        for (key, label) in [("five_hour", "5 小时额度"), ("seven_day", "每周额度")] {
            guard let value = limits[key], !(value is NSNull) else { continue }
            guard let window = value as? [String: Any], let used = number(window["used_percentage"]), used >= 0, used <= 100 else { throw ClaudeSnapshotError.invalid }
            var resetsAt: Date?
            if let raw = window["resets_at"], !(raw is NSNull) {
                guard let seconds = number(raw), seconds > 0, seconds < 253_402_300_800 else { throw ClaudeSnapshotError.invalid }
                resetsAt = Date(timeIntervalSince1970: seconds)
            }
            if let resetsAt, resetsAt <= Date() { continue }
            metrics.append(.init(id: key, label: label, used: used, total: 100, resetsAt: resetsAt, category: .subscription))
        }
        guard !metrics.isEmpty else { throw ClaudeSnapshotError.noLimits }
        return QuotaSnapshot(metrics: metrics, fetchedAt: modifiedAt)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
}
