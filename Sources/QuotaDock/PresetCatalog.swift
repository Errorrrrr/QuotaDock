import QuotaDockCore

struct ToolPreset: Identifiable {
    var id: String { name }
    let name: String
    let method: String
    let makeTool: () -> ToolDefinition
}

enum PresetCatalog {
    static let items: [ToolPreset] = [
        .init(name: "Codex", method: "官方 CLI 订阅额度", makeTool: { .init(name: "Codex", symbol: "terminal", colorHex: "15977D", provider: .codexCLI, brandID: "codex") }),
        .init(name: "Claude", method: "CLI 登录 · 后台自动刷新", makeTool: { .init(name: "Claude", symbol: "asterisk", colorHex: "C17752", provider: .claudeOAuth, brandID: "claude") }),
        .init(name: "DeepSeek", method: "官方 API / Harness CLI", makeTool: {
            .init(name: "DeepSeek", symbol: "water.waves", colorHex: "4B64DC", provider: .httpJSON,
                  http: .init(endpoint: "https://api.deepseek.com/user/balance", mappings: [.init(label: "API 余额", usedPath: "", totalPath: "", remainingPath: "balance_infos.0.total_balance", unit: "", kind: .balance, unitPath: "balance_infos.0.currency", category: .balance)]), brandID: "deepseek")
        }),
        .init(name: "OpenRouter", method: "官方 API / Ori CLI", makeTool: {
            .init(name: "OpenRouter", symbol: "arrow.triangle.branch", colorHex: "8067C9", provider: .httpJSON,
                  http: .init(endpoint: "https://openrouter.ai/api/v1/credits", mappings: [.init(label: "API 余额", usedPath: "data.total_usage", totalPath: "data.total_credits", unit: "USD", category: .purchased)]), brandID: "openrouter")
        }),
        cli("Cursor", symbol: "cursorarrow.rays", color: "577584", brandID: "cursor", provider: .cursorCLI),
        manual("硅基流动", symbol: "cpu", color: "6C5CE7", brandID: "siliconflow"),
        .init(name: "Kimi", method: "CLI 本地服务 · 套餐及加购", makeTool: { .init(name: "Kimi", symbol: "moon.stars", colorHex: "577584", provider: .kimiCLI, brandID: "kimi") }),
        .init(name: "智谱 GLM", method: "CLI 配置 · Coding Plan", makeTool: { .init(name: "智谱 GLM", symbol: "sparkles", colorHex: "4B64DC", provider: .glmCLI, brandID: "glm") }),
        cli("通义千问", symbol: "cloud", color: "A15BB5", brandID: "qwen", provider: .qwenCLI),
        .init(name: "Antigravity", method: "桌面登录 · 套餐及 AI Credits", makeTool: { .init(name: "Antigravity", symbol: "sparkles", colorHex: "4B64DC", provider: .antigravityDesktop, brandID: "antigravity") }),
        cli("GitHub Copilot", symbol: "chevron.left.forwardslash.chevron.right", color: "577584", brandID: "copilot", provider: .copilotCLI)
    ]

    private static func cli(_ name: String, symbol: String, color: String, brandID: String, provider: ProviderKind) -> ToolPreset {
        .init(name: name, method: provider.displayName, makeTool: { .init(name: name, symbol: symbol, colorHex: color, provider: provider, brandID: brandID) })
    }

    private static func manual(_ name: String, symbol: String, color: String, brandID: String) -> ToolPreset {
        .init(name: name, method: "手动 / 自定义接口", makeTool: { .init(name: name, symbol: symbol, colorHex: color, brandID: brandID) })
    }

    struct CLIInformation {
        let title: String
        let detail: String
    }

    static func cliInformation(for tool: ToolDefinition) -> CLIInformation? {
        switch tool.resolvedBrandID {
        case "cursor": return .init(title: "Cursor CLI · 本机登录", detail: "读取 CLI 登录文件，通过内置 DashboardService 协议查询可展示额度与账号姓名。服务端未返回的套餐窗口不推算。")
        case "kimi": return .init(title: "Kimi Code CLI · 本地服务", detail: "运行 kimi web --no-open，在账号中填写本地地址和访问 Token。自动读取套餐窗口、加购余额、昵称和套餐；各账号需连接各自已登录的服务。")
        case "qwen": return .init(title: "Qwen Code CLI · 本机用量", detail: "读取独立 QWEN_HOME 的已保存统计，不调用模型。统计在控制台展示；CLI 未提供账号剩余额度，可手动补充。")
        case "claude": return .init(title: "Claude Code · 后台自动刷新", detail: "复用 CLI OAuth 登录查询订阅额度和额外用量预算。支持独立配置目录；可配置同账号快照作为失败备用。")
        case "antigravity": return .init(title: "Antigravity · 后台自动刷新", detail: "桌面接入读取当前登录账号的套餐、AI Credits 和额度，需要桌面应用运行。CLI 与快照仍可单独选择；不会混用两处登录账号。")
        case "copilot": return .init(title: "GitHub Copilot CLI · 官方额度", detail: "通过官方 account.getQuota RPC 读取高级请求、聊天、补全额度与重置时间。支持独立 COPILOT_HOME；超额消费不当作加购余额。")
        case "glm": return .init(title: "GLM Coding Plan · CLI 配置", detail: "选择已配置 GLM 的 Claude Code settings.json，查询官方插件使用的 Coding Plan 额度接口。支持智谱与 Z.ai，不启动模型会话；ZCode 独立登录尚未适配。")
        case "openrouter": return .init(title: "Ori CLI · 密钥额度", detail: "读取所选 Ori 明文登录文件，通过官方接口获取密钥剩余额度。加密/OIDC 存储暂不支持，账户总余额仍可用官方 API 接入。")
        case "deepseek": return .init(title: "DeepSeek Harness · API 余额", detail: "读取独立 DSH_HOME 内的 DEEPSEEK_API_KEY 并查询官方余额。不需要重复填写 Key；浏览器登录暂不支持。")
        default: return nil
        }
    }

    static func explanation(for provider: ProviderKind) -> String {
        switch provider {
        case .copilotCLI: return "通过官方 Copilot CLI RPC 读取账号额度，使用独立 COPILOT_HOME 区分账号。"
        case .cursorCLI: return "读取 Cursor CLI 登录账号，通过 CLI 内置接口查询额度。"
        case .qwenCLI: return "读取 Qwen CLI 本机已保存统计，明确区分用量与账号剩余额度。"
        case .oriCLI: return "读取 Ori CLI 明文登录记录，查询 OpenRouter 密钥剩余额度。"
        case .deepseekCLI: return "使用 DeepSeek Harness 配置中的 API Key 查询官方余额。"
        case .manual: return "手动填写服务商显示的额度，适用于补充记录或尚未适配自动读取的服务。"
        case .httpJSON: return "连接官方或自有 HTTPS JSON 接口。支持多窗口、余额和字段映射，每个账号分别保存凭据。"
        case .codexCLI: return "通过本机 Codex CLI 的官方 app-server 读取订阅限额；需安装 CLI 并已登录 ChatGPT 账号。API Key 模式不提供订阅额度。"
        case .antigravitySnapshot: return "通过官方 agy statusLine 桥接快照读取额度，无需提取登录凭据；在账号中配置独立快照文件。"
        case .kimiCLI: return "连接已登录的 Kimi Code CLI 本地服务；只读取额度和账号信息，访问 Token 单独存入钥匙串。"
        case .glmCLI: return "读取指定 Claude Code 配置中的 GLM 认证信息，直接请求官方 Coding Plan 额度接口，不复制凭据或调用模型。"
        case .claudeOAuth: return "使用 Claude Code 本地 OAuth 登录，后台查询 5 小时、每周额度及额外用量预算。可指定同账号备用快照；登录过期由官方 CLI 更新。"
        case .antigravityDesktop: return "读取正在运行的官方桌面应用，仅在本机只读查询套餐和额度。不读取钥匙串，会话令牌只在内存使用，不保存、不输出。"
        case .antigravityCLI: return "通过 agy 的只读命令自动查询当前登录账号额度和 AI Credits，不调用模型。可指定备用快照。"
        case .claudeSnapshot: return "读取 Claude Code 官方 statusLine 输出的额度快照，不提取 OAuth 凭据。需要手动配置状态栏桥接脚本。"
        }
    }
}
