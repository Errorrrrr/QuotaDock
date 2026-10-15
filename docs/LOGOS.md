# QuotaDock 国际工具 Logo 来源

核验日期：2026-10-15。仅用于工具/账号识别；商标权属于各品牌。保持原始颜色、比例，不以模板图染色。

| 资源 | 格式和尺寸 | 来源与验证 | 处理 |
|---|---|---|---|
| `codex.png` | PNG，1024 × 1024，Alpha，官方 Codex 蓝紫色终端图标 | 本机官方 ChatGPT/Codex 应用包 `/Applications/ChatGPT.app/Contents/Resources/icon-codex-light.png`；公开说明 https://help.openai.com/en/articles/20001276-moving-to-the-new-chatgpt-desktop-app | 原样复制 Codex 专用产品图标，未使用 OpenAI 公司 Blossom 代替。 |
| `claude.png` | PNG，192 × 192，Alpha，橙色 Claude 星芒/深色圆底 | Claude Code 官方文档 https://code.claude.com/docs/en/overview 中 light favicon link；文件 https://code.claude.com/docs/_mintlify/favicons/claude-code/pLsy-mRpNksna2sx/_generated/favicon/android-chrome-192x192.png | 原始下载。主站 manifest 的 icon-512x512.png 实际是 Anthropic 字母标，不使用。 |
| `deepseek.png` | PNG，225 × 225，Alpha，蓝色鲸鱼 | 官网 https://www.deepseek.com/ 的 favicon link；文件 https://www.deepseek.com/favicon.ico | 用 macOS sips 将 ICO 原尺寸无损转 PNG；没有重绘/改色。 |
| `openrouter.svg` | SVG，1024 × 730，透明背景，紫色 OR glyph | 官方品牌页 https://openrouter.ai/brand ；文件 https://openrouter.ai/brand/logos/transparent/glyph/svg/glyph-grape.svg | 原样保存。该官方品牌页提供最新 glyph，保留紫色，不使用旧箭头。 |
| `cursor.svg` | SVG，viewBox 0 0 466.73 532.09，透明背景，深色 #26251e 立方体 | 官方品牌页 https://cursor.com/brand 的 Download brand assets；品牌包 https://ptht05hbb1ssoooe.public.blob.vercel-storage.com/assets/brand/cursor-brand-assets.zip | 从官方包原样抽取 General Logos/Cube/SVG/CUBE_2D_LIGHT.svg。LIGHT 表示用于浅背景，图形深色；DARK 版是浅色图形，未采用。 |

资源路径：`Sources/QuotaDock/Resources/ToolLogos/`。以上都是品牌官方站点/已认证官方组织的真实资产，没有生成或自行绘制。

验证：实际检查文件格式、PNG 尺寸/Alpha、SVG viewBox 和颜色；目视检查 OpenAI/Claude/DeepSeek/OpenRouter 图片。Swift 和 Package 未修改，也没有运行共享构建。

---

# QuotaDock 官方工具 Logo 来源

核对日期：2026-10-15。六个文件均为官方站点或官方 GitHub 仓库的原始公开图标资源，下载后未重绘、裁切、着色或修改内容。仅用于识别对应工具，不表示品牌方背书。

| 文件 | 格式 / 尺寸 | 官方来源页面 | 原始资源地址 | 备注 |
| --- | --- | --- | --- | --- |
| `siliconflow.png` | PNG，180 × 180，有 Alpha | https://www.siliconflow.com/ | https://framerusercontent.com/images/bFE5gkPwrI76ftGXfAEDMfKyC9Q.png | 官网 HTML 的 apple-touch-icon；紫色图形标识，选用高于 64px favicon 的版本。 |
| `kimi.png` | PNG，192 × 192，有 Alpha | https://www.kimi.com/ | https://www.kimi.com/pwa-192.png | 官网 HTML 的 apple-touch-icon；K 图形与蓝点，带官方黑色底纹。品牌页另有 https://www.kimi.com/resources/kimi-brand 。 |
| `glm.svg` | SVG，viewBox 0 0 30 30 | https://z.ai/ （重定向 https://chat.z.ai/） | https://z-cdn.chatglm.cn/z-ai/static/logo.svg | 官网 HTML 的 favicon 与 apple-touch-icon；Z.ai 图形标识。 |
| `qwen.png` | PNG，80 × 80，有 Alpha | https://qwen.ai/ | https://img.alicdn.com/imgextra/i4/O1CN01OXv3EM1FN8t9W4P79_!!6000000000474-2-tps-80-80.png | 官网 HTML 的 favicon；透明底蓝色图形标识。 |
| `gemini.png` | PNG，512 × 512，有 Alpha | https://gemini.google.com/ | https://www.gstatic.com/lamda/images/gemini_sparkle_4g_512_lt_f94943af3be039176192d.png | 官网 HTML 的 favicon 与 apple-touch-icon；Google 官方彩色 Gemini 图形。 |
| `copilot.svg` | SVG，24 × 24 | https://github.com/primer/octicons/blob/main/icons/copilot-24.svg | https://raw.githubusercontent.com/primer/octicons/main/icons/copilot-24.svg | GitHub 官方 Primer Octicons 的 Copilot 图形；透明底黑色，无字标。Octicons 仓库采用 MIT 许可证：https://github.com/primer/octicons/blob/main/LICENSE 。 |

目录：`Sources/QuotaDock/Resources/ToolLogos/`。

验证：PNG 的格式、尺寸与 Alpha 已由 `sips` 检查；两个 SVG 的根元素与 viewBox 已检查，且均已通过 AppKit `NSImage(contentsOf:)` 解码。图片均为独立图形图标，不使用大幅文字 wordmark。Copilot 为黑色路径，显示时宜保持白色背景；不要统一给彩色 Logo 染色。

## 文件 SHA-256

```text
siliconflow.png de24dbe378ddc893071841e6a2c0c213108ccec0e98bb4a8042428accc847224
kimi.png       6c14f9c3062e953b3ed57ae3e19db931c1c1bba38d4d8d55550544f31d55e469
glm.svg        07a45e8e35b0b631ed2c68cd1cb041f9721b1ceeb0bd0e34f1459b0304a741c7
qwen.png       cd9390bc4209c319121d111f3a1f535b3c7dd909b8f860d41acc9744138d58df
gemini.png     5e7cfecaa53f4f65a313fe89b0f389548126544a78fad8489510c70ae641a4a1
copilot.svg    eeafb3c2f333e04ccf7d031ae215f7adafaed4c6352556b0bf79496e048bcdd7
```

## Antigravity 替换

2026-10-15：新增 antigravity.png，从本机官方 Antigravity IDE.app 的 Contents/Resources/Antigravity IDE.icns 转换；仅用于标识对应工具。Gemini 不再出现在工具预设及演示。
