#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
source_png="${1:-$repo_root/Assets/AppIcon/GlassDBIcon.png}"
iconset="$repo_root/Assets/AppIcon/GlassDB.iconset"
icns="$repo_root/Assets/AppIcon/GlassDB.icns"
asset_catalog="$repo_root/Assets/Assets.xcassets"
appiconset="$asset_catalog/GlassDB.appiconset"

if [[ ! -f "$source_png" ]]; then
  echo "Source icon PNG not found: $source_png" >&2
  exit 66
fi

rm -rf "$iconset"
mkdir -p "$iconset"

swift -module-cache-path "$repo_root/.build/module-cache" "$repo_root/scripts/render-iconset.swift" "$source_png" "$iconset"
xattr -cr "$iconset"

rm -rf "$appiconset"
mkdir -p "$appiconset"
cp "$iconset"/*.png "$appiconset"/

cat > "$asset_catalog/Contents.json" <<'JSON'
{
  "info": {
    "author": "xcode",
    "version": 1
  }
}
JSON

cat > "$appiconset/Contents.json" <<'JSON'
{
  "images": [
    {
      "filename": "icon_16x16.png",
      "idiom": "mac",
      "scale": "1x",
      "size": "16x16"
    },
    {
      "filename": "icon_16x16@2x.png",
      "idiom": "mac",
      "scale": "2x",
      "size": "16x16"
    },
    {
      "filename": "icon_32x32.png",
      "idiom": "mac",
      "scale": "1x",
      "size": "32x32"
    },
    {
      "filename": "icon_32x32@2x.png",
      "idiom": "mac",
      "scale": "2x",
      "size": "32x32"
    },
    {
      "filename": "icon_128x128.png",
      "idiom": "mac",
      "scale": "1x",
      "size": "128x128"
    },
    {
      "filename": "icon_128x128@2x.png",
      "idiom": "mac",
      "scale": "2x",
      "size": "128x128"
    },
    {
      "filename": "icon_256x256.png",
      "idiom": "mac",
      "scale": "1x",
      "size": "256x256"
    },
    {
      "filename": "icon_256x256@2x.png",
      "idiom": "mac",
      "scale": "2x",
      "size": "256x256"
    },
    {
      "filename": "icon_512x512.png",
      "idiom": "mac",
      "scale": "1x",
      "size": "512x512"
    },
    {
      "filename": "icon_512x512@2x.png",
      "idiom": "mac",
      "scale": "2x",
      "size": "512x512"
    }
  ],
  "info": {
    "author": "xcode",
    "version": 1
  }
}
JSON

if iconutil -c icns "$iconset" -o "$icns"; then
  echo "Created $icns"
else
  echo "Warning: iconutil could not create $icns; release packaging will use Assets.xcassets." >&2
fi

echo "Created $appiconset"
