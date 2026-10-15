import Foundation

extension ToolDefinition {
    /// Stable preset identity, including configurations written before brandID existed.
    public var resolvedBrandID: String? {
        if let id = brandID { return id }
        // Older configurations predate brandID; recognize their existing presets.
        let normalizedName = name.lowercased().filter { !$0.isWhitespace }
        switch normalizedName {
        case "codex", "openaicodex": return "codex"
        case "claude", "claudecode": return "claude"
        case "deepseek": return "deepseek"
        case "openrouter": return "openrouter"
        case "cursor": return "cursor"
        case "硅基流动", "siliconflow": return "siliconflow"
        case "kimi", "moonshot": return "kimi"
        case "智谱", "智谱glm", "glm", "z.ai", "zai": return "glm"
        case "通义千问", "千问", "qwen": return "qwen"
        case "gemini", "googlegemini": return "gemini" // Legacy data only; no longer offered as a preset.
        case "antigravity", "googleantigravity": return "antigravity"
        case "githubcopilot", "copilot": return "copilot"
        default:
            if provider == .codexCLI { return "codex" }
            if [.claudeOAuth, .claudeSnapshot].contains(provider) { return "claude" }
            let brands: [ProviderKind: String] = [.antigravityDesktop: "antigravity", .antigravityCLI: "antigravity", .antigravitySnapshot: "antigravity", .kimiCLI: "kimi", .glmCLI: "glm", .copilotCLI: "copilot", .cursorCLI: "cursor", .qwenCLI: "qwen", .oriCLI: "openrouter", .deepseekCLI: "deepseek"]
            if let brand = brands[provider] { return brand }
            return nil
        }
    }

    /// Only implemented quota readers belong in the selectable connection menu.
    public var availableProviders: [ProviderKind] {
        switch resolvedBrandID {
        case "codex": return [.codexCLI, .httpJSON, .manual]
        case "claude": return [.claudeOAuth, .claudeSnapshot, .httpJSON, .manual]
        case "deepseek": return [.deepseekCLI, .httpJSON, .manual]
        case "openrouter": return [.oriCLI, .httpJSON, .manual]
        case "cursor": return [.cursorCLI, .manual, .httpJSON]
        case "qwen": return [.qwenCLI, .manual, .httpJSON]
        case "copilot": return [.copilotCLI, .manual, .httpJSON]
        case "antigravity": return [.antigravityDesktop, .antigravityCLI, .antigravitySnapshot, .manual, .httpJSON]
        case "kimi": return [.kimiCLI, .manual, .httpJSON]
        case "glm": return [.glmCLI, .manual, .httpJSON]
        default: return [.manual, .httpJSON]
        }
    }

    public var hasOfficialHTTPPreset: Bool {
        switch resolvedBrandID {
        case "deepseek": return http.endpoint == "https://api.deepseek.com/user/balance"
        case "openrouter": return http.endpoint == "https://openrouter.ai/api/v1/credits"
        default: return false
        }
    }

    public func connectionTitle(for provider: ProviderKind) -> String {
        switch provider {
        case .codexCLI: return "Codex CLI · 本机登录"
        case .claudeOAuth, .antigravityCLI, .antigravityDesktop: return provider.displayName
        case .claudeSnapshot: return "Claude Code CLI · 快照备用"
        case .antigravitySnapshot: return "Antigravity CLI · 快照备用"
        case .kimiCLI: return "Kimi Code CLI · 本地服务"
        case .glmCLI: return "GLM Coding Plan · CLI 配置"
        case .copilotCLI, .cursorCLI, .qwenCLI, .oriCLI, .deepseekCLI: return provider.displayName
        case .httpJSON:
            if hasOfficialHTTPPreset {
                return resolvedBrandID == "deepseek" ? "DeepSeek 官方 API" : "OpenRouter 官方 API"
            }
            return "自定义 JSON 接口"
        case .manual: return "手动记录"
        }
    }
}


extension ToolDefinition {
    /// A preset keeps its identity when renamed or connected through another reader.
    /// Custom tools remain independent unless their display names are the same.
    public func representsSameTool(as other: ToolDefinition) -> Bool {
        if let brand = resolvedBrandID, brand == other.resolvedBrandID { return true }
        let normalized = name.lowercased().filter { !$0.isWhitespace }
        return !normalized.isEmpty && normalized == other.name.lowercased().filter { !$0.isWhitespace }
    }
}

extension AppConfiguration {
    /// Reject newly introduced duplicates without making legacy duplicates uneditable.
    public func toolPreventingSave(_ candidate: ToolDefinition) -> ToolDefinition? {
        let previous = tools.first { $0.id == candidate.id }
        return tools.first { existing in
            existing.id != candidate.id && candidate.representsSameTool(as: existing)
                && !(previous?.representsSameTool(as: existing) ?? false)
        }
    }
}
