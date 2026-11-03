// Tree geometry and min-size constants for the tiling subsystem. Sizing
// timing lives in FrameSizingConfiguration.

import Foundation

/// Tiling-subsystem constants.
///
/// Every value carries an origin (empirical / specified / OS-imposed)
/// and notes the effect of changing it. User-tunable defaults (gap,
/// padding) live here too — they are still configurable via
/// `UserConfig` at runtime. These are engine fallbacks; `WindowManager`
/// pushes the user's values at start.
enum TilingConfig {

    // MARK: - layout defaults (user-tunable)

    // user-tunable.
    static let defaultGap: CGFloat = 8
    static let defaultOuterPadding: CGFloat = 8

    // BSP depth ceiling. depth N → smallest slot = 1/2^N of the screen.
    // 3 → 1/8 of the screen. the default; each monitor can set 1 to 7.
    static let defaultMaxDepth: Int = 3

    // smart-insert backtracking threshold (px). when splitting a leaf would
    // create children below this on either axis, smart insert backtracks to a
    // shallower leaf. produces 2x2 grids on vertical monitors.
    static let minSlotDimension: CGFloat = 500

    // MARK: - split ratio bounds

    // empirical. 0.85/0.15 keeps the smaller side at >= ~15% of the parent
    // slot, preventing one child from being squeezed into an unusable strip.
    // shared by BSPTree.adjustForMinSizes/applyResizeDelta and LayoutEngine.pairFit.
    static let minRatio: CGFloat = 0.15
    static let maxRatio: CGFloat = 0.85
    static let defaultRatio: CGFloat = 0.5

    // ratios within this delta of the current value are not written back —
    // avoids no-op AX writes triggered by sub-pixel jitter during manual resize.
    static let manualResizeRatioTolerance: CGFloat = 0.01

    // step size for keyboard-driven resize (resizeDirection action).
    static let resizeStep: CGFloat = 0.05

    // MARK: - min-size memory

    // slack on min-size conflict comparisons in BSPTree.adjustForMinSizes.
    // apps occasionally round actualSize up by a pixel; without this slack
    // we'd treat 1px overshoots as min-size violations.
    static let minSizeConflictSlackPx: CGFloat = 5

    // an observed actual size this many px smaller than the recorded min
    // unlocks a new (lower) min bound. without this, a one-time tight resize
    // would never relax our memory of an app's minimum.
    static let lowerMinSizeAcceptedDeltaPx: CGFloat = 10

    // upper bound for "real" min-size readings. anything above this is
    // assumed to be a bogus AX sentinel (apps occasionally report 16384 or
    // INT_MAX) and is rejected.
    static let usableMinSizeMaxPx: CGFloat = 10000

    // MARK: - frame readback (two-pass layout)

    // per-window match tolerance in the verified readback, and how far a known
    // minimum may overflow its slot. ignores rounding noise.
    static let frameToleranceXPx: CGFloat = 20

    // MARK: - pointer input

    // pointer travel between mouse-down and mouse-up below which a press is
    // a click, not a drag. a .leftMouseDragged event fires on 1pt of hand
    // jitter during an ordinary click; without this floor every such click
    // ran a full tiled-drag transaction and flashed red when the busy app's
    // frame read timed out.
    static let dragThresholdPx: CGFloat = 8

    // MARK: - geometric tolerances

    // 1px slack on rect comparisons in pairFits (sub-pixel rounding).
    static let rectComparisonSlackPx: CGFloat = 1
}
