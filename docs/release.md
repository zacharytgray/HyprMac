# Release pipeline

`scripts/release.sh` is the single entry point for shipping a new
version. It bumps the version, runs the test suite, builds, signs,
notarizes, packages a DMG, uploads a GitHub Release, regenerates the
Sparkle appcast, updates the Homebrew cask, and pushes the resulting
commit.

This document is the operator's guide. For per-release feature-list
prep, see CLAUDE.md "Release Feature List".

## Usage

```sh
export PATH="/usr/local/bin:$PATH"
export DEVELOPMENT_TEAM=WYY8494SWG
source ~/OpenClaude/Secrets/.env
./scripts/release.sh <version>
```

The `PATH` and `source` lines exist because `xcodegen`, `gh`, and
`DEVELOPMENT_TEAM` live in places the script's invocation
environment may not see by default. Match this exact pattern from
within Claude Code or another sandboxed shell.

The script commits and pushes automatically. Commit any other
in-flight changes first, then run the release.

## Prerequisites

Tools (all on `PATH`):

- `xcodegen` — regenerates the Xcode project from `project.yml`.
- `xcodebuild` — runs tests and the release build.
- `xcrun notarytool` — submits the DMG to Apple Notary Service.
- `xcrun stapler` — staples the notarization ticket to the DMG.
- `hdiutil` — creates the DMG.
- `gh` — GitHub CLI for the release upload.
- `git` — commits and pushes.

Credentials and config:

- `DEVELOPMENT_TEAM` — Apple Developer Team ID (env var).
- `KEYCHAIN_PASSWORD` — login keychain password (env var, optional —
  prompted if missing). Used to unlock the keychain and pre-authorize
  codesign access so signing does not pop up dozens of password
  prompts.
- `notarytool` keychain profile named `HyprMac` — stored credentials
  for `xcrun notarytool submit`. Create once via
  `xcrun notarytool store-credentials HyprMac` (you'll need an
  app-specific password and your Apple ID).
- A signing identity `Developer ID Application: Zachary Gray (WYY8494SWG)`
  in the login keychain.
- `gh` authenticated against `zacharytgray/HyprMac`.
- Sparkle SPM package resolved (any prior Debug build does this).

## What it does, step by step

The script numbers each step in its own output (`[N/8]`). All eight:

### [1/8] Bump version

Edits `project.yml` in place. Updates `MARKETING_VERSION` to the
supplied version and increments `CURRENT_PROJECT_VERSION` by one.
Both are read back later by `Bundle.infoDictionary` for the
"What's New" version-detection logic.

### [2/8] Regenerate Xcode project

Runs `xcodegen generate` so the version bump from step 1 reaches
the `.pbxproj`.

### [3/8] Run tests

`xcodebuild test` against the Debug configuration with a separate
`derivedDataPath` (`build/test`) so test artifacts do not pollute
the Release build directory used downstream. The test phase is the
release gate — a non-zero exit, a build failure, or any failed
test aborts the release here. Nothing signed, notarized, or
uploaded yet.

This is the single most important point in the script. Everything
that follows is hard or impossible to undo: notarization receipts
exist on Apple's side, GitHub Releases are visible to users
immediately, the Homebrew cask propagates to anyone who runs
`brew upgrade`. Test failure must abort before any of those steps.

### [4/8] Build, sign, package, notarize

- Unlocks the login keychain (using `KEYCHAIN_PASSWORD` env var or
  prompting). `security set-key-partition-list` grants codesign
  access to the signing key for this session, avoiding the ~20
  password prompts that would otherwise appear.
- Runs the Release `xcodebuild` with hardened runtime, manual code
  signing, and the Release entitlements file.
- Re-signs every nested binary (Sparkle helper apps, XPC services,
  frameworks) with the Developer ID + timestamp + hardened runtime.
  This is necessary because Sparkle ships unsigned helpers; the
  Apple notary rejects unsigned nested code.
- Re-signs the main `.app` last with the Release entitlements.
- Stages the `.app` plus an `Applications` symlink in a temp
  directory and runs `hdiutil create` to produce the DMG.
- Submits the DMG to `xcrun notarytool submit --wait` and staples
  the ticket on success.

If notarization fails the script prompts before continuing — an
un-notarized DMG works on the developer's machine but Gatekeeper
blocks it on every other machine. Continuing past this prompt is
almost never the right call; abort and debug.

### [5/8] Upload to GitHub Release

`gh release create` uploads the DMG with `--generate-notes`, which
auto-populates the release body from commits since the previous
tag. Edit the body via `gh release edit` afterward if you want
prose around the auto-list.

### [6/8] Regenerate Sparkle appcast

Runs Sparkle's `generate_appcast` against `dist/`, which signs and
appends a new entry for the current DMG and writes
`dist/appcast.xml`. The script then copies the result to
`docs/appcast.xml` so the GitHub Pages site (which serves the
appcast Sparkle reads on update checks) picks it up at the next
push.

If the Sparkle binary is not at the expected path, the script logs
a warning and skips this step. To resolve: run any Debug build to
materialize the SPM package (`SourcePackages/artifacts/sparkle/`),
then re-run the release.

### [7/8] Update Homebrew cask

Computes the DMG SHA-256, edits `Casks/hyprmac.rb` to reference
the new version + sha, copies the result into the local
`zacharytgray/homebrew-hyprmac` tap, and pushes. Falls back to a
temp clone when the tap is not installed locally.

### [8/8] Commit and push

`git add` of the touched files (`project.yml`,
`HyprMac.xcodeproj/project.pbxproj`, `Casks/hyprmac.rb`,
`docs/appcast.xml`, the script itself), commit as
`Release v<version>`, push.

## Recovering from a partial failure

The script is `set -e`, so a non-zero exit at any step aborts. The
recovery depends on where it stopped.

### Tests failed (step 3)

Nothing externally visible yet. Fix the failing tests, commit, and
re-run the release script with the same version argument. Step 1
re-bumps the version to the same value (a no-op
`sed`), step 2 regenerates, step 3 re-runs the tests.

### Build failed (step 4)

Same recovery — nothing pushed externally. Fix the build error and
re-run.

### Notarization failed (step 4)

The DMG exists at `dist/HyprMac-<version>.dmg` but is not
stapled. Most causes: missing entitlements on a nested binary,
hardened runtime missing on a helper, or a
not-yet-trusted signing certificate. `xcrun notarytool log <submission-id>
--keychain-profile HyprMac` shows the full notary log. Fix and
re-run.

### GitHub Release upload failed (step 5)

The DMG is signed and notarized but the release does not exist.
Re-run `gh release create v<version> dist/HyprMac-<version>.dmg
--repo zacharytgray/HyprMac --title "HyprMac v<version>"
--generate-notes` manually, then re-run the script with the same
version — earlier steps short-circuit and the script picks up at
step 6.

### Appcast regen failed (step 6)

Run any Debug build first to materialize the Sparkle SPM artifact,
then run `dist/HyprMac.app/Contents/Frameworks/Sparkle.framework/Versions/A/Resources/generate_appcast
dist/` manually with the right
`--download-url-prefix`. Copy the result to `docs/appcast.xml`,
commit, push.

### Homebrew tap update failed (step 7)

Hand-update `Casks/hyprmac.rb` (version + sha), copy to
`$(brew --repository zacharytgray/hyprmac)/Casks/hyprmac.rb`,
commit and push that repo manually.

### Already-released version

If the GitHub Release already exists for the version you specified,
`gh release create` fails. Either bump the patch version and re-run
or delete the existing release first
(`gh release delete v<version> --yes`).

## What the test gate catches

The Phase 8 test suite (196 tests) covers BSP tree mutation,
layout computation, frame readback, suppression registry, window
state cache, focus state controller, window discovery, polling
scheduler, toggle-split fallthrough regression, keybind decoder
tolerance, config migration, default keybinds, and dwindle layout
preview. A real bug in any of these surfaces would catch here
before release. Coverage of orchestration glue
(`WindowManager`-driven flows) is via manual smoke test only — the
test gate is necessary but not sufficient.

Run `xcodebuild test` standalone before invoking `release.sh` if
you want a faster signal — the in-script run is the safety net,
not the iteration loop.

## Manual smoke test (post-release)

After the script completes, install the new DMG (or wait for
Sparkle to detect it) and walk through:

- Caps Lock chord triggers — focus, swap, workspace switch,
  workspace move.
- Drag-swap on a single monitor and across monitors (if
  multi-display setup is available).
- Float toggle (`Hypr+Shift+T`) and float cycle (`Hypr+F`).
- App quit + reopen — windows return to their workspaces.
- Welcome / What's-New panel appears on first launch of the new
  version.

If anything regressed, `gh release edit v<version> --draft` hides
the release while you investigate; affected users on Sparkle
auto-update will not see it until you flip it back to public.
