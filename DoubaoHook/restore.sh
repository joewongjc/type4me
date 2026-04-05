#!/bin/bash
# One-click restore DoubaoIme to original state
set -e
echo "Stopping DoubaoIme..."
sudo killall DoubaoIme DoubaoImeSettings 2>/dev/null || true
sleep 1
echo "Restoring original binary..."
sudo cp /tmp/DoubaoIme.original "/Library/Input Methods/DoubaoIme.app/Contents/MacOS/DoubaoIme"
sudo rm -f "/Library/Input Methods/DoubaoIme.app/Contents/Frameworks/DoubaoHook.dylib"
echo "Re-signing..."
sudo codesign --force --deep --sign - "/Library/Input Methods/DoubaoIme.app"
echo "Starting DoubaoIme..."
open "/Library/Input Methods/DoubaoIme.app"
sleep 2
echo "Done. DoubaoIme restored."
