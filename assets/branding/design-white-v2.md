# QuotaDock 白底 Logo

按用户要求，将深蓝背景改为白底，保留青绿色 Q 形额度环和三根用量柱。使用内置 imagegen 编辑，源图为 `quotadock-logo-v1.png`，交付为 `quotadock-logo-white-v2.png`。已按用户确认设为应用图标，打包为 QuotaDock.icns；原图保持不变。菜单栏使用同造型的单色模板图，由 AppKit 自动适配系统外观。

## 最终提示词

Edit this QuotaDock app logo. Change ONLY the background treatment: replace the deep navy blue rounded-square tile with a clean pure white tile, and use a white canvas outside it too. Preserve the exact existing Q-shaped quota ring and three ascending rounded usage bars, their shape, placement, proportions and jade/teal colors. Adjust the very subtle shading only as necessary for the mark to remain crisp and legible on white. Calm polished macOS icon, clean white background, no dark blue anywhere, no added elements, no text, no watermark. Keep the same square framing and centered composition.


## 应用资源

- 应用原图：`../../Sources/QuotaDock/Resources/Branding/AppIcon.png`
- 菜单栏模板：`../../Sources/QuotaDock/Resources/Branding/StatusTemplate.png`
- 打包：`../../scripts/build-app.sh` 生成完整普通与 Retina 图标尺寸，并设置 CFBundleIconFile。

## 菜单栏模板提示词（内置 imagegen）

Derive a macOS menu-bar template glyph from this approved QuotaDock logo. Preserve the distinctive exact silhouette of its Q ring with lower-right tail and three ascending rounded bars. Output ONLY this Q and the three bars as solid pure black shapes on true alpha-transparent background. Remove the white tile, all backgrounds, all gradients, shadows, bevels, glow and texture. Flat black silhouette only, clean smooth vector-like edges. Keep the Q and bars separate as in the reference; no redesign, no added text or decoration. Center the glyph on square canvas with tight approximately 5 percent transparent padding, designed to remain readable at 18 pixels.
