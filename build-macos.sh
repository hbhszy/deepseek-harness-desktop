#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")" && pwd)"
source_file="$project_root/src/macos/Main.swift"
info_plist="$project_root/src/macos/Info.plist"
assets_dir="$project_root/assets"
build_dir="$project_root/build/macos"
dist_dir="$project_root/dist"
app_bundle="$dist_dir/DeepSeek Harness.app"
zip_file="$dist_dir/DeepSeek Harness-macos-arm64.zip"
contents_dir="$app_bundle/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
iconset_dir="$build_dir/WhaleIcon.iconset"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS 构建必须在 Mac 上运行。" >&2
  exit 1
fi

for required in "$source_file" "$info_plist" "$assets_dir/whale-blue.svg"; do
  if [[ ! -f "$required" ]]; then
    echo "缺少构建文件：$required" >&2
    exit 1
  fi
done

if [[ "$app_bundle" != "$project_root/dist/DeepSeek Harness.app" ]]; then
  echo "拒绝清理非预期的应用目录：$app_bundle" >&2
  exit 1
fi

mkdir -p "$build_dir" "$dist_dir"
if [[ -d "$app_bundle" ]]; then
  rm -rf "$app_bundle"
fi
rm -f "$zip_file"
rm -rf "$iconset_dir"
mkdir -p "$macos_dir" "$resources_dir" "$iconset_dir"

echo "正在编译 macOS arm64 应用…"
xcrun swiftc \
  -O \
  -whole-module-optimization \
  -swift-version 5 \
  -target arm64-apple-macos13.0 \
  -framework AppKit \
  -framework WebKit \
  "$source_file" \
  -o "$macos_dir/DeepSeek Harness"

cp "$info_plist" "$contents_dir/Info.plist"

echo "正在生成应用图标…"
blue_svg="$build_dir/whale-blue-1024.svg"
white_svg="$build_dir/whale-white-1024.svg"
sed 's/width="512" height="512"/width="1024" height="1024"/' "$assets_dir/whale-blue.svg" > "$blue_svg"
sed -e 's/width="512" height="512"/width="1024" height="1024"/' -e 's/#4D6BFE/#FFFFFF/g' "$assets_dir/whale-blue.svg" > "$white_svg"
sips -s format png "$blue_svg" --out "$build_dir/whale-blue-1024.png" >/dev/null
sips -s format png "$white_svg" --out "$resources_dir/whale-white.png" >/dev/null
cp "$build_dir/whale-blue-1024.png" "$resources_dir/whale-blue.png"

while read -r file size; do
  sips -z "$size" "$size" "$build_dir/whale-blue-1024.png" --out "$iconset_dir/$file" >/dev/null
done <<'SIZES'
icon_16x16.png 16
icon_16x16@2x.png 32
icon_32x32.png 32
icon_32x32@2x.png 64
icon_128x128.png 128
icon_128x128@2x.png 256
icon_256x256.png 256
icon_256x256@2x.png 512
icon_512x512.png 512
icon_512x512@2x.png 1024
SIZES

iconutil -c icns "$iconset_dir" -o "$resources_dir/WhaleIcon.icns"

echo "正在签名并打包…"
plutil -lint "$contents_dir/Info.plist" >/dev/null
codesign --force --deep --sign - "$app_bundle"
codesign --verify --deep --strict "$app_bundle"
ditto -c -k --sequesterRsrc --keepParent "$app_bundle" "$zip_file"

echo
echo "构建完成："
echo "$app_bundle"
echo "$zip_file"
file "$macos_dir/DeepSeek Harness"
codesign -dv --verbose=2 "$app_bundle" 2>&1 | grep -E '^(Identifier|Format|Signature)='

if [[ "${1:-}" == "--run" ]]; then
  open "$app_bundle"
elif [[ $# -gt 0 ]]; then
  echo "未知参数：$1（支持：--run）" >&2
  exit 1
fi
