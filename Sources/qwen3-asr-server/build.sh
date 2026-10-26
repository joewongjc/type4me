#!/bin/bash
# Build the qwen3-asr-server PyInstaller binary.
#
# MLX is compiled from source with MLX_METAL_JIT=ON so the resulting binary
# works on macOS 14+ (any Apple Silicon) regardless of which macOS version
# was used to build.  JIT mode embeds Metal kernel sources in libmlx.dylib
# and compiles them at runtime for the host's Metal version, avoiding the
# "metallib language version 4.0 not supported" crash on older systems.
#
# Usage:
#   bash qwen3-asr-server/build.sh          # full rebuild (venv + PyInstaller)
#   bash qwen3-asr-server/build.sh --quick  # skip venv setup, PyInstaller only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && /bin/pwd -P)"
cd "$SCRIPT_DIR"

QUICK=0
for arg in "$@"; do
    case "$arg" in
        --quick) QUICK=1 ;;
    esac
done

PYTHON="${PYTHON:-python3.12}"
VENV_DIR=".venv"
MIN_MACOS="14.0"

# --- venv + dependencies ---------------------------------------------------
if [ "$QUICK" = "0" ]; then
    echo "=== [qwen3-asr-server] Setting up venv ==="
    if [ ! -d "$VENV_DIR" ]; then
        $PYTHON -m venv "$VENV_DIR"
    fi
    source "$VENV_DIR/bin/activate"

    echo "=== [qwen3-asr-server] Installing MLX (JIT mode, target macOS $MIN_MACOS) ==="
    # Install MLX from source with JIT mode for backward compatibility.
    # This compiles Metal kernels at runtime, adapting to the host's Metal
    # version instead of shipping a pre-compiled metallib tied to one OS.
    #
    # Pin to a specific git tag instead of `pip install mlx --no-binary mlx`:
    # PyPI no longer ships an mlx source distribution (only wheels), so
    # --no-binary fails with "No matching distribution found for mlx".
    # Pulling directly from the GitHub tag bypasses that and is decoupled
    # from PyPI's distribution policy. v0.31.0 matches the version shipped
    # in v1.9.2's local DMG (verified: identical 2,855,435-byte metallib).
    CMAKE_ARGS="-DMLX_METAL_JIT=ON -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN_MACOS" \
        pip install "git+https://github.com/ml-explore/mlx.git@v0.31.0" --no-deps

    echo "=== [qwen3-asr-server] Installing remaining dependencies ==="
    pip install -r requirements.txt
else
    source "$VENV_DIR/bin/activate"
fi

# --- PyInstaller build ------------------------------------------------------
echo "=== [qwen3-asr-server] Building with PyInstaller ==="
pip install pyinstaller 2>/dev/null

pyinstaller --clean --noconfirm qwen3-asr-server.spec

DIST="$SCRIPT_DIR/dist/qwen3-asr-server"
if [ -d "$DIST" ]; then
    # Report metallib size to verify JIT mode is active (should be ~2-5MB, not ~125MB)
    METALLIB=$(find "$DIST" -name "mlx.metallib" 2>/dev/null | head -1)
    if [ -n "$METALLIB" ]; then
        SIZE=$(du -h "$METALLIB" | cut -f1)
        echo "[qwen3-asr-server] mlx.metallib size: $SIZE (JIT mode: expect ~2-5MB, not ~125MB)"
        # PyInstaller puts libmlx.dylib in _internal/ but keeps mlx.metallib in
        # _internal/mlx/lib/.  MLX resolves the metallib relative to its dylib via
        # dladdr, so it looks in _internal/ and fails.  Copy metallib next to the
        # top-level dylib so MLX can find it at runtime.
        INTERNAL="$DIST/_internal"
        if [ -f "$INTERNAL/libmlx.dylib" ] && [ ! -f "$INTERNAL/mlx.metallib" ]; then
            cp "$METALLIB" "$INTERNAL/mlx.metallib"
            echo "[qwen3-asr-server] Copied mlx.metallib next to libmlx.dylib for runtime discovery"
        fi
    fi
    TOTAL=$(du -sh "$DIST" | cut -f1)
    echo "=== [qwen3-asr-server] Build complete ($TOTAL) ==="
else
    echo "ERROR: qwen3-asr-server PyInstaller dist not found"
    exit 1
fi
