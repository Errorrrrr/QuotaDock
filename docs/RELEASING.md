# 发布流程

仓库：https://github.com/Errorrrrr/QuotaDock

正式安装包由 `.github/workflows/macos.yml` 在 GitHub Actions 的 `macos-15` arm64 runner 上构建。本机不需要生成发布包。

1. 修改 `VERSION` 和 `UpdateController.currentVersion` 的调试回退版本，新增 `docs/releases/v<版本>.md` 发布说明。不要提前修改 `update.json`。
2. 提交并推送 main。main / PR 会自动执行 Swift 测试、CLI 桥接测试、release 构建、arm64 架构和 ad-hoc 签名验证，构建产物保留 7 天。
3. 创建并推送与 VERSION 一致的 `v<版本>` 标签，例如 `git tag v0.1.3`、`git push origin v0.1.3`。标签触发相同验证，再将 ZIP 和 SHA256SUMS 上传到草稿 Release，上传完整后公开发布。
4. 发布任务随后检出 main，确认 VERSION 仍与标签一致，生成并提交 `update.json`。这确保更新清单只指向已经发布的附件。若 main 已进入下一版本，任务会拒绝覆盖清单，需要人工核对处理。
5. 在 Actions 页面确认 build 和 release 均成功，匿名下载附件并校验 SHA256SUMS，在应用中确认检查更新结果。

可从 Actions 的 Run workflow 选择尚未发布的版本标签重新运行；已经公开的 Release 不会覆盖附件。如果附件已发布而清单更新失败，先核对公开附件及校验值，再在该版本的 main 上执行 `RELEASE_TAG=v<版本> python3 scripts/update-release-manifest.py`，提交推送 update.json。不要删除公开版本或修改标签以绕过保护。

首次添加或修改 workflow 时，GitHub 凭据需要相应 workflow 写入权限。正常运行不需要额外仓库密钥；构建任务只读，发布任务使用 GitHub 自带 GITHUB_TOKEN 的 contents:write 权限。不要将个人账号令牌或额度账号配置加入 Actions。

应用手动读取 `raw.githubusercontent.com/Errorrrrr/QuotaDock/main/update.json`，不依赖 GitHub API 配额、不携带账号身份或额度资料。更新按钮打开浏览器下载，用户自行退出后替换安装。当前为 ad-hoc 签名，尚未使用 Developer ID 签名及 Apple 公证。

本地开发可运行 `bash scripts/test.sh`、`python3 scripts/test-antigravity-bridge.py` 和 `bash scripts/build-app.sh`。清理 `.build/`、`dist/` 前，先把要保留的应用安装到 Applications 并退出构建目录中的实例；不要删除账号配置或 CodeGraph 索引。
