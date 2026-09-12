#!/bin/bash
# Notarizes RollScrub.app with Apple and staples the ticket to the bundle.
#
# Stapling is the part people skip and regret: without it the app only passes
# Gatekeeper while the machine can reach Apple to ask about it, so the first
# person to open it on a flaky connection gets "cannot be opened".
#
# One-time setup — store an app-specific password (appleid.apple.com →
# Sign-In and Security → App-Specific Passwords), NOT your Apple ID password.
# Use the Apple ID that owns the Developer Program membership:
#
#   xcrun notarytool store-credentials "rollscrub-notary" \
#     --apple-id "<your-developer-apple-id>" \
#     --team-id "R398R96429"
#
# Then: ./make-app.sh && ./notarize.sh
set -euo pipefail

APP="${1:-/Applications/RollScrub.app}"
PROFILE="${NOTARY_PROFILE:-rollscrub-notary}"

die() { echo "error: $*" >&2; exit 1; }

[ -d "$APP" ] || die "no app bundle at $APP (run ./make-app.sh first)"

# An ad-hoc signature is accepted locally and rejected by notarization with a
# far less obvious message, so catch it here. Ad-hoc carries no Authority line
# at all, which is why it is tested separately rather than as an empty name.
SIGINFO="$(codesign -dvv "$APP" 2>&1)" || die "$APP is not signed at all."
AUTHORITY="$(printf '%s\n' "$SIGINFO" | awk -F= '/^Authority=/ { print $2; exit }')"

# Matched with case rather than `grep -q`: under `set -o pipefail`, grep -q
# exits at the first match and SIGPIPEs the writer, so the pipeline reports
# failure precisely when the pattern was found.
case "$SIGINFO" in
  *"Signature=adhoc"*)
    die "$APP is ad-hoc signed, which Apple will not notarize.
       Install a Developer ID Application certificate, then re-run ./make-app.sh.
       Check what you have: security find-identity -v -p codesigning" ;;
esac

case "$AUTHORITY" in
  "Developer ID Application"*) ;;
  "") die "$APP carries no signing authority. Re-run ./make-app.sh with a Developer ID certificate installed." ;;
  *) die "$APP is signed by '$AUTHORITY', not a Developer ID Application certificate.
       Notarization needs Developer ID. Check: security find-identity -v -p codesigning" ;;
esac

case "$SIGINFO" in
  *"flags="*"(runtime)"*) ;;
  *) die "$APP is not signed with the hardened runtime (--options runtime). Rebuild with ./make-app.sh." ;;
esac

xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  || die "no stored credentials named '$PROFILE'. See the setup comment at the top of this script."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ZIP="$WORK/RollScrub.zip"

# ditto, not zip: it preserves the bundle's symlinks and resource layout, and a
# plain zip produces an archive notarization rejects as malformed.
echo "==> packaging"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> submitting to Apple (this usually takes a few minutes)"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "==> stapling the ticket"
xcrun stapler staple "$APP"

echo "==> verifying"
xcrun stapler validate "$APP"
spctl -a -vvv -t exec "$APP"

echo
echo "Notarized and stapled: $APP"
echo "This bundle now opens on any Mac without a Gatekeeper warning, offline included."
