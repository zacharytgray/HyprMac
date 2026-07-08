# 01 — Current UI Inventory (surface by surface)

Every user-visible surface as it exists today (v0.7.0), with dimensions, current
structure, and the source file behind it. Use this as the "before" map.

Legend: **[NEW]** = already on the custom HyprMac design system. **[STOCK]** = still on
default macOS styling (redesign priority — see the inconsistency note in `README.md`).

---

## A. Menu bar dropdown  **[NEW]**
`HyprMac/App/MenuBarView.swift` · width **280pt** · background `hyprBackground`

The primary always-available surface. `MenuBarExtra(.window)` style. Vertical stack:

1. **Header** — `HYPRMAC` wordmark (mono, 2pt kerning) + a status line reading
   "Tiling active" (cyan) or "Tiling paused" (tertiary), with a custom pill toggle on
   the right that enables/disables the whole app.
2. **Workspaces panel** — a `HyprPanel` titled "Workspaces". One row per physical
   screen (with a `display` SF Symbol + screen number if multi-monitor). Each row shows
   a horizontal run of **workspace badges** 1…N (N = highest occupied/active). Badge
   states: active (cyan fill + border), occupied (elevated surface), empty (clear).
   A `◇` marker rides on badges whose workspace holds floating windows.
3. **Actions** — hover-highlighted rows: "Settings…" (⌘,), "Retile all spaces",
   "Check for updates…", divider, "Quit HyprMac" (⌘Q, red).

### The menu-bar label itself (the glyph in the system menu bar)
`WorkspaceIndicatorLabel` in the same file. A compact **dot-grid** string, one symbol
per workspace 1…N:
- `●` active · `◆` active + floating · `○` occupied · `◇` occupied + floating · `·` empty

Followed by a `tray`/`tray.fill` glyph + count when the scratchpad holds windows. Falls
back to a static `rectangle.split.2x2` icon if the indicator is disabled or there's no
data yet.

---

## B. Settings window  **[NEW]**
`HyprMac/Settings/SettingsView.swift` · default **760×600**, min **720×560** · pinned `.floating`

`NavigationSplitView` — custom sidebar (180–220pt, ideal 192) + detail pane.

**Sidebar:** `HYPRMAC` wordmark + `v0.7.0` at top; then 4 tab items, each a row with a
2pt cyan left-edge active indicator + SF Symbol + label; a footer button showing the
config file path (`~/Library/Application Support/HyprMac/config.json`) that reveals it
in Finder.

**Detail pane:** big page title (`hyprTitle`, 17pt semibold) + a scrollable stack of
`HyprPanel`s. Tabs:

### B1. General  `GeneralSettingsView.swift`
Panels, top to bottom:
- **Status** — HyprMac master enable toggle (+ "ACTIVE" cyan badge); Accessibility
  permission status with a "Grant" button when missing.
- **Mouse** — focus-follows-mouse toggle; refresh-rate slider (60–240 Hz, 30 step)
  shown as a chip, disabled when FFM is off.
- **Never tile** — list of excluded apps (icon + name + bundle id + remove button);
  "Add app" opens an `NSOpenPanel` to `/Applications`.
- **Menu bar** — workspace-indicator on/off toggle.
- **iCloud sync** — sync toggle (or an "unavailable" row if iCloud Drive is off).
- **Startup** — a "Launch at login" row that just shows a `MANUAL` chip and tells you
  to add it in System Settings (not automated).
- **About** — version chip; "Getting started" → replays onboarding; "Reset all
  settings" (red).

### B2. Keybinds  `KeybindsSettingsView.swift`
- **Hypr Key** panel — a `Picker` to choose the physical Hypr key (Caps Lock, Tab,
  backtick, backslash, F13–F20, L/R Shift/Ctrl/Opt/Cmd), with an explanatory footer.
- Then one `HyprPanel` per category (Focus & Navigation, Window Management, Workspaces,
  System). Each row: action icon + description + a **KeybadgeView** (chord rendered as
  chip-styled key badges). Tap to select, double-tap or context-menu to edit/delete.
- **Actions row** — Add keybind / Edit / Delete (when a row is selected) / Reset to
  defaults.
- **Editor sheet** (`KeybindEditorSheet`, 480pt) — a `KeyRecorderView` to capture a
  chord + an action `Picker` with contextual param controls (direction picker, workspace
  picker, next/previous segmented control, bundle-id picker).

### B3. App Launcher  `AppLauncherSettingsView.swift`
Deliberately separated from Keybinds so the launcher list stays focused. Empty state
(icon + "No app launchers" copy) or a "Launchers" panel of rows (app icon + name +
bundle id + chord badge + trash). "Add app launcher" opens an editor sheet that picks
an `.app` then records a chord.

### B4. Tiling  `TilingSettingsView.swift`
- **Window Gaps** — inner gap slider (0–32px) + outer padding slider (0–32px), each with
  a px chip.
- **Focus Indicator** — focus color picker; "Show focus border" toggle; conditional
  "Floating border color"; "Dim inactive windows" toggle + conditional intensity slider
  (5–60%); shared "Animation duration" slider (0–1000ms) that fades border + dim in
  lockstep.
- **Per-Monitor Settings** — one row per screen: name + resolution, a tiling on/off
  toggle, a **max-splits pill picker (1–7)**, and a **live dwindle preview** (a scaled
  render of how the layout would tile that monitor's aspect ratio at that split count,
  using cyan-tinted rects). This live preview is the nicest bespoke thing in the app —
  keep the spirit of it.

---

## C. Onboarding (first launch)  **[STOCK]**
`HyprMac/Welcome/OnboardingView.swift` · window **520×440** floating, HUD vibrancy

5-page tutorial, manual page-swap with opacity transitions. Header = app icon (56pt) +
"Getting Started" + subtitle. Pages:
1. **Concept** — "Caps Lock Is Your Superpower" — introduces the Hypr key.
2. **Focus** — "Move Between Windows" — Hypr + arrows.
3. **Workspaces** — Hypr + number.
4. **Quick Tips** — 5 tip rows (float, cycle, menu-bar warp, drag-swap, split toggle).
5. **Finish** — "You're All Set", points at Hypr+K.

Footer = `PaginationView` (Skip on left, dots, Next/"Let's Go!" on right). All styling
is stock: `.accentColor` SF Symbols, `.system` fonts, `.secondary` text.

## D. Welcome slideshow (post-install)  **[STOCK]**
`HyprMac/Welcome/WelcomeSlideView.swift` · same 520×440 window

4-page feature tour: Automatic Tiling, Virtual Workspaces, Essential Shortcuts (a mono
grid of the 8 headline chords from `WelcomeContent.essentialKeybinds`), Mouse Features.
Uses the shared `FeaturePage` component (centered icon + title + description + detail).
Same stock styling.

## E. What's New (post-update)  **[STOCK]**
`HyprMac/Welcome/WhatsNewView.swift` · same window

Single scrolling page rendering `WhatsNewFeatures.current` (a curated array, updated per
release — see `WelcomeContent.swift`). Each feature = SF Symbol + title + description.
"Continue" button. Stock styling.

> C, D, E all live in the same 520×440 floating window (`WelcomeView` router,
> `WelcomeWindowController`) and share `PaginationView` / `FeaturePage`. They are three
> near-parallel flows — a redesign should consider collapsing/unifying them.

---

## F. Keybind overlay (Hypr+K)  **[STOCK]**
`HyprMac/Core/KeybindOverlayController.swift` · **480pt** wide × ≤560, `.hudWindow` `.floating`

The most-used in-app reference. An `NSPanel` HUD toggled by Hypr+K. Scrolling list
grouped by `KeybindCategory`; each group = an uppercase secondary header + a rounded
`.controlBackgroundColor` container of rows (action icon + description + `KeybadgeView`
chord). Styling is stock system fonts + `.secondary` — it does **not** use the design
system, despite `KeybadgeView` being shared with the (new-styled) settings tabs.

---

## G. In-use chrome (Surface B — drawn over other apps)
Covered in depth in [`03-interaction-model.md`](03-interaction-model.md). Summary of the
drawn elements and their current tuning:

- **Focus border** (`FocusBorder.swift`) — active width 2pt, settled 1.5pt, floating
  1.5pt, error 2.5pt; fill alpha 0.08 active / 0.12 error; settles after 0.5s; show/hide
  fades ~0.22/0.28s; error state does a 7-step shake. Color = user's focus color
  (defaults to system accent).
- **Focus brackets** (`FocusBrackets.swift`) — corner brackets, 14pt legs, 4.5pt stroke
  (7pt outline), inset 14pt inside the window, scale-in 0.10s / fade-out 0.12s. Shown
  while Hypr held.
- **Dimming overlay** (`DimmingOverlay.swift`) — per-tile black layers, default
  intensity 0.2, opacity-animated, fades with the shared chrome duration.
- **Scratchpad scrim** (`ScratchpadController.swift`) — dim scrim at intensity 0.45
  behind the summoned floating layer.

---

## Component & token inventory (shared building blocks)
`HyprMac/Settings/SettingsComponents.swift` + `HyprMac/Shared/DesignSystem.swift`

- `HyprPanel(title, footer)` — rounded section container (radius 10, `hyprSurface`
  fill, 0.5pt separator border) with optional uppercase title + caption footer.
- `HyprRow(title, icon, subtitle, divider)` — label + trailing control row with hairline
  divider.
- `HyprChip(text, prominent)` — small mono pill for identifier-ish text.
- `HyprAccentBadge(text, icon)` — the cyan signature pill (Hypr key, active markers).
- `HyprToggleStyle` — custom flat pill switch (monochrome off / cyan on), replaces the
  glossy system switch.
- `KeybadgeView` / `KeyChip` — chord rendered as key-cap chips (note: `KeyChip` uses
  `Color.gray.opacity(0.18)`, a stock-ish fill, not a design-system token — minor
  inconsistency).
- `DwindlePreview` (in TilingSettingsView) — the live layout preview.

Full token values are in [`02-design-system.md`](02-design-system.md).
