#!/bin/zsh
# Build a Developer ID–signed StudioLane disk image.
# Notarization runs only when a notarytool keychain profile is set:
#   NOTARY_KEYCHAIN_PROFILE=your-profile ./scripts/dmg.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Use the certificate hash. The display name contains a non-ASCII letter that
# breaks when the identity string is passed through the shell.
SIGN_ID="$(security find-identity -v -p codesigning | awk '/Developer ID Application/ { print $2; exit }')"
if [[ -z "$SIGN_ID" ]]; then
  echo "No Developer ID Application certificate in the login keychain." >&2
  exit 1
fi

"$ROOT/scripts/bundle.sh"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/.build/StudioAudioLane.app/Contents/Info.plist")"

STAGE="$(mktemp -d /tmp/studiolane-dmg.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$ROOT/.build/StudioAudioLane.app" "$STAGE/StudioLane.app"

# Hardened runtime and a timestamp are what Apple expects on a downloadable app.
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$STAGE/StudioLane.app"
codesign --verify --deep --strict --verbose=2 "$STAGE/StudioLane.app"

mkdir -p "$ROOT/dist"
OUT="$ROOT/dist/StudioLane-${VERSION}.dmg"
rm -f "$OUT"

create-dmg \
  --volname "StudioLane" \
  --volicon "$ROOT/Resources/AppIcon.icns" \
  --background "$ROOT/scripts/dmg-background.png" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 128 \
  --icon "StudioLane.app" 160 190 \
  --hide-extension "StudioLane.app" \
  --app-drop-link 440 190 \
  --no-internet-enable \
  "$OUT" \
  "$STAGE"

codesign --force --timestamp --sign "$SIGN_ID" "$OUT"
codesign --verify --verbose=2 "$OUT"

if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
  xcrun stapler staple "$OUT"
  stapler validate "$OUT" || xcrun stapler validate "$OUT"
fi

echo "$OUT"
