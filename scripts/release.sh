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
echo "[1/8] Bumping version to $NEW_VERSION"
sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$NEW_VERSION\"/" project.yml

# bump build number
OLD_BUILD=$(grep 'CURRENT_PROJECT_VERSION' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
NEW_BUILD=$((OLD_BUILD + 1))
sed -i '' "s/CURRENT_PROJECT_VERSION: \"$OLD_BUILD\"/CURRENT_PROJECT_VERSION: \"$NEW_BUILD\"/" project.yml

# --- step 2: regenerate xcode project ---
echo "[2/8] Regenerating Xcode project"
xcodegen generate 2>&1 | tail -1

# --- step 3: run tests ---
# gate placed before signing/notarization/upload so a red test aborts the
# release before any expensive or externally visible step runs. Debug
# configuration keeps tests fast; separate derivedDataPath so test
# artifacts don't pollute the Release build directory used downstream.
echo "[3/8] Running tests"
TEST_OUT=$(mktemp)
if xcodebuild test \
    -project HyprMac.xcodeproj \
    -scheme HyprMac \
    -configuration Debug \
    -derivedDataPath "$BUILD_DIR/test" \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | tee "$TEST_OUT" | grep -E "Test Suite '.*\.xctest'|Executed [0-9]+ tests" | tail -2; then
    SUMMARY=$(grep -E '^[[:space:]]*Executed [0-9]+ tests' "$TEST_OUT" | tail -1)
    if echo "$SUMMARY" | grep -q '0 failures'; then
        echo "       ✓ $SUMMARY"
    else
        echo ""
        echo "ERROR: Tests failed. Aborting release before signing/notarization/upload."
        echo "       $SUMMARY"
        rm -f "$TEST_OUT"
        exit 1
    fi
else
    echo ""
    echo "ERROR: Test build failed. Aborting release."
    rm -f "$TEST_OUT"
    exit 1
fi
rm -f "$TEST_OUT"

# --- step 4: build, sign, create DMG, notarize ---
echo "[4/8] Building release"
mkdir -p "$DIST_DIR"
# unlock keychain and pre-authorize codesign so we don't get 20+ password prompts.
# set-key-partition-list grants codesign access to the signing key for this session.
echo "       Unlocking keychain"
if [ -n "$KEYCHAIN_PASSWORD" ]; then
    KC_PASS="$KEYCHAIN_PASSWORD"
else
    read -s -p "       Keychain password: " KC_PASS; echo
fi
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
security unlock-keychain -p "$KC_PASS" "$KEYCHAIN"
# grant codesign + productbuild + timestamp access to all signing keys
security set-key-partition-list -S apple-tool:,apple:,codesign:,productbuild:,timestamp: \
    -s -k "$KC_PASS" "$KEYCHAIN" >/dev/null 2>&1
unset KC_PASS

xcodebuild \
    -project HyprMac.xcodeproj \
    -scheme HyprMac \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    CODE_SIGN_STYLE=Manual \
    ENABLE_HARDENED_RUNTIME=YES \
    OTHER_CODE_SIGN_FLAGS="--timestamp --keychain $KEYCHAIN" \
    CODE_SIGN_ENTITLEMENTS="$PROJECT_DIR/HyprMac/HyprMac-Release.entitlements" \
    build 2>&1 | grep -E '(error:|BUILD)' || true

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: Build failed"
    exit 1
fi

# re-sign all nested binaries (Sparkle helpers) with Developer ID + timestamp
echo "       Re-signing nested frameworks"
SIGN_ID="Developer ID Application: Zachary Gray (WYY8494SWG)"
find "$APP_PATH/Contents/Frameworks" -type f -perm +111 -o -name "*.dylib" | while read bin; do
    codesign --force --sign "$SIGN_ID" --keychain "$KEYCHAIN" --timestamp --options runtime "$bin" 2>/dev/null || true
done
# re-sign XPC services and .app bundles inside frameworks
find "$APP_PATH/Contents/Frameworks" -name "*.xpc" -o -name "*.app" | while read bundle; do
    codesign --force --deep --sign "$SIGN_ID" --keychain "$KEYCHAIN" --timestamp --options runtime "$bundle" 2>/dev/null || true
done
# re-sign the framework itself
find "$APP_PATH/Contents/Frameworks" -name "*.framework" | while read fw; do
    codesign --force --sign "$SIGN_ID" --keychain "$KEYCHAIN" --timestamp --options runtime "$fw" 2>/dev/null || true
done
# re-sign the main app last
codesign --force --sign "$SIGN_ID" --keychain "$KEYCHAIN" --timestamp --options runtime \
    --entitlements "$PROJECT_DIR/HyprMac/HyprMac-Release.entitlements" \
    "$APP_PATH"

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

# --- step 5: upload to GitHub Release ---
echo "[5/8] Creating GitHub Release v$NEW_VERSION"
gh release create "v$NEW_VERSION" "$DMG_PATH" \
    --repo "$REPO" \
    --title "HyprMac v$NEW_VERSION" \
    --generate-notes

# --- step 6: generate Sparkle appcast ---
echo "[6/8] Generating Sparkle appcast"
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

# --- step 7: update Homebrew cask ---
echo "[7/8] Updating Homebrew cask"
DMG_SHA=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
# update local copy
sed -i '' "s/version \".*\"/version \"$NEW_VERSION\"/" "$PROJECT_DIR/Casks/hyprmac.rb"
sed -i '' "s/sha256 \".*\"/sha256 \"$DMG_SHA\"/" "$PROJECT_DIR/Casks/hyprmac.rb"
# push to homebrew tap repo
TAP_DIR="$(brew --repository zacharytgray/hyprmac 2>/dev/null || echo "")"
if [ -n "$TAP_DIR" ] && [ -d "$TAP_DIR" ]; then
    cp "$PROJECT_DIR/Casks/hyprmac.rb" "$TAP_DIR/Casks/hyprmac.rb"
    git -C "$TAP_DIR" add Casks/hyprmac.rb
    git -C "$TAP_DIR" commit -m "Update HyprMac to v$NEW_VERSION" 2>/dev/null || true
    git -C "$TAP_DIR" push 2>/dev/null || true
    echo "       ✓ Tap repo updated"
else
    # tap not installed locally — push via temp clone
    TEMP_TAP="/tmp/homebrew-hyprmac-update"
    rm -rf "$TEMP_TAP"
    git clone --depth 1 "https://github.com/zacharytgray/homebrew-hyprmac.git" "$TEMP_TAP" 2>/dev/null
    cp "$PROJECT_DIR/Casks/hyprmac.rb" "$TEMP_TAP/Casks/hyprmac.rb"
    git -C "$TEMP_TAP" add Casks/hyprmac.rb
    git -C "$TEMP_TAP" commit -m "Update HyprMac to v$NEW_VERSION" 2>/dev/null || true
    git -C "$TEMP_TAP" push 2>/dev/null || true
    rm -rf "$TEMP_TAP"
    echo "       ✓ Tap repo updated (via temp clone)"
fi
echo "       ✓ Cask updated (sha256: ${DMG_SHA:0:16}...)"

# --- step 8: commit and push ---
echo "[8/8] Committing and pushing"
git add project.yml HyprMac.xcodeproj/project.pbxproj Casks/hyprmac.rb docs/appcast.xml scripts/build-release.sh scripts/release.sh 2>/dev/null || true
git commit -m "Release v$NEW_VERSION" 2>/dev/null || echo "       (nothing to commit)"
git push

echo ""
echo "=== Release v$NEW_VERSION complete ==="
echo "  DMG:     $DMG_PATH"
echo "  Release: https://github.com/$REPO/releases/tag/v$NEW_VERSION"
echo "  Cask:    brew install --cask hyprmac (after tap update)"
echo ""
