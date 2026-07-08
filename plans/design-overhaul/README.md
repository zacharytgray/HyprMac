# HyprMac — Design Overhaul Context Package

This folder is a **self-contained handoff** for a design session working on a full
visual + UX/layout overhaul of HyprMac. It was assembled from the live codebase on
2026-07-06 (app v0.7.0). Everything a fresh session needs to redesign the app —
without having to read the whole Swift codebase — is here.

The overhaul is **not just a re-skin**. The mandate is: rethink the *layout and
information architecture* of HyprMac's UI for an incredible, simple UX, and give it a
cohesive visual identity. Read [`00-brief.md`](00-brief.md) first — it frames the goal.

## How to use this package

Read in order. Each file is standalone but they build on each other.

| File | What it is |
|---|---|
| [`00-brief.md`](00-brief.md) | **Start here.** What HyprMac is, who uses it, the two design surfaces, the overhaul goals, hard constraints, and the design ask. |
| [`01-ui-inventory.md`](01-ui-inventory.md) | Every user-visible surface, screen by screen: current layout, dimensions, what it does, and the source file behind it. This is the map of "what exists today." |
| [`02-design-system.md`](02-design-system.md) | The current design tokens verbatim — color, type, spacing, radius, motion — plus the usage rules and where they're applied vs. not applied. |
| [`03-interaction-model.md`](03-interaction-model.md) | The keyboard-first interaction model (keybinds, workflows) and the *in-use* ephemeral visual language (focus border, brackets, dimming, workspace glyphs, scratchpad) that IS the product moment-to-moment. |
| [`assets/`](assets/) | Current app icon (256 + 1024), a real tiled-desktop screenshot, and the demo thumbnail. Visual reference for "how it looks today." |

## The single most important finding

HyprMac has **two visual worlds that don't match**:

1. The **Settings window** was recently overhauled onto a custom, opinionated design
   system (mono/tech aesthetic, cyan+magenta signature accents, custom panels,
   toggles, chips). It looks intentional.
2. **Everything else** the user actually sees — the **onboarding**, the **welcome
   slideshow**, the **What's New** panel, and the **Hypr+K keybind overlay** — still
   uses stock macOS defaults (`.accentColor`, system fonts, `.controlBackgroundColor`).
   It looks generic and disconnected from the settings.

A user's first-run impression (onboarding) and their most-used in-app reference
(keybind overlay) are the two surfaces still on the *old* look. Unifying these — or
deciding a fresh direction for all of them — is the core of the overhaul. See
[`02-design-system.md`](02-design-system.md#applied-vs-not-applied) for the exact split.

## Source-of-truth pointers (live code, if the session has repo access)

- Design tokens: `HyprMac/Shared/DesignSystem.swift`
- Reusable settings components: `HyprMac/Settings/SettingsComponents.swift`
- Settings shell: `HyprMac/Settings/SettingsView.swift`
- Menu bar: `HyprMac/App/MenuBarView.swift`
- Onboarding / welcome / what's-new: `HyprMac/Welcome/`
- Keybind overlay: `HyprMac/Core/KeybindOverlayController.swift`
- In-use chrome: `HyprMac/Core/FocusBorder.swift`, `FocusBrackets.swift`, `DimmingOverlay.swift`
- Product framing: `README.md`, `CLAUDE.md` (architecture + key decisions)
