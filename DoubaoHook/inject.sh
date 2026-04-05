#!/bin/bash
# Inject DoubaoHook into DoubaoIme with proper entitlements preservation
set -e

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
DOUBAO_APP="/Library/Input Methods/DoubaoIme.app"
DOUBAO_BIN="$DOUBAO_APP/Contents/MacOS/DoubaoIme"
ORIGINAL="/tmp/DoubaoIme.original"
ENTITLEMENTS="/tmp/doubao-entitlements.plist"
DYLIB="$HOOK_DIR/DoubaoHook.dylib"

echo "Building hook..."
cd "$HOOK_DIR"
clang -dynamiclib -framework Foundation -lobjc -arch arm64 -arch x86_64 \
    -o DoubaoHook.dylib DoubaoHook.m -install_name @rpath/DoubaoHook.dylib

echo "Stopping DoubaoIme..."
sudo killall DoubaoIme 2>/dev/null || true
sleep 1

echo "Restoring original binary..."
sudo cp "$ORIGINAL" "$DOUBAO_BIN"

echo "Copying dylib..."
sudo cp "$DYLIB" "$DOUBAO_APP/Contents/Frameworks/DoubaoHook.dylib"

echo "Injecting load command..."
sudo insert_dylib --inplace --all-yes "@rpath/DoubaoHook.dylib" "$DOUBAO_BIN" 2>&1 | tail -1

echo "Re-signing with entitlements..."
sudo codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$DOUBAO_APP"

echo "Starting DoubaoIme..."
sleep 1
open "$DOUBAO_APP"
sleep 3

echo "Verifying..."
if pgrep -x DoubaoIme > /dev/null; then
    echo "✓ DoubaoIme running (pid $(pgrep -x DoubaoIme))"
    tail -2 ~/Library/Application\ Support/Type4Me/doubao-hook.log
else
    echo "✗ DoubaoIme not running!"
fi
