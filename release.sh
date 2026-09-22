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
# Built into a staging directory, not /Applications. Cutting a release should
# not disturb the copy running on this Mac, and it must not depend on that copy
# being quit — the artifact is what matters, and it is verified from the zip.
DIST="$(mktemp -d)"
trap 'rm -rf "$DIST"' EXIT
VERSION="$VERSION" BUILD="$BUILD" ./make-app.sh "$DIST"

APP="$DIST/RollScrub.app"
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

# The download buttons name the file, and nothing else in this script touches
# them. A release that leaves them alone puts the *previous* build on the
# homepage — which is how somebody downloads a copy that cannot talk to the
# current licence server, pays, and is told their key does not exist. Only
# site/*.html: appcast.xml legitimately lists every past version, and
# rewriting it would break the update path for everyone not on the newest.
# Anchored to href=, and recursive, so that it matches exactly what the check
# below looks for. Prose is left alone deliberately: a changelog sentence
# naming an old build is a historical fact, and silently repointing it at the
# newest zip would make the changelog lie.
echo "==> pointing the site's download links at $VERSION"
while IFS= read -r page; do
  # Both quote styles, spelled out twice rather than matched with a
  # back-reference: BSD sed silently matches nothing when a \1 appears in an
  # -E pattern, so the clever version rewrites no links at all and the check
  # below then aborts every release.
  /usr/bin/sed -i '' -E \
    -e "s|href=\"/releases/RollScrub-[0-9]+(\.[0-9]+)*\.zip\"|href=\"/releases/RollScrub-$VERSION.zip\"|g" \
    -e "s|href='/releases/RollScrub-[0-9]+(\.[0-9]+)*\.zip'|href='/releases/RollScrub-$VERSION.zip'|g" \
    "$page"
done < <(find "$SITE" -name '*.html' -type f)

# Checked, not assumed. A link left pointing at an older build looks identical
# on the page and surfaces only as a customer who cannot activate. The
# `|| true` matters: grep exits non-zero when it finds nothing, which under
# `set -e` would kill the script precisely when everything is correct.
STALE="$(grep -rhoE "href=[\"']/releases/RollScrub-[0-9]+(\.[0-9]+)*\.zip[\"']" "$SITE" --include='*.html' \
         | grep -v "RollScrub-$VERSION\.zip" || true)"
[ -z "$STALE" ] || die "site still links an older build: $STALE"

echo
echo "Release $VERSION ($BUILD) ready:"
ls -lh "$RELEASES" "$APPCAST"
echo
echo "The site's download links now point at $VERSION."
echo
echo "Commit and push, then DEPLOY — a push alone changes nothing:"
echo "  npx wrangler deploy"
echo
echo "site/ is served by the Worker's ASSETS binding, so these go live only"
echo "once that deploy lands:"
echo "  ${DOWNLOAD_PREFIX}RollScrub-$VERSION.zip"
echo "  https://rollscrub.com/appcast.xml"
echo
echo "Then confirm the feed is actually reachable, because a broken one fails silently:"
echo "  curl -sI https://rollscrub.com/appcast.xml | head -1"
