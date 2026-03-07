#!/bin/bash
set -e

echo "Building release..."
swift build -c release

echo "Installing binary..."
cp .build/release/cmdloop /usr/local/bin/cmdloop

echo "Installing launch agent..."
cp com.cmdloop.plist ~/Library/LaunchAgents/com.cmdloop.plist
launchctl load ~/Library/LaunchAgents/com.cmdloop.plist

echo "Done! cmdloop is now running and will start on login."
