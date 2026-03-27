#!/bin/bash
# =============================================================================
# build-sherpa.sh — Build sherpa-onnx.xcframework for macOS (arm64 + x86_64)
# =============================================================================
#
# Prerequisites:
#   - Xcode command line tools
#   - CMake (brew install cmake)
#   - Git
#
# Usage:
#   ./scripts/build-sherpa.sh
#
# Output:
#   Frameworks/sherpa-onnx.xcframework
#   Type4Me/Bridge/SherpaOnnxBridge.swift  (copied from sherpa-onnx)
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/.build-sherpa"
FRAMEWORK_DIR="$PROJECT_ROOT/Frameworks"
BRIDGE_DIR="$PROJECT_ROOT/Type4Me/Bridge"

SHERPA_REPO="https://github.com/k2-fsa/sherpa-onnx.git"
SHERPA_TAG="v1.12.33"  # Update to latest stable release

echo "========================================="
echo "Building sherpa-onnx.xcframework"
echo "Tag: $SHERPA_TAG"
echo "========================================="

# 1. Clone or update sherpa-onnx
if [ -d "$BUILD_DIR/sherpa-onnx" ]; then
    echo "→ Updating existing sherpa-onnx checkout..."
    cd "$BUILD_DIR/sherpa-onnx"
    git fetch origin
    git checkout "$SHERPA_TAG"
else
    echo "→ Cloning sherpa-onnx..."
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"
    git clone --depth 1 --branch "$SHERPA_TAG" "$SHERPA_REPO"
fi

# 2. Build for macOS (universal: arm64 + x86_64)
cd "$BUILD_DIR/sherpa-onnx"

echo "→ Running macOS build script..."
if [ -f "build-swift-macos.sh" ]; then
    bash build-swift-macos.sh
elif [ -f "scripts/build-swift-macos.sh" ]; then
    bash scripts/build-swift-macos.sh
else
    echo "ERROR: Cannot find build-swift-macos.sh in sherpa-onnx repo"
    echo "Manual build steps:"
    echo "  1. cd $BUILD_DIR/sherpa-onnx"
    echo "  2. mkdir build-swift-macos && cd build-swift-macos"
    echo "  3. cmake -DCMAKE_OSX_ARCHITECTURES='arm64;x86_64' \\"
    echo "       -DCMAKE_BUILD_TYPE=Release \\"
    echo "       -DSHERPA_ONNX_ENABLE_C_API=ON \\"
    echo "       -DBUILD_SHARED_LIBS=OFF .."
    echo "  4. make -j$(sysctl -n hw.ncpu)"
    echo "  5. Create xcframework from the static libs"
    exit 1
fi

# 2.5 Merge libonnxruntime.a into libsherpa-onnx.a (upstream script omits it)
INSTALL_LIB="$BUILD_DIR/sherpa-onnx/build-swift-macos/install/lib"
if [ -f "$INSTALL_LIB/libonnxruntime.a" ]; then
    echo "→ Merging libonnxruntime.a into libsherpa-onnx.a..."
    libtool -static -o "$INSTALL_LIB/libsherpa-onnx-merged.a" \
        "$INSTALL_LIB/libsherpa-onnx.a" \
        "$INSTALL_LIB/libonnxruntime.a"
    mv "$INSTALL_LIB/libsherpa-onnx-merged.a" "$INSTALL_LIB/libsherpa-onnx.a"
    echo "→ Merged successfully"

    # Rebuild xcframework with the merged lib
    echo "→ Rebuilding xcframework..."
    rm -rf "$BUILD_DIR/sherpa-onnx/build-swift-macos/sherpa-onnx.xcframework"
    xcodebuild -create-xcframework \
        -library "$INSTALL_LIB/libsherpa-onnx.a" \
        -headers "$INSTALL_LIB/../include" \
        -output "$BUILD_DIR/sherpa-onnx/build-swift-macos/sherpa-onnx.xcframework"
    echo "→ xcframework rebuilt with onnxruntime"
fi

# 3. Find and copy the xcframework
echo "→ Looking for xcframework..."
XCFW=$(find "$BUILD_DIR" -name "sherpa-onnx.xcframework" -type d | head -1)

if [ -z "$XCFW" ]; then
    echo "ERROR: sherpa-onnx.xcframework not found after build"
    exit 1
fi

echo "→ Found: $XCFW"
mkdir -p "$FRAMEWORK_DIR"
rm -rf "$FRAMEWORK_DIR/sherpa-onnx.xcframework"
cp -R "$XCFW" "$FRAMEWORK_DIR/"
echo "→ Copied to $FRAMEWORK_DIR/sherpa-onnx.xcframework"

# 3.5 Generate module.modulemap so Swift's canImport(SherpaOnnxLib) works
HEADERS_DIR=$(find "$FRAMEWORK_DIR/sherpa-onnx.xcframework" -type d -name "Headers" | head -1)
if [ -n "$HEADERS_DIR" ]; then
    # Find the C API header relative to Headers dir
    C_API_HEADER=$(find "$HEADERS_DIR" -name "c-api.h" -type f | head -1)
    if [ -n "$C_API_HEADER" ]; then
        REL_HEADER=$(python3 -c "import os; print(os.path.relpath('$C_API_HEADER', '$HEADERS_DIR'))")
        cat > "$HEADERS_DIR/module.modulemap" <<MODULEMAP
module SherpaOnnxLib {
    header "$REL_HEADER"
    export *
}
MODULEMAP
        echo "→ Generated module.modulemap at $HEADERS_DIR/module.modulemap"
    else
        echo "WARNING: c-api.h not found, canImport(SherpaOnnxLib) may not work"
    fi
fi

# 4. Copy the Swift API wrapper
echo "→ Checking Swift API wrapper..."
if [ -f "$BRIDGE_DIR/SherpaOnnxBridge.swift" ]; then
    echo "→ SherpaOnnxBridge.swift already exists, skipping copy (preserving project customizations)"
else
    SWIFT_API="$BUILD_DIR/sherpa-onnx/swift-api-examples/SherpaOnnx.swift"
    if [ -f "$SWIFT_API" ]; then
        cp "$SWIFT_API" "$BRIDGE_DIR/SherpaOnnxBridge.swift"
        echo "→ Copied SherpaOnnx.swift → Type4Me/Bridge/SherpaOnnxBridge.swift"
    else
        echo "WARNING: SherpaOnnx.swift not found at $SWIFT_API"
    fi
fi

# 5. Copy C header (if needed for bridging)
HEADER=$(find "$BUILD_DIR" -name "sherpa-onnx-c-api.h" -type f | head -1)
if [ -n "$HEADER" ]; then
    cp "$HEADER" "$BRIDGE_DIR/sherpa-onnx-c-api.h"
    echo "→ Copied C header → Type4Me/Bridge/sherpa-onnx-c-api.h"
fi

echo ""
echo "========================================="
echo "Done! xcframework is at:"
echo "  $FRAMEWORK_DIR/sherpa-onnx.xcframework"
echo ""
echo "Next steps:"
echo "  1. swift build   (should compile with SherpaOnnx support)"
echo "  2. Run the app and select '本地识别 (Paraformer)' in Settings"
echo "  3. Download models when prompted"
echo "========================================="
