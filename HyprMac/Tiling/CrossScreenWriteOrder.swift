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
    /// fits the screen it stands on, but not from where it stands: moved,
    /// then resized
    case positionFirstOverflow(source: String)

    var description: String {
        switch self {
        case let .sizeFirst(source): return "size-first (fits source \(source))"
        case .positionFirstParked: return "position-first (parked)"
        case let .positionFirst(source): return "position-first (does not fit source \(source))"
        case let .positionFirstOverflow(source):
            return "position-first (hangs off source \(source) from where it stands)"
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

    /// The order for a window that stays on its screen, or nil to size it
    /// where it stands, which is the default.
    ///
    /// A size written where the window stands is clamped at the screen's
    /// right and bottom edges when the target, put at the window's current
    /// origin, hangs off them. The resend after the move then has to finish
    /// the job, and not every app takes that. Telegram in a 595 pt right
    /// column at x=1955 on a 2560 pt screen, sent 1265x823: the first size
    /// landed 605 wide, and the resend that widened it to 1265 at the target
    /// origin came back 32 pt shorter with the bottom edge kept, so every
    /// togglesplit back to a stack was refused as a geometry mismatch.
    /// Telegram is off by those 32 pt whenever a size write changes its
    /// width across its layout switch. Moved first to a spot the size fits,
    /// the full width lands in the first size write (1265x791), and the
    /// resend at the target origin only has the height left to fix, which
    /// it does: 1265x823, accepted 20 times out of 20 live.
    ///
    /// The edges are the full frame's: the clamp was at 2560, not at the
    /// usable frame's 2550. A target bigger than the screen is left to the
    /// default; nothing here makes it fit.
    static func decideInPlace(from original: CGRect, targetSize: CGSize, source: Source?,
                              sizeSlack: CGFloat) -> CrossScreenWriteOrder? {
        guard let source, original.isSubstantiallyVisible(on: source.fullFrame),
              targetSize.width <= source.fullFrame.width + sizeSlack,
              targetSize.height <= source.fullFrame.height + sizeSlack else { return nil }
        let hangsRight = original.minX + targetSize.width > source.fullFrame.maxX + sizeSlack
        let hangsBelow = original.minY + targetSize.height > source.fullFrame.maxY + sizeSlack
        return hangsRight || hangsBelow ? .positionFirstOverflow(source: source.name) : nil
    }
}
