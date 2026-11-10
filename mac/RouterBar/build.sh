#!/bin/sh
# Builds RouterBar.app.
#   sh build.sh               build for this Mac, install to /Applications, (re)launch
#   sh build.sh --no-install  build only (build/RouterBar.app)
#   sh build.sh --release     universal build (Apple Silicon + Intel) zipped for GitHub Releases:
#                             build/RouterBar-<version>-macOS.zip
set -e
cd "$(dirname "$0")"
VERSION=1.0.0
BUILD=1
APP=build/RouterBar.app
MODE=${1:-install}

if [ "$MODE" = "--release" ]; then
    ARCHS="--arch arm64 --arch x86_64"
else
    ARCHS=""
fi
# shellcheck disable=SC2086
swift build -c release $ARCHS
# shellcheck disable=SC2086
BIN=$(swift build -c release $ARCHS --show-bin-path)/RouterBar

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RouterBar"

# App icon
if [ ! -f build/AppIcon.icns ]; then
    T=build/icon.iconset; rm -rf "$T"; mkdir -p "$T"
    swift Support/make-icon.swift build/icon-1024.png
    for s in 16 32 128 256 512; do
        sips -z $s $s build/icon-1024.png --out "$T/icon_${s}x${s}.png" >/dev/null
        d=$((s * 2)); sips -z $d $d build/icon-1024.png --out "$T/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$T" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>RouterBar</string>
    <key>CFBundleDisplayName</key><string>RouterBar</string>
    <key>CFBundleIdentifier</key><string>local.routerbar</string>
    <key>CFBundleExecutable</key><string>RouterBar</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

# Ad-hoc signature (no Apple developer account) with the hardened runtime (blocks code
# injection into the running app). Gatekeeper warns on first launch of a downloaded copy;
# see docs/mac-app.md.
codesign --force --deep --options runtime --sign - "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/RouterBar"))"

case "$MODE" in
    --no-install) exit 0 ;;
    --release)
        ZIP="build/RouterBar-$VERSION-macOS.zip"
        rm -f "$ZIP"
        ditto -c -k --keepParent "$APP" "$ZIP"
        echo "Release archive: $ZIP"
        exit 0 ;;
esac

pkill -x RouterBar 2>/dev/null && sleep 1 || true
rm -rf /Applications/RouterBar.app
cp -R "$APP" /Applications/RouterBar.app
open /Applications/RouterBar.app
echo "Installed to /Applications/RouterBar.app and launched."
