#!/bin/bash
set -euo pipefail

APP_NAME="Loopscape"
VERSION="1.5"
VOLUME="${APP_NAME} ${VERSION}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="$HERE/.build/dmg"
RAW="$HERE/.build/${APP_NAME}-rw.dmg"
OUT="$HERE/.build/${APP_NAME}-${VERSION}.dmg"

"$HERE/build.sh" --dest "$STAGE"

echo "==> staging"
rm -f "$STAGE/Applications"
ln -s /Applications "$STAGE/Applications"

echo "==> creating image"
rm -f "$RAW" "$OUT"
hdiutil create -volname "$VOLUME" -srcfolder "$STAGE" -ov \
    -fs HFS+ -format UDRW "$RAW" >/dev/null

MOUNT="$(hdiutil attach "$RAW" -readwrite -noverify -noautoopen | \
    grep -Eo '/Volumes/.*$' | head -1)"

# Cosmetic only: without Finder automation the image still mounts and still works,
# the two icons just land wherever Finder decides.
osascript <<APPLESCRIPT >/dev/null 2>&1 || echo "    (Finder layout skipped)"
tell application "Finder"
  tell disk "$VOLUME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 150, 800, 540}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 128
    set position of item "${APP_NAME}.app" of container window to {150, 190}
    set position of item "Applications" of container window to {450, 190}
    close
    open
    update without registering applications
    delay 2
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT" >/dev/null

echo "==> compressing"
hdiutil convert "$RAW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
rm -f "$RAW"

echo "==> done: $OUT ($(du -h "$OUT" | cut -f1))"
