#!/bin/bash
set -euo pipefail

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

read_plist() {
    local key="$1"
    local file="$2"
    /usr/libexec/PlistBuddy -c "Print :$key" "$file" 2>/dev/null
}

test_bundle() {
    local app_path="$1"
    local info_plist="$app_path/Contents/Info.plist"

    [ -d "$app_path" ] || fail "app bundle not found at $app_path"
    [ -f "$info_plist" ] || fail "Info.plist missing at $info_plist"
    [ -f "$app_path/Contents/MacOS/Type4Me" ] || fail "app executable missing"
    [ -f "$app_path/Contents/Resources/AppIcon.icns" ] || fail "app icon missing"
    [ -f "$app_path/Contents/Resources/Assets/type4me-wordmark-light.svg" ] || fail "light wordmark missing"
    [ -f "$app_path/Contents/Resources/Assets/type4me-wordmark-dark.svg" ] || fail "dark wordmark missing"

    [ "$(read_plist CFBundleExecutable "$info_plist")" = "Type4Me" ] || fail "CFBundleExecutable should be Type4Me"
    [ -n "$(read_plist CFBundleIdentifier "$info_plist")" ] || fail "CFBundleIdentifier should be present"
    [ "$(read_plist CFBundleName "$info_plist")" = "Type4Me" ] || fail "CFBundleName should be Type4Me"
    [ "$(read_plist CFBundleDisplayName "$info_plist")" = "Type4Me" ] || fail "CFBundleDisplayName should be Type4Me"
    [ "$(read_plist CFBundlePackageType "$info_plist")" = "APPL" ] || fail "CFBundlePackageType should be APPL"
    [ -n "$(read_plist CFBundleShortVersionString "$info_plist")" ] || fail "CFBundleShortVersionString should be present"
    if [ -n "${EXPECTED_VERSION:-}" ]; then
        [ "$(read_plist CFBundleShortVersionString "$info_plist")" = "$EXPECTED_VERSION" ] || fail "CFBundleShortVersionString should be $EXPECTED_VERSION"
    fi
    [ -n "$(read_plist CFBundleVersion "$info_plist")" ] || fail "CFBundleVersion should be present"
    [ "$(read_plist CFBundleIconFile "$info_plist")" = "AppIcon" ] || fail "CFBundleIconFile should be AppIcon"
    [ "$(read_plist LSMinimumSystemVersion "$info_plist")" = "14.0" ] || fail "LSMinimumSystemVersion should be 14.0"
    [ "$(read_plist LSUIElement "$info_plist")" = "true" ] || fail "LSUIElement should be true"

    # Base usage descriptions (Contents/Info.plist, development region: en)
    local mic_desc
    mic_desc="$(read_plist NSMicrophoneUsageDescription "$info_plist")"
    [ -n "$mic_desc" ] || fail "NSMicrophoneUsageDescription missing in Info.plist"
    if [ -n "${EXPECTED_MICROPHONE_USAGE_DESCRIPTION:-}" ]; then
        [ "$mic_desc" = "$EXPECTED_MICROPHONE_USAGE_DESCRIPTION" ] || fail "NSMicrophoneUsageDescription ($mic_desc) does not match expected ($EXPECTED_MICROPHONE_USAGE_DESCRIPTION)"
    fi

    local speech_desc
    speech_desc="$(read_plist NSSpeechRecognitionUsageDescription "$info_plist")"
    [ -n "$speech_desc" ] || fail "NSSpeechRecognitionUsageDescription missing in Info.plist"
    if [ -n "${EXPECTED_SPEECH_RECOGNITION_USAGE_DESCRIPTION:-}" ]; then
        [ "$speech_desc" = "$EXPECTED_SPEECH_RECOGNITION_USAGE_DESCRIPTION" ] || fail "NSSpeechRecognitionUsageDescription ($speech_desc) does not match expected ($EXPECTED_SPEECH_RECOGNITION_USAGE_DESCRIPTION)"
    fi

    local apple_events_desc
    apple_events_desc="$(read_plist NSAppleEventsUsageDescription "$info_plist")"
    [ -n "$apple_events_desc" ] || fail "NSAppleEventsUsageDescription missing in Info.plist"
    if [ -n "${EXPECTED_APPLE_EVENTS_USAGE_DESCRIPTION:-}" ]; then
        [ "$apple_events_desc" = "$EXPECTED_APPLE_EVENTS_USAGE_DESCRIPTION" ] || fail "NSAppleEventsUsageDescription ($apple_events_desc) does not match expected ($EXPECTED_APPLE_EVENTS_USAGE_DESCRIPTION)"
    fi
    if echo "$apple_events_desc" | grep -qi "accessibility access to inject"; then
        fail "NSAppleEventsUsageDescription incorrectly describes accessibility injection instead of automation: $apple_events_desc"
    fi

    # en.lproj check: must NOT exist so development region in Info.plist provides English and allows overrides
    [ ! -d "$app_path/Contents/Resources/en.lproj" ] || fail "en.lproj directory should not exist in bundle (base Info.plist provides English fallback)"

    # zh-Hans.lproj checks
    local zh_strings="$app_path/Contents/Resources/zh-Hans.lproj/InfoPlist.strings"
    [ -f "$zh_strings" ] || fail "zh-Hans.lproj/InfoPlist.strings missing at $zh_strings"
    plutil -lint "$zh_strings" >/dev/null 2>&1 || fail "zh-Hans.lproj/InfoPlist.strings is invalid strings plist"

    local zh_mic
    zh_mic="$(read_plist NSMicrophoneUsageDescription "$zh_strings")"
    [ -n "$zh_mic" ] || fail "NSMicrophoneUsageDescription missing in zh-Hans.lproj/InfoPlist.strings"
    if [ -n "${EXPECTED_ZH_HANS_MICROPHONE_USAGE_DESCRIPTION:-}" ]; then
        [ "$zh_mic" = "$EXPECTED_ZH_HANS_MICROPHONE_USAGE_DESCRIPTION" ] || fail "zh-Hans NSMicrophoneUsageDescription ($zh_mic) does not match expected ($EXPECTED_ZH_HANS_MICROPHONE_USAGE_DESCRIPTION)"
    fi

    local zh_speech
    zh_speech="$(read_plist NSSpeechRecognitionUsageDescription "$zh_strings")"
    [ -n "$zh_speech" ] || fail "NSSpeechRecognitionUsageDescription missing in zh-Hans.lproj/InfoPlist.strings"
    if [ -n "${EXPECTED_ZH_HANS_SPEECH_RECOGNITION_USAGE_DESCRIPTION:-}" ]; then
        [ "$zh_speech" = "$EXPECTED_ZH_HANS_SPEECH_RECOGNITION_USAGE_DESCRIPTION" ] || fail "zh-Hans NSSpeechRecognitionUsageDescription ($zh_speech) does not match expected ($EXPECTED_ZH_HANS_SPEECH_RECOGNITION_USAGE_DESCRIPTION)"
    fi

    local zh_events
    zh_events="$(read_plist NSAppleEventsUsageDescription "$zh_strings")"
    [ -n "$zh_events" ] || fail "NSAppleEventsUsageDescription missing in zh-Hans.lproj/InfoPlist.strings"
    if [ -n "${EXPECTED_ZH_HANS_APPLE_EVENTS_USAGE_DESCRIPTION:-}" ]; then
        [ "$zh_events" = "$EXPECTED_ZH_HANS_APPLE_EVENTS_USAGE_DESCRIPTION" ] || fail "zh-Hans NSAppleEventsUsageDescription ($zh_events) does not match expected ($EXPECTED_ZH_HANS_APPLE_EVENTS_USAGE_DESCRIPTION)"
    fi
    if echo "$zh_events" | grep -q "辅助功能权限来注入"; then
        fail "zh-Hans NSAppleEventsUsageDescription incorrectly describes accessibility injection instead of automation: $zh_events"
    fi
}

test_packaging_overrides() {
    local script_dir
    script_dir="$(cd "$(dirname "$0")" && /bin/pwd -P)"
    local temp_dir
    temp_dir="$(mktemp -d)"
    local dummy_bin="$temp_dir/Type4Me"
    if [ -f "$script_dir/../.build/release/Type4Me" ]; then
        cp "$script_dir/../.build/release/Type4Me" "$dummy_bin"
    else
        cp /bin/echo "$dummy_bin"
    fi
    echo "Testing package-app.sh default behavior..."
    local test_app_default="$temp_dir/Type4Me-default.app"
    APP_PATH="$test_app_default" \
    BINARY="$dummy_bin" \
    SKIP_BUILD=1 \
    SIGNING_IDENTITY="-" \
    bash "$script_dir/package-app.sh" >/dev/null

    test_bundle "$test_app_default"

    echo "Testing package-app.sh override behavior..."
    local test_app_overrides="$temp_dir/Type4Me-overrides.app"
    local custom_mic_en="Custom Mic Access for English"
    local custom_speech_en="Custom Speech Access for English"
    local custom_events_en="Custom AppleEvents Access for English"
    local custom_mic_zh="自定义麦克风权限说明"
    local custom_speech_zh="自定义语音识别权限说明"
    local custom_events_zh="自定义自动化控制权限说明"

    APP_PATH="$test_app_overrides" \
    BINARY="$dummy_bin" \
    SKIP_BUILD=1 \
    SIGNING_IDENTITY="-" \
    MICROPHONE_USAGE_DESCRIPTION="$custom_mic_en" \
    SPEECH_RECOGNITION_USAGE_DESCRIPTION="$custom_speech_en" \
    APPLE_EVENTS_USAGE_DESCRIPTION="$custom_events_en" \
    ZH_HANS_MICROPHONE_USAGE_DESCRIPTION="$custom_mic_zh" \
    ZH_HANS_SPEECH_RECOGNITION_USAGE_DESCRIPTION="$custom_speech_zh" \
    ZH_HANS_APPLE_EVENTS_USAGE_DESCRIPTION="$custom_events_zh" \
    bash "$script_dir/package-app.sh" >/dev/null

    EXPECTED_MICROPHONE_USAGE_DESCRIPTION="$custom_mic_en" \
    EXPECTED_SPEECH_RECOGNITION_USAGE_DESCRIPTION="$custom_speech_en" \
    EXPECTED_APPLE_EVENTS_USAGE_DESCRIPTION="$custom_events_en" \
    EXPECTED_ZH_HANS_MICROPHONE_USAGE_DESCRIPTION="$custom_mic_zh" \
    EXPECTED_ZH_HANS_SPEECH_RECOGNITION_USAGE_DESCRIPTION="$custom_speech_zh" \
    EXPECTED_ZH_HANS_APPLE_EVENTS_USAGE_DESCRIPTION="$custom_events_zh" \
    test_bundle "$test_app_overrides"

    echo "PASS: package-app.sh packaging overrides verified successfully"
}

if [ "${1:-}" = "--test-packaging" ] || [ "${1:-}" = "--test-overrides" ]; then
    test_packaging_overrides
    exit 0
fi

APP_PATH="${1:-${APP_PATH:-/Applications/Type4Me.app}}"
test_bundle "$APP_PATH"
echo "PASS: app bundle metadata looks correct at $APP_PATH"
