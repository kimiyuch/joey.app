#!/bin/zsh
# Builds Joey.app (arm64, ad-hoc signed, self-contained) into ./build.
set -euo pipefail
cd "$(dirname "$0")"

source ./release.env
# Where the app looks for updates; override with JOEY_FEED_URL (e.g. for local testing).
FEED_URL=${JOEY_FEED_URL:-https://github.com/$REPO/releases/latest/download/appcast.xml}
SPARKLE=vendor/sparkle-2.10.0/Sparkle.framework

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

# Bundle every Homebrew dylib the app needs (libtorrent, OpenSSL, libmpv with FFmpeg and friends),
# following dependencies recursively, and point all references at @rpath instead of Homebrew paths.
FW="$APP/Contents/Frameworks"
typeset -A bundled  # file name -> real path in the Homebrew Cellar
queue=("$APP/Contents/MacOS/Joey")
while (( ${#queue} )); do
  source=$queue[1]; queue=(${queue[2,-1]})
  for dep in $(otool -L "$source" | awk 'NR>1 {print $1}' || true); do
    # Homebrew libraries refer to each other by absolute path, a few by @rpath or @loader_path.
    case $dep in
      /opt/homebrew/*) ;;
      @rpath/*|@loader_path/*) [[ $source == /opt/homebrew/* ]] || continue; dep="$(dirname "$source")/${dep#*/}" ;;
      *) continue ;;
    esac
    name=$(basename "$dep")
    [[ -n ${bundled[$name]-} ]] && continue
    bundled[$name]=$(realpath "$dep")
    cp -L "$dep" "$FW/$name"
    chmod u+w "$FW/$name"
    queue+=("${bundled[$name]}")
  done
done
for lib in "$FW"/*.dylib; do
  install_name_tool -id "@rpath/$(basename "$lib")" "$lib" 2>/dev/null
  install_name_tool -add_rpath "@loader_path" "$lib" 2>/dev/null || true
done
for target in "$APP/Contents/MacOS/Joey" "$FW"/*.dylib; do
  changes=()
  for dep in $(otool -L "$target" | awk 'NR>1 {print $1}' | grep '^/opt/homebrew/' || true); do
    changes+=(-change "$dep" "@rpath/$(basename "$dep")")
  done
  if (( ${#changes} )); then install_name_tool "${changes[@]}" "$target" 2>/dev/null; fi
done
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Joey"

# Third-party licenses that have to ship with the binaries, one folder per Homebrew package.
LICENSES="$APP/Contents/Resources/Licenses"
mkdir -p "$LICENSES/Sparkle"
cp vendor/sparkle-2.10.0/LICENSE "$LICENSES/Sparkle/"
for real in ${(v)bundled}; do
  keg=${real%%/lib/*}
  package=$(basename "$(dirname "$keg")")
  mkdir -p "$LICENSES/$package"
  find "$keg" -maxdepth 1 -type f \( -iname 'LICEN[CS]E*' -o -iname 'COPYING*' -o -iname 'COPYRIGHT*' -o -iname 'NOTICE*' -o -iname '*GPL*' \) \
    -exec cp {} "$LICENSES/$package/" \;
done

ditto "$SPARKLE" "$FW/Sparkle.framework"

# Sign inside-out: Sparkle's helpers, the framework, the dylibs, then the app.
S="$FW/Sparkle.framework/Versions/B"
codesign --force --sign - "$S/XPCServices/Installer.xpc" "$S/XPCServices/Downloader.xpc" "$S/Autoupdate" "$S/Updater.app"
codesign --force --sign - "$FW/Sparkle.framework"
codesign --force --sign - "$FW"/*.dylib
codesign --force --sign - "$APP"
echo "Built $APP"
