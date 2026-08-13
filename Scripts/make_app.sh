#!/usr/bin/env bash
#
# make_app.sh — 把 SwiftPM release 产物打包成标准 macOS SkillHub.app
#
# 用法：
#   Scripts/make_app.sh                 # 先 swift build -c release，再打包
#   SKIP_BUILD=1 Scripts/make_app.sh    # 跳过构建，直接用已有 release 产物打包
#   UNIVERSAL=1 Scripts/make_app.sh     # 构建 arm64 + x86_64 通用版本
#   SIGN_IDENTITY="Developer ID Application: ..." Scripts/make_app.sh
#
# 输出：.build/app/SkillHub.app（.build/ 已被 .gitignore 忽略）
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# ---- 配置 --------------------------------------------------------------------
APP_NAME="SkillHub"
BUNDLE_ID="${BUNDLE_ID:-io.github.0flowerocean0.SkillHub}"
VERSION="${VERSION:-$(tr -d '[:space:]' < VERSION)}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
MIN_SYSTEM_VERSION="14.0"

OUTPUT_DIR="$ROOT_DIR/.build/app"
APP_DIR="$OUTPUT_DIR/$APP_NAME.app"

# ---- 1. 构建 release 产物 -----------------------------------------------------
SWIFT_BUILD_ARGS=(-c release)
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    SWIFT_BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi
if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    echo "==> swift build ${SWIFT_BUILD_ARGS[*]} ..."
    swift build "${SWIFT_BUILD_ARGS[@]}"
fi

BIN_PATH="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
EXECUTABLE="$BIN_PATH/$APP_NAME"
RESOURCE_BUNDLE="$BIN_PATH/${APP_NAME}_${APP_NAME}.bundle"

if [[ ! -x "$EXECUTABLE" ]]; then
    echo "错误：找不到可执行文件 $EXECUTABLE" >&2
    echo "请先运行 swift build -c release" >&2
    exit 1
fi

# ---- 2. 组装 .app 目录结构（幂等：先清空再重建） --------------------------------
echo "==> 组装 $APP_DIR ..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$EXECUTABLE" "$APP_DIR/Contents/MacOS/$APP_NAME"

# SwiftPM 资源 bundle（包含 Assets.xcassets 编译产物等）
if [[ -d "$RESOURCE_BUNDLE" ]]; then
    cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/"
else
    echo "警告：未找到资源 bundle $RESOURCE_BUNDLE，跳过" >&2
fi

# ---- 3. （可选）生成 AppIcon.icns ---------------------------------------------
# 参考：Sources/SkillHub/Assets.xcassets/AppIcon.appiconset/ 下的
# icon_16x16.png ... icon_512x512@2x.png 已符合 iconutil 的命名约定，
# 直接拷进临时 .iconset 目录即可转换。没有 iconutil 或转换失败时跳过，
# 不影响 .app 生成（App 运行时会用 Bundle.module 里的 PNG 设置 Dock 图标）。
ICONSET_SRC="$ROOT_DIR/Sources/SkillHub/Assets.xcassets/AppIcon.appiconset"
ICON_FILE=""
if command -v iconutil >/dev/null 2>&1 && [[ -d "$ICONSET_SRC" ]]; then
    TMP_ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$TMP_ICONSET"
    for size in 16 32 128 256 512; do
        for suffix in "" "@2x"; do
            src="$ICONSET_SRC/icon_${size}x${size}${suffix}.png"
            [[ -f "$src" ]] && cp "$src" "$TMP_ICONSET/"
        done
    done
    if iconutil -c icns "$TMP_ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns" 2>/dev/null; then
        ICON_FILE="AppIcon"
        echo "==> 已生成 AppIcon.icns"
    else
        echo "警告：iconutil 转换失败，跳过 icns（不影响打包）" >&2
    fi
    rm -rf "$(dirname "$TMP_ICONSET")"
fi

# ---- 4. 写入 Info.plist -------------------------------------------------------
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MIN_SYSTEM_VERSION</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

if [[ -n "$ICON_FILE" ]]; then
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string $ICON_FILE" \
        "$APP_DIR/Contents/Info.plist"
fi

# ---- 5. 签名 -------------------------------------------------------------------
# SwiftPM 产物复制进 .app 并加入资源后，原可执行文件签名不再覆盖整个 bundle。
# 未提供 SIGN_IDENTITY 时使用 ad-hoc 签名，仅用于本机测试，不能代替 Developer ID 分发签名。
if command -v codesign >/dev/null 2>&1; then
    if [[ -n "${SIGN_IDENTITY:-}" ]]; then
        codesign --force --options runtime --timestamp \
            --sign "$SIGN_IDENTITY" "$APP_DIR"
        echo "==> 已使用 Developer ID 签名"
    else
        codesign --force --deep --sign - "$APP_DIR"
        echo "==> 已完成本地 ad-hoc 签名（仅供本机测试）"
    fi
else
    echo "警告：未找到 codesign，生成的 .app 未签名" >&2
fi

# ---- 6. 完成 ------------------------------------------------------------------
echo ""
echo "✅ 打包完成：$APP_DIR"
echo "   版本：$VERSION ($BUILD_NUMBER)，最低系统：macOS $MIN_SYSTEM_VERSION"
echo "   试运行：open \"$APP_DIR\""
