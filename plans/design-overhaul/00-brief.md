# 00 — Design Brief

## What HyprMac is

HyprMac is a **keyboard-driven tiling window manager for macOS**, inspired by
Hyprland. It runs as a menu-bar-only accessory app (no Dock icon, no main window). It
automatically tiles your windows into a BSP "dwindle" layout, gives you 9 virtual
workspaces per monitor, and puts every window operation — focus, swap, float, move,
resize — one chord away on the keyboard.

The signature interaction is the **Hypr key**: Caps Lock, remapped at the driver level
to act as a dedicated modifier. Hold Caps Lock + press something = do a window thing.
"One key unlocks everything."

It's in the same category as yabai, AeroSpace, and Amethyst, but leans into a
Hyprland-style, keyboard-first, no-SIP-required workflow. Distributed via DMG,
Homebrew cask, and Sparkle auto-update. Not sandboxed, not on the App Store (uses
private APIs).

- Current version: **0.7.0**
- Platform: **macOS 13 Ventura or later**, built with SwiftUI + AppKit
- Requires Accessibility permission

## Who uses it

Power users and developers who live on the keyboard and want Linux-tiling-WM ergonomics
on a Mac. They:

- Are comfortable with modifier chords and expect to *learn* a keymap, not discover it
  through menus.
- Run multi-monitor setups (the app has deep multi-monitor logic).
- Value speed and determinism over animation and hand-holding — the app is deliberately
  instant/no-animation in its tiling behavior.
- Will edit a JSON config or Settings pane to tune gaps, keybinds, and per-monitor
  behavior.

The app owner is a CS PhD student who studies LLMs and builds this as a serious hobby
project. The bar is high: this should feel like a polished, opinionated indie Mac app,
not a utility.

## The two design surfaces

HyprMac's "design" splits cleanly into two very different worlds. **Both are in scope.**

### Surface A — Configuration & meta UI (traditional GUI)

The windows and panels the user opens deliberately. Fully redesignable — normal SwiftUI
surfaces.

- **Menu bar dropdown** — status, per-monitor workspace badges, actions (280pt wide).
- **Settings window** — 4 tabs (General, Keybinds, App Launcher, Tiling) in a
  sidebar + detail layout (760×600).
- **Onboarding** — 5-page first-run tutorial (520×440 floating window).
- **Welcome slideshow** — 4-page post-install feature tour (same window).
- **What's New** — single-page post-update changelog (same window).
- **Keybind overlay (Hypr+K)** — a HUD cheat-sheet of all active keybinds (480pt HUD).

Full detail: [`01-ui-inventory.md`](01-ui-inventory.md).

### Surface B — In-use visual language (ephemeral chrome over other apps)

The moment-to-moment experience. HyprMac has almost no "screen of its own" while you
work — instead it draws ephemeral chrome *on top of your other apps*:

- **Focus border** — outline around the focused window; tints during keyboard
  traversal, settles to a thin border, flashes/shakes on error.
- **Focus brackets** — corner brackets that appear around the focus target while the
  Hypr key is held.
- **Dimming overlay** — darkens every window except the focused one.
- **Tiling itself** — gaps, padding, split ratios: the literal geometry of the layout
  is a design surface.
- **Menu-bar workspace indicator** — a compact dot-grid glyph encoding workspace state.
- **Scratchpad** — a summonable layer of floating windows over a dimmed scrim.

This is where the *product's feel* lives. A redesign that only touches Surface A would
miss the thing users stare at all day. Full detail:
[`03-interaction-model.md`](03-interaction-model.md).

## Overhaul goals

The owner's words: *"Not only planning on changing the app stylistically, but the
layout of the HyprMac app for an incredible and simple UX."*

Concretely, aim for:

1. **A single, cohesive visual identity across every surface.** Today the Settings
   window looks bespoke and the onboarding / keybind overlay look stock. Pick one
   language and apply it everywhere (or design a new one and apply it everywhere).

2. **Rethought information architecture, not just restyled panels.** Question the
   current 4-tab settings split, the separate "Keybinds" vs "App Launcher" tabs, the
   3 near-duplicate welcome/onboarding/what's-new flows, and whether the menu-bar
   dropdown is carrying the right things. Simplicity is the target — fewer, clearer
   surfaces.

3. **A best-in-class keybind experience.** The keymap *is* the product. The Hypr+K
   overlay and the Keybinds settings tab are the two places users learn and manage it.
   These deserve to be the centerpiece, not an afterthought on stock styling.

4. **A first-run that teaches the Hypr key fast and feels premium.** Onboarding is the
   make-or-break moment for a keyboard-first app — if users don't internalize the Hypr
   key, they churn.

5. **In-use chrome that reads as one coherent system** with the app UI — focus
   border, brackets, dimming, and workspace glyphs sharing the same accent language and
   motion feel.

## Hard constraints (do not design around these)

- **macOS-native, SwiftUI + AppKit.** No web stack. Custom components are fine (the app
  already ships custom toggles, panels, chips) but they render through SwiftUI/AppKit.
- **Menu-bar accessory app.** There is no persistent main window and no Dock presence.
  All Surface-A UI is summoned (menu bar dropdown, settings window, floating panels).
- **Light + dark mode both required.** The current system defers chassis colors to
  macOS semantic `NSColor`s so it tracks the OS appearance automatically. Any new
  palette must work in both.
- **Instant, low-animation tiling.** The tiling engine is deliberately synchronous and
  animation-free (a screenshot-proxy animator was removed on purpose). UI chrome can
  animate (fades, snaps), but don't propose animated window-move choreography — it's an
  explicit non-goal.
- **The Hypr key branding is load-bearing.** "Hypr key" = Caps Lock by default. The
  cyan+magenta accent pair is the current signature. These can evolve but the concept
  of a single hero modifier must stay legible.
- **Accent color is used sparingly by design.** Current rule: signature cyan appears in
  ~4 places only (focus border, active sidebar item, key-recorder pulse, Hypr-key
  badge); everything else is monochrome. A redesign can change the ratio but should be
  intentional about it — restraint is part of the current character.
- **Windows float above tiled windows.** Settings/welcome/overlay panels are pinned to
  `.floating` NSWindow level so they sit above HyprMac-managed windows. Keep that in
  mind for modality/backdrop decisions.

## What "done" looks like for the design session

A design session consuming this package should be able to produce: a unified visual
system (tokens + component specs), a rethought IA for Settings and the
onboarding/welcome/what's-new flows, redesigned mockups/specs for each Surface-A
screen, and a coherent visual language for the Surface-B in-use chrome — all
implementable in SwiftUI/AppKit within the constraints above.
