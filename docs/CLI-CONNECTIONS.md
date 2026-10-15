# CLI 接入说明

账号别名用于 CLI 未提供昵称时的展示。邮箱和套餐只在控制台补充显示。每条账号必须对应独立登录来源；填写不同别名不会创建新的上游账号。

支持默认登录的 CLI 来源在“添加账号”中直接点击“读取并添加”即可；无需重复填写名称、凭据或默认目录。其他账号目录与备用文件位于“高级设置”。读取失败或取消时不保存空账号，同一默认 Codex/Claude 来源不能重复添加。

## Antigravity

默认选择“Antigravity CLI · 后台自动刷新”。安装并登录官方 `agy` 后添加一个账号即可，应用按刷新周期依次调用：

```bash
agy -p "/usage" --output-format json --print-timeout 20s
agy -p "/credits" --output-format json --print-timeout 20s
```

这些是官方内建只读命令，不启动模型对话。读取实际返回的分组 5 小时/每周额度及独立 AI Credits。默认消费者登录还会只读使用 agy 专用钥匙串记录，以同一账号查询 Google userinfo 和套餐资料，补充真实昵称、邮箱与套餐；邮箱和套餐只在控制台展示。登录记录不可用或资料接口失败时保留额度并显示提示，不猜测套餐。查询期间校验登录账号未变化，不混用另一账号的资料；不刷新或保存认证令牌。CLI 当前登录变化时查询对象也会变化；只允许一个自动查询账号。尚未确认独立认证目录的隔离协议，多账号继续使用各自快照。

为避免旧版本把 print 输入交给模型，启动前保守检查可执行文件是否包含内建只读命令分派标记；未知版本或 shell wrapper 拒绝自动查询，提示升级并可回退快照。使用官方原生 agy 可执行文件。

账号中的“备用快照路径”可填写同账号快照。主动查询失败才使用快照，并显示“备用快照”、原始数据时间和错误原因；未配置或快照过期则显示错误并保留上次成功数据。快照需要按下述步骤生成，应用不会自动修改 CLI 配置。仅 `/credits` 失败时保留已刷新的订阅额度并提示余额不可用。

官方依据：[无头模式中的只读命令](https://www.antigravity.google/docs/cli/headless/)、[/usage](https://www.antigravity.google/docs/cli/commands/usage/)、[/credits](https://www.antigravity.google/docs/cli/commands/credits/)。

### 配置备用或独立快照

1. 安装官方 `agy` 并登录账号。
2. 将本目录的 `antigravity-statusline.py` 复制到稳定路径，例如 `~/.local/share/quotadock/antigravity-statusline.py`。源码运行时脚本位于项目 `scripts/`，应用包中脚本与本说明同目录。需要 Python 3。
3. 在 `~/.gemini/antigravity-cli/settings.json` 合并以下配置；将脚本路径替换为实际绝对路径。

```json
{
  "statusLine": {
    "type": "command",
    "command": "python3 /绝对路径/antigravity-statusline.py --output ~/.local/share/quotadock/antigravity-personal.json",
    "stack_with_default": true
  }
}
```

已有自定义 statusLine 时保留原配置，不直接覆盖。可使用 wrapper 将同一份 stdin 分别传给原脚本和此桥接脚本，只显示原脚本 stdout，将此桥接脚本 stdout 重定向到 `/dev/null`。

4. 在 agy 中用 `/usage` 更新额度，并触发状态栏更新。
5. 在 QuotaDock 添加 Antigravity 工具，接入方式选“Antigravity CLI · 快照备用”（或在自动查询账号中填入“备用快照路径”）。添加账号，快照路径填 `~/.local/share/quotadock/antigravity-personal.json`。

这是被动快照，自动刷新只重读文件。超过 24 小时或窗口已过重置点会提示更新，不会自行推算恢复额度。官方 statusLine 未提供可确认的昵称和 AI credits 字段，分别使用账号别名和手动加购记录。

多账号应由各自登录的 CLI 环境输出到不同文件，不要把切换账号后的同一个快照同时绑定到多个账号。

官方依据：https://antigravity.google/docs/cli/statusline/

## Kimi Code CLI

1. 安装当前 Kimi Code CLI，完成登录。
2. 在该账号环境运行 `kimi web --no-open`，保持服务运行。
3. 添加 Kimi 工具，选择“Kimi Code CLI · 本地服务”。
4. 添加账号：本地地址填写启动横幅显示的地址，例如 `http://127.0.0.1:58627`；Token 单独填入“本地服务 Token”。不要把包含 `#token=` 的完整链接填进地址栏。

地址只允许回环 IP 和明确端口。端口被占用时 CLI 可能递增端口，以实际启动地址为准。Token 不是开放平台 API Key，会保存到系统钥匙串；服务 Token 轮换或端口变化后请更新。

自动读取五小时、周和月窗口中实际存在的项目，以及加购钱包、昵称、邮箱和套餐名。每个账号必须使用各自登录的服务和 Token；本工具不启动服务、登录或切换账号。无效登录、服务停止或不兼容的 CLI 版本会显示明确错误。

官方依据：https://www.kimi.com/code/docs/en/kimi-code-cli/reference/server-api.html

## 智谱 GLM Coding Plan

1. 按官方文档在 Claude Code 配置 GLM Coding Plan。
2. 添加“智谱 GLM”，选择“GLM Coding Plan · CLI 配置”。
3. 添加账号，选择该账号的完整 settings.json 文件路径，例如 `~/.claude-glm/settings.json`。

配置中的 `env` 需要包含 `ANTHROPIC_BASE_URL` 和 `ANTHROPIC_AUTH_TOKEN`。支持的官方地址：

- `https://open.bigmodel.cn/api/anthropic`
- `https://dev.bigmodel.cn/api/anthropic`
- `https://api.z.ai/api/anthropic`

QuotaDock 只读取这两个字段，按官方额度插件的协议发起只读请求，不运行 Claude 模型、安装插件、复制 Token 或修改配置。每个账号使用自己的配置文件。自定义代理不受支持；ZCode 自身 OAuth 登录尚未适配。

目前展示官方插件定义的 5 小时和每月 MCP 额度；未确认的窗口、昵称和套餐不会猜测。

官方依据：https://docs.z.ai/devpack/extension/usage-query-plugin

## Claude Code

默认选择“Claude Code · 后台自动刷新”。先在官方 Claude CLI 完成订阅账号登录；账号目录留空采用进程 `CLAUDE_CONFIG_DIR`，否则 `~/.claude`。多账号必须分别在独立 `CLAUDE_CONFIG_DIR` 登录，并在 QuotaDock 指定相同目录。

应用按 CLI 的命名规则读取此目录对应的 macOS 钥匙串；条目不存在时才读取同目录 `.credentials.json`。不会从自定义目录回退到默认账号，不复制或保存登录凭据，不读取浏览器 Cookie。后台钥匙串访问禁止交互，系统拒绝授权时显示错误。

使用 CLI 内置的 `GET https://api.anthropic.com/api/oauth/usage` 查询；可选 `/api/oauth/profile` 补充昵称、邮箱和套餐。这是 Claude Code 内部 OAuth 协议，不是承诺稳定的公共 API。只支持具备 `user:profile` 权限的完整登录，API Key / setup-token 不适用；不会运行 `claude -p` 或发起模型请求。令牌到期请让官方 CLI 更新登录，QuotaDock 下一次刷新会重读；本工具不轮换共享 refresh token。HTTP 429 后暂停此来源的主动请求 15 分钟。

展示实际返回的 5 小时、周和模型周窗口。`extra_usage` 的金额单位为美分，换算 USD 后显示为“额外用量月预算”，它是消费上限，不是已购买余额。未返回额度不显示成剩余 100%。

可在账号中填写同账号“备用快照路径”；查询失败时自动回退，标注备用及原始时间。超过 24 小时、未来文件时间或已过重置点的快照窗口不能当成当前额度。已有快照接入方式仍保留，不会擅自把历史账号绑定到本机当前登录。

### 配置备用或独立快照

使用同目录 `claude-statusline.py` 保存 `rate_limits` 快照，statusLine command 的写法与 Antigravity 类似，但不要添加 `stack_with_default`。每个 `CLAUDE_CONFIG_DIR` 使用不同快照文件。额度在官方 CLI 会话提供数据后更新。

## GitHub Copilot CLI

安装并登录官方 `copilot`。选择“GitHub Copilot CLI”，账号目录留空使用 `COPILOT_HOME` 或 `~/.copilot`，多账号填写各自已登录的独立目录。

读取器启动 `copilot --headless --no-auto-update --stdio`，通过 Content-Length JSON-RPC 调用 `account.getQuota` 和可选的 `auth.getStatus`。不会创建聊天会话。仅展示服务端返回的额度桶及重置时间；超额消费不是加购余额。旧 CLI 缺少该 RPC 时需要升级。

## Cursor CLI

在官方 `agent`（或 `cursor-agent`）中登录。选择“Cursor CLI”，留空读取 `~/.cursor/auth.json`，多账号明确选择各自登录文件。

使用该文件的 accessToken 查询官方 CLI 内置 DashboardService 的 `GetUsageLimitStatusAndActiveGrants` 和 `GetMe`。仅发送到 `https://api2.cursor.sh`，不读取浏览器 Cookie，不修改登录文件。只展示 `showInClient` 的有效额度项，币种 USD；没有额度项时明确显示“服务端未提供可展示额度”。这些内置接口可能随 CLI 更新，不保证包含所有套餐窗口。Token 过期需在 CLI 重新登录。

## Qwen Code CLI

选择“Qwen Code CLI · 本机用量”，留空采用 `QWEN_HOME` 或 `~/.qwen`。多账号使用独立目录；同目录的统计可能跨账号累计。

读取 `settings.json` 和 `usage_record.jsonl`，按 sessionId 去重并展示今日已保存 Token/请求统计。官方 TUI 的 `/clear` 会保存历史；未保存会话不计入。不会启动模型、运行 `/clear` 或读取对话正文。该数据仅在控制台展示为统计，不显示百分比、不触发低额度告警。没有找到可用的账号剩余额度查询协议，套餐额度可以手动补充。

## OpenRouter Ori CLI

选择“Ori CLI · 密钥额度”，填写账号的 `credentials.json`。留空优先 `~/.ori/credentials.json`，不存在时读取旧版 `~/.openrouter/credentials.json`。

支持旧版 `{key, createdAt, userId}` 与 version 1 plaintext 记录。当前读取器不支持 version 2 的 encrypted / OIDC / connect；不会绕过加密存储，也不会复用已退出记录中的旧密钥。

读取后调用官方 `GET /api/v1/key`，显示 `limit_remaining`（USD）。没有密钥上限时不会显示“无限账户余额”；累计消耗单独展示。账户总余额仍需选择“OpenRouter 官方 API”并提供 Management API Key。

## DeepSeek Harness

选择“DeepSeek Harness · API 余额”，填写独立 `DSH_HOME`；留空采用环境配置或 `~/.dsh`。

只读取 `.credentials.yaml` 旧版顶层或 version 1 `refs` 中的 `DEEPSEEK_API_KEY`，不存在时尝试同目录 `.env`。管理凭据文件需权限 600。支持普通、单引号和 JSON 双引号标量；拒绝 YAML 标签/别名/插值与重复键，不执行脚本，也不混入启动 QuotaDock 时的其他账号 API Key。

查询 `https://api.deepseek.com/user/balance`，按响应分别展示 CNY/USD 当前余额，不混合币种。当前支持 API Key 模式，Harness 浏览器登录的独立 grant 存储尚未验证，不会把其 token 当 API Key 使用。

## 版本与验证范围

上述五种新增读取器已通过合成数据与假 CLI 协议测试，尚未使用真实登录账号完成联网验收。CLI 内置协议升级或所选登录方式不受支持时会明确报错，并保留上次成功的数据和时间。

本轮主动查询：Antigravity 已在本机官方 CLI 验证 `/usage`、`/credits` 返回成功且 `num_turns=0`；Claude 的鉴权、接口格式和字段单位依据本机官方 CLI 2.1.85 实现核对。自动测试覆盖隔离、限流、取消、解析和快照回退；真实 Claude 验收因本机无可用 OAuth 登录而返回 loginRequired，尚未完成联网；未自动登录或更改凭据。
