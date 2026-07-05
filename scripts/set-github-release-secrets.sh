#!/usr/bin/env bash
set -euo pipefail

repo="${GLASSDB_GITHUB_REPO:-makikub/glass-db}"
certificate_path="${DEVELOPER_ID_APPLICATION_CERTIFICATE_PATH:-}"
certificate_password="${DEVELOPER_ID_APPLICATION_CERTIFICATE_PASSWORD:-}"
codesign_identity="${DEVELOPER_ID_APPLICATION_IDENTITY:-}"
sparkle_private_key="${SPARKLE_ED_PRIVATE_KEY:-}"
sparkle_private_key_file="${SPARKLE_ED_KEY_FILE:-}"

usage() {
  cat >&2 <<'USAGE'
Usage:
  DEVELOPER_ID_APPLICATION_CERTIFICATE_PATH=/path/to/cert.p12 \
  DEVELOPER_ID_APPLICATION_CERTIFICATE_PASSWORD=... \
  DEVELOPER_ID_APPLICATION_IDENTITY="Developer ID Application: ..." \
  SPARKLE_ED_KEY_FILE=/path/to/sparkle-private-key \
  APPLE_ID=... APPLE_TEAM_ID=... APPLE_APP_SPECIFIC_PASSWORD=... \
  scripts/set-github-release-secrets.sh

Alternative notary credentials:
  APP_STORE_CONNECT_API_KEY_ID=... \
  APP_STORE_CONNECT_API_ISSUER_ID=... \
  APP_STORE_CONNECT_API_KEY_PATH=/path/to/AuthKey_XXXX.p8 \
  scripts/set-github-release-secrets.sh

Set GLASSDB_GITHUB_REPO to override the target repository.
USAGE
}

set_secret() {
  local name="$1"
  local value="$2"
  if [[ -z "$value" ]]; then
    echo "missing: $name" >&2
    return 1
  fi
  gh secret set "$name" --repo "$repo" --body "$value" >/dev/null
  echo "set: $name"
}

base64_one_line() {
  base64 < "$1" | tr -d '\n'
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

command -v gh >/dev/null || { echo "gh is required." >&2; exit 69; }
gh auth status >/dev/null

if [[ -z "$certificate_path" || ! -f "$certificate_path" ]]; then
  echo "DEVELOPER_ID_APPLICATION_CERTIFICATE_PATH must point to a .p12 file." >&2
  usage
  exit 64
fi

if [[ -z "$codesign_identity" ]]; then
  codesign_identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -n 1)"
fi

if [[ -z "$sparkle_private_key" && -n "$sparkle_private_key_file" ]]; then
  if [[ ! -f "$sparkle_private_key_file" ]]; then
    echo "SPARKLE_ED_KEY_FILE does not exist: $sparkle_private_key_file" >&2
    exit 66
  fi
  sparkle_private_key="$(tr -d '[:space:]' < "$sparkle_private_key_file")"
fi

missing=0
set_secret DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64 "$(base64_one_line "$certificate_path")" || missing=1
set_secret DEVELOPER_ID_APPLICATION_CERTIFICATE_PASSWORD "$certificate_password" || missing=1
set_secret DEVELOPER_ID_APPLICATION_IDENTITY "$codesign_identity" || missing=1
set_secret SPARKLE_ED_PRIVATE_KEY "$sparkle_private_key" || missing=1

if [[ -n "${APPLE_ID:-}" || -n "${APPLE_TEAM_ID:-}" || -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
  set_secret APPLE_ID "${APPLE_ID:-}" || missing=1
  set_secret APPLE_TEAM_ID "${APPLE_TEAM_ID:-}" || missing=1
  set_secret APPLE_APP_SPECIFIC_PASSWORD "${APPLE_APP_SPECIFIC_PASSWORD:-}" || missing=1
elif [[ -n "${APP_STORE_CONNECT_API_KEY_ID:-}" || -n "${APP_STORE_CONNECT_API_ISSUER_ID:-}" || -n "${APP_STORE_CONNECT_API_KEY_PATH:-}" ]]; then
  if [[ -z "${APP_STORE_CONNECT_API_KEY_PATH:-}" || ! -f "${APP_STORE_CONNECT_API_KEY_PATH:-}" ]]; then
    echo "APP_STORE_CONNECT_API_KEY_PATH must point to the .p8 key file." >&2
    missing=1
  else
    set_secret APP_STORE_CONNECT_API_KEY_ID "${APP_STORE_CONNECT_API_KEY_ID:-}" || missing=1
    set_secret APP_STORE_CONNECT_API_ISSUER_ID "${APP_STORE_CONNECT_API_ISSUER_ID:-}" || missing=1
    set_secret APP_STORE_CONNECT_API_KEY_BASE64 "$(base64_one_line "$APP_STORE_CONNECT_API_KEY_PATH")" || missing=1
  fi
else
  echo "missing: notary credentials. Provide Apple ID secrets or App Store Connect API key secrets." >&2
  missing=1
fi

exit "$missing"
