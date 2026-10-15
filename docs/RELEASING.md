# 发布流程

仓库：https://github.com/Errorrrrr/QuotaDock

1. 修改 `VERSION`，同步 `update.json` 的版本、更新说明、最低系统版本、架构及对应 Release/ZIP 地址。稳定版本使用三段数字，不发布预览版到该清单。
2. 运行 `bash scripts/test.sh` 和 `python3 scripts/test-antigravity-bridge.py`，再运行 `bash scripts/build-app.sh`。安装包当前按本机架构构建，发布前用 `file dist/QuotaDock.app/Contents/MacOS/QuotaDock` 核对，不能把单架构包标成 universal。
3. 使用 `ditto -c -k --sequesterRsrc --keepParent dist/QuotaDock.app dist/QuotaDock-<版本>-macOS-<架构>.zip` 打包，计算 SHA256SUMS。
4. 提交源码，创建匹配的 `v<版本>` Git tag 和 GitHub Release，上传 ZIP 与 SHA256SUMS，再确认公开下载可用。将版本清单与对应 Release 同步发布；更新清单不能指向未完成的安装包。
5. 无认证访问版本清单及下载链接，并在应用中检查更新。核对当前版本不会提示旧版本，新版本不会跨仓库或跳转未知下载地址。

应用手动读取 `raw.githubusercontent.com/Errorrrrr/QuotaDock/main/update.json`，不依赖 GitHub API 配额、不携带账号身份或额度资料。更新按钮打开浏览器下载，用户自行退出后替换安装。当前为 ad-hoc 签名，尚未使用 Developer ID 签名及 Apple 公证。
