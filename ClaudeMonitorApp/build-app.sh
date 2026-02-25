#!/bin/bash
# Build Claude Monitor as a .app bundle using swiftc directly (no Xcode project needed)
# Produces ClaudeMonitorApp.app with proper Info.plist for UNUserNotificationCenter

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SWIFT_FILE="$REPO_DIR/claude_monitor.swift"
APP_DIR="$SCRIPT_DIR/build/ClaudeMonitorApp.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
INSTALL_DIR="$HOME/.claude/monitor"

echo "Building Claude Monitor app bundle..."

# Clean previous build
rm -rf "$SCRIPT_DIR/build"
mkdir -p "$MACOS_DIR"

# Compile
swiftc "$SWIFT_FILE" \
    -o "$MACOS_DIR/ClaudeMonitorApp" \
    -framework Cocoa \
    -framework SwiftUI \
    -framework Combine \
    -framework UserNotifications \
    -parse-as-library \
    -suppress-warnings \
    2>&1

if [ $? -ne 0 ]; then
    echo "Build failed!"
    exit 1
fi

# Copy Info.plist
cp "$SCRIPT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"

echo "Build successful: $APP_DIR"

# Kill existing instance if running
pkill -f "ClaudeMonitorApp$" 2>/dev/null || true
sleep 0.5

# Install to ~/.claude/monitor/
echo "Installing to $INSTALL_DIR..."
rm -rf "$INSTALL_DIR/ClaudeMonitorApp.app"
cp -R "$APP_DIR" "$INSTALL_DIR/ClaudeMonitorApp.app"

# Launch
echo "Launching Claude Monitor app..."
open "$INSTALL_DIR/ClaudeMonitorApp.app"

echo "Claude Monitor app is running."
