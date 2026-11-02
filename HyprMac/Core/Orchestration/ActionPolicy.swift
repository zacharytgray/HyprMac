// Which gates a pressed action passes before it reaches `ActionDispatcher`.
// Pure decisions; `WindowManager.handleAction` runs the effects.

import Foundation

enum ActionPolicy {
    enum Outcome: Equatable {
        case toggleOverview
        case dropMidDisplayTransition
        case scratchpad(ScratchpadActionRoute)
        case dispatch
    }

    struct Decision: Equatable {
        let cancelsRecovery: Bool
        let outcome: Outcome
    }

    /// Gate order: overview, cancel recovery, transition drop, scratchpad. A
    /// press the transition drops still cancels a recovery.
    static func decide(_ action: Action,
                       displayTransitionPending: Bool,
                       scratchpadVisible: Bool) -> Decision {
        if action == .showWorkspaceOverview {
            return Decision(cancelsRecovery: false, outcome: .toggleOverview)
        }
        let outcome: Outcome
        if displayTransitionPending, isDroppedMidDisplayTransition(action) {
            outcome = .dropMidDisplayTransition
        } else if scratchpadVisible, let route = ScratchpadActionRoute.route(for: action) {
            outcome = .scratchpad(route)
        } else {
            outcome = .dispatch
        }
        return Decision(cancelsRecovery: cancelsPendingRecovery(action), outcome: outcome)
    }

    /// Actions that wait out a display transition. Save and restore are in
    /// here too: mid-transition the topology key and the trees are both in
    /// flux, so a save would file a half-migrated layout and a restore would
    /// be undone by the settle reconcile.
    static func isDroppedMidDisplayTransition(_ action: Action) -> Bool {
        switch action {
        case .switchWorkspace, .moveToWorkspace, .moveToWorkspaceAndFollow, .moveWindowToMonitor,
             .cycleWorkspace, .moveToNextEmptyWorkspace, .saveLayout, .restoreLayout, .retileAll:
            return true
        default:
            return false
        }
    }

    /// Whether `action` makes an armed admission retry stale.
    ///
    /// Whatever the user just asked for is newer than a retry armed off a
    /// layout they have already moved past. Focus and informational actions
    /// preserve recovery, as does showing the workspace a newcomer has been waiting
    /// for, and forgetting it here would hand it a fresh timer on the reveal
    /// retile instead of its one remaining attempt.
    ///
    /// Resize, swap and split toggle preserve it too. They only rework the
    /// live tree, which never holds a stranded window, so nothing they do
    /// gives it another attempt: a move to a visible workspace followed by a
    /// quick resize used to leave the window assigned, in no tree, and with
    /// nothing scheduled.
    static func cancelsPendingRecovery(_ action: Action) -> Bool {
        switch action {
        case .switchWorkspace, .cycleWorkspace, .focusDirection, .focusFloating,
             .focusMenuBar, .showKeybinds, .showWorkspaceOverview, .launchApp,
             .runCommand, .saveLayout, .resizeDirection, .swapDirection, .toggleSplit:
            return false
        default: return true
        }
    }
}

/// What an action does first while the scratchpad layer is up. Workspace flows
/// dismiss the layer, then run normally. Float-toggle and floater-cycle get
/// scratchpad semantics: toggling a member into the dimmed workspace's tree, or
/// cycling into invisible floaters under the scrim, both read as broken.
enum ScratchpadActionRoute: Equatable {
    /// Eject a summoned member into tiling, or dismiss the layer when focus
    /// is not a member. The normal move flow then relocates it.
    case ejectThenDispatch
    case hideThenDispatch
    case refuse
    /// Toggle a summoned member tiled or floating within the layer, or send
    /// the focused window to it.
    case toggleMember
    case cycleSummoned
    /// An app with a member up focuses that member. Activating the app would
    /// bring its other windows forward over the scrim.
    case focusMemberElseDispatch(bundleID: String)

    /// Nil means the layer does not change how `action` runs.
    static func route(for action: Action) -> ScratchpadActionRoute? {
        switch action {
        case .moveToWorkspace, .moveToWorkspaceAndFollow, .moveWindowToMonitor:
            return .ejectThenDispatch
        case .switchWorkspace, .cycleWorkspace:
            return .hideThenDispatch
        case .moveToNextEmptyWorkspace:
            return .refuse
        case .toggleFloating:
            return .toggleMember
        case .focusFloating:
            return .cycleSummoned
        case .launchApp(let bundleID):
            return .focusMemberElseDispatch(bundleID: bundleID)
        default:
            return nil
        }
    }
}
