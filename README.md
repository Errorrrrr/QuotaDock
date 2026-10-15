# QuotaDock

macOS 菜单栏账号额度工具。支持按工具分组、同一工具多个账号、多个额度窗口、余额、重置时间和低额度提示。界面使用原生 AppKit，无 SwiftUI 或第三方运行时依赖，最低 macOS 14。

菜单栏下拉面板使用 360 宽紧凑账号列表：工具 Logo、名称、额度和重置时间集中展示，面板高度随内容调整，多账号可滚动。双额度账号约占 72 高度，更新时间在悬停提示中；只有一个工具时省去筛选栏。

订阅窗口（5 小时、每周）与额外购买额度分开显示。加购额度按实际单位展示金额、点数或次数，不与订阅百分比相加，也不假定具体扣费顺序；每周窗口以服务返回的重置时间为准，不等同自然周。

## 使用

```bash
./scripts/build-app.sh
open dist/QuotaDock.app
```

也可将 `dist/QuotaDock.app` 拖入“应用程序”。启动后驻留菜单栏；点击菜单栏只打开额度弹窗，点击弹窗顶部“打开控制台”管理工具与账号。关闭控制台后应用仍驻留菜单栏，从面板右下角“退出”结束应用。

1. 点击“添加工具”，选择预设或自定义 JSON 接口。
2. 为该工具添加账号。Codex、Claude 自动刷新等支持本机登录的方式可直接点击“读取并添加”，无需填写名称或默认目录；别名、其他账号目录、备用快照放在高级设置。API、本地服务或独立快照仍按接入方式填写必要信息。
3. 点菜单栏弹窗中账号旁的图钉，可选择具体额度窗口/余额并固定显示，或保留“自动 · 剩余最少的窗口”。选择按账号保存；所选窗口暂未返回时显示 —，不会自动换成另一项。账号编辑中也能设置“菜单栏显示额度”；未固定账号时只显示应用图标。
4. 在“偏好设置”调整刷新周期（1–60 分钟）和低额度阈值。

演示模式完全独立，不覆盖真实配置、不会访问服务商，也不能修改账号。预览菜单栏面板：

```bash
open dist/QuotaDock.app --args --demo --preview
```

如果应用已经运行，应先从菜单栏退出，再传入演示参数。

## 首批工具与真实能力

| 工具 | 本版接入 | 多账号方式 |
|---|---|---|
| Codex | 官方 CLI `account/rateLimits/read`，订阅窗口、重置时间、可用时返回的额外 credits | 不同且已登录的 `CODEX_HOME` |
| Claude Code | CLI OAuth 后台查询订阅额度、额外用量预算；快照备用 | 独立 CLAUDE_CONFIG_DIR 登录或快照 |
| DeepSeek | 官方 API / Harness 配置读取 API 余额 | 每个账号独立 API Key 或 DSH_HOME |
| OpenRouter | 官方 credits 接口 / Ori 明文登录的密钥额度 | 独立 Management Key 或 CLI 登录文件 |
| Antigravity | 官方 agy 只读后台查询额度、AI Credits、昵称及套餐；快照备用 | 自动查询跟随当前 CLI 登录；独立多账号用快照 |
| Kimi Code | 官方 CLI 本地服务，套餐窗口、加购余额、昵称/邮箱/套餐 | 每账号独立登录服务及 Token |
| 智谱 GLM | 读取 GLM 的 Claude Code 配置，查询官方插件同源 Coding Plan 接口 | 每账号独立 settings.json |
| Cursor | CLI 登录文件 + 内置 DashboardService 可展示额度 | 独立 auth.json |
| GitHub Copilot | 官方 CLI account.getQuota RPC | 独立 COPILOT_HOME |
| 通义千问 | Qwen CLI 已保存本机统计，**不代表剩余额度** | 独立 QWEN_HOME |
| 硅基流动 | 手动 / 自定义接口 | 独立账号记录 |
| 自定义工具 | HTTPS GET JSON，支持字段映射和多个窗口 | 独立凭据及接口账号标识 |

**名称预设不等于已实现服务商自动接入。** 订阅限额与 API 余额分别展示，不跨账号、币种累加。硅基流动旧 `/user/info` 已停用，因此未使用。接口依据与限制见 [数据源说明](docs/PROVIDERS.md)。

各账号可在“额外购买额度”中手动补充服务未开放查询的余额，界面标注“加购 / 手动”；不会自动扣减手动值。自定义接口每个字段映射也可指定“订阅额度 / 额外购买 / 账户余额 / 自定义”归属。

### Codex

安装官方 Codex CLI 并用 ChatGPT 账号完成登录。账号的 `CODEX_HOME` 留空使用当前进程的环境配置或 `~/.codex`。多账号需先使用官方 CLI 分别登录：

```bash
CODEX_HOME="$HOME/.codex-personal" codex login
CODEX_HOME="$HOME/.codex-work" codex login
```

随后在 QuotaDock 为两个账号填写相应目录。同一目录不可重复添加；改展示名称不会生成另一个上游账号。QuotaDock 不执行登录、不复制认证文件、不发起模型对话，必要的令牌刷新由官方 CLI 处理。API Key 登录模式可能没有订阅额度。

CLI 在进程 PATH、`~/.local/bin`、`/opt/homebrew/bin`、`/usr/local/bin` 等目录查找。用其他安装路径时，请将可执行文件链接到这些路径之一。

### Claude Code

默认使用“Claude Code · 后台自动刷新”，复用 CLI 的 OAuth 登录，查询 5 小时、每周等真实窗口和额外用量月预算。账号目录留空使用默认登录，多账号填入各自 `CLAUDE_CONFIG_DIR`。昵称、邮箱和套餐按接口实际返回展示。

查询失败可自动使用账号中指定的“备用快照路径”，明确标注备用和数据时间。OAuth 登录过期由官方 CLI 更新，HTTP 429 后等待 15 分钟；后台不弹出钥匙串授权，也不调用模型。内部 OAuth 协议可能随官方版本变化，详情见 [CLI 接入说明](docs/CLI-CONNECTIONS.md)。以下是可选的备用快照配置，不是启用主动查询的前提。

随附 `scripts/claude-statusline.py` 读取 Claude Code 的 statusLine stdin，仅保存 `rate_limits`，不保存完整会话信息。需要 Python 3。

将以下配置**合并**到对应 Claude 账号配置的 `settings.json`（路径改为本机实际位置）：

```json
{
  "statusLine": {
    "type": "command",
    "command": "python3 /path/to/QuotaDock/scripts/claude-statusline.py --output ~/.local/share/quotadock/claude-personal.json"
  }
}
```

这会使用本工具的额度状态栏。已有自定义 statusLine 时先保留原配置；如需同时使用，可用 wrapper 将同一份 stdin 分别传给原脚本和本桥接脚本，并将桥接脚本 stdout 重定向到 `/dev/null`。

在 QuotaDock 自动查询账号中填写备用快照路径，或选择“Claude Code CLI · 快照备用”接入并填入快照路径 `~/.local/share/quotadock/claude-personal.json`。多账号可通过官方 `CLAUDE_CONFIG_DIR` 分离，每个账号必须使用不同输出文件。

额度字段由 Claude Code 决定，通常需要支持的订阅且会话至少收到一次 API 响应。此方式是**被动快照**，应用每次刷新读取文件，并非主动查询 Claude 服务器；界面显示快照时间，超过 24 小时会提示过期。缺失字段不会显示成“剩余 100%”。

### 各工具 CLI

新增 Cursor、Copilot、Qwen、Ori、DeepSeek Harness 的读取方式与登录限制，完整步骤见 [CLI 接入说明](docs/CLI-CONNECTIONS.md)，账号编辑器中也可直接打开随应用附带的说明和桥接脚本。Antigravity 默认使用只读 `/usage` 与 `/credits` 后台查询，失败可回退快照；Kimi 需要本地服务运行，GLM 读取明确指定的 CLI 配置。Gemini 已从预设与演示中移除，不会把它的旧数据改标成 Antigravity。

### 自定义 HTTP

只发 GET 请求。HTTPS 默认必需，本机 `localhost` / `127.0.0.1` / `::1` 可用 HTTP。不接受重定向、URL 用户名密码，凭据通过可配置请求头发送。账号标识可通过 `{accountId}` 插入地址，插入值会安全编码。

示例响应：

```json
{
  "windows": [
    { "used": 25, "total": 100, "reset": "2026-10-16T00:00:00Z" },
    { "used": 50, "total": 100, "reset": 1792108800 }
  ],
  "balance": { "amount": "12.50", "currency": "CNY" }
}
```

- 配额映射：`windows.0.used`、`windows.0.total`、`windows.0.reset`；可添加另一个窗口。
- 余额映射：选择“余额（无上限）”，剩余路径 `balance.amount`，动态单位路径 `balance.currency`。
- 配额中“剩余路径”填写后优先于“已用路径”。支持数字字符串，重置支持 ISO 8601、Unix 秒或毫秒。
- DeepSeek 默认展示 `balance_infos[0]`，若实际账号返回多个币种，可复制映射修改数组下标。

## 数据和凭据

- 配置：`~/Library/Application Support/QuotaDock/config.json`；目录 0700，文件 0600，原子保存。
- API 凭据：系统钥匙串 `com.quotadock.credentials`，按账号 UUID 隔离，不写入配置或日志。
- 账号不可直接迁移到其他工具；更改工具的接口主机、协议或端口会清除该工具账号凭据，防止旧密钥发送到新服务。
- 读取失败保留当前运行期间最后成功值并显式标记。额度快照不持久化；重启后重新查询。
- 配置损坏、外部修改时拒绝覆盖。请先检查原文件，再重启应用。
- 不自动采集浏览器 Cookie，不将账号资料上传到中转服务。额度查询访问相应官方服务或用户配置的数据源；手动检查更新访问 GitHub 的公开版本清单。Codex 使用官方 CLI 的连接能力。

## 检查更新

控制台左下角或应用菜单选择“检查更新…”。应用读取本仓库的公开 `update.json`，显示当前版本、新版本和更新说明；点击“下载更新”后由浏览器下载，退出应用后手动替换。不会自动安装或上传账号资料，也不需要 GitHub 登录。网络失败会明确提示，可重新检查。

首个安装包面向 Apple Silicon（arm64），要求 macOS 14 或更新版本；Intel Mac 可从源码构建。安装包为 ad-hoc 本地签名，尚未获得 Apple 公证。

## 开发与验证

```bash
./scripts/test.sh
./scripts/build-app.sh
codegraph index
```

`scripts` 将 Swift 缓存放在项目 `.build` 内。应用包使用本地 ad-hoc 签名，没有 Developer ID 签名或 Apple 公证，当前构建面向本机架构。测试覆盖解析、安全校验、JSON-RPC 握手、超时、快照过期等；假 CLI/合成数据测试不等同所有服务的真实账号联网验证。

代码分层：

- `Sources/QuotaDockCore`：数据模型、HTTP/Codex/Claude Provider、账号切换能力协议。
- `Sources/QuotaDock`：菜单栏、面板、管理窗口、刷新调度、钥匙串和配置存储。
- `Tests/QuotaDockCoreTests`：无真实凭据的核心回归测试。
- `docs/PROVIDERS.md`：服务商文档及数据含义。

## 后续账号切换

已定义独立的 `AccountSwitching` 协议和能力状态。本版只查询额度，**没有实际账号切换**；菜单栏图钉只切换展示内容。后续按工具分别实现激活、验证、失败回滚与会话重启策略，并与额度读取分离。
