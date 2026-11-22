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
    case toggleMaximize
    case closeWindow
    case cycleWorkspace(Int)
    case resizeDirection(Direction)
    case toggleScratchpad
    case moveToScratchpad
    case toggleTiling
    case runCommand(label: String, command: String)
    case saveLayout
    case restoreLayout
    case retileAll
    case showWindowRules
}
```

`Direction` is `enum Direction: String, Codable { left, right, up, down }`.

`cycleWorkspace(Int)` takes `+1` (next occupied workspace on the
current monitor) or `-1` (previous). `moveWindowToMonitor` honors all
four directions: it moves the focused window to the visible workspace of
the nearest enabled monitor that lies wholly in that direction, left and
right for side-by-side arrangements, up and down for stacked ones. The
pick is `WorkspaceOrchestrator.nearestScreenIndex`, a pure function over
`NSScreen.frame` rectangles: nearest along the axis wins, a tie goes to
the monitor sharing the most extent with the source on the cross axis.
Nothing that way beeps and flashes. Defaults are Hypr+Ctrl+arrow. The
case was repurposed from the old workspace-to-monitor move, which static
anchoring made a permanent no-op; its wire key is unchanged (see below).

## Maximize, dedicated workspace and workspace 10

`toggleMaximize` defaults to Hypr+F and encodes as `{"toggleMaximize":{}}`. It
is unavailable while paused or while the scratchpad is up, and ignores keyboard
autorepeat. See "Maximize" in `docs/tiling-algorithm.md`.

`moveToNextEmptyWorkspace` encodes as `{"moveToNextEmptyWorkspace":{}}`. It has
had no default chord since config v2, when `ConfigMigration` moved Hypr+F to
`toggleMaximize` for anyone still on the old default. It stays bindable, and
its link still works. A chord on it set after v2 is left alone, which is why
that migration is gated on the saved `version`. `focusFloating` defaults to
Hypr+Shift+T. `moveToNextEmptyWorkspace` is unavailable while paused and
ignores keyboard autorepeat. It selects the actual AX-focused managed window,
not the cursor's monitor, and moves it to the next empty workspace anchored to
its physical display. See `docs/architecture.md` for eligibility and failure behavior.

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
and Hypr+Ctrl+Shift+0 for workspace 10. No offered Hypr key is Control or
Shift, so the chord works under all of them.
Hypr+Shift+N (`moveToWorkspace`) stays silent: it follows only when the
destination is already showing on another monitor.

It encodes under its own key, `{"moveToWorkspaceAndFollow":{"_0":N}}`,
with the same payload as `moveToDesktop`. The key is frozen like the others.

`WorkspaceOrchestrator.moveToWorkspace(N, follow: true)` runs the same checks
as the silent move and never switches when the move does not happen: a
refusal beeps and shakes, and no focused window or a window already on N
does nothing. Both moves ignore a number outside 1–10 with a beep; a hand
edit is the only way to get one. After that:

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
bind the layout action by hand. Both actions are dropped, with a beep,
while a display transition is settling (`ActionPolicy.isDroppedMidDisplayTransition`).
The workspace actions are dropped the same way.
The launch toggle is `restoreLayoutOnLaunch` in `config.json`, off by
default. What save and restore do is in `docs/architecture.md`
("Layout persistence").

Downgrade risk: a build older than per-keybind tolerance that shares
`config.json` over iCloud fails the whole decode on the unknown
`saveLayout` key and falls back to defaults, as described under
"Per-element tolerance" below. That is not fixable from this side.
Keep every machine sharing a config on a tolerant build.

## Retile all spaces

`retileAll` defaults to Hypr+R and encodes as `{"retileAll":{}}`.
It runs the same pass as the menu bar's "Retile all spaces": it hides the
scratchpad, redistributes every window, and applies window rules (below).
It ignores key autorepeat, is unavailable while tiling is paused, and is
dropped, with a beep, while a display transition is settling.
`mergeNewDefaults` injects it only onto a free chord. No `ConfigMigration` step is involved.

```json
{"retileAll":{}}
{"action":{"retileAll":{}},"keyCode":15,"modifiers":1}
```

## Window rules

`windowRules` in `config.json` pins an app to a workspace, or to the scratchpad
with `"workspace": 0`. Settings → General → "Pin apps" edits it, one rule per
app:

```
"windowRules": [
  { "bundleID": "com.apple.Terminal", "workspace": 2 }
]
```

- **Scratchpad pins.** A new window joins the scratchpad and brings it up
  (`ScratchpadController.adoptPinned`). At launch and on Retile All, the app's
  open windows park in it with the layer down, so it fills again after a
  restart. A build without this option reads `0` as a pin to nothing.
- **New windows.** `ActionDispatcher.assignNewWindows` uses the pin as the
  preferred workspace instead of the one visible where the window opened.
  A pin also wins over opening an app's first window on the monitor under
  the pointer (see the initial assignment paragraphs under "Forced
  insertion" in `docs/tiling-algorithm.md`).
  A full pinned workspace spills onward, like any admission. If the pin
  sent the window somewhere else, HyprMac switches to that workspace and
  focuses the window afterwards, the Hyprland default. With several such
  windows in one pass it follows the focused one.
- **Reopened windows.** Some apps (Mail, Teams, Mimestream, Slack) reuse a
  closed window's id, so discovery reports the reopen as a return of the
  ghost. When a verified close comes back on screen while its recorded
  workspace is hidden, discovery drifts it onto the visible workspace,
  floating or tiled, and
  marks it (`WindowChanges.reopenedOntoHiddenWorkspace`). For a pinned app
  that drift is dropped and the window goes through `assignNewWindows` like
  a new window: its pin, the same spill and the same follow. A scratchpad
  pin adopts it. The log reads `window rule: <bundle> (<id>) reopened,
  pinned to ws<N>`. Any other return keeps its workspace, including a
  reopen or flap on its own visible workspace. An unpinned app's reopen
  still drifts to the visible workspace.
- **Never tile apps, and windows a float rule covers.** They stay floating
  and still go to their pin.
  `WorkspaceOrchestrator.placePinnedFloater` carries the floater to the
  workspace's display, and parks it with that frame saved when the
  workspace is hidden. A reopened one starts from the frame it reopened at,
  not one its ghost saved before the close.
- **Retile All.** `WindowPlacement.startupPlacement` gives pinned windows
  their own batches ahead of the screen batches, so they claim their
  workspace first. Pinned floaters move too. Hidden windows and scratchpad
  members keep their workspace. Startup and a Maximum splits change run
  the same pass.
- **Skipped:** Quick Look previews (they belong to whichever app opened
  them), windows on a disabled monitor, a rule naming a workspace outside
  1–10, and windows that come back from a minimize, Cmd-H or an unreadable
  hold (they keep their workspace). A new pinned window that
  finds every workspace full stays on the one where it opened.

Between those moments a pin is not a tether: a window moved elsewhere
stays there until the next Retile All. The array decodes per element,
like `keybinds`: a malformed rule is logged and dropped, and an
unreadable `windowRules` value costs only the rules.

Downgrade: an older build sharing `config.json` over iCloud ignores
`windowRules` and writes the file without it on its next save, so the
pins are lost on every machine. Keep machines that share a config on a
build with window rules. No `ConfigMigration` step is involved.

## Float and tile rules

The user's word on what floats. Settings → General → "Float and tile rules"
lists every rule, with a Float/Tile switch and a remove button on each row.

- **App float** is Never tile: the app's bundle id in `excludedBundleIDs`,
  the list that has always held it. Configs and Nix modules that set it
  work unchanged. There is no migration.
- **App tile and window rules** live in `floatingRules`, written only when
  there is at least one:

```
"floatingRules": [
  { "bundleID": "us.zoom.xos", "action": "float", "match": { "titleIs": "Zoom Meeting" } },
  { "bundleID": "com.microsoft.teams2", "action": "tile", "match": { "titleContains": "Meeting" } },
  { "bundleID": "com.apple.FaceTime", "action": "tile", "match": { "titleIs": "FaceTime" } }
]
```

`action` is `float` or `tile`. `match` holds exactly one criterion: `titleIs`
(the exact title) or `titleContains` (ignoring case). With no `match` the rule
covers the app. There is no rule for windows above normal windows
(picture-in-picture, call pop-ups): discovery binds only layer-0 windows, so
those are never managed and already float.

**Precedence**, highest first: Quick Look previews and windows on a disabled
monitor (always float, outside rules); the user's own choice for that window
(below); a window rule, the first that matches in list order; the app's rule;
HyprMac's automatic logic (a window whose size AX can't set floats). A hand
edit that puts an app in `excludedBundleIDs` and gives it an app tile rule
floats it, as before tile rules existed. Settings never makes that state:
picking one removes the other.

A first Hypr+T on a window that keeps a length no slot can hold (its own
fixed-size record, or its app's hint at the length it stands at) is refused
with the shake before anything moves; a second within 5 s tries for real, in
case the app let go of it.

**The user wins.** A direct action on a window beats every rule for it, Never
tile included, until the window closes: Hypr+T, tiling
or untiling it in the scratchpad, and the dedicated workspace move
(`FloatingWindowController.noteManualChoice`). No rule refuses those. Only a
window that can't take a tile fails, as before: the red shake, or a float in
place, with no retry loop. Rules then leave that window alone: a rule edit
skips it, the late-title re-check skips it, and Retile All keeps a window the
user tiled by hand tiled. A window floated by hand goes back to tiling on
Retile All, as it always did. The choice is forgotten when the window closes
(fully forgotten, or reopened after a verified close).

A tile rule never tiles a window HyprMac can't resize. At admission it stays
floating with one `.notice` line; from the overlay or the menu it gets the red
shake and no rule is saved. The same precedence answers at every place that
asked about Never tile: admission (`WindowDiscoveryService.admitNew`), startup
and Retile All (`FloatingWindowController.autoFloatReason`), a move to a
workspace and the scratchpad (`isNeverTile`, `floatRule(for:)`).

**The window rules overlay**, `showWindowRules`, default Hypr+I:

```json
{"showWindowRules":{}}
{"action":{"showWindowRules":{}},"keyCode":34,"modifiers":1}
```

A small card over the focused window, fixed when the key is pressed. It
shows the app, the window's title and the rule that covers it, and offers
permanent rules only (floating or tiling one window once is Hypr+T): always
float or always tile all of the app's windows (the one in effect is not offered again); always
float or always tile windows whose title is, or contains, the text in an
editable field prefilled with the window's title, which the user trims (a
Teams chat window carries the chat's name, so "Chat |" or the app name is the
usual edit); and forget the rule that covers it. Up and Down choose, Return
applies, Esc closes, and a mouse works. The title field and its is/contains
switch appear only under a picked title row; the field takes the typing and
Tab switches is/contains. Until then, the title rows say "edit title…". A click
on an app row or Forget applies it at once. A click on a title row picks it
and opens the field, like the arrow keys; a second click on the row (its ↩
chip included) or Return applies it. Hypr+I again closes it, and so does moving on: a
click elsewhere, another app coming forward, any other HyprMac action, or the
window going away. It is the same glass card, type and key chips as Hypr+K,
and it never activates HyprMac: a non-activating key panel takes the keys,
and closing hands focus back to the window. A new
rule goes ahead of the app's older ones. Forget removes the rule that decides
the window: a title rule, the app tile rule, or the app from Never tile. Any
rule set here for a window also drops the user's hand choice for it: it is the
newest word. Hypr+I is added for existing configs by `mergeNewDefaults` only
when the chord is free; no `ConfigMigration` step is involved.

**The menu bar's "Focused window" section** takes the window that had focus
when the menu opened, and acts on it whatever hover does while the menu is up
(hover focus is paused while a HyprMac panel is open). It shows the rule that
covers it, "Edit rule for this window…" (the overlay), "Always float all
<App> windows", "Always tile all <App> windows", and "Forget rule for this
window". Rows wrap to two lines.

**After a failed tile.** When HyprMac tried to tile a new window, failed, and
floated it in place (`AdmissionRecovery`), it offers once per app, a moment
later: "<App> window couldn't tile. Always float windows like this?" with
"Choose…" (the overlay on that window) and "Not now". It is HyprMac's own
panel, takes no focus, needs no notification permission, and hides after
10 s. Not shown when the window tiled meanwhile, a rule covers it, or the user
toggled it; not for a window that is simply not resizable. Asked apps are kept
per Mac in UserDefaults (`FailedTilePromptedApps`), not in the config.

**Live, for edits on this Mac.** A change made in Settings, the menu bar or the
overlay (`UserConfig.floatingRulesEdited`) re-applies to open windows whose
verdict changed (`FloatingWindowController.applyRuleChange`). A change that
arrives by reload, from iCloud, a Nix rebuild or a hand edit, or from Reset
all settings (`floatingRulesReloaded`), moves nothing open, as Never tile
edits never did: it reaches new windows, Hypr+T and Retile All. Mid display
transition a local edit waits until the screens settle, and a window it moves
leaves any maximize first. On a local edit, one that a rule now floats
floats, back to its pre-tile frame when that is on its screen; one that a
tile rule now covers, or whose float rule is gone, tiles if it can. A window
with a hand choice, scratchpad members, hidden windows and windows on a
disabled monitor keep what they have. A window on a hidden workspace changes
state now and shows it on reveal.

**Late titles.** Apps often name a window a moment after it opens. A new
window of an app with title rules, that no window rule matched at first sight,
is asked again at 0.5, 1, 2 and 4 s when its title has changed. The first
match applies once, and later title changes are ignored. A window the user
floated or tiled in between is skipped. Logs: `title rule re-check: <id> now
matches …`.

Downgrade: an older build ignores `floatingRules` and drops it on its next
save, like `windowRules`. App floats survive, since they are
`excludedBundleIDs`. The array decodes per element: a rule with an unknown
action or a malformed match (including `"match": null` and an unknown key such
as `raised`, which an unreleased build wrote) is logged and dropped alone.

## Workspace names

`workspaceNames` in `config.json` gives workspaces 1–10 an optional name.
Settings → General → "Workspace names" edits it:

```
"workspaceNames": { "4": "term" }
```

A set name replaces the number in the switch HUD, the menu bar panel
(buttons, tooltips), the workspace pickers in Settings and the
"is full" flash. Overview cards show it after the number (the digit
keys still switch by number) and its search matches it. The Compact
menu bar style puts a name that is one Latin letter or digit (SF Symbols
has badge symbols only for those) in the badge in place of the number
(`w.square`, filled and circled as the number would be). Any other name
replaces the badge with text, in full, beside the fullscreen icon while
the workspace has a maximized window. The Full menu bar glyphs, the
keybind list and log lines keep the number. All readers go through
`UserConfig.workspaceDisplayName`; a missing or blank name falls back to
the number. Keys other than "1"…"10" and empty names are dropped on load,
and an unreadable value costs only the names. An older build ignores the
key and drops it on its next save. No `ConfigMigration` step is involved.

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
`moveToNextEmptyWorkspace`, `moveToWorkspaceAndFollow` or `retileAll`.

The `hyprmac://action/<name>` link names (`ExternalCommand.actionNames`,
`docs/external-control.md`) are a second frozen list. They use the Swift
case names, not these wire keys, and `ExternalCommandTests` pins them.

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
  these types. `version` stays strict too, because it picks which
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
Before per-element tolerance, that one unknown key threw, the whole
file counted as unreadable, and the
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

`config.json` carries a top-level `version`. The current schema is 2
(`ConfigMigration.currentVersion`), and every save writes it:
`UserConfig.makeSavedConfig` sets `version: ConfigMigration.currentVersion`.

`SavedConfig.version` is an `Int?` so older files still decode. A file with no
`version` key reads as version 1 (`ConfigMigration.schemaVersion(of:)`), which
covers every config written before the bump.

Steps gated on the version run only when the loaded file is older:

- v1 → v2: Hypr+F moved from `moveToNextEmptyWorkspace` to `toggleMaximize`
  (`ConfigMigration.migrateHyprFToMaximize`). It rewrites the bind only while
  Hypr+F is still the shipped default and nothing else is bound to maximize.
  The next save writes `version: 2`, so it runs once.

Other keybind moves (`migrateToggleFloating`, `migrateFocusFloating`) are not
gated on the version. They run on every load and leave a customized bind alone.

A file without `version` runs the v1 → v2 step on every load until a save
writes the key. Hand-written and Nix-managed files should set `version = 2`;
the Nix module adds it when `settings` leaves it out.

An older build that predates the bump reads `version` as an unknown key and
drops it on its next save, so the file reads as v1 again. That is safe: the
new build runs the v1 → v2 step again, and it changes only a Hypr+F that is
still the old default.

A future bump raises `currentVersion`, adds a step in `ConfigMigration` gated
on the old version, and updates `ConfigMigrationTests` and
`KeybindDecoderToleranceTests` for both shapes.

## Monitor-config split

Two on-disk files:

- `~/Library/Application Support/HyprMac/config.json` — main config.
  Synced via iCloud Drive when the user enables sync (resolves to
  a symlink into `~/Library/Mobile Documents/com~apple~CloudDocs/HyprMac/`).
- `~/Library/Application Support/HyprMac/monitor-config.json` —
  per-machine settings. Local only, never synced.
  `maxSplitsPerMonitor`, `disabledMonitors`,
  `outerPaddingPerMonitor`, `workspaceMonitors` and
  `workspaceMonitorsPerDisplaySet` live here. The first two
  used to live in `config.json`, but per-machine settings round-tripping
  through iCloud Drive clobbered each machine's setup. The status bar
  export keys `statusExportEnabled` and `statusHookCommand` live here
  too, set by hand with no Settings UI (see [status-bar.md](status-bar.md)).
  So does `externalControlEnabled`, which Settings → General → System turns
  on and off (see [external-control.md](external-control.md)).
  HyprMac watches this file too and reloads it on change.

A file HyprMac can't decode is copied to `<name>.unreadable` before a save
overwrites it. A file that exists but won't open is not overwritten at all: the
save is skipped until it opens again. `<name>.replaced` holds
what iCloud set up or a reset replaced, including Keys → Reset to defaults. Reading never touches the file: HyprMac
runs on defaults until a save would replace it. With iCloud sync on, a launch
that can't read the linked file holds `config.json` saves instead. A launch can
also replace a regular local file with the link, keeping it as `<name>.replaced`.
If the `.unreadable` copy fails, the save is skipped. A copy
never overwrites an older one. Different content goes to `<name>.unreadable.2`,
then `.3`, and identical content is not copied twice. See Persistence in [architecture.md](architecture.md).

`ConfigMigration.resolveMonitorConfig` handles the migration: if
the local file is absent and the synced config has the old fields,
it adopts the synced values and returns `needsLocalWrite: true` so
the caller persists a local file. After one launch, the local file
is the source of truth and the synced fields are ignored.

`workspaceMonitors` is optional and maps a monitor name
(`NSScreen.localizedName`) to the workspaces that live on it, e.g.
`{"DELL U3225QE": [1, 2, 3], "LG HDR 4K": [4, 5], "Built-in Retina Display": [6, 7]}`.
Absent or empty means the formula homes, `(N - 1) % enabledMonitorCount`.
Unlisted workspaces, and workspaces listed under a monitor that is not
connected or is disabled, keep their formula home. A number listed under
two monitors goes to the one that is connected and enabled; under two of
those, to the name that sorts first, with one notice in the log. Numbers
outside 1–10 are ignored. A mapping that would leave an enabled monitor
with no workspace is ignored for that layout. Keys 1–9 and 0 still mean
workspaces 1–10. It decodes tolerantly like the other monitor fields: a
value this build can't read costs only `workspaceMonitors`. It was
local-only from the start, so there is no `ConfigMigration` step.

`workspaceMonitorsPerDisplaySet` is optional too. It is a list of the same
mapping, one per set of connected displays, and it is what Settings writes:
`[{"displays": ["DELL U4021QW", "LG SDQHD"], "workspaceMonitors": {"DELL U4021QW": [1, 2, 3, 4, 5, 6], "LG SDQHD": [7, 8, 9, 10]}}]`.
`displays` lists every connected display by name, disabled ones too, in any
order; list a name twice for two displays of one model. The entry whose
`displays` match the connected set exactly applies, even an empty mapping
(the formula on that set). Any other set uses `workspaceMonitors`, which
Settings no longer writes. So once a set has an entry, a hand edit of
`workspaceMonitors` no longer changes that set. The first Settings edit on
a set creates its entry from the mapping it had. A bad entry costs only
itself; a value that isn't a list costs only this field; a second entry
for one set loses to the first. The field is additive and missing means
`workspaceMonitors` everywhere, so there is no `ConfigMigration` step. A
build from before it ignores the field, uses `workspaceMonitors`, and drops
the field on its next save.

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

### Double-tap Hypr to toggle Caps Lock

`doubleTapHyprTogglesCapsLock` in `config.json`, off by default, is the
toggle of the same name in Settings → Keys. With Caps Lock as the Hypr key
there is otherwise no way to turn Caps Lock on while HyprMac is active.

`HyprDoubleTap` (in `HotkeyManager.swift`) decides. A tap is a press and
release of the Hypr key within 300 ms with no other key or modifier going
down. Two taps count when the second press starts within 300 ms of the
first release. Then `KeyRemapper.toggleCapsLock` flips the lock state, LED
included, through `IOHIDSetModifierLockState`. It works for every Hypr key
choice.

- A chord (Hypr plus a key), a hold, or a key between the taps starts over,
  so fast Hypr chords never toggle. Four taps toggle twice.
- Only a real release counts. A reset after a wake, a tap timeout or a
  pause is not a release.
- It is off while tiling is paused. Caps Lock is then a plain Caps Lock
  anyway (see "Caps Lock remap" in `architecture.md`).
- It does not work while secure input is on (a password field, or an app
  that leaves secure input on). macOS delivers no key events to the event
  tap then, so HyprMac never sees the taps. The Settings text says so.
- Mouse buttons are not in the tap's event mask, so a click between two
  taps does not start over.

Pinned by the double tap tests in `PhysicalCapsLockTests`.

## Hex color storage

`UserConfig.focusBorderColorHex`, `floatingBorderColorHex` and
`overlayAccentHex` are `String?` — `nil` means "use the system default", a hex string like
`"007AFF"` means "use this exact color".

`NSColor.fromHex` returns `nil` on malformed input and logs a
`.warning`. Invalid color strings fall back to the system default
silently rather than crashing.

## Config key reference

Every key HyprMac reads from its two config files. "Range" is what Settings
offers; a hand-edited value outside it is noted where HyprMac treats it
differently. A missing optional key uses its default. "File only" means no
Settings control writes it. Tabs and panels are named as Settings shows them.

### `config.json`

Synced over iCloud when sync is on.

| Key | Type | Range | Default | Changed in Settings |
| --- | --- | --- | --- | --- |
| `version` | integer | 2 | written as 2; missing reads as 1 | File only (see "Schema versioning") |
| `keybinds` | array of keybinds | — | required; missing built-in binds are added at load | Keys |
| `gapSize` | number (px) | 0–32, step 2 | required; 8 | Layout → Gaps → Inner gap |
| `outerPadding` | number (px) | 0–32, step 2 | required; 8 | Layout → Gaps → Outer padding |
| `enabled` | boolean | — | required; `true` | General → Status, the menu bar, Hypr+P |
| `hyprKey` | string | `capsLock`, `backslash`, `f13`…`f20`, `leftOption`, `rightOption`, `leftCommand`, `rightCommand`; also `tab`, `grave`, `leftShift`, `rightShift`, `leftControl`, `rightControl` (not recommended) | `capsLock` | Keys → Hypr key |
| `doubleTapHyprTogglesCapsLock` | boolean | — | `false` | Keys → Hypr key |
| `focusFollowsMouse` | boolean | — | `true` | General → Mouse |
| `mouseHoverPollHz` | integer (Hz) | 60, 120, 240; other values show as Custom, below 30 runs at 30 | 120 | General → Mouse → Hover response |
| `keepCursorOnWorkspaceSwitch` | boolean | — | `false` | General → Mouse |
| `excludedBundleIDs` | array of bundle IDs | — | `com.apple.FaceTime`, `com.apple.systempreferences` | General → Float and tile rules (Never tile) |
| `floatingRules` | array of rules | see "Float and tile rules" | none | General → Float and tile rules, the menu bar, Hypr+I |
| `windowRules` | array of rules | see "Window rules" | none | General → Pin apps |
| `workspaceNames` | object, `"1"`…`"10"` → name | non-empty names | none | General → Workspace names |
| `restoreLayoutOnLaunch` | boolean | — | `false` | General → Layouts |
| `overlayAppearance` | string | `system`, `light`, `dark` | `system` | General → System |
| `overlayAccentHex` | hex color | — | none (cyan and magenta) | Layout → Focus appearance |
| `showFocusBorder` | boolean | — | `false` | Layout → Focus appearance → Focus indicator |
| `focusBracketStyle` | string | `rounded`, `off` | `rounded` | Layout → Focus appearance → Focus indicator |
| `focusBracketColorHex` | hex color | — | none (black) | Layout → Focus appearance |
| `focusBracketRadius` | number (pt) | 0–32 | 20 | Layout → Focus appearance → Mark roundness |
| `focusBracketThickness` | number (pt) | 1–6, step 0.5 | 4.5 | Layout → Focus appearance → Mark thickness |
| `focusBracketLength` | number (pt) | 4–40; a file value is clamped to it | 15 | Layout → Focus appearance → Mark length |
| `focusBorderColorHex` | hex color | — | none (cyan) | Layout → Focus appearance → Tiled window color |
| `floatingBorderColorHex` | hex color | — | none (magenta) | Layout → Focus appearance → Floating window color |
| `focusBorderFlash` | boolean | — | `true` | Layout → Focus appearance → Flash on focus change |
| `animateFocusIndicator` | boolean | — | `true` | Layout → Focus appearance → Animate focus moves |
| `dimInactiveWindows` | boolean | — | `true` | Layout → Focus appearance |
| `dimIntensity` | number, 0–1 | 0–0.27; higher is file only | 0.135 | Layout → Focus appearance |
| `chromeFadeDurationSec` | number (s) | 0–1 | 0.13 | Layout → Focus appearance → Fade duration |
| `windowCornerRadius` | number (pt) | 0–32 | none (16 on macOS 26 and later, 10 before) | Layout → Focus appearance |
| `scratchpadTileByDefault` | boolean | — | `true` | Layout → Scratchpad |
| `scratchpadRegionInset` | number, fraction | 0–0.15 | 0.06 | Layout → Scratchpad → Layer padding |
| `showMenuBarIndicator` | boolean | — | `true` | Legacy. File only; read once to pick the first menu bar style, then ignored |

Corners and window borders at once (`focusBracketStyle` `rounded` with
`showFocusBorder` `true`) is file only. Settings keeps it and shows it as
"Both (saved)".

### `monitor-config.json`

Per Mac, never synced. Monitor names are `NSScreen.localizedName`, as
Settings shows them.

| Key | Type | Range | Default | Changed in Settings |
| --- | --- | --- | --- | --- |
| `maxSplitsPerMonitor` | object, name → integer | 1–7 | 3 | Layout → Per-Monitor Settings → Max splits |
| `disabledMonitors` | array of names | — | none | Layout → Per-Monitor Settings (the switch by each name) |
| `outerPaddingPerMonitor` | object, name → `top`/`left`/`bottom`/`right` | each side optional | none (`outerPadding`) | Layout → Per-Monitor Settings → Edge padding |
| `workspaceMonitorsPerDisplaySet` | array of `{displays, workspaceMonitors}` | workspaces 1–10 | none | Layout → Per-Monitor Settings → Workspaces |
| `workspaceMonitors` | object, name → workspaces | 1–10 | none (formula homes) | File only; the fallback for display sets with no entry |
| `externalControlEnabled` | boolean | — | `false` | General → System → Allow other apps to control HyprMac |
| `statusExportEnabled` | boolean | — | `false` | File only (see [status-bar.md](status-bar.md)) |
| `statusHookCommand` | string | — | none | File only (see [status-bar.md](status-bar.md)) |

Legacy keys, read for a one-time migration and never written:
`maxSplitsPerMonitor` and `disabledMonitors` in `config.json` (see
"Monitor-config split"), and `topPaddingPerMonitor` in `monitor-config.json`.

### Per-Mac preferences

Per-Mac options that are not in either file live in HyprMac's preferences
(`com.zachgray.HyprMac`), never synced. iCloud sync and the update switches
live there too.

| Key | Type | Range | Default | Changed in Settings |
| --- | --- | --- | --- | --- |
| `showDockIcon` | boolean | — | `false` | General → System → Show in Dock |
| `menuBarStyle` | string | `full`, `compact`, `hidden` | `full` | General → System → Menu bar |
| `HyprMacUpdatesManagedExternally` | boolean | — | `false` | `defaults` only; read at launch. `true` turns off the in-app updater for a copy something else updates (see README) |

## Hand-editing config.json

Config lives at `~/Library/Application Support/HyprMac/config.json`
(delete to reset to defaults). Keybind entries look like:

```json
{ "keyCode": 123, "modifiers": 1, "action": { "focusDirection": { "_0": "left" } } }
```

`ConfigStore` watches both files and reloads on change. It holds each file
open, so an edit in place shows at once. Every two seconds it also checks
which file each path reaches, so an atomic save, a re-pointed link (Home
Manager, Stow, chezmoi) or a swapped folder is picked up too. If an edit does
not show up, restart HyprMac.

A config file HyprMac can't write, such as a link into the Nix store, still
loads. Settings shows a read-only notice, and changes made there last until
the next reload. HyprMac never replaces a read-only file, even in a writable
folder. The iCloud switch stays off while the config is read-only, or while
another tool's link or linked folder puts it where it is. If an edit leaves the file unreadable, HyprMac keeps
its current settings. A copy of the broken file goes to `config.json.unreadable`
before the next save replaces it. A restart with the broken file runs on
defaults. Example — bind Hypr+B to launch Safari:

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

**Other config fields** (all keys, with types and defaults, are in
"Config key reference" above): `gapSize`, `outerPadding`, `enabled`,
`focusFollowsMouse`, `excludedBundleIDs` (Never tile: bundle IDs that
always float — auto-float on discovery; Hypr+T still tiles one by hand, and
a window tile rule can take one window out, see "Float and tile rules"),
`floatingRules` (app tile and window rules, see "Float and tile rules"),
`windowRules` (per-app workspace pins, see "Window rules"), `disabledMonitors` (in `monitor-config.json`: monitor names
matching `NSScreen.localizedName`, excluded from tiling entirely),
`outerPaddingPerMonitor` (in `monitor-config.json`: per-side outer
padding per monitor name, e.g.
`{"DELL U3225QE": {"top": 37, "left": 8}, "Built-in Retina Display": {"right": 60}}`;
`top`, `left`, `bottom` and `right` are each optional, and a missing side
or monitor uses `outerPadding`. An unreleased build wrote a top-only
`topPaddingPerMonitor` map; it still loads as top overrides when
`outerPaddingPerMonitor` is absent, and the next save drops it),
`scratchpadTileByDefault` (windows sent to the scratchpad tile into
the layer instead of floating; no-fit windows float regardless),
`scratchpadRegionInset` (per-edge inset fraction of the scratchpad's
tiled region, 0–0.15; 0.06 default keeps the scrimmed border visible,
0 is edge-to-edge).

Find any app's bundle ID:
`mdls -name kMDItemCFBundleIdentifier /Applications/AppName.app`
