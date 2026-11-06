# Settings polish

Reference for how the Settings and appearance controls behave. It holds the hover tiers, the focus defaults and the window-radius research behind the 16 pt and 10 pt fallbacks.

## Hover response

The former refresh-rate slider controls **hover-to-focus checks during mouse movement**. `WindowManager` supplies `MouseTrackingManager.hoverThrottleInterval`; the mouse handler drops events that arrive too soon. It does not run a timer at the selected frequency and does no hover work while focus-follows-mouse is disabled.

The slider is a three-tier picker: Low 60 Hz, Medium 120 Hz, High 240 Hz. The wording says it controls pointer-driven focus checks, not an overall refresh rate.

Medium retains the existing 120 Hz default. The minimum spacing between eligible checks is approximately 16.7 ms at Low, 8.3 ms at Medium, and 4.2 ms at High. These are throttle intervals, not guaranteed focus latencies: dropped events are not replayed if the pointer stops, and main-thread work can delay handling. The window-list cache also reuses one list for up to 80 ms, so attempts do not equal expensive window-list queries.

Window discovery is separate: accessibility notifications request coalesced discovery, with a fixed 10-second reconciliation timer for missed events. Neither this timer nor display refresh, key handling, animation durations, or window sizing uses the hover setting.

Higher rates permit more hit-test attempts while the pointer moves. This establishes a work-versus-responsiveness tradeoff, but no energy or battery-life measurement was collected. The same tier remains active on battery and external power. A later optional battery override would need an injected power-state provider, explicit preference migration, and measurements. macOS provides IOKit power-source snapshots and limited-power notifications; there is no reason to add another recurring power poll.

### Rate compatibility

`mouseHoverPollHz` remains the stored integer. Existing 90, 150, 180, 210 Hz and manually configured values are not rounded to tiers. Selecting a tier explicitly replaces the value. Values below the pre-existing 30 Hz runtime floor remain stored and are labelled with their effective rate. File reloads apply the saved hover value as startup does.

## Focus appearance

The default uses dimming and corner cues while the Hypr key is held. Persistent colored focus fills and full-window borders are off. The existing border renderer remains available as an opt-in because it also owns bounded red rejection feedback and existing users may deliberately use its colors.

| Setting | Old default | Default |
| --- | --- | --- |
| Dim inactive windows | Off | On |
| Dim amount | 20% | 13.5% |
| Dim slider | 5–60% | 0–27% |
| Persistent borders | On | Off |
| Corner cue color | Shared focus color, cyan by default | Black |
| Dimming/border fade | 220 ms | 130 ms |

The 0–27% dim range puts the 13.5% default at the midpoint. Existing stronger saved amounts remain intact; opening settings does not clamp or rewrite them. The displayed percentage reports the saved amount, and using the slider chooses a value in the new range.

Window shape and key-press marks have separate controls. **Window corner radius** keeps the existing `windowCornerRadius` override and shapes only dimming cut-outs and optional window borders. **Mark roundness** shapes only the four Hypr-key marks; zero gives square marks and higher values round their corner arcs. The marks default to 20-point roundness, 15-point straight segments, and 4.5-point thickness, matching the saved MacBook settings. Changing either radius updates only appearance. Color is independent of the persistent border and defaults to black with a white contrast stroke (4.5-point foreground, 6.5-point contrast). The fixed corner entrance/release timings remain unchanged; the fade slider controls borders, dimming, and the scratchpad scrim.

Explicit saved dimming, border, color, radius, and fade preferences remain authoritative. Missing fields, fresh configurations, and Reset to Defaults use the new baseline. Error feedback still shows a red overlay shake and message after rejection even when persistent borders or corner cues are off. It does not shake application windows.

### Corner compatibility

The optional `focusBracketStyle`, `focusBracketColorHex`, and `focusBracketRadius` fields extend the existing configuration without renaming its keys. For an older file with no style field, an explicit focus-border color becomes the initial bracket color. Once the new style field is saved, an absent bracket color means the black default and never reimports the old border color. Thus the laptop's saved black cue is preserved until changed deliberately. Old builds can ignore the new fields, but may discard them if they rewrite the shared file; cross-version iCloud writes cannot preserve preferences unknown to the old writer.

### Window-radius research

Apple describes macOS 27 Golden Gate as giving windows a consistent, tighter radius. It described Tahoe's radii as varying with window style: larger toolbars get larger corners, while titlebar-only windows use smaller corners. These are standard-window design statements, not a guarantee for custom-shaped application windows. Sources: [WWDC26 Platforms State of the Union](https://developer.apple.com/videos/play/wwdc2026/102/) and [WWDC25 AppKit design](https://developer.apple.com/videos/play/wwdc2025/310/).

Apple's [WWDC25 window-corner slide at 7:30](https://developer.apple.com/videos/play/wwdc2025/310/?time=450) supplies numeric Tahoe values:

| Window style on macOS 26 | Radius |
| --- | --- |
| Titlebar | 16 pt |
| Compact toolbar | 20 pt |
| Toolbar | 26 pt |

No numeric Golden Gate radius was verified. Apple's linked macOS 27 Figma kit returned HTTP 403, and the Sketch page exposed no downloadable layer geometry. This pass retains the existing 16-point fallback for macOS 26 and later and the existing 10-point compatibility fallback for earlier versions. The former is a documented Tahoe titlebar value, **not** a documented Golden Gate universal value; the latter was not independently measured in this pass. The reset button is therefore labelled **Suggested**, not **OS default**. A controlled measurement on Golden Gate is still needed before choosing a different automatic value.

The MacBook's read-only OS inventory reports macOS 27.0, build 26A428. Its explicit 15-point HyprMac override remains untouched. A global manual correction remains useful, although one radius cannot perfectly match differently shaped windows simultaneously. There is no per-app override interface in this pass.

## Overlay glass

The transient overlays have one look: neutral glass, with no setting. These are the Hypr+K keybind list, the workspace switch, fullscreen and status HUDs, and the workspace overview. Settings, focus chrome, the menu bar and onboarding are not affected. Overlay appearance (System, Light, Dark) still applies.

- **macOS 26 and later.** `glassEffect(.regular.tint(...).interactive())` goes on the card content itself. A live probe on macOS 27 showed that this gives true Liquid Glass in a borderless panel; a `.regular` glass layer drawn behind the content did not. Nothing above the glassed card may flatten it: no compositing group, shadow or mask.
- **Before macOS 26.** The fallback is a behind-window `NSVisualEffectView` (`.popover`, always active), the lightest material that follows light and dark. It has the same tint drawn under the content, a hairline edge and an outside-only shadow.
- **Tint.** Window background color, so light in light mode and dark in dark mode. It is 0.18 on the HUDs and 0.28 on Hypr+K and the overview (`OverlayGlassTint` in `DesignSystem.swift`).
- **Labels.** Text uses system label styles, so it picks up the glass vibrancy. That includes the WORKSPACE caption, the section headers and ACTIVE. The overlay accent appears only on the search caret, the matched text and the Tutorial label. Failed status captions stay red. Key chips in the overlays use a translucent fill; Settings keeps its opaque chips.
- **System settings.** HyprMac does not read or override the system Liquid Glass or Reduce Transparency settings. The SDK does not document whether `glassEffect` follows them.
- **Pinned headers.** A second material behind the pinned section headers would show as bands, so the headers get no fill. Each row is masked by one gradient laid over the list viewport. It is clear under the header text and solid 10 pt below the header, where a resting row's text starts. Arrow-key stops never dim a row. While more rows are below, the same gradient fades rows and headers over the last 32 pt, so the scroll cue survives.

A branch build briefly wrote an `overlayStyle` key. It never shipped, so there is no migration; the key is ignored and the next save drops it.

Offscreen snapshots (`HYPRMAC_RENDER_UI`) show the content over a stand-in wallpaper but cannot render the blur or Liquid Glass. Judge those live.

## Live-update boundary

Live updates now compare complete configuration snapshots with the initial state already recorded. Only changed layout fields invoke layout effects. Appearance changes use a dedicated visual path, without rebuilding window caches, setting application frames, assigning workspaces, or changing focus. The subscription is installed once, and file reloads are observed after their complete state has been applied.

Gap/padding, split limits, monitor enablement, and scratchpad region size still have their intended layout effects. Dimming, color, fade, corner radius, and border/corner appearance do not.

## Pause shortcut

**Caps + P** is the default pause/resume shortcut. The keyboard event tap stays alive while tiling is paused, including when the app starts paused. Layout and mouse tracking stop; pause/resume and keyboard help remain available. Repeated key-down events do not toggle tiling repeatedly. Existing custom bindings remain authoritative: if Caps + P is already occupied, the new action is not injected over it and can be assigned in Settings. The default-merge rules also apply to configuration reloads.

## Control groups

Mark roundness, length, thickness, and corner color form one group without internal dividers. With window borders enabled, tiled color, floating color, and fade duration form one group. Fade remains available for dimming even when window borders are disabled. Fresh installs select Corners with persistent window borders off. Explicit saved choices remain intact.

## Launch at login setup

The tutorial ends with an optional launch-at-login prompt. Skip goes directly to this prompt; Not now closes setup without changing login items. Yes registers the current app through Apple's `SMAppService.mainApp`. An enabled service is confirmed from macOS status. If approval is required or registration fails, HyprMac opens Login Items and displays the remaining steps. General settings provides the same enable/status controls and a way to manage Login Items later. Returning from System Settings refreshes the status. The choice is local to this Mac and is not synced through UserConfig.

Registration is tested with injected service actions so the suite does not modify real login items. Actual first-login launching and approval UI need a manual macOS check. References: [Apple SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice) and [Login Items instructions](https://support.apple.com/en-ca/guide/mac-help/-mh15189/mac).
