import Foundation
import AppKit

// CG ↔ NS coordinate conversion.
// CG uses top-left origin; NS uses bottom-left origin. conversion depends on the primary
// screen height (NSScreen.screens.first?.frame.height).
//
// per §5.2 of REFACTOR_PLAN.md, this consolidates duplicated conversion logic currently in:
//   - MouseTrackingManager:51
//   - FocusBorder:286
//   - DimmingOverlay:138
//
// extraction happens in a later phase. this file establishes the seam so callers can migrate
// one at a time without churning the include graph.
//
// placeholder — populated when conversion sites are migrated.
enum CoordinateSpace {}
