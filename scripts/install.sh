#!/bin/zsh
# Build, wrap, and install Studio Audio Lane into /Applications.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="/Applications/Studio Audio Lane.app"
BUNDLE_ID="dev.maxkongerskov.StudioAudioLane"

"$ROOT/scripts/bundle.sh"
APP="$ROOT/.build/StudioAudioLane.app"

if pgrep -f "${BUNDLE_ID}|StudioAudioLane.app/Contents/MacOS/StudioAudioLane" >/dev/null 2>&1; then
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in {1..20}; do
    pgrep -f "StudioAudioLane.app/Contents/MacOS/StudioAudioLane" >/dev/null 2>&1 || break
    sleep 0.2
  done
  if pgrep -f "StudioAudioLane.app/Contents/MacOS/StudioAudioLane" >/dev/null 2>&1; then
    pkill -TERM -f "StudioAudioLane.app/Contents/MacOS/StudioAudioLane" || true
    sleep 0.3
  fi
fi

if [ -e "$DEST" ]; then
  TRASH="$HOME/.Trash/Studio Audio Lane.app.$(date +%s)"
  mv "$DEST" "$TRASH"
fi
ditto "$APP" "$DEST"
xattr -cr "$DEST" 2>/dev/null || true
codesign --force --deep --sign - "$DEST"
touch "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
open "$DEST"
echo "installed $DEST"
