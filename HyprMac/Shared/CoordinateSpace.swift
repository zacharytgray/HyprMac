// CG ↔ NS coordinate conversion seam. CG uses a top-left origin; NS
// uses bottom-left. Conversion anchors on the primary screen height
// (`NSScreen.screens.first?.frame.height`).

import Foundation
import AppKit

/// Conversion namespace for CG ↔ NS coordinate work.
///
/// Today the active conversions live inline in the call sites
/// (`MouseTrackingManager`, `FocusBorder`, `DimmingOverlay`,
/// `DisplayManager`). This enum is the agreed home for the next
/// shared helper if a third caller appears or if the conversion
/// pattern grows beyond `primaryScreenHeight - y`.
enum CoordinateSpace {}
