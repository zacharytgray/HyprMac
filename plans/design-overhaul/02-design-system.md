# 02 — Current Design System (tokens + rules)

Verbatim from `HyprMac/Shared/DesignSystem.swift` (the settings-window design system).
This is the "after" for the Settings window and the "target to unify toward" for
everything else — or the starting point a redesign evolves from.

## Design intent (from the source comments)

> Chassis colors defer to `NSColor` system semantics so light/dark behavior matches the
> rest of macOS. The HyprMac signature accents (cyan + magenta) appear in exactly four
> places: focus border, active sidebar item, key recorder pulse, "Hypr Key" badge.

The character is **mono/technical, flat, restrained**. Monospace for anything
identifier-like (wordmark, chords, bundle ids, versions). Near-monochrome chassis with
one hero accent. It reads like a terminal-adjacent power tool, which fits a Hyprland
homage.

## Color

### Chassis — semantic, follows macOS light/dark automatically
| Token | Backing `NSColor` |
|---|---|
| `hyprBackground` | `.windowBackgroundColor` |
| `hyprSurface` | `.controlBackgroundColor` |
| `hyprSurfaceElevated` | `.underPageBackgroundColor` |
| `hyprSeparator` | `.separatorColor` |
| `hyprTextPrimary` | `.labelColor` |
| `hyprTextSecondary` | `.secondaryLabelColor` |
| `hyprTextTertiary` | `.tertiaryLabelColor` |

### Signature accents — dynamic per appearance
| Token | Dark mode | Light mode |
|---|---|---|
| `hyprCyan` | `#56D8F0` (neon on near-black) | `#007AAA` (deeper, holds contrast on white) |
| `hyprMagenta` | `#E84BCB` | `#B7228F` |

Cyan is the workhorse accent (active states, toggles-on, badges). Magenta is the
secondary signature — paired with cyan it's the "HyprMac gradient" identity, but it is
barely used in the current UI (mostly reserved for the focus-border/brand moment). **A
redesign has room to make magenta earn its place or drop it.**

## Typography — SF, with mono for identifiers
| Token | Spec |
|---|---|
| `hyprTitle` | 17pt semibold |
| `hyprSection` | 12pt semibold (uppercased + kerned in use) |
| `hyprBody` | 13pt regular |
| `hyprCaption` | 11pt regular |
| `hyprMono` | 12pt medium **monospaced** |
| `hyprMonoSm` | 11pt medium monospaced |
| `hyprMonoXs` | 10pt medium monospaced |

Wordmark `HYPRMAC` is `hyprMono` with 2pt kerning. Chords/bundle-ids/versions all go
mono. This mono-for-data / sans-for-prose split is a defining trait.

## Spacing (`HyprSpacing`)
`xs 4 · sm 8 · md 12 · lg 16 · xl 24 · xxl 32`

## Radius (`HyprRadius`)
`sm 4 · md 6 · lg 10` — panels use `lg`, chips use `sm`, rows/buttons `md`. All
`.continuous` (squircle) corners.

## Motion (`HyprMotion`)
| Token | Curve |
|---|---|
| `snap` | `easeOut 0.12s` (hovers, toggles) |
| `glide` | `easeOut 0.20s` |
| `physical` | `spring(response 0.35, damping 0.82)` |

In-use chrome (focus border/brackets/dim) has its own separate tuning constants (see
[`03-interaction-model.md`](03-interaction-model.md)); the user can override the
border/dim fade with a single "Animation duration" slider (0–1000ms).

## Signature-usage rule (current discipline)
Cyan is intentionally rationed. The custom `HyprToggleStyle` and `HyprAccentBadge`
exist specifically to avoid the glossy system-accent switch and to keep accent usage
deliberate. If you introduce more color, do it on purpose — the restraint is part of
why the settings window looks intentional.

---

## Applied vs. not-applied  {#applied-vs-not-applied}

The single most important thing to fix. The design system is applied to **some**
surfaces and not others:

| Surface | On design system? |
|---|---|
| Settings window (all 4 tabs) | ✅ Yes — fully |
| Menu bar dropdown | ✅ Yes — restyled to match |
| Onboarding (first run) | ❌ No — stock `.accentColor` + system fonts |
| Welcome slideshow | ❌ No — stock |
| What's New panel | ❌ No — stock |
| **Keybind overlay (Hypr+K)** | ❌ No — stock, even though it shares `KeybadgeView` with the new settings |
| In-use chrome (border/brackets/dim) | ⚠️ Partial — its own tuning; color defaults to system accent, not `hyprCyan`, unless the user sets a focus color |

The onboarding and the keybind overlay are, respectively, the **first** and the **most
frequently reopened** surfaces in the whole app — and both are on the old look. Any
redesign's first win is bringing these into one system.

### Minor token leaks to clean up while you're in here
- `KeyChip` (in `KeyBadgeViews.swift`) fills with `Color.gray.opacity(0.18)` instead of
  a `hyprSurface*` token.
- The keybind overlay uses `Color(nsColor: .controlBackgroundColor).opacity(0.5)` and
  raw `.system(size:)` fonts rather than `HyprPanel`/`hyprBody`.
- Onboarding/welcome use `.accentColor` (the macOS system accent, user-configurable in
  System Settings) rather than `hyprCyan`, so their accent color is whatever the user's
  OS accent happens to be — inconsistent with the cyan brand.

## App icon
`assets/app-icon-256.png` / `app-icon-1024.png`. A blue rounded-rect (macOS
big-sur-style squircle) with a stylized window: three traffic-light dots top-left and a
tiled pane arrangement (one tall left pane, two stacked right panes) rendered in
translucent light-blue on a blue radial gradient. It signals "tiling window manager" but
does **not** use the cyan/magenta brand accents — it's a separate blue. Worth
reconciling with whatever accent direction the overhaul picks.
