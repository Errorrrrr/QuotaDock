# 额度数据源与接入边界

核验日期：2026-10-15。证据包含官方文档、本机官方 CLI 实现及分项真实验收；各项联网验证范围分别注明。

## Codex

通过本机 `codex app-server --listen stdio://` 调用官方 JSON-RPC 协议：先 `initialize`，收到成功响应后发送 `initialized`，再调用 `account/rateLimits/read` 和 `account/read`（`refreshToken: false`）。不会发起模型对话、登录或账号切换。

- `account/read` 的 ChatGPT 账号返回 `email` 与 `planType`；官方响应不包含昵称。昵称来自同一 CODEX_HOME 的 ID token 显示资料，且必须与官方返回的邮箱匹配；菜单栏和弹窗优先显示昵称，控制台列表补充邮箱及套餐。昵称不可用时使用配置别名，绝不从邮箱截取伪造昵称，未知套餐不猜测。身份查询失败不丢弃已取得的额度，配置名称不被覆盖。
- 优先读取 `rateLimitsByLimitId`，兼容 `rateLimits`；每个额度桶包含 `primary`、`secondary` 窗口。
- `usedPercent` 是已用百分比；`windowDurationMins` 是窗口分钟数；`resetsAt` 是 Unix 秒时间戳。缺失额度不代表已使用 0%。
- 此接口描述 ChatGPT/Codex 订阅额度，不能拿来表示 OpenAI API 余额。API 用量和费用接口是另一类数据。
- 每条账号配置的 `externalID` 是已登录的 `CODEX_HOME` 目录；为空时采用当前环境的 `CODEX_HOME`，未设置时采用 `~/.codex`。同一路径代表同一登录账号，修改展示名称不会创建另一个上游账号。
- 额度请求的凭据管理和必要令牌刷新由 Codex CLI 完成。为展示昵称，QuotaDock 有限读取相同 CODEX_HOME 下 auth.json 的 ID token，仅提取 name/email 并校验邮箱一致性；不提取 access_token/refresh_token，不保存或输出令牌，不将未经验签的显示资料用于认证。文件/昵称缺失、过大或账号不匹配时回退到手动别名。独立账号需要事先在各自目录完成官方 CLI 登录；本工具不会自动登录。
- CLI 路径按进程 `PATH`、`~/.local/bin`、`/opt/homebrew/bin`、`/usr/local/bin` 等位置查找。一次查询最长 20 秒；失败时显示脱敏错误。
- app-server 是有公开文档的官方集成入口；CLI 仍将该命令标记为实验性，应保留版本兼容与错误处理。

官方来源：[App Server](https://learn.chatgpt.com/docs/app-server)、[凭据存储](https://learn.chatgpt.com/docs/auth#credential-storage)、[OpenAI API 用量示例](https://developers.openai.com/cookbook/examples/completions_usage_api)。

## Claude

默认主动查询：复用 Claude Code 的 OAuth 登录，调用其内置 `/api/oauth/usage` 和可选 `/api/oauth/profile`（固定主机 `api.anthropic.com`、Bearer、`anthropic-beta: oauth-2025-04-20`）。协议、钥匙串命名、profile 昵称/套餐映射以及 extra_usage 美分单位，已核对本机官方 CLI 2.1.85 的实现。它不是公开稳定 API，CLI 版本变化可能需要跟进。

只读取所选 CLAUDE_CONFIG_DIR 对应的凭据；自定义目录的钥匙串服务带路径 SHA-256 前 8 位，不会回退到默认账号。钥匙串不存在才读同目录 `.credentials.json`，访问被拒绝或内容无效时不另选账号。后台禁止钥匙串交互。OAuth 过期由 CLI 更新，本工具不刷新或轮换共享令牌；429 后退避 15 分钟。可配置同账号快照作为失败备用，保留原始时间。

实际返回的 `five_hour`、`seven_day` 和已确认模型周限额按百分比显示；extra_usage 月预算按美分换算 USD，不能称为预付余额。真实验收：本机未找到可用 OAuth 登录（loginRequired），尚未完成 Claude 账号联网；合成接口与隔离/回退测试通过。

以下为保留的快照方式：

Claude Code 官方 `statusLine` 的输入 JSON 提供 `rate_limits.five_hour`、`rate_limits.seven_day`，各自包含 `used_percentage` 与 `resets_at`。可由本地桥接脚本保存为账号专属快照供 QuotaDock 读取，无需提取 OAuth 凭据。

这些数据仅在支持的 Pro/Max 订阅或带额度限制的网关场景出现，而且通常在会话第一次 API 响应后才有。窗口字段可独立缺失，到达重置时间后会被移除。快照只代表最近一次观测，不保证后台实时刷新。

`CLAUDE_CONFIG_DIR` 可为多账号分别配置目录；每个目录应输出到不同快照文件，并明确绑定展示账号。原有 statusLine 应保留，不可直接覆盖。API 组织的 Usage/Cost API 与 Claude 个人订阅额度不同；Enterprise Analytics 也有单独的权限与密钥类型。

官方来源：[Status line 数据及额度窗口](https://code.claude.com/docs/en/statusline)、[CLAUDE_CONFIG_DIR](https://code.claude.com/docs/en/env-vars)、[Usage and Cost API](https://platform.claude.com/docs/en/manage-claude/usage-cost-api)。

## DeepSeek

官方 `GET https://api.deepseek.com/user/balance` 使用 Bearer API Key，返回 `balance_infos[]`。`total_balance` 是包括赠金与充值的当前可用余额（字符串数值），不是最初总配额；`currency` 可以是 `CNY` 或 `USD`。

JSON 映射可使用 `balance_infos.0.total_balance` 作为余额，币种必须与所选数组条目的 `currency` 一致。赠金和充值余额分别是 `granted_balance`、`topped_up_balance`，不应把任何一个当作已使用金额。多个 API Key 如果属于同一上游账号，读取的仍可能是同一账号余额。

官方来源：[查询余额](https://api-docs.deepseek.com/api/get-user-balance/)。

## OpenRouter

官方 `GET https://openrouter.ai/api/v1/credits` 使用 Bearer **Management key**。`data.total_credits` 是累计购买的额度，`data.total_usage` 是已用额度，差值为余额，单位 USD。普通推理 API Key 不能假定有权限；官方文档列出普通密钥可能返回 403。

官方来源：[Get remaining credits](https://openrouter.ai/docs/api/api-reference/credits/get-remaining-credits)。

## Cursor

官方团队 Admin API 的 `POST https://api.cursor.com/teams/spend` 使用 Basic Authentication（API Key 作用户名，密码为空），需要管理权限与 `admin:*` scope。

`spendCents` 是当期按量收费金额，不含套餐内用量；`overallSpendCents` 包含两者；`effectivePerUserLimitDollars` 是当前生效的用户支出限额。费用字段不能直接等同个人套餐剩余比例。未找到个人订阅稳定公开的额度导出命令。本次使用已安装官方 CLI 内置的 DashboardService 协议读取可展示 credit grants，不使用浏览器 Cookie；此接口不等于所有套餐窗口的完整公开 API。

官方来源：[API 鉴权和权限](https://cursor.com/docs/api)、[团队 Spending Data](https://cursor.com/docs/account/teams/admin-api)。

## 硅基流动

旧接口 `GET /v1/user/info` **已在 2026-08-14 停止服务**，不能作为当前可用余额模板。旧文档和 OpenAPI 中的 `data.totalBalance`、`chargeBalance`、`balance` 不代表接口仍有效。官方表示替代账户接口上线后会另行公告；现阶段采用手工记录或用户已有的受支持接口。

官方来源：[2026-08-11 接口停用公告](https://docs.siliconflow.cn/docs/release-notes/overview)。

## 展示与扩展约定

订阅百分比、请求次数、API 货币余额分别建模，不跨币种或跨账户相加。失败时保留最近一次成功值并标注时间与状态。账号切换作为单独能力扩展，不由查询额度顺带执行。

## 各工具 CLI 能力与本应用适配状态

2026-10-15 再次逐项核验。现有 11 个预设中，10 个确认有官方 CLI 或命令行入口；硅基流动本次未查到自有官方账号 CLI。存在 CLI 不等于 QuotaDock 已实现其额度读取，会话消耗也不等于账号剩余额度。

| 工具 | 官方 CLI / 命令行入口 | 额度相关证据 | QuotaDock 状态 |
| --- | --- | --- | --- |
| Codex | `codex` | [app-server](https://learn.chatgpt.com/docs/app-server) 账号和额度 JSON-RPC | 已实现，按 CODEX_HOME 隔离 |
| Claude Code | `claude` | 本机官方 CLI 内置 OAuth usage/profile；[statusLine](https://code.claude.com/docs/en/statusline) | 已实现后台主动查询与快照备用；本机无 OAuth 登录，联网未验收 |
| Kimi Code | `kimi` | [当前 /usage](https://www.kimi.com/code/docs/en/kimi-code-cli/reference/slash-commands.html) 包含额度；[本地 Server API](https://www.kimi.com/code/docs/en/kimi-code-cli/reference/server-api.html) 有结构化额度和用户资料 | 已实现认证本地服务读取；真实账号待验证 |
| Antigravity | `agy` | [只读 print 命令](https://www.antigravity.google/docs/cli/headless/) `/usage`、`/credits`；statusLine 备用 | 已实现后台查询和快照回退；新读取器真实账号验证通过 |
| 智谱 GLM | [官方 ZCode Agent CLI](https://github.com/zai-org/ZCode/blob/main/README.en.md) | [官方 Claude Code 查询插件](https://docs.z.ai/devpack/extension/usage-query-plugin) 可查个人 Coding Plan；ZCode 桌面额度面板不等于已确认 CLI 查询协议 | 已实现指定 Claude Code 配置读取及官方插件同源额度查询；ZCode 独立登录待适配 |
| Cursor | `agent` / `cursor-agent` | 已安装官方 CLI 2026.06.04-5fd875e 内置 DashboardService protobuf 定义 | 已实现 CLI 登录文件 + 可展示额度查询，真实账号待验证 |
| 通义千问 | `qwen` | [usageHistoryService](https://github.com/QwenLM/qwen-code/blob/main/packages/core/src/services/usageHistoryService.ts) 的已保存本机统计 | 已实现统计读取；未提供账号剩余额度 |
| GitHub Copilot | `copilot` | [官方 SDK 额度接口](https://docs.github.com/en/copilot/how-tos/copilot-sdk/features/usage-and-billing) `account.getQuota` | 已实现官方 RPC，真实账号待验证 |
| OpenRouter | `ori` | 当前官方发布物 `ori auth --help`、内置 CredentialRecord schema、[key API](https://openrouter.ai/docs/api/api-reference/api-keys/get-current-key) | 已实现明文 CLI 登录的密钥限额；encrypted/OIDC/connect 未支持 |
| DeepSeek | `dsh` | 已安装官方 credentials-local 源码及 [余额 API](https://api-docs.deepseek.com/api/get-user-balance/) | 已实现 DSH_HOME 内 API Key 读取；浏览器登录 grant 未支持 |
| 硅基流动 | 未确认自有官方 CLI | 旧账户接口已停用 | 手动 / 自定义接口 |

### Kimi 已实现的接入

当前官方 CLI 的 `kimi web --no-open` 可启动本地服务。账号必须明确填写回环 IP、端口和服务 Token；不自动发现或启动服务，不读取 OAuth 存储，不发起模型对话。只访问 oauth/usage 与 oauth/userinfo，禁止重定向；Token 按账号存入钥匙串，修改服务地址/端口后需重新填写。

- `GET /api/v1/oauth/usage`：`kind: ok` 时返回 usages 和 extraUsage；窗口可含 limit5h、limit7d、monthTotal、monthCode，usedRatio 是 0–1 已用比例，resetAt 是 RFC3339 时间。只展示存在的窗口。
- extraUsage 为可空的加购钱包，包含 balanceCents、totalCents、currency 以及月度限额/消费字段，不能和套餐百分比混合。
- `GET /api/v1/oauth/userinfo`：含 nickname、userLevelName，email 为可选字段，可以覆盖昵称、套餐、邮箱需求。
- 接口失败可能以 HTTP 成功封装中的 `kind: error` 返回，必须检查业务状态；解析与请求流程已实现并通过合成协议测试，尚未用真实 Kimi 账号验证。
- 当前 Kimi 已有新 TypeScript CLI；旧 Python CLI 仓库已归档，不能直接套用旧协议。

工具编辑器只允许选择该工具已实现的读取器。待适配并不表示服务商没有 CLI；已确认但本应用未实现的能力不得伪装成可用选项。Gemini 已按产品要求从预设移除，改为 Antigravity。所有已确认有 CLI 的预设均有对应读取选项，但能力和登录方式覆盖不同；会话消耗不会被转换成账号余额。

## 本轮新增接入的边界

- Antigravity 主动查询：官方 `agy -p "/usage"` 和 `/credits` 的结构化 JSON；验证 status=SUCCESS、command.name、num_turns=0，不将自然语言模型输出当额度。保守校验内建只读分派标记后才启动 print；未知版本回退快照。新 Swift 读取器真实账号返回分组 5 小时/每周额度及 AI Credits，未发起模型对话。只跟随当前 CLI 登录，单一自动账号；独立多账号继续使用快照。
- Antigravity 备用快照：解析官方 statusLine 的 `product: antigravity`、`quota.*.remaining_fraction/reset_time`、`email`、`plan_tier`；快照最长 24 小时，已过重置时间的窗口不再当作新鲜额度。桥接脚本仅保存这些字段，不保存会话、项目路径、认证信息。官方该快照没有确认的昵称/加购余额字段，昵称回退到别名，加购由用户另行补充，绝不显示为 0。
- GLM：指定 Claude Code `settings.json`，只取 `env.ANTHROPIC_BASE_URL` 与 `env.ANTHROPIC_AUTH_TOKEN`；严格允许 HTTPS 官方 `api.z.ai`、`open.bigmodel.cn`、`dev.bigmodel.cn`，请求 `/api/monitor/usage/quota/limit`。协议依据 [官方插件源码](https://github.com/zai-org/zai-coding-plugins/blob/main/plugins/glm-plan-usage/skills/usage-query-skill/scripts/query-usage.mjs)，Authorization 使用原 Token 而非擅加 Bearer。仅解析已确认的 TOKENS_LIMIT（5 小时）和 TIME_LIMIT（每月 MCP），未知类型不猜测。未实现读取 ZCode 自身 OAuth。
- 不执行任意插件脚本、不启动模型会话；账户切换仍未实现。CLI 可升级导致协议变化，错误会保留最后成功值并标记失败。
- 已有配置当前只有 Codex，无 Gemini 账号需要迁移。Gemini 旧品牌识别仅为兼容旧配置保留，不再作为新增入口。

## 2026-10-15 CLI 扩展实现依据

- Copilot：[官方 SDK client.ts](https://github.com/github/copilot-sdk/blob/main/nodejs/src/client.ts)、[RPC schema](https://github.com/github/copilot-sdk/blob/main/nodejs/src/generated/rpc.ts)。Content-Length 帧协议；`remainingPercentage` 是剩余百分比；无限套餐单独处理，overage 不推算成购买余额。独立 COPILOT_HOME，剔除继承的 GitHub Token，错误不回显 stderr。身份失败不丢弃额度。
- Cursor：官方安装版本 `2026.06.04-5fd875e` 的 `index.js` 中 `aiserver.v1.DashboardService` / `ActiveCreditGrant` / `GetMeResponse`。按 grantId 区分、毫秒到期时间、分转换 USD，仅显示 showInClient 项。没有令牌刷新实现，过期时需在 CLI 登录。查询地址固定，拒绝重定向。
- Qwen：[官方历史记录格式](https://github.com/QwenLM/qwen-code/blob/main/packages/core/src/services/usageHistoryService.ts)。按 sessionId 最后记录生效；只读取已保存聚合统计，不读取聊天内容。昵称与套餐不能从聚合统计推导。官方当前认证文档已移除旧 Qwen OAuth，不能套用旧免费 OAuth 配额。
- Ori：2026-10-15 下载官方 `https://openrouter.ai/labs/ori/ori-darwin-arm64` 到临时目录，仅执行 help、核对内置格式，没有安装、登录或运行 Agent。`ori auth` 只输出身份与来源，不导出密钥；因此读取明确选择的受支持明文文件。尊重 version 2 的加密、OIDC 与退出标记，不回退读取残留 key。`limit_remaining: null` 表示密钥未设限，不是账户无限余额。
- Harness：已安装官方 `@deepseek-ai/dsh-credentials-local` 的严格 CredentialRef→string YAML，取指定目录的 DEEPSEEK_API_KEY，仅请求官方余额。新版 `deepseek-account-platform` 的 grant 属于另一认证机制，本版不混用。多币种余额独立展示。

具体配置步骤及限制见 [CLI 接入说明](CLI-CONNECTIONS.md)。上述新增五项通过协议夹具测试；本机 Cursor 没有 auth.json，未进行真实账号查询，其余新增账号也未完成真实联网验收。

### Antigravity 昵称与套餐补充

自动来源可选读取 agy 消费者登录专用钥匙串（service `gemini`、account `antigravity`，禁止弹出认证交互）。兼容 go-keyring 原始 JSON、base64 与旧 hex 编码；要求 consumer 登录和未过期 access token。不读取 IDE 或其他 Google 应用凭据，不轮换或保存令牌。CLI 子进程使用环境白名单，避免继承无关 API/ADC/gateway 登录覆盖。

使用同一 bearer 请求 Google `oauth2/v2/userinfo`，返回 ID 须匹配登录记录 subject；昵称及邮箱来自认证响应，不使用未验证 JWT 直接生成显示资料。再只读调用 `daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`（HEALTH_CHECK），优先 paidTier.name，避免将 API Free 层误当订阅套餐。查询前后检查登录主体，发现变化时丢弃混合结果；资料失败保留额度，套餐失败保留已确认身份。

依据：[官方 go-keyring macOS 编码](https://github.com/zalando/go-keyring/blob/master/keyring_darwin.go)、[Google Code Assist 协议实现](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/server.ts) 及本机官方 agy 实现。该内部套餐协议可能随服务更新；备用 statusLine 快照仍保留。

套餐修正（0.1.1）：真实响应中 currentTier=free-tier、name=Gemini Code Assist for individuals 是 Code Assist 服务层；日常和生产接口结果相同，不能据此断言 Antigravity Free/Pro/Ultra。仅规范化明确的 Google AI/Google One Pro、Ultra 订阅名称，其他结果不作为套餐，显示未识别提示。旧版“套餐返回通过”仅证明字段存在，不能证明其订阅含义正确，本条修正该验收结论。
