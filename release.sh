#!/bin/bash
# Builds, notarizes, and packages a RollScrub release, then regenerates the
# Sparkle appcast that existing installs poll for updates.
#
#   VERSION=1.1 BUILD=2 ./release.sh
#
# Upload the whole releases/ directory to rollscrub.com afterwards, so that
# https://rollscrub.com/appcast.xml and the zip beside it both resolve — the
# appcast points at those URLs and an update fails without them.
set -euo pipefail

cd "$(dirname "$0")"

VERSION="${VERSION:?set VERSION, e.g. VERSION=1.1 BUILD=2 ./release.sh}"
BUILD="${BUILD:?set BUILD to a number higher than the last release}"

# Cloudflare Pages serves site/ as the domain root, so site/releases/ is
# /releases/. The appcast is written to the root instead, because the feed URL
# baked into every shipped copy is https://rollscrub.com/appcast.xml and older
# installs will keep asking for exactly that path forever.
SITE="site"
RELEASES="$SITE/releases"
APPCAST="$SITE/appcast.xml"
DOWNLOAD_PREFIX="${DOWNLOAD_PREFIX:-https://rollscrub.com/releases/}"

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
"$APPCAST_TOOL" --download-url-prefix "$DOWNLOAD_PREFIX" -o "$APPCAST" "$RELEASES"

echo
echo "Release $VERSION ($BUILD) ready:"
ls -lh "$RELEASES" "$APPCAST"
echo
echo "Commit and push — Cloudflare Pages deploys site/ and these go live:"
echo "  ${DOWNLOAD_PREFIX}RollScrub-$VERSION.zip"
echo "  https://rollscrub.com/appcast.xml"
echo
echo "Then confirm the feed is actually reachable, because a broken one fails silently:"
echo "  curl -sI https://rollscrub.com/appcast.xml | head -1"
