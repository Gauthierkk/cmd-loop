#!/bin/bash
set -e

echo "Stopping cmdloop..."
launchctl unload ~/Library/LaunchAgents/com.cmdloop.plist 2>/dev/null || true

echo "Removing files..."
rm -f ~/Library/LaunchAgents/com.cmdloop.plist
rm -f /usr/local/bin/cmdloop

echo "Done! cmdloop has been uninstalled."
