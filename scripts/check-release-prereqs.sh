#!/usr/bin/env bash
set -euo pipefail

repo="${GLASSDB_GITHUB_REPO:-makikub/glass-db}"
repo_root="$(git rev-parse --show-toplevel)"
missing=0

check_file() {
  local path="$1"
  local label="$2"
  if [[ -f "$path" ]]; then
    echo "ok: $label"
  else
    echo "missing: $label ($path)" >&2
    missing=1
  fi
}

check_secret() {
  local name="$1"
  if grep -qx "$name" "$secrets_file"; then
    echo "ok: GitHub secret $name"
  else
    echo "missing: GitHub secret $name" >&2
    missing=1
  fi
}

check_file "$repo_root/release/sparkle-public-key.txt" "Sparkle public key"

if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "ok: local Developer ID Application identity"
else
  echo "missing: local Developer ID Application identity" >&2
  missing=1
fi

if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  secrets_file="$(mktemp "${TMPDIR:-/tmp}/glassdb-secrets.XXXXXX")"
  trap 'rm -f "$secrets_file"' EXIT
  gh secret list --repo "$repo" | awk '{print $1}' > "$secrets_file"

  check_secret DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64
  check_secret DEVELOPER_ID_APPLICATION_CERTIFICATE_PASSWORD
  check_secret DEVELOPER_ID_APPLICATION_IDENTITY
  check_secret SPARKLE_ED_PRIVATE_KEY

  if grep -qx APPLE_ID "$secrets_file" && grep -qx APPLE_TEAM_ID "$secrets_file" && grep -qx APPLE_APP_SPECIFIC_PASSWORD "$secrets_file"; then
    echo "ok: GitHub Apple ID notary secrets"
  elif grep -qx APP_STORE_CONNECT_API_KEY_ID "$secrets_file" && grep -qx APP_STORE_CONNECT_API_ISSUER_ID "$secrets_file" && grep -qx APP_STORE_CONNECT_API_KEY_BASE64 "$secrets_file"; then
    echo "ok: GitHub App Store Connect API notary secrets"
  else
    echo "missing: GitHub notary secrets" >&2
    missing=1
  fi
else
  echo "warning: gh is not authenticated; skipped GitHub secret checks" >&2
fi

exit "$missing"
