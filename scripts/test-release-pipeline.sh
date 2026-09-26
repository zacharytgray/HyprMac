#!/bin/bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/release.sh"

grep -q '^set -Eeuo pipefail$' "$SCRIPT"
grep -q 'ERROR: Sparkle generate_appcast missing' "$SCRIPT"
grep -q 'cp "$PROJECT_DIR/docs/appcast.xml" "$DIST_DIR/appcast.xml"' "$SCRIPT"
grep -q 'git -C "$TEMP_TAP" push origin HEAD:main' "$SCRIPT"
grep -q 'spctl -a -vv -t exec' "$SCRIPT"
grep -q -- '-resolvePackageDependencies' "$SCRIPT"
grep -q -- '-clonedSourcePackagesDirPath "$BUILD_DIR/SourcePackages"' "$SCRIPT"
grep -q 'scripts/test-isolated.sh "$SPARKLE_FRAMEWORK"' "$SCRIPT"
grep -q 'resolved Sparkle artifacts are incomplete' "$SCRIPT"
grep -q 'ARCHS="arm64 x86_64"' "$SCRIPT"
grep -q 'ONLY_ACTIVE_ARCH=NO' "$SCRIPT"
grep -q 'lipo -archs' "$SCRIPT"
grep -q 'git commit -m "Released HyprMac v\$NEW_VERSION"' "$SCRIPT"
grep -q 'git -C "$TEMP_TAP" commit -m "Updated HyprMac to v\$NEW_VERSION"' "$SCRIPT"
if grep -Eq 'read .*Keychain password' "$SCRIPT"; then
    echo "release pipeline still requires an interactive secret prompt" >&2
    exit 1
fi
if grep -Eq 'git .*push.*\|\| true|xcodebuild .*\|.*\|\| true' "$SCRIPT"; then
    echo "release failures can still be swallowed" >&2
    exit 1
fi

clean_line=$(grep -n 'release must start from a clean main checkout' "$SCRIPT" | cut -d: -f1)
bump_line=$(grep -n 'sed -i.*MARKETING_VERSION' "$SCRIPT" | cut -d: -f1)
commit_line=$(grep -n 'git commit -m "Released HyprMac v\$NEW_VERSION"' "$SCRIPT" | cut -d: -f1)
push_line=$(grep -n 'git push origin "\$RELEASE_COMMIT:refs/heads/main"' "$SCRIPT" | cut -d: -f1)
tag_line=$(grep -n 'git tag -a "v\$NEW_VERSION"' "$SCRIPT" | cut -d: -f1)
tag_push_line=$(grep -n 'git push origin "refs/tags/v\$NEW_VERSION"' "$SCRIPT" | cut -d: -f1)
release_line=$(grep -n 'gh release create "v\$NEW_VERSION"' "$SCRIPT" | head -1 | cut -d: -f1)
[[ "$clean_line" -lt "$bump_line" ]]
[[ "$commit_line" -lt "$push_line" && "$push_line" -lt "$tag_line" ]]
[[ "$tag_line" -lt "$tag_push_line" && "$tag_push_line" -lt "$release_line" ]]
grep -q -- '--verify-tag' "$SCRIPT"
if grep -Eq 'notarytool .*\|\| true|stapler .*\|\| true|codesign .*\|\| true|spctl .*\|\| true' "$SCRIPT"; then
    echo "release verification failures can still be swallowed" >&2
    exit 1
fi

echo "release pipeline invariants verified"
