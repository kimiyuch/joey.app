#!/bin/zsh
# Builds Joey.app and packages it as build/Joey.dmg (drag-to-Applications installer).
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

STAGING=build/dmg
DMG=build/Joey.dmg
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R build/Joey.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname Joey -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGING"
echo "Built $DMG"
