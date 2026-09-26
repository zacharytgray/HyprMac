# Settings polish

## Evidence and scope

This pass starts from `origin/main` at `701c551`. The preserved hub checkout was not changed. Read-only inspection of the MacBook on September 14, 2026 found:

- `mouseHoverPollHz: 120` and focus-follows-mouse enabled.
- Dimming enabled at `0.1346203613281251`, persistent borders disabled, focus color `000000`, fade duration `0.13`, and corner radius `15`.
- The configuration file is an iCloud Drive symlink. Both direct settings edits and complete file reloads therefore need safe live-update behavior.

Initial inspection was read-only. After the first polish commit, the signed Debug build was installed and launched on the MacBook at Zach's explicit request. Its startup log confirmed Accessibility trust and successful startup; configuration and release-app hashes remained unchanged.

## Hover response

The former refresh-rate slider controls **hover-to-focus checks during mouse movement**. `WindowManager` supplies `MouseTrackingManager.hoverThrottleInterval`; the mouse handler drops events that arrive too soon. It does not run a timer at the selected frequency and does no hover work while focus-follows-mouse is disabled.

| Before | After |
| --- | --- |
| A numeric 60–240 Hz refresh-rate slider | Hover response: Low 60 Hz, Medium 120 Hz, High 240 Hz |
| Frequency looked like an overall refresh control | Wording says it controls pointer-driven focus checks |
| Saved intermediate rates | Exact custom rate remains visible and preserved |

Medium retains the existing 120 Hz default. The minimum spacing between eligible checks is approximately 16.7 ms at Low, 8.3 ms at Medium, and 4.2 ms at High. These are throttle intervals, not guaranteed focus latencies: dropped events are not replayed if the pointer stops, and main-thread work can delay handling. The window-list cache also reuses one list for up to 80 ms, so attempts do not equal expensive window-list queries.

Window discovery is separate: accessibility notifications request coalesced discovery, with a fixed 10-second reconciliation timer for missed events. Neither this timer nor display refresh, key handling, animation durations, or window sizing uses the hover setting.

Higher rates permit more hit-test attempts while the pointer moves. This establishes a work-versus-responsiveness tradeoff, but no energy or battery-life measurement was collected. The same tier remains active on battery and external power. A later optional battery override would need an injected power-state provider, explicit preference migration, and measurements. macOS provides IOKit power-source snapshots and limited-power notifications; there is no reason to add another recurring power poll.

### Rate compatibility

`mouseHoverPollHz` remains the stored integer. Existing 90, 150, 180, 210 Hz and manually configured values are not rounded to tiers. Selecting a tier explicitly replaces the value. Values below the pre-existing 30 Hz runtime floor remain stored and are labelled with their effective rate. File reloads now apply the saved hover value as startup does.

## Focus appearance

The default uses dimming and corner cues while the Hypr key is held. Persistent colored focus fills and full-window borders are off. The existing border renderer remains available as an opt-in because it also owns bounded red rejection feedback and existing users may deliberately use its colors.

| Setting | Before default | New default |
| --- | --- | --- |
| Dim inactive windows | Off | On |
| Dim amount | 20% | 13.5% |
| Dim slider | 5–60% | 0–27% |
| Persistent borders | On | Off |
| Corner cue color | Shared focus color, cyan by default | Black |
| Dimming/border fade | 220 ms | 130 ms |

Zach requested his current dim level at the midpoint. The new 0–27% range puts the observed 13.46% almost exactly halfway. Existing stronger saved amounts remain intact; opening settings does not clamp or rewrite them. The displayed percentage reports the saved amount, and using the slider chooses a value in the new range.

Window shape and key-press marks have separate controls. **Window corner radius** keeps the existing `windowCornerRadius` override and shapes only dimming cut-outs and optional window borders. **Mark roundness** shapes only the four Hypr-key marks; zero gives square marks and higher values round their corner arcs. The marks default to 20-point roundness, 15-point straight segments, and 4.5-point thickness, matching the saved MacBook settings. The follow-up below consolidates their visibility with the border choice. Changing either radius updates only appearance. Color is independent of the persistent border and defaults to black with a white contrast stroke (4.5-point foreground, 6.5-point contrast). The fixed corner entrance/release timings remain unchanged; the fade slider controls borders, dimming, and the scratchpad scrim.

Explicit saved dimming, border, color, radius, and fade preferences remain authoritative. Missing fields, fresh configurations, and Reset to Defaults use the new baseline. Error feedback still shows a red overlay shake and message after rejection even when persistent borders or corner cues are off. It does not shake application windows.

### Corner compatibility

The optional `focusBracketStyle`, `focusBracketColorHex`, and `focusBracketRadius` fields extend the existing configuration without renaming its keys. For an older file with no style field, an explicit focus-border color becomes the initial bracket color. Once the new style field is saved, an absent bracket color means the black default and never reimports the old border color. Thus the laptop's saved black cue is preserved until changed deliberately. Old builds can ignore the new fields, but may discard them if they rewrite the shared file; cross-version iCloud writes cannot preserve preferences unknown to the old writer.

### Window-radius research

Apple describes macOS 27 Golden Gate as giving windows a consistent, tighter radius. It described Tahoe's radii as varying with window style: larger toolbars get larger corners, while titlebar-only windows use smaller corners. These are standard-window design statements, not a guarantee for custom-shaped application windows. Sources: [WWDC26 Platforms State of the Union](https://developer.apple.com/videos/play/wwdc2026/102/) and [WWDC25 AppKit design](https://developer.apple.com/videos/play/wwdc2025/310/).

Apple's [WWDC25 window-corner slide at 7:30](https://developer.apple.com/videos/play/wwdc2025/310/?time=450) supplies numeric Tahoe values:

| Window style on macOS 26 | Radius |
| --- | --- |
| Titlebar | 16 pt |
| Compact toolbar | 20 pt |
| Toolbar | 26 pt |

No numeric Golden Gate radius was verified. Apple's linked macOS 27 Figma kit returned HTTP 403, and the Sketch page exposed no downloadable layer geometry. This pass retains the existing 16-point fallback for macOS 26 and later and the existing 10-point compatibility fallback for earlier versions. The former is a documented Tahoe titlebar value, **not** a documented Golden Gate universal value; the latter was not independently measured in this pass. The reset button is therefore labelled **Suggested**, not **OS default**. A controlled measurement on Golden Gate is still needed before choosing a different automatic value.

The MacBook's read-only OS inventory reports macOS 27.0, build 26A428. Its explicit 15-point HyprMac override remains untouched. A global manual correction remains useful, although one radius cannot perfectly match differently shaped windows simultaneously. There is no per-app override interface in this pass.

## Live-update boundary

The first aesthetic save could trigger a layout change through a file-watcher echo. The old layout subscriptions used `dropFirst().removeDuplicates()`: dropping the initial value left deduplication uninitialized. The first reload's unchanged gap, padding, split limits, and disabled-monitor values then reached retile or redistribution callbacks.

Two additional problems made updates inconsistent:

- `@Published` emits before storing the new value. Appearance callbacks that read the configuration instead of the emitted value could render the previous setting.
- Each start added another set of subscriptions, while stop left them installed. Repeated disable/enable cycles multiplied later callbacks.

Live updates now compare complete configuration snapshots with the initial state already recorded. Only changed layout fields invoke layout effects. Appearance changes use a dedicated visual path, without rebuilding window caches, setting application frames, assigning workspaces, or changing focus. The subscription is installed once, and file reloads are observed after their complete state has been applied.

Gap/padding, split limits, monitor enablement, and scratchpad region size still have their intended layout effects. Dimming, color, fade, corner radius, and border/corner appearance do not.

## Verification and remaining acceptance

The untouched baseline passed 796 tests, with 92 display-dependent skips and zero failures, using `scripts/test-isolated.sh --debug-variant`. This harness does not start the window manager and redirects configuration and caches into the build directory.

Final validation:

- Full isolated suite: **820 tests, 94 display-dependent skips, zero failures** (726 non-skipped passes). Log: `build/polish/final-tests.log`.
- Focused cadence, migration, configuration routing, radius independence, and wire-format tests passed during implementation. The future-style/neutral-color migration regression was observed failing, then passing after the fix.
- The old Combine operator order was reproduced independently: an initial value of 8 followed by an unchanged 8 reaches the old `dropFirst().removeDuplicates()` subscriber once. New production-observer tests verify unchanged reloads produce no layout effects.
- Display-backed tests for initial bracket paths, live appearance, and rapid hide/show compile but are skipped by the isolated harness. They require a later authorized GUI run.
- Debug and Release universal app builds **passed** and both contain arm64 and x86_64 binaries. They use the generated `build/polish/HyprMac.xcodeproj`, existing cached Sparkle dependency, `ARCHS='arm64 x86_64'`, and `CODE_SIGNING_ALLOWED=NO`. These are local verification builds, not signed distribution artifacts. Logs: `build/polish/debug-build.log` and `build/polish/release-build.log`.
- Generated project membership, bundle identities, and `git diff --check` passed. Release retains existing AX-notification cast warnings; both builds report the non-blocking absence of App Intents metadata.

Final review also fixed stopped-state handling: stop clears the held-key flag and hides brackets, and appearance updates cannot re-show them while disabled.

Deterministic routing tests establish the routing boundary; they do not establish visual quality on the MacBook. A later explicitly authorized live acceptance pass should adjust every appearance control while tiled/floating windows occupy multiple workspaces, confirm stable geometry and focus, test corners on light/dark content, and trigger a rejected operation to confirm red feedback remains visible.


## Tutorial and appearance follow-up

The first-run screen is now a seven-page **HyprMac tutorial** covering the Hypr key, tiled and floating windows, focus and swaps, workspaces, the menu-bar workspace glyphs, recovery/help, and the launch-at-login choice. It uses the configured Hypr key and bindings. The menu bar has a Tutorial action, and the searchable keymap opened by the default **Caps + K** includes a Tutorial button. The misleading Command-Q label has been removed from Quit in the menu bar.

**Caps + P** is the default pause/resume shortcut. The keyboard event tap stays alive while tiling is paused, including when the app starts paused. Layout and mouse tracking stop; pause/resume and keyboard help remain available. Repeated key-down events do not toggle tiling repeatedly. Existing custom bindings remain authoritative: if Caps + P is already occupied, the new action is not injected over it and can be assigned in Settings. The existing default-merge rules also apply to configuration reloads.

The Focus indicator picker offers **Corners**, **Window borders**, or **None**. Dimming remains independent. Existing configurations with both enabled show **Both (saved)** until the user chooses another mode; the UI does not encourage creating that combined configuration. Color and shape controls appear with their corresponding indicator. Border colors are labelled **Tiled window color** and **Floating window color**. **Fade duration** replaces the internal-sounding Chrome fade label.

Corner marks have separate **Mark thickness** and **Mark length** sliders. Thickness controls the stroke width; length controls each straight segment. Mark roundness remains independently adjustable. Older saved thickness settings retain their previous segment length on upgrade, after which the two values can be changed independently. Both corner-radius controls have reset buttons. **Reset appearance defaults** restores the appearance baseline without changing layout, shortcuts, exclusions, or monitors. General settings retains the separate reset for all settings.

HyprMac's Settings, Tutorial, and keyboard-help windows now use a window level immediately above the passive border panels. Previously, they shared the same floating level, so ordering a border forward could draw it over the app's own interface. This changes overlay ordering only; it does not mutate managed window geometry or assignments.

Follow-up validation: the full isolated suite passed **832 tests, 94 display-dependent skips, zero failures** (738 non-skipped passes). The focused shortcut suite also passed. The new event-path regression sends synthetic keyboard events directly to the handler without installing an event tap or posting keys to the desktop. It verifies paused help, one pause dispatch despite autorepeat, and pass-through of ordinary shortcuts. Additional regressions cover reload migration, thickness-only updates, and atomic appearance resets. Log: `build/polish/tutorial-full-tests.log`.

The follow-up also passed the signed Debug build and unsigned Release compatibility build, both universal arm64/x86_64. Logs: `build/polish/tutorial-signed-debug-build.log` and `build/polish/tutorial-release-build.log`. At Zach's request, the signed build from `b5e95d5` was installed at the canonical MacBook Debug path and launched after resetting only its `hasSeenOnboarding` preference. Startup confirmed Accessibility trust and a running manager. The tutorial-sized interface window was present at window level 4, above the passive overlays. Configuration and release-app hashes remained unchanged. A remote screenshot was unavailable, so detailed visual acceptance remains with Zach.

## Drag intent and help follow-up

Before this change, ordinary tiled titlebar dragging inserted a window at the target edge, Option at release selected a same-tree swap, and Hypr had no effect on dragging. Keyboard Hypr+Shift+Arrow swapping remained available. The old cross-screen drag-swap handler had been removed; swap transactions themselves had not.

Holding **HYPR during a titlebar drag now requests a swap**. The logical Hypr state is latched during the press/drag, so releasing Hypr just before the mouse does not turn the gesture back into insertion. A plain drag still inserts. Option at release remains a compatibility shortcut. The existing transaction preserves resize precedence, size-limit validation, restoration on rejection, and the same-workspace/display boundary. Pressing Hypr during an active mouse press does not invoke focus repair.

Shortcut displays now say **HYPR**, with its physical key explained on tutorial page one and in the keymap header. The default is Caps Lock. The mouse-focus explanation uses plain wording. Complete default workspace families collapse to **Switch to workspace N** and **Move window to workspace N**, with N defined as 1–9. Settings disclosures reveal the individual editable bindings; incomplete or customized families remain explicit. Summary rows no longer hide a customized seed binding or imply that an arbitrary key is an arrow/number.

The Tutorial action now uses an explicitly wired callback from the actual SwiftUI delegate-adaptor instance. It no longer depends on a conditional cast of `NSApp.delegate`, which could silently skip the action. Menu and Settings use that same explicit route. The help panel accepts the first mouse click, and the full Tutorial pill is clickable. Reopening the tutorial replaces its previous window immediately rather than leaving multiple controllers/windows behind.

Validation: new drag regressions were introduced before implementation and the expected missing-API build failure was recorded. After implementation, **33 focused drag tests passed**, followed by **840 tests, 94 display-dependent skips, zero failures** in the full isolated suite (746 non-skipped passes). The suite covers swap-intent lifetime, Option compatibility, ordinary insertion, tutorial callback routing, HYPR formatting, and safe workspace grouping. Logs: `build/polish/hypr-drag-red.log`, `build/polish/hypr-drag-green.log`, and `build/polish/drag-help-full-tests.log`.

The drag/help follow-up passed signed Debug and unsigned Release builds, both universal arm64/x86_64. The signed `d64ffbd` build was installed and launched on the MacBook, with Accessibility trust and startup confirmed. The revised tutorial was reopened through the Debug-only onboarding reset, and its interface window was present above the overlay layer. Configuration and release-app hashes remained unchanged. Live gesture and button acceptance remain for Zach to try; no synthetic events were posted to the laptop. Build/deployment logs: `build/polish/drag-help-signed-debug-build.log`, `build/polish/drag-help-release-build.log`, and `build/polish/drag-help-deployment.log`.

## Simpler workspace display

The menu now answers one question per row: which workspace is this monitor showing? Each enabled monitor appears by name with its current workspace. The repeated global workspace grids, floating diamonds, and symbol legend are gone. The compact menu-bar label shows the current workspace numbers in left-to-right monitor order. Hover text names their monitors. Paused tiling and disabled indicators show the app icon instead of a stale workspace map.

The view consumes published monitor snapshots rather than querying the workspace manager while drawing. The existing indicator preference is preserved. The tutorial's first slide uses Zach's supplied wording for the default Caps Lock configuration, and the workspace slide reflects the new menu.

Validation passed 3 focused presentation tests and the full isolated suite: **843 tests, 94 display-dependent skips, zero failures** (749 non-skipped passes). The Release build passed. An offscreen render of the actual menu view at 280 points confirmed that the monitor/workspace rows fit without wrapping. The tutorial's offscreen renderer omitted several text layers, so that image was not used as visual approval. Logs and preview: `build/polish/menu-focused-tests.log`, `build/polish/menu-full-tests.log`, `build/polish/menu-release-build.log`, and `build/polish/menu-preview/menu.png`.

The signed universal Debug build from `49ac733` passed verification and was installed at the canonical MacBook Debug path. Startup confirmed Accessibility trust and a running manager. The tutorial was reopened using the Debug-only onboarding flag. Configuration and release-app hashes remained unchanged. Build and deployment logs: `build/polish/menu-signed-debug-build.log` and `build/polish/menu-deployment.log`.


## Restored menu-bar glyphs

Zach preferred the original always-visible workspace strip. The menu-bar label again uses filled circles/diamonds for workspaces currently shown on a monitor, hollow circles/diamonds for other occupied workspaces, and a small dot for an empty position. Diamonds indicate floating windows. Positions correspond to workspace numbers, with trailing empty workspaces omitted. Multiple monitors can produce multiple filled symbols. The strip remains visible while paused, matching its original behavior.

The clicked menu retains the simpler monitor-name/current-workspace rows from the previous change. A dedicated tutorial page explains the strip with numbered examples and a symbol legend. The first slide retains Zach's exact supplied text.

Both keyboard help and Settings → Keys now list **HYPR + drag** as a mouse gesture. Settings explains that holding HYPR while dragging a tiled window by its title bar onto another tile swaps them within the same workspace. This is a help entry, not a new editable keyboard binding.

Validation passed all 6 focused menu-presentation tests and the full isolated suite: **846 tests, 94 display-dependent skips, zero failures** (752 non-skipped passes). Signed Debug and unsigned Release builds passed for arm64 and x86_64. The signed `d38c064` Debug build was installed and launched on the MacBook after resetting its onboarding flag. Startup confirmed Accessibility trust and a running manager. Both configuration files and the release app remained byte-for-byte unchanged. Logs: `build/polish/glyph-focused-tests.log`, `build/polish/glyph-full-tests.log`, `build/polish/glyph-signed-debug-build.log`, `build/polish/glyph-release-build.log`, and `build/polish/glyph-deployment.log`.

### Control groups

Mark roundness, length, thickness, and corner color form one group without internal dividers. With window borders enabled, tiled color, floating color, and fade duration form one group. Fade remains available for dimming even when window borders are disabled. Fresh installs select Corners with persistent window borders off. Explicit saved choices remain intact.

### Launch at login setup

The tutorial ends with an optional launch-at-login prompt. Skip goes directly to this prompt; Not now closes setup without changing login items. Yes registers the current app through Apple's `SMAppService.mainApp`. An enabled service is confirmed from macOS status. If approval is required or registration fails, HyprMac opens Login Items and displays the remaining steps. General settings provides the same enable/status controls and a way to manage Login Items later. Returning from System Settings refreshes the status. The choice is local to this Mac and is not synced through UserConfig.

Registration is tested with injected service actions so the suite does not modify real login items. Actual first-login launching and approval UI need a manual macOS check. References: [Apple SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice) and [Login Items instructions](https://support.apple.com/en-ca/guide/mac-help/-mh15189/mac).

## Workspace shortcut update

The current app has ten regular workspaces. The earlier nine-workspace screenshots and validation counts above describe their original builds. Complete shortcut families now cover keys 1–9 and 0, with 0 selecting workspace 10. The overview uses two rows of five. Hypr+F moves the focused window to the next empty workspace on its display; Hypr+Shift+T cycles floating windows, and Hypr+T still toggles floating. Custom bindings and occupied chords are preserved during migration.

## Hypr key system guidance

macOS applies System Settings → Keyboard → Keyboard Shortcuts… → Modifier Keys before my `hidutil` mapping and before any CGEvent exists. If Caps Lock is set to "No Action" there, the key never reaches HyprMac and the Hypr key is simply dead. The same holds for Control, Option, and Command when one of those is the chosen Hypr key. The pane is per keyboard, so each keyboard needs its own check. Tab, backtick, backslash, F13–F20, and Shift are not listed in that pane and need nothing.

There is no supported API to read that setting. `KeyRemapper.clearSystemModifierOverrides` pretended otherwise and was a proven no-op: `UserDefaults(suiteName: UserDefaults.globalDomain)` is rejected by Foundation and never exposed the ByHost keys it filtered for. I removed it and its call site. HyprMac no longer tries to change the user's Modifier Keys setting.

In its place I added `HyprKeySystemGuidance`, a pure model that returns the required setting for the chosen key, or nil when the pane cannot remap it. It carries the title, the detail, the settings path in words, and the `x-apple.systempreferences:com.apple.Keyboard-Settings.extension?CustomizeModifierKeys` deep link. The permissions gate shows it as a second row under Accessibility with a "CHECK" tag — never "Granted" and never a checkmark, because I cannot verify it. The tour's first page and the Settings → Keys Hypr panel show the same line with an Open Keyboard Settings button. All three hide when the selected key needs no guidance. The Settings keycap also stopped showing a hardcoded ⇪ and now follows the selected key's badge.

Validation: the tests were written first and failed to compile, as recorded. After implementation, 9 focused guidance tests passed, `WelcomeContentTests` passed, and the full isolated suite passed **881 tests, 23 skipped, zero failures** — the 872-test baseline plus the 9 new ones. The real `HyprMac.xcodeproj` built clean in Debug, and the signed universal Debug build passed. `project.pbxproj` was regenerated with `xcodegen generate` to pick up the new source file.

One note on the harness: a full run leaves `focusBorderColorHex` set to `123456` in its isolated home, so the next run of `ConfigUpdateCoordinatorTests` sees no change and two tests fail. I reproduced this at `46c2496` with no changes of my own, so it predates this work. Deleting the isolated home's `config.json` clears it. Logs: `build/guidance/red.log`, `build/guidance/green.log`, `build/guidance/welcome.log`, `build/guidance/full-tests.log`, `build/guidance/xcode-debug-build.log`, and `build/guidance/signed-debug-build.log`.

## Brand mark and hypr chips

Zach flagged the Settings → Keys Hypr panel as cluttered, with a truncated "Open Keyboard…" button and the old cyan caps-lock keycap. The panel now shows the brand mark, a title, one line, and the key picker. The Modifier Keys reminder is one row under it: a single sentence, an info button whose popover holds the full explanation, and a fully visible "Open Keyboard Settings…" button. It still hides when the chosen key isn't in that pane. The permissions gate row is titled "Modifier Keys" and uses the same short sentence plus "HyprMac can't check it."

`HyprMac/Shared/HyprMark.swift` draws the mark in SwiftUI from the brand kit's `hyprmac-mark-h` geometry, so it needs no asset and stays sharp at any size. `HyprLockup` (mark plus "HyprMac" in SF Pro Semibold, caps as tall as the key) replaces the mono "HYPRMAC" wordmark in the Settings sidebar, the menu, the tutorial and What's New header, and the permissions gate.

The Hypr modifier now renders as a cyan "hypr" keycap everywhere a chord is drawn as chips: keybind rows, the recorder, workspace family summaries, the mouse gesture row, the menu, and the tutorial. The Hypr+K overlay keeps its own HYPR style. Chips never wrap; the row title truncates instead. Workspace families use a custom disclosure row so their chips line up with the rows below. The menu is 320 points wide so "Workspace overview" fits next to its chord.

Smaller fixes: the ACTIVE badge sits next to its toggle, the corner color well no longer overflows its row, recorder pills share one height, and the tutorial's Tab keycap no longer reads "Tab TAB".

`HyprMacTests/InterfaceSnapshotTests.swift` renders these views offscreen at 2x. It is skipped unless `HYPRMAC_RENDER_UI` names an output directory, and it restores the isolated config's Hypr key and keybinds afterwards:

```
HYPRMAC_RENDER_UI=/tmp/ui-shots ./scripts/test-isolated.sh --debug-variant InterfaceSnapshotTests
```

Validation: the full isolated suite passed twice in a row, 1021 tests, 27 skipped, zero failures. Visual acceptance on the MacBook is still Zach's.
