#!/bin/bash
# Usage:
#   ./build.sh              build, install to /Applications, start at login
#   ./build.sh --dest DIR   build the bundle into DIR and stop (used by make-dmg.sh)
set -euo pipefail

APP_NAME="Loopscape"
BUNDLE_ID="com.aklimoff.loopscape"
VERSION="1.0"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEST="/Applications"
INSTALL=1
if [[ "${1:-}" == "--dest" ]]; then
    DEST="${2:?--dest needs a directory}"
    INSTALL=0
    mkdir -p "$DEST"
fi
APP="${DEST}/${APP_NAME}.app"

mkdir -p "$HERE/.build"

if [[ ! -f "$HERE/${APP_NAME}.icns" ]]; then
    echo "==> rendering icon"
    swiftc -swift-version 5 -o "$HERE/.build/makeicon" "$HERE/make-icon.swift"
    "$HERE/.build/makeicon" "$HERE/.build/icon1024.png"
    ICONSET="$HERE/.build/${APP_NAME}.iconset"
    rm -rf "$ICONSET"; mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z $s $s "$HERE/.build/icon1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s*2)) $((s*2)) "$HERE/.build/icon1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$HERE/${APP_NAME}.icns"
fi

echo "==> compiling"
swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 \
    -o "$HERE/.build/${APP_NAME}" "$HERE/${APP_NAME}.swift"

echo "==> assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$HERE/.build/${APP_NAME}" "$APP/Contents/MacOS/${APP_NAME}"
cp "$HERE/${APP_NAME}.icns" "$APP/Contents/Resources/${APP_NAME}.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIconFile</key><string>${APP_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force -s - "$APP"

if [[ $INSTALL -eq 0 ]]; then
    echo "==> built ${APP}"
    exit 0
fi

# A hand-assembled bundle stays invisible to Spotlight until it is registered.
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$APP"

echo "==> installing launch agent"
AGENT="$HOME/Library/LaunchAgents/${BUNDLE_ID}.plist"
mkdir -p "$(dirname "$AGENT")" "$HOME/Library/Application Support/${APP_NAME}/videos"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${BUNDLE_ID}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${APP}/Contents/MacOS/${APP_NAME}</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/${BUNDLE_ID}" 2>/dev/null || true
# bootout is asynchronous; the single-instance guard would make a new process exit if the
# old one is still winding down.
sleep 2
launchctl bootstrap "gui/$(id -u)" "$AGENT"

echo "==> done, ${APP_NAME} is running from ${APP}"
