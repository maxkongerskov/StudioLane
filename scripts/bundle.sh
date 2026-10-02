#!/bin/zsh
# Build the release binary and wrap it as .build/StudioAudioLane.app.
# Does not open the app. Sourced by launch.sh and install.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build -c release
BIN="$ROOT/.build/release/StudioAudioLane"
APP="$ROOT/.build/StudioAudioLane.app"
ICON="$ROOT/Resources/AppIcon.icns"
if [[ ! -f "$BIN" ]]; then
  echo "missing binary: $BIN" >&2
  exit 1
fi
if [[ ! -f "$ICON" ]]; then
  echo "missing icon: $ICON" >&2
  exit 1
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>StudioLane</string>
  <key>CFBundleExecutable</key><string>StudioAudioLane</string>
  <key>CFBundleIdentifier</key><string>dev.maxkongerskov.StudioAudioLane</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleName</key><string>StudioLane</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key>
      <string>dev.maxkongerskov.StudioAudioLane.project</string>
      <key>UTTypeDescription</key>
      <string>StudioLane Project</string>
      <key>UTTypeConformsTo</key>
      <array>
        <string>public.json</string>
        <string>public.data</string>
      </array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key>
        <array>
          <string>salproject</string>
        </array>
      </dict>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>StudioLane Project</string>
      <key>CFBundleTypeRole</key>
      <string>Editor</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>dev.maxkongerskov.StudioAudioLane.project</string>
      </array>
      <key>LSHandlerRank</key>
      <string>Owner</string>
    </dict>
  </array>
</dict>
</plist>
PLIST
cp "$BIN" "$APP/Contents/MacOS/StudioAudioLane"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$APP/Contents/MacOS/StudioAudioLane"
codesign --force --deep --sign - "$APP"
