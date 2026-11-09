#!/bin/zsh
# Builds Crumbs.app into ./build. Needs only Apple's free Command Line Tools
# (install with: xcode-select --install). No Xcode needed.
set -euo pipefail
cd "${0:A:h}"

APP=build/Crumbs.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -parse-as-library -swift-version 5 \
  -target "$(uname -m)-apple-macos14.0" \
  Sources/*.swift -o "$APP/Contents/MacOS/Crumbs"

cp Info.plist "$APP/Contents/"

# App icon: Icon/icon-1024.png -> AppIcon.icns  (redraw it with: swift Icon/render-icon.swift Icon/icon-1024.png)
ICONSET=build/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Icon/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Icon/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"
codesign --force --sign - "$APP"   # local "ad-hoc" signature, fine for your own Mac

echo "Built $APP"
echo "Install:  cp -R $APP /Applications/"
