#!/usr/bin/env bash
# Build, sign, notarize and package a public SkillHub release.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

: "${SIGN_IDENTITY:?请设置 SIGN_IDENTITY（Developer ID Application 证书名称）}"
: "${NOTARY_PROFILE:?请设置 NOTARY_PROFILE（xcrun notarytool store-credentials 创建的 profile）}"

VERSION="${VERSION:-$(tr -d '[:space:]' < VERSION)}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
APP_PATH="$ROOT_DIR/.build/app/SkillHub.app"
DIST_DIR="$ROOT_DIR/.build/dist"
ARCHIVE_PATH="$DIST_DIR/SkillHub-$VERSION-macos-universal.zip"
DMG_PATH="$DIST_DIR/SkillHub-$VERSION-macos-universal.dmg"

UNIVERSAL=1 VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" \
    SIGN_IDENTITY="$SIGN_IDENTITY" "$ROOT_DIR/Scripts/make_app.sh"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

mkdir -p "$DIST_DIR"
rm -f "$ARCHIVE_PATH" "$ARCHIVE_PATH.sha256"
ditto -c -k --keepParent "$APP_PATH" "$ARCHIVE_PATH"
xcrun notarytool submit "$ARCHIVE_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

# Recreate the archive so the stapled ticket is included in the downloadable artifact.
rm -f "$ARCHIVE_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ARCHIVE_PATH"
shasum -a 256 "$ARCHIVE_PATH" > "$ARCHIVE_PATH.sha256"
SKIP_CHECKSUM=1 DMG_PATH="$DMG_PATH" "$ROOT_DIR/Scripts/make_dmg.sh"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
shasum -a 256 "$DMG_PATH" > "$DMG_PATH.sha256"
spctl --assess --type execute --verbose=2 "$APP_PATH"

echo "✅ 发布产物：$ARCHIVE_PATH"
echo "✅ 校验文件：$ARCHIVE_PATH.sha256"
echo "✅ DMG：$DMG_PATH"
echo "✅ DMG 校验文件：$DMG_PATH.sha256"
