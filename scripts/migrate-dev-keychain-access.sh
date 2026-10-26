#!/bin/bash
set -euo pipefail

APP_PATH="${1:-/Applications/Type4Me Dev.app}"
LOGIN_KEYCHAIN="${LOGIN_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && /bin/pwd -P)"
BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw "$APP_PATH/Contents/Info.plist")
TEAM_ID=$(codesign -dvvv "$APP_PATH" 2>&1 | sed -n 's/^TeamIdentifier=//p')

if [ "$BUNDLE_ID" != "com.type4me.dev" ]; then
    exit 0
fi
if [ -z "$TEAM_ID" ] || [ "$TEAM_ID" = "not set" ]; then
    echo "WARNING: Dev signer has no Apple Team ID; Keychain access cannot persist securely across binary changes." >&2
    exit 0
fi

MARKER_DIR="$HOME/Library/Application Support/Type4Me Dev"
MARKER_PATH="$MARKER_DIR/keychain-team-$TEAM_ID-v2.migrated"

ITEMS=()
add_item_if_present() {
    local service="$1"
    local account="$2"
    if security find-generic-password \
        -s "$service" -a "$account" "$LOGIN_KEYCHAIN" >/dev/null 2>&1; then
        ITEMS+=("$service|$account")
    fi
}

# Every provider with saved non-secret configuration has a matching top-level
# key in credentials.json. Reading attributes with find-generic-password does
# not request or expose the stored secret.
CREDENTIALS_FILE="$HOME/Library/Application Support/Type4Me/credentials.json"
if [ -f "$CREDENTIALS_FILE" ]; then
    SAVED_ACCOUNTS=$(
        plutil -p "$CREDENTIALS_FILE" 2>/dev/null \
            | sed -n 's/^  "\(tf_\(asr\|llm\)_[^"]*\)" => {$/\1/p' \
            || true
    )
else
    SAVED_ACCOUNTS=""
fi

# Include every provider declared by the current source tree as candidates.
# This also finds secure-only configurations that have no plaintext entry in
# credentials.json. Nonexistent candidates are discarded without prompting.
DECLARED_ACCOUNTS=$(
    {
        sed -n 's/^[[:space:]]*case \([A-Za-z0-9_]*\)$/tf_asr_\1/p' \
            "$PROJECT_DIR/Sources/Type4Me/ASR/ASRProvider.swift"
        sed -n 's/^[[:space:]]*case \([A-Za-z0-9_]*\)$/tf_llm_\1/p' \
            "$PROJECT_DIR/Sources/Type4Me/LLM/LLMProvider.swift"
    } 2>/dev/null || true
)

while IFS= read -r account; do
    [ -n "$account" ] && add_item_if_present "com.type4me.grouped" "$account"
done < <(printf '%s\n%s\n' "$SAVED_ACCOUNTS" "$DECLARED_ACCOUNTS" | sort -u)

# Legacy scalar secrets are no longer normally created, but include any that
# still exist so older installations keep working without prompts.
for account in \
    tf_appKey tf_accessKey tf_resourceId \
    tf_llmApiKey tf_llmModel tf_llmEndpointId tf_llmBaseURL
do
    add_item_if_present "com.type4me.scalar" "$account"
done

credential_fingerprint() {
    local item service account created
    for item in "${ITEMS[@]}"; do
        service="${item%%|*}"
        account="${item#*|}"
        created=$(security find-generic-password \
            -s "$service" -a "$account" "$LOGIN_KEYCHAIN" 2>&1 \
            | sed -n 's/.*"cdat"<timedate>=[^ ]*  "\([0-9]*Z\).*/\1/p' \
            | head -1)
        printf '%s|%s|%s\n' "$service" "$account" "$created"
    done | shasum -a 256 | awk '{ print $1 }'
}

if [ ${#ITEMS[@]} -eq 0 ]; then
    echo "No existing Type4Me Keychain items need migration."
    mkdir -p "$MARKER_DIR"
    printf '%s\n' "empty" > "$MARKER_PATH"
    exit 0
fi

CURRENT_FINGERPRINT=$(credential_fingerprint)
if [ -f "$MARKER_PATH" ] \
    && [ "$(cat "$MARKER_PATH")" = "$CURRENT_FINGERPRINT" ] \
    && [ "${FORCE_KEYCHAIN_ACL_MIGRATION:-0}" != "1" ]; then
    echo "Keychain access already migrated for team $TEAM_ID."
    exit 0
fi

request_keychain_password() {
    if [ -n "${KC_PASS:-}" ]; then
        printf '%s' "$KC_PASS"
        return
    fi
    local value
    if launchctl print "gui/$(id -u)" >/dev/null 2>&1; then
        value=$(osascript <<'APPLESCRIPT'
tell application "System Events"
    activate
    set response to display dialog "Type4Me 需要登录钥匙串密码，将现有 API 凭据授权给稳定的 Apple Development Team。此操作只执行一次，密码不会保存。" default answer "" with hidden answer buttons {"取消", "迁移"} default button "迁移" cancel button "取消" with title "迁移 Type4Me Dev 钥匙串权限"
    return text returned of response
end tell
APPLESCRIPT
        ) || return 1
        printf '%s' "$value"
        return
    fi
    if [ -t 0 ]; then
        read -r -s -p "Login Keychain password for one-time Type4Me ACL migration: " value
        echo >&2
        printf '%s' "$value"
        return
    fi
    return 1
}

KEYCHAIN_PASSWORD="$(request_keychain_password)"
cleanup() {
    unset KEYCHAIN_PASSWORD
}
trap cleanup EXIT
if [ -z "$KEYCHAIN_PASSWORD" ] \
    || ! security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$LOGIN_KEYCHAIN"; then
    echo "ERROR: Could not unlock the Login Keychain; ACL migration was not completed." >&2
    exit 1
fi

PARTITIONS=("apple-tool:" "apple:" "teamid:$TEAM_ID")
PRODUCTION_TEAM_ID=""
if [ -d "/Applications/Type4Me.app" ]; then
    PRODUCTION_TEAM_ID=$(codesign -dvvv "/Applications/Type4Me.app" 2>&1 \
        | sed -n 's/^TeamIdentifier=//p' || true)
fi
if [ -n "$PRODUCTION_TEAM_ID" ] && [ "$PRODUCTION_TEAM_ID" != "not set" ] \
    && [ "$PRODUCTION_TEAM_ID" != "$TEAM_ID" ]; then
    PARTITIONS+=("teamid:$PRODUCTION_TEAM_ID")
fi
PARTITION_LIST=$(IFS=,; printf '%s' "${PARTITIONS[*]}")

UPDATED=0
for item in "${ITEMS[@]}"; do
    service="${item%%|*}"
    account="${item#*|}"
    if security set-generic-password-partition-list \
        -s "$service" -a "$account" \
        -S "$PARTITION_LIST" \
        -k "$KEYCHAIN_PASSWORD" \
        "$LOGIN_KEYCHAIN" >/dev/null 2>&1; then
        UPDATED=$((UPDATED + 1))
    fi
done
if [ "$UPDATED" -ne "${#ITEMS[@]}" ]; then
    echo "ERROR: Keychain ACL migration updated $UPDATED/${#ITEMS[@]} items." >&2
    exit 1
fi

mkdir -p "$MARKER_DIR"
printf '%s\n' "$CURRENT_FINGERPRINT" > "$MARKER_PATH"
echo "Keychain ACL migration complete: $UPDATED items now trust team $TEAM_ID."
