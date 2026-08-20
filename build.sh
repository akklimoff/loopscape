#!/bin/bash
set -euo pipefail

APP_NAME="Loopscape"
BUNDLE_ID="com.aklimoff.loopscape"
APP="/Applications/${APP_NAME}.app"
AGENT="$HOME/Library/LaunchAgents/${BUNDLE_ID}.plist"
DATA="$HOME/Library/Application Support/${APP_NAME}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> compiling"
swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 \
    -o "$HERE/.build/${APP_NAME}" "$HERE/${APP_NAME}.swift"

echo "==> assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$HERE/.build/${APP_NAME}" "$APP/Contents/MacOS/${APP_NAME}"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force -s - "$APP"

# A hand-assembled bundle stays invisible to Spotlight until it is registered.
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$APP"

echo "==> installing launch agent"
mkdir -p "$(dirname "$AGENT")" "$DATA/videos"
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
