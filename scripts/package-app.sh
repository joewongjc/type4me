#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && /bin/pwd -P)"
APP_PATH="${APP_PATH:-$PROJECT_DIR/dist/Type4Me.app}"
APP_NAME="Type4Me"
APP_EXECUTABLE="Type4Me"
APP_ICON_NAME="AppIcon"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.type4me.app}"
APP_VERSION="${APP_VERSION:-1.9.2}"
APP_BUILD="${APP_BUILD:-1}"
MIN_SYSTEM_VERSION="${MIN_SYSTEM_VERSION:-14.0}"
VARIANT="${VARIANT:-cloud}"    # cloud or local
ARCH="${ARCH:-universal}"      # arm64 or universal
MICROPHONE_USAGE_DESCRIPTION="${MICROPHONE_USAGE_DESCRIPTION:-Type4Me 需要访问麦克风以录制语音并将其转换为文本。}"
SPEECH_RECOGNITION_USAGE_DESCRIPTION="${SPEECH_RECOGNITION_USAGE_DESCRIPTION:-Type4Me 需要语音识别权限以将你的语音转写为文字。}"
APPLE_EVENTS_USAGE_DESCRIPTION="${APPLE_EVENTS_USAGE_DESCRIPTION:-Type4Me 需要辅助功能权限来注入转写文字到其他应用}"
INFO_PLIST="$APP_PATH/Contents/Info.plist"

ENTITLEMENTS="$PROJECT_DIR/entitlements.plist"

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    SIGNING_IDENTITY="$CODESIGN_IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    SIGNING_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
    echo "Using Developer ID: $SIGNING_IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Type4Me Dev"; then
    SIGNING_IDENTITY="Type4Me Dev"
else
    SIGNING_IDENTITY="-"
fi

if [ "$ARCH" = "arm64" ]; then
    echo "Building arm64 release..."
    swift build -c release --package-path "$PROJECT_DIR" --arch arm64 2>&1 | grep -E "Build complete|Build succeeded|error:|warning:" || true
else
    echo "Building universal release (arm64 + x86_64)..."
    swift build -c release --package-path "$PROJECT_DIR" --arch arm64 --arch x86_64 2>&1 | grep -E "Build complete|Build succeeded|error:|warning:" || true
fi

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
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
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

# --- Models and local ASR server (local variant only) ---
if [ "$VARIANT" = "local" ]; then
    MODELS_DIR="$APP_PATH/Contents/Resources/Models"
    rm -rf "$MODELS_DIR"
    mkdir -p "$MODELS_DIR"

    # SenseVoice int8 model (~229MB)
    SHERPA_SV_MODEL="$HOME/Library/Application Support/Type4Me/models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17"
    if [ -d "$SHERPA_SV_MODEL" ]; then
        echo "Bundling sherpa-onnx SenseVoice int8 model..."
        cp -R "$SHERPA_SV_MODEL" "$MODELS_DIR/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17"
        echo "SenseVoice model bundled."
    else
        echo "ERROR: SenseVoice model not found at $SHERPA_SV_MODEL"
        exit 1
    fi

    # Silero VAD model (~0.6MB)
    SILERO_VAD_MODEL="$HOME/Library/Application Support/Type4Me/models/silero_vad"
    if [ -d "$SILERO_VAD_MODEL" ]; then
        echo "Bundling Silero VAD model..."
        cp -R "$SILERO_VAD_MODEL" "$MODELS_DIR/silero_vad"
        echo "Silero VAD model bundled."
    else
        echo "ERROR: Silero VAD model not found at $SILERO_VAD_MODEL"
        exit 1
    fi

    # Qwen3-ASR model (4-bit quantized, ~510MB)
    QWEN3_MODEL="${QWEN3_MODEL_PATH:-$HOME/.cache/modelscope/hub/models/Qwen/Qwen3-ASR-0.6B-4bit}"
    if [ -d "$QWEN3_MODEL" ]; then
        echo "Bundling Qwen3-ASR model (8-bit)..."
        mkdir -p "$MODELS_DIR/Qwen3-ASR"
        # Copy model weights (may be single file or sharded)
        cp "$QWEN3_MODEL"/model*.safetensors "$MODELS_DIR/Qwen3-ASR/" 2>/dev/null || true
        cp "$QWEN3_MODEL"/model.safetensors.index.json "$MODELS_DIR/Qwen3-ASR/" 2>/dev/null || true
        # Copy config and tokenizer files
        for f in config.json tokenizer_config.json vocab.json merges.txt \
                 generation_config.json preprocessor_config.json chat_template.json; do
            cp "$QWEN3_MODEL/$f" "$MODELS_DIR/Qwen3-ASR/" 2>/dev/null || true
        done
        echo "Qwen3-ASR model bundled."
    else
        echo "ERROR: Qwen3-ASR model not found at $QWEN3_MODEL"
        exit 1
    fi

    # qwen3-asr-server (PyInstaller dist)
    # Build automatically with MLX_METAL_JIT=ON for macOS 14+ compatibility.
    # Placed in Contents/Resources/ (not MacOS/) to avoid codesign treating
    # PyInstaller internals (.dist-info, python3.x dirs) as nested bundles.
    QWEN3_DIST="$PROJECT_DIR/qwen3-asr-server/dist/qwen3-asr-server"
    if [ "${SKIP_QWEN3_BUILD:-0}" != "1" ] && [ -f "$PROJECT_DIR/qwen3-asr-server/build.sh" ]; then
        echo "Building qwen3-asr-server (MLX JIT mode for macOS 14+ compat)..."
        bash "$PROJECT_DIR/qwen3-asr-server/build.sh"
    fi
    if [ -d "$QWEN3_DIST" ]; then
        echo "Bundling qwen3-asr-server..."
        rm -rf "$APP_PATH/Contents/Resources/qwen3-asr-server-dist" "$APP_PATH/Contents/MacOS/qwen3-asr-server"
        cp -R "$QWEN3_DIST" "$APP_PATH/Contents/Resources/qwen3-asr-server-dist"
        cat > "$APP_PATH/Contents/MacOS/qwen3-asr-server" << 'WRAPPER'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/../Resources/qwen3-asr-server-dist/qwen3-asr-server" "$@"
WRAPPER
        chmod +x "$APP_PATH/Contents/MacOS/qwen3-asr-server"
        # Remove .dist-info dirs that confuse codesign's bundle detection
        find "$APP_PATH/Contents/Resources/qwen3-asr-server-dist" -type d -name "*.dist-info" -exec rm -rf {} + 2>/dev/null || true
        # Keep mlx.metallib in the bundle.  Even in JIT mode (MLX_METAL_JIT=ON)
        # the small (~2-5MB) metallib is required for MLX initialization.
        # JIT mode ensures the metallib uses only core shaders compatible with
        # macOS 14+; additional kernels are compiled from embedded source at
        # runtime for the host's Metal version.
        find "$APP_PATH/Contents/Resources/qwen3-asr-server-dist" -type f \( -name "*.dylib" -o -name "*.so" -o -name "*.metallib" -o -perm +111 \) \
            -exec codesign --force --options runtime --timestamp --sign "${SIGNING_IDENTITY}" {} \; 2>/dev/null || true
        echo "qwen3-asr-server bundled and signed."
    else
        echo "WARNING: qwen3-asr-server dist not found at $QWEN3_DIST (Qwen3 calibration will be unavailable)"
    fi

    echo "Local variant: all models bundled."
else
    echo "Cloud variant: skipping model bundling."
fi

# Copy third-party licenses
cp "$PROJECT_DIR/Type4Me/Resources/THIRD_PARTY_LICENSES.txt" "$APP_PATH/Contents/Resources/" 2>/dev/null || true

# Sign the app bundle. Skip if already signed with the same identity to preserve
# Keychain ACLs and Accessibility TCC records across rebuilds.
NEEDS_SIGN=1
if codesign -dvv "$APP_PATH" 2>&1 | grep -q "Authority=${SIGNING_IDENTITY}"; then
    # Same identity, but binary may have changed. Check if signature is still valid.
    if codesign --verify --strict "$APP_PATH" 2>/dev/null; then
        echo "Signature valid with '${SIGNING_IDENTITY}', skipping re-sign."
        NEEDS_SIGN=0
    fi
fi

if [ "$NEEDS_SIGN" = "1" ]; then
    echo "Signing with '${SIGNING_IDENTITY}'..."

    # Sign frameworks and dylibs first (inside-out signing)
    find "$APP_PATH/Contents/Frameworks" \
        -type f \( -name "*.dylib" -o -name "*.so" -o -name "*.framework" \) \
        -exec codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" {} \; 2>/dev/null || true

    # Sign the wrapper script in Contents/MacOS
    Q3_WRAPPER="$APP_PATH/Contents/MacOS/qwen3-asr-server"
    if [ -f "$Q3_WRAPPER" ]; then
        codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$Q3_WRAPPER"
    fi

    # Sign the main app bundle with hardened runtime + entitlements
    CODESIGN_ARGS=(--force --options runtime --timestamp --sign "$SIGNING_IDENTITY")
    if [ -f "$ENTITLEMENTS" ]; then
        CODESIGN_ARGS+=(--entitlements "$ENTITLEMENTS")
    fi
    codesign "${CODESIGN_ARGS[@]}" "$APP_PATH" && echo "Signed." || echo "Signing skipped (no identity available)."
    codesign --verify --strict "$APP_PATH" && echo "Signature verified." || { echo "ERROR: Signature verification failed"; exit 1; }
fi

echo "Variant: $VARIANT | Arch: $ARCH"

# Remove quarantine flag that macOS adds to downloaded apps.
# This flag can silently prevent Accessibility permission from working.
xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true

echo "App bundle ready at $APP_PATH"
