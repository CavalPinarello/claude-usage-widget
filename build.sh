#!/bin/bash
# Builds Headroom.app (formerly Claude Usage.app) into ~/Applications and (re)starts it.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$DIR/Sources"
APP="$HOME/Applications/Headroom.app"
OLD_APP="$HOME/Applications/Claude Usage.app"   # name until 2026-11-09
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

PLIST="$HOME/Library/LaunchAgents/com.claudeusage.widget.plist"
JOB="gui/$(id -u)/com.claudeusage.widget"

echo "→ stopping any running copy"
# With KeepAlive on, a plain kill makes launchd relaunch the old binary
# mid-build: take the job out of launchd first, then stop strays.
launchctl bootout "$JOB" 2>/dev/null || true
pkill -f "Claude Usage.app/Contents/MacOS/ClaudeUsage" 2>/dev/null || true
pkill -f "Headroom.app/Contents/MacOS/Headroom" 2>/dev/null || true
sleep 0.4

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Xcode command line tools are required:  xcode-select --install" >&2
  exit 1
fi

echo "→ building"
rm -rf "$APP" "$OLD_APP"
mkdir -p "$MACOS" "$RES"
# Pin the deployment target so the compiler enforces macOS 13 availability.
swiftc -O -target "$(uname -m)-apple-macos13.0" \
  -framework Cocoa \
  -o "$MACOS/Headroom" "$SRC"/*.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Headroom</string>
  <key>CFBundleDisplayName</key><string>Headroom</string>
  <key>CFBundleExecutable</key><string>Headroom</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
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

cp "$DIR/bin/claude-usage-models" "$RES/claude-usage-models"
cp "$DIR/Resources/AppIcon.icns" "$RES/AppIcon.icns"    # redraw with: swift tools/make-icon.swift

echo "→ signing (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo "→ launching"
if [ -f "$PLIST" ]; then
  # Open at Login is on: launchd owns the process (and restarts it on a crash).
  # Point the agent at the current executable (it moved with the rename).
  /usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $MACOS/Headroom" "$PLIST"
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
else
  open -a "$APP"
fi
echo "✓ $APP"
