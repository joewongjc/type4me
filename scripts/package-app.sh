#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && /bin/pwd -P)"
APP_PATH="${APP_PATH:-$PROJECT_DIR/dist/Type4Me.app}"
APP_NAME="Type4Me"
APP_EXECUTABLE="Type4Me"
APP_ICON_NAME="AppIcon"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.type4me.app}"
APP_VERSION="${APP_VERSION:-1.4.0}"
APP_BUILD="${APP_BUILD:-1}"
MIN_SYSTEM_VERSION="${MIN_SYSTEM_VERSION:-14.0}"
MICROPHONE_USAGE_DESCRIPTION="${MICROPHONE_USAGE_DESCRIPTION:-Type4Me 需要访问麦克风以录制语音并将其转换为文本。}"
APPLE_EVENTS_USAGE_DESCRIPTION="${APPLE_EVENTS_USAGE_DESCRIPTION:-Type4Me 需要辅助功能权限来注入转写文字到其他应用}"
INFO_PLIST="$APP_PATH/Contents/Info.plist"

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    SIGNING_IDENTITY="$CODESIGN_IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Type4Me Dev"; then
    SIGNING_IDENTITY="Type4Me Dev"
else
    SIGNING_IDENTITY="-"
fi

echo "Building universal release (arm64 + x86_64)..."
swift build -c release --package-path "$PROJECT_DIR" --arch arm64 --arch x86_64 2>&1 | grep -E "Build complete|Build succeeded|error:|warning:" || true

if [ -f "$PROJECT_DIR/.build/apple/Products/Release/Type4Me" ]; then
    BINARY="$PROJECT_DIR/.build/apple/Products/Release/Type4Me"
elif [ -f "$PROJECT_DIR/.build/release/Type4Me" ]; then
    BINARY="$PROJECT_DIR/.build/release/Type4Me"
else
    BINARY="$(find "$PROJECT_DIR/.build" -path '*/release/Type4Me' -type f -not -path '*/x86_64/*' -not -path '*/arm64/*' | head -n 1)"
fi

if [ ! -f "$BINARY" ]; then
    echo "Build failed: binary not found"
    exit 1
fi

echo "Packaging app bundle at $APP_PATH..."
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BINARY" "$APP_PATH/Contents/MacOS/$APP_EXECUTABLE"
cp "$PROJECT_DIR/Type4Me/Resources/${APP_ICON_NAME}.icns" "$APP_PATH/Contents/Resources/${APP_ICON_NAME}.icns" 2>/dev/null || true

cat >"$INFO_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_EXECUTABLE}</string>
    <key>CFBundleIconFile</key>
    <string>${APP_ICON_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${APP_BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${APP_BUILD}</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_SYSTEM_VERSION}</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>${MICROPHONE_USAGE_DESCRIPTION}</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>${APPLE_EVENTS_USAGE_DESCRIPTION}</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

mkdir -p "$APP_PATH/Contents/Resources/Sounds"
cp "$PROJECT_DIR/Type4Me/Resources/Sounds/"*.wav "$APP_PATH/Contents/Resources/Sounds/" 2>/dev/null || true

# Copy SenseVoice model if available (for full DMG builds)
SENSEVOICE_MODEL_CACHE="$HOME/.cache/modelscope/hub/models/iic/SenseVoiceSmall"
if [ "${BUNDLE_SENSEVOICE_MODEL:-0}" = "1" ] && [ -d "$SENSEVOICE_MODEL_CACHE" ]; then
    echo "Bundling SenseVoice model..."
    mkdir -p "$APP_PATH/Contents/Resources/Models"
    cp -R "$SENSEVOICE_MODEL_CACHE" "$APP_PATH/Contents/Resources/Models/SenseVoiceSmall"
    echo "SenseVoice model bundled."
fi

# Copy sensevoice-server if built and BUNDLE_LOCAL_ASR is set
SENSEVOICE_DIST="$PROJECT_DIR/sensevoice-server/dist/sensevoice-server"
if [ "${BUNDLE_LOCAL_ASR:-0}" = "1" ] && [ -d "$SENSEVOICE_DIST" ]; then
    echo "Bundling sensevoice-server..."
    cp -R "$SENSEVOICE_DIST" "$APP_PATH/Contents/MacOS/sensevoice-server-dist"
    # Create a wrapper script at the expected path
    cat > "$APP_PATH/Contents/MacOS/sensevoice-server" << 'WRAPPER'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/sensevoice-server-dist/sensevoice-server" "$@"
WRAPPER
    chmod +x "$APP_PATH/Contents/MacOS/sensevoice-server"
    # Sign all binaries in the server dist for Gatekeeper
    find "$APP_PATH/Contents/MacOS/sensevoice-server-dist" -type f \( -name "*.dylib" -o -name "*.so" -o -perm +111 \) \
        -exec codesign --force --sign "${SIGNING_IDENTITY}" {} \; 2>/dev/null || true
    codesign --force --sign "${SIGNING_IDENTITY}" "$APP_PATH/Contents/MacOS/sensevoice-server" 2>/dev/null || true
    echo "sensevoice-server bundled and signed."
fi

# Copy third-party licenses
cp "$PROJECT_DIR/Type4Me/Resources/THIRD_PARTY_LICENSES.txt" "$APP_PATH/Contents/Resources/" 2>/dev/null || true

echo "Signing with '${SIGNING_IDENTITY}'..."
# Temporarily move out sensevoice-server-dist before signing — its PyInstaller
# internals (.dist-info, .dylibs dirs) cause codesign to fail with
# "bundle format unrecognized". The binaries inside are already signed above.
SERVER_DIST="$APP_PATH/Contents/MacOS/sensevoice-server-dist"
SERVER_DIST_TMP="/tmp/sensevoice-server-dist-codesign-$$"
if [ -d "$SERVER_DIST" ]; then
    mv "$SERVER_DIST" "$SERVER_DIST_TMP"
fi

codesign -f -s "$SIGNING_IDENTITY" "$APP_PATH" 2>/dev/null && echo "Signed." || echo "Signing skipped (no identity available)."

if [ -d "$SERVER_DIST_TMP" ]; then
    mv "$SERVER_DIST_TMP" "$SERVER_DIST"
fi

echo "App bundle ready at $APP_PATH"
