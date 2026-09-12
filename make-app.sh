#!/bin/bash
# Builds DupSweep.app and installs it to a single canonical location.
#
# SwiftPM leaves loose executables in .build (debug/ and release/ copies of
# both the GUI and the CLI), which Spotlight happily indexes — so searching
# for "dupsweep" turns up four things that all look launchable. This script
# keeps exactly one installed app and tells Spotlight to ignore the rest.
set -euo pipefail

cd "$(dirname "$0")"
DEST="${1:-/Applications}"
APP_NAME="DupSweep.app"
STAGE=".build/stage/$APP_NAME"

# Keep build artifacts out of Spotlight so only the installed app is findable.
mkdir -p .build
touch .build/.metadata_never_index

swift build -c release --product DupSweepApp
BIN="$(swift build -c release --product DupSweepApp --show-bin-path)/DupSweepApp"

rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/DupSweep"

cat > "$STAGE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>DupSweep</string>
  <key>CFBundleDisplayName</key>       <string>DupSweep</string>
  <key>CFBundleIdentifier</key>        <string>local.dupsweep.review</string>
  <key>CFBundleExecutable</key>        <string>DupSweep</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key>           <string>1</string>
  <key>LSMinimumSystemVersion</key>    <string>14.0</string>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>NSRemovableVolumesUsageDescription</key>
  <string>DupSweep needs access to your external drive to show and clean up duplicate photos and videos.</string>
</dict>
</plist>
PLIST

# Extended attributes picked up from the build tree make codesign refuse with
# "resource fork, Finder information, or similar detritus not allowed".
xattr -cr "$STAGE"

# Stable ad-hoc identity, so macOS does not treat each rebuild as a brand new
# app and re-ask for drive access every time.
codesign --force --sign - --identifier local.dupsweep.review "$STAGE"

if [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
  echo "note: /Applications not writable, installing to $DEST"
fi

rm -rf "${DEST:?}/$APP_NAME"
cp -R "$STAGE" "$DEST/$APP_NAME"
rm -rf "$STAGE"

echo "Installed $DEST/$APP_NAME"
