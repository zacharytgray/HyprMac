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
    case moveWindowToMonitor(Direction)
    case toggleFloating
    case toggleSplit
    case showKeybinds
    case launchApp(bundleID: String)
    case focusMenuBar
    case focusFloating
    case closeWindow
    case cycleWorkspace(Int)
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

## JSON wire format

The `Codable` implementation in `Models/Action.swift` preserves the
v0.4.2 synthesized format byte-for-byte. Each case encodes as a
single-key object with the case name as the key and the payload as
the value:

```json
{ "switchDesktop": { "_0": 3 } }
{ "focusDirection": { "_0": "left" } }
{ "launchApp": { "bundleID": "com.apple.Terminal" } }
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
  At the top level the array decoder (synthesized for `[Keybind]`)
  rejects the whole array on the first bad entry — see "Per-element
  tolerance" below.
- **Optional `SavedConfig` fields**: missing fields decode as `nil`
  and the runtime applies the matching default from
  `UserConfigDefaults`.

## Per-element tolerance (known limitation)

The `[Keybind]` array decode is the synthesized one — it throws on
the first bad keybind and rejects every subsequent entry. A safer
behavior — skip the bad keybind, keep the rest — is tracked but not
implemented. The right place to add it is when `ConfigStore` grows
a custom `loadSavedConfig` with explicit per-element decoding,
likely as part of a future schema migration.

`KeybindDecoderToleranceTests.testUnknownActionKeyThrows` pins the
strict behavior so a regression to silent-skip would fail the
suite.

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
{ "keyCode": 123, "modifiers": { "rawValue": 1 }, "action": { "focusDirection": { "_0": "left" } } }
```

Restart HyprMac after editing. Example — bind Hypr+B to launch Safari:

```json
{ "keyCode": 11, "modifiers": { "rawValue": 1 }, "action": { "launchApp": { "bundleID": "com.apple.Safari" } } }
```

**Modifier rawValues** (bitwise OR to combine — see
`Models/Keybind.swift`): `1` Hypr, `2` Shift, `4` Option, `8`
Control, `16` Command. Hypr+Shift = `3`, Hypr+Ctrl = `9`.

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
