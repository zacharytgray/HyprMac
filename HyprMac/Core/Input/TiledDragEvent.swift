import Cocoa

struct TiledDragEvent {
    static func point(event: NSEvent, primaryHeight: CGFloat) -> CGPoint {
        if let location = event.cgEvent?.location { return location }
        let appKitPoint = event.window?.convertPoint(toScreen: event.locationInWindow)
            ?? event.locationInWindow
        return CGPoint(x: appKitPoint.x, y: primaryHeight - appKitPoint.y)
    }

    /// Did this press actually move the pointer far enough to be a drag?
    ///
    /// macOS fires `.leftMouseDragged` on a pixel of hand jitter, so the
    /// event alone is not evidence. Travel from the press point decides.
    /// A nil press point (monitors installed mid-press) falls back to the
    /// event flag — the old behaviour.
    static func isDrag(from press: CGPoint?, to release: CGPoint, sawDragEvent: Bool,
                       threshold: CGFloat = TilingConfig.dragThresholdPx) -> Bool {
        guard sawDragEvent else { return false }
        guard let press else { return true }
        return hypot(release.x - press.x, release.y - press.y) >= threshold
    }

    /// Pointer travel from the press point, or nil when there was no
    /// press point to measure from. Diagnostics only.
    static func travel(from press: CGPoint?, to release: CGPoint) -> CGFloat? {
        guard let press else { return nil }
        return hypot(release.x - press.x, release.y - press.y)
    }

    static func release(event: NSEvent, primaryHeight: CGFloat,
                        sawDragEvent: Bool, swapRequested: Bool = false) -> TiledDragRelease {
        TiledDragRelease(pointer: point(event: event, primaryHeight: primaryHeight),
                         swapRequested: swapRequested,
                         sawDragEvent: sawDragEvent)
    }
}
