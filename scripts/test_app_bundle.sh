#!/bin/bash
set -euo pipefail

APP_PATH="${1:-${APP_PATH:-/Applications/Type4Me.app}}"
EXPECTED_BUNDLE_ID="${EXPECTED_BUNDLE_ID:-com.type4me.app}"
EXPECTED_APP_NAME="${EXPECTED_APP_NAME:-Type4Me}"
EXPECTED_APP_VERSION="${EXPECTED_APP_VERSION:-1.0.0}"
EXPECTED_APP_BUILD="${EXPECTED_APP_BUILD:-1}"
INFO_PLIST="$APP_PATH/Contents/Info.plist"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

read_plist() {
    local key="$1"
    /usr/libexec/PlistBuddy -c "Print :$key" "$INFO_PLIST" 2>/dev/null
}

[ -d "$APP_PATH" ] || fail "app bundle not found at $APP_PATH"
[ -f "$INFO_PLIST" ] || fail "Info.plist missing at $INFO_PLIST"
[ -f "$APP_PATH/Contents/MacOS/Type4Me" ] || fail "app executable missing"
[ -f "$APP_PATH/Contents/Resources/AppIcon.icns" ] || fail "app icon missing"

[ "$(read_plist CFBundleExecutable)" = "Type4Me" ] || fail "CFBundleExecutable should be Type4Me"
[ "$(read_plist CFBundleIdentifier)" = "$EXPECTED_BUNDLE_ID" ] || fail "CFBundleIdentifier should be $EXPECTED_BUNDLE_ID"
[ "$(read_plist CFBundleName)" = "$EXPECTED_APP_NAME" ] || fail "CFBundleName should be $EXPECTED_APP_NAME"
[ "$(read_plist CFBundleDisplayName)" = "$EXPECTED_APP_NAME" ] || fail "CFBundleDisplayName should be $EXPECTED_APP_NAME"
[ "$(read_plist CFBundlePackageType)" = "APPL" ] || fail "CFBundlePackageType should be APPL"
[ "$(read_plist CFBundleShortVersionString)" = "$EXPECTED_APP_VERSION" ] || fail "CFBundleShortVersionString should be $EXPECTED_APP_VERSION"
[ "$(read_plist CFBundleVersion)" = "$EXPECTED_APP_BUILD" ] || fail "CFBundleVersion should be $EXPECTED_APP_BUILD"
[ "$(read_plist CFBundleIconFile)" = "AppIcon" ] || fail "CFBundleIconFile should be AppIcon"
[ "$(read_plist LSMinimumSystemVersion)" = "14.0" ] || fail "LSMinimumSystemVersion should be 14.0"
[ -n "$(read_plist NSMicrophoneUsageDescription)" ] || fail "NSMicrophoneUsageDescription should be present"
[ -n "$(read_plist NSAppleEventsUsageDescription)" ] || fail "NSAppleEventsUsageDescription should be present"
[ "$(read_plist LSUIElement)" = "true" ] || fail "LSUIElement should be true"

echo "PASS: app bundle metadata looks correct"
