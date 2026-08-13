#!/usr/bin/env bash
# Package an existing SkillHub.app as a distributable DMG.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${VERSION:-$(tr -d '[:space:]' < VERSION)}"
APP_PATH="${APP_PATH:-$ROOT_DIR/.build/app/SkillHub.app}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/.build/dist}"
DMG_PATH="${DMG_PATH:-$DIST_DIR/SkillHub-$VERSION-macos-universal.dmg}"

[[ -d "$APP_PATH" ]] || {
    echo "错误：找不到 $APP_PATH，请先运行 UNIVERSAL=1 Scripts/make_app.sh" >&2
    exit 1
}

STAGING_DIR="$(mktemp -d)"
cleanup() { rm -rf "$STAGING_DIR"; }
trap cleanup EXIT

cp -R "$APP_PATH" "$STAGING_DIR/SkillHub.app"
ln -s /Applications "$STAGING_DIR/Applications"

mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH" "$DMG_PATH.sha256"
hdiutil create \
    -volname "SkillHub $VERSION" \
    -srcfolder "$STAGING_DIR" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$DMG_PATH"

hdiutil verify "$DMG_PATH"
if [[ "${SKIP_CHECKSUM:-0}" != "1" ]]; then
    (
        cd "$(dirname "$DMG_PATH")"
        shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$DMG_PATH").sha256"
    )
fi

echo "✅ DMG：$DMG_PATH"
echo "✅ SHA-256：$DMG_PATH.sha256"
