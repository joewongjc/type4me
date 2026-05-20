#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && /bin/pwd -P)"
APP_PATH="${APP_PATH:-/Applications/Type4Me.app}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.type4me.localfixed}"
APP_VERSION="${APP_VERSION:-1.9.3-local}"
APP_BUILD="${APP_BUILD:-2}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Type4Me Local Dev}"
ARCH="${ARCH:-arm64}"
SKIP_QWEN3_BUILD="${SKIP_QWEN3_BUILD:-1}"

DEFAULT_BUNDLED_QWEN3="/Applications/Type4Me.app/Contents/Resources/Models/Qwen3-ASR"
DEFAULT_CACHE_QWEN3="$HOME/.cache/modelscope/hub/models/Qwen/Qwen3-ASR-0.6B-4bit"
if [ -n "${QWEN3_MODEL_PATH:-}" ]; then
    :
elif [ -d "$DEFAULT_BUNDLED_QWEN3" ]; then
    QWEN3_MODEL_PATH="$DEFAULT_BUNDLED_QWEN3"
elif [ -d "$DEFAULT_CACHE_QWEN3" ]; then
    QWEN3_MODEL_PATH="$DEFAULT_CACHE_QWEN3"
else
    echo "ERROR: Qwen3-ASR model not found. Set QWEN3_MODEL_PATH=/path/to/Qwen3-ASR" >&2
    exit 1
fi

if [ ! -d "$PROJECT_DIR/Frameworks/sherpa-onnx.xcframework" ]; then
    echo "sherpa-onnx.xcframework not found; building it first..."
    bash "$PROJECT_DIR/scripts/build-sherpa.sh"
fi

if [ "$SKIP_QWEN3_BUILD" != "1" ] || [ ! -d "$PROJECT_DIR/qwen3-asr-server/dist/qwen3-asr-server" ]; then
    bash "$PROJECT_DIR/qwen3-asr-server/build.sh"
fi

osascript -e 'quit app "Type4Me"' 2>/dev/null || true
pkill -f '/Applications/Type4Me.app/Contents/MacOS/Type4Me' 2>/dev/null || true
pkill -f 'qwen3-asr-server' 2>/dev/null || true
sleep 2

APP_PATH="$APP_PATH" \
APP_BUNDLE_ID="$APP_BUNDLE_ID" \
APP_VERSION="$APP_VERSION" \
APP_BUILD="$APP_BUILD" \
VARIANT=local \
ARCH="$ARCH" \
CODESIGN_IDENTITY="$CODESIGN_IDENTITY" \
SKIP_QWEN3_BUILD="$SKIP_QWEN3_BUILD" \
QWEN3_MODEL_PATH="$QWEN3_MODEL_PATH" \
bash "$PROJECT_DIR/scripts/package-app.sh"

xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true

MODEL="$APP_PATH/Contents/Resources/Models/Qwen3-ASR"
HOTWORDS="$HOME/Library/Application Support/Type4Me/hotwords.txt"
LOG="${TMPDIR:-/tmp}/type4me-qwen3-smoke.log"
rm -f "$LOG"
"$APP_PATH/Contents/MacOS/qwen3-asr-server" --model-path "$MODEL" --port 0 --hotwords-file "$HOTWORDS" >"$LOG" 2>&1 &
PID=$!
for _ in {1..60}; do
    if grep -q "PORT:" "$LOG" 2>/dev/null; then
        break
    fi
    if grep -qE "ERROR|Traceback|Failed" "$LOG" 2>/dev/null; then
        cat "$LOG"
        kill "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
        exit 1
    fi
    sleep 1
done

if ! grep -q "PORT:" "$LOG" 2>/dev/null; then
    cat "$LOG" 2>/dev/null || true
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    echo "ERROR: Qwen3-ASR smoke test timed out" >&2
    exit 1
fi

cat "$LOG"
kill "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true

defaults write "$APP_BUNDLE_ID" tf_qwen3FinalEnabled -bool true
open -n "$APP_PATH"
echo "Local Type4Me app installed at $APP_PATH"
