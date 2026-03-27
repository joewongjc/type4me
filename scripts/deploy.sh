#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && /bin/pwd -P)"
APP_PATH="${APP_PATH:-/Applications/Type4Me.app}"
APP_NAME="Type4Me"
LAUNCH_APP="${LAUNCH_APP:-1}"

echo "Stopping Type4Me..."
osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
sleep 1

APP_PATH="$APP_PATH" bash "$SCRIPT_DIR/package-app.sh"

if [ "$LAUNCH_APP" = "1" ]; then
    echo "Launching via GUI session (no shell env vars)..."
    launchctl asuser "$(id -u)" /usr/bin/open "$APP_PATH"
else
    echo "Skipping launch because LAUNCH_APP=$LAUNCH_APP"
fi

echo "Done."
