#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: SPARKLE_PUBLIC_ED_KEY=... scripts/package-release.sh <version> [build-number]" >&2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 64
fi

version="$1"
build_number="${2:-$(date +%Y%m%d%H%M)}"
bundle_id="${GLASSDB_BUNDLE_ID:-io.github.makikub.GlassDB}"
feed_url="${SPARKLE_FEED_URL:-https://makikub.github.io/glass-db/releases/appcast.xml}"
configuration="${CONFIGURATION:-release}"
codesign_identity="${GLASSDB_CODESIGN_IDENTITY:--}"
notary_profile="${GLASSDB_NOTARY_PROFILE:-}"
allow_dummy_public_key="${GLASSDB_ALLOW_DUMMY_PUBLIC_KEY:-0}"

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$repo_root/.build/module-cache}"

public_ed_key="${SPARKLE_PUBLIC_ED_KEY:-}"
public_key_file="$repo_root/release/sparkle-public-key.txt"
if [[ -z "$public_ed_key" && -f "$public_key_file" ]]; then
  public_ed_key="$(tr -d '[:space:]' < "$public_key_file")"
fi
if [[ -z "$public_ed_key" ]]; then
  echo "SPARKLE_PUBLIC_ED_KEY is required. Generate it with Sparkle's generate_keys tool or add release/sparkle-public-key.txt." >&2
  exit 64
fi
if [[ "$public_ed_key" == "dummy" && "$allow_dummy_public_key" != "1" ]]; then
  echo "SPARKLE_PUBLIC_ED_KEY=dummy is only allowed with GLASSDB_ALLOW_DUMMY_PUBLIC_KEY=1." >&2
  exit 64
fi

swift build -c "$configuration"
bin_path="$(swift build -c "$configuration" --show-bin-path)"
executable="$bin_path/GlassDB"

app_dir="$repo_root/build/release/GlassDB.app"
zip_path="$repo_root/docs/releases/GlassDB-${version}.zip"
icon_path="$repo_root/Assets/AppIcon/GlassDB.icns"
asset_catalog="$repo_root/Assets/Assets.xcassets"

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Frameworks" "$repo_root/docs/releases"
mkdir -p "$app_dir/Contents/Resources"

cp "$executable" "$app_dir/Contents/MacOS/GlassDB"
if [[ -f "$icon_path" ]]; then
  cp "$icon_path" "$app_dir/Contents/Resources/GlassDB.icns"
elif [[ -d "$asset_catalog" ]]; then
  xcrun actool \
    --compile "$app_dir/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 26.0 \
    --app-icon GlassDB \
    --output-partial-info-plist "$app_dir/Contents/Resources/AssetCatalogInfo.plist" \
    "$asset_catalog" >/dev/null
else
  echo "Warning: no app icon assets were found. Run scripts/make-app-icon.sh first." >&2
fi

sparkle_framework="$(find "$repo_root/.build" -path '*/Sparkle.framework' -type d | head -n 1)"
if [[ -z "$sparkle_framework" ]]; then
  echo "Sparkle.framework was not found under .build. Run swift build and try again." >&2
  exit 1
fi
ditto "$sparkle_framework" "$app_dir/Contents/Frameworks/Sparkle.framework"

cat > "$app_dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>GlassDB</string>
  <key>CFBundleIdentifier</key>
  <string>${bundle_id}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>GlassDB</string>
  <key>CFBundleIconFile</key>
  <string>GlassDB</string>
  <key>CFBundleIconName</key>
  <string>GlassDB</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${version}</string>
  <key>CFBundleVersion</key>
  <string>${build_number}</string>
  <key>LSMinimumSystemVersion</key>
  <string>26.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
  <key>SUPublicEDKey</key>
  <string>${public_ed_key}</string>
  <key>SUFeedURL</key>
  <string>${feed_url}</string>
</dict>
</plist>
PLIST

plutil -lint "$app_dir/Contents/Info.plist" >/dev/null

codesign_args=(--force --options runtime --sign "$codesign_identity")
if [[ "$codesign_identity" != "-" ]]; then
  codesign_args+=(--timestamp)
fi

sparkle_version_dir="$app_dir/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign "${codesign_args[@]}" "$sparkle_version_dir/XPCServices/Downloader.xpc"
codesign "${codesign_args[@]}" "$sparkle_version_dir/XPCServices/Installer.xpc"
codesign "${codesign_args[@]}" "$sparkle_version_dir/Updater.app"
codesign "${codesign_args[@]}" "$sparkle_version_dir/Autoupdate"
codesign "${codesign_args[@]}" "$app_dir/Contents/Frameworks/Sparkle.framework"
codesign "${codesign_args[@]}" --identifier "$bundle_id" "$app_dir"

if [[ -n "$notary_profile" ]]; then
  notary_zip="$repo_root/build/release/GlassDB-notary-${version}.zip"
  rm -f "$notary_zip"
  ditto -c -k --keepParent "$app_dir" "$notary_zip"
  xcrun notarytool submit "$notary_zip" --keychain-profile "$notary_profile" --wait
  xcrun stapler staple "$app_dir"
  codesign --verify --deep --strict "$app_dir"
fi

rm -f "$zip_path"
ditto -c -k --keepParent "$app_dir" "$zip_path"

echo "Created $app_dir"
echo "Created $zip_path"
echo "Next: run scripts/update-appcast.sh"
