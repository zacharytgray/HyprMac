# Keybinds and actions

Keybinds map a key chord to an `Action`. The `Action` enum is the
protocol between `HotkeyManager` (which produces values) and
`ActionDispatcher` (which applies them). This document is the
reference for the wire format and the schema-stability contract.

## Action enum

```swift
enum Action: Equatable {
    case focusDirection(Direction)
    case swapDirection(Direction)
    case switchWorkspace(Int)
    case moveToWorkspace(Int)
    case moveToWorkspaceAndFollow(Int)
    case moveWindowToMonitor(Direction)
    case toggleFloating
    case toggleSplit
    case showKeybinds
    case showWorkspaceOverview
    case launchApp(bundleID: String)
    case focusMenuBar
    case focusFloating
    case moveToNextEmptyWorkspace
    case closeWindow
    case cycleWorkspace(Int)
    case resizeDirection(Direction)
    case toggleScratchpad
    case moveToScratchpad
    case toggleTiling
    case runCommand(label: String, command: String)
    case saveLayout
    case restoreLayout
}
```

`Direction` is `enum Direction: String, Codable { left, right, up, down }`.

`cycleWorkspace(Int)` takes `+1` (next occupied workspace on the
current monitor) or `-1` (previous). `moveWindowToMonitor` accepts
the full four-way `Direction` for symmetry, but the orchestrator
only honors `.left` / `.right`. It moves the focused window to the
adjacent monitor's visible workspace — the case was repurposed from
the old workspace-to-monitor move, which static anchoring made a
permanent no-op; its wire key is unchanged (see below).

## Dedicated workspace and workspace 10

`moveToNextEmptyWorkspace` defaults to Hypr+F and encodes as
`{"moveToNextEmptyWorkspace":{}}`. `focusFloating` keeps its wire key and
now defaults to Hypr+Shift+T. The new action is unavailable while paused and
ignores keyboard autorepeat. It selects the actual AX-focused managed window,
not the cursor's monitor, and moves it to the next empty workspace anchored to
its physical display. See the README for eligibility and rejection behavior.

Regular workspace IDs are 1–10. The physical 0 key maps to ID 10:
Hypr+0 switches, and Hypr+Shift+0 sends. Their wire values remain
`{"switchDesktop":{"_0":10}}` and `{"moveToDesktop":{"_0":10}}`.
Internal workspace 0 still means scratchpad. No workspace renumbering or schema
migration is involved.

`mergeNewDefaults` first runs the legacy Shift+T Toggle Float migration, then
the narrow F-to-Shift+T Cycle Floating migration. The latter requires one exact
old default, an unambiguous F chord, a free Shift+T chord, and no saved dedicated
workspace action. Default injection then fills free chords for missing actions.
Custom and conflicting bindings survive unchanged. Startup/reload migration is
idempotent and is persisted on the next normal settings save; no schema-version
flag is added. An explicitly chosen binding identical to a legacy default cannot
be distinguished from that default.

## Move and follow

`moveToWorkspaceAndFollow(N)` moves the focused window to workspace N and
switches there with that window focused. It defaults to Hypr+Ctrl+Shift+1–9,
and Hypr+Ctrl+Shift+0 for workspace 10. Before this action Hypr+Ctrl+Shift
went only with the arrow keys (resize), so the digit chords were free. No
offered Hypr key is Control or Shift, so the chord works under all of them.
Hypr+Shift+N (`moveToWorkspace`) stays silent: it follows only when the
destination is already showing on another monitor.

It encodes under its own key, `{"moveToWorkspaceAndFollow":{"_0":N}}`,
with the same payload as `moveToDesktop`. The key is frozen like the others.

`WorkspaceOrchestrator.moveToWorkspace(N, follow: true)` runs the same checks
as the silent move and never switches when the move does not happen: a
refusal beeps and shakes, and no focused window or a window already on N
does nothing. After that:

- **Destination showing on another monitor:** the same as the silent move.
  The window is placed there, focused, and the cursor follows. No switch HUD.
- **Destination hidden:** the window leaves the source tree without a
  relayout and is not parked. `switchWorkspace(N, preferredWindowID:)` then
  hides the old workspace on the destination's monitor, lays out every
  visible workspace in one pass, and focuses the moved window. When the
  destination is on the source's monitor, the source is hidden as it
  stood. When it is on the other monitor, the source stays up and closes
  the gap in that same pass.
- **Floaters and Quick Look previews** stay floating, except a floater
  coming off a disabled monitor, which tiles as it does with the silent
  move. A floater bound for the other monitor is carried there first.

The cursor goes to where the window is going: its slot in the destination
tree, else the frame a floater was carried to, else its live frame. It
takes the first of those that lies on the destination screen, and falls
back to the middle of that screen. A `follow warp:` line at `.notice` says
which one it used. The live frame can still read the
source screen when the first layout attempt fails, and `ensureFocus` picks
from the screen under the cursor. So a follow that trusted it handed the
next Hypr press to a tile on the wrong monitor. The silent move's follow to
a showing workspace, and a window picked in the overview, use the same rule.

`mergeNewDefaults` injects the ten binds onto free chords only. A chord the
user already bound keeps the user's bind; that number then has no follow bind
until the user adds one in Settings, and the skip logs at `.notice`. A follow
action the user already bound to another chord is not injected again.

Downgrade: a build with per-keybind tolerance (v0.12.0 and later) that
reads a config holding these binds drops only them, then its next save
writes the file without them. This build re-injects the defaults on its
next launch; a customized follow chord is lost. A build older than v0.12.0
resets the whole config instead, as "Per-element tolerance" describes. No `ConfigMigration` step is involved, as with
`runCommand`, `moveToNextEmptyWorkspace`, `saveLayout` and `restoreLayout`.

## Save and restore layout

`saveLayout` and `restoreLayout` default to Hypr+Ctrl+S and Hypr+Ctrl+R
and encode as `{"saveLayout":{}}` and `{"restoreLayout":{}}`. Neither
chord is used by another default (`testEveryDefaultUsesUniqueChord`).
`mergeNewDefaults` injects each one only onto a free chord, so a user
who already bound Hypr+Ctrl+S or Hypr+Ctrl+R keeps that bind and can
bind the layout action by hand. Both actions are dropped while a
display transition is settling (`WindowManager.isDroppedMidDisplayTransition`).
The launch toggle is `restoreLayoutOnLaunch` in `config.json`, off by
default. What save and restore do is in `docs/architecture.md`
("Layout persistence").

Downgrade risk: a build older than per-keybind tolerance that shares
`config.json` over iCloud fails the whole decode on the unknown
`saveLayout` key and falls back to defaults, as described under
"Per-element tolerance" below. That is not fixable from this side.
Keep every machine sharing a config on a tolerant build.

## JSON wire format

The `Codable` implementation in `Models/Action.swift` preserves the
v0.4.2 synthesized format byte-for-byte. Each case encodes as a
single-key object with the case name as the key and the payload as
the value:

```json
{ "switchDesktop": { "_0": 3 } }
{ "moveToWorkspaceAndFollow": { "_0": 3 } }
{ "focusDirection": { "_0": "left" } }
{ "launchApp": { "bundleID": "com.apple.Terminal" } }
{ "runCommand": { "label": "Screenshot", "command": "/usr/sbin/screencapture -i ~/Desktop/shot.png" } }
{ "toggleFloating": {} }
```

Cases without payloads still encode as `{ "case_name": {} }` —
nested empty containers, matching the synthesized format Swift
produces for cases with no associated values.

## Frozen case keys

The JSON case keys are an API guarantee. The `switchWorkspace` /
`moveToWorkspace` / `moveWindowToMonitor` cases were renamed in code
(formerly `switchDesktop` / `moveToDesktop` /
`moveWorkspaceToMonitor`); the JSON wire format keeps the legacy
names indefinitely:

```swift
private enum CaseKey: String, CodingKey {
    case switchWorkspace     = "switchDesktop"
    case moveToWorkspace     = "moveToDesktop"
    case moveWindowToMonitor = "moveWorkspaceToMonitor"
    // ...
}
```

The decoder also accepts the new names as aliases, so a hand-edited
config using `switchWorkspace` or `moveWindowToMonitor` decodes
cleanly. The encoder always writes the canonical (legacy) name. End
result: existing user configs never see noisy churn after an
in-code rename — and existing `Hypr+Ctrl+arrow` binds picked up the
new move-window semantics with no config change.

This pattern generalizes — any future case rename should add an
alias entry rather than break the wire format.

A case added later is frozen at the key it first shipped with, such as
`moveToNextEmptyWorkspace` or `moveToWorkspaceAndFollow`.

## `AnyKey`

`Action.swift` declares a small file-private `AnyKey: CodingKey`
type that lets the decoder read the outer case-name key without
pre-declaring every accepted alias as a `CodingKey` case. It is
five lines and earns its keep by enabling the alias-map lookup. If
a similar dynamic-key reader appears elsewhere, it can move to
`Shared/`.

## Decoder tolerance

Malformed payloads are handled defensively rather than crashing.

- **Direction**: `Action.decodeDirection` accepts a `String`,
  returns the matching `Direction` when valid, and falls back to
  `.right` with a `.warning` log when the value is unknown. A typo
  in a hand-edited config does not take the app down.
- **Action case**: a payload key that matches neither the canonical
  spelling nor an alias throws a `DecodingError.dataCorruptedError`.
  One `Keybind` either decodes exactly or not at all. The
  containing `SavedConfig` then drops just that keybind. See
  "Per-element tolerance" below.
- **Optional `SavedConfig` fields**: missing fields decode as `nil`
  and the runtime applies the matching default from
  `UserConfigDefaults`. So does a value this build can't read: a case a
  newer build added, a changed type, a typo. That field is treated as
  missing and logs at `.notice`, and every other field decodes normally.
  `ConfigMigrationTests` pins each field. Two older exceptions do not
  log: an unreadable `overlayAppearance` decodes as `.system`, and an
  unreadable `focusBracketStyle` decodes as `.rounded`, because the key's
  presence marks the new bracket schema.
- **Core fields**: the `keybinds` array, `gapSize`, `outerPadding` and
  `enabled` stay strict, since every build since v0.4.2 writes them with
  these types. `version` stays strict too, because it will pick which
  migrations run.

## Per-element tolerance

`SavedConfig` decodes its `keybinds` array one element at a time.
An element that throws is skipped with a `.warning` log (the
action key itself stays out of the log because it is hand-editable
text); every other keybind and every other field decodes normally. The custom `init(from:)` lives in an extension in
`Persistence/ConfigStore.swift`, so the memberwise initializer
still exists and `encode(to:)` is still synthesized. The wire
format is untouched.

This matters because `config.json` is shared across machines over
iCloud Drive. When a newer build adds an `Action` case and
`UserConfig.mergeNewDefaults` injects its default keybind, an older
build sharing the file meets a case key it has never heard of.
Before per-element tolerance, that one unknown key threw, the
`try?` in `ConfigStore.loadSavedConfig` returned `nil`, and the
older machine silently reset gaps, colors, excluded bundles and
every keybind to defaults, then pushed the reset back through
iCloud on its next save.

If every keybind is skipped, `keybinds` is empty and
`UserConfig.mergeNewDefaults` repopulates the full default table,
so the user gets working binds rather than none.

Remaining caveat: an older build that skips a newer action and then
saves writes the shared file without that keybind. The newer
build's `mergeNewDefaults` re-injects the default bind on its next
launch, but a *customized* chord for that action is lost. Nothing
else in the config is touched.

`KeybindDecoderToleranceTests` pins both halves:
`testUnknownActionKeyThrows` for the strict single-keybind decode,
and the `testSavedConfig...` cases for the skip-and-keep-going
behavior plus the unchanged encoded key set.
`testLayoutSnapshotActionsRoundTripThroughSavedConfig` and
`testUnknownLayoutActionBesideKnownOnesKeepsTheRest` cover the two
layout actions.

## Schema versioning

`SavedConfig` carries an optional `version: Int?`:

```swift
struct SavedConfig: Codable {
    let version: Int?  // nil for v1 (the implicit version)
    // ...
}
```

The field is declared but not currently emitted. `ConfigMigration.currentVersion`
is `1`; the encoder constructs `SavedConfig(version: nil, ...)` so
the encoded JSON does not gain a `version` key. This keeps the wire
format byte-equal for unchanged settings — important when a user's
config round-trips through iCloud sync between machines on
different HyprMac versions.

The first concrete schema bump will be the moment to start
emitting a value. The decoder already maps `nil → 1`; bumping to
v2 means setting `version = 2` on encode, adding a v1 → v2 migration
case in `ConfigMigration`, and updating `KeybindDecoderToleranceTests`
to round-trip both shapes.

## Monitor-config split

Two on-disk files:

- `~/Library/Application Support/HyprMac/config.json` — main config.
  Synced via iCloud Drive when the user enables sync (resolves to
  a symlink into `~/Library/Mobile Documents/com~apple~CloudDocs/HyprMac/`).
- `~/Library/Application Support/HyprMac/monitor-config.json` —
  per-machine settings. Local only, never synced.
  `maxSplitsPerMonitor` and `disabledMonitors` live here. These
  used to live in `config.json`, but per-machine settings round-tripping
  through iCloud Drive clobbered each machine's setup.

`ConfigMigration.resolveMonitorConfig` handles the migration: if
the local file is absent and the synced config has the old fields,
it adopts the synced values and returns `needsLocalWrite: true` so
the caller persists a local file. After one launch, the local file
is the source of truth and the synced fields are ignored.

## Default keybinds

`Models/DefaultKeybinds.swift` holds the built-in keybind table.
`UserConfig.mergeNewDefaults` injects new defaults into existing
saved configs at load time, so users who upgrade pick up new
keybinds without resetting their customizations. New default
actions go in `DefaultKeybinds.swift`; the merge handles the rest.

The workspace number keys carry three families: Hypr+N switches,
Hypr+Shift+N moves the window, and Hypr+Ctrl+Shift+N moves it and
follows. `testEveryDefaultUsesUniqueChord` keeps every default on its own
chord. The Hypr+K overlay and Settings → Keys fold each complete family
into one row (`KeybindOverlayGrouping.workspaceRun`); a family with a
customized key is listed bind by bind.

## Run a command

`runCommand(label:command:)` binds a chord to a program of the
user's choosing. The payload is two strings: `command` is the
command line, and `label` is the name shown in the settings list and
the `Hypr+K` overlay. An empty label falls back to `Run <program
basename>`. `command` is required — a keybind without it is skipped
by the per-element tolerance in `SavedConfig`. A missing `label`
decodes as `""`.

**No shell.** `CommandRunner` tokenizes the line in-process and hands
`Process` an executable URL plus an argument array. Nothing is passed
to `/bin/sh`, so pipes, `;`, `&&`, redirects, globs and `$VAR` are
inert — they arrive at the program as ordinary arguments. Point the
keybind at a script when you need any of those.

**Quoting.** Whitespace (including a non-breaking space) separates
arguments. `"..."` and `'...'` group an argument that contains spaces.
A backslash escapes the next character outside single quotes, so a
line cannot end in one. A leading `~` or `~/` expands to the home
directory, only at the start of an argument and only when unquoted.

**Program lookup.** A token containing `/` is used as the path; a
relative one is taken from the home directory, which is also the
child's working directory. A bare name is searched for in the app's own `PATH` first, then in
`/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/bin`,
`/usr/sbin`, `/sbin` — the fallbacks matter because a GUI-launched
app inherits a minimal `PATH`. The match must be a regular
executable file.

**Runtime.** The child starts asynchronously from the home directory
with the app's environment; stdout, stderr and stdin go to
`/dev/null`. Nothing about the command — its text, arguments, paths
or output — is written to the log. A non-zero exit logs only the
status number (`runCommand exited with status 3`).

There is no default binding. The action ignores key autorepeat, so
holding the chord runs the program once, and — like Launch App — it
is unavailable while tiling is paused.

## Hypr key

`hyprKey` in `config.json` holds a `HyprKey` raw value. The Settings →
Keys picker offers `HyprKey.pickerChoices`: `capsLock` (the default),
`backslash`, `f13` through `f20`, `leftOption`, `rightOption`,
`leftCommand` and `rightCommand`.

`tab`, `grave`, `leftShift`, `rightShift`, `leftControl` and
`rightControl` are no longer offered. Tab and backtick are the keys of
default binds (Hypr+Tab and Hypr+Shift+Tab cycle workspaces, Hypr+`
focuses the menu bar), so either one as the Hypr key blocks them.
Default binds add Shift (Hypr+Shift+…) and Control (Hypr+Ctrl+…) on top
of Hypr, so either one as the Hypr key makes those binds unreachable or
awkward.

No default bind adds Option or Command on top of Hypr, and Apple
keyboards have both on each side, so both sides are offered. With a
left-hand key as Hypr, that key plus any key HyprMac binds goes to
HyprMac instead of the app: ⌘S, ⌘T, ⌘W and ⌘1–9, or ⌥← and ⌥→. Unbound
chords pass through unchanged. `HyprKey.leftModifierNote` says this under
the picker and points to the right-hand key for those shortcuts.

The dropped cases stay in the enum with their raw values, so a config
that already names a dropped key keeps it and keeps working.
`HyprKey.pickerRows(for:)` appends that key to the picker so the
selection still has a matching row, and `HyprKey.notRecommendedNote`
explains in one sentence why it is no longer recommended. The row goes
away once the user picks another key. There is no migration.

An unknown `hyprKey` value, such as a key a newer build added, decodes
as `nil` with a `.notice` log. This build then uses the default Hypr key,
Caps Lock, and keeps every other setting. With iCloud sync on, its next
save writes `capsLock` over the unknown value, and the newer machine
picks that up. Before this, an unknown value failed the whole decode,
`ConfigStore.loadSavedConfig` returned nil, and every setting reset.

Never remove a `HyprKey` case or change a raw value: its users would
silently move to Caps Lock. `HyprKeyPickerTests` pins the offered list,
the kept row, both notes, the default binds the notes name, decoding of
every dropped value, and the fallback for an unknown one. Modifier Keys guidance
(`HyprKeySystemGuidance`) covers Caps Lock, Option and Command, plus
Control for older configs.

## Hex color storage

`UserConfig.focusBorderColorHex` and `floatingBorderColorHex` are
`String?` — `nil` means "use the system default", a hex string like
`"007AFF"` means "use this exact color".

`NSColor.fromHex` returns `nil` on malformed input and logs a
`.warning`. Invalid color strings fall back to the system default
silently rather than crashing.

## Hand-editing config.json

Config lives at `~/Library/Application Support/HyprMac/config.json`
(delete to reset to defaults). Keybind entries look like:

```json
{ "keyCode": 123, "modifiers": 1, "action": { "focusDirection": { "_0": "left" } } }
```

Restart HyprMac after editing. Example — bind Hypr+B to launch Safari:

```json
{ "keyCode": 11, "modifiers": 1, "action": { "launchApp": { "bundleID": "com.apple.Safari" } } }
```

Example — bind Hypr+Ctrl+Shift+3 to move the window to workspace 3 and follow it:

```json
{ "keyCode": 20, "modifiers": 11, "action": { "moveToWorkspaceAndFollow": { "_0": 3 } } }
```

Example — bind Hypr+5 to an interactive screenshot:

```json
{ "keyCode": 23, "modifiers": 1, "action": { "runCommand": { "label": "Screenshot", "command": "/usr/sbin/screencapture -i ~/Desktop/shot.png" } } }
```

**Modifier values**: `modifiers` is a bare number, the bitwise OR of
the modifiers in the chord (see `Models/Keybind.swift`): `1` Hypr, `2`
Shift, `4` Option, `8` Control, `16` Command. Hypr+Shift = `3`,
Hypr+Ctrl = `9`, Hypr+Ctrl+Shift = `11`. An object such as
`{ "rawValue": 1 }` does not decode, and HyprMac drops that keybind.
`KeybindDecoderToleranceTests.testDocumentedJSONExamplesDecode` decodes
every JSON example in this file.

**Key codes** (decimal, Carbon `kVK_*`):

- Arrows: Left=123, Right=124, Up=126, Down=125
- Letters: A=0, S=1, D=2, F=3, H=4, G=5, Z=6, X=7, C=8, V=9, B=11,
  Q=12, W=13, E=14, R=15, Y=16, T=17, O=31, U=32, I=34, P=35, L=37,
  J=38, K=40, N=45, M=46
- Numbers: 1=18, 2=19, 3=20, 4=21, 5=23, 6=22, 7=26, 8=28, 9=25, 0=29
- Return=36, Space=49, Tab=48, Delete=51, Escape=53, Grave/Backtick=50

**Other config fields**: `gapSize`, `outerPadding`, `enabled`,
`focusFollowsMouse`, `excludedBundleIDs` (bundle IDs that never
tile — auto-float on discovery), `disabledMonitors` (monitor names
matching `NSScreen.localizedName`, excluded from tiling entirely),
`scratchpadTileByDefault` (windows sent to the scratchpad tile into
the layer instead of floating; no-fit windows float regardless),
`scratchpadRegionInset` (per-edge inset fraction of the scratchpad's
tiled region, 0–0.15; 0.06 default keeps the scrimmed border visible,
0 is edge-to-edge).

Find any app's bundle ID:
`mdls -name kMDItemCFBundleIdentifier /Applications/AppName.app`
