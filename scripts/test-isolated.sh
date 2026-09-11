#!/bin/bash
set -euo pipefail

# run the suite without starting the window manager or loading live settings
ROOT=$(cd "$(dirname "$0")/.." && pwd)
AUDIT_DIR="$ROOT/build/isolated-tests"
mkdir -p "$AUDIT_DIR/home"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 /path/to/Sparkle.xcframework [XCTest selection]" >&2
    exit 2
fi
SPARKLE_FRAMEWORK=$(cd "$1" && pwd)
export CFFIXED_USER_HOME="$AUDIT_DIR/home"

python3 - "$ROOT" "$AUDIT_DIR" "$SPARKLE_FRAMEWORK" <<'PY'
import json
import sys
from pathlib import Path

root, audit, sparkle = map(Path, sys.argv[1:])
quoted = lambda path: json.dumps(str(path))
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
    dependencies:
      - framework: {quoted(sparkle)}
    settings:
      base:
        PRODUCT_MODULE_NAME: HyprMac
        ENABLE_TESTABILITY: YES
  HyprMacTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: {quoted(root / "HyprMacTests")}
    dependencies:
      - target: HyprMac
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
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

PRODUCTS="$AUDIT_DIR/derived/Build/Products/Debug"
export DYLD_LIBRARY_PATH="$PRODUCTS"
export DYLD_FRAMEWORK_PATH="$PRODUCTS"
xcrun xctest -XCTest "${2:-All}" "$PRODUCTS/HyprMacTests.xctest"
