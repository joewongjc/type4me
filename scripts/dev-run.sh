#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && /bin/pwd -P)"
REQUIRE_STABLE_SIGNING_VALUE=1

find_identity() {
    local prefix="$1"
    security find-identity -v -p codesigning 2>/dev/null \
        | sed -n "s/.*\"\($prefix[^\"]*\)\".*/\1/p" \
        | head -1
}

SIGNING_IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$SIGNING_IDENTITY" ]; then
    SIGNING_IDENTITY="$(find_identity 'Apple Development:')"
fi
if [ -z "$SIGNING_IDENTITY" ]; then
    SIGNING_IDENTITY="$(find_identity 'Developer ID Application:')"
fi
if [ -z "$SIGNING_IDENTITY" ]; then
    SIGNING_IDENTITY="$(find_identity 'Type4Me Dev')"
fi

if [ -z "$SIGNING_IDENTITY" ]; then
    if [ "${ALLOW_ADHOC_SIGNING:-0}" = "1" ]; then
        echo "WARNING: ALLOW_ADHOC_SIGNING=1; macOS permissions may reset after this build."
        REQUIRE_STABLE_SIGNING_VALUE=0
        SIGNING_IDENTITY="-"
    else
        echo "No Apple signing identity found; running one-time setup..."
        bash "$SCRIPT_DIR/setup-dev-signing.sh"
        SIGNING_IDENTITY="$(find_identity 'Apple Development:')"
        if [ -z "$SIGNING_IDENTITY" ]; then
            echo "ERROR: Signing setup did not produce an Apple identity." >&2
            exit 1
        fi
    fi
fi

APP_NAME="${APP_NAME:-Type4Me Dev}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.type4me.dev}"
URL_SCHEME="${URL_SCHEME:-type4me-dev}"
APP_PATH="${APP_PATH:-/Applications/Type4Me Dev.app}"
ARCH="${ARCH:-arm64}"
VARIANT="${VARIANT:-cloud}"
REQUIRE_STABLE_SIGNING="${REQUIRE_STABLE_SIGNING:-$REQUIRE_STABLE_SIGNING_VALUE}"

if [ -z "${APP_BUILD:-}" ]; then
    PREVIOUS_BUILD=""
    if [ -f "$APP_PATH/Contents/Info.plist" ]; then
        PREVIOUS_BUILD=$(plutil -extract CFBundleVersion raw "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)
    fi
    case "$PREVIOUS_BUILD" in
        ""|*[!0-9]*) APP_BUILD=1 ;;
        *) APP_BUILD=$((10#$PREVIOUS_BUILD + 1)) ;;
    esac
fi

echo "Dev build number: $APP_BUILD"

echo "Stopping $APP_NAME..."
osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
sleep 1

PREVIOUS_REQUIREMENT=""
PREVIOUS_WAS_STABLE=0
if [ -d "$APP_PATH" ]; then
    PREVIOUS_REQUIREMENT=$(codesign -d -r- "$APP_PATH" 2>&1 \
        | sed -n 's/^designated => //p' || true)
    PREVIOUS_SIGNATURE=$(codesign -dv "$APP_PATH" 2>&1 \
        | sed -n 's/^Signature=//p' || true)
    if [ -n "$PREVIOUS_REQUIREMENT" ] && [ "$PREVIOUS_SIGNATURE" != "adhoc" ]; then
        PREVIOUS_WAS_STABLE=1
    fi
fi

APP_NAME="$APP_NAME" \
APP_BUNDLE_ID="$APP_BUNDLE_ID" \
URL_SCHEME="$URL_SCHEME" \
APP_PATH="$APP_PATH" \
ARCH="$ARCH" \
VARIANT="$VARIANT" \
APP_BUILD="$APP_BUILD" \
TYPE4ME_DEV_BUILD=1 \
CODESIGN_IDENTITY="$SIGNING_IDENTITY" \
bash "$SCRIPT_DIR/package-app.sh"

CURRENT_BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw "$APP_PATH/Contents/Info.plist")
CURRENT_REQUIREMENT=$(codesign -d -r- "$APP_PATH" 2>&1 \
    | sed -n 's/^designated => //p' || true)
CURRENT_SIGNATURE=$(codesign -dv "$APP_PATH" 2>&1 \
    | sed -n 's/^Signature=//p' || true)

if [ "$CURRENT_BUNDLE_ID" != "com.type4me.dev" ]; then
    echo "ERROR: Dev package has unexpected bundle ID: $CURRENT_BUNDLE_ID" >&2
    exit 1
fi
if [ "$REQUIRE_STABLE_SIGNING" = "1" ] \
    && { [ "$CURRENT_SIGNATURE" = "adhoc" ] || [ -z "$CURRENT_REQUIREMENT" ]; }; then
    echo "ERROR: Dev package lacks a stable code-signing requirement." >&2
    exit 1
fi
if [ "$REQUIRE_STABLE_SIGNING" = "1" ] \
    && [ "$PREVIOUS_WAS_STABLE" = "1" ] \
    && [ "$CURRENT_REQUIREMENT" != "$PREVIOUS_REQUIREMENT" ]; then
    if [ "${ALLOW_SIGNING_IDENTITY_MIGRATION:-0}" = "1" ]; then
        echo "Dev signing identity migration explicitly allowed for this build."
    else
        echo "ERROR: The Dev app's designated requirement changed across rebuilds." >&2
        echo "Previous: $PREVIOUS_REQUIREMENT" >&2
        echo "Current:  $CURRENT_REQUIREMENT" >&2
        exit 1
    fi
fi

echo "Dev signing identity check passed."
echo "Designated requirement: $CURRENT_REQUIREMENT"
bash "$SCRIPT_DIR/migrate-dev-keychain-access.sh" "$APP_PATH"

echo "Launching $APP_NAME..."
launchctl asuser "$(id -u)" /usr/bin/open "$APP_PATH" 2>/dev/null || /usr/bin/open "$APP_PATH"
echo "Done."
