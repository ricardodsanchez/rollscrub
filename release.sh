#!/bin/bash
# Builds, notarizes, and packages a RollScrub release, then regenerates the
# Sparkle appcast that existing installs poll for updates.
#
#   VERSION=1.1 BUILD=2 ./release.sh
#
# Upload the whole releases/ directory to rollscrub.app afterwards, so that
# https://rollscrub.app/appcast.xml and the zip beside it both resolve — the
# appcast points at those URLs and an update fails without them.
set -euo pipefail

cd "$(dirname "$0")"

VERSION="${VERSION:?set VERSION, e.g. VERSION=1.1 BUILD=2 ./release.sh}"
BUILD="${BUILD:?set BUILD to a number higher than the last release}"
RELEASES="releases"
DOWNLOAD_PREFIX="${DOWNLOAD_PREFIX:-https://rollscrub.app/releases/}"

die() { echo "error: $*" >&2; exit 1; }

# Sparkle's tools live in the resolved package artifacts; the path carries the
# version, so find it rather than pinning it.
APPCAST_TOOL="$(find .build/artifacts -name generate_appcast -type f 2>/dev/null | head -1)"
[ -n "$APPCAST_TOOL" ] || die "generate_appcast not found — run: swift package resolve"

echo "==> building $VERSION ($BUILD)"
VERSION="$VERSION" BUILD="$BUILD" ./make-app.sh

APP="/Applications/RollScrub.app"
INSTALLED="$(defaults read "$APP/Contents/Info.plist" CFBundleVersion)"
[ "$INSTALLED" = "$BUILD" ] || die "built bundle reports build $INSTALLED, expected $BUILD"

echo "==> notarizing"
./notarize.sh "$APP"

mkdir -p "$RELEASES"
ARCHIVE="$RELEASES/RollScrub-$VERSION.zip"
echo "==> packaging $ARCHIVE"
rm -f "$ARCHIVE"
ditto -c -k --keepParent "$APP" "$ARCHIVE"

# generate_appcast signs every archive in the directory with the EdDSA private
# key from the keychain and rewrites appcast.xml across all of them, so old
# versions keep their entries and users on any prior build still see a path
# forward.
echo "==> regenerating appcast"
"$APPCAST_TOOL" --download-url-prefix "$DOWNLOAD_PREFIX" "$RELEASES"

echo
echo "Release $VERSION ($BUILD) ready in $RELEASES/"
ls -lh "$RELEASES"
echo
echo "Next: upload $RELEASES/ to rollscrub.app so these resolve —"
echo "  ${DOWNLOAD_PREFIX}RollScrub-$VERSION.zip"
echo "  https://rollscrub.app/appcast.xml   (from $RELEASES/appcast.xml)"
