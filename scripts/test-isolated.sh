#!/bin/bash
set -euo pipefail

# run the suite without starting the window manager or loading live settings
ROOT=$(cd "$(dirname "$0")/.." && pwd)
AUDIT_DIR="$ROOT/build/sizing/isolated-tests"
mkdir -p "$AUDIT_DIR/home" "$AUDIT_DIR/cache" "$AUDIT_DIR/tmp"

MODE=sparkle
SPARKLE_FRAMEWORK=
SELECTION=All
if [[ "${1:-}" == "--debug-variant" ]]; then
    MODE=without_sparkle
    SELECTION="${2:-All}"
elif [[ $# -ge 1 ]]; then
    SPARKLE_FRAMEWORK=$(cd "$1" && pwd)
    SELECTION="${2:-All}"
else
    echo "Usage: $0 --debug-variant [XCTest selection]" >&2
    echo "       $0 /path/to/Sparkle.xcframework [XCTest selection]" >&2
    exit 2
fi

export CFFIXED_USER_HOME="$AUDIT_DIR/home"
export XDG_CACHE_HOME="$AUDIT_DIR/cache"
export CLANG_MODULE_CACHE_PATH="$AUDIT_DIR/cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$AUDIT_DIR/cache/swiftpm"
export TMPDIR="$AUDIT_DIR/tmp"
export HYPRMAC_HEADLESS_TESTS=1

python3 - "$ROOT" "$AUDIT_DIR" "$MODE" "$SPARKLE_FRAMEWORK" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
audit = Path(sys.argv[2])
mode = sys.argv[3]
sparkle = Path(sys.argv[4]) if sys.argv[4] else None
quoted = lambda path: json.dumps(str(path))
dependencies = "" if mode == "without_sparkle" else f'''    dependencies:
      - framework: {quoted(sparkle)}
'''
variant_settings = "        SWIFT_ACTIVE_COMPILATION_CONDITIONS: DEBUG HYPRMAC_DEBUG_VARIANT\n" if mode == "without_sparkle" else ""
spec = f'''name: HyprMacIsolatedTests
options:
  deploymentTarget:
    macOS: "13.0"
settings:
  base:
    SWIFT_VERSION: "5.9"
    SWIFT_OBJC_BRIDGING_HEADER: {quoted(root / "HyprMac/PrivateAPI/HyprMac-Bridging-Header.h")}
    CODE_SIGNING_ALLOWED: NO
    OTHER_LDFLAGS: ["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"]
targets:
  HyprMac:
    type: library.dynamic
    platform: macOS
    sources:
      - path: {quoted(root / "HyprMac")}
        excludes: ["App/HyprMacApp.swift", "Resources", "Info.plist", "*.entitlements"]
{dependencies}    settings:
      base:
        PRODUCT_MODULE_NAME: HyprMac
        ENABLE_TESTABILITY: YES
        # load through rpaths so xctest needs no DYLD_* vars
        LD_DYLIB_INSTALL_NAME: "@rpath/HyprMac.dylib"
        LD_RUNPATH_SEARCH_PATHS: ["$(inherited)", "@loader_path"]
{variant_settings}  HyprMacTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: {quoted(root / "HyprMacTests")}
    dependencies:
      - target: HyprMac
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
        LD_RUNPATH_SEARCH_PATHS: ["$(inherited)", "@loader_path/../../.."]
schemes:
  HyprMacIsolatedTests:
    build:
      targets:
        HyprMac: all
        HyprMacTests: [test]
    test:
      targets: [HyprMacTests]
'''
(audit / 'project.yml').write_text(spec)
PY

xcodegen generate --spec "$AUDIT_DIR/project.yml"
xcodebuild build-for-testing \
    -project "$AUDIT_DIR/HyprMacIsolatedTests.xcodeproj" \
    -scheme HyprMacIsolatedTests -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$AUDIT_DIR/derived" \
    CODE_SIGNING_ALLOWED=NO

# a run starts from no config, whatever the last run left behind
rm -rf "$AUDIT_DIR/home/Library/Application Support/HyprMac" \
    "$AUDIT_DIR/home/Library/Mobile Documents"

PRODUCTS="$AUDIT_DIR/derived/Build/Products/Debug"
# debug builds inherit the release app's real prefs, which CFFIXED_USER_HOME
# does not redirect. keep the iCloud symlink out of the isolated home. the value
# is plist syntax: a bare NO reads as a string, and RuntimeVariant ignores it.
"$(xcrun -f xctest)" -iCloudSyncEnabled '<false/>' -XCTest "$SELECTION" "$PRODUCTS/HyprMacTests.xctest"
