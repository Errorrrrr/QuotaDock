#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
swift build -c release --cache-path .build/cache --config-path .build/config --security-path .build/security --disable-sandbox
APP_VERSION=$(cat VERSION)
[[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "VERSION 格式无效" >&2; exit 1; }
APP="$PWD/dist/QuotaDock.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/QuotaDock "$APP/Contents/MacOS/QuotaDock"
mkdir -p "$APP/Contents/Helpers"
cp .build/release/QuotaDockUpdater "$APP/Contents/Helpers/QuotaDockUpdater"
codesign --force --sign - "$APP/Contents/Helpers/QuotaDockUpdater"
rm -rf "$APP/Contents/Resources/QuotaDock_QuotaDock.bundle"
cp -R .build/release/QuotaDock_QuotaDock.bundle "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/Integration"
cp scripts/claude-statusline.py scripts/antigravity-statusline.py docs/CLI-CONNECTIONS.md "$APP/Contents/Resources/Integration/"
ICONSET="$PWD/.build/QuotaDock.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Sources/QuotaDock/Resources/Branding/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z "$retina" "$retina" Sources/QuotaDock/Resources/Branding/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/QuotaDock.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>QuotaDock</string>
<key>CFBundleDisplayName</key><string>QuotaDock</string>
<key>CFBundleIdentifier</key><string>com.quotadock.app</string>
<key>CFBundleExecutable</key><string>QuotaDock</string>
<key>CFBundleIconFile</key><string>QuotaDock.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
printf '已构建：%s\n' "$APP"
