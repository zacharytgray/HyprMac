#!/bin/bash
# build and run HyprMac directly (not through Xcode debugger)
set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="HyprMac"
BUILD_DIR="$PROJECT_DIR/build"
APP_PATH="$BUILD_DIR/Build/Products/Debug/$APP_NAME.app"

# DEVELOPMENT_TEAM must be set for code signing
# set it in your shell profile or pass it: DEVELOPMENT_TEAM=XXXX ./scripts/run-debug.sh
if [ -z "$DEVELOPMENT_TEAM" ]; then
    echo "ERROR: DEVELOPMENT_TEAM not set. Export your Apple team ID."
    echo "  export DEVELOPMENT_TEAM=YOUR_TEAM_ID"
    exit 1
fi

# unlock keychain so code signing doesn't prompt for password
security unlock-keychain ~/Library/Keychains/login.keychain-db 2>/dev/null || true

echo "=== Building $APP_NAME ==="
cd "$PROJECT_DIR"

xcodebuild \
    -project HyprMac.xcodeproj \
    -scheme HyprMac \
    -configuration Debug \
    -derivedDataPath "$BUILD_DIR" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    build 2>&1 | grep -E '(error:|BUILD)' || true

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: Build failed"
    exit 1
fi

# clear extended attributes that trigger password prompts
xattr -cr "$APP_PATH" 2>/dev/null

# kill any running instance
pkill -x "$APP_NAME" 2>/dev/null && sleep 0.5

echo "=== Launching $APP_NAME ==="
open "$APP_PATH"
