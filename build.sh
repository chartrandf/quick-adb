#!/bin/sh
# Usage: ./build.sh [build|install|dmg]
#   build    QuickADB.app in this folder (default)
#   install  build, copy to /Applications (Spotlight finds it there) and launch
#   dmg      build QuickADB.dmg: drag-to-Applications installer
set -e
cd "$(dirname "$0")"
APP=QuickADB.app
VERSION=1.0

build() {
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/QuickADB"
  cp resources/AppIcon.icns "$APP/Contents/Resources/"
  cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Quick ADB</string>
  <key>CFBundleDisplayName</key><string>Quick ADB</string>
  <key>CFBundleIdentifier</key><string>io.local.quickadb</string>
  <key>CFBundleExecutable</key><string>QuickADB</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
  codesign --force --sign - "$APP"
  echo "Built $APP"
}

case "${1:-build}" in
  build)
    build
    ;;
  install)
    build
    pkill -x QuickADB && sleep 1 || true
    rm -rf "/Applications/$APP"
    cp -R "$APP" /Applications/
    open "/Applications/$APP"
    echo "Installed /Applications/$APP"
    ;;
  dmg)
    build
    STAGE=$(mktemp -d)
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    rm -f QuickADB.dmg
    hdiutil create -volname "Quick ADB" -srcfolder "$STAGE" -ov -format UDZO QuickADB.dmg >/dev/null
    rm -rf "$STAGE"
    echo "Built QuickADB.dmg"
    ;;
  *)
    echo "Usage: $0 [build|install|dmg]" >&2
    exit 1
    ;;
esac
