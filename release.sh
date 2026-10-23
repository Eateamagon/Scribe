#!/bin/bash
# Builds a universal (Apple silicon + Intel) Scribe.app and packs it into a
# drag-to-Applications DMG in dist/. Nothing to install on the receiving Mac:
# Scribe uses only Apple's own frameworks.
#
#     bash release.sh 1.1              # build dist/Scribe-1.1.dmg
#     bash release.sh 1.1 --publish    # ...and create GitHub release v1.1 with it
#
# --publish needs the GitHub CLI signed in (gh auth status) and the version's
# changes already committed and pushed — the release is tagged at origin/main.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
PUBLISH="${2:-}"
if [ -z "$VERSION" ]; then
  echo "Usage: bash release.sh <version> [--publish]    e.g. bash release.sh 1.1"
  exit 1
fi

APP="Scribe.app"
DMG="dist/Scribe-$VERSION.dmg"

VERSION="$VERSION" UNIVERSAL=1 bash build.sh

# Refuse to ship a build that lost a slice or its signature.
ARCHS="$(lipo -archs "$APP/Contents/MacOS/Scribe")"
case "$ARCHS" in
  *arm64*x86_64*|*x86_64*arm64*) ;;
  *) echo "!! Binary is '$ARCHS', not universal. Not packaging."; exit 1 ;;
esac
codesign --verify --strict "$APP"

echo
echo "Packing $DMG..."
STAGE="$(mktemp -d)/Scribe"
mkdir -p "$STAGE" dist
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "dist-assets/Install Scribe.txt" "$STAGE/"
rm -f "$DMG"
hdiutil create -volname "Scribe $VERSION" -srcfolder "$STAGE" \
  -fs HFS+ -format UDZO -imagekey zlib-level=9 -quiet "$DMG"
rm -rf "$(dirname "$STAGE")"

echo "Built $(pwd)/$DMG  ($(du -h "$DMG" | cut -f1), $ARCHS)"

if [ "$PUBLISH" = "--publish" ]; then
  echo
  echo "Publishing GitHub release v$VERSION..."
  gh release create "v$VERSION" "$DMG" \
    --target main \
    --title "Scribe $VERSION" \
    --notes-file "dist-assets/release-notes.md"
  gh release view "v$VERSION" --json url --jq .url
fi
