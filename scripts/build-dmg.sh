#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && /bin/pwd -P)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && /bin/pwd -P)"
APP_NAME="Type4Me"
APP_VERSION="${APP_VERSION:-1.9.0}"
VARIANT="${VARIANT:-cloud}"    # cloud or local
ARCH="${ARCH:-}"               # arm64 or universal (default: universal for cloud, arm64 for local)
DIST_DIR="${DIST_DIR:-$PROJECT_DIR/dist}"
VOLUME_NAME="${VOLUME_NAME:-$APP_NAME}"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/type4me-dmg.XXXXXX")"

# Default ARCH based on variant
if [ -z "$ARCH" ]; then
    if [ "$VARIANT" = "local" ]; then
        ARCH="arm64"   # Local ASR (MLX) requires Apple Silicon
    else
        ARCH="universal"
    fi
fi

# Build DMG filename
ARCH_SUFFIX=""
if [ "$ARCH" = "arm64" ]; then
    ARCH_SUFFIX="-apple-silicon"
fi
DMG_NAME="${DMG_NAME:-${APP_NAME}-v${APP_VERSION}-${VARIANT}${ARCH_SUFFIX}.dmg}"
DMG_PATH="$DIST_DIR/$DMG_NAME"

echo "=== Building ${VARIANT} DMG (${ARCH}) ==="

cleanup() {
    rm -rf "$STAGING_DIR"
    # Restore sherpa-onnx framework if it was hidden for cloud build
    if [ -f "$PROJECT_DIR/Frameworks/sherpa-onnx.xcframework/Info.plist.cloud-hidden" ]; then
        mv "$PROJECT_DIR/Frameworks/sherpa-onnx.xcframework/Info.plist.cloud-hidden" \
           "$PROJECT_DIR/Frameworks/sherpa-onnx.xcframework/Info.plist"
    fi
}
trap cleanup EXIT

mkdir -p "$DIST_DIR"

# Clean build cache when sherpa-onnx availability doesn't match last build.
# Package.swift conditionally defines HAS_SHERPA_ONNX based on framework presence,
# but swift build won't re-evaluate this if source files haven't changed.
SHERPA_AVAILABLE="no"
[ -f "$PROJECT_DIR/Frameworks/sherpa-onnx.xcframework/Info.plist" ] && SHERPA_AVAILABLE="yes"
LAST_SHERPA_STATE="$PROJECT_DIR/.build/.sherpa-state"
if [ -f "$LAST_SHERPA_STATE" ] && [ "$(cat "$LAST_SHERPA_STATE")" != "${VARIANT}-${SHERPA_AVAILABLE}" ]; then
    echo "Variant/sherpa state changed, cleaning build cache..."
    swift package clean 2>/dev/null || true
fi

# For cloud builds, temporarily hide sherpa-onnx so Package.swift excludes it
if [ "$VARIANT" = "cloud" ] && [ -f "$PROJECT_DIR/Frameworks/sherpa-onnx.xcframework/Info.plist" ]; then
    echo "Hiding sherpa-onnx framework for cloud build..."
    mv "$PROJECT_DIR/Frameworks/sherpa-onnx.xcframework/Info.plist" \
       "$PROJECT_DIR/Frameworks/sherpa-onnx.xcframework/Info.plist.cloud-hidden"
fi

VARIANT="$VARIANT" ARCH="$ARCH" APP_VERSION="$APP_VERSION" \
    APP_PATH="$STAGING_DIR/${APP_NAME}.app" bash "$SCRIPT_DIR/package-app.sh"

# Record variant/sherpa state for next build's cache invalidation
mkdir -p "$PROJECT_DIR/.build"
echo "${VARIANT}-${SHERPA_AVAILABLE}" > "$PROJECT_DIR/.build/.sherpa-state"
ln -s /Applications "$STAGING_DIR/Applications"

# Check signing identity before staging dir might get cleaned up
SIGNED_WITH_DEVID=0
CODESIGN_INFO=$(codesign -dvv "$STAGING_DIR/${APP_NAME}.app" 2>&1 || true)
if echo "$CODESIGN_INFO" | grep -q "Developer ID"; then
    SIGNED_WITH_DEVID=1
    echo "Verified: signed with Developer ID"
fi

rm -f "$DMG_PATH"
echo "Creating DMG at $DMG_PATH..."
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)

# Notarize and staple if Developer ID signing was used
NOTARY_PROFILE="${NOTARY_PROFILE:-type4me-notary}"
if [ "$SIGNED_WITH_DEVID" = "1" ]; then
    echo ""
    echo "=== Notarizing DMG ==="
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait

    echo "Stapling notarization ticket..."
    xcrun stapler staple "$DMG_PATH"
    echo "Notarization complete."
else
    echo "(Skipping notarization: not signed with Developer ID)"
fi

echo ""
echo "=== DMG ready ==="
echo "  Path: $DMG_PATH"
echo "  Size: $DMG_SIZE"
echo "  Variant: $VARIANT"
echo "  Arch: $ARCH"
