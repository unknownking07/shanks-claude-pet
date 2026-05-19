#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/build/Shanks.app"
CONTENTS="$APP_DIR/Contents"

echo "→ Building release binary..."
cd "$ROOT"
swift build -c release 2>&1 | grep -v "^Build complete" | grep -v "^warning:" || true
swift build -c release --quiet

BIN_PATH="$(swift build -c release --show-bin-path)"
BINARY="$BIN_PATH/Clawd"
RESOURCE_BUNDLE="$BIN_PATH/Clawd_Clawd.bundle"

if [ ! -f "$BINARY" ]; then
    echo "✗ Binary not found at $BINARY"
    exit 1
fi

echo "→ Assembling Shanks.app..."
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS"
mkdir -p "$CONTENTS/Resources"

cp -X "$BINARY" "$CONTENTS/MacOS/Clawd"

# Copy resource bundle (sprites, icons, assets)
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -RX "$RESOURCE_BUNDLE" "$CONTENTS/Resources/"
fi


# Write Info.plist
cat > "$CONTENTS/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Shanks</string>
    <key>CFBundleDisplayName</key>
    <string>Shanks</string>
    <key>CFBundleIdentifier</key>
    <string>com.shanks.app</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleExecutable</key>
    <string>Clawd</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSUserNotificationAlertStyle</key>
    <string>alert</string>
</dict>
</plist>
PLIST

echo "→ Stripping extended attributes..."
find "$APP_DIR" -name '._*' -delete 2>/dev/null || true
find "$APP_DIR" -type f -exec xattr -c {} + 2>/dev/null || true
find "$APP_DIR" -type d -exec xattr -c {} + 2>/dev/null || true
xattr -cr "$APP_DIR" 2>/dev/null || true

# Also strip resource forks
find "$APP_DIR" -type f -exec /usr/bin/xattr -d com.apple.ResourceFork {} + 2>/dev/null || true
find "$APP_DIR" -type f -exec /usr/bin/xattr -d com.apple.FinderInfo {} + 2>/dev/null || true

echo "→ Ad-hoc signing..."
codesign --force --deep --sign - "$APP_DIR"

echo "→ Installing to /Applications..."
rm -rf "/Applications/Shanks.app"
cp -R "$APP_DIR" "/Applications/Shanks.app"

echo ""
echo "✓ Done. Shanks.app is in /Applications."
echo "  Open it with: open /Applications/Shanks.app"
echo ""
echo "  To enable Launch on Login, open the app and check the menu bar icon."
