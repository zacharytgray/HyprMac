// Named constants for the tiling subsystem. Single source for every
// magic number that BSPNode, BSPTree, TilingEngine, MinSizeMemory, and
// FrameReadbackPoller would otherwise inline.

import Foundation

/// Tiling-subsystem constants.
///
/// Every value carries an origin (empirical / specified / OS-imposed)
/// and notes the effect of changing it. User-tunable defaults (gap,
/// padding) live here too — they are still configurable via
/// `UserConfig` at runtime, but the defaults are single-sourced here so
/// every tiling type agrees.
enum TilingConfig {

    // MARK: - layout defaults (user-tunable)

    // user-tunable. matched against UserConfig.json on init.
    static let defaultGap: CGFloat = 8
    static let defaultOuterPadding: CGFloat = 8

    // BSP depth ceiling. depth N → smallest slot = 1/2^N of the screen.
    // 3 → 1/8 of the screen; beyond this, windows auto-float.
    static let defaultMaxDepth: Int = 3

    // smart-insert backtracking threshold (px). when splitting a leaf would
    // create children below this on either axis, smart insert backtracks to a
    // shallower leaf. produces 2x2 grids on vertical monitors.
    static let minSlotDimension: CGFloat = 500

    // MARK: - split ratio bounds

    // empirical. 0.85/0.15 keeps the smaller side at >= ~15% of the parent
    // slot, preventing one child from being squeezed into an unusable strip.
    // shared by BSPTree.adjustForMinSizes/applyResizeDelta and TilingEngine.pairFits.
    static let minRatio: CGFloat = 0.15
    static let maxRatio: CGFloat = 0.85
    static let defaultRatio: CGFloat = 0.5

    // ratios within this delta of the current value are not written back —
    // avoids no-op AX writes triggered by sub-pixel jitter during manual resize.
    static let manualResizeRatioTolerance: CGFloat = 0.01

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

    // tolerance for over/undershoot in TilingEngine.applyLayout pass-1 readback.
    // ignores rounding noise; conflicts beyond this trigger pass-2 ratio adjust.
    static let frameToleranceXPx: CGFloat = 20

    // AX read cadence during pass-1 readback. tighter = more samples but more
    // sleep churn; looser = slower convergence on slow apps (Spotify, Messages).
    static let readbackPollInterval: TimeInterval = 0.03

    // hard cap before giving up on a window settling. exceeds Spotify's
    // slowest observed resize.
    static let readbackMaxWait: TimeInterval = 0.36

    // floor before an over-target reading is eligible to adjust the parent
    // ratio. apps that haven't finished resizing this long after the request
    // are treated as having a real minimum.
    static let readbackMinConflictSettle: TimeInterval = 0.24

    // consecutive matching reads required to call a frame "settled".
    static let readbackStableSamples: Int = 2

    // px wiggle that still counts as the same reading during settle detection.
    static let readbackStableTolerancePx: CGFloat = 2

    // MARK: - geometric tolerances

    // 1px slack on rect comparisons in pairFits (sub-pixel rounding).
    static let rectComparisonSlackPx: CGFloat = 1
}
