#!/usr/bin/env bash
set -euo pipefail

# Clipy distribution build & DMG packager.
# Builds arm64 and x86_64 binaries separately and produces two DMGs.
# Usage: ./script/build_dmg.sh [arm64|x86_64|both]

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
VERSION="$(grep -m1 'MARKETING_VERSION' Clipy.xcodeproj/project.pbxproj | sed 's/.*= *//;s/;//')"
[ -z "$VERSION" ] && VERSION="1.5.1"

DIST="$ROOT/dist"
mkdir -p "$DIST"

WHICH="${1:-both}"

# 安定した署名 ID で署名する。アドホック署名だとビルド毎に指定要件(DR)が
# 変わり、上書き更新時に「ログイン項目」の重複や「アクセシビリティ」権限の
# 孤立が起きる。固定 ID で署名すれば DR が安定し、更新が同一アプリ扱いになる。
# 環境変数 SIGN_IDENTITY で上書き可。空文字にするとアドホックにフォールバック。
SIGN_IDENTITY="${SIGN_IDENTITY:-Clipy Signing}"

build_arch() {
    local ARCH="$1"
    local LABEL="$2"
    local OUTDIR="$DIST/build_${ARCH}"
    local APP="$OUTDIR/Build/Products/Release/Clipy.app"
    local DMG="$DIST/Clipy_${VERSION}_${LABEL}.dmg"

    echo "==> Building Clipy for ${ARCH} (${LABEL})"
    rm -rf "$OUTDIR"
    xcodebuild \
        -workspace Clipy.xcworkspace \
        -scheme Clipy \
        -configuration Release \
        -derivedDataPath "$OUTDIR" \
        ARCHS="$ARCH" \
        ONLY_ACTIVE_ARCH=NO \
        VALID_ARCHS="$ARCH" \
        EXCLUDED_ARCHS="" \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        build | tail -5

    if [ ! -d "$APP" ]; then
        echo "ERROR: build failed for $ARCH" >&2
        exit 1
    fi

    echo "==> App size:"
    du -sh "$APP"
    echo "==> Architectures in main binary:"
    file "$APP/Contents/MacOS/Clipy"

    echo "==> Packaging DMG: $DMG"
    rm -f "$DMG"
    local STAGE="$OUTDIR/dmg_stage"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/Clipy.app"
    xattr -cr "$STAGE/Clipy.app"

    if [ -n "$SIGN_IDENTITY" ]; then
        echo "==> Signing with: $SIGN_IDENTITY"
        codesign --force --deep --sign "$SIGN_IDENTITY" "$STAGE/Clipy.app"
    else
        echo "==> Ad-hoc signing (SIGN_IDENTITY empty)"
        codesign --force --deep --sign - "$STAGE/Clipy.app"
    fi
    codesign -dvvv "$STAGE/Clipy.app" 2>&1 | grep -E "Authority=|TeamIdentifier=" | head -2 || true

    ln -s /Applications "$STAGE/Applications"

    hdiutil create -volname "Clipy ${VERSION} (${LABEL})" \
        -srcfolder "$STAGE" \
        -ov -format UDZO \
        -fs HFS+ \
        "$DMG" >/dev/null

    echo "==> Done: $DMG ($(du -h "$DMG" | awk '{print $1}'))"
}

case "$WHICH" in
    arm64)   build_arch arm64  AppleSilicon ;;
    x86_64)  build_arch x86_64 Intel ;;
    both)    build_arch arm64  AppleSilicon
             build_arch x86_64 Intel ;;
    *)       echo "Usage: $0 [arm64|x86_64|both]"; exit 1 ;;
esac

echo
echo "==> Artifacts in $DIST:"
ls -lh "$DIST"/*.dmg
