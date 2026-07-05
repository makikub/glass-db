#!/usr/bin/env bash
set -euo pipefail

keychain_name="${GLASSDB_CI_KEYCHAIN_NAME:-glassdb-release.keychain-db}"
keychain_password="${GLASSDB_CI_KEYCHAIN_PASSWORD:-$(uuidgen)}"
certificate_base64="${DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64:-}"
certificate_password="${DEVELOPER_ID_APPLICATION_CERTIFICATE_PASSWORD:-}"
certificate_path="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/glassdb-developer-id.p12"

if [[ -z "$certificate_base64" ]]; then
  echo "DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64 is required." >&2
  exit 64
fi

security create-keychain -p "$keychain_password" "$keychain_name"
security set-keychain-settings -lut 21600 "$keychain_name"
security unlock-keychain -p "$keychain_password" "$keychain_name"

printf '%s' "$certificate_base64" | base64 --decode > "$certificate_path"
security import "$certificate_path" \
  -k "$keychain_name" \
  -P "$certificate_password" \
  -T /usr/bin/codesign \
  -T /usr/bin/security

security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "$keychain_password" \
  "$keychain_name" >/dev/null

security list-keychains -d user -s "$keychain_name" $(security list-keychains -d user | tr -d '"')
security default-keychain -d user -s "$keychain_name"

echo "Imported Developer ID certificate into $keychain_name"
