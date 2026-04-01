#!/bin/bash
# full release pipeline: bump version, build, notarize, upload, update appcast + cask
# usage: ./scripts/release.sh <version>
# example: ./scripts/release.sh 0.2.0
set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

APP_NAME="HyprMac"
BUILD_DIR="$PROJECT_DIR/build"
DIST_DIR="$PROJECT_DIR/dist"
APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
REPO="zacharytgray/HyprMac"
SPARKLE_BIN="$BUILD_DIR/SourcePackages/artifacts/sparkle/Sparkle/bin"

NEW_VERSION="${1:?Usage: ./scripts/release.sh <version>}"

# require DEVELOPMENT_TEAM
if [ -z "$DEVELOPMENT_TEAM" ]; then
    echo "ERROR: DEVELOPMENT_TEAM not set."
    echo "  export DEVELOPMENT_TEAM=YOUR_TEAM_ID"
    exit 1
fi

DMG_NAME="$APP_NAME-$NEW_VERSION.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

echo ""
echo "=== HyprMac Release v$NEW_VERSION ==="
echo ""

# --- step 1: bump version in project.yml ---
echo "[1/7] Bumping version to $NEW_VERSION"
sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$NEW_VERSION\"/" project.yml

# bump build number
OLD_BUILD=$(grep 'CURRENT_PROJECT_VERSION' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
NEW_BUILD=$((OLD_BUILD + 1))
sed -i '' "s/CURRENT_PROJECT_VERSION: \"$OLD_BUILD\"/CURRENT_PROJECT_VERSION: \"$NEW_BUILD\"/" project.yml

# --- step 2: regenerate xcode project ---
echo "[2/7] Regenerating Xcode project"
xcodegen generate 2>&1 | tail -1

# --- step 3: build, sign, create DMG, notarize ---
echo "[3/7] Building release"
mkdir -p "$DIST_DIR"
security unlock-keychain ~/Library/Keychains/login.keychain-db 2>/dev/null || true

xcodebuild \
    -project HyprMac.xcodeproj \
    -scheme HyprMac \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    CODE_SIGN_STYLE=Manual \
    ENABLE_HARDENED_RUNTIME=YES \
    CODE_SIGN_ENTITLEMENTS="$PROJECT_DIR/HyprMac/HyprMac-Release.entitlements" \
    build 2>&1 | grep -E '(error:|BUILD)' || true

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: Build failed"
    exit 1
fi

echo "       Creating DMG"
rm -f "$DMG_PATH"
STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG_PATH" 2>&1 | tail -1

rm -rf "$STAGING"

echo "       Notarizing"
if xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "HyprMac" \
    --wait 2>&1 | tail -3; then
    xcrun stapler staple "$DMG_PATH" 2>&1 | tail -1
    echo "       ✓ Signed and notarized"
else
    echo ""
    echo "WARNING: Notarization failed. DMG is at $DMG_PATH but is NOT notarized."
    echo "You may need to run: xcrun notarytool store-credentials HyprMac"
    echo ""
    read -p "Continue with un-notarized DMG? (y/N) " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] || exit 1
fi

# --- step 4: upload to GitHub Release ---
echo "[4/7] Creating GitHub Release v$NEW_VERSION"
gh release create "v$NEW_VERSION" "$DMG_PATH" \
    --repo "$REPO" \
    --title "HyprMac v$NEW_VERSION" \
    --generate-notes

# --- step 5: generate Sparkle appcast ---
echo "[5/7] Generating Sparkle appcast"
if [ -x "$SPARKLE_BIN/generate_appcast" ]; then
    "$SPARKLE_BIN/generate_appcast" "$DIST_DIR" --download-url-prefix "https://github.com/$REPO/releases/download/v$NEW_VERSION/"
    # move appcast to docs/ for GitHub Pages
    mkdir -p "$PROJECT_DIR/docs"
    cp "$DIST_DIR/appcast.xml" "$PROJECT_DIR/docs/appcast.xml"
    echo "       ✓ appcast.xml updated"
else
    echo "       WARNING: Sparkle generate_appcast not found at $SPARKLE_BIN"
    echo "       Run a debug build first to resolve SPM packages, then retry."
fi

# --- step 6: update Homebrew cask ---
echo "[6/7] Updating Homebrew cask"
DMG_SHA=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
sed -i '' "s/version \".*\"/version \"$NEW_VERSION\"/" "$PROJECT_DIR/Casks/hyprmac.rb"
sed -i '' "s/sha256 \".*\"/sha256 \"$DMG_SHA\"/" "$PROJECT_DIR/Casks/hyprmac.rb"
echo "       ✓ Cask updated (sha256: ${DMG_SHA:0:16}...)"

# --- step 7: commit and push ---
echo "[7/7] Committing and pushing"
git add project.yml HyprMac.xcodeproj/project.pbxproj Casks/hyprmac.rb docs/appcast.xml 2>/dev/null || true
git commit -m "Release v$NEW_VERSION" 2>/dev/null || echo "       (nothing to commit)"
git push

echo ""
echo "=== Release v$NEW_VERSION complete ==="
echo "  DMG:     $DMG_PATH"
echo "  Release: https://github.com/$REPO/releases/tag/v$NEW_VERSION"
echo "  Cask:    brew install --cask hyprmac (after tap update)"
echo ""
