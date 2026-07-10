#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: scripts/verify-app-signatures.sh <GlassDB.app>" >&2
}

if [[ $# -ne 1 ]]; then
  usage
  exit 64
fi

app="$1"
codesign_bin="${CODESIGN_BIN:-codesign}"
allow_ad_hoc="${GLASSDB_ALLOW_AD_HOC_RELEASE:-0}"

fail() {
  echo "App signature verification failed: $*" >&2
  exit 1
}

[[ -d "$app" ]] || fail "missing app bundle: $app"

sparkle="$app/Contents/Frameworks/Sparkle.framework"
sparkle_version="$sparkle/Versions/B"
labels=(
  "GlassDB.app"
  "Sparkle.framework"
  "Downloader.xpc"
  "Installer.xpc"
  "Updater.app"
  "Autoupdate"
)
components=(
  "$app"
  "$sparkle"
  "$sparkle_version/XPCServices/Downloader.xpc"
  "$sparkle_version/XPCServices/Installer.xpc"
  "$sparkle_version/Updater.app"
  "$sparkle_version/Autoupdate"
)

team_identifier() {
  local component="$1"
  local details
  local team_id

  details="$("$codesign_bin" -dv --verbose=4 "$component" 2>&1)" \
    || fail "could not read code signature: $component"
  team_id="$(sed -n 's/^TeamIdentifier=//p' <<<"$details" | head -n 1)"
  [[ -n "$team_id" ]] || fail "missing TeamIdentifier: $component"
  printf '%s' "$team_id"
}

expected_team=""
for index in "${!components[@]}"; do
  label="${labels[$index]}"
  component="${components[$index]}"
  [[ -e "$component" ]] || fail "missing $label: $component"

  verify_args=(--verify --strict)
  if [[ "$component" == "$app" ]]; then
    verify_args+=(--deep)
  fi
  "$codesign_bin" "${verify_args[@]}" "$component" \
    || fail "invalid code signature for $label"

  actual_team="$(team_identifier "$component")"
  if [[ -z "$expected_team" ]]; then
    expected_team="$actual_team"
    if [[ "$allow_ad_hoc" != "1" && "$expected_team" == "not set" ]]; then
      fail "GlassDB.app is ad-hoc signed; a TeamIdentifier is required for public releases"
    fi
  elif [[ "$actual_team" != "$expected_team" ]]; then
    fail "$label TeamIdentifier is $actual_team, expected $expected_team"
  fi
done

echo "App signature verification passed with TeamIdentifier=$expected_team"
