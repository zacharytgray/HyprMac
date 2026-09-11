# Window sizing and target insertion: next-phase brief

## Status and scope

This is a research and implementation brief for the phase after the UX stability audit is merged. It does not implement target insertion or change the sizing engine.

Zach has exercised the current audit build and reports that those changes are working well. The verified audit baseline is 281 tests with 55 display-dependent skips and no failures. SwiftLint reports 200 violations and 15 errors versus the existing baseline of 201 violations and 16 errors, so the audit adds no lint errors. The canonical laptop build is `HyprMac Debug` 0.12.0 (82.1), bundle identifier `com.zachgray.HyprMac.debug`, source marker `08ec4f1adbef+51764a1a18cb`, with live Accessibility trust verified.

The next phase should remain narrow:

- Preserve SIP. Use public Accessibility APIs and the existing non-injecting architecture.
- Improve sizing verification before changing drag behavior.
- Add same-workspace, same-monitor target insertion only after that foundation is tested.
- Keep Max Splits as a hard per-monitor limit.
- Preserve keyboard swapping. A simple modifier can preserve drag swapping if it remains easy to explain and test.
- Avoid layout presets, cross-monitor insertion, scratchpad insertion, continuous rearrangement during drag, automatic eviction, and new auto-floating behavior in the first version.

## Platform findings

There is no general public macOS API that predicts whether another application's window will accept an exact rectangle. Accessibility exposes whether `AXPosition` or `AXSize` is settable, permits a client to request a value, and permits readback. Settable means that an attempt is supported; it does not expose the application's minimum size, maximum size, aspect-ratio rule, content-driven constraint, or the rectangle it will ultimately accept.

An application's own `NSWindow` has sizing constraints and delegate hooks such as `windowWillResize(_:to:)`, but those belong to the process that owns the window. HyprMac cannot query them as a universal external contract. The strings `AXMinimumSize` and `AXMinSize` probed by `HyprWindow` are absent from the public Accessibility attribute contract inspected during research. They can remain optional hints, but must never be treated as proof.

Accessibility notifications can tell HyprMac that a move or resize happened, but notification registration itself may be unsupported. Notifications are useful evidence after an attempt, not a preflight oracle. WindowServer bounds can also be useful secondary observations, but they do not predict whether an application will accept the next request.

This means the reliable model is transactional: propose a layout, attempt it, observe the result, and either commit the topology or restore the previous state. An unavailable read, AX error, timeout, or unsettled value is **unknown**, never success.

SIP can stay enabled for this design. AeroSpace uses Accessibility-based window control without requiring Dock injection. Yabai's enhanced Dock-injection capabilities and related SIP changes are outside this proposal.

Primary references:

- Apple, `AXUIElementIsAttributeSettable`: <https://developer.apple.com/documentation/applicationservices/1459972-axuielementisattributesettable>
- Apple, `AXUIElementSetAttributeValue`: <https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue>
- Apple, `AXObserverAddNotification`: <https://developer.apple.com/documentation/applicationservices/1462089-axobserveraddnotification>
- Apple, `NSWindow`: <https://developer.apple.com/documentation/appkit/nswindow>
- AeroSpace window frame application: <https://github.com/nikitabobko/AeroSpace/blob/39e519044725694635712c739df9ca40ae78c5d1/Sources/AppBundle/tree/MacApp.swift#L411-L439>
- Yabai window frame application: <https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/window_manager.c#L729-L766>
- Yabai SIP documentation: <https://github.com/asmvik/yabai/wiki/Disabling-System-Integrity-Protection>

## Current HyprMac behavior

HyprMac already has a binary split tree capable of four vertical columns. The observed half-screen-heavy result comes from insertion policy rather than a structural limitation. Smart insertion searches eligible leaves, chooses a split orientation from geometry, honors minimum-slot estimates and Max Splits, and auto-floats a new window when no fitting leaf exists. Adding members clears user-set ratios and resets split ratios, which works against deliberately constructed layouts.

Current drag handling detects a moved tiled window using its post-drag frame, uses the dragged window's center to choose a target slot, then swaps the two window occupants. It does not reparent a leaf or create a split around the target. Hyprland's Dwindle layout is the useful behavioral reference: a moved tiled window can be removed and inserted around a target, while split direction can be selected or preserved. Relevant upstream references are:

- Dwindle configuration: <https://wiki.hypr.land/configuring/layouts/dwindle-layout/>
- Hyprland drag controller: <https://github.com/hyprwm/Hyprland/blob/f05d73f35795ded80d7e1264a37e41b461625f9f/src/layout/supplementary/DragController.cpp#L252>
- Dwindle insertion: <https://github.com/hyprwm/Hyprland/blob/f05d73f35795ded80d7e1264a37e41b461625f9f/src/layout/algorithm/tiled/dwindle/DwindleAlgorithm.cpp#L67>

The closest local paths are:

- `HyprMac/Core/DragManager.swift` for gesture classification and target choice.
- `HyprMac/Core/Input/DragSwapHandler.swift` for applying a drag swap and rollback.
- `HyprMac/Tiling/BSPTree.swift` and `HyprMac/Tiling/LayoutEngine.swift` for topology and geometry.
- `HyprMac/Tiling/TilingEngine.swift` for membership, Max Splits, layout application, overflow handling, and tree lifetime.
- `HyprMac/Tiling/FrameReadbackPoller.swift` for post-write settling and conflict classification.
- `HyprMac/Models/HyprWindow.swift` for AX reads, writes, and the resize-move-resize sequence.
- `HyprMac/Tiling/MinSizeMemory.swift` for learned per-window constraints.
- `docs/investigation/README.md` and its saved patch for earlier failed attempts.

## Sizing risks to resolve first

The current two-pass design is a sound starting point, but it does not yet provide the acceptance boundary needed for structural drag operations:

1. `HyprWindow` property setters discard `AXError`. A failed write and a successful asynchronous write are not distinguished at the call site.
2. Readback treats a failed position read as the requested position. It primarily classifies dimensions, so a correctly sized window that refused its position can be accepted while overlapping another tile.
3. On unsettled or undersized outcomes, some paths cache or reapply the requested frame. Internal geometry can therefore diverge from the actual window.
4. The adjusted second pass is applied without a second readback. The final state is assumed after only the first candidate was observed.
5. The wait budget is accumulated from requested sleep intervals, not measured with a monotonic clock around AX calls. Slow synchronous AX calls can exceed the nominal deadline substantially.
6. The 20-point frame tolerance is larger than the default 8-point gap. Two individually tolerated errors can erase a gap or create overlap.
7. Learned minimum sizes are observations tied to a window's prior state. Content, mode, toolbars, and app updates can change the accepted floor, so the cache must remain a heuristic.

Earlier overlap fixes in `docs/investigation/failed-fix-attempts.patch` caused false rejections, floating cascades, flicker, and latency. The new phase should avoid open-ended retries, global reshuffles, and treating learned sizes as permanent truth.

## Proposed sizing contract

Introduce a narrow, testable frame-application seam. It should accept target frames, an AX adapter, and a monotonic clock, then return an outcome for every affected window:

- `accepted(actualFrame)` only when both position and size are observed within explicit per-axis tolerances and the complete layout has no unintended overlap.
- `rejected(actualFrame, reason)` when a settled, readable result violates geometry or a write explicitly fails.
- `unknown(reason)` when reads fail, the result does not settle by the actual deadline, the window disappears, or a newer transaction supersedes the attempt.

The deadline must be elapsed monotonic time, including time spent inside AX calls. A deadline cannot interrupt a synchronous AX call already in progress, so per-call messaging timeouts also need a deliberate bound; do not promise a hard wall-clock limit based only on the polling loop. Retries must be bounded by both a deadline and a small maximum attempt count. Late callbacks or observations from an older generation must not commit or roll back a newer operation.

Verify the complete affected layout after every final write, including the adjusted pass. Check position, dimensions, usable-screen containment, pairwise overlap, and gaps using tolerances that cannot silently consume the configured gap. Exact tolerance values should come from deterministic tests and live measurements rather than preserving the current 20-point constant by assumption.

Do not auto-float or evict existing windows when target insertion fails. Leave the tree unchanged and restore actual pre-drag frames. Existing normal insertion overflow behavior can remain unchanged unless a separate reproduced bug justifies changing it.

## Minimal target-insertion transaction

The first feature should operate only when the dragged and target windows belong to the same tiling tree on the same workspace and monitor.

The existing `BSPTree.Snapshot` excludes child pointers and cannot restore topology after insertion. Use a candidate tree or a topology-capable snapshot; do not reuse the swap snapshot unchanged.

At mouse-down, capture:

- The complete affected BSP topology, including split directions, ratios, user-set flags, and leaf order.
- Actual readable frames for every affected window.
- Membership, floating state, workspace, monitor identity, Max Splits value, and an operation generation.

At drop:

1. Choose the target from the pointer position, not the dragged window's center.
2. Choose one of four target edges using a simple, deterministic region rule. A lightweight preview is useful if it is reliable, but it should not continuously mutate the tree.
3. Build a candidate tree in memory by removing the dragged leaf and splitting the target leaf on the chosen side.
4. Reject the candidate before any AX writes if it exceeds Max Splits, crosses workspace or monitor boundaries, violates known coarse geometry, or the relevant state changed during the drag.
5. Attempt the candidate once through the verified sizing seam.
6. Commit the candidate topology only if every affected window is accepted and the aggregate geometry is valid.
7. Otherwise restore the complete old topology and the actual pre-drag frames, then verify restoration. If restoration is rejected or unknown, stop retrying and report the degraded state clearly.

Keep existing keyboard swap behavior. If drag swapping remains, use one explicit modifier rather than ambiguous center-versus-edge behavior. The first implementation does not need presets, equalize commands, `preselect`, `smart_split`, cross-monitor reparenting, or scratchpad integration.

## Test plan

Build red-capable deterministic tests before production changes. The core harness should use a fake AX adapter and fake monotonic clock. It must script the result of each position write, size write, read, and elapsed-time advance without requiring WindowServer.

Sizing seam cases:

- Immediate exact acceptance.
- Delayed acceptance before the actual deadline.
- Persistent shrink refusal and persistent grow refusal.
- Accepted size with rejected or clamped position.
- Explicit AX write errors.
- Failed reads and intermittent reads.
- An unsettled result at the deadline.
- A slow AX call that consumes the deadline without sleeps.
- A late response from an older transaction generation.
- Successful first pass followed by rejected adjusted pass.
- Small per-window errors that create aggregate overlap or erase the configured gap.
- A window closing and a display/workspace change during the attempt.
- Restoration success, restoration rejection, and restoration unknown.

Topology transaction cases:

- Insert on each side of a target and verify exact leaf order and split direction.
- Produce four vertical columns without any leaf being forced to half the screen.
- Preserve unrelated branches, ratios, workspace membership, floating state, and focus.
- Enforce Max Splits before AX writes.
- Reject cross-monitor, cross-workspace, scratchpad, and stale-state drops in the first version.
- Preserve keyboard swap and any explicitly supported modifier-drag swap.
- Prove failed or unknown candidate application restores the original topology and frames.

After deterministic tests pass, add a narrow SIP-enabled manual matrix using a controlled test app plus representative constrained apps such as Messages, Spotify, Safari or Chrome, and Xcode. Exercise shrink refusal, grow refusal, delayed acceptance, four columns on a wide display, rollback, monitor changes, app closure during a drop, and restart/state restoration. Automated seam tests support the implementation; they do not replace live confirmation of visual behavior.

## Recommended delivery order

1. Land the current UX stability audit independently.
2. Add fake AX and clock seams with tests that characterize current behavior.
3. Correct write-result handling, actual-deadline accounting, full-frame verification, final-pass readback, and aggregate overlap checks with focused red/green evidence.
4. Run the full documented suite and repeat controlled live sizing checks before changing drag topology.
5. Add pure candidate-tree insertion and rollback tests.
6. Wire same-workspace, same-monitor pointer-edge insertion through the verified transaction.
7. After fresh authorization for live app changes, deploy to the existing canonical debug path and perform the manual matrix before deciding whether to broaden the feature. The previous deployment authorization does not authorize new experiments on live windows or settings.

The success criterion is conservative and observable: report success only for a verified non-overlapping layout, or a normal rejection only after verifying restoration. If the app also refuses restoration, return a distinct degraded result and bounded recovery; external apps prevent a universal restoration guarantee. A rejected custom arrangement is acceptable. Silent overlap, hidden topology mutation, automatic eviction, or an unverified rollback is not.
