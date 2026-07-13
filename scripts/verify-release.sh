#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: scripts/verify-release.sh <version> [build-number]" >&2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 64
fi

version="$1"
build_number="${2:-}"
repo_root="$(git rev-parse --show-toplevel)"
release_zip="$repo_root/docs/releases/GlassDB-${version}.zip"
appcast="$repo_root/docs/releases/appcast.xml"
landing_page="$repo_root/docs/index.html"
expected_url="https://makikub.github.io/glass-db/releases/GlassDB-${version}.zip"
expected_landing_href="href=\"releases/GlassDB-${version}.zip\""
work_dir="$(mktemp -d "/tmp/gdbrel.XXXXXX")"
allow_ad_hoc="${GLASSDB_ALLOW_AD_HOC_RELEASE:-0}"

cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

fail() {
  echo "Release verification failed: $*" >&2
  exit 1
}

[[ -f "$release_zip" ]] || fail "missing $release_zip"
[[ -f "$appcast" ]] || fail "missing $appcast"
[[ -f "$landing_page" ]] || fail "missing $landing_page"

if unzip -l "$release_zip" | grep -Eq '(^|/)(__MACOSX|\\._|\\.DS_Store)'; then
  fail "archive contains AppleDouble or Finder metadata files"
fi

ditto -x -k "$release_zip" "$work_dir"
app="$work_dir/GlassDB.app"
info="$app/Contents/Info.plist"

[[ -d "$app" ]] || fail "archive does not contain GlassDB.app"
[[ -f "$info" ]] || fail "archive is missing Info.plist"
[[ -f "$app/Contents/MacOS/GlassDB" ]] || fail "archive is missing executable"
[[ -d "$app/Contents/Frameworks/Sparkle.framework" ]] || fail "archive is missing Sparkle.framework"
[[ -f "$app/Contents/Resources/GlassDB.icns" || -f "$app/Contents/Resources/Assets.car" ]] || fail "archive is missing app icon resources"
otool -l "$app/Contents/MacOS/GlassDB" | grep -q '@executable_path/../Frameworks' || fail "executable is missing @executable_path/../Frameworks rpath"
if find "$app" \( -name '._*' -o -name '__MACOSX' -o -name '.DS_Store' \) -print -quit | grep -q .; then
  fail "extracted app contains AppleDouble or Finder metadata files"
fi

short_version="$(plutil -extract CFBundleShortVersionString raw "$info")"
actual_build="$(plutil -extract CFBundleVersion raw "$info")"
feed_url="$(plutil -extract SUFeedURL raw "$info")"
public_key="$(plutil -extract SUPublicEDKey raw "$info")"

[[ "$short_version" == "$version" ]] || fail "CFBundleShortVersionString is $short_version, expected $version"
if [[ -n "$build_number" ]]; then
  [[ "$actual_build" == "$build_number" ]] || fail "CFBundleVersion is $actual_build, expected $build_number"
fi
[[ "$feed_url" == "https://makikub.github.io/glass-db/releases/appcast.xml" ]] || fail "unexpected SUFeedURL: $feed_url"
[[ -n "$public_key" && "$public_key" != "dummy" ]] || fail "SUPublicEDKey must be a real Sparkle public key"

"$repo_root/scripts/verify-app-signatures.sh" "$app" || fail "app or Sparkle signature verification failed"
codesign_details="$(codesign -dv --verbose=4 "$app" 2>&1)"
if [[ "$allow_ad_hoc" != "1" ]] && grep -q "Signature=adhoc" <<<"$codesign_details"; then
  fail "app is ad-hoc signed; use Developer ID signing for public release"
fi
if [[ "$allow_ad_hoc" != "1" ]]; then
  spctl -a -vvv -t execute "$app" || fail "Gatekeeper assessment failed"
fi

grep -q "<sparkle:shortVersionString>${version}</sparkle:shortVersionString>" "$appcast" || fail "appcast does not include version $version"
grep -q "url=\"$expected_url\"" "$appcast" || fail "appcast download URL is not $expected_url"
grep -q "sparkle:edSignature=" "$appcast" || fail "appcast is missing Sparkle EdDSA signature"
grep -q "$expected_landing_href" "$landing_page" || fail "landing page download link is not GlassDB-${version}.zip"

echo "Release verification passed for GlassDB $version"
