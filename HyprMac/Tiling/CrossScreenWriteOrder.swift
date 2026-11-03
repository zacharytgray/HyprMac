// How a window crossing onto another screen takes its frame. Pure; the engine
// reads the screens and logs the "write order:" notice.

import CoreGraphics

/// How a window crossing onto another screen takes its frame, and why.
enum CrossScreenWriteOrder: CustomStringConvertible {
    /// resized on the screen it stands on, moved, resized again
    case sizeFirst(source: String)
    /// parked, hidden or on no screen: moved, then resized
    case positionFirstParked
    /// bigger than the screen it stands on: moved, then resized
    case positionFirst(tooSmallSource: String)

    var description: String {
        switch self {
        case let .sizeFirst(source): return "size-first (fits source \(source))"
        case .positionFirstParked: return "position-first (parked)"
        case let .positionFirst(source): return "position-first (does not fit source \(source))"
        }
    }

    /// The screen the window stands on.
    struct Source {
        let name: String
        let fullFrame: CGRect
        let usableFrame: CGRect
    }

    static func decide(from original: CGRect, targetSize: CGSize, source: Source?,
                       sizeSlack: CGFloat) -> CrossScreenWriteOrder {
        // a hide-corner sliver counts for the screen it is parked on, so
        // check the frame really stands there before trusting that screen
        guard let source, original.isSubstantiallyVisible(on: source.fullFrame) else {
            return .positionFirstParked
        }
        guard targetSize.width <= source.usableFrame.width + sizeSlack,
              targetSize.height <= source.usableFrame.height + sizeSlack else {
            return .positionFirst(tooSmallSource: source.name)
        }
        return .sizeFirst(source: source.name)
    }
}
