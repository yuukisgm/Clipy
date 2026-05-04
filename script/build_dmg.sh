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
