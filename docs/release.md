# Release pipeline

`scripts/release.sh` is the single entry point for a HyprMac release. It tests,
builds, signs, notarizes, publishes, updates Sparkle, and updates Homebrew. The
script stops on the first failed command; it does not offer a bypass for a
failed test, signature, notarization, or Gatekeeper check.

Releases run on the Mac mini hub, the same machine as all other repository
work.

## Before you release: What's New

Update `WhatsNewFeatures.current` in `HyprMac/Welcome/WelcomeContent.swift`
from `git log v<previous>..HEAD --oneline`. List user-facing changes only.
Each entry needs an SF Symbol, a short title, a one-line description, and a
tint (`.cyan` by default, `.magenta` for floating or scratchpad). Add
`credit:` with the GitHub handle of an outside contributor. Update
`WelcomeContentTests.testWhatsNewDescribesOnlyThe<version>Changes` to match;
the release gate fails otherwise. Commit and push this before starting the
script, which refuses a dirty checkout.

## Usage

Start from a clean `main` checkout at exactly `origin/main`, with no local or
remote `v<version>` tag and no GitHub Release for that version.

```sh
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export DEVELOPMENT_TEAM=WYY8494SWG
./scripts/release.sh <version> [release-notes-file]
```

If supplied, the release-notes file must exist and be nonempty. Set
`KEYCHAIN_PASSWORD` when the login keychain needs unlocking. Otherwise the
script requires the keychain to be unlocked already; it never prompts for a
secret. A locked keychain makes `codesign` fail with `errSecInternalComponent`.
Pick a `<version>` above the current `MARKETING_VERSION` in `project.yml`.

## Prerequisites

- `xcodegen`, `xcodebuild`, `xcrun`, `hdiutil`, `codesign`, `spctl`, `lipo`,
  `gh`, and `git` on `PATH`.
- Apple team `WYY8494SWG` and the Developer ID Application identity in the
  login keychain.
- A `notarytool` keychain profile named `HyprMac`.
- `gh` authenticated for `zacharytgray/HyprMac`.
- Permission to push `main`, the final tag, and the Homebrew tap.

Commit all release content before starting. The pipeline intentionally refuses
a dirty checkout and verifies `origin/main` again immediately before it makes
the release commit.

## The eight steps

### 1. Bump the version

The script sets `MARKETING_VERSION` in `project.yml` and increments
`CURRENT_PROJECT_VERSION`.

### 2. Generate the project and resolve Sparkle

It regenerates the Xcode project, explicitly resolves packages into
`build/SourcePackages`, and requires both `Sparkle.xcframework` and
`generate_appcast`. Missing Sparkle artifacts are fatal.

### 3. Run isolated tests

The release gate calls `scripts/test-isolated.sh` with the resolved
`Sparkle.xcframework`. This builds a testable library instead of launching the
window-manager app host, and runs under an isolated home, cache, and temporary
directory. The script requires both a zero exit status and an XCTest summary
with zero failures.

### 4. Build, sign, package, and notarize

The Release build explicitly targets `arm64` and `x86_64`, uses the same
resolved package directory, and must report both architectures through `lipo`.
The pipeline re-signs Sparkle's nested code, signs the app last with the Release
entitlements, and verifies the signature. It then creates the DMG, submits it
to Apple, staples and validates the ticket, mounts the DMG read-only, and runs
both `codesign` and Gatekeeper verification against the packaged app. It then
copies the stapled `HyprMac-<version>.dmg` to `build/HyprMac.dmg` and validates
that copy's ticket as well. The copy lives outside `dist/` so Sparkle's
`generate_appcast` never treats it as a second update.

### 5. Generate and validate update metadata

Sparkle generates a signed appcast entry for the DMG. The pipeline verifies
the short version, build number, download URL, and EdDSA signature. It also
updates the in-repository Homebrew cask with the DMG SHA-256 and verifies the
new version and hash.

### 6. Commit, push `main`, and publish the final tag

After fetching `origin` again and confirming it has not moved, the script
creates the `Released HyprMac v<version>` commit, pushes that exact commit to `main`,
creates the annotated tag on that final commit, and pushes the tag. The tag
therefore contains the final project version, appcast, and cask metadata.

### 7. Create the GitHub Release

The script creates the release from the already-pushed tag with `--verify-tag`
and uses either the supplied notes file or generated notes. It uploads two
assets, both the same notarized bytes:

- `HyprMac-<version>.dmg`, referenced by the Sparkle appcast and the Homebrew
  cask.
- `HyprMac.dmg`, which keeps
  `https://github.com/zacharytgray/HyprMac/releases/latest/download/HyprMac.dmg`
  working as a permanent download link.

### 8. Update the Homebrew tap

It clones `zacharytgray/homebrew-hyprmac` into a temporary directory, copies
the validated cask, commits `Updated HyprMac to v<version>`, and pushes that
commit to the tap's `main` branch.

## Failure and recovery

Do not blindly rerun the script after a failure. It has no resume mode, and a
failure after step 1 leaves a deliberately dirty checkout. Inspect the exact
state first.

- **Before the step 6 push:** no public repository state has changed. Preserve
  useful logs or artifacts, then restore or replace the release checkout and
  restart from a clean `main` at `origin/main`.
- **After `main` was pushed but before the tag:** the release commit is public
  but untagged. Inspect `main` and finish the missing operation deliberately;
  do not rebuild different bytes under the same version.
- **After the tag was pushed but before the GitHub Release:** verify that the
  tag points to the release commit, then create the GitHub Release from that
  existing tag and upload both assets from the exact notarized DMG, the
  versioned name and `HyprMac.dmg`.
- **After the GitHub Release but before the tap push:** verify the published
  DMG hash, then update the tap with the already-validated cask.

Published tags and releases are immutable release history. Do not delete or
replace them to make a rerun pass. If published artifacts are wrong, fix the
cause and ship a new patch version.

Useful diagnostics include the tail printed from the test or build log and
`xcrun notarytool log <submission-id> --keychain-profile HyprMac` for a failed
notarization.

## Manual acceptance

As a separate acceptance gate before running this publishing script, install a
signed candidate built from the same commit on the target macOS version. Check
normal drag insertion, Hypr-held drag swapping,
directional focus and swap, workspace switching and moves, HYPR+T float
toggling, app quit/reopen, and the post-update What's New panel.
