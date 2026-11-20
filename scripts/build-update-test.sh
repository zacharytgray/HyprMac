#!/bin/bash
# build two copies of a Sparkle-enabled test app (an old and a newer version)
# and a fake feed for them, to test the update flow on the MacBook.
# it uses a throwaway signing key and a feed on 127.0.0.1. the real appcast,
# the real EdDSA key and GitHub releases are never touched. see docs/testing.md
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 /path/to/Sparkle.xcframework [output dir]" >&2
    exit 2
fi
SPARKLE_FRAMEWORK=$(cd "$1" && pwd)
OUT=${2:-"$ROOT/build/update-test"}
PORT=${UPDATE_TEST_PORT:-18765}
BUILD_DIR="$ROOT/build/update-test.noindex"
SPEC="$BUILD_DIR/project.yml"
APP="$BUILD_DIR/Build/Products/Debug/HyprMac Debug.app"
SIGN_ID='Developer ID Application: Zachary Gray (WYY8494SWG)'
OLD_VERSION=0.0.1
OLD_BUILD=1
NEW_VERSION=99.0.0
NEW_BUILD=9999

test -d "$SPARKLE_FRAMEWORK"
python3 -c 'import cryptography' 2>/dev/null || {
    echo "ERROR: python3 needs the cryptography module to sign the fake update." >&2
    exit 1
}
rm -rf "$OUT"
mkdir -p "$BUILD_DIR" "$OUT/old" "$OUT/feed"

# the debug target, with Sparkle linked and embedded
cp "$ROOT/project.yml" "$SPEC"
perl -0pi -e 's/packages:\n  Sparkle:\n    url: https:\/\/github\.com\/sparkle-project\/Sparkle\n    from: "2\.6\.0"\n\n//' "$SPEC"
SPARKLE_FRAMEWORK="$SPARKLE_FRAMEWORK" perl -0pi -e 's/- package: Sparkle/- framework: $ENV{SPARKLE_FRAMEWORK}/g' "$SPEC"
SPARKLE_FRAMEWORK="$SPARKLE_FRAMEWORK" perl -0pi -e 's/(  HyprMac Debug:\n    type: application\n    platform: macOS\n    sources:\n      - HyprMac\n)/$1    dependencies:\n      - framework: $ENV{SPARKLE_FRAMEWORK}\n/' "$SPEC"
ROOT="$ROOT" perl -0pi -e 's{(?<=: )HyprMac/}{$ENV{ROOT}/HyprMac/}g; s{(?m)^(\s+- )HyprMac$}{$1$ENV{ROOT}/HyprMac}g; s{(?m)^(\s+- )HyprMacTests$}{$1$ENV{ROOT}/HyprMacTests}g' "$SPEC"
test "$(grep -c -F "framework: $SPARKLE_FRAMEWORK" "$SPEC")" = 2
xcodegen generate --spec "$SPEC" --project "$BUILD_DIR" >/dev/null

# throwaway EdDSA key for this run only
PUBLIC_KEY=$(python3 - "$OUT/feed-private-key" <<'PY'
import base64, sys
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
key = Ed25519PrivateKey.generate()
raw = serialization.Encoding.Raw
open(sys.argv[1], "wb").write(key.private_bytes(raw, serialization.PrivateFormat.Raw, serialization.NoEncryption()))
print(base64.b64encode(key.public_key().public_bytes(raw, serialization.PublicFormat.Raw)).decode())
PY
)

build_app() {
    local version=$1 build=$2 dest=$3
    # DEBUG without HYPRMAC_DEBUG_VARIANT: Sparkle stays in, and so does the
    # file log and the test hook
    xcodebuild \
        -project "$BUILD_DIR/HyprMac.xcodeproj" \
        -scheme "HyprMac Debug" \
        -configuration Debug \
        -derivedDataPath "$BUILD_DIR" \
        -destination 'generic/platform=macOS' \
        ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
        MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
        HYPRMAC_SOURCE_REVISION="update-test-$version" \
        SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG' \
        CODE_SIGNING_ALLOWED=NO \
        build >"$BUILD_DIR/xcodebuild-$version.log" 2>&1 || {
            tail -60 "$BUILD_DIR/xcodebuild-$version.log" >&2
            echo "ERROR: build of $version failed." >&2
            exit 1
        }
    rm -rf "$dest"
    cp -R "$APP" "$dest"
    local plist="$dest/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :SUFeedURL http://127.0.0.1:$PORT/appcast.xml" \
        -c "Set :SUPublicEDKey $PUBLIC_KEY" \
        -c "Add :NSAppTransportSecurity dict" \
        -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" "$plist"
    # sign the way release.sh does: nested code, then the framework, then the app
    while IFS= read -r -d '' bin; do
        codesign --force --sign "$SIGN_ID" --options runtime "$bin"
    done < <(find "$dest/Contents/Frameworks" -type f \( -perm +111 -o -name '*.dylib' \) -print0)
    while IFS= read -r -d '' bundle; do
        codesign --force --deep --sign "$SIGN_ID" --options runtime "$bundle"
    done < <(find "$dest/Contents/Frameworks" \( -name '*.xpc' -o -name '*.app' \) -print0)
    while IFS= read -r -d '' framework; do
        codesign --force --sign "$SIGN_ID" --options runtime "$framework"
    done < <(find "$dest/Contents/Frameworks" -name '*.framework' -print0)
    # a Debug build keeps its code in a dylib beside the executable
    while IFS= read -r -d '' dylib; do
        codesign --force --sign "$SIGN_ID" --options runtime "$dylib"
    done < <(find "$dest/Contents/MacOS" -name '*.dylib' -print0)
    codesign --force --sign "$SIGN_ID" --options runtime \
        --entitlements "$ROOT/HyprMac/HyprMac-Release.entitlements" "$dest"
    codesign --verify --deep --strict "$dest"
    test "$(plutil -extract CFBundleIdentifier raw "$plist")" = 'com.zachgray.HyprMac.debug'
    test "$(plutil -extract CFBundleShortVersionString raw "$plist")" = "$version"
    test -d "$dest/Contents/Frameworks/Sparkle.framework"
}

build_app "$OLD_VERSION" "$OLD_BUILD" "$OUT/old/HyprMac Debug.app"
NEW_APP="$BUILD_DIR/new/HyprMac Debug.app"
mkdir -p "$BUILD_DIR/new"
build_app "$NEW_VERSION" "$NEW_BUILD" "$NEW_APP"

ARCHIVE="HyprMacDebug-$NEW_VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$NEW_APP" "$OUT/feed/$ARCHIVE"
SIGNATURE=$(python3 - "$OUT/feed-private-key" "$OUT/feed/$ARCHIVE" <<'PY'
import base64, sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
key = Ed25519PrivateKey.from_private_bytes(open(sys.argv[1], "rb").read())
print(base64.b64encode(key.sign(open(sys.argv[2], "rb").read())).decode())
PY
)
rm -f "$OUT/feed-private-key"
LENGTH=$(stat -f %z "$OUT/feed/$ARCHIVE")
cat >"$OUT/feed/appcast.xml" <<XML
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>HyprMac update test</title>
        <item>
            <title>$NEW_VERSION</title>
            <pubDate>$(date -R)</pubDate>
            <sparkle:version>$NEW_BUILD</sparkle:version>
            <sparkle:shortVersionString>$NEW_VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
            <description><![CDATA[<h3>Fake update</h3><p>A test build. Nothing here is released.</p>]]></description>
            <enclosure url="http://127.0.0.1:$PORT/$ARCHIVE" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
        </item>
    </channel>
</rss>
XML
cp "$ROOT/scripts/update-test-feed.py" "$OUT/feed/serve.py"

echo "old app:  $OUT/old/HyprMac Debug.app ($OLD_VERSION)"
echo "feed:     $OUT/feed (serves $NEW_VERSION on port $PORT)"
