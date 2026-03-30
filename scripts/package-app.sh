#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && /bin/pwd -P)"
APP_PATH="${APP_PATH:-$PROJECT_DIR/dist/Type4Me.app}"
APP_NAME="Type4Me"
APP_EXECUTABLE="Type4Me"
APP_ICON_NAME="AppIcon"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.type4me.app}"
APP_VERSION="${APP_VERSION:-1.5.1}"
APP_BUILD="${APP_BUILD:-1}"
MIN_SYSTEM_VERSION="${MIN_SYSTEM_VERSION:-14.0}"
MICROPHONE_USAGE_DESCRIPTION="${MICROPHONE_USAGE_DESCRIPTION:-Type4Me 需要访问麦克风以录制语音并将其转换为文本。}"
SPEECH_RECOGNITION_USAGE_DESCRIPTION="${SPEECH_RECOGNITION_USAGE_DESCRIPTION:-Type4Me 需要语音识别权限以将你的语音转写为文字。}"
APPLE_EVENTS_USAGE_DESCRIPTION="${APPLE_EVENTS_USAGE_DESCRIPTION:-Type4Me 需要辅助功能权限来注入转写文字到其他应用}"
INFO_PLIST="$APP_PATH/Contents/Info.plist"

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    SIGNING_IDENTITY="$CODESIGN_IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Type4Me Dev"; then
    SIGNING_IDENTITY="Type4Me Dev"
elif [ -d "$APP_PATH" ] && codesign -dv "$APP_PATH" 2>/dev/null; then
    # Existing app is already signed -- reuse its identity to preserve Accessibility permission.
    # Changing signing identity invalidates macOS TCC entries (Accessibility, etc).
    EXISTING_AUTHORITY=$(codesign -dvvv "$APP_PATH" 2>&1 | grep "^Authority=" | head -1 | cut -d= -f2)
    if [ -n "$EXISTING_AUTHORITY" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "$EXISTING_AUTHORITY"; then
        SIGNING_IDENTITY="$EXISTING_AUTHORITY"
        echo "Reusing existing signing identity: $SIGNING_IDENTITY"
    else
        # Existing app was ad-hoc signed or cert is gone -- keep ad-hoc to not break permission
        SIGNING_IDENTITY="-"
    fi
else
    # Fresh install, no existing app. Create a persistent self-signed certificate
    # instead of ad-hoc. Ad-hoc signing generates a new CDHash every build, causing
    # macOS to revoke Accessibility permission on each rebuild.
    CERT_NAME="Type4Me Local"
    if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
        echo "Creating self-signed certificate '$CERT_NAME' for consistent code signing..."
        echo "This is a one-time operation to keep Accessibility permissions across rebuilds."
        CERT_TEMP=$(mktemp -d)
        cat > "$CERT_TEMP/cert.cfg" <<CERTEOF
[ req ]
distinguished_name = req_dn
[ req_dn ]
CN = $CERT_NAME
[ extensions ]
keyUsage = digitalSignature
extendedKeyUsage = codeSigning
CERTEOF
        openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout "$CERT_TEMP/key.pem" -out "$CERT_TEMP/cert.pem" \
            -days 3650 -subj "/CN=$CERT_NAME" -extensions extensions \
            -config "$CERT_TEMP/cert.cfg" 2>/dev/null
        openssl pkcs12 -export -out "$CERT_TEMP/cert.p12" \
            -inkey "$CERT_TEMP/key.pem" -in "$CERT_TEMP/cert.pem" \
            -passout pass: 2>/dev/null
        security import "$CERT_TEMP/cert.p12" -k ~/Library/Keychains/login.keychain-db \
            -T /usr/bin/codesign -P "" 2>/dev/null || \
        security import "$CERT_TEMP/cert.p12" -k ~/Library/Keychains/login.keychain \
            -T /usr/bin/codesign -P "" 2>/dev/null || true
        security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db \
            "$CERT_TEMP/cert.pem" 2>/dev/null || \
        security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain \
            "$CERT_TEMP/cert.pem" 2>/dev/null || true
        rm -rf "$CERT_TEMP"
        echo "Certificate '$CERT_NAME' created and trusted."
    fi
    SIGNING_IDENTITY="$CERT_NAME"
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
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>${SPEECH_RECOGNITION_USAGE_DESCRIPTION}</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>${APPLE_EVENTS_USAGE_DESCRIPTION}</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>${APP_BUNDLE_ID}</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>type4me</string>
            </array>
        </dict>
    </array>
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

# Copy Qwen3-ASR model (4-bit quantized) if available
QWEN3_MODEL_CACHE="${QWEN3_MODEL_PATH:-$HOME/.cache/modelscope/hub/models/Qwen/Qwen3-ASR-0.6B-4bit}"
if [ "${BUNDLE_SENSEVOICE_MODEL:-0}" = "1" ] && [ -d "$QWEN3_MODEL_CACHE" ]; then
    echo "Bundling Qwen3-ASR model (4-bit)..."
    mkdir -p "$APP_PATH/Contents/Resources/Models/Qwen3-ASR"
    cp "$QWEN3_MODEL_CACHE"/model.safetensors "$APP_PATH/Contents/Resources/Models/Qwen3-ASR/"
    cp "$QWEN3_MODEL_CACHE"/config.json "$APP_PATH/Contents/Resources/Models/Qwen3-ASR/"
    cp "$QWEN3_MODEL_CACHE"/tokenizer_config.json "$APP_PATH/Contents/Resources/Models/Qwen3-ASR/" 2>/dev/null || true
    cp "$QWEN3_MODEL_CACHE"/vocab.json "$APP_PATH/Contents/Resources/Models/Qwen3-ASR/" 2>/dev/null || true
    cp "$QWEN3_MODEL_CACHE"/merges.txt "$APP_PATH/Contents/Resources/Models/Qwen3-ASR/" 2>/dev/null || true
    cp "$QWEN3_MODEL_CACHE"/generation_config.json "$APP_PATH/Contents/Resources/Models/Qwen3-ASR/" 2>/dev/null || true
    cp "$QWEN3_MODEL_CACHE"/preprocessor_config.json "$APP_PATH/Contents/Resources/Models/Qwen3-ASR/" 2>/dev/null || true
    echo "Qwen3-ASR model bundled."
fi

# Copy sensevoice-server if built and BUNDLE_LOCAL_ASR is set
SENSEVOICE_DIST="$PROJECT_DIR/sensevoice-server/dist/sensevoice-server"
if [ "${BUNDLE_LOCAL_ASR:-0}" = "1" ] && [ -d "$SENSEVOICE_DIST" ]; then
    echo "Bundling sensevoice-server..."
    rm -rf "$APP_PATH/Contents/MacOS/sensevoice-server-dist" "$APP_PATH/Contents/MacOS/sensevoice-server"
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
    echo "sensevoice-server bundled and signed."
fi

# Copy qwen3-asr-server if built and BUNDLE_LOCAL_ASR is set
QWEN3_DIST="$PROJECT_DIR/qwen3-asr-server/dist/qwen3-asr-server"
if [ "${BUNDLE_LOCAL_ASR:-0}" = "1" ] && [ -d "$QWEN3_DIST" ]; then
    echo "Bundling qwen3-asr-server..."
    rm -rf "$APP_PATH/Contents/MacOS/qwen3-asr-server-dist" "$APP_PATH/Contents/MacOS/qwen3-asr-server"
    cp -R "$QWEN3_DIST" "$APP_PATH/Contents/MacOS/qwen3-asr-server-dist"
    # Create a wrapper script at the expected path
    cat > "$APP_PATH/Contents/MacOS/qwen3-asr-server" << 'WRAPPER'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/qwen3-asr-server-dist/qwen3-asr-server" "$@"
WRAPPER
    chmod +x "$APP_PATH/Contents/MacOS/qwen3-asr-server"
    # Sign all binaries in the server dist for Gatekeeper
    find "$APP_PATH/Contents/MacOS/qwen3-asr-server-dist" -type f \( -name "*.dylib" -o -name "*.so" -o -name "*.metallib" -o -perm +111 \) \
        -exec codesign --force --sign "${SIGNING_IDENTITY}" {} \; 2>/dev/null || true
    echo "qwen3-asr-server bundled and signed."
fi

# Copy LLM model if available (for local LLM DMG builds)
LLM_MODEL_DIR="$PROJECT_DIR/sensevoice-server/models"
LLM_MODEL_SIZE="${BUNDLE_LOCAL_LLM:-0}"  # 0=none, 4b, 9b
if [ "$LLM_MODEL_SIZE" = "9b" ] && [ -f "$LLM_MODEL_DIR/Qwen3.5-9B-Q4_K_M.gguf" ]; then
    echo "Bundling Qwen3.5-9B LLM model (5.3GB)..."
    mkdir -p "$APP_PATH/Contents/Resources/Models"
    cp "$LLM_MODEL_DIR/Qwen3.5-9B-Q4_K_M.gguf" "$APP_PATH/Contents/Resources/Models/qwen3.5-9b-q4_k_m.gguf"
    echo "Qwen3.5-9B model bundled."
elif [ "$LLM_MODEL_SIZE" = "4b" ] && [ -f "$LLM_MODEL_DIR/qwen3-4b-q4_k_m.gguf" ]; then
    echo "Bundling Qwen3-4B LLM model (2.3GB)..."
    mkdir -p "$APP_PATH/Contents/Resources/Models"
    cp "$LLM_MODEL_DIR/qwen3-4b-q4_k_m.gguf" "$APP_PATH/Contents/Resources/Models/qwen3-4b-q4_k_m.gguf"
    echo "Qwen3-4B model bundled."
fi

# Copy third-party licenses
cp "$PROJECT_DIR/Type4Me/Resources/THIRD_PARTY_LICENSES.txt" "$APP_PATH/Contents/Resources/" 2>/dev/null || true

echo "Signing with '${SIGNING_IDENTITY}'..."
# PyInstaller dist dirs contain .dylibs and dist-info dirs that confuse
# codesign's bundle detection. Move server files out temporarily.
SERVER_TEMP=""
SV_DIST="$APP_PATH/Contents/MacOS/sensevoice-server-dist"
SV_WRAPPER="$APP_PATH/Contents/MacOS/sensevoice-server"
Q3_DIST="$APP_PATH/Contents/MacOS/qwen3-asr-server-dist"
Q3_WRAPPER="$APP_PATH/Contents/MacOS/qwen3-asr-server"
if [ -d "$SV_DIST" ] || [ -f "$SV_WRAPPER" ] || [ -d "$Q3_DIST" ] || [ -f "$Q3_WRAPPER" ]; then
    SERVER_TEMP="$(mktemp -d)"
    [ -d "$SV_DIST" ] && mv "$SV_DIST" "$SERVER_TEMP/sensevoice-server-dist"
    [ -f "$SV_WRAPPER" ] && mv "$SV_WRAPPER" "$SERVER_TEMP/sensevoice-server"
    [ -d "$Q3_DIST" ] && mv "$Q3_DIST" "$SERVER_TEMP/qwen3-asr-server-dist"
    [ -f "$Q3_WRAPPER" ] && mv "$Q3_WRAPPER" "$SERVER_TEMP/qwen3-asr-server"
fi
codesign -f -s "$SIGNING_IDENTITY" "$APP_PATH" 2>/dev/null && echo "Signed." || echo "Signing skipped (no identity available)."
if [ -n "$SERVER_TEMP" ]; then
    [ -d "$SERVER_TEMP/sensevoice-server-dist" ] && mv "$SERVER_TEMP/sensevoice-server-dist" "$SV_DIST"
    [ -f "$SERVER_TEMP/sensevoice-server" ] && mv "$SERVER_TEMP/sensevoice-server" "$SV_WRAPPER"
    [ -d "$SERVER_TEMP/qwen3-asr-server-dist" ] && mv "$SERVER_TEMP/qwen3-asr-server-dist" "$Q3_DIST"
    [ -f "$SERVER_TEMP/qwen3-asr-server" ] && mv "$SERVER_TEMP/qwen3-asr-server" "$Q3_WRAPPER"
    rm -rf "$SERVER_TEMP"
fi

# Remove quarantine flag that macOS adds to downloaded apps.
# This flag can silently prevent Accessibility permission from working.
xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true

echo "App bundle ready at $APP_PATH"
