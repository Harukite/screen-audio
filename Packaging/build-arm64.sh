#!/bin/zsh
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
artifact_dir="$project_root/.build/artifacts"
app_bundle="$artifact_dir/ScreenAudio.app"
binary="$project_root/.build/arm64-apple-macosx/release/ScreenAudio"
archive="$artifact_dir/ScreenAudio-macos-arm64-audio-permission.zip"

cd "$project_root"
swift build -c release --product ScreenAudio

mkdir -p "$app_bundle/Contents/MacOS"
mkdir -p "$app_bundle/Contents/Resources"
cp "$binary" "$app_bundle/Contents/MacOS/ScreenAudio"
cp "$project_root/Packaging/Info.plist" "$app_bundle/Contents/Info.plist"
cp "$project_root/Packaging/AppIcon.icns" "$app_bundle/Contents/Resources/AppIcon.icns"
chmod +x "$app_bundle/Contents/MacOS/ScreenAudio"

plutil -lint "$app_bundle/Contents/Info.plist"
# 图标校验：plist 声明的名字必须真的存在于 Resources，否则 Finder 会静默回退到通用图标
icon_name="$(plutil -extract CFBundleIconFile raw "$app_bundle/Contents/Info.plist")"
test -f "$app_bundle/Contents/Resources/${icon_name}.icns"
codesign --force --deep --sign - "$app_bundle"
codesign --verify --deep --strict "$app_bundle"
lipo -archs "$app_bundle/Contents/MacOS/ScreenAudio"
ditto -c -k --sequesterRsrc --keepParent "$app_bundle" "$archive"

printf 'Created %s\n' "$archive"
