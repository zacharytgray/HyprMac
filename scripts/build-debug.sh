#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD_DIR="$ROOT/build/debug-canonical.noindex"
SPARKLE_FRAMEWORK=${1:-"$ROOT/build/audit-harness/Sparkle.xcframework"}
SPARKLE_FRAMEWORK=$(cd "$SPARKLE_FRAMEWORK" && pwd)
GIT_REVISION=$(git -C "$ROOT" rev-parse --short=12 HEAD)
CONTENT_HASH=$(
    find "$ROOT/HyprMac" -type f -print0 \
        | sort -z \
        | xargs -0 shasum -a 256
    shasum -a 256 "$ROOT/HyprMac/Info.plist" "$ROOT/project.yml"
)
CONTENT_HASH=$(printf '%s' "$CONTENT_HASH" | shasum -a 256 | cut -c1-12)
SOURCE_REVISION="$GIT_REVISION+$CONTENT_HASH"
APP="$BUILD_DIR/Build/Products/Debug/HyprMac Debug.app"
SPEC="$BUILD_DIR/project.yml"
PROJECT_DIR="$BUILD_DIR"

test -d "$SPARKLE_FRAMEWORK"
mkdir -p "$BUILD_DIR" "$PROJECT_DIR"
cp "$ROOT/project.yml" "$SPEC"
perl -0pi -e 's/packages:\n  Sparkle:\n    url: https:\/\/github\.com\/sparkle-project\/Sparkle\n    from: "2\.6\.0"\n\n//' "$SPEC"
SPARKLE_FRAMEWORK="$SPARKLE_FRAMEWORK" perl -0pi -e 's/- package: Sparkle/- framework: $ENV{SPARKLE_FRAMEWORK}/g' "$SPEC"
ROOT="$ROOT" perl -0pi -e 's{(?<=: )HyprMac/}{$ENV{ROOT}/HyprMac/}g; s{(?m)^(\s+- )HyprMac$}{$1$ENV{ROOT}/HyprMac}g; s{(?m)^(\s+- )HyprMacTests$}{$1$ENV{ROOT}/HyprMacTests}g' "$SPEC"
if rg -q 'packages:|package: Sparkle' "$SPEC"; then
    echo "ERROR: unresolved Sparkle package dependency in generated spec" >&2
    exit 1
fi
test "$(rg -c --fixed-strings "framework: $SPARKLE_FRAMEWORK" "$SPEC")" = 1
xcodegen generate --spec "$SPEC" --project "$PROJECT_DIR"
xcodebuild \
    -project "$PROJECT_DIR/HyprMac.xcodeproj" \
    -scheme "HyprMac Debug" \
    -configuration Debug \
    -derivedDataPath "$BUILD_DIR" \
    -destination 'generic/platform=macOS' \
    ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
    HYPRMAC_SOURCE_REVISION="$SOURCE_REVISION" \
    CODE_SIGN_IDENTITY='Developer ID Application: Zachary Gray (WYY8494SWG)' \
    CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=WYY8494SWG \
    clean build

test -d "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
SIGNATURE=$(codesign -dvv "$APP" 2>&1)
printf '%s\n' "$SIGNATURE" | rg -q '^TeamIdentifier=WYY8494SWG$'
printf '%s\n' "$SIGNATURE" | rg -q '^Authority=Developer ID Application: Zachary Gray \(WYY8494SWG\)$'
test "$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")" = 'com.zachgray.HyprMac.debug'
test "$(plutil -extract CFBundleName raw "$APP/Contents/Info.plist")" = 'HyprMac Debug'
test "$(plutil -extract HyprMacSourceRevision raw "$APP/Contents/Info.plist")" = "$SOURCE_REVISION"
while IFS= read -r -d '' binary; do
    if file "$binary" | rg -q 'Mach-O'; then
        lipo "$binary" -verify_arch arm64 x86_64
    fi
done < <(find "$APP" -type f -print0)
shasum -a 256 "$APP/Contents/MacOS/HyprMac Debug"
echo "$APP"
