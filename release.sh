#!/bin/zsh
# Builds a release and publishes it to GitHub Releases, where Sparkle picks it up.
#
#   ./release.sh 0.2
#
# The release notes are the version's section in CHANGELOG.md ("## 0.2 (date)"), which has to exist.
#
# Environment:
#   PUBLISH=0            build into build/release without bumping git or uploading (for testing)
#   DOWNLOAD_BASE_URL    where the update archive will live (default: the GitHub release)
set -euo pipefail
cd "$(dirname "$0")"
source ./release.env

VERSION=${1:?usage: ./release.sh <version>}
PUBLISH=${PUBLISH:-1}
TAG="v$VERSION"
PLIST=Resources/Info.plist
SPARKLE_BIN=vendor/sparkle-2.10.0/bin
OUT=build/release
DOWNLOAD_BASE_URL=${DOWNLOAD_BASE_URL:-https://github.com/$REPO/releases/download/$TAG/}

# Everything between this version's heading and the next one, without surrounding blank lines.
NOTES=$(awk -v v="$VERSION" '/^## / { found = ($2 == v); next } found' CHANGELOG.md \
  | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}')

if [[ $PUBLISH == 1 ]]; then
  [[ -n $NOTES ]] || { echo "Add a '## $VERSION (date)' section to CHANGELOG.md first."; exit 1; }
  [[ -z $(git status --porcelain) ]] || { echo "Commit or stash your changes first."; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "GitHub CLI isn't logged in: run 'gh auth login'."; exit 1; }
fi

# Sparkle compares CFBundleVersion, so it has to go up with every release.
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" $PLIST) + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" $PLIST
echo "Building Joey $VERSION ($BUILD)"

./make-dmg.sh

rm -rf "$OUT" && mkdir -p "$OUT/updates"
ARCHIVE="Joey-$VERSION.zip"
ditto -c -k --keepParent build/Joey.app "$OUT/updates/$ARCHIVE"
cp build/Joey.dmg "$OUT/Joey.dmg"
if [[ -n $NOTES ]]; then
  print -r -- "$NOTES" > "$OUT/updates/Joey-$VERSION.md"
fi

# Signs the archive with the key in the Keychain and writes the feed.
"$SPARKLE_BIN/generate_appcast" --account joey --embed-release-notes \
  --download-url-prefix "$DOWNLOAD_BASE_URL" -o "$OUT/appcast.xml" "$OUT/updates"

if [[ $PUBLISH != 1 ]]; then
  echo "Built $OUT (not published)"
  exit 0
fi

git commit -q -am "Release $VERSION"
git tag "$TAG"
git push -q && git push -q origin "$TAG"
gh release create "$TAG" --repo "$REPO" --title "Joey $VERSION" --notes "$NOTES" \
  "$OUT/updates/$ARCHIVE" "$OUT/Joey.dmg" "$OUT/appcast.xml"
echo "Published Joey $VERSION"
echo "Now add $VERSION to the changelog in ../joey.web (resources/views/changelog.blade.php) and deploy it."
