# MacBook debug deployment

All repository work runs on the Mac mini hub. The MacBook (`zachbook-pro`)
only runs the signed Debug app for live-behavior tests.

## Build

`./scripts/build-debug.sh [Sparkle.xcframework]` builds the signed, universal
`HyprMac Debug.app` into `build/debug-canonical.noindex/Build/Products/Debug/`.

- Bundle id `com.zachgray.HyprMac.debug`, product `HyprMac Debug`, no Sparkle.
- Info.plist `HyprMacSourceRevision` is `<sha12>+<content hash>` of the tree.
  The hash includes absolute paths, so a different worktree gives a different
  hash for the same source.
- It needs a cached Sparkle.xcframework, by default at
  `build/audit-harness/Sparkle.xcframework`. `build/` is ignored, so copy it
  into a fresh worktree. It also needs `rg` and the Developer ID identity.

## Redeploy

The Debug app lives at `/Applications/HyprMac Debug.app`.

1. Build on the hub. Note the executable sha256 and `HyprMacSourceRevision`.
2. Tar only the one app, scp it to the MacBook, extract into a staging
   directory, and run `codesign --verify --deep --strict` on it.
3. Find the exact running pid with `pgrep -f` on the full executable path of
   whichever HyprMac is running (Debug or release). Send `kill -TERM` to that
   pid only. Wait until `ps -p` shows it gone.
4. Move the old bundle to `/Applications/.hyprmac-debug-previous` for rollback.
   Move the new one into place.
   Launch it with `/usr/bin/open`.
5. Verify the new pid's executable path, `HyprMacSourceRevision`, and the
   executable sha256. Check that the file log shows `AXIsProcessTrusted=true`
   and `started`. Both are `.debug` lines, so `log show` does not have them
   (see [debugging.md](debugging.md)).

Accessibility trust carries over because the signing identity and bundle id
do not change. Launch through Launch Services (`/usr/bin/open`); a binary
started directly from SSH reports untrusted.

Debug and release share `~/Library/Application Support/HyprMac/`.
`config.json` there can be a symlink into iCloud Drive. Back up those files
before any migration test.

## Rollback

To the previous Debug build: stop it as in step 3, move
`/Applications/.hyprmac-debug-previous` back into place, and launch it with
`/usr/bin/open`.

To the release: stop the Debug app the same way, then run
`/usr/bin/open '/Applications/HyprMac.app'`. No preference reset, permission
change or reinstall is needed.

## Checking trust from SSH

The Debug app has `--check-accessibility` and `--request-accessibility`. Both
print a result and exit without starting the window manager. Run them through
Launch Services so the result is about the app and not the SSH session:

```sh
/usr/bin/open -n -W --stdout /tmp/hyprmac-ax.log --stderr /tmp/hyprmac-ax.err \
  '/Applications/HyprMac Debug.app' --args --check-accessibility
cat /tmp/hyprmac-ax.log
```

## Previewing the overlays

`--preview-overlays` shows every transient overlay with sample data in its
real panel: the switch HUD (a number and a custom name), the fullscreen HUD, a
saved and a failed status HUD, Hypr+K scrolled under a header, and the
workspace overview. It quits after 90 seconds. It starts no window manager,
event tap, AX or tiling, and it only reads the config. Quit the running
HyprMac first, or both menu bar items show. `--glass-fallback` forces the
pre-macOS 26 blur on macOS 26 and later, with or without the preview. Both
flags exist only in builds that define `DEBUG`.

```sh
/usr/bin/open -n '/Applications/HyprMac Debug.app' --args --preview-overlays --glass-fallback
```
