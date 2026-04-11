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

# Update Keychain partition lists so Type4Me can access its stored credentials
# without prompting after re-sign. Asks for Keychain password once.
NEW_CDHASH=$(codesign -dvvv "$APP_PATH" 2>&1 | grep "^CDHash=" | cut -d= -f2)
TEAM_ID=$(codesign -dvvv "$APP_PATH" 2>&1 | grep "^TeamIdentifier=" | cut -d= -f2)
if [ -n "$NEW_CDHASH" ]; then
    # Collect all Type4Me keychain accounts: parse acct+svce pairs from dump.
    # Entry format: label (0x00000007) appears first, then acct, then svce.
    T4M_ITEMS=()
    while IFS= read -r line; do
        T4M_ITEMS+=("$line")
    done < <(security dump-keychain -a 2>/dev/null | awk '
        /"acct"/ { gsub(/.*="/, ""); gsub(/"$/, ""); acct=$0 }
        /"svce".*"com\.type4me\.(grouped|scalar)"/ { gsub(/.*="/, ""); gsub(/"$/, ""); if(acct) print $0 "|" acct; acct="" }
    ')

    if [ ${#T4M_ITEMS[@]} -gt 0 ]; then
        # Check if partition list already has current CDHash (sample first item)
        FIRST_ACCT="${T4M_ITEMS[0]#*|}"
        NEEDS_UPDATE=1
        if security dump-keychain -a 2>/dev/null | grep -A30 "\"$FIRST_ACCT\"" | grep -q "$NEW_CDHASH" 2>/dev/null; then
            NEEDS_UPDATE=0
        fi

        if [ "$NEEDS_UPDATE" = "1" ]; then
            echo "Updating Keychain partition lists (${#T4M_ITEMS[@]} items)..."
            KC_PASS_FILE="$HOME/.type4me-kc-pass"
            if [ -n "${KC_PASS:-}" ]; then
                : # already set via env var
            elif [ -f "$KC_PASS_FILE" ]; then
                KC_PASS="$(cat "$KC_PASS_FILE")"
            else
                read -s -p "Keychain password (save to $KC_PASS_FILE to skip next time): " KC_PASS
                echo
            fi
            UPDATED=0
            for item in "${T4M_ITEMS[@]}"; do
                svc="${item%%|*}"
                acct="${item#*|}"
                if security set-generic-password-partition-list \
                    -s "$svc" -a "$acct" \
                    -S "apple-tool:,apple:,teamid:${TEAM_ID},cdhash:$NEW_CDHASH" \
                    -k "$KC_PASS" \
                    ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then
                    UPDATED=$((UPDATED + 1))
                fi
            done
            echo "Keychain: $UPDATED/${#T4M_ITEMS[@]} items updated."
        fi
    fi
fi

if [ "$LAUNCH_APP" = "1" ]; then
    echo "Launching via GUI session (no shell env vars)..."
    launchctl asuser "$(id -u)" /usr/bin/open "$APP_PATH"
else
    echo "Skipping launch because LAUNCH_APP=$LAUNCH_APP"
fi

echo "Done."
