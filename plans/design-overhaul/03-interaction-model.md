# 03 — Interaction Model & In-Use Visual Language

The keymap and the ephemeral on-screen chrome. For a keyboard-first WM, **this is the
product** — more than any settings pane. A redesign should treat the keymap's
learnability and the in-use chrome's coherence as first-class.

## The Hypr key

Caps Lock, remapped to F18 at the IOKit/driver level via `hidutil` (restored on quit),
acts as a dedicated **Hypr** modifier. Hold it + press a key = a window operation. The
physical key is configurable (Tab, backtick, backslash, F13–F20, L/R of each real
modifier), but Caps Lock is the default and the whole brand ("Hypr key", "Caps Lock is
your superpower"). One hero modifier is the core mental model — keep it legible.

Badge label in UI: the Hypr key renders as `⇪` (or the chosen key's glyph) in chord
chips.

## Default keymap

| Chord | Action | Category |
|---|---|---|
| `Hypr + ←/→/↑/↓` | Focus window in direction | Focus & Navigation |
| `Hypr + Shift + ←/→/↑/↓` | Swap window in direction | Window Management |
| `Hypr + J` | Toggle split direction (transpose) | Window Management |
| `Hypr + Shift + T` | Toggle floating/tiling (eject scratchpad window) | Window Management |
| `Hypr + F` | Focus / cycle floating windows | Focus & Navigation |
| `Hypr + S` | Toggle scratchpad layer | Window Management |
| `Hypr + Shift + S` | Send focused window to scratchpad | Window Management |
| `Hypr + 1–9` | Switch to workspace N | Workspaces |
| `Hypr + Shift + 1–9` | Move focused window to workspace N | Workspaces |
| `Hypr + Ctrl + ←/→` | Move focused window to adjacent monitor | Workspaces |
| `Hypr + Tab` / `Hypr + Shift + Tab` | Cycle occupied workspaces on current monitor | Workspaces |
| `Hypr + W` | Close window | Window Management |
| `Hypr + K` | Show/hide keybind overlay | System |
| `Hypr + Enter` | Launch/focus Terminal | Apps |
| `` Hypr + ` `` | Warp cursor to menu bar | Focus & Navigation |

Categories (source of truth `KeybindCategory.swift`): **Focus & Navigation · Window
Management · Workspaces · Apps · System**. Both the Settings > Keybinds tab and the
Hypr+K overlay group by these.

### Mouse interactions
- **Focus-follows-mouse** — hover a tiled window to focus it (no raise; toggleable;
  auto-suppressed while a menu is open or right after keyboard actions).
- **Drag-to-swap** — drag a window onto another's slot to swap them (works across
  monitors).

## Core workflows the UI must support learning/managing

1. **Learn the Hypr key** (onboarding) — the single most important thing a new user
   must internalize.
2. **Recall a keybind mid-flow** (Hypr+K overlay) — fast glance, dismiss, keep working.
3. **Rebind / add keybinds and app launchers** (Settings) — including capturing a chord
   via the key recorder.
4. **Tune the layout** — gaps, padding, per-monitor max-splits, focus indicator, dim.
5. **Read workspace state at a glance** — the menu-bar dot-grid glyph + dropdown badges.

## In-use visual language (Surface B — drawn on top of other apps)

HyprMac has almost no window of its own during normal use. What the user sees is
ephemeral chrome painted over their real apps. This is the app's *feel*. Current
elements and their tuning (all overridable pieces noted):

### Focus border  `HyprMac/Core/FocusBorder.swift`
A colored outline hugging the focused window (follows the window's actual corner
radius). Behavior:
- **Active** 2pt stroke, 0.08 fill alpha — during/just-after a focus action.
- **Settles** after 0.5s to a **1.5pt** thin border (0.3s settle animation).
- **Floating** windows get a 1.5pt border in the (separate, configurable) floating
  color.
- **Error** state: 2.5pt, 0.12 fill, plus a 7-step horizontal **shake**
  (`[10,-10,7,-7,3,-3,0]`, 0.04s/step) — e.g. focus move with no target that direction.
- Show/hide fades ~0.22s / 0.28s.
- Color = user's **focus color** (defaults to macOS system accent, *not* `hyprCyan`) —
  configurable in Settings > Tiling. Fade duration is user-controlled (0–1000ms).

### Focus brackets  `HyprMac/Core/FocusBrackets.swift`
Corner brackets that appear **inside** the focused window while the Hypr key is held (a
"you're in command mode" affordance). 14pt legs, 4.5pt stroke with a 7pt outline for
contrast, inset 14pt from the edges, arcs tangent to the inset corners. Scale-in 0.10s /
fade-out 0.12s, with a small 6pt initial offset. Uses the focus color.

### Dimming overlay  `HyprMac/Core/DimmingOverlay.swift`
Per-tile black layers that darken every window except the focused one. Default intensity
0.2 (5–60% configurable), the focused tile's layer stays at opacity 0. Fades in lockstep
with the focus border via the shared chrome-fade duration. Toggleable.

### Menu-bar workspace glyph
The dot-grid string (`● ◆ ○ ◇ ·`) described in [`01-ui-inventory.md`](01-ui-inventory.md#a-menu-bar-dropdown--new).
It's the ambient, always-on status readout. Terse and information-dense by design.

### Scratchpad  `HyprMac/Core/ScratchpadController.swift`
A quasimodal layer: Hypr+S summons a set of floating windows over a **0.45-intensity dim
scrim**; click-outside / Cmd-Tab / workspace-switch dismisses it (re-parks the windows
off-screen). Hypr+Shift+S stashes the focused window into it; Hypr+Shift+T ejects one
back into tiling. Menu bar shows a tray glyph + count while windows are stashed. Think
"drop-down terminal / music / chat you want on hand but out of the way."

### Tiling geometry itself
Gaps (inner) + outer padding are user-tunable and are, literally, the visual rhythm of
the whole desktop. BSP dwindle: split direction from aspect ratio (wider→horizontal,
taller→vertical), max depth 3 (smallest slot = 1/8 screen), smart insertion that
backtracks on constrained monitors to avoid sub-500px slots (produces 2×2 grids on
vertical monitors). Windows beyond max depth auto-float. No animation — retiles are
instant.

## Design implications for Surface B

- The **focus color defaults to the OS system accent, not the HyprMac cyan** — so the
  brand accent and the in-use accent can silently diverge. A redesign should decide
  whether the in-use chrome should default to the brand accent (cyan) so the whole
  product reads as one system, while still letting power users override.
- Focus border, brackets, dimming, and the scratchpad scrim are **four different
  ephemeral chromes** with independently-authored tuning. Unifying their motion feel and
  accent handling would make the "in command" moment feel designed rather than
  assembled.
- The menu-bar glyph language (`● ◆ ○ ◇ ·`) is dense and clever but unexplained anywhere
  the user naturally looks — worth a legend somewhere in the redesigned dropdown or
  onboarding.
