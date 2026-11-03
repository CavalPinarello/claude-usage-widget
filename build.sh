#!/bin/bash
# Builds Claude Usage.app into ~/Applications and (re)starts it.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$DIR/Sources/main.swift"
APP="$HOME/Applications/Claude Usage.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

echo "→ stopping any running copy"
# Stop by PID, matched on the exact executable name: `pkill -f` matches any
# process whose arguments merely contain the string.
for PID in $(pgrep -x ClaudeUsage); do
  case "$(ps -o command= -p "$PID")" in
    *"Claude Usage.app/Contents/MacOS/ClaudeUsage"*) kill "$PID" ;;
  esac
done
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -qx ClaudeUsage || break; sleep 0.3; done

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
  -o "$MACOS/ClaudeUsage" "$SRC"

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
