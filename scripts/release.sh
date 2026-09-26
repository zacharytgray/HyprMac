#!/bin/bash
# full release pipeline: bump, test, sign, notarize, publish, appcast, and cask
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

APP_NAME="HyprMac"
BUILD_DIR="$PROJECT_DIR/build"
DIST_DIR="$PROJECT_DIR/dist"
APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
REPO="zacharytgray/HyprMac"
SPARKLE_BIN="$BUILD_DIR/SourcePackages/artifacts/sparkle/Sparkle/bin"
SPARKLE_FRAMEWORK="$BUILD_DIR/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework"
NEW_VERSION="${1:?Usage: ./scripts/release.sh <version> [release-notes-file]}"
RELEASE_NOTES_FILE="${2:-}"
DMG_NAME="$APP_NAME-$NEW_VERSION.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
# stable-named copy for the /releases/latest/download link. it lives in
# BUILD_DIR, not DIST_DIR, so generate_appcast never sees it.
STABLE_DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
SOURCE_COMMIT="$(git rev-parse HEAD)"

if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
    echo "ERROR: DEVELOPMENT_TEAM not set." >&2
    exit 1
fi
if [[ -n "$RELEASE_NOTES_FILE" && ! -s "$RELEASE_NOTES_FILE" ]]; then
    echo "ERROR: release notes file is missing or empty: $RELEASE_NOTES_FILE" >&2
    exit 1
fi
if [[ -n "$(git status --porcelain)" || "$(git branch --show-current)" != main ]]; then
    echo "ERROR: release must start from a clean main checkout." >&2
    exit 1
fi
git fetch --prune origin
if [[ "$SOURCE_COMMIT" != "$(git rev-parse origin/main)" ]]; then
    echo "ERROR: origin/main moved or this checkout is not at origin/main." >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/v$NEW_VERSION" >/dev/null \
    || git ls-remote --exit-code --tags origin "refs/tags/v$NEW_VERSION" >/dev/null 2>&1; then
    echo "ERROR: tag v$NEW_VERSION already exists." >&2
    exit 1
fi
if gh release view "v$NEW_VERSION" --repo "$REPO" >/dev/null 2>&1; then
    echo "ERROR: GitHub release v$NEW_VERSION already exists." >&2
    exit 1
fi

echo "=== HyprMac Release v$NEW_VERSION ==="

echo "[1/8] Bumping version to $NEW_VERSION"
sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$NEW_VERSION\"/" project.yml
OLD_BUILD=$(grep 'CURRENT_PROJECT_VERSION' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
NEW_BUILD=$((OLD_BUILD + 1))
sed -i '' "s/CURRENT_PROJECT_VERSION: \"$OLD_BUILD\"/CURRENT_PROJECT_VERSION: \"$NEW_BUILD\"/" project.yml

echo "[2/8] Regenerating Xcode project"
xcodegen generate
echo "       Resolving Sparkle for the isolated test and Release builds"
xcodebuild -resolvePackageDependencies \
    -project HyprMac.xcodeproj \
    -scheme HyprMac \
    -clonedSourcePackagesDirPath "$BUILD_DIR/SourcePackages"
if [[ ! -d "$SPARKLE_FRAMEWORK" || ! -x "$SPARKLE_BIN/generate_appcast" ]]; then
    echo "ERROR: resolved Sparkle artifacts are incomplete under $BUILD_DIR/SourcePackages." >&2
    exit 1
fi

echo "[3/8] Running tests"
TEST_OUT=$(mktemp)
trap 'rm -f "${TEST_OUT:-}" "${BUILD_OUT:-}"' EXIT
if ! scripts/test-isolated.sh "$SPARKLE_FRAMEWORK" >"$TEST_OUT" 2>&1; then
    tail -80 "$TEST_OUT" >&2
    echo "ERROR: test build or test execution failed." >&2
    exit 1
fi
SUMMARY=$(grep -E '^[[:space:]]*Executed [0-9]+ tests' "$TEST_OUT" | tail -1)
if [[ -z "$SUMMARY" || "$SUMMARY" != *"0 failures"* ]]; then
    tail -80 "$TEST_OUT" >&2
    echo "ERROR: passing test summary not found." >&2
    exit 1
fi
echo "       $SUMMARY"

echo "[4/8] Building, signing, packaging, and notarizing"
mkdir -p "$DIST_DIR"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
if [[ -n "${KEYCHAIN_PASSWORD:-}" ]]; then
    echo "       Unlocking keychain"
    KC_PASS="$KEYCHAIN_PASSWORD"
    security unlock-keychain -p "$KC_PASS" "$KEYCHAIN"
    security set-key-partition-list -S apple-tool:,apple:,codesign:,productbuild:,timestamp: \
        -s -k "$KC_PASS" "$KEYCHAIN" >/dev/null
    unset KC_PASS
else
    echo "       Using existing unlocked keychain authorization"
    security show-keychain-info "$KEYCHAIN" >/dev/null
fi

BUILD_OUT=$(mktemp)
if ! xcodebuild \
    -project HyprMac.xcodeproj \
    -scheme HyprMac \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    -clonedSourcePackagesDirPath "$BUILD_DIR/SourcePackages" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    CODE_SIGN_STYLE=Manual \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    ENABLE_HARDENED_RUNTIME=YES \
    OTHER_CODE_SIGN_FLAGS="--timestamp --keychain $KEYCHAIN" \
    CODE_SIGN_ENTITLEMENTS="$PROJECT_DIR/HyprMac/HyprMac-Release.entitlements" \
    build >"$BUILD_OUT" 2>&1; then
    tail -100 "$BUILD_OUT" >&2
    echo "ERROR: release build failed." >&2
    exit 1
fi
test -d "$APP_PATH"
APP_ARCHS=$(lipo -archs "$APP_PATH/Contents/MacOS/$APP_NAME")
for required_arch in arm64 x86_64; do
    if [[ " $APP_ARCHS " != *" $required_arch "* ]]; then
        echo "ERROR: Release executable is missing $required_arch (found: $APP_ARCHS)." >&2
        exit 1
    fi
done

SIGN_ID="Developer ID Application: Zachary Gray (WYY8494SWG)"
echo "       Re-signing nested code"
while IFS= read -r -d '' bin; do
    codesign --force --sign "$SIGN_ID" --keychain "$KEYCHAIN" --timestamp --options runtime "$bin"
done < <(find "$APP_PATH/Contents/Frameworks" -type f \( -perm +111 -o -name '*.dylib' \) -print0)
while IFS= read -r -d '' bundle; do
    codesign --force --deep --sign "$SIGN_ID" --keychain "$KEYCHAIN" --timestamp --options runtime "$bundle"
done < <(find "$APP_PATH/Contents/Frameworks" \( -name '*.xpc' -o -name '*.app' \) -print0)
while IFS= read -r -d '' framework; do
    codesign --force --sign "$SIGN_ID" --keychain "$KEYCHAIN" --timestamp --options runtime "$framework"
done < <(find "$APP_PATH/Contents/Frameworks" -name '*.framework' -print0)
codesign --force --sign "$SIGN_ID" --keychain "$KEYCHAIN" --timestamp --options runtime \
    --entitlements "$PROJECT_DIR/HyprMac/HyprMac-Release.entitlements" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

rm -f "$DMG_PATH"
STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"
rm -rf "$STAGING"

xcrun notarytool submit "$DMG_PATH" --keychain-profile HyprMac --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
VERIFY_MOUNT=$(mktemp -d "${TMPDIR:-/tmp}/hyprmac-release-verify.XXXXXX")
hdiutil attach -readonly -nobrowse -mountpoint "$VERIFY_MOUNT" "$DMG_PATH"
codesign --verify --deep --strict --verbose=2 "$VERIFY_MOUNT/$APP_NAME.app"
spctl -a -vv -t exec "$VERIFY_MOUNT/$APP_NAME.app"
hdiutil detach "$VERIFY_MOUNT"
rm -f "$STABLE_DMG_PATH"
cp "$DMG_PATH" "$STABLE_DMG_PATH"
xcrun stapler validate "$STABLE_DMG_PATH"
echo "       Signed, notarized, and stapled"

echo "[5/8] Generating and validating Sparkle appcast and cask"
if [[ ! -x "$SPARKLE_BIN/generate_appcast" ]]; then
    echo "ERROR: Sparkle generate_appcast missing at $SPARKLE_BIN" >&2
    exit 1
fi
cp "$PROJECT_DIR/docs/appcast.xml" "$DIST_DIR/appcast.xml"
"$SPARKLE_BIN/generate_appcast" "$DIST_DIR" \
    --download-url-prefix "https://github.com/$REPO/releases/download/v$NEW_VERSION/"
test -s "$DIST_DIR/appcast.xml"
cp "$DIST_DIR/appcast.xml" "$PROJECT_DIR/docs/appcast.xml"
grep -q "<sparkle:shortVersionString>$NEW_VERSION</sparkle:shortVersionString>" docs/appcast.xml
grep -q "<sparkle:version>$NEW_BUILD</sparkle:version>" docs/appcast.xml
grep -q "releases/download/v$NEW_VERSION/$DMG_NAME" docs/appcast.xml
grep -q 'sparkle:edSignature="[^"]\+"' docs/appcast.xml

DMG_SHA=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
sed -i '' "s/version \".*\"/version \"$NEW_VERSION\"/" Casks/hyprmac.rb
sed -i '' "s/sha256 \".*\"/sha256 \"$DMG_SHA\"/" Casks/hyprmac.rb
grep -q "version \"$NEW_VERSION\"" Casks/hyprmac.rb
grep -q "sha256 \"$DMG_SHA\"" Casks/hyprmac.rb

echo "[6/8] Committing, pushing main, and publishing final tag"
git fetch --prune origin
if [[ "$SOURCE_COMMIT" != "$(git rev-parse origin/main)" ]]; then
    echo "ERROR: origin/main moved during the release; refusing to publish." >&2
    exit 1
fi
git add project.yml HyprMac.xcodeproj/project.pbxproj Casks/hyprmac.rb docs/appcast.xml \
    scripts/release.sh scripts/test-release-pipeline.sh docs/release.md
git commit -m "Released HyprMac v$NEW_VERSION"
RELEASE_COMMIT=$(git rev-parse HEAD)
git push origin "$RELEASE_COMMIT:refs/heads/main"
git tag -a "v$NEW_VERSION" -m "HyprMac v$NEW_VERSION" "$RELEASE_COMMIT"
git push origin "refs/tags/v$NEW_VERSION"
test "$(git rev-list -n 1 "v$NEW_VERSION")" = "$RELEASE_COMMIT"

echo "[7/8] Creating GitHub Release v$NEW_VERSION"
if [[ -n "$RELEASE_NOTES_FILE" ]]; then
    gh release create "v$NEW_VERSION" "$DMG_PATH" "$STABLE_DMG_PATH" --repo "$REPO" \
        --title "HyprMac v$NEW_VERSION" --notes-file "$RELEASE_NOTES_FILE" --verify-tag
else
    gh release create "v$NEW_VERSION" "$DMG_PATH" "$STABLE_DMG_PATH" --repo "$REPO" \
        --title "HyprMac v$NEW_VERSION" --generate-notes --verify-tag
fi

echo "[8/8] Updating Homebrew tap"
TEMP_TAP=$(mktemp -d "${TMPDIR:-/tmp}/homebrew-hyprmac.XXXXXX")
git clone --depth 1 "https://github.com/zacharytgray/homebrew-hyprmac.git" "$TEMP_TAP"
cp Casks/hyprmac.rb "$TEMP_TAP/Casks/hyprmac.rb"
git -C "$TEMP_TAP" add Casks/hyprmac.rb
git -C "$TEMP_TAP" commit -m "Updated HyprMac to v$NEW_VERSION"
git -C "$TEMP_TAP" push origin HEAD:main
rm -rf "$TEMP_TAP"

echo "=== Release v$NEW_VERSION complete ==="
echo "DMG SHA-256: $DMG_SHA"
echo "Release: https://github.com/$REPO/releases/tag/v$NEW_VERSION"
