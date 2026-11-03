#!/bin/bash
set -e

APP_NAME="Tomato"
DIST_DIR="dist"
BUNDLE_DIR="${DIST_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${BUNDLE_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
ICON_SRC="Resources/AppIcon.png"

echo "🔨 正在编译 Release 版本..."
swift build -c release

echo "📦 正在打包 ${BUNDLE_DIR}..."
rm -rf "${BUNDLE_DIR}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

cp ".build/release/TomatoApp" "${MACOS_DIR}/TomatoApp"
cp "Info.plist" "${CONTENTS_DIR}/Info.plist"

# SwiftPM 会把 SDK 版本写成部署目标。改回当前 SDK，macOS 27 才会使用新版界面。
SDK_VERSION="$(xcrun --show-sdk-version)"
vtool -set-build-version macos 15.0 "${SDK_VERSION}" -replace -output "${MACOS_DIR}/TomatoApp" "${MACOS_DIR}/TomatoApp" >/dev/null

echo "🎨 正在生成 App 图标..."
MASTER_PNG="$(mktemp -t tomato-icon).png"
ICONSET_DIR="$(mktemp -d -t tomato-iconset)"
# 浅色模式：白底 icns，作为通用回退
magick "${ICON_SRC}" -background white -alpha remove -alpha off -resize 1024x1024 "${MASTER_PNG}"
for SIZE in 16 32 128 256 512; do
    sips -z "${SIZE}" "${SIZE}" "${MASTER_PNG}" --out "${ICONSET_DIR}/icon_${SIZE}x${SIZE}.png" >/dev/null
    RETINA=$((SIZE * 2))
    sips -z "${RETINA}" "${RETINA}" "${MASTER_PNG}" --out "${ICONSET_DIR}/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
mv "${ICONSET_DIR}" "${ICONSET_DIR}.iconset"
iconutil -c icns "${ICONSET_DIR}.iconset" -o "${RESOURCES_DIR}/AppIcon.icns"
rm -rf "${MASTER_PNG}" "${ICONSET_DIR}.iconset"

# Icon Composer：浅色白底 / 深色黑底，随系统外观切换
ICON_DOC="$(mktemp -d -t tomato-icondoc)/AppIcon.icon"
mkdir -p "${ICON_DOC}/Assets"
cp "Resources/AppIcon.icon/icon.json" "${ICON_DOC}/icon.json"
cp "${ICON_SRC}" "${ICON_DOC}/Assets/Tomato.png"
xcrun actool "${ICON_DOC}" \
    --compile "${RESOURCES_DIR}" \
    --app-icon AppIcon \
    --enable-on-demand-resources NO \
    --development-region en \
    --target-device mac \
    --platform macosx \
    --minimum-deployment-target 15.0 \
    --include-all-app-icons \
    --enable-icon-stack-fallback-generation=disabled \
    --output-partial-info-plist /dev/null \
    >/dev/null
rm -rf "$(dirname "${ICON_DOC}")"

# Ad-hoc 签名以支持 macOS 本地通知权限
codesign --force --deep --sign - "${BUNDLE_DIR}"

echo "✅ 打包完成！路径: $(pwd)/${BUNDLE_DIR}"
