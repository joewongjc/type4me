#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && /bin/pwd -P)"

if ! security find-identity -v -p codesigning 2>/dev/null | grep -Eq '"(Developer ID Application|Apple Development|Type4Me Dev)'; then
    cat <<'MSG'
WARNING: No stable code-signing identity was found.

macOS permissions and Keychain access are more likely to prompt repeatedly when
the app is ad-hoc signed. For smoother local development, create a local
"Type4Me Dev" code-signing certificate in Keychain Access, or sign in to Xcode
so an "Apple Development" identity is available.

Continuing with the best available signing mode...

MSG
fi

APP_NAME="${APP_NAME:-Type4Me Dev}" \
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.type4me.dev}" \
URL_SCHEME="${URL_SCHEME:-type4me-dev}" \
APP_PATH="${APP_PATH:-/Applications/Type4Me Dev.app}" \
ARCH="${ARCH:-arm64}" \
VARIANT="${VARIANT:-cloud}" \
bash "$SCRIPT_DIR/deploy.sh"
