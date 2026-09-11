# MacBook debug deployment — September 11, 2026

## Current state

The canonical debug app is installed and running on `zachbook-pro`
(`100.78.164.103`) with Accessibility trust confirmed. Zach manually enabled
its Accessibility permission, then the canonical app was quit gracefully and
relaunched through Launch Services. The final normal process logged all three:

```text
bundle: com.zachgray.HyprMac.debug
AXIsProcessTrusted=true
started
```

These live startup events were captured at 14:08:08 CDT on September 11, 2026.
The release is not running. The process executable is exactly
`/Users/zgray/Applications/HyprMac Debug.app/Contents/MacOS/HyprMac Debug`.
No additional permission change, installation, or cleanup was needed after
Zach's grant. Deployment is complete; visual acceptance of the original bugs
remains a separate manual check.

A diagnostic launched directly from SSH returned false even after the grant.
The same signed executable launched through Launch Services returned true,
and the normal running GUI app independently logged true. Future remote AX
verification must use the GUI launch context; the SSH-direct result does not
establish the normal app's trust state. No permission for SSH or scripting
helpers was changed to work around this distinction.

## User acceptance update

On September 11, 2026, Zach reported that the deployed changes were working
well after using them and authorized committing and merging this phase before
starting the sizing work. This is positive live user feedback, not a recorded
pass of every case in the manual acceptance matrix. No additional deployment
or settings changes accompanied that authorization.

## Canonical identities

| Item | Preserved release | Installed debug |
| --- | --- | --- |
| Path | `/Applications/HyprMac.app` | `/Users/zgray/Applications/HyprMac Debug.app` |
| Product / executable | `HyprMac` | `HyprMac Debug` |
| Bundle identifier | `com.zachgray.HyprMac` | `com.zachgray.HyprMac.debug` |
| Version (build) | 0.12.0 (82) | 0.12.0 (82.1) |
| Architecture | arm64 + x86_64 | arm64 + x86_64 |
| Signature | Preserved notarized Developer ID | Developer ID Application: Zachary Gray (WYY8494SWG) |
| Updater | Preserved Sparkle | Sparkle absent; production update action absent |

Debug source marker: `08ec4f1adbef+51764a1a18cb`. This combines the base Git
revision with the builder's hash of current application files and project
specification, including the audit changes that were uncommitted at build time. Executable SHA-256:
`c25216f35946cf19fef4addb34322aa6675645f378e231320398c97e944388fc`.
The signature has no secure timestamp because the timestamp authority was
unavailable. This is a local debug deployment, not a notarized release.

## Verification

- Complete isolated suite: **281 tests, 55 display-dependent skips, 0 failures**
  (226 non-skipped passes), `build/deployment/final-suite-green.log`.
- Signed universal debug build passed; unsigned release compatibility build
  passed, `build/deployment/release-compat.log`.
- SwiftLint: 200 findings, including 15 existing errors, versus baseline
  201 findings / 16 errors. No new lint errors; lint remains failing overall.
- `bash -n scripts/build-debug.sh scripts/test-isolated.sh` and
  `git diff --check` passed. Independent source and artifact review passed.
- Deep strict signature verification passed before transfer and on the laptop.
  Bundle metadata and executable hash matched. Running application APIs reported
  the canonical executable, debug identifier, and `HyprMac Debug` display name.
- Spotlight returned exactly `/Applications/HyprMac.app` and
  `/Users/zgray/Applications/HyprMac Debug.app` after cleanup and installation.
- Release executable and Info.plist hashes match the pre-deployment snapshot;
  its deep strict signature still passes. Both Application Support configuration
  files and the release preference plist have unchanged hashes.
- After Zach's manual grant, a Launch Services diagnostic returned true and
  the normal debug process logged `AXIsProcessTrusted=true` followed by
  `started`. Window-manager startup is verified. Visual resolution of the
  reported bugs remains unverified; use the precise acceptance script in
  [the audit report](ux-stability-audit.md#manual-acceptance-checklist).
- Post-grant settings still have `enabled: true`, `showFocusBorder: false`, and
  an explicit `scratchpadTileByDefault: false`. The existing false scratchpad
  preference remains authoritative; the new tiled default does not replace it.
  Both configuration files and the release preference plist remain byte-for-byte
  unchanged. Debug's separate preferences now record `lastSeenVersion: 0.12.0`;
  release onboarding is inherited and its preference domain is unchanged.
  Neither domain has an explicit iCloud-sync override, so sync remains disabled.

The first final-suite attempt exposed an existing timer test that expected one
callback in a fixed 0.5-second interval; build load delayed observation to
0.676 seconds and two valid callbacks occurred. The test now checks timer
identity across two starts and invalidation on stop, without wall-clock
counting. No production scheduler behavior changed for this test correction.

## Deployment performed

1. Inventoried running release, exact bundle paths, metadata, signatures,
   Spotlight results, and configuration hashes before changes. Private ignored
   evidence: `build/deployment/laptop-before.json`.
2. Rechecked each approved stale path against that snapshot, including resolved
   non-symlink path, identifier, version, executable hash, signature, and absence
   of running processes within it. Unregistered each exact bundle using
   `lsregister -u`, then removed only its app directory. No parent directory,
   release bundle, or user data was removed.
3. Built the dedicated `HyprMac Debug` scheme using `scripts/build-debug.sh`
   and the cached Sparkle XCFramework needed by the generated release target.
   The exact successful command was `./scripts/build-debug.sh`; Xcode signed
   with `--timestamp=none` without a separate re-sign step. The successful log
   is `build/deployment/signed-debug-build.log`.
   Build output stays under `build/debug-canonical.noindex`, outside Spotlight
   indexing. Only the resulting debug app was transferred.
4. Created `build/deployment/hyprmac-debug-transfer.tar.gz` from that one app,
   copied it to laptop `/tmp/hyprmac-debug-transfer.tar.gz`, checked every archive
   member for the exact app prefix and absence of traversal or links, extracted
   into `/Users/zgray/Applications`, and removed the transfer archive. The
   canonical debug path was absent before extraction; no extra app copy remains.
5. Verified installed metadata, signature, and executable hash. Used
   `NSRunningApplication.terminate()` only after matching the running release's
   bundle path to `/Applications/HyprMac.app`; waited for it to exit.
6. Ran the installed debug executable with `--request-accessibility`, then
   `/usr/bin/open '/Users/zgray/Applications/HyprMac Debug.app'` and opened the
   Accessibility pane. The debug-only diagnostic exits without starting the
   window manager or restoring the keyboard remap.
7. Checked its own `--check-accessibility` result, running application identity,
   signature, Spotlight pair, release absence, and preservation hashes.
   Initial evidence: `build/deployment/install.log`, `launch.log`,
   `accessibility-ui.log`, `runtime-verification.log`, and `laptop-after.json`.
8. After Zach manually granted Accessibility, confirmed release absence,
   gracefully quit only the canonical debug app, and ran this diagnostic on
   the MacBook through Launch Services:

   ```sh
   /usr/bin/open -n -W \
     --stdout /tmp/hyprmac-debug-ax-check.log \
     --stderr /tmp/hyprmac-debug-ax-check.err \
     '/Users/zgray/Applications/HyprMac Debug.app' --args --check-accessibility
   /usr/bin/open '/Users/zgray/Applications/HyprMac Debug.app'
   ```

   The diagnostic returned `trusted=true`. Captured a subsequent controlled
   normal relaunch using a read-only unified-log stream filtered to debug's
   lifecycle category and the exact bundle/trust/start messages. It logged
   trust true and successful manager startup. The stream was stopped afterward;
   the app remains running. No global logging setting was changed.
9. Rechecked metadata, signature, running identity, preservation hashes, the
   exact Spotlight pair, and absence of all four approved stale paths.
   No additional files were deleted. Post-grant evidence:
   `build/deployment/post-grant-relaunch.log`, `post-grant-live-startup.log`,
   `post-grant-inventory.json`, and `post-grant-final.json`.

No packages, services, login items, release installation, global privacy
settings, or unrelated applications were changed. Debug reads existing release
onboarding and iCloud boolean preferences as fallback without writing to the
release preference domain. The existing HyprMac configuration directory remains
shared and was not edited by deployment.

## Approved stale bundles removed

All four had identifier `com.zachgray.HyprMac` and executable `HyprMac`; these
were old build products, not the canonical release or user data.

| Exact removed path | Version (build) | Verified signature before removal |
| --- | --- | --- |
| `/Users/zgray/GitHub/HyprMac/build/Build/Products/Debug/HyprMac.app` | 0.10.1 (76) | Ad hoc linker signature; strict verification failed for missing resource sealing |
| `/Users/zgray/GitHub/HyprMac/build/Build/Products/Release/HyprMac.app` | 0.10.2 (77) | Developer ID, team WYY8494SWG; deep strict verification passed |
| `/Users/zgray/GitHub/HyprMac/build/test/Build/Products/Debug/HyprMac.app` | 0.10.2 (77) | Ad hoc linker signature; strict verification failed for missing resource sealing |
| `/Users/zgray/GitHub/HyprMac/build/release/Build/Products/Release/HyprMac.app` | 0.10.0 (75) | Linker metadata; codesign reported unsigned |

Cleanup evidence: `build/deployment/approved-cleanup.log`. No other stale
bundle was removed. There are no timestamped debug installations.

## Rollback to release

Run on the MacBook:

1. Locate only the canonical debug process:
   `/usr/bin/pgrep -fl '^/Users/zgray/Applications/HyprMac Debug.app/Contents/MacOS/HyprMac Debug$'`.
2. Confirm that exact executable using
   `/usr/sbin/lsof -a -p <PID> -d txt`. Send `/bin/kill -TERM <PID>` only after
   the path matches; wait until `/bin/ps -p <PID>` confirms it has exited.
3. Launch `/usr/bin/open '/Applications/HyprMac.app'`.
4. Verify the release executable with
   `/usr/bin/pgrep -fl '^/Applications/HyprMac.app/Contents/MacOS/HyprMac$'`
   and `lsof` for that process. Confirm step 1 returns no debug process.
5. Leave both canonical apps and all settings/data in place. No preference
   reset, permission removal, login-item change, or reinstall is needed.

Rollback has not been performed. Debug remains the sole running HyprMac app,
with Accessibility trust and window-manager startup confirmed. The matching source changes are now recorded in commit
`c82446001012f2ad97839c3ffe184e0c7039eeb1`. Landing uses a separate temporary
checkout because the original worktree has read-only Git metadata in this
session; see [the audit report](ux-stability-audit.md). This does not change the
installed build or its source marker.
