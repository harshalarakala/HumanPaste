#!/bin/zsh
set -euo pipefail

APP_NAME="HumanPaste"
PRODUCT_DIR="$(pwd)/dist"
APP_DIR="$PRODUCT_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RES_DIR="$CONTENTS_DIR/Resources"
PLIST="$CONTENTS_DIR/Info.plist"
DOCS_DIR="$(pwd)/docs"

echo "Cleaning dist..."
rm -rf "$PRODUCT_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"

echo "Compiling Swift..."
swiftc -O -sdk $(xcrun --show-sdk-path --sdk macosx) -parse-as-library \
  -framework Cocoa -framework Carbon \
  -o "$MACOS_DIR/$APP_NAME" \
  human_paste.swift

echo "Writing Info.plist..."
cat > "$PLIST" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>HumanPaste</string>
  <key>CFBundleDisplayName</key>
  <string>HumanPaste</string>
  <key>CFBundleIdentifier</key>
  <string>dev.local.humanpaste</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleExecutable</key>
  <string>HumanPaste</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>11.0</string>
  <key>LSUIElement</key>
  <false/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSMainNibFile</key>
  <string></string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Needed to send keystrokes for human-like paste.</string>
  <key>NSHumanReadableCopyright</key>
  <string>© 2025</string>
</dict>
</plist>
PLIST

echo "Adding app icon placeholder..."
touch "$RES_DIR/AppIcon.icns"

echo "Ad-hoc signing..."
codesign --force --deep --sign - "$APP_DIR"

echo "Built: $APP_DIR"
echo "Run with: open \"$APP_DIR\""

echo "Creating DMG..."
DMG="$PRODUCT_DIR/$APP_NAME.dmg"
APP_TMP="$PRODUCT_DIR/$APP_NAME-tmp"
rm -rf "$DMG" "$APP_TMP"
mkdir -p "$APP_TMP"
cp -R "$APP_DIR" "$APP_TMP/"
hdiutil create -volname "$APP_NAME" -srcfolder "$APP_TMP" -ov -format UDZO "$DMG" >/dev/null
echo "DMG created: $DMG"

# Update GitHub Pages docs with latest DMG
mkdir -p "$DOCS_DIR"
cp -f "$DMG" "$DOCS_DIR/$APP_NAME.dmg"
if [ ! -f "$DOCS_DIR/index.html" ]; then
  cat > "$DOCS_DIR/index.html" << 'HTML'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width,initial-scale=1" />
    <title>HumanPaste for macOS</title>
    <style>
      body{font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,Helvetica,Arial,sans-serif;margin:40px;color:#111}
      .card{max-width:720px;margin:0 auto;padding:24px;border:1px solid #e5e7eb;border-radius:12px;box-shadow:0 2px 10px rgba(0,0,0,.04)}
      h1{margin-top:0;font-size:28px}
      a.btn{display:inline-block;background:#111;color:#fff;text-decoration:none;padding:12px 16px;border-radius:8px}
      .muted{color:#6b7280;font-size:14px;margin-top:8px}
      code{background:#f3f4f6;padding:2px 6px;border-radius:6px}
    </style>
  </head>
  <body>
    <div class="card">
      <h1>HumanPaste</h1>
      <p>Human-like Cmd+V for macOS. Intercepts paste and types your clipboard with realistic keystrokes.</p>
      <p>
        <a class="btn" href="HumanPaste.dmg">Download latest DMG</a>
      </p>
      <p class="muted">After download: move the app to <code>/Applications</code>, then grant Accessibility and Input Monitoring permissions in System Settings → Privacy &amp; Security.</p>
      <p class="muted">Source: <a href="https://github.com/harshalarakala/HumanPaste">github.com/harshalarakala/HumanPaste</a></p>
    </div>
  </body>
  </html>
HTML
fi
