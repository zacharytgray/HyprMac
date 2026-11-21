// Native window tabs (Terminal, Finder, any app with "Prefer tabs"): every tab
// is its own window and only the selected one is on screen. A tab switch is
// one window leaving and another of the same app standing in its frame. These
// are the pure rules that recognise it.

import CoreGraphics

/// A window that left and the window of the same app that took its frame.
/// `shown` takes over the place `hiddenID` had: workspace, leaf or floating
/// state, and focus.
struct TabSwitch {
    let hiddenID: CGWindowID
    let shown: HyprWindow
    /// the shown tab stands in the frame the hidden one was last read at,
    /// so nothing needs writing
    let keepsFrame: Bool
}

enum TabSwitchPairing {
    // macOS gives the selected tab the group's frame. Terminal rounds the
    // width to its cell grid, and the tab bar comes and goes when the tab
    // count crosses one, which changes the height by up to about 30 points
    static let originTolerance: CGFloat = 4
    static let widthTolerance: CGFloat = 8
    static let heightTolerance: CGFloat = 32

    /// A known window missing from the walk, with the frames it was last
    /// read at.
    struct Leaver: Equatable {
        let windowID: CGWindowID
        let pid: pid_t
        let frames: [CGRect]
    }

    /// A window the walk read that discovery does not know: new, or back
    /// from hidden.
    struct Arrival: Equatable {
        let windowID: CGWindowID
        let pid: pid_t
        let frame: CGRect?
    }

    /// A new tab is published at 0×0 and sized a moment later. Such a frame
    /// says nothing about where the window stands.
    static func isUnsized(_ frame: CGRect?) -> Bool {
        guard let frame, !frame.isNull else { return true }
        return frame.width < 2 || frame.height < 2
    }

    static func sharesSlot(_ frame: CGRect?, with reference: CGRect) -> Bool {
        guard let frame, !isUnsized(frame), !isUnsized(reference) else { return false }
        return abs(frame.minX - reference.minX) <= originTolerance
            && abs(frame.minY - reference.minY) <= originTolerance
            && abs(frame.width - reference.width) <= widthTolerance
            && abs(frame.height - reference.height) <= heightTolerance
    }

    static func stands(_ frame: CGRect?, inPlaceOf leaver: Leaver) -> Bool {
        leaver.frames.contains { sharesSlot(frame, with: $0) }
    }

    /// Whether `frame` is one of the frames the leaver had, to the point.
    static func keepsFrame(_ frame: CGRect?, of leaver: Leaver) -> Bool {
        guard let frame else { return false }
        return leaver.frames.contains {
            abs(frame.minX - $0.minX) <= 1 && abs(frame.minY - $0.minY) <= 1
                && abs(frame.width - $0.width) <= 1 && abs(frame.height - $0.height) <= 1
        }
    }

    /// Leaver to arrival, for every pair with no other candidate on either
    /// side. Two windows of one app can share a frame, so anything ambiguous
    /// pairs with nothing and takes the ordinary close and open.
    static func pairs(leavers: [Leaver], arrivals: [Arrival]) -> [CGWindowID: CGWindowID] {
        func matches(_ leaver: Leaver, _ arrival: Arrival) -> Bool {
            leaver.pid == arrival.pid && leaver.windowID != arrival.windowID
                && stands(arrival.frame, inPlaceOf: leaver)
        }
        var result: [CGWindowID: CGWindowID] = [:]
        for leaver in leavers {
            let candidates = arrivals.filter { matches(leaver, $0) }
            guard candidates.count == 1, let arrival = candidates.first,
                  leavers.filter({ matches($0, arrival) }).count == 1 else { continue }
            result[leaver.windowID] = arrival.windowID
        }
        return result
    }
}
