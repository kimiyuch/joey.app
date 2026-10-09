#!/bin/zsh
# Builds Joey.app (arm64, ad-hoc signed, self-contained) into ./build.
set -euo pipefail
cd "$(dirname "$0")"

source ./release.env
# Where the app looks for updates; override with JOEY_FEED_URL (e.g. for local testing).
FEED_URL=${JOEY_FEED_URL:-https://github.com/$REPO/releases/latest/download/appcast.xml}
SPARKLE=vendor/sparkle-2.10.0/Sparkle.framework

LIBTORRENT=/opt/homebrew/opt/libtorrent-rasterbar/lib/libtorrent-rasterbar.2.1.dylib
OPENSSL=/opt/homebrew/Cellar/openssl@4/4.0.3/lib
APP=build/Joey.app

./scripts/fetch-sparkle.sh
swift build -c release
BIN=$(swift build -c release --show-bin-path)/Joey

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Joey"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SUFeedURL $FEED_URL" "$APP/Contents/Info.plist"

if [[ ! -f build/AppIcon.icns ]]; then
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Third-party licenses that have to ship with the binaries.
LICENSES="$APP/Contents/Resources/Licenses"
mkdir -p "$LICENSES"
cp /opt/homebrew/opt/libtorrent-rasterbar/LICENSE "$LICENSES/libtorrent.txt"
cp "$OPENSSL/../LICENSE.txt" "$LICENSES/OpenSSL.txt"
cp vendor/sparkle-2.10.0/LICENSE "$LICENSES/Sparkle.txt"

# Bundle the dylibs and point everything at @rpath instead of Homebrew paths.
FW="$APP/Contents/Frameworks"
cp -L "$LIBTORRENT" "$OPENSSL/libssl.4.dylib" "$OPENSSL/libcrypto.4.dylib" "$FW/"
chmod u+w "$FW"/*.dylib
for lib in "$FW"/*.dylib; do
  install_name_tool -id "@rpath/$(basename "$lib")" "$lib" 2>/dev/null
done
for target in "$APP/Contents/MacOS/Joey" "$FW"/*.dylib; do
  otool -L "$target" | awk 'NR>1 {print $1}' | grep -E 'libtorrent-rasterbar|libssl|libcrypto' | while read -r dep; do
    install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$target" 2>/dev/null
  done
done
install_name_tool -add_rpath "@loader_path" "$FW/libtorrent-rasterbar.2.1.dylib" 2>/dev/null || true
install_name_tool -add_rpath "@loader_path" "$FW/libssl.4.dylib" 2>/dev/null || true
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Joey"

ditto "$SPARKLE" "$FW/Sparkle.framework"

# Sign inside-out: Sparkle's helpers, the framework, the dylibs, then the app.
S="$FW/Sparkle.framework/Versions/B"
codesign --force --sign - "$S/XPCServices/Installer.xpc" "$S/XPCServices/Downloader.xpc" "$S/Autoupdate" "$S/Updater.app"
codesign --force --sign - "$FW/Sparkle.framework"
codesign --force --sign - "$FW"/*.dylib
codesign --force --sign - "$APP"
echo "Built $APP"
