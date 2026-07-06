#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: GLASSDB_CODESIGN_IDENTITY="Developer ID Application: ..." GLASSDB_NOTARY_PROFILE=glassdb-notary scripts/release.sh <version> [build-number]

Runs the full public release harness:
  1. package and optionally notarize GlassDB.app
  2. regenerate Sparkle appcast after the final zip is written
  3. verify the archive and appcast

Set GLASSDB_ALLOW_AD_HOC_RELEASE=1 only for local smoke checks.
USAGE
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 64
fi

version="$1"
build_number="${2:-}"
repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

allow_ad_hoc="${GLASSDB_ALLOW_AD_HOC_RELEASE:-0}"
codesign_identity="${GLASSDB_CODESIGN_IDENTITY:-}"
notary_profile="${GLASSDB_NOTARY_PROFILE:-}"

if [[ "$allow_ad_hoc" != "1" ]]; then
  if [[ -z "$codesign_identity" || "$codesign_identity" == "-" ]]; then
    echo "GLASSDB_CODESIGN_IDENTITY is required for a public release." >&2
    echo "Set GLASSDB_ALLOW_AD_HOC_RELEASE=1 only for a local smoke-check archive." >&2
    exit 64
  fi
  if [[ -z "$notary_profile" ]]; then
    echo "GLASSDB_NOTARY_PROFILE is required for a public release." >&2
    echo "Set GLASSDB_ALLOW_AD_HOC_RELEASE=1 only for a local smoke-check archive." >&2
    exit 64
  fi
fi

if [[ -n "$build_number" ]]; then
  scripts/package-release.sh "$version" "$build_number"
else
  scripts/package-release.sh "$version"
fi

# The package step can staple notarization tickets, which changes the final zip.
# Always regenerate the appcast after the final archive has been written.
scripts/update-appcast.sh

verify_args=("$version")
if [[ -n "$build_number" ]]; then
  verify_args+=("$build_number")
fi
scripts/verify-release.sh "${verify_args[@]}"

echo "Release harness passed for GlassDB $version${build_number:+ build $build_number}"
