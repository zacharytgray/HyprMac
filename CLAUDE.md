# HyprMac — Claude Instructions

See [AGENTS.md](AGENTS.md) for full architecture, keybinds, config format, and technical decisions.

## Build & Test (debug)
```bash
xcodebuild -project HyprMac.xcodeproj -scheme HyprMac -configuration Debug \
  -derivedDataPath build CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "(error:|BUILD)"

# run
pkill -x HyprMac; build/Build/Products/Debug/HyprMac.app/Contents/MacOS/HyprMac
```

## Project Generation
Uses XcodeGen. After changing `project.yml` or adding/removing files:
```bash
xcodegen generate
```

## Release a New Version
Run the all-in-one release script. It handles version bump, build, sign, notarize, DMG, GitHub Release, Sparkle appcast, Homebrew cask, commit, and push.

```bash
source ~/OpenClaude/Secrets/.env
./scripts/release.sh <version>
```

Example: `./scripts/release.sh 0.2.0`

## Code Style
- Comments: short lowercase fragments, not narration
- No unnecessary abstractions or error handling
- Prefer editing existing files over creating new ones
- No meta-language ("As an AI...", "According to the spec...")
