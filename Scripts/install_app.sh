#!/usr/bin/env bash
#
# install_app.sh — 一键升级：构建 release → 打包 .app → 安装到 /Applications → 重启
#
# 用法：
#   Scripts/install_app.sh              # 完整构建 + 安装 + 重启
#   VERSION=1.1.0 Scripts/install_app.sh
#   NO_LAUNCH=1 Scripts/install_app.sh  # 安装后不启动
#
set -euo pipefail

APP_NAME="SkillHub"
INSTALL_DIR="/Applications"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# ---- 1. 构建 + 打包（复用 make_app.sh）----------------------------------------
"$ROOT_DIR/Scripts/make_app.sh"

APP_DIR="$ROOT_DIR/.build/app/$APP_NAME.app"
TARGET="$INSTALL_DIR/$APP_NAME.app"

# ---- 2. 关闭正在运行的旧版 -----------------------------------------------------
if pgrep -x "$APP_NAME" > /dev/null; then
    echo "==> 关闭正在运行的 $APP_NAME ..."
    pkill -x "$APP_NAME" || true
    sleep 1
fi

# ---- 3. 安装到 /Applications ---------------------------------------------------
echo "==> 安装到 $TARGET ..."
rm -rf "$TARGET"
cp -R "$APP_DIR" "$TARGET"

# 本地构建无需 quarantine；保险起见清除可能存在的隔离属性
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

# ---- 4. 重新启动 ----------------------------------------------------------------
if [[ "${NO_LAUNCH:-0}" != "1" ]]; then
    echo "==> 启动 $APP_NAME ..."
    open "$TARGET"
fi

echo ""
echo "✅ 完成：$TARGET 已安装$([[ "${NO_LAUNCH:-0}" != "1" ]] && echo "并启动")"
