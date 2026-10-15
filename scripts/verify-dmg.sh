#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version="${2:-$(cat VERSION)}"
dmg="${1:-$PWD/dist/QuotaDock-$version-macOS-arm64.dmg}"
mount_dir=$(mktemp -d "${TMPDIR:-/tmp}/quotadock-mount.XXXXXX")
mounted=false
cleanup() {
  if $mounted; then
    hdiutil detach "$mount_dir" || return 1
  fi
  rmdir "$mount_dir"
}
trap cleanup EXIT
hdiutil verify "$dmg"
hdiutil attach "$dmg" -readonly -nobrowse -mountpoint "$mount_dir"
mounted=true
test -L "$mount_dir/Applications"
test "$(readlink "$mount_dir/Applications")" = /Applications
app="$mount_dir/QuotaDock.app"
test -d "$app"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" = "$version"
test "$(lipo -archs "$app/Contents/MacOS/QuotaDock")" = arm64
codesign --verify --strict "$app"
hdiutil detach "$mount_dir"
mounted=false
echo "Verified DMG app, Applications link, version, arm64 architecture and signature; detached."
