#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(cat VERSION)
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid VERSION" >&2; exit 1; }
app="$PWD/dist/QuotaDock.app"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" = "$version"
test "$(lipo -archs "$app/Contents/MacOS/QuotaDock")" = arm64
codesign --verify --strict "$app"
staging=$(mktemp -d "${TMPDIR:-/tmp}/quotadock-dmg.XXXXXX")
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/QuotaDock.app"
ln -s /Applications "$staging/Applications"
name="QuotaDock-$version-macOS-arm64"
ditto -c -k --sequesterRsrc --keepParent "$app" "dist/$name.zip"
hdiutil create -volname "QuotaDock $version" -srcfolder "$staging" -format UDZO -ov "dist/$name.dmg"
bash scripts/verify-dmg.sh "$PWD/dist/$name.dmg" "$version"
(cd dist && shasum -a 256 "$name.zip" "$name.dmg" > SHA256SUMS && shasum -a 256 -c SHA256SUMS)
