# UI Overhaul — Implementation Plan

Source of truth: `handoff/HyprMac-UI-Spec.md` + mockups in `handoff/HyprMac Overhaul.dc.html`
(option ids 1a–1m, 2f/2g menu bar finals, 6d icon). Owner decisions locked in:

- **Chrome scope**: apply the new default *colors only* — focus border default → `hyprCyan`,
  floating border default → `hyprMagenta`, scratchpad scrim gets a 4% magenta tint over the
  45% black. Zero other changes to tiling visuals (no bracket/dim/fade behavior changes).
- Overlay = option A (1g). Icon = 6d (PNGs already rendered in `handoff/assets-new/`).
- Scratchpad work committed separately first (834a27c).

## Phase 1 — Foundations: tokens, chrome defaults, menu bar

**KeyChip → the shared key-cap chip** (`Settings/KeyBadgeViews.swift:37`)
- Fill `Color.gray.opacity(0.18)` → `Color.hyprSurfaceElevated`.
- Key-cap depth per spec §2: 1pt border, bottom edge ~1pt brighter (mockups:
  `border: rgba(255,255,255,.14)`, `border-bottom-color: rgba(255,255,255,.24)`).
  SwiftUI: gradient stroke (separator → brighter at bottom) or layered strokes.
- Propagates automatically to Settings rows, overlay, recorder (4 call sites).

**Brand chrome defaults** (`Models/UserConfig.swift`)
- `resolvedFocusBorderColor` (~L251): fallback `NSColor.controlAccentColor` → `NSColor.hyprCyan`.
- `resolvedFloatingBorderColor` (~L256): fallback `NSColor.systemOrange` → `NSColor.hyprMagenta`.
- No migration needed: unset users store `nil` hex; the resolver computes at runtime.
  Users with explicit hex keep their color.

**Scrim tint** (`Core/DimmingOverlay.swift` + scrim activation in `Core/WindowManager.swift` ~L886)
- DimmingOverlay fill is hardcoded `black.withAlphaComponent(intensity)`. Add an optional
  tint so the scratchpad scrim path renders 45% black + 4% `hyprMagenta` (pre-blend into a
  single fill color; normal focus-dim path unchanged, stays pure black).
- NOTE: this file just changed in 834a27c — read the current version, don't trust scout line numbers.

**Menu bar** (`App/MenuBarView.swift`, final mockups 2f dark / 2g light)
- Insert "Keybind cheat sheet" as FIRST action row (above Settings…), trailing ⇪ K KeyChips.
  Action: `(NSApp.delegate as? AppDelegate)?.windowManager?.handleAction(.showKeybinds)` + dismiss dropdown.
- Remove dead `shortcut: "⌘,"` from Settings row (~L157) — label was never wired.
- Workspaces panel footer: legend line `● active  ○ occupied  ◇ floating` (◇ magenta,
  hairline top border) + right-aligned magenta `⬒ N stashed` chip when
  `MenuBarState.shared.scratchpadCount > 0`.
- `workspaceBadge` ◇ marker (~L130) → `hyprMagenta`.
- "Check for updates…" row: trailing `v{appVersion}` mono tertiary
  (`Bundle.main…CFBundleShortVersionString`).
- Menu bar *label* stays template-tinted — no color changes there.

## Phase 2 — Hypr+K overlay restyle (option 1g)

`Core/KeybindOverlayController.swift` rewrite of chrome + content:
- Panel: no title bar. NSPanel subclass with `canBecomeKey = true`, styleMask
  `[.borderless, .nonactivatingPanel]` (Spotlight-style: key without activating the app).
  Width 560. Dark HUD surface ~96% opacity, radius 14, hairline border — drawn in SwiftUI
  (rounded rect), not `.hudWindow` chrome.
- Header: "Keybinds" + ⇪ K KeyChips left; "type to filter · esc to close" hint right
  (hint swaps to the live filter string while typing).
- Two-column grid per 1g: left = Focus & Navigation, Workspaces; right = Window Management,
  Apps + System. Empty categories drop; rebalance if a column is empty.
- Category headers: cyan, uppercase, tracked. Rows: description left, chord right in mono
  (per 1g rows — chips live in the header; rows use plain mono chords).
- Floating-related rows (toggleFloating, scratchpad actions) get a magenta ◇ suffix.
- Type-to-filter: local NSEvent keyDown monitor while panel is key — esc closes,
  chars/backspace edit a filter string, case-insensitive substring on actionDescription.
  Remove monitor on close.

## Phase 3 — Tour shell (replaces onboarding + welcome + what's-new)

New `Welcome/TourView.swift`; delete `OnboardingView.swift`, `WelcomeSlideView.swift`,
`WhatsNewView.swift`, `PaginationView.swift`. Keep `WelcomeContent.swift`
(WhatsNewFeatures + FeaturePage absorbed/restyled; `essentialKeybinds` dies with the slideshow).

- Shell (520×440, reuse `WelcomeWindowController` in `App/WelcomeView.swift`): header
  (30×30 `NSApp.applicationIconImage` + HYPRMAC wordmark mono kerned + right slot:
  `n / 4` page counter for first-run, version chip for what's-new), content page,
  footer (Skip · dots · Next, or single right-aligned Continue for what's-new).
  Styled on-system with Hypr tokens (mockups 1k/1l) — solid `hyprBackground`, panels
  `hyprSurface`, cyan accents.
- Modes: `WelcomeMode` → `{ firstRun, whatsNew }`. AppDelegate mapping: first launch →
  firstRun; legacy user (`lastSeenVersion == nil` but has seen onboarding) → whatsNew;
  version bump → whatsNew.
- First-run pages (4, cutting the old tip-dump):
  1. Hypr key hero — keycap graphic (rounded key, ⇪ CAPS LOCK, cyan glow ring), title
     "Caps Lock is your superpower", one-liner, **live try-it pill**: "Try it now — hold ⇪
     and press →" that flips to a ✓ confirmed state when the app sees a focusDirection action.
     Hook: ActionDispatcher posts `Notification.Name.hyprMacActionDispatched` (userInfo
     carries enough to identify focusDirection); Tour page observes. Follow the existing
     notification-name pattern (`.hyprMacWorkspaceChanged` etc. in MenuBarView.swift).
  2. Focus — cyan focus semantics (border, FFM, directional focus).
  3. Workspaces — Hypr+1-9, glyph language.
  4. Finish — points at Hypr+K overlay.
- What's-new page: changelog rows from `WhatsNewFeatures.current` (icon in tinted rounded
  square + title + one-liner, mockup 1l), single Continue.
- `AppDelegate.showOnboarding()` → `showTour()`; update the one call site
  (GeneralSettingsView "Getting started" row — Phase 4 restyles that row anyway).
- `xcodegen generate` after the file add/deletes.

## Phase 4 — Settings IA: 4 tabs → 3

**Shell** (`Settings/SettingsView.swift`): `SettingsTab` → `{ general, keys, layout }`,
labels General · Keys · Layout. Sidebar anatomy unchanged.

**Keys** (restyle `KeybindsSettingsView.swift`, mockup 1e):
- Hypr hero panel at top: 52×52 keycap glyph (⇪ cyan, key-cap borders), "Hypr key" title +
  one-liner, trailing physical-key Picker (absorbs today's hyprKeyPanel). Background: the one
  sanctioned gradient — `LinearGradient` cyan .09 → magenta .07 + cyan .22 border.
- Search field (header row, next to a cyan "＋ Add" button) filtering all rows incl. launchers.
- Categories: Focus & Navigation · Window Management · Workspaces · **Apps** · System.
  Apps = `.launchApp` binds rendered with app icon + "Launch / focus X" (port `launcherRow`
  styling from AppLauncherSettingsView). Drop the `nonLauncherBinds` filter; add `.apps`
  to visibleCategories.
- "＋ Add" is a Menu: "Keybind…" → KeybindEditorSheet; "App launcher…" → AppLauncherEditorSheet.
- Floating-behavior rows get the magenta ◇ suffix.
- Delete `AppLauncherSettingsView.swift` after moving `AppLauncherEditorSheet` out
  (own file or into KeybindsSettingsView). Selection/edit/delete interactions unchanged.

**Layout** (restyle `TilingSettingsView.swift`, mockup 1f):
- Gaps panel promoted to hero: sliders left, live `DwindlePreview` right that reacts to BOTH
  sliders (extend DwindlePreview to take gap/padding params).
- Focus Chrome panel: focus color row (chip reads "hyprCyan · default" when hex unset),
  floating color row **always visible** (remove the `showFocusBorder` gate, add magenta ◇),
  show-border toggle, dim toggle + intensity, "Chrome fade" slider with
  "shared by border + dim + scrim" footer.
- Per-monitor panel: unchanged (name + resolution, tiling toggle, max-splits pills, thumbnail).

**General** (mockup 1j, 7 → 5 panels):
Status (enable + ACTIVE badge + accessibility) · Mouse · Never Tile ·
System (menu-bar indicator + iCloud sync + launch-at-login MANUAL chip) ·
footer panel ("Replay the tour" › + "Reset all settings…" red). About panel dies
(version stays in the sidebar).

## Phase 5 — App icon (6d, assets already rendered)

Regenerate `Resources/Assets.xcassets/AppIcon.appiconset/` from
`handoff/assets-new/hyprmac-icon-1024-final.png` via sips (16/32/64/128/256/512/1024),
using the provided 256/64 exports for those exact sizes. Existing Contents.json slot
mapping reused. `AppIcon.svg` is stale — flag, don't block on it.

## Phase 6 — Verification + docs

- Full debug build + unit tests (baseline: DimmingOverlayTests state per repo-quirks memory).
- Update CLAUDE.md file structure + keybind/menu-bar descriptions where the overhaul
  changed reality (Welcome files, Settings tabs, overlay behavior).
- WhatsNewFeatures.current is NOT updated now — that happens at release time per the
  release checklist.

## Sequencing

Phases run sequentially (1 → 2 → 3 → 4 → 5 → 6); 2–4 all consume Phase 1's KeyChip;
3 and 4 both touch GeneralSettingsView. Each phase ends with a successful
`xcodebuild … build` before the next starts.
