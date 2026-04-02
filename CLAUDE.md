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

**Important:** The script needs `DEVELOPMENT_TEAM`, `gh`, and `xcodegen` available. These tools live in `/usr/local/bin` which isn't in Claude Code's default PATH. Also `source` alone doesn't export vars to subsequent commands in the same shell invocation. Use this exact pattern:

```bash
export PATH="/usr/local/bin:$PATH" && export DEVELOPMENT_TEAM=WYY8494SWG && source ~/OpenClaude/Secrets/.env && ./scripts/release.sh <version>
```

The script commits and pushes automatically — commit your changes first, then run the release. Check `project.yml` for the current `MARKETING_VERSION` to pick the next version number.

## Code Style
- Comments: short lowercase fragments, not narration
- No unnecessary abstractions or error handling
- Prefer editing existing files over creating new ones
- No meta-language ("As an AI...", "According to the spec...")
