#!/bin/bash
# Removes the app, the login item, and nothing else. Your Claude Code login is
# untouched — this tool never wrote to the Keychain.
set -uo pipefail
LABEL="com.claudeusage.widget"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
pkill -f "Claude Usage.app/Contents/MacOS/ClaudeUsage" 2>/dev/null
pkill -f "Headroom.app/Contents/MacOS/Headroom" 2>/dev/null
rm -rf "$HOME/Applications/Claude Usage.app" "$HOME/Applications/Headroom.app"
echo "✓ removed Headroom.app, its login item, and its LaunchAgent"
