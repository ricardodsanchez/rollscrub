#!/bin/bash
# Builds RollScrub.app and installs it to a single canonical location.
#
# SwiftPM leaves loose executables in .build (debug/ and release/ copies of
# both the GUI and the CLI), which Spotlight happily indexes — so searching
# for "rollscrub" turns up four things that all look launchable. This script
# keeps exactly one installed app and tells Spotlight to ignore the rest.
set -euo pipefail

cd "$(dirname "$0")"
DEST="${1:-/Applications}"
APP_NAME="RollScrub.app"

# Sparkle decides whether an update exists by comparing CFBundleVersion, so
# every release needs a higher one than the last. VERSION is what people see.
VERSION="${VERSION:-1.0}"
BUILD="${BUILD:-1}"

# Staged outside the project: this tree can live in iCloud Drive, and a
# file-provider directory stamps com.apple.FinderInfo and provenance
# attributes onto everything — which codesign refuses outright, and which
# xattr -c cannot always clear. A temp directory is never synced.
STAGE_ROOT="$(mktemp -d)"
STAGE="$STAGE_ROOT/$APP_NAME"
trap 'rm -rf "$STAGE_ROOT"' EXIT

# Keep build artifacts out of Spotlight so only the installed app is findable.
mkdir -p .build
touch .build/.metadata_never_index

# Built for both architectures: a single-arch build makes Sparkle stamp
# hardwareRequirements into the appcast, which silently withholds every update
# from the other kind of Mac.
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}" --product RollScrubApp
BINPATH="$(swift build -c release "${ARCHS[@]}" --product RollScrubApp --show-bin-path)"

mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" "$STAGE/Contents/Frameworks"
cp "$BINPATH/RollScrubApp" "$STAGE/Contents/MacOS/RollScrub"

# SwiftPM links Sparkle but leaves it in the build directory: nothing embeds it
# into a hand-assembled bundle, so the app would launch to a missing-library
# crash on any machine but this one. ditto preserves the framework's version
# symlinks, which cp flattens and codesign then rejects.
ditto "$BINPATH/Sparkle.framework" "$STAGE/Contents/Frameworks/Sparkle.framework"

# The linked binary carries no @executable_path rpath, so @rpath/Sparkle.framework
# resolves nowhere once bundled. Added here rather than through unsafeFlags in
# Package.swift, which would bar this package from ever being a dependency.
install_name_tool -add_rpath @executable_path/../Frameworks "$STAGE/Contents/MacOS/RollScrub"

cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>RollScrub</string>
  <key>CFBundleDisplayName</key>       <string>RollScrub</string>
  <key>CFBundleIdentifier</key>        <string>com.rollscrub.RollScrub</string>
  <key>CFBundleExecutable</key>        <string>RollScrub</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key>           <string>$BUILD</string>
  <key>LSMinimumSystemVersion</key>    <string>14.0</string>
  <key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>NSHumanReadableCopyright</key>  <string>© 2026 Ricardo Sanchez</string>
  <key>NSRemovableVolumesUsageDescription</key>
  <string>RollScrub needs access to your external drive to show and clean up duplicate photos and videos.</string>
  <key>NSDesktopFolderUsageDescription</key>
  <string>RollScrub needs access to look for duplicate photos and videos in this folder.</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>RollScrub needs access to look for duplicate photos and videos in this folder.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>RollScrub needs access to look for duplicate photos and videos in this folder.</string>
  <key>NSPhotoLibraryUsageDescription</key>
  <string>RollScrub needs access to look for duplicate photos and videos in your Photos library.</string>
  <key>SUFeedURL</key>                  <string>https://rollscrub.com/appcast.xml</string>
  <key>SUPublicEDKey</key>              <string>dlmHLAiiatePqkcQyLJwukdlNBTx7ZzPkJxSALTMkVk=</string>
</dict>
</plist>
PLIST

# Extended attributes picked up from the build tree make codesign refuse with
# "resource fork, Finder information, or similar detritus not allowed".
xattr -cr "$STAGE"

# A Developer ID certificate when one is installed, ad-hoc otherwise so local
# builds keep working. Only a Developer ID signature carrying the hardened
# runtime can be notarized, and Apple's timestamp server has to be reachable —
# an un-timestamped signature stops validating the day the certificate expires.
#
# The identifier is pinned either way: macOS keys granted folder access to it,
# and letting it drift makes every rebuild re-ask for your drives.
SIGN_IDENTITY="${SIGN_IDENTITY:-$(
  security find-identity -v -p codesigning |
    awk -F'"' '/Developer ID Application/ { print $2; exit }'
)}"

sign() {  # sign <path> [extra codesign args...]
  local target="$1"; shift
  if [ -n "$SIGN_IDENTITY" ]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$@" "$target"
  else
    codesign --force --sign - "$@" "$target"
  fi
}

# Signing runs deepest-first. Signing the outer bundle seals a hash of
# everything inside it, so anything signed afterwards invalidates the outer
# signature — which surfaces much later as a notarization rejection rather
# than an error here. Sparkle's helpers are separate executables and each
# needs its own signature.
SPARKLE="$STAGE/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SPARKLE/XPCServices/Downloader.xpc"
sign "$SPARKLE/XPCServices/Installer.xpc"
sign "$SPARKLE/Updater.app"
sign "$SPARKLE/Autoupdate"
sign "$STAGE/Contents/Frameworks/Sparkle.framework"
sign "$STAGE" --identifier com.rollscrub.RollScrub

if [ -n "$SIGN_IDENTITY" ]; then
  echo "signed: $SIGN_IDENTITY"
else
  echo "signed: ad-hoc — fine on this Mac, but not distributable and not notarizable."
  echo "        Install a Developer ID Application certificate to ship it."
fi

# Catches a broken nesting order or an unsigned helper now, not at notarization.
codesign --verify --deep --strict "$STAGE"

if [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
  echo "note: /Applications not writable, installing to $DEST"
fi

rm -rf "${DEST:?}/$APP_NAME"
cp -R "$STAGE" "$DEST/$APP_NAME"

echo "Installed $DEST/$APP_NAME"
