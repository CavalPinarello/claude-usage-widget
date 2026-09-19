#!/bin/bash
# Builds Claude Usage.app into ~/Applications and (re)starts it.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$DIR/Sources"
APP="$HOME/Applications/Claude Usage.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

echo "→ stopping any running copy"
pkill -f "Claude Usage.app/Contents/MacOS/ClaudeUsage" 2>/dev/null || true
sleep 0.4

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Xcode command line tools are required:  xcode-select --install" >&2
  exit 1
fi

echo "→ building"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"
# Pin the deployment target so the compiler enforces macOS 13 availability.
swiftc -O -target "$(uname -m)-apple-macos13.0" \
  -framework Cocoa \
  -o "$MACOS/ClaudeUsage" "$SRC"/*.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude Usage</string>
  <key>CFBundleDisplayName</key><string>Claude Usage</string>
  <key>CFBundleExecutable</key><string>ClaudeUsage</string>
  <key>CFBundleIdentifier</key><string>com.claudeusage.widget</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "→ signing (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo "→ launching"
open -a "$APP"
echo "✓ $APP"
