// Which AX windows discovery lets into its snapshot. One place for the rule,
// with plain values in and out, so tests drive it without live AX.

import ApplicationServices

/// The identity half of discovery's AX walk: which windows HyprMac manages
/// at all.
///
/// Standard windows get in as they always have: role `AXWindow`, subrole
/// `AXStandardWindow` (or none), not modal. Everything else is dropped:
/// sheets, dialogs, floating panels, popovers.
///
/// The one exception is the Quick Look preview panel (`QLPreviewPanel`). It
/// is a shared panel living in whichever app opened it (Finder, Messages,
/// Mail), not in a Quick Look process. On the macOS 15.7 hub, in-process, it
/// reports role `AXWindow` and subrole `"Quick Look"`; its role description
/// is the generic `window`, and it has no identifier, title or document. So
/// the subrole is the only Quick Look signal. An admitted panel always
/// floats (`FloatingAdmissionPolicy`); it never enters a tree. The rule adds
/// what the panel must also be before it is managed:
///
/// - not modal;
/// - not in native full screen (`AXFullScreen`);
/// - backed by its own CG window, found through `_AXUIElementGetWindow`
///   and never by position, that is visible (alpha above 0.01) on the
///   normal or floating layer. The panel sits at the floating level (CG
///   layer 3) while its app is active. Quick Look's own full-screen view
///   sets the panel's alpha to 0 and draws on higher layers, so a panel in
///   that view fails this check and leaves the snapshot.
///
/// Threading: pure; no state.
enum WindowAdmissionFilter {

    /// Subrole `QLPreviewPanel` reports. Read on macOS 15.7.9 (24G830).
    static let quickLookSubrole = "Quick Look"

    /// CG layers a Quick Look panel can sit on: normal, and floating while
    /// its app is active.
    static let quickLookLayers: Set<Int> = [
        Int(CGWindowLevelForKey(.normalWindow)),
        Int(CGWindowLevelForKey(.floatingWindow)),
    ]

    /// Why a window stayed out of the snapshot.
    enum DropReason: String, Equatable {
        case role
        case subrole
        case modal
        /// a Quick Look panel in native full screen
        case fullScreen
        /// a Quick Look panel whose own CG window is missing, invisible, or
        /// on a layer the panel never uses
        case noVisibleWindow
    }

    enum Verdict: Equatable {
        /// an ordinary standard window; discovery matches it as before
        case standard
        /// a Quick Look panel, managed as a floating window
        case quickLookPanel
        case dropped(DropReason)
    }

    /// The on-screen CG entry for a window's own id.
    struct CGWindowFacts: Equatable {
        let layer: Int
        let alpha: CGFloat
    }

    static func isQuickLookSubrole(_ subrole: String?) -> Bool {
        subrole == quickLookSubrole
    }

    /// Decide one AX window.
    ///
    /// `isFullScreen` and `cgWindow` are asked only for a Quick Look
    /// candidate, so a standard window costs no extra AX reads. `cgWindow`
    /// is the entry for the id `_AXUIElementGetWindow` returned, or nil when
    /// there is no such id or no on-screen entry for it.
    static func classify(role: String?,
                         subrole: String?,
                         isModal: Bool,
                         isFullScreen: () -> Bool,
                         cgWindow: () -> CGWindowFacts?) -> Verdict {
        guard role == kAXWindowRole as String else { return .dropped(.role) }
        if isModal { return .dropped(.modal) }
        if subrole == nil || subrole == kAXStandardWindowSubrole as String { return .standard }
        guard isQuickLookSubrole(subrole) else { return .dropped(.subrole) }
        if isFullScreen() { return .dropped(.fullScreen) }
        guard let cg = cgWindow(), quickLookLayers.contains(cg.layer), cg.alpha > 0.01 else {
            return .dropped(.noVisibleWindow)
        }
        return .quickLookPanel
    }
}
