#!/bin/zsh
# Builds MONEY!.app. --install copies it to /Applications and restarts it.
set -euo pipefail
cd "${0:A:h}/.."
APP="build/MONEY!.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target arm64-apple-macos27.0 -o "$APP/Contents/MacOS/MONEY" Sources/*.swift
cp Resources/Info.plist "$APP/Contents/"
if [[ ! -f build/AppIcon.icns || scripts/make-icon.swift -nt build/AppIcon.icns ]]; then
  rm -rf build/AppIcon.iconset
  mkdir -p build/AppIcon.iconset
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/"
# Sign with the Apple Development identity so Accessibility access survives rebuilds.
ID=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --options runtime --entitlements Resources/Flick.entitlements --sign "${ID:--}" "$APP"
if [[ "${1:-}" == "--install" ]]; then
  pkill -x MONEY 2>/dev/null || true; pkill -x Halo 2>/dev/null || true; pkill -x Flick 2>/dev/null || true; sleep 0.5
  # The app was called Flick, then Halo: move old copies to the Trash.
  for old in Flick Halo; do
    if [[ -d "/Applications/$old.app" ]]; then mv "/Applications/$old.app" ~/.Trash/"$old-$(date +%s).app"; fi
  done
  rm -rf "/Applications/MONEY!.app"
  ditto "$APP" "/Applications/MONEY!.app"
  open "/Applications/MONEY!.app"
fi
echo "built $APP"
