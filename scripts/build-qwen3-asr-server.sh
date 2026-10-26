#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SERVER_DIR="$PROJECT_DIR/Modules/qwen3-asr-server"

echo "=== Building qwen3-asr-server standalone binary ==="

cd "$SERVER_DIR"

# Ensure venv exists (use python3.14 for MLX compatibility)
if [ ! -d .venv ]; then
    echo "Creating venv..."
    /opt/homebrew/bin/python3.14 -m venv .venv
fi

source .venv/bin/activate

# Install dependencies + pyinstaller
echo "Installing dependencies..."
pip install -q -r requirements.txt
pip install -q pyinstaller

# Clean previous build
rm -rf build dist

# Build standalone binary
echo "Running PyInstaller..."
pyinstaller \
    --onedir \
    --name qwen3-asr-server \
    --hidden-import=mlx \
    --hidden-import=mlx.core \
    --hidden-import=mlx.nn \
    --hidden-import=mlx_qwen3_asr \
    --hidden-import=llama_cpp \
    --hidden-import=numpy \
    --hidden-import=soundfile \
    --hidden-import=uvicorn \
    --hidden-import=uvicorn.logging \
    --hidden-import=uvicorn.loops \
    --hidden-import=uvicorn.loops.auto \
    --hidden-import=uvicorn.protocols \
    --hidden-import=uvicorn.protocols.http \
    --hidden-import=uvicorn.protocols.http.auto \
    --hidden-import=uvicorn.protocols.websockets \
    --hidden-import=uvicorn.protocols.websockets.auto \
    --hidden-import=uvicorn.lifespan \
    --hidden-import=uvicorn.lifespan.on \
    --hidden-import=fastapi \
    --hidden-import=starlette \
    --hidden-import=starlette.routing \
    --hidden-import=starlette.middleware \
    --collect-all mlx \
    --collect-all mlx_qwen3_asr \
    --collect-all llama_cpp \
    --noconfirm \
    server.py

echo ""
echo "=== Signing binaries for macOS Gatekeeper ==="
DIST="$SERVER_DIR/dist/qwen3-asr-server"
# Ad-hoc sign all executables and dylibs to avoid Gatekeeper blocking
find "$DIST" -type f \( -name "*.dylib" -o -name "*.so" -o -name "*.metallib" -o -perm +111 \) -exec codesign --force --sign - {} \; 2>/dev/null || true
codesign --force --sign - "$DIST/qwen3-asr-server" 2>/dev/null || true
echo "Signing complete."

echo ""
echo "=== Build complete ==="
echo "Output: $DIST"
du -sh "$DIST" 2>/dev/null || true
echo ""
echo "Test with:"
echo "  $DIST/qwen3-asr-server --model-path <path-to-qwen3-asr-model> --port 8766"
