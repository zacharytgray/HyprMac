# HyprMac UI Overhaul — Spec for SwiftUI/AppKit handoff

Direction: evolve the existing mono/tech system; unify it across every surface.
Companion mockups: `HyprMac Overhaul.dc.html` (option ids 1a–1m referenced below).

---

## 1. Accent semantics (the core rule) — board 1a

Two accents, two meanings, applied everywhere including in-use chrome:

| Accent | Token | Meaning | Appears on |
|---|---|---|---|
| Cyan | `hyprCyan` | **Focus / active / on** | focus border, focus brackets, active workspace badge, active sidebar item, toggles-on, primary buttons, ACTIVE badge, key-recorder pulse, bound keys in overlay B |
| Magenta | `hyprMagenta` | **The floating layer** | floating-window border (new default), scratchpad scrim tint + tray glyph + count, every ◇ floating marker (menu bar glyph, workspace badges, keybind rows) |
| Everything else | mono chassis | — | — |

Changes from today:
- **Focus color default = `hyprCyan`** (was: system accent). Fully user-overridable — including **no color at all**: "Show focus border" off + dimming remains a first-class, supported look (see §7).
- **Floating border color default = `hyprMagenta`** (was: separate configurable with no brand default). Also overridable/disable-able.
- Scratchpad scrim gets a 4% magenta tint over the 45% black scrim so "summoned floating layer" reads as magenta territory.
- `KeyChip` fill: replace `Color.gray.opacity(0.18)` with `hyprSurfaceElevated`.

## 2. Tokens (unchanged unless noted)

- **Chassis**: keep the semantic NSColor mapping verbatim (`hyprBackground` = windowBackground, etc.) — light/dark for free.
- **Accents**: cyan `#56D8F0` dark / `#007AAA` light; magenta `#E84BCB` dark / `#B7228F` light.
- **Type**: unchanged (17/12/13/11 + mono 12/11/10). Rule: mono for identifiers, chords, versions, paths; sans for prose. Wordmark = mono, 2pt kerning.
- **Spacing** 4/8/12/16/24/32 · **Radius** 4/6/10 continuous · **Motion** snap 0.12 / glide 0.20 / physical spring.
- New shared component: **key-cap chip** — mono 10pt, `hyprSurfaceElevated` fill, 1pt border, bottom border 1pt brighter (subtle key-cap depth). Used identically in Settings rows, overlay, tour, menu bar.

## 3. Settings — 4 tabs → 3 (mockups 1e, 1f, 1j)

**General · Keys · Layout.** Sidebar unchanged in anatomy (wordmark + version, 2pt cyan active bar, config-path footer).

### Keys (1e) — the centerpiece
- **Hypr hero panel** at top: big key-cap glyph, one-line explanation, physical-key picker. Subtle cyan→magenta gradient wash (the one sanctioned brand-gradient moment in Settings).
- **Search field** filters all rows (actions + launchers).
- Categories: Focus & Navigation · Window Management · Workspaces · **Apps** · System.
- **App Launcher tab is deleted**; launchers are rows in the Apps category (app icon + "Launch / focus X" + chord). Same editor sheet, same recorder.
- One "＋ Add" button (menu: Keybind… / App launcher…). Selection/edit/delete interactions unchanged.
- Rows that produce floating behavior carry a small magenta ◇ suffix.

### Layout (1f)
- **Gaps panel with the live dwindle preview promoted to hero** (preview reacts to both sliders live).
- **Focus Chrome panel**: focus color (default chip says "hyprCyan · default"), floating color (default magenta), show-border toggle, dim toggle + intensity, one "Chrome fade" slider labeled as shared by border + dim + scrim.
- **Per-monitor panel**: name + resolution, tiling toggle, max-splits pills, per-monitor dwindle thumbnail (kept from today).

### General (1j) — 7 panels → 5
Status (enable + ACTIVE badge + accessibility) · Mouse · Never Tile · System (menu-bar indicator, iCloud, launch-at-login MANUAL chip) · footer panel (Replay the tour · Reset all settings).

## 4. Flows — 3 windows → 1 Tour shell (1k, 1l)

One `TourView` shell in the 520×440 floating window: header (mini app icon + wordmark + page counter or version chip) · content page · footer (Skip / dots / Next).
- **First run**: 4 pages — Hypr key hero (with a **live try-it** hint: "hold ⇪ press →" — the app can actually detect it and check the row), Focus, Workspaces, Finish→Hypr+K. Cut the old page 4 tip-dump; tips move to the What's New/overlay.
- **Post-update**: the same shell renders changelog rows (icon + title + one-liner), version chip in header, single Continue.
- **Replay** (from General): first-run page set.
Delete `WelcomeSlideView` as a separate flow; `PaginationView`/`FeaturePage` are absorbed into the Tour components, restyled on-system.

## 5. Hypr+K overlay — pick one of three (1g / 1h / 1i)

**Decision: A (1g) — refined two-column list.** On-system HUD (dark surface at 96% opacity, radius 14, hairline border), key-cap chips shared with Settings, type-to-filter, esc closes, category headers in cyan, floating-related rows carry the magenta ◇.

## 6. Menu bar (1c, 1d)

- Dropdown: add **"Keybind cheat sheet ⇪K"** as the first action; add a **glyph legend** line (● active ○ occupied ◇ floating) at the bottom of the Workspaces panel — the ◇ rendered magenta; scratchpad count chip (magenta) in the same row.
- **Remove the ⌘, shortcut label from the Settings row** (it was never wired up — known bug). The row stays; either drop the shortcut entirely or actually register ⌘, on the dropdown window if you want it back later.
- Update-check row shows current version inline.
- Final mockups: 2f (dark) / 2g (light).
- Menu-bar glyph string unchanged, but ◇/tray glyph adopt magenta when rendered in the dropdown (menu bar itself stays template-tinted per macOS rules).

## 7. In-use chrome (1m)

**Out of scope by owner decision** — the tiling look & feel is not being overhauled; colors remain user-customizable and the colorless dim-only look stays as-is. The only carry-overs if desired later: focus-color default → hyprCyan, and the shared fade constant. Ideas board 2h is parked, not planned.

## 8. App icon (turn 2: 2a–2e)

**Final: 6d "recessed well" keycap.** Dark squircle chassis → sunken tray (inner top shadow, faint bottom rim) → raised keycap (vertical gradient face, lit top edge, 5u bottom bevel, cast shadow) → cyan caps-lock glyph drawn as vector strokes (not a font glyph). No two-accent gradients; all shading is neutral.
Assets: `assets-new/hyprmac-icon-1024-final.png` / `-256-final.png` (production), `-64-final.png` (dock-size check). Geometry, in 116-unit design space: squircle r26 · well 102 r23 · cap 88 r18, bevel 5 · glyph stroke 33/1024 scale.

## 9. Build order suggestion

1. Token/default changes (KeyChip fill → hyprSurfaceElevated) + menu bar fixes (remove dead ⌘, label, add cheat-sheet row + legend) — small diffs, immediate coherence.
2. Overlay restyle to 1g (shared components exist) — biggest visible win per hour.
3. Tour shell consolidation.
4. Settings IA merge (Keys tab).
5. Icon.
