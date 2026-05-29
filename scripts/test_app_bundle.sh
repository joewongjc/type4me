#!/bin/bash
set -euo pipefail

APP_PATH="${1:-${APP_PATH:-/Applications/Type4Me.app}}"
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
[ "$(read_plist CFBundleIdentifier)" = "com.type4me.app" ] || fail "CFBundleIdentifier should be com.type4me.app"
[ "$(read_plist CFBundleName)" = "Type4Me" ] || fail "CFBundleName should be Type4Me"
[ "$(read_plist CFBundleDisplayName)" = "Type4Me" ] || fail "CFBundleDisplayName should be Type4Me"
[ "$(read_plist CFBundlePackageType)" = "APPL" ] || fail "CFBundlePackageType should be APPL"
[ "$(read_plist CFBundleShortVersionString)" = "1.0.0" ] || fail "CFBundleShortVersionString should be 1.0.0"
[ "$(read_plist CFBundleVersion)" = "1" ] || fail "CFBundleVersion should be 1"
[ "$(read_plist CFBundleIconFile)" = "AppIcon" ] || fail "CFBundleIconFile should be AppIcon"
[ "$(read_plist LSMinimumSystemVersion)" = "14.0" ] || fail "LSMinimumSystemVersion should be 14.0"
[ -n "$(read_plist NSMicrophoneUsageDescription)" ] || fail "NSMicrophoneUsageDescription should be present"
[ -n "$(read_plist NSAppleEventsUsageDescription)" ] || fail "NSAppleEventsUsageDescription should be present"
[ "$(read_plist LSUIElement)" = "true" ] || fail "LSUIElement should be true"

echo "PASS: app bundle metadata looks correct"
