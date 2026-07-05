#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
updates_dir="$repo_root/docs/releases"
download_url_prefix="${SPARKLE_DOWNLOAD_URL_PREFIX:-https://makikub.github.io/glass-db/releases/}"
allow_unsigned_appcast="${GLASSDB_ALLOW_UNSIGNED_APPCAST:-0}"

sparkle_checkout="$(find "$repo_root/.build/checkouts" -maxdepth 2 -name generate_appcast -type f | head -n 1)"
sparkle_artifact="$(find "$repo_root/.build/artifacts" -path '*/generate_appcast' -type f | head -n 1)"

if [[ -n "$sparkle_checkout" ]]; then
  generate_appcast="$sparkle_checkout"
elif [[ -n "$sparkle_artifact" ]]; then
  generate_appcast="$sparkle_artifact"
else
  echo "generate_appcast was not found. Build or resolve the Sparkle package first." >&2
  exit 1
fi

args=(--download-url-prefix "$download_url_prefix")

if [[ -n "${SPARKLE_ED_KEY_FILE:-}" ]]; then
  args+=(--ed-key-file "$SPARKLE_ED_KEY_FILE")
fi

if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
  printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$generate_appcast" "${args[@]}" --ed-key-file - "$updates_dir"
else
  "$generate_appcast" "${args[@]}" "$updates_dir"
fi

echo "Updated $updates_dir/appcast.xml"

if [[ "$allow_unsigned_appcast" != "1" ]] && ! grep -q "sparkle:edSignature=" "$updates_dir/appcast.xml"; then
  echo "appcast.xml is missing sparkle:edSignature. Provide a Sparkle EdDSA private key or set GLASSDB_ALLOW_UNSIGNED_APPCAST=1 for local smoke checks." >&2
  exit 1
fi
