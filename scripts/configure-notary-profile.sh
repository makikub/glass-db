#!/usr/bin/env bash
set -euo pipefail

profile="${GLASSDB_NOTARY_PROFILE:-glassdb-notary}"

if [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
  xcrun notarytool store-credentials "$profile" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD"
  echo "Configured notary profile $profile"
  exit 0
fi

if [[ -n "${APP_STORE_CONNECT_API_KEY_ID:-}" && -n "${APP_STORE_CONNECT_API_ISSUER_ID:-}" && -n "${APP_STORE_CONNECT_API_KEY_BASE64:-}" ]]; then
  key_path="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/AuthKey_${APP_STORE_CONNECT_API_KEY_ID}.p8"
  printf '%s' "$APP_STORE_CONNECT_API_KEY_BASE64" | base64 --decode > "$key_path"
  xcrun notarytool store-credentials "$profile" \
    --key "$key_path" \
    --key-id "$APP_STORE_CONNECT_API_KEY_ID" \
    --issuer "$APP_STORE_CONNECT_API_ISSUER_ID"
  echo "Configured notary profile $profile"
  exit 0
fi

echo "Notary credentials are required. Provide Apple ID secrets or App Store Connect API key secrets." >&2
exit 64
