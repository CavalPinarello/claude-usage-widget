#!/bin/bash
# Removes the app, the login item, and nothing else. Your Claude Code login is
# untouched — this tool never wrote to the Keychain.
set -uo pipefail
LABEL="com.claudeusage.widget"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
pkill -f "Claude Usage.app/Contents/MacOS/ClaudeUsage" 2>/dev/null
rm -rf "$HOME/Applications/Claude Usage.app"
echo "✓ removed Claude Usage.app, its login item, and its LaunchAgent"
