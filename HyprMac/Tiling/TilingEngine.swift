// One BSP tree per `(workspace, screen)` pair plus the orchestration
// surface that drives smart insert, swap, split toggling, two-pass
// readback, and min-size memory.

import Cocoa

/// Stable key for a `(workspace, screen)` tree.
private struct TilingKey: Hashable {
    let workspace: Int
    let screenID: Int

    init(workspace: Int, screen: NSScreen) {
        self.workspace = workspace
        self.screenID = Int(screen.frame.origin.x * 10000 + screen.frame.origin.y)
    }
}

private struct TiledDragOccluderContext: Equatable {
    let workspace: Int
    let physicalDisplayID: CGDirectDisplayID
    let usableFrame: CGRect
    let floatingIDs: Set<CGWindowID>
}

/// Owner of every BSP tree HyprMac maintains.
///
/// One tree per `(workspace, screen)` pair. Keeps gap/padding tunables,
/// per-screen depth overrides, min-size memory, and typed admission refusals. Public surface owns smart insert, swap, split toggling,
/// readback-driven settle/conflict resolution, and tree migration on
/// monitor reconnect.
///
/// Threading: main-thread only.
class TilingEngine {
    /// Result of applying a verified layout. Mirrors
    /// `FrameSizingTransaction.Outcome` but carries `restorationAttempted`,
    /// which says whether a rollback ran at all, and the progress of both
    /// attempts. Publication and cache recovery read the progress: the
    /// candidate's written set and the restoration's are different sets.
    enum LayoutApplicationOutcome: Equatable {
        case accepted(actualFrames: [CGWindowID: CGRect],
                      progress: FrameSizingProgressReport)
        case rejectedRestored(reason: FrameSizingFailure,
                              actualFrames: [CGWindowID: CGRect],
                              progress: FrameSizingProgressReport)
        case degraded(candidateReason: FrameSizingFailure,
                      restorationReason: FrameSizingFailure?,
                      restorationAttempted: Bool,
                      actualFrames: [CGWindowID: CGRect],
                      progress: FrameSizingProgressReport)
    }

    /// One `(workspace, screen)` whose last layout attempt did not leave
    /// verified geometry behind, with the ids involved. The admission
    /// recovery reads this when it decides what to finish.
    struct UnverifiedLayout {
        let workspace: Int
        /// nil when the screen that owned the key is gone.
        let screen: NSScreen?
        /// every id the failed attempt targeted, plus whatever the live
        /// tree still holds for that key.
        let windowIDs: Set<CGWindowID>
        /// ids the failed attempt had just inserted into its candidate.
        /// Empty for a retile, a swap or a drag.
        let insertedIDs: Set<CGWindowID>
    }

    private struct UnverifiedRecord {
        var windowIDs: Set<CGWindowID>
        var insertedIDs: Set<CGWindowID>
        /// every attempt on this key since the last accepted layout put its
        /// own originals back, verified. False the moment one did not, and
        /// it never recovers until an accepted layout drops the record —
        /// because from then on nobody knows where the incumbents are.
        var restorationVerifiedThroughout: Bool
    }

    /// What one tiling pass did with the windows it had just inserted.
    ///
    /// The failure's own window id is not the newcomer's id. A candidate
    /// fails on whichever window refused its frame, and that is usually an
    /// incumbent — Safari 21611 refused while 26016 was the new window. So
    /// the newcomers are carried here, by the ids the pass inserted, and the
    /// ones that did not survive publication are `failedInsertedIDs`.
    struct AdmissionResult {
        let workspace: Int
        let screen: NSScreen
        /// the generation the pass ran under. A retry ignores the minima
        /// this pass observed at or after it.
        let generation: UInt64
        /// ids the pass smart-inserted into its candidate.
        let insertedIDs: Set<CGWindowID>
        /// ids the live tree holds once the pass is over. On a failure this
        /// is the prior membership, so it never contains a newcomer.
        let publishedIDs: Set<CGWindowID>
        /// why the layout was not accepted. nil when it was.
        let failure: FrameSizingFailure?
        /// incumbents the rollback verifiably put back on their originals,
        /// against the strict one point bound. Empty when no rollback ran
        /// or it failed, which is also when the prior tree stops speaking
        /// for the screen.
        let restoredIDs: Set<CGWindowID>
        /// newcomers refused before sizing; recovery floats these without a retry.
        let refusedIDs: Set<CGWindowID>

        /// newcomers this pass could not leave tiled.
        var failedInsertedIDs: Set<CGWindowID> { insertedIDs.subtracting(publishedIDs) }
        /// every newcomer this pass left outside the tree, however it got
        /// there.
        var strandedIDs: Set<CGWindowID> { failedInsertedIDs.union(refusedIDs) }
        /// whether the rollback put every one of its targets back.
        var restorationVerified: Bool { !restoredIDs.isEmpty }
        var published: Bool { failure == nil }
    }

    /// What a forced insert did. The old optional return said "no eviction"
    /// and "nothing happened" with the same `nil`, so a caller could not
    /// tell a tiled window from a refused one.
    enum ForceInsertResult: Equatable {
        case alreadyPresent
        case inserted
        case failed(ForceInsertFailure)
    }

    enum ForceInsertFailure: Equatable {
        /// no available leaf accepts the window.
        case noFittingSlot
        /// the window fit the tree but the screen did not accept the layout.
        case layoutRejected(FrameSizingFailure)
    }

    /// One slot's reason for refusing an incoming window, with where the
    /// bound that refused it came from.
    ///
    /// There is one of these per leaf the search tried, never a single
    /// "largest free slot": which leaf can take a window depends on the split
    /// direction, the ratios and the tenant already sitting there, so one
    /// number would be a fiction.
    struct FitRefusal: Equatable {
        /// `learned` is a bound the app refused (`observed` provenance),
        /// `appHint` a bound another window of the same app refused, `seeded`
        /// an `AXMinimumSize` value nothing has tested, and `structural` a
        /// depth, count or slot-geometry limit no attempt can talk its way
        /// out of.
        enum Source: String { case learned, appHint, seeded, structural }

        let incoming: CGWindowID
        /// the tenant of the leaf that refused. nil for an empty leaf.
        let tenant: CGWindowID?
        let slot: CGSize
        let incomingMinimum: CGSize
        let tenantMinimum: CGSize
        let axis: String
        let source: Source
    }

    /// What a fit check says about an explicit user request.
    enum AdmissionOutlook: Equatable {
        case fits
        /// nothing but learned bounds or app hints is in the way. One real
        /// attempt would settle whether they are still true.
        case revalidatable([FitRefusal])
        /// refused for something an attempt cannot change — a seeded bound
        /// that survived the bypass, or structure.
        case refused([FitRefusal])
    }

    /// How far forward an explicit revalidation's bypass reaches: past every
    /// generation there will ever be, so every observed entry is covered.
    ///
    /// The admission retry ignores only bounds recorded *before* the
    /// admission it is retrying, because those are the ones that might be
    /// stale. A user asking again, by hand, is distrusting the whole observed
    /// record for these windows. It still erases nothing: the entries stand
    /// unless the attempt is accepted and lowers them through the ordinary
    /// reconcile path.
    static let revalidationBypassBefore: UInt64 = .max

    /// Pseudo-workspace the scratchpad layer's tree lives on. Matches
    /// `ScratchpadController.workspace`; kept local so the engine has no
    /// dependency on the controller.
    static let scratchpadWorkspace = 0

    private var trees: [TilingKey: BSPTree] = [:]
    // verified admission survives a temporary hide and a screen migration.
    private var admittedWindowIDs: [Int: Set<CGWindowID>] = [:]
    private var pendingInsertedWindowIDs: [TilingKey: [CGWindowID]] = [:]
    /// Keys whose last layout attempt did not produce verified geometry.
    /// Set by any non-accepted attempt, cleared by an accepted one or by
    /// lifecycle cleanup. Nothing in here advertises an intended rect.
    private var unverified: [TilingKey: UnverifiedRecord] = [:]
    let displayManager: DisplayManager

    /// Gap between adjacent tiles, in pixels. Default from
    /// `TilingConfig.defaultGap`; runtime-tunable from the settings UI.
    var gapSize: CGFloat = TilingConfig.defaultGap {
        didSet { if gapSize != oldValue { invalidatePendingLayout() } }
    }

    /// Padding between tiles and the screen edge, in pixels.
    /// Runtime-tunable.
    var outerPadding: CGFloat = TilingConfig.defaultOuterPadding {
        didSet { if outerPadding != oldValue { invalidatePendingLayout() } }
    }

    /// Per-screen max BSP depth overrides, keyed by
    /// `NSScreen.localizedName`. Falls back to
    /// `TilingConfig.defaultMaxDepth` for screens without an override.
    var maxSplitsPerMonitor: [String: Int] = [:] {
        didSet { if maxSplitsPerMonitor != oldValue { invalidatePendingLayout() } }
    }

    /// Effective max depth for `screen`, honoring any per-screen
    /// override.
    func maxDepth(for screen: NSScreen) -> Int {
        maxSplitsPerMonitor[screen.localizedName] ?? TilingConfig.defaultMaxDepth
    }

    /// Minimum child dimension (px) below which smart insert
    /// backtracks to a shallower leaf.
    var minSlotDimension: CGFloat = TilingConfig.minSlotDimension {
        didSet { if minSlotDimension != oldValue { invalidatePendingLayout() } }
    }

    private let minSizes = MinSizeMemory()
    /// generation at which each window last had an `.observed` minimum
    /// recorded. Only the bypass reads it.
    private var observedMinimumGeneration: [CGWindowID: UInt64] = [:]
    /// windows whose older observed minima one pass is ignoring, each with
    /// the generation to ignore them below. Per window, because two newcomers
    /// retried together were admitted at different generations and one must
    /// not inherit the other's reach. Set for one retry only.
    private var minimaBypass: [CGWindowID: UInt64]?
    private var layoutGeneration: UInt64 = 0
    private let frameSizingIOFactory: ([CGWindowID: HyprWindow], @escaping () -> UInt64) -> FrameSizingIO
    private let tiledDragDisplayID: (NSScreen) -> CGDirectDisplayID

    init(displayManager: DisplayManager,
         frameSizingIOFactory: @escaping ([CGWindowID: HyprWindow], @escaping () -> UInt64) -> FrameSizingIO = FrameSizingIO.accessibility,
         tiledDragDisplayID: @escaping (NSScreen) -> CGDirectDisplayID = {
             ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                 .uint32Value ?? 0
         }) {
        self.displayManager = displayManager
        self.frameSizingIOFactory = frameSizingIOFactory
        self.tiledDragDisplayID = tiledDragDisplayID
    }

    @discardableResult
    internal func beginLayoutGeneration() -> UInt64 {
        layoutGeneration &+= 1
        return layoutGeneration
    }

    @discardableResult
    private func invalidatePendingLayout() -> UInt64 {
        pendingSwapRevert = nil
        return beginLayoutGeneration()
    }

    /// Seed `MinSizeMemory` from current AX values for every window.
    /// Called before any layout pass so size constraints are fresh.
    func primeMinimumSizes(_ windows: [HyprWindow]) { minSizes.prime(windows) }

    /// Everything `MinSizeMemory` currently believes, with the evidence
    /// behind each entry, for the state dump.
    var knownMinimumSizes: [CGWindowID: MinSizeMemory.Entry] { minSizes.snapshot }

    /// Drop any stored min-size memory for `windowID`. Called when a
    /// window is forgotten by the discovery layer.
    func forgetMinimumSize(windowID: CGWindowID) {
        forgetAdmittedIdentity(windowID: windowID)
        minSizes.forget(windowID: windowID)
        observedMinimumGeneration.removeValue(forKey: windowID)
    }

    /// Drop verified-admission identity for `windowID`, leaving its learned
    /// minima alone. Discovery calls this the moment an id turns up as a new
    /// window rather than a returned one: CGWindowIDs get recycled, and a
    /// fresh window inheriting the old one's incumbency would quietly lose
    /// its place in admission recovery.
    func forgetAdmittedIdentity(windowID: CGWindowID) {
        for workspace in Array(admittedWindowIDs.keys) {
            admittedWindowIDs[workspace]?.remove(windowID)
        }
    }

    /// Defensive cleanup — drop `windowID` from whichever BSP tree
    /// currently holds it and prune empties. Called from the discovery
    /// gone path so a closed window's node cannot outlive its AX presence
    /// even when the owning workspace is hidden (and therefore skipped by
    /// `tileAllVisibleSpaces`). Sibling promotion keeps the surviving
    /// arrangement intact — no compact, so a transient disappearance
    /// (Cmd-H, minimize, missed AX poll) doesn't reshuffle the tree.
    /// No-op when no tree contains `windowID`.
    func removeWindowID(_ windowID: CGWindowID) {
        for (_, t) in trees {
            guard let w = t.allWindows.first(where: { $0.windowID == windowID }) else { continue }
            invalidatePendingLayout()
            t.remove(w)
            t.root.pruneEmptyNodes()
            return
        }
    }

    /// The bound a fit check should honour for `window`.
    ///
    /// A bypass sets aside an observed bound recorded *before* its own
    /// generation — evidence old enough that the app may have changed its
    /// mind since. Anything the current admission itself observed stands:
    /// that readback passed the learning guards (complete writes, a complete
    /// stable readback at the target origin, a geometric refusal), so it is
    /// the best thing anyone knows about the window, and probing it again
    /// only repeats the resize the user just watched.
    ///
    /// An explicit request — a float→tile, a move, the fit diagnostic —
    /// sets aside an app hint too. A hint is another window's evidence, and
    /// this window has never been asked; without this the hinted window has
    /// no way back into a tree and only a restart clears it.
    ///
    /// Seeded hints and every other window's memory all still count, and the
    /// memory itself is untouched either way.
    private func minimumSize(for window: HyprWindow?) -> CGSize {
        guard let window else { return .zero }
        if let before = minimaBypass?[window.windowID], bypasses(window.windowID, before: before) {
            return .zero
        }
        return minSizes.minimumSize(for: window)
    }

    /// Whether a bypass reaching back to `before` covers this window's entry.
    private func bypasses(_ windowID: CGWindowID, before: UInt64) -> Bool {
        switch minSizes.entry(for: windowID)?.provenance {
        case .observed:
            return (observedMinimumGeneration[windowID] ?? 0) < before
        case .appHint:
            // only the explicit kind. an admission retry keeps the hint: it
            // is what the app just told us through its other window.
            return before == Self.revalidationBypassBefore
        default:
            return false
        }
    }

    private func tree(for key: TilingKey) -> BSPTree {
        if let existing = trees[key] { return existing }
        let tree = BSPTree()
        trees[key] = tree
        return tree
    }

    /// Non-creating tree accessor for tests. Returns the live tree
    /// for `(workspace, screen)`, or `nil` when none exists.
    /// Production callers go through `tree(for:)` so the tree is
    /// created on demand.
    internal func existingTree(forWorkspace workspace: Int, screen: NSScreen) -> BSPTree? {
        trees[TilingKey(workspace: workspace, screen: screen)]
    }

    /// Leaf window ids of the live tree for `(workspace, screen)`, in
    /// tree order. Read-only — never creates a tree. Used by the state
    /// dump to show tree membership without exposing the tree itself.
    func windowIDs(inTreeForWorkspace workspace: Int, screen: NSScreen) -> [CGWindowID] {
        existingTree(forWorkspace: workspace, screen: screen)?.allWindows.map(\.windowID) ?? []
    }

    // MARK: - layout persistence

    /// Serialised shape of `workspace`'s tree on whichever screen holds
    /// it, or `nil` when the workspace has no tiled windows. `ref` names
    /// each window in a restart-stable way; a window it declines (no
    /// bundle ID) is dropped and its split collapses, exactly as if it
    /// had closed. Read-only — the engine stays the only thing that
    /// walks nodes (`docs/architecture.md`).
    func layoutTree(forWorkspace workspace: Int, ref: (HyprWindow) -> SavedWindowRef?) -> LayoutNode? {
        for (key, t) in trees where key.workspace == workspace && !t.allWindows.isEmpty {
            if let root = Self.serialize(t.root, ref: ref) { return root }
        }
        return nil
    }

    private static func serialize(_ node: BSPNode, ref: (HyprWindow) -> SavedWindowRef?) -> LayoutNode? {
        if let window = node.window {
            return ref(window).map(LayoutNode.leaf)
        }
        guard let left = node.left, let right = node.right else { return nil }
        switch (serialize(left, ref: ref), serialize(right, ref: ref)) {
        case (nil, nil):
            return nil
        case (let only?, nil), (nil, let only?):
            return only
        case (let l?, let r?):
            return .split(override: node.splitOverride, ratio: node.splitRatio,
                          userSet: node.userSetRatio, left: l, right: r)
        }
    }

    func captureTiledDrag(draggedID: CGWindowID, workspace: Int, screen: NSScreen,
                          floatingIDs: Set<CGWindowID>) -> TiledDragCaptureResult {
        let key = TilingKey(workspace: workspace, screen: screen)
        guard let sourceTree = trees[key] else { return .ineligible(.notTiled) }
        let generation = invalidatePendingLayout()
        guard let context = tiledDragContext(workspace: workspace, screen: screen,
                                             floatingIDs: floatingIDs,
                                             sourceTree: sourceTree) else {
            return .unknown(.superseded)
        }
        let transaction = TiledDragTransaction(ioFactory: frameSizingIOFactory,
                                               minimumSize: minimumSize(for:))
        return transaction.capture(
            draggedID: draggedID, tree: sourceTree, context: context,
            generation: generation,
            currentContext: {
                guard self.layoutGeneration == generation else { return nil }
                return self.tiledDragContext(workspace: workspace, screen: screen,
                                             floatingIDs: floatingIDs,
                                             sourceTree: sourceTree)
            }
        )
    }

    func captureTiledDrag(
        pointer: CGPoint,
        occludingWindows: [HyprWindow],
        currentLocation: @escaping () -> (workspace: Int, screen: NSScreen,
                                          floatingIDs: Set<CGWindowID>)?,
        onCapturedFrames: ([CGWindowID: CGRect]) -> Void = { _ in }
    ) -> TiledDragCaptureResult {
        guard let initialLocation = currentLocation() else { return .unknown(.superseded) }
        let key = TilingKey(workspace: initialLocation.workspace, screen: initialLocation.screen)
        guard let sourceTree = trees[key] else {
            return captureTiledDragOccluders(
                occludingWindows, initialLocation: initialLocation,
                currentLocation: currentLocation, onCapturedFrames: onCapturedFrames)
        }
        let generation = invalidatePendingLayout()
        guard let context = tiledDragContext(
            workspace: initialLocation.workspace, screen: initialLocation.screen,
            floatingIDs: initialLocation.floatingIDs, sourceTree: sourceTree
        ) else { return .unknown(.superseded) }
        let transaction = TiledDragTransaction(ioFactory: frameSizingIOFactory,
                                               minimumSize: minimumSize(for:))
        return transaction.capture(
            pointer: pointer, tree: sourceTree, context: context,
            occludingWindows: occludingWindows, generation: generation,
            currentContext: {
                guard self.layoutGeneration == generation,
                      let location = currentLocation() else { return nil }
                return self.tiledDragContext(workspace: location.workspace,
                                             screen: location.screen,
                                             floatingIDs: location.floatingIDs,
                                             sourceTree: sourceTree)
            },
            onCapturedFrames: onCapturedFrames
        )
    }

    private func captureTiledDragOccluders(
        _ windows: [HyprWindow],
        initialLocation: (workspace: Int, screen: NSScreen, floatingIDs: Set<CGWindowID>),
        currentLocation: @escaping () -> (workspace: Int, screen: NSScreen,
                                          floatingIDs: Set<CGWindowID>)?,
        onCapturedFrames: ([CGWindowID: CGRect]) -> Void
    ) -> TiledDragCaptureResult {
        var seen = Set<CGWindowID>()
        for window in windows where !seen.insert(window.windowID).inserted {
            return .unknown(.duplicateWindowID(window.windowID))
        }
        let generation = invalidatePendingLayout()
        guard let context = tiledDragOccluderContext(initialLocation) else {
            return .unknown(.superseded)
        }
        let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
        let io = frameSizingIOFactory(byID) {
            guard self.layoutGeneration == generation,
                  let location = currentLocation(),
                  self.tiledDragOccluderContext(location) == context else {
                return generation &+ 1
            }
            return generation
        }
        let captured = FrameSizingAttempt(io: io).captureFrames(
            windowIDs: windows.map(\.windowID), generation: generation)
        guard case .accepted = captured.verdict,
              captured.actualFrames.count == windows.count,
              layoutGeneration == generation,
              let location = currentLocation(),
              tiledDragOccluderContext(location) == context else {
            switch captured.verdict {
            case .accepted: return .unknown(.superseded)
            case let .rejected(reason), let .unknown(reason): return .unknown(reason)
            }
        }
        onCapturedFrames(captured.actualFrames)
        return .ineligible(.noTarget)
    }

    private func tiledDragOccluderContext(
        _ location: (workspace: Int, screen: NSScreen, floatingIDs: Set<CGWindowID>)
    ) -> TiledDragOccluderContext? {
        let displayID = physicalDisplayID(for: location.screen)
        let matchingScreens = displayManager.screens.filter {
            physicalDisplayID(for: $0) == displayID
        }
        guard matchingScreens.count == 1, let screen = matchingScreens.first else { return nil }
        return TiledDragOccluderContext(
            workspace: location.workspace,
            physicalDisplayID: displayID,
            usableFrame: displayManager.cgRect(for: screen),
            floatingIDs: location.floatingIDs)
    }

    func dropTiledDrag(
        _ snapshot: TiledDragSnapshot,
        mode: TiledDragMode?,
        currentLocation: @escaping () -> (workspace: Int, screen: NSScreen,
                                          floatingIDs: Set<CGWindowID>)?
    ) -> TiledDragDropOutcome {
        func currentState() -> (location: (workspace: Int, screen: NSScreen,
                                            floatingIDs: Set<CGWindowID>),
                                context: TiledDragContext)? {
            guard layoutGeneration == snapshot.generation,
                  let location = currentLocation() else { return nil }
            guard let context = tiledDragContext(workspace: location.workspace,
                                                 screen: location.screen,
                                                 floatingIDs: location.floatingIDs,
                                                 sourceTree: snapshot.sourceTree) else { return nil }
            return (location, context)
        }
        func currentContext() -> TiledDragContext? {
            currentState()?.context
        }

        guard currentContext() == snapshot.context else { return .superseded }
        let transaction = TiledDragTransaction(ioFactory: frameSizingIOFactory,
                                               minimumSize: minimumSize(for:))
        let outcome = transaction.dropRelease(snapshot, mode: mode,
                                              currentContext: currentContext)
        guard currentContext() == snapshot.context else { return .superseded }
        guard case let .committed(candidate, actualFrames, progress) = outcome else {
            noteDragGeometry(outcome, snapshot: snapshot)
            return outcome
        }
        guard let state = currentState(), state.context == snapshot.context else {
            return .superseded
        }
        let key = TilingKey(workspace: state.location.workspace, screen: state.location.screen)
        guard trees[key] === snapshot.sourceTree else { return .superseded }
        // the same gate a tiling candidate passes. an accepted verdict says
        // the frames read back on target; it does not say every setter
        // returned success, and a tree may only describe geometry it can
        // vouch for. the drop still stands for the caches — those frames
        // were read — but the key keeps its mark.
        guard progress.candidateVerified else {
            // the frames read back on target, so the caches can still take
            // the drop. the mark is a different question: the candidate is
            // not published, so the live tree still describes the pre-drag
            // arrangement while the windows sit in the post-drag one, and
            // nothing put them back. a swap would otherwise end up
            // advertising each window the other's slot.
            mark(key, windowIDs: snapshot.context.memberIDs, insertedIDs: [], restored: false)
            hyprLog(.notice, .tiling, "drag accepted but not fully written — tree not published")
            return outcome
        }
        trees[key] = candidate
        unverified.removeValue(forKey: key)
        return .committed(candidate: candidate, actualFrames: actualFrames, progress: progress)
    }

    /// A drag is a layout attempt too. Anything short of a committed drop
    /// leaves the dragged tile somewhere the tree did not put it, or the
    /// originals written back over it, so the key stops speaking for its
    /// geometry until a layout is accepted again.
    private func noteDragGeometry(_ outcome: TiledDragDropOutcome, snapshot: TiledDragSnapshot) {
        switch outcome {
        case .ignored, .superseded, .committed: return
        case .rejectedRestored, .degraded: break
        }
        guard let key = trees.first(where: { $0.value === snapshot.sourceTree })?.key else { return }
        var restored = false
        if case .rejectedRestored = outcome { restored = true }
        mark(key, windowIDs: snapshot.context.memberIDs, insertedIDs: [], restored: restored)
    }

    private func tiledDragContext(workspace: Int, screen: NSScreen,
                                  floatingIDs: Set<CGWindowID>,
                                  sourceTree: BSPTree) -> TiledDragContext? {
        let requestedDisplayID = physicalDisplayID(for: screen)
        let matchingScreens = displayManager.screens.filter {
            physicalDisplayID(for: $0) == requestedDisplayID
        }
        guard matchingScreens.count == 1, let currentScreen = matchingScreens.first else { return nil }
        let key = TilingKey(workspace: workspace, screen: currentScreen)
        guard trees[key] === sourceTree else { return nil }
        let memberIDs = sourceTree.allWindows.map(\.windowID)
        return TiledDragContext(
            workspace: workspace,
            physicalDisplayID: physicalDisplayID(for: currentScreen),
            usableFrame: displayManager.cgRect(for: currentScreen),
            gap: gapSize,
            padding: outerPadding,
            maxDepth: maxDepth(for: currentScreen),
            memberIDs: Set(memberIDs),
            floatingIDs: floatingIDs,
            fingerprint: sourceTree.structuralFingerprint()
        )
    }

    private func physicalDisplayID(for screen: NSScreen) -> CGDirectDisplayID {
        tiledDragDisplayID(screen)
    }

    /// Reconcile `trees` with the current monitor topology.
    ///
    /// When a screen is disconnected (e.g., laptop lid close, dock unplug), every
    /// `(workspace, screen)` tree keyed to the vanished screen must either move
    /// to the workspace's new home screen or be pruned. Without this, vanished
    /// trees linger forever, leaking memory and producing stale layouts when the
    /// monitor reconnects with the same physical position.
    ///
    /// - Parameters:
    ///   - currentScreens: the live screens (after `DisplayManager.refresh()`).
    ///   - homeScreenForWorkspace: closure that returns a workspace's current
    ///     home screen, or nil if the workspace has no live home. Caller is
    ///     responsible for running `WorkspaceManager.initializeMonitors()`
    ///     **before** calling this — otherwise the home-screen map is stale and
    ///     migrations target vanished destinations.
    ///
    /// - Note: TilingKey currently keys on screen-origin coordinates. If two
    ///   monitors swap positions during a reconnect, trees follow the position,
    ///   not the physical display. Migrating to `displayID` keying is a future
    ///   change (see plan §4.2 — deferred for risk reasons).
    func handleDisplayChange(currentScreens: [NSScreen],
                             homeScreenForWorkspace: (Int) -> NSScreen?) {
        // resolution and usable bounds can change without changing a tree key.
        invalidatePendingLayout()
        var migrations: [(old: TilingKey, dest: NSScreen)] = []
        var orphans: [TilingKey] = []

        // static anchoring guarantees exactly one home screen per workspace, so
        // a tree is stale unless it sits on its workspace's *current* home. this
        // catches two cases: (1) the home screen vanished (lid close / unplug),
        // and (2) the home moved to a different live screen after a reconnect —
        // e.g. ws1's home is the laptop when it's alone, but the leftmost
        // external once monitors return. case (2) leaves a tree behind on a
        // screen that still exists, so a plain "is the screen still here?" check
        // misses it and the window ends up duplicated across two trees, feeding
        // intendedTileRects a wrong-monitor rect and scrambling directional focus.
        for key in trees.keys {
            // scratchpad (ws 0) tree has no static home (homeScreenForWorkspace(0)
            // is nil) so it would land in orphans and get destroyed on every
            // display change / wake. leave it alone — the next show() reconciles
            // it (tileScratchpad clears any stale (0, deadScreen) tree).
            if key.workspace == Self.scratchpadWorkspace { continue }
            let dest = homeScreenForWorkspace(key.workspace)
            let homeID = dest.map { TilingKey(workspace: key.workspace, screen: $0).screenID }
            if homeID == key.screenID { continue }
            if let dest {
                migrations.append((key, dest))
            } else {
                orphans.append(key)
            }
        }

        for (oldKey, newScreen) in migrations {
            guard let tree = trees.removeValue(forKey: oldKey) else { continue }
            let newKey = TilingKey(workspace: oldKey.workspace, screen: newScreen)
            // the mark belongs to the tree, not to the coordinates. dropping
            // it on migration would let the same unverified windows start
            // advertising intended rects under the new key without a single
            // accepted layout.
            if let carried = unverified.removeValue(forKey: oldKey) {
                mark(newKey, windowIDs: carried.windowIDs, insertedIDs: carried.insertedIDs,
                     restored: carried.restorationVerifiedThroughout)
            }
            // a tree may already exist on the destination if the workspace had
            // been visited there before. keep the larger one and merge the
            // other's windows into it — dropping a tree wholesale orphaned its
            // windows into arbitrary-order reinsertion (wake scramble).
            if let existing = trees[newKey] {
                let (keep, donor) = existing.allWindows.count >= tree.allWindows.count
                    ? (existing, tree) : (tree, existing)
                let keepIDs = Set(keep.allWindows.map { $0.windowID })
                let rect = displayManager.cgRect(for: newScreen)
                var merged = 0
                for w in donor.allWindows where !keepIDs.contains(w.windowID) {
                    if smartInsertFitting(w, into: keep,
                                          maxDepth: maxDepth(for: newScreen), rect: rect) {
                        merged += 1
                    } else {
                        // depth or known-minimum refusal — the window keeps
                        // its workspace assignment, so the next tile pass
                        // re-inserts or auto-floats it instead of it silently
                        // vanishing.
                        hyprLog(.notice, .lifecycle, "display change: no room to merge '\(w.title ?? "?")' (\(w.windowID)) into ws\(oldKey.workspace) tree — deferring to next tile pass")
                    }
                }
                trees[newKey] = keep
                hyprLog(.notice, .lifecycle, "display change: ws\(oldKey.workspace) tree collision at sid=\(newKey.screenID) — kept \(keep.allWindows.count - merged)-window tree, merged \(merged) from the other")
                continue
            }
            trees[newKey] = tree
            hyprLog(.notice, .lifecycle, "display change: migrated ws\(oldKey.workspace) tree from sid=\(oldKey.screenID) to home (\(tree.allWindows.count) windows)")
        }

        for key in orphans {
            let count = trees[key]?.allWindows.count ?? 0
            trees.removeValue(forKey: key)
            hyprLog(.debug, .lifecycle, "display change: pruned orphaned tree for ws \(key.workspace) (\(count) windows)")
        }

        // a pruned key takes its mark with it. a migrated one already
        // moved its mark above.
        unverified = unverified.filter { trees[$0.key] != nil }
    }

    private var layoutEngine: LayoutEngine {
        LayoutEngine(gapSize: gapSize, outerPadding: outerPadding,
                     minSlotDimension: minSlotDimension)
    }

    private lazy var readbackPoller = FrameReadbackPoller(
        generation: { [weak self] in self?.layoutGeneration ?? UInt64.max },
        ioFactory: frameSizingIOFactory
    )

    /// `applyVerifiedLayout` plus the unverified-geometry bookkeeping for
    /// the key that owns the tree. Every production path goes through
    /// this; the plain call stays for tests that hand it a loose tree.
    private func applyTrackedLayout(_ tree: BSPTree, in rect: CGRect,
                                    generation: UInt64,
                                    key: TilingKey,
                                    inserted: [CGWindowID] = [],
                                    originalFrames: [CGWindowID: CGRect]? = nil,
                                    restorationUsableFrame: CGRect? = nil) -> LayoutApplicationOutcome {
        let outcome = applyVerifiedLayout(tree, in: rect, generation: generation,
                                          originalFrames: originalFrames,
                                          restorationUsableFrame: restorationUsableFrame)
        noteGeometry(outcome, for: key, generation: generation, inserted: inserted)
        return outcome
    }

    internal func applyVerifiedLayout(_ tree: BSPTree, in rect: CGRect,
                                      generation: UInt64,
                                      originalFrames suppliedOriginalFrames: [CGWindowID: CGRect]? = nil,
                                      restorationUsableFrame suppliedRestorationFrame: CGRect? = nil) -> LayoutApplicationOutcome {
        let outcome = applyVerifiedLayoutAttempt(tree, in: rect, generation: generation,
                                                  originalFrames: suppliedOriginalFrames,
                                                  restorationUsableFrame: suppliedRestorationFrame)
        switch outcome {
        case .accepted: break
        case let .rejectedRestored(reason, frames, progress):
            hyprLog(.notice, .tiling, "verified layout rejected and restored: reason=\(reason) actual=\(frames)"
                    + Self.overlapTrace(progress))
        case let .degraded(candidateReason, restorationReason, attempted, frames, progress):
            hyprLog(.notice, .tiling,
                    "verified layout degraded: candidate=\(candidateReason) restoration=\(String(describing: restorationReason)) attempted=\(attempted) actual=\(frames)"
                    + Self.overlapTrace(progress))
        }
        return outcome
    }

    private static func overlapTrace(_ progress: FrameSizingProgressReport) -> String {
        guard !progress.restorationOverlaps.isEmpty else { return "" }
        return " originalOverlap=" + progress.restorationOverlaps
            .map { "\($0.first)/\($0.second)" }.joined(separator: ",")
    }

    /// Whether a candidate may become the live tree.
    ///
    /// Only an accepted layout publishes. Acceptance is the one state that
    /// carries every condition at once: all three setters returned success
    /// for every target, the final readback was complete and stable, every
    /// window matched its target within the per-window tolerances, and the
    /// aggregate geometry passed `validateFrames`. Anything else — a
    /// partial write, an unreadable or unsettled readback, a cleanup error
    /// after clean-looking frames, a window that stopped 340 points short —
    /// keeps the prior membership and ratios and leaves the key unverified.
    /// The caller's `layoutGeneration == generation` check is the ownership
    /// half of the gate.
    ///
    /// A layout with no targets writes nothing and has nothing to verify.
    /// It publishes because that is how a workspace that lost its last
    /// window empties its tree, not because an empty set satisfied a test.
    private func publishes(_ outcome: LayoutApplicationOutcome) -> Bool {
        guard case let .accepted(_, progress) = outcome else { return false }
        return progress.candidateVerified
    }

    /// Record whether `key`'s geometry is still something the tree can
    /// speak for. An accepted layout clears the mark; anything else sets
    /// it, because the frames the tree describes were not the frames the
    /// screen ended up with. Superseded work touches nothing: a newer
    /// generation already owns the key.
    private func noteGeometry(_ outcome: LayoutApplicationOutcome, for key: TilingKey,
                              generation: UInt64, inserted: [CGWindowID]) {
        guard layoutGeneration == generation else { return }
        if publishes(outcome) {
            unverified.removeValue(forKey: key)
            return
        }
        var ids = Set(inserted)
        ids.formUnion(outcome.progress.candidate.targetIDs)
        var restored = false
        if case .rejectedRestored = outcome { restored = true }
        mark(key, windowIDs: ids, insertedIDs: Set(inserted), restored: restored)
    }

    /// Mark `key` unverified, folding this attempt's rollback into whatever
    /// earlier attempts on the same key already said. A single failed
    /// rollback anywhere in the run is enough: a restoration writes the
    /// frames it captured when it started, so once one of them leaves the
    /// incumbents somewhere unplanned, every later rollback faithfully
    /// restores that.
    private func mark(_ key: TilingKey, windowIDs: Set<CGWindowID>,
                      insertedIDs: Set<CGWindowID>, restored: Bool) {
        if var existing = unverified[key] {
            existing.windowIDs.formUnion(windowIDs)
            existing.insertedIDs.formUnion(insertedIDs)
            existing.restorationVerifiedThroughout = existing.restorationVerifiedThroughout && restored
            unverified[key] = existing
            return
        }
        unverified[key] = UnverifiedRecord(windowIDs: windowIDs, insertedIDs: insertedIDs,
                                           restorationVerifiedThroughout: restored)
    }

    /// Every `(workspace, screen)` whose geometry the engine cannot speak
    /// for, for the state dump and for step 4's bounded recovery.
    var unverifiedLayouts: [UnverifiedLayout] {
        unverified.keys.sorted { ($0.workspace, $0.screenID) < ($1.workspace, $1.screenID) }
            .map { key in
                let screen = displayManager.screens.first {
                    TilingKey(workspace: key.workspace, screen: $0) == key
                }
                let treeIDs = Set(trees[key]?.allWindows.map(\.windowID) ?? [])
                return UnverifiedLayout(workspace: key.workspace, screen: screen,
                                        windowIDs: (unverified[key]?.windowIDs ?? []).union(treeIDs),
                                        insertedIDs: unverified[key]?.insertedIDs ?? [])
            }
    }

    /// Every window living under an unverified key. The state dump's
    /// `unverified=` field.
    var unverifiedGeometryWindowIDs: Set<CGWindowID> {
        unverifiedLayouts.reduce(into: Set<CGWindowID>()) { $0.formUnion($1.windowIDs) }
    }

    /// Windows waiting on a bounded recovery attempt, or on the evidence
    /// that would let one finish. The records live in `AdmissionRecovery`,
    /// which is orchestration, not tree state; the engine only reads them
    /// so the state dump has one place to ask.
    var pendingRecoveryWindowIDs: Set<CGWindowID> { pendingRecoverySource() }

    /// Set by `WindowManager` to the admission recovery's pending set.
    var pendingRecoverySource: () -> Set<CGWindowID> = { [] }

    /// Mark `(workspace, screen)` unverified on somebody else's evidence.
    ///
    /// For the drift monitor, which watches a tiled window's app take its
    /// frame back after an accepted layout. The tree stopped describing the
    /// screen, and nothing here should pretend otherwise until a layout for
    /// the key is accepted again. No-op for a key with no tree.
    func markUnverifiedGeometry(forWorkspace workspace: Int, screen: NSScreen, reason: String) {
        let key = TilingKey(workspace: workspace, screen: screen)
        guard let tree = trees[key] else { return }
        mark(key, windowIDs: Set(tree.allWindows.map(\.windowID)), insertedIDs: [], restored: false)
        hyprLog(.notice, .tiling, "unverified mark set for ws\(workspace): \(reason)")
    }

    /// Drop the unverified mark for `(workspace, screen)` without laying
    /// anything out, if the incumbents are provably back where the tree
    /// says. For the admission recovery, which gives up on a key once it has
    /// floated the newcomer in place.
    ///
    /// The engine decides, not the caller: the mark belongs to the key and
    /// any number of attempts may have set it, so only the engine knows
    /// whether every one of them put its originals back. Ordinary clearing
    /// still happens on its own, when a layout for the key is accepted.
    ///
    /// - Returns: whether the mark was dropped.
    @discardableResult
    func clearUnverifiedGeometry(forWorkspace workspace: Int, screen: NSScreen) -> Bool {
        let key = TilingKey(workspace: workspace, screen: screen)
        guard let record = unverified[key] else { return true }
        guard record.restorationVerifiedThroughout else {
            hyprLog(.notice, .tiling, "unverified mark kept for ws\(workspace): a rollback did not verify")
            return false
        }
        unverified.removeValue(forKey: key)
        return true
    }

    private func applyVerifiedLayoutAttempt(_ tree: BSPTree, in rect: CGRect, generation: UInt64,
                                            originalFrames suppliedOriginalFrames: [CGWindowID: CGRect]?,
                                            restorationUsableFrame suppliedRestorationFrame: CGRect?) -> LayoutApplicationOutcome {
        let windows = tree.allWindows
        let restorationFrame = suppliedRestorationFrame ?? rect
        let originalFrames: [CGWindowID: CGRect]
        if let suppliedOriginalFrames {
            guard suppliedOriginalFrames.count == windows.count,
                  windows.allSatisfy({ suppliedOriginalFrames[$0.windowID] != nil }) else {
                let missing = windows.first { suppliedOriginalFrames[$0.windowID] == nil }
                return .degraded(candidateReason: .windowUnavailable(missing?.windowID ?? 0),
                                 restorationReason: nil, restorationAttempted: false,
                                 actualFrames: suppliedOriginalFrames,
                                 progress: FrameSizingProgressReport())
            }
            originalFrames = suppliedOriginalFrames
        } else {
            let captured = readbackPoller.captureFrames(windows, generation: generation)
            guard case .accepted = captured.verdict,
                  captured.actualFrames.count == windows.count else {
                let missing = windows.first { captured.actualFrames[$0.windowID] == nil }
                return .degraded(
                    candidateReason: captured.verdict.failure ?? .windowUnavailable(missing?.windowID ?? 0),
                    restorationReason: nil, restorationAttempted: false,
                    actualFrames: captured.actualFrames,
                    progress: FrameSizingProgressReport(candidate: captured.progress)
                )
            }
            originalFrames = captured.actualFrames
        }

        let candidate = tree.deepClone()
        let firstLayouts = candidate.layout(in: rect, gap: gapSize, padding: outerPadding)
        let first = applyLayout(firstLayouts, usableFrame: rect, generation: generation)
        if case .accepted = first.verdict {
            return .accepted(actualFrames: first.actualFrames,
                             progress: FrameSizingProgressReport(candidate: first.progress))
        }

        var terminal = first
        if case .rejected = first.verdict, !first.conflicts.isEmpty,
           layoutGeneration == generation {
            let conflicts = first.conflicts.map { (window: $0.window, actual: $0.actual) }
            candidate.adjustForMinSizes(conflicts, in: rect, gap: gapSize, padding: outerPadding)
            let adjusted = candidate.layout(in: rect, gap: gapSize, padding: outerPadding)
            let frames = Dictionary(uniqueKeysWithValues: adjusted.map { ($0.0.windowID, $0.1) })
            let tolerance = FrameSizingConfiguration().sizeOvershootTolerance
            let resolves = first.observations.allSatisfy { observation in
                guard let frame = frames[observation.window.windowID] else { return false }
                return (!observation.widthConflict || observation.actual.width <= frame.width + tolerance)
                    && (!observation.heightConflict || observation.actual.height <= frame.height + tolerance)
            }
            if resolves {
                terminal = applyLayoutFinal(adjusted, usableFrame: rect, generation: generation)
                if case .accepted = terminal.verdict {
                    copyVerifiedRatios(from: candidate.root, to: tree.root)
                    return .accepted(actualFrames: terminal.actualFrames,
                                     progress: FrameSizingProgressReport(candidate: terminal.progress))
                }
            } else {
                hyprLog(.notice, .tiling, "adjusted layout cannot resolve observed constraints — restoring")
            }
        }

        let candidateProgress = FrameSizingProgressReport(candidate: terminal.progress)
        guard layoutGeneration == generation else {
            return .degraded(candidateReason: .superseded, restorationReason: nil,
                             restorationAttempted: false,
                             actualFrames: terminal.actualFrames,
                             progress: candidateProgress)
        }
        let reason = terminal.verdict.failure ?? .attemptsExhausted
        if let invalidOriginalID = originalFrames.keys.sorted().first(where: { windowID in
            originalFrames[windowID].map { !restorationFrame.contains($0) } ?? true
        }) {
            // an original parked off the usable frame is not a restoration
            // target, so the candidate writes stay where they landed. the
            // tree keeps its prior ratios: nothing here was verified
            return .degraded(candidateReason: reason,
                             restorationReason: .outsideUsableFrame(invalidOriginalID),
                             restorationAttempted: false,
                             actualFrames: terminal.actualFrames,
                             progress: candidateProgress)
        }
        let originals = windows.compactMap { window in
            originalFrames[window.windowID].map { (window, $0) }
        }
        let restored = readbackPoller.applyRestoration(originals, usableFrame: restorationFrame,
                                                        gap: gapSize, generation: generation)
        var progress = candidateProgress
        progress.restoration = restored.progress
        progress.restorationOverlaps = restored.overlaps
        if case .accepted = restored.verdict {
            return .rejectedRestored(reason: reason, actualFrames: restored.actualFrames,
                                     progress: progress)
        }
        return .degraded(candidateReason: reason,
                         restorationReason: restored.verdict.failure,
                         restorationAttempted: true,
                         actualFrames: restored.actualFrames,
                         progress: progress)
    }

    private func copyVerifiedRatios(from source: BSPNode, to destination: BSPNode) {
        destination.splitRatio = source.splitRatio
        if let sourceLeft = source.left, let destinationLeft = destination.left {
            copyVerifiedRatios(from: sourceLeft, to: destinationLeft)
        }
        if let sourceRight = source.right, let destinationRight = destination.right {
            copyVerifiedRatios(from: sourceRight, to: destinationRight)
        }
    }

    // delegate to FrameReadbackPoller and reconcile its result against our
    // min-size memory. returns the conflicts the engine should pass into
    // BSPTree.adjustForMinSizes.
    private func applyLayout(_ layouts: [(HyprWindow, CGRect)], usableFrame: CGRect,
                             generation: UInt64) -> FrameReadbackPoller.Result {
        reconcile(readbackPoller.applyLayout(layouts, usableFrame: usableFrame,
                                             gap: gapSize, generation: generation),
                  generation: generation)
    }

    private func applyLayoutFinal(_ layouts: [(HyprWindow, CGRect)], usableFrame: CGRect,
                                  generation: UInt64) -> FrameReadbackPoller.Result {
        reconcile(readbackPoller.applyFinal(layouts, usableFrame: usableFrame,
                                            gap: gapSize, generation: generation),
                  generation: generation)
    }

    // both passes teach the same memory. the adjusted pass is where a
    // window that was given a bigger tile finally accepts a smaller frame
    // than the one it refused, and that accepted readback is the only
    // honest thing to lower the bound to.
    private func reconcile(_ result: FrameReadbackPoller.Result,
                           generation: UInt64) -> FrameReadbackPoller.Result {
        for obs in result.observations {
            // stamp only what was actually written, so a retry's bypass
            // cannot skip an older bound that this pass left alone
            if minSizes.recordObserved(obs.window, target: obs.target, actual: obs.actual,
                                       widthConflict: obs.widthConflict,
                                       heightConflict: obs.heightConflict,
                                       phase: result.progress.phase) {
                observedMinimumGeneration[obs.window.windowID] = generation
            }
        }
        for (window, size) in result.accepted {
            // a window whose app hint this pass set aside has now been
            // measured on its own, so its entry stops being somebody else's
            if minimaBypass?[window.windowID] != nil {
                minSizes.adoptOwnEvidence(window, accepted: size)
            }
            minSizes.lowerIfAccepted(window, actual: size)
        }
        return result
    }

    private func overflowingWindows(in layouts: [(HyprWindow, CGRect)]) -> [HyprWindow] {
        layouts.compactMap { window, frame in
            let minSize = minimumSize(for: window)
            if minSize.width > frame.width + TilingConfig.frameToleranceXPx || minSize.height > frame.height + TilingConfig.frameToleranceXPx {
                return window
            }
            return nil
        }
    }

    private func layoutCanAccommodateKnownMinimums(_ tree: BSPTree, rect: CGRect) -> Bool {
        let initial = tree.layout(in: rect, gap: gapSize, padding: outerPadding)
        let conflicts = initial.compactMap { window, frame -> (window: HyprWindow, actual: CGSize)? in
            let minSize = minimumSize(for: window)
            if minSize.width > frame.width + TilingConfig.frameToleranceXPx || minSize.height > frame.height + TilingConfig.frameToleranceXPx {
                return (window: window, actual: minSize)
            }
            return nil
        }

        guard !conflicts.isEmpty else { return true }

        tree.adjustForMinSizes(conflicts, in: rect, gap: gapSize, padding: outerPadding)
        let adjusted = tree.layout(in: rect, gap: gapSize, padding: outerPadding)
        return overflowingWindows(in: adjusted).isEmpty
    }

    private func autoFloatOverflow(_ overflow: [HyprWindow],
                                   inserted: [HyprWindow],
                                   tree: BSPTree,
                                   key: TilingKey,
                                   screen: NSScreen) -> Bool {
        // Tahoe: AX readback lags AX setattr, so "overflow" frequently
        // reports false positives. yabai's window_manager.c:732 documents
        // the same race ("frame cache is not reliable... causing layout to
        // not be modified the way we expect"). auto-floating from a stale
        // readback is exactly what's been making windows mysteriously float
        // and land at wrong sizes. accept the apparent overflow and let the
        // next AX-event-driven retile fix it if it's real.
        guard !overflow.isEmpty, !inserted.isEmpty else { return false }
        let overflowIDs = Set(overflow.map { $0.windowID })
        let target = inserted.reversed().first { overflowIDs.contains($0.windowID) }
            ?? inserted.last
        guard let target else { return false }

        hyprLog(.notice, .tiling, "overflow detected (NOT auto-floating, may be stale readback): '\(target.title ?? "?")' (\(target.windowID))")
        // no tree removal or routing from readback —
        // returning false lets the caller fall through to applyLayoutFinal.
        _ = tree; _ = key; _ = screen
        return false
    }

    private func rememberPendingInserted(_ windows: [HyprWindow], for key: TilingKey) {
        guard !windows.isEmpty else { return }
        pendingInsertedWindowIDs[key, default: []].append(contentsOf: windows.map(\.windowID))
    }

    private func consumePendingInserted(for key: TilingKey, in tree: BSPTree) -> [HyprWindow] {
        guard let ids = pendingInsertedWindowIDs.removeValue(forKey: key), !ids.isEmpty else { return [] }
        let windowsByID = Dictionary(uniqueKeysWithValues: tree.allWindows.map { ($0.windowID, $0) })
        return ids.compactMap { windowsByID[$0] }
    }

    private func mergedInserted(_ inserted: [HyprWindow], pending: [HyprWindow]) -> [HyprWindow] {
        var seen: Set<CGWindowID> = []
        var result: [HyprWindow] = []
        for window in inserted + pending where !seen.contains(window.windowID) {
            seen.insert(window.windowID)
            result.append(window)
        }
        return result
    }


    @discardableResult
    private func smartInsertFitting(_ window: HyprWindow, into tree: BSPTree,
                                    maxDepth: Int, rect: CGRect) -> Bool {
        layoutEngine.smartInsertFitting(window, into: tree, maxDepth: maxDepth,
                                        rect: rect, minimumSize: minimumSize(for:))
    }

    private func fittingLeaf(for window: HyprWindow?, in tree: BSPTree,
                             maxDepth: Int, rect: CGRect,
                             noting: ((LayoutEngine.SlotRefusal) -> Void)? = nil) -> BSPNode? {
        layoutEngine.fittingLeaf(for: window, in: tree, maxDepth: maxDepth,
                                 rect: rect, minimumSize: minimumSize(for:), noting: noting)
    }

    private struct TileMembershipResult {
        let key: TilingKey
        let tree: BSPTree
        let rect: CGRect
        let insertedWindows: [HyprWindow]
        /// newcomers a bypassed pass refused outright, so nothing routed them.
        var refusedWindows: [HyprWindow] = []
    }

    // shared tree-update path between tileWindows and prepareTileLayout.
    // primes min-sizes, removes gone windows (sibling promotion keeps the
    // tree shape), smart-inserts new windows in a stable order
    // (auto-floating those that don't fit), and resets split ratios.
    // pure with respect to AX — only mutates the tree and engine state.
    private func updateTreeMembership(_ windows: [HyprWindow],
                                      onWorkspace workspace: Int,
                                      screen: NSScreen, candidate: BSPTree? = nil) -> TileMembershipResult {
        primeMinimumSizes(windows)
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = candidate ?? tree(for: key)
        let rect = displayManager.cgRect(for: screen)

        let tileWindows = windows.filter { !$0.isFloating }
        let treeWindows = t.allWindows
        let currentIDs = Set(tileWindows.map { $0.windowID })
        let treeIDs = Set(treeWindows.map { $0.windowID })

        for w in treeWindows where !currentIDs.contains(w.windowID) { t.remove(w) }

        t.root.pruneEmptyNodes()
        // no compact on removal — BSPNode.remove promotes the sibling with
        // ratios/overrides intact. compacting here rebuilt the whole tree,
        // reshuffling unrelated windows every time anything closed or hid.

        // reset before insert decisions: fittingLeaf judges candidate rects
        // with live ratios, and a stale pass-2 adjustment (0.85/0.15) from a
        // previous cycle would skew which leaf accepts the window.
        t.root.resetSplitRatios()

        // deterministic batch order: left-to-right by current frame, id
        // tiebreak. AX enumeration order shifts with focus/z churn, which
        // made multi-window inserts land differently every time.
        var toInsert = tileWindows.filter { !treeIDs.contains($0.windowID) }
        if toInsert.count > 1 {
            let frames = Dictionary(uniqueKeysWithValues: toInsert.map { ($0.windowID, $0.frame ?? .zero) })
            toInsert.sort { a, b in
                let aIncumbent = admittedWindowIDs[workspace]?.contains(a.windowID) ?? false
                let bIncumbent = admittedWindowIDs[workspace]?.contains(b.windowID) ?? false
                if aIncumbent != bIncumbent { return aIncumbent }
                let fa = frames[a.windowID] ?? .zero
                let fb = frames[b.windowID] ?? .zero
                if fa.origin.x != fb.origin.x { return fa.origin.x < fb.origin.x }
                if fa.origin.y != fb.origin.y { return fa.origin.y < fb.origin.y }
                return a.windowID < b.windowID
            }
        }

        var insertedWindows: [HyprWindow] = []
        var refusedWindows: [HyprWindow] = []
        for w in toInsert {
            let insert = {
                self.smartInsertFitting(w, into: t, maxDepth: self.maxDepth(for: screen), rect: rect)
            }
            // an unrelated newcomer must not inherit another request's bypass.
            let fits = minimaBypass?[w.windowID] == nil ? withoutMinimaBypass(insert) : insert()
            if fits {
                insertedWindows.append(w)
            } else {
                refusedWindows.append(w)
                hyprLog(.notice, .tiling, "no fitting tile slot: wid=\(w.windowID) ws\(workspace) — staying in place")
            }
        }

        if !insertedWindows.isEmpty {
            t.root.clearUserSetRatios()
            t.root.resetSplitRatios()
        }
        t.root.applySavedRatios()

        return TileMembershipResult(key: key, tree: t, rect: rect,
                                    insertedWindows: insertedWindows,
                                    refusedWindows: refusedWindows)
    }

    /// Tile `windows` for `(workspace, screen)`.
    ///
    /// `screen` is supplied explicitly because window positions can be
    /// the hide-corner sliver — physical position is not trustworthy
    /// during a workspace switch. Two-pass: pass 1 lays out and reads
    /// back actual frames; pass 2 (when conflicts are detected)
    /// adjusts split ratios via `MinSizeMemory` and re-applies. If
    /// the adjusted pass fails, restoration is verified and the prior
    /// topology remains live. Only an accepted layout publishes its
    /// membership and ratios; every other outcome keeps the prior tree and
    /// leaves the key's geometry marked unverified.
    ///
    /// The result names the windows this pass inserted and the ones the live
    /// tree ended up holding, so the caller can tell which newcomers were
    /// stranded without reading the failure's window id.
    @discardableResult
    func tileWindows(_ windows: [HyprWindow], onWorkspace workspace: Int, screen: NSScreen,
                     alsoRestoringWithin extraReach: CGRect? = nil) -> AdmissionResult {
        let generation = beginLayoutGeneration()
        pendingSwapRevert = nil
        let live = trees[TilingKey(workspace: workspace, screen: screen)]
        let candidate = live?.deepClone() ?? BSPTree()
        let incumbents = admittedWindowIDs[workspace, default: []]
        let m = updateTreeMembership(windows, onWorkspace: workspace, screen: screen, candidate: candidate)
        let key = m.key
        let t = m.tree
        let rect = m.rect

        let refusedIncumbents = Set(m.refusedWindows.map(\.windowID)).intersection(incumbents)
        if let id = refusedIncumbents.min(), layoutGeneration == generation {
            // publishing only the subset would hide an incumbent from geometry tracking.
            let ids = Set(windows.filter { !$0.isFloating }.map(\.windowID))
            let inserted = Set(m.insertedWindows.map(\.windowID)).subtracting(incumbents)
            mark(key, windowIDs: ids, insertedIDs: inserted, restored: false)
            return admissionResult(.degraded(candidateReason: .noFittingSlot(id),
                                              restorationReason: nil, restorationAttempted: false,
                                              actualFrames: [:], progress: FrameSizingProgressReport()),
                                   workspace: workspace, screen: screen, key: key,
                                   generation: generation, inserted: inserted,
                                   refused: Set(m.refusedWindows.map(\.windowID)).subtracting(incumbents))
        }
        _ = consumePendingInserted(for: key, in: t)
        let outcome = applyTrackedLayout(t, in: rect, generation: generation, key: key,
                                         inserted: m.insertedWindows.map(\.windowID).filter { !incumbents.contains($0) },
                                         restorationUsableFrame: extraReach.map { rect.union($0) })
        if publishes(outcome), layoutGeneration == generation {
            if let live { live.root = candidate.root } else { trees[key] = candidate }
            admittedWindowIDs[workspace, default: []].formUnion(candidate.allWindows.map(\.windowID))
        }

        // clean up empty trees for this workspace on other screens
        for (key, t) in trees where key.workspace == workspace {
            if !t.allWindows.isEmpty { continue }
            if TilingKey(workspace: workspace, screen: screen) != key {
                trees.removeValue(forKey: key)
                unverified.removeValue(forKey: key)
            }
        }

        return admissionResult(outcome, workspace: workspace, screen: screen, key: key,
                               generation: generation,
                               inserted: Set(m.insertedWindows.map(\.windowID)).subtracting(incumbents),
                               refused: Set(m.refusedWindows.map(\.windowID)).subtracting(incumbents))
    }

    /// Build the typed admission result from what the live tree holds now.
    ///
    /// `publishedIDs` is read back off the tree rather than assumed from the
    /// outcome, so a superseded pass that published nothing reports the
    /// membership that actually survived.
    private func admissionResult(_ outcome: LayoutApplicationOutcome,
                                 workspace: Int, screen: NSScreen, key: TilingKey,
                                 generation: UInt64,
                                 inserted: Set<CGWindowID>,
                                 refused: Set<CGWindowID>) -> AdmissionResult {
        let published = Set(trees[key]?.allWindows.map(\.windowID) ?? [])
        var failure: FrameSizingFailure?
        var restored: Set<CGWindowID> = []
        switch outcome {
        case .accepted:
            break
        case let .rejectedRestored(reason, _, progress):
            failure = reason
            restored = Set(progress.restoration?.targetIDs ?? [])
        case let .degraded(candidateReason, _, _, _, _):
            failure = candidateReason
        }
        return AdmissionResult(workspace: workspace, screen: screen, generation: generation,
                               insertedIDs: inserted, publishedIDs: published,
                               failure: failure, restoredIDs: restored, refusedIDs: refused)
    }

    /// One more admission attempt for `(workspace, screen)`, ignoring for
    /// each id in `bypass` the minima observed before its own generation.
    ///
    /// Everything else is an ordinary tiling pass: fresh generation, private
    /// candidate, same publication gate. Nothing is erased from
    /// `MinSizeMemory` — the bypass lasts exactly as long as this call.
    ///
    /// `refusingImpossibleArrangements` is the bounded recovery's retry. It
    /// asks the structural fit check first, with every tenant's known floor
    /// in hand, and refuses without a single setter when the arrangement
    /// cannot exist. The retry has no reason to probe: every bound it is
    /// honouring came from a guarded readback of the admission it is
    /// retrying, so writing the same frames again would only repeat the
    /// resize the user just watched. An explicit revalidation does not set
    /// it — the user asking by hand is asking for a real attempt.
    @discardableResult
    func retryAdmission(_ windows: [HyprWindow], onWorkspace workspace: Int, screen: NSScreen,
                        bypassingMinimaBefore bypass: [CGWindowID: UInt64],
                        refusingImpossibleArrangements: Bool = false,
                        restorationReach: CGRect? = nil) -> AdmissionResult {
        let previous = minimaBypass
        minimaBypass = bypass
        defer { minimaBypass = previous }
        if refusingImpossibleArrangements {
            // only the newcomers this retry is for, against the live tree's
            // incumbents. a held window or a second stranded newcomer beside
            // them is not part of the arrangement being judged — the
            // ordinary pass would simply leave it out.
            let key = TilingKey(workspace: workspace, screen: screen)
            let published = Set(trees[key]?.allWindows.map(\.windowID) ?? [])
            let judged = windows.filter {
                !$0.isFloating && (published.contains($0.windowID) || bypass[$0.windowID] != nil)
            }
            if !fitWindows(judged, onWorkspace: workspace, screen: screen) {
                return structuralRefusal(Set(bypass.keys), workspace: workspace, screen: screen)
            }
        }
        return tileWindows(windows, onWorkspace: workspace, screen: screen,
                           alsoRestoringWithin: restorationReach)
    }

    /// The result of a retry that never ran: the known minima cannot be
    /// arranged in the usable frame, so nothing was written and the live
    /// tree is exactly as the admission left it.
    private func structuralRefusal(_ newcomers: Set<CGWindowID>,
                                   workspace: Int, screen: NSScreen) -> AdmissionResult {
        let key = TilingKey(workspace: workspace, screen: screen)
        let published = Set(trees[key]?.allWindows.map(\.windowID) ?? [])
        let refused = newcomers.subtracting(published)
        hyprLog(.notice, .tiling, "admission retry refused pre-write: ids="
                + "[" + refused.sorted().map(String.init).joined(separator: ", ") + "]"
                + " ws\(workspace) — the known minima do not fit the usable frame")
        return AdmissionResult(workspace: workspace, screen: screen,
                               generation: layoutGeneration,
                               insertedIDs: [], publishedIDs: published,
                               failure: refused.min().map { FrameSizingFailure.noFittingSlot($0) },
                               restoredIDs: [], refusedIDs: refused)
    }

    /// Tile scratchpad members into a caller-supplied `rect` on the layer's
    /// `screen`, keyed on `TilingKey(workspace: 0, screen)`.
    ///
    /// Unlike `tileWindows`, the layout rect is passed in (the inset region
    /// inside the layer's monitor) rather than derived from
    /// `displayManager.cgRect(for:)`. Same membership-diff + two-pass min-size
    /// resolution otherwise. Windows that can't be smart-inserted (tree full at
    /// max depth) are returned as rejects — the caller keeps them floating.
    /// Returns scratchpad rejects to its own controller: routing a reject
    /// through the overflow-adopt path would loop back into the scratchpad.
    /// - Returns: the windows that didn't fit (stay floating members).
    @discardableResult
    func tileScratchpad(_ windows: [HyprWindow], screen: NSScreen, in rect: CGRect) -> [HyprWindow] {
        let generation = beginLayoutGeneration()
        pendingSwapRevert = nil
        primeMinimumSizes(windows)
        let key = TilingKey(workspace: Self.scratchpadWorkspace, screen: screen)
        let live = trees[key]
        let t = live?.deepClone() ?? BSPTree()

        let currentIDs = Set(windows.map { $0.windowID })
        let treeWindows = t.allWindows
        let treeIDs = Set(treeWindows.map { $0.windowID })

        // membership diff: remove gone (sibling promotion keeps shape), insert new
        for w in treeWindows where !currentIDs.contains(w.windowID) { t.remove(w) }
        t.root.pruneEmptyNodes()
        t.root.resetSplitRatios()

        var rejects: [HyprWindow] = []
        for w in windows where !treeIDs.contains(w.windowID) {
            if !smartInsertFitting(w, into: t, maxDepth: maxDepth(for: screen), rect: rect) {
                hyprLog(.notice, .tiling, "scratchpad tile: no fitting slot for '\(w.title ?? "?")' (\(w.windowID)) — stays floating")
                rejects.append(w)
            }
        }

        t.root.resetSplitRatios()
        t.root.applySavedRatios()

        let outcome = applyTrackedLayout(t, in: rect, generation: generation, key: key,
                                         restorationUsableFrame: displayManager.cgRect(for: screen))
        if publishes(outcome), layoutGeneration == generation {
            if let live { live.root = t.root } else { trees[key] = t }
            // discard the old monitor's tree only once the destination holds
            // the candidate frames
            for other in trees.keys where other.workspace == Self.scratchpadWorkspace && other != key {
                trees.removeValue(forKey: other)
                unverified.removeValue(forKey: other)
            }
        }
        return rejects
    }

    /// Intended layout rects for the scratchpad layer's ws-0 tree, laid out in
    /// the caller's `rect` (the inset region) rather than the full screen.
    /// `intendedTileRects` derives its rect from `displayManager.cgRect(for:)`,
    /// so it's wrong for the layer — this is the layer-region equivalent the
    /// controller reads into `lastShownFrames`.
    func scratchpadTileRects(screen: NSScreen, in rect: CGRect) -> [CGWindowID: CGRect] {
        let key = TilingKey(workspace: Self.scratchpadWorkspace, screen: screen)
        guard let t = trees[key] else { return [:] }
        var out: [CGWindowID: CGRect] = [:]
        for (window, frame) in t.layout(in: rect, gap: gapSize, padding: outerPadding) {
            out[window.windowID] = frame
        }
        return out
    }

    /// Mutate the (workspace, screen) tree to reflect `windows` and return
    /// the resulting per-window layout rects WITHOUT applying frames.
    ///
    /// - Important: This call **mutates the tree** before returning — windows
    ///   missing from the input are removed (with `compact`), new windows are
    ///   added via `smartInsertFitting`, structural-change ratio flags are
    ///   cleared, and `resetSplitRatios` is run. The caller is committed to
    ///   either applying the returned layout (via `applyComputedLayout`) or
    ///   accepting that the tree is now in its post-tile state regardless of
    ///   what the caller does with the returned rects. This is intentional —
    ///   animation paths need post-mutation geometry to interpolate toward.
    /// - Returns: `[(window, frame)]` pairs in tree iteration order. Empty
    ///   array if the tree ends up empty.
    func prepareTileLayout(_ windows: [HyprWindow], onWorkspace workspace: Int, screen: NSScreen) -> [(HyprWindow, CGRect)] {
        _ = beginLayoutGeneration()
        pendingSwapRevert = nil
        let m = updateTreeMembership(windows, onWorkspace: workspace, screen: screen)
        rememberPendingInserted(m.insertedWindows, for: m.key)
        return m.tree.layout(in: m.rect, gap: gapSize, padding: outerPadding)
    }

    /// BSP-computed intended rect for every tiled window across all
    /// `(workspace, screen)` trees, keyed by window ID. This is the layout
    /// the engine *wants* — distinct from the live AX frame, which can be
    /// inflated when an app refuses to shrink to its slot. Use in geometric
    /// pickers (directional focus/swap) so a crammed window doesn't push
    /// its inflated edges past a neighbor's far edge and exclude that
    /// neighbor from the candidate set.
    func intendedTileRects() -> [CGWindowID: CGRect] {
        var out: [CGWindowID: CGRect] = [:]
        // diag: track which (ws, screen) tree last wrote each windowID so a
        // window living in two trees (stale dup) is loud. see directional-focus bug.
        var sourceTree: [CGWindowID: String] = [:]
        for (key, t) in trees {
            // a key whose last attempt was not accepted has no rect to
            // offer. omitting it sends every one of its windows down the
            // caller's actual-frame fallback, together rather than one at
            // a time, which is the only consistent thing to do when the
            // tree and the screen disagree.
            if unverified[key] != nil {
                hyprLog(.debug, .tiling, "intendedRects: tree ws\(key.workspace) sid=\(key.screenID) unverified — omitted (\(t.allWindows.count) windows)")
                continue
            }
            guard let screen = displayManager.screens.first(where: {
                TilingKey(workspace: key.workspace, screen: $0) == key
            }) else {
                hyprLog(.notice, .tiling, "intendedRects: tree ws\(key.workspace) sid=\(key.screenID) matches NO current screen — skipped (\(t.allWindows.count) windows)")
                continue
            }
            let rect = displayManager.cgRect(for: screen)
            hyprLog(.debug, .tiling, "intendedRects: tree ws\(key.workspace) sid=\(key.screenID) -> '\(screen.localizedName)' rect=\(rect) (\(t.allWindows.count) windows)")
            for (window, frame) in t.layout(in: rect, gap: gapSize, padding: outerPadding) {
                let tag = "ws\(key.workspace)@\(screen.localizedName)"
                if let prev = sourceTree[window.windowID] {
                    hyprLog(.notice, .tiling, "intendedRects: DUP windowID \(window.windowID) '\(window.title ?? "?")' in both [\(prev)] and [\(tag)] — \(tag) wins rect=\(frame)")
                }
                sourceTree[window.windowID] = tag
                out[window.windowID] = frame
            }
        }
        return out
    }

    /// Add a single window to the `(workspace, screen)` tree and
    /// retile. Returns a refusal when smart insert cannot
    /// place the window without violating `minSlotDimension`. No-op
    /// for floating windows, which report `nil` because no admission ran.
    @discardableResult
    func addWindow(_ window: HyprWindow, toWorkspace workspace: Int, on screen: NSScreen) -> AdmissionResult? {
        guard !window.isFloating else { return nil }
        let current = trees[TilingKey(workspace: workspace, screen: screen)]?.allWindows ?? []
        let windows = current.contains(where: { $0.windowID == window.windowID }) ? current : current + [window]
        return tileWindows(windows, onWorkspace: workspace, screen: screen)
    }

    /// Remove `window` from its workspace's tree on whichever screen
    /// holds it. Prunes the tree (sibling promotion preserves the
    /// surviving arrangement), then retiles the affected screen.
    func removeWindow(_ window: HyprWindow, fromWorkspace workspace: Int) {
        admittedWindowIDs[workspace]?.remove(window.windowID)
        // search all trees for this workspace
        for (key, t) in trees where key.workspace == workspace {
            if t.contains(window) {
                let generation = invalidatePendingLayout()
                t.remove(window)
                t.root.pruneEmptyNodes()
                if let screen = displayManager.screens.first(where: {
                    TilingKey(workspace: workspace, screen: $0) == key
                }) {
                    _ = retile(key: key, screen: screen, generation: generation)
                }
                return
            }
        }
    }

    private func retile(key: TilingKey, screen: NSScreen,
                        inserted: [HyprWindow] = [],
                        generation suppliedGeneration: UInt64? = nil) -> LayoutApplicationOutcome {
        let t = tree(for: key)
        primeMinimumSizes(t.allWindows)
        let rect = displayManager.cgRect(for: screen)
        _ = mergedInserted(inserted, pending: consumePendingInserted(for: key, in: t))
        let generation = suppliedGeneration ?? beginLayoutGeneration()

        t.root.resetSplitRatios()

        return applyTrackedLayout(t, in: rect, generation: generation, key: key,
                                  inserted: inserted.map(\.windowID))
    }

    /// Apply a manual resize: update the surrounding split ratios so
    /// `window`'s new frame is preserved, then retile.
    func applyResize(_ window: HyprWindow, newFrame: CGRect, onWorkspace workspace: Int, screen: NSScreen) {
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        let rect = displayManager.cgRect(for: screen)

        let snapshot = t.snapshot()
        let generation = invalidatePendingLayout()
        t.applyResizeDelta(for: window, newFrame: newFrame, in: rect, gap: gapSize, padding: outerPadding)
        let outcome = retile(key: key, screen: screen, generation: generation)
        if case .accepted = outcome { return }
        if layoutGeneration == generation { t.restore(snapshot) }
    }

    /// `true` when `a` and `b` can be swapped without violating any
    /// recorded min-size constraint.
    ///
    /// Snapshots the tree, performs a trial swap with cleared
    /// user-resize ratios, and asks `LayoutEngine` whether the result
    /// fits every window's currently-known minimum. Restores the
    /// original tree before returning regardless of outcome. Primes
    /// `MinSizeMemory` for every window in the tree first — siblings'
    /// min sizes still influence the post-swap fit decision.
    private enum SwapFit {
        case fits
        case revalidatable([CGWindowID: UInt64])
        case refused
    }

    private func swapFit(_ a: HyprWindow, _ b: HyprWindow,
                         onWorkspace workspace: Int, screen: NSScreen) -> SwapFit {
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        // prime ALL tree windows, not just [a, b]. siblings still influence
        // whether adjustForMinSizes can resolve conflicts post-swap; if their
        // min sizes are stale or missing in the memory, the fit check produces
        // inconsistent rejections (e.g., a swap that should reject when a
        // sibling has a hard minimum sneaks through because its min wasn't
        // re-synced).
        primeMinimumSizes(t.allWindows)
        guard t.contains(a) && t.contains(b) else { return .refused }

        let snapshot = t.snapshot()
        defer { t.restore(snapshot) }

        let rect = displayManager.cgRect(for: screen)
        func trial() -> Bool {
            t.restore(snapshot)
            t.swap(a, b)
            // clear userSetRatio + reset to 50/50 for the test layout. matches
            // what the actual swap does below, so preflight and the
            // post-acceptance retile evaluate against the same baseline.
            t.root.clearUserSetRatios()
            t.root.resetSplitRatios()
            return layoutCanAccommodateKnownMinimums(t, rect: rect)
        }
        if trial() { return .fits }

        let bypass = revalidationBypass(incoming: [a.windowID, b.windowID], key: key)
        return withMinimaBypass(bypass, trial) ? .revalidatable(bypass) : .refused
    }

    func canSwapWindows(_ a: HyprWindow, _ b: HyprWindow,
                        onWorkspace workspace: Int, screen: NSScreen) -> Bool {
        if case .refused = swapFit(a, b, onWorkspace: workspace, screen: screen) {
            return false
        }
        return true
    }

    /// Synchronous swap path (no animation).
    ///
    /// Snapshots the tree before swapping so a post-readback overflow
    /// — which `canSwapWindows`' seeded mins can miss when an app's
    /// real minimum depends on UI state — can be reverted. Returns
    /// `true` on success, `false` when the swap was rejected up front
    /// or reverted after readback.
    @discardableResult
    func swapWindows(_ a: HyprWindow, _ b: HyprWindow, onWorkspace workspace: Int, screen: NSScreen) -> Bool {
        let fit = swapFit(a, b, onWorkspace: workspace, screen: screen)
        if case .refused = fit { return false }
        return performSwap(a, b, fit: fit, onWorkspace: workspace, screen: screen)
    }

    private func performSwap(_ a: HyprWindow, _ b: HyprWindow, fit: SwapFit,
                             onWorkspace workspace: Int, screen: NSScreen) -> Bool {
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)

        // canSwapWindows uses the recorded min sizes which can be seeded
        // (AX-static) rather than confirmed via readback. for windows like
        // Spotify whose actual min depends on current UI state, the seeded
        // values can be too small — canSwapWindows accepts, but the real
        // pass-1 readback after the swap reveals overflow. snapshot the
        // tree first so we can revert on that case.
        let snapshot = t.snapshot()
        t.swap(a, b)
        // see canSwapWindows — swap is a structural change, prior manual
        // ratios applied to the OLD occupant of a slot, not the new one.
        t.root.clearUserSetRatios()
        let rect = displayManager.cgRect(for: screen)
        let generation = beginLayoutGeneration()
        let apply = { self.applyTrackedLayout(t, in: rect, generation: generation, key: key) }
        let outcome: LayoutApplicationOutcome
        switch fit {
        case .fits:
            outcome = apply()
        case let .revalidatable(bypass):
            outcome = withMinimaBypass(bypass, apply)
        case .refused:
            return false
        }
        switch outcome {
        case .accepted:
            return true
        case .rejectedRestored, .degraded:
            guard layoutGeneration == generation else { return false }
            hyprLog(.debug, .lifecycle, "swap frame application failed — restoring tree")
            t.restore(snapshot)
            return false
        }
    }

    /// Pending pre-mutation snapshot for animated swap and split-toggle paths.
    /// Consumed (or cleared) by `applyComputedLayout`.
    /// Defensively cleared by `prepareToggleSplitLayout` to prevent leakage
    /// across consecutive prepare-then-apply cycles when the user triggers
    /// a non-swap action between the two halves.
    private var pendingSwapRevert: (key: TilingKey, generation: UInt64,
                                    snapshot: BSPTree.Snapshot,
                                    originalFrames: [CGWindowID: CGRect],
                                    minimaBypass: [CGWindowID: UInt64]?)?

    /// Swap two windows' positions in the tree and return post-swap layout
    /// rects without applying frames.
    ///
    /// - Important: **Mutates the tree** before returning — `BSPTree.swap`
    ///   exchanges leaf window references and `resetSplitRatios` runs. If the
    ///   caller does nothing with the returned layout, the tree is still in
    ///   its post-swap state. Captures a pre-swap snapshot for revert; the
    ///   matching `applyComputedLayout` call consumes it.
    /// - Returns: `nil` if either window is missing or the swap cannot fit
    ///   even after learned evidence is set aside; otherwise the new layout.
    func prepareSwapLayout(_ a: HyprWindow, _ b: HyprWindow,
                           onWorkspace workspace: Int, screen: NSScreen) -> [(HyprWindow, CGRect)]? {
        let fit = swapFit(a, b, onWorkspace: workspace, screen: screen)
        if case .refused = fit { return nil }
        return prepareSwap(a, b, fit: fit, onWorkspace: workspace, screen: screen)
    }

    private func prepareSwap(_ a: HyprWindow, _ b: HyprWindow, fit: SwapFit,
                             onWorkspace workspace: Int,
                             screen: NSScreen) -> [(HyprWindow, CGRect)]? {
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        guard t.contains(a) && t.contains(b) else { return nil }
        let rect = displayManager.cgRect(for: screen)

        let generation = beginLayoutGeneration()
        let captured = readbackPoller.captureFrames(t.allWindows, generation: generation)
        guard case .accepted = captured.verdict,
              captured.actualFrames.count == t.allWindows.count else { return nil }

        // capture snapshot for post-readback overflow revert (animated swap
        // path). canSwapWindows uses the recorded min size which can be
        // seeded rather than confirmed via readback — for windows like
        // Spotify whose actual min depends on UI state, the seed lies and
        // canSwapWindows false-accepts. The real readback during retile
        // (triggered by applyComputedLayout) is the ground truth, and
        // applyComputedLayout reverts via this snapshot if overflow persists.
        pendingSwapRevert = (key: key, generation: generation,
                             snapshot: t.snapshot(), originalFrames: captured.actualFrames,
                             minimaBypass: {
                                 if case let .revalidatable(bypass) = fit { return bypass }
                                 return nil
                             }())
        t.swap(a, b)
        // clear userSetRatio + reset to 50/50 so the test layout matches
        // canSwapWindows's evaluation baseline (see canSwapWindows).
        t.root.clearUserSetRatios()
        t.root.resetSplitRatios()
        return t.layout(in: rect, gap: gapSize, padding: outerPadding)
    }

    /// Re-apply the current tree state to AX frames using the two-pass
    /// min-size resolution. Pairs with `prepare*Layout`: caller mutates the
    /// tree (via prepare), drives an animation against the returned rects,
    /// then calls `applyComputedLayout` on completion to settle frames.
    ///
    /// Prepared mutations capture their pre-animation topology and frames.
    /// A rejected or unknown final application restores that state and returns
    /// `false` so the caller can report failure.
    @discardableResult
    func applyComputedLayout(onWorkspace workspace: Int, screen: NSScreen) -> Bool {
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        guard let pending = pendingSwapRevert, pending.key == key else {
            let outcome = retile(key: key, screen: screen)
            if case .accepted = outcome { return true }
            return false
        }
        pendingSwapRevert = nil

        guard layoutGeneration == pending.generation else { return false }
        let rect = displayManager.cgRect(for: screen)
        let apply = {
            self.applyTrackedLayout(t, in: rect, generation: pending.generation, key: key,
                                    originalFrames: pending.originalFrames)
        }
        let outcome = pending.minimaBypass.map { withMinimaBypass($0, apply) } ?? apply()
        switch outcome {
        case .accepted:
            return true
        case .rejectedRestored, .degraded:
            guard layoutGeneration == pending.generation else { return false }
            hyprLog(.debug, .lifecycle, "prepared frame application failed — restoring tree")
            t.restore(pending.snapshot)
            return false
        }
    }

    /// Synchronous split-direction toggle for `window`'s parent
    /// node. Animation-free path; the dispatcher's animated path goes
    /// through `prepareToggleSplitLayout` instead.
    func toggleSplit(_ window: HyprWindow, onWorkspace workspace: Int, screen: NSScreen) {
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        let rect = displayManager.cgRect(for: screen)
        let snapshot = t.snapshot()
        let generation = invalidatePendingLayout()
        t.toggleSplit(for: window, in: rect, gap: gapSize, padding: outerPadding)
        let outcome = retile(key: key, screen: screen, generation: generation)
        if case .accepted = outcome { return }
        if layoutGeneration == generation { t.restore(snapshot) }
    }

    /// Resize the focused window by moving the nearest matching-axis split
    /// boundary in `direction`. Walks from the leaf upward to find the first
    /// ancestor whose split direction matches the resize axis, then shifts
    /// its `splitRatio` by `resizeStep` toward the arrow. Flags the ancestor
    /// `userSetRatio = true` so the adjustment survives retiles.
    func resizeInDirection(_ window: HyprWindow, direction: Direction,
                           onWorkspace workspace: Int, screen: NSScreen) {
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        let rect = displayManager.cgRect(for: screen)

        guard let leaf = t.root.find(window) else { return }
        let snapshot = t.snapshot()
        let generation = invalidatePendingLayout()

        let axis: SplitDirection = (direction == .left || direction == .right) ? .horizontal : .vertical
        let positive = (direction == .right || direction == .down)

        var node = leaf
        var didResize = false
        while let parent = node.parent {
            guard let parentRect = t.rectForNode(parent, in: rect, gap: gapSize, padding: outerPadding) else {
                node = parent
                continue
            }
            guard parent.direction(for: parentRect) == axis else {
                node = parent
                continue
            }

            // move the split boundary in the arrow direction. ratio is the
            // left/top fraction, so right/down = +, left/up = -. position
            // independent: the focused window's edge on that axis follows
            // the arrow, growing or shrinking as geometry allows.
            let delta: CGFloat = positive ? TilingConfig.resizeStep : -TilingConfig.resizeStep
            let newRatio = min(max(parent.splitRatio + delta, TilingConfig.minRatio), TilingConfig.maxRatio)
            guard newRatio != parent.splitRatio else { break }
            parent.splitRatio = newRatio
            parent.userSetRatio = true
            didResize = true
            hyprLog(.debug, .tiling, "resizeDirection \(direction): ratio → \(String(format: "%.2f", newRatio))")
            break
        }

        if didResize {
            let outcome = retile(key: key, screen: screen, generation: generation)
            if case .accepted = outcome { return }
            if layoutGeneration == generation { t.restore(snapshot) }
        }
    }

    /// Toggle the split direction of `window`'s parent and return post-toggle
    /// layout rects without applying frames.
    ///
    /// - Important: **Mutates the tree** before returning. `splitOverride`
    ///   flips on the parent and `resetSplitRatios` runs. Calling this twice
    ///   in succession reverts the toggle — that footgun is exactly what the
    ///   `WindowManager.toggleSplit()` fallthrough fix prevents (see plan
    ///   §4.2 + commit ee9e2df).
    /// - Returns: `nil` if `window` isn't in the tree (no toggle performed);
    ///   otherwise the post-toggle layout.
    func prepareToggleSplitLayout(_ window: HyprWindow,
                                  onWorkspace workspace: Int, screen: NSScreen) -> [(HyprWindow, CGRect)]? {
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        guard t.contains(window) else { return nil }
        let generation = invalidatePendingLayout()
        let captured = readbackPoller.captureFrames(t.allWindows, generation: generation)
        guard case .accepted = captured.verdict,
              captured.actualFrames.count == t.allWindows.count else { return nil }
        pendingSwapRevert = (key: key, generation: generation,
                             snapshot: t.snapshot(), originalFrames: captured.actualFrames,
                             minimaBypass: nil)
        let rect = displayManager.cgRect(for: screen)
        t.toggleSplit(for: window, in: rect, gap: gapSize, padding: outerPadding)
        t.root.resetSplitRatios()
        return t.layout(in: rect, gap: gapSize, padding: outerPadding)
    }

    /// What an explicit user request should expect from `(workspace, screen)`.
    ///
    /// Runs the ordinary fit check first. If it refuses, runs it again with
    /// every learned bound for the incoming window *and* the destination's
    /// tenants set aside, on the same tree and under the same structural
    /// rules. A refusal the second check does not repeat was a refusal by
    /// memory alone, and one attempt would say whether that memory is still
    /// true. A refusal it does repeat is real, and the facts reported are the
    /// ones that survived the bypass.
    ///
    /// No AX write and no layout happen here, and the bypass lasts exactly as
    /// long as the second check. Two things are not read-only, both inherited
    /// from the fit check this replaces: priming can pick up a window's
    /// `AXMinimumSize` as a new `seeded` entry, and asking about a workspace
    /// that has no tree yet creates an empty one. Neither touches an
    /// `observed` bound, which is what a revalidation is about.
    func admissionOutlook(_ window: HyprWindow, onWorkspace workspace: Int,
                          screen: NSScreen) -> AdmissionOutlook {
        let key = TilingKey(workspace: workspace, screen: screen)
        let t = tree(for: key)
        if t.root.isEmpty {
            logOutlook([], incoming: window.windowID, workspace: workspace, verdict: "fits")
            return .fits
        }
        var toPrime = t.allWindows
        toPrime.append(window)
        primeMinimumSizes(toPrime)
        let rect = displayManager.cgRect(for: screen)
        let depth = maxDepth(for: screen)

        var honoured: [FitRefusal] = []
        if fittingLeaf(for: window, in: t, maxDepth: depth, rect: rect,
                       noting: { honoured.append(self.refusal($0, incoming: window)) }) != nil {
            logOutlook([], incoming: window.windowID, workspace: workspace, verdict: "fits")
            return .fits
        }

        var bypassed: [FitRefusal] = []
        let found: BSPNode? = withRevalidationBypass(incoming: [window.windowID], key: key) {
            fittingLeaf(for: window, in: t, maxDepth: depth, rect: rect,
                        noting: { bypassed.append(self.refusal($0, incoming: window)) })
        }
        if found != nil {
            logOutlook(honoured, incoming: window.windowID, workspace: workspace, verdict: "revalidatable")
            return .revalidatable(honoured)
        }
        logOutlook(bypassed, incoming: window.windowID, workspace: workspace, verdict: "refused")
        return .refused(bypassed)
    }

    /// Attach provenance to one slot's geometric refusal.
    ///
    /// The memory is read directly, never through the bypass: a bound that is
    /// being ignored for the duration of a check is still the reason the
    /// first check said no. A minimum of zero on the refusing side
    /// contributes nothing, so a slot too small for the gap alone reads as
    /// structural rather than blaming a bound that is not there.
    ///
    /// A nonzero bound with no entry behind it came from the window's own
    /// `AXMinimumSize` mirror, which the memory reads when it holds nothing.
    /// Priming refused that value — at or above `usableMinSizeMaxPx`, or not
    /// finite — and kept no entry for it, but the fit check still honoured
    /// it. It is a hint nothing has tested, so it reads as seeded; calling it
    /// structural would hide an app-declared minimum behind the geometry.
    private func refusal(_ slot: LayoutEngine.SlotRefusal, incoming: HyprWindow) -> FitRefusal {
        var source = FitRefusal.Source.structural
        if !slot.depthExhausted {
            var provenances: [MinSizeProvenance] = []
            if slot.incomingMinimum != .zero {
                provenances.append(minSizes.entry(for: incoming.windowID)?.provenance ?? .seeded)
            }
            if slot.tenantMinimum != .zero, let tenant = slot.tenantID {
                provenances.append(minSizes.entry(for: tenant)?.provenance ?? .seeded)
            }
            if provenances.contains(.observed) {
                source = .learned
            } else if provenances.contains(.appHint) {
                source = .appHint
            } else if provenances.contains(.seeded) {
                source = .seeded
            }
        }
        return FitRefusal(incoming: incoming.windowID, tenant: slot.tenantID, slot: slot.slot,
                          incomingMinimum: slot.incomingMinimum, tenantMinimum: slot.tenantMinimum,
                          axis: slot.axis, source: source)
    }

    private func logOutlook(_ refusals: [FitRefusal], incoming: CGWindowID,
                            workspace: Int, verdict: String) {
        for r in refusals {
            hyprLog(.notice, .tiling, "fit refusal: incoming=\(r.incoming) ws\(workspace)"
                    + " tenant=\(r.tenant.map(String.init) ?? "none") slot=\(Self.sizeText(r.slot))"
                    + " needIncoming=\(Self.sizeText(r.incomingMinimum))"
                    + " needTenant=\(Self.sizeText(r.tenantMinimum))"
                    + " axis=\(r.axis) source=\(r.source.rawValue)")
        }
        hyprLog(.notice, .tiling, "fit outlook: incoming=\(incoming) ws\(workspace)"
                + " verdict=\(verdict) refusals=\(refusals.count)")
    }

    private static func sizeText(_ size: CGSize) -> String {
        String(format: "%gx%g", Double(size.width), Double(size.height))
    }

    /// Run `body` with every observed bound ignored for `incoming` and for
    /// whoever currently holds `key`'s tree.
    ///
    /// Widening it to the incumbents is the point: the bound that refuses an
    /// incoming window is usually the tenant's, not its own — Safari 21611
    /// refused while 26016 was the window trying to get in. The map is
    /// rebuilt per call and dropped on the way out, so nothing outlives the
    /// one check or the one attempt it wraps.
    private func withRevalidationBypass<T>(incoming: Set<CGWindowID>, key: TilingKey,
                                           _ body: () -> T) -> T {
        withMinimaBypass(revalidationBypass(incoming: incoming, key: key), body)
    }

    private func withMinimaBypass<T>(_ bypass: [CGWindowID: UInt64],
                                     _ body: () -> T) -> T {
        let previous = minimaBypass
        minimaBypass = bypass
        defer { minimaBypass = previous }
        return body()
    }

    /// Run `body` with no bypass at all, whatever pass it is nested in. For
    /// the decisions that belong to some other window than the one being
    /// revalidated.
    private func withoutMinimaBypass<T>(_ body: () -> T) -> T {
        let previous = minimaBypass
        minimaBypass = nil
        defer { minimaBypass = previous }
        return body()
    }

    private func revalidationBypass(incoming: Set<CGWindowID>, key: TilingKey) -> [CGWindowID: UInt64] {
        var bypass: [CGWindowID: UInt64] = [:]
        for id in incoming { bypass[id] = Self.revalidationBypassBefore }
        for window in trees[key]?.allWindows ?? [] {
            bypass[window.windowID] = Self.revalidationBypassBefore
        }
        return bypass
    }

    /// One explicit-request admission attempt for `(workspace, screen)` with
    /// every learned bound for `incoming` and for the destination's tenants
    /// set aside.
    ///
    /// Otherwise an ordinary tiling pass: fresh generation, private
    /// candidate, same publication gate, same reconcile path. An accepted
    /// layout lowers the bounds it disproved; a refused one publishes nothing
    /// and changes the memory only through the guarded learning path — a
    /// window that really refused its slot under the readback guards raises
    /// its own entry, which is fresh evidence rather than the bound this pass
    /// set aside. Nothing here clears an entry.
    ///
    /// `restorationReach` widens the rect a rollback is allowed to write
    /// into. A window being moved from another screen is still standing on
    /// that screen when the attempt captures it, and a captured original
    /// outside the restoration rect cancels the whole rollback — every
    /// incumbent would be left on the failed candidate's frames and the
    /// newcomer stranded on a screen it does not belong to. Pass the screen
    /// the newcomer is coming from and the rollback can reach both.
    @discardableResult
    func revalidateAdmission(_ windows: [HyprWindow], incoming: Set<CGWindowID>,
                             onWorkspace workspace: Int, screen: NSScreen,
                             restorationReach: CGRect? = nil) -> AdmissionResult {
        let key = TilingKey(workspace: workspace, screen: screen)
        let bypass = revalidationBypass(incoming: incoming, key: key)
        hyprLog(.notice, .tiling, "minima revalidation attempt: ws\(workspace)"
                + " incoming=[\(incoming.sorted().map(String.init).joined(separator: ", "))]"
                + " bypassing=[\(bypass.keys.sorted().map(String.init).joined(separator: ", "))]")
        return retryAdmission(windows, onWorkspace: workspace, screen: screen,
                              bypassingMinimaBefore: bypass,
                              restorationReach: restorationReach)
    }

    /// A capacity probe other subsystems run for their own reasons — the
    /// workspace fit checks. It answers on the
    /// memory as it stands, never on a bypass belonging to whatever pass it
    /// was called from.
    func canFitWindows(_ windows: [HyprWindow], onWorkspace workspace: Int, screen: NSScreen) -> Bool {
        withoutMinimaBypass { fitWindows(windows, onWorkspace: workspace, screen: screen) }
    }

    private func fitWindows(_ windows: [HyprWindow], onWorkspace workspace: Int, screen: NSScreen) -> Bool {
        let ids = Set(windows.map(\.windowID))
        guard ids.count == windows.count else { return false }
        let key = TilingKey(workspace: workspace, screen: screen)
        let candidate = trees[key]?.deepClone() ?? BSPTree()
        for window in candidate.allWindows where !ids.contains(window.windowID) { candidate.remove(window) }
        candidate.root.pruneEmptyNodes()
        candidate.root.resetSplitRatios()
        primeMinimumSizes(windows)
        let rect = displayManager.cgRect(for: screen)
        for window in windows where !candidate.contains(window) {
            guard smartInsertFitting(window, into: candidate, maxDepth: maxDepth(for: screen), rect: rect) else { return false }
        }
        return true
    }

    /// Insert `window` into an available slot without replacing an incumbent.
    ///
    /// Used by float→tile toggles when the user explicitly wants
    /// `window` tiled even though smart insert would otherwise reject
    /// for capacity.
    ///
    /// Everything happens on a private candidate, so a refusal — no leaf
    /// takes the window, or the screen will not accept the layout — leaves
    /// the live tree exactly as it was. `.failed` is an explicit refusal the
    /// caller reports while keeping the incoming window floating.
    ///
    /// `bypassingLearnedMinima` is the explicit-revalidation pass: the user
    /// asked a second time after a refusal that only learned bounds produced,
    /// so this one attempt ignores the observed bounds of the window and of
    /// the tenants already in the tree. Structure is untouched — the same
    /// depth, the same slot geometry, no eviction, and the same
    /// publication gate decide it.
    func forceInsertWindow(_ window: HyprWindow, toWorkspace workspace: Int, on screen: NSScreen,
                           bypassingLearnedMinima: Bool = false) -> ForceInsertResult {
        let key = TilingKey(workspace: workspace, screen: screen)
        guard !bypassingLearnedMinima else {
            return withRevalidationBypass(incoming: [window.windowID], key: key) {
                forceInsertWindow(window, toWorkspace: workspace, on: screen)
            }
        }
        primeMinimumSizes([window])
        let live = trees[key]
        let rect = displayManager.cgRect(for: screen)

        if live?.contains(window) == true { return .alreadyPresent }
        let candidate = live?.deepClone() ?? BSPTree()

        guard smartInsertFitting(window, into: candidate, maxDepth: maxDepth(for: screen), rect: rect) else {
            return .failed(.noFittingSlot)
        }

        // only now: a refusal above applies nothing, and cancelling an
        // in-flight layout for a pass that never ran is a layout lost for
        // nothing
        let generation = invalidatePendingLayout()
        _ = consumePendingInserted(for: key, in: candidate)
        return commitForceInsert(candidate, live: live, key: key, rect: rect,
                                 window: window, generation: generation, success: .inserted)
    }

    private func commitForceInsert(_ candidate: BSPTree, live: BSPTree?, key: TilingKey,
                                   rect: CGRect, window: HyprWindow, generation: UInt64,
                                   success: ForceInsertResult) -> ForceInsertResult {
        primeMinimumSizes(candidate.allWindows)
        candidate.root.resetSplitRatios()
        let outcome = applyTrackedLayout(candidate, in: rect, generation: generation, key: key,
                                         inserted: [window.windowID])
        guard publishes(outcome), layoutGeneration == generation else {
            let reason: FrameSizingFailure
            switch outcome {
            case .accepted: reason = .superseded
            case let .rejectedRestored(r, _, _): reason = r
            case let .degraded(r, _, _, _, _): reason = r
            }
            hyprLog(.notice, .tiling, "force insert refused for \(window.windowID): \(reason)")
            return .failed(.layoutRejected(reason))
        }
        if let live { live.root = candidate.root } else { trees[key] = candidate }
        admittedWindowIDs[key.workspace, default: []].formUnion(candidate.allWindows.map(\.windowID))
        return success
    }
}

extension TilingEngine.LayoutApplicationOutcome {
    /// What the attempts behind this outcome are known to have done.
    var progress: FrameSizingProgressReport {
        switch self {
        case let .accepted(_, progress): return progress
        case let .rejectedRestored(_, _, progress): return progress
        case let .degraded(_, _, _, _, progress): return progress
        }
    }
}

private extension FrameSizingAttempt.Verdict {
    var failure: FrameSizingFailure? {
        switch self {
        case .accepted: nil
        case .rejected(let reason), .unknown(let reason): reason
        }
    }
}
