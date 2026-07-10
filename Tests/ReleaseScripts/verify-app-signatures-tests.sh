#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
work_dir="$(mktemp -d /tmp/glassdb-signature-tests.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT

app="$work_dir/GlassDB.app"
sparkle_version="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
mkdir -p \
  "$sparkle_version/XPCServices/Downloader.xpc" \
  "$sparkle_version/XPCServices/Installer.xpc" \
  "$sparkle_version/Updater.app"
touch "$sparkle_version/Autoupdate"

fake_codesign="$work_dir/codesign"
cat > "$fake_codesign" <<'FAKE_CODESIGN'
#!/usr/bin/env bash
set -euo pipefail

component="${!#}"
if [[ " $* " == *" --verify "* ]]; then
  if [[ -n "${INVALID_COMPONENT:-}" && "$component" == *"$INVALID_COMPONENT"* ]]; then
    exit 1
  fi
  exit 0
fi

team="TEAM123456"
if [[ "${AD_HOC:-0}" == "1" ]]; then
  team="not set"
fi
if [[ -n "${MISMATCH_COMPONENT:-}" && "$component" == *"$MISMATCH_COMPONENT"* ]]; then
  team="OTHERTEAM1"
fi
echo "Identifier=test.component" >&2
echo "TeamIdentifier=$team" >&2
FAKE_CODESIGN
chmod +x "$fake_codesign"

verify="$repo_root/scripts/verify-app-signatures.sh"
CODESIGN_BIN="$fake_codesign" "$verify" "$app"

if MISMATCH_COMPONENT="Installer.xpc" CODESIGN_BIN="$fake_codesign" "$verify" "$app" >"$work_dir/mismatch.out" 2>&1; then
  echo "Expected TeamIdentifier mismatch to fail" >&2
  exit 1
fi
grep -q "Installer.xpc TeamIdentifier is OTHERTEAM1, expected TEAM123456" "$work_dir/mismatch.out"

if INVALID_COMPONENT="Updater.app" CODESIGN_BIN="$fake_codesign" "$verify" "$app" >"$work_dir/invalid.out" 2>&1; then
  echo "Expected invalid nested signature to fail" >&2
  exit 1
fi
grep -q "invalid code signature for Updater.app" "$work_dir/invalid.out"

if AD_HOC=1 CODESIGN_BIN="$fake_codesign" "$verify" "$app" >"$work_dir/ad-hoc.out" 2>&1; then
  echo "Expected an ad-hoc public release to fail" >&2
  exit 1
fi
grep -q "a TeamIdentifier is required for public releases" "$work_dir/ad-hoc.out"
AD_HOC=1 GLASSDB_ALLOW_AD_HOC_RELEASE=1 CODESIGN_BIN="$fake_codesign" "$verify" "$app"

echo "Release signature regression tests passed"
