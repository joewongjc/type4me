#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && /bin/pwd -P)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && /bin/pwd -P)"
APP_VERSION="${APP_VERSION:-1.9.3}"
APP_FLAVOR="${APP_FLAVOR:-public}"  # public or personal
VARIANT="${VARIANT:-pure}"          # pure, official, local, or cloud(alias pure)
ARCH="${ARCH:-}"                    # arm64 or universal (default: universal for pure/official, arm64 for local)
DIST_DIR="${DIST_DIR:-$PROJECT_DIR/dist}"
NOTARY_PROFILE="${NOTARY_PROFILE:-AC_NOTARY}"
TIMESTAMP_URL="${TIMESTAMP_URL:-http://timestamp.apple.com/ts01}"
SKIP_NOTARIZE="${SKIP_NOTARIZE:-0}"
KEEP_OUT_DIR="${KEEP_OUT_DIR:-0}"

case "$APP_FLAVOR" in
    public)
        APP_NAME="${APP_NAME:-Type4Me}"
        APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.type4me.app}"
        URL_SCHEME="${URL_SCHEME:-type4me}"
        ;;
    personal)
        APP_NAME="${APP_NAME:-Type4Me CtriXin}"
        APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.ctrixin.type4me}"
        URL_SCHEME="${URL_SCHEME:-type4me-ctrixin}"
        ;;
    *) echo "ERROR: Unknown APP_FLAVOR=$APP_FLAVOR (expected public or personal)"; exit 1 ;;
esac

case "$VARIANT" in
    pure|local) ;;
    official)
        if [ ! -f "$PROJECT_DIR/Type4Me/CloudSubscription/marker" ]; then
            echo "ERROR: official variant is archived (subscription paused)."
            echo "       To re-enable, restore Type4Me/CloudSubscription/marker first."
            exit 1
        fi
        ;;
    cloud) VARIANT="pure" ;;
    *) echo "ERROR: Unknown VARIANT=$VARIANT (expected pure, official, or local)"; exit 1 ;;
esac

if [ -z "$ARCH" ]; then
    if [ "$VARIANT" = "local" ]; then
        ARCH="arm64"
    else
        ARCH="universal"
    fi
fi

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    SIGNING_IDENTITY="$CODESIGN_IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    SIGNING_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
else
    SIGNING_IDENTITY="-"
fi

if [ "$SKIP_NOTARIZE" != "1" ] && [ "$SIGNING_IDENTITY" = "-" ]; then
    echo "ERROR: Notarized DMG builds require a Developer ID Application identity."
    echo "       Set CODESIGN_IDENTITY or use SKIP_NOTARIZE=1 for local smoke tests."
    exit 1
fi

APP_BUNDLE="${APP_NAME}.app"
SLUG=$(printf '%s-%s-%s' "$APP_NAME" "$VARIANT" "$ARCH" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9._-')
OUT_DIR="${OUT_DIR:-$DIST_DIR/notarized/${SLUG}-$(date +%Y%m%d-%H%M%S)}"
APP="$OUT_DIR/$APP_BUNDLE"
VOLUME_NAME="${VOLUME_NAME:-$APP_NAME}"
DMG_BASENAME="${DMG_NAME:-${APP_NAME}-v${APP_VERSION}-${VARIANT}-${ARCH}}"
DMG_TMP="$OUT_DIR/${DMG_BASENAME}.dmg"
if [ "$SKIP_NOTARIZE" = "1" ]; then
    DMG="$OUT_DIR/${DMG_BASENAME}-signed.dmg"
else
    DMG="$OUT_DIR/${DMG_BASENAME}-notarized.dmg"
fi
APP_ENTITLEMENTS="${APP_ENTITLEMENTS:-$PROJECT_DIR/entitlements.plist}"
HELPER_ENTITLEMENTS="${HELPER_ENTITLEMENTS:-}"
APP_ZIP="$OUT_DIR/app-notary.zip"
STAGE="$OUT_DIR/dmg-stage"

cleanup() {
    if [ "$KEEP_OUT_DIR" != "1" ] && [ "$SKIP_NOTARIZE" = "1" ]; then
        : # Keep dry-run output so local validation can inspect it.
    fi
    if [ -f "$PROJECT_DIR/Frameworks/sherpa-onnx.xcframework/Info.plist.cloud-hidden" ]; then
        mv "$PROJECT_DIR/Frameworks/sherpa-onnx.xcframework/Info.plist.cloud-hidden" \
           "$PROJECT_DIR/Frameworks/sherpa-onnx.xcframework/Info.plist"
    fi
    if [ -f "$PROJECT_DIR/Type4Me/CloudSubscription/marker.hidden" ]; then
        mv "$PROJECT_DIR/Type4Me/CloudSubscription/marker.hidden" \
           "$PROJECT_DIR/Type4Me/CloudSubscription/marker"
    fi
}
trap cleanup EXIT

mkdir -p "$OUT_DIR" "$DIST_DIR"

NEEDS_SHERPA=0
NEEDS_SUBSCRIPTION=0
[ "$VARIANT" = "local" ] && NEEDS_SHERPA=1
[ "$VARIANT" = "official" ] && NEEDS_SUBSCRIPTION=1

SHERPA_AVAILABLE="no"
[ -f "$PROJECT_DIR/Frameworks/sherpa-onnx.xcframework/Info.plist" ] && SHERPA_AVAILABLE="yes"
SUB_AVAILABLE="no"
[ -f "$PROJECT_DIR/Type4Me/CloudSubscription/marker" ] && SUB_AVAILABLE="yes"
BUILD_STATE="${VARIANT}-sherpa:${SHERPA_AVAILABLE}-sub:${SUB_AVAILABLE}"
LAST_STATE_FILE="$PROJECT_DIR/.build/.variant-state"
if [ -f "$LAST_STATE_FILE" ] && [ "$(cat "$LAST_STATE_FILE")" != "$BUILD_STATE" ]; then
    echo "Build state changed, cleaning build cache..."
    swift package clean 2>/dev/null || true
fi

if [ "$NEEDS_SHERPA" = "0" ] && [ -f "$PROJECT_DIR/Frameworks/sherpa-onnx.xcframework/Info.plist" ]; then
    echo "Hiding sherpa-onnx framework for ${VARIANT} build..."
    mv "$PROJECT_DIR/Frameworks/sherpa-onnx.xcframework/Info.plist" \
       "$PROJECT_DIR/Frameworks/sherpa-onnx.xcframework/Info.plist.cloud-hidden"
fi

if [ "$NEEDS_SUBSCRIPTION" = "0" ] && [ -f "$PROJECT_DIR/Type4Me/CloudSubscription/marker" ]; then
    echo "Hiding CloudSubscription for ${VARIANT} build..."
    mv "$PROJECT_DIR/Type4Me/CloudSubscription/marker" \
       "$PROJECT_DIR/Type4Me/CloudSubscription/marker.hidden"
fi

cat > "$OUT_DIR/build-info.txt" <<INFO
app_name=$APP_NAME
app_bundle_id=$APP_BUNDLE_ID
url_scheme=$URL_SCHEME
app_flavor=$APP_FLAVOR
variant=$VARIANT
arch=$ARCH
notary_profile=$NOTARY_PROFILE
signing_identity=$SIGNING_IDENTITY
INFO

APP_FLAVOR="$APP_FLAVOR" \
APP_NAME="$APP_NAME" \
APP_BUNDLE_ID="$APP_BUNDLE_ID" \
URL_SCHEME="$URL_SCHEME" \
VARIANT="$VARIANT" \
ARCH="$ARCH" \
APP_VERSION="$APP_VERSION" \
CODESIGN_IDENTITY="$SIGNING_IDENTITY" \
APP_PATH="$APP" \
bash "$SCRIPT_DIR/package-app.sh"

mkdir -p "$PROJECT_DIR/.build"
echo "$BUILD_STATE" > "$LAST_STATE_FILE"
xattr -cr "$APP"

COMMON=(--force --options runtime --timestamp="$TIMESTAMP_URL" --sign "$SIGNING_IDENTITY")
if [ "$SIGNING_IDENTITY" != "-" ]; then
    echo "Re-signing nested code inside-out..."

    if [ -d "$APP/Contents/Frameworks" ]; then
        while IFS= read -r -d '' item; do
            codesign "${COMMON[@]}" --deep "$item"
        done < <(find "$APP/Contents/Frameworks" -mindepth 1 -maxdepth 1 -print0)
    fi

    if [ -d "$APP/Contents/PlugIns" ]; then
        while IFS= read -r -d '' item; do
            codesign "${COMMON[@]}" --deep "$item"
        done < <(find "$APP/Contents/PlugIns" -mindepth 1 -maxdepth 1 -print0)
    fi

    while IFS= read -r -d '' file; do
        [ "$file" = "$APP/Contents/MacOS/Type4Me" ] && continue
        if file "$file" | grep -q 'Mach-O'; then
            if [ -n "$HELPER_ENTITLEMENTS" ] && [ -f "$HELPER_ENTITLEMENTS" ]; then
                codesign "${COMMON[@]}" --entitlements "$HELPER_ENTITLEMENTS" "$file"
            else
                codesign "${COMMON[@]}" "$file"
            fi
        fi
    done < <(find "$APP/Contents" -type f -print0)

    QWEN3_WRAPPER="$APP/Contents/MacOS/qwen3-asr-server"
    if [ -f "$QWEN3_WRAPPER" ]; then
        if [ -n "$HELPER_ENTITLEMENTS" ] && [ -f "$HELPER_ENTITLEMENTS" ]; then
            codesign "${COMMON[@]}" --entitlements "$HELPER_ENTITLEMENTS" "$QWEN3_WRAPPER"
        else
            codesign "${COMMON[@]}" "$QWEN3_WRAPPER"
        fi
    fi

    APP_SIGN_ARGS=("${COMMON[@]}")
    if [ -f "$APP_ENTITLEMENTS" ]; then
        APP_SIGN_ARGS+=(--entitlements "$APP_ENTITLEMENTS")
    fi
    codesign "${APP_SIGN_ARGS[@]}" "$APP"
fi

codesign --verify --deep --strict --verbose=2 "$APP"

if [ "$SKIP_NOTARIZE" != "1" ] && [ "$SIGNING_IDENTITY" != "-" ]; then
    echo "Submitting app for notarization..."
    ditto -c -k --keepParent "$APP" "$APP_ZIP"
    xcrun notarytool submit "$APP_ZIP" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait --timeout 45m \
        --no-s3-acceleration \
        --output-format json | tee "$OUT_DIR/app-notary.json"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
else
    echo "Skipping app notarization (SKIP_NOTARIZE=$SKIP_NOTARIZE, SIGNING_IDENTITY=$SIGNING_IDENTITY)."
fi

rm -rf "$STAGE" "$DMG_TMP" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_BUNDLE"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG_TMP"

if [ "$SIGNING_IDENTITY" != "-" ]; then
    codesign --force --timestamp="$TIMESTAMP_URL" --sign "$SIGNING_IDENTITY" "$DMG_TMP"
    codesign --verify --verbose=2 "$DMG_TMP"
fi

if [ "$SKIP_NOTARIZE" != "1" ] && [ "$SIGNING_IDENTITY" != "-" ]; then
    echo "Submitting DMG for notarization..."
    xcrun notarytool submit "$DMG_TMP" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait --timeout 45m \
        --no-s3-acceleration \
        --output-format json | tee "$OUT_DIR/dmg-notary.json"
    cp "$DMG_TMP" "$DMG"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
else
    cp "$DMG_TMP" "$DMG"
    echo "Skipping DMG notarization (SKIP_NOTARIZE=$SKIP_NOTARIZE, SIGNING_IDENTITY=$SIGNING_IDENTITY)."
fi

shasum -a 256 "$DMG" | tee "$OUT_DIR/SHA256SUMS.txt"

cat <<DONE

=== DMG ready ===
  App: $APP
  DMG: $DMG
  SHA256: $OUT_DIR/SHA256SUMS.txt
  Flavor: $APP_FLAVOR
  Bundle ID: $APP_BUNDLE_ID
  URL scheme: $URL_SCHEME
  Variant: $VARIANT
  Arch: $ARCH
DONE
