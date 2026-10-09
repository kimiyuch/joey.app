#!/bin/zsh
# Downloads the Sparkle release (framework + signing tools) into vendor/ if it isn't there yet.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=2.10.0
DEST=vendor/sparkle-$VERSION
[[ -d $DEST/Sparkle.framework ]] && exit 0
mkdir -p "$DEST"
curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz" | tar -xJ -C "$DEST"
echo "Fetched Sparkle $VERSION into $DEST"
