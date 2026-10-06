import Foundation

/// One owner for opening, following and explicit returns. Native tail visibility
/// decides arrival; geometry only coalesces requests when the layout changes.
nonisolated struct TimelineScrollState: Equatable {
    enum Phase { case idle, tracking, interacting, decelerating, animating }
    enum Mode { case reading, following, returning }

    struct BottomRequest: Equatable {
        let generation: Int
        let contentHeight: CGFloat
        let visibleHeight: CGFloat
    }
    struct BottomCommand: Equatable {
        let id: Int
        let request: BottomRequest
        /// The opening return lands without an animation so a cached window
        /// never plays a visible top-to-bottom scroll. Every later return
        /// (sending, accepted responses, the bottom pill) keeps the spring.
        let instant: Bool
    }

    private(set) var phase = Phase.idle
    private(set) var mode = Mode.reading
    private(set) var viewport = TimelineViewport()
    private(set) var tail = TimelineTailVisibility()
    private(set) var navigationGeneration = 0
    private(set) var interactionIsPresented = false
    private(set) var navigationIsSuspended = false
    private(set) var hasOpened = false
    private(set) var activeCommand: BottomCommand?
    private var lastRequest: BottomRequest?
    private var commandID = 0
    private var awaitsUserScrollSettlement = false
    /// Set by `open()`, consumed by the first command it produces. A reader
    /// gesture before that command clears it, so later returns animate.
    private var openingReturnIsPending = false
    /// R2 backstop: the publish-point reconcile asks at most once per
    /// displacement episode. The latch re-arms only when a published sample
    /// measurably reaches the bottom, so a failed native target cannot turn
    /// the recheck into a layout loop.
    private var bottomReconcileIsSpent = false

    /// The marker probes lie — round 1.3's device probe read "at bottom"
    /// from the tail flag while the measured gap sat hundreds of points
    /// short, and the follow chain (gated on that flag) never started. The
    /// at-bottom truth is measured directly from the last published
    /// viewport: `visibleBottom` reaches `contentHeight` exactly when the
    /// scroll rests at its maximum offset, so the gap is the real remaining
    /// travel. The probes stay only as the fallback before the first
    /// measurement.
    var viewportIsAtBottom: Bool {
        guard viewport.isMeasured else { return tail.isAtBottom }
        return viewport.measuredAtBottom
    }

    var userIsScrolling: Bool { [.tracking, .interacting, .decelerating].contains(phase) }
    var returningToBottom: Bool { mode == .returning }
    var needsUserScrollSettlement: Bool {
        awaitsUserScrollSettlement && phase == .idle && tail.isMeasured && !navigationIsSuspended
    }

    mutating func open(interactionPresented: Bool = false) {
        guard !hasOpened else { return }
        hasOpened = true
        interactionIsPresented = interactionPresented
        openingReturnIsPending = true
        requestBottom()
    }

    mutating func requestBottom() {
        mode = .returning
        awaitsUserScrollSettlement = false
        invalidateNavigation()
    }

    mutating func browseHistory() {
        mode = .reading
        awaitsUserScrollSettlement = false
        // The reader took over before the opening return was issued; a later
        // explicit return is a normal animated one.
        openingReturnIsPending = false
        invalidateNavigation()
    }

    mutating func setInteractionPresented(_ presented: Bool) {
        guard interactionIsPresented != presented else { return }
        interactionIsPresented = presented
        if presented { browseHistory() }
        else { requestBottom() }
    }

    mutating func setNavigationSuspended(_ suspended: Bool) {
        guard navigationIsSuspended != suspended else { return }
        navigationIsSuspended = suspended
        // Preserve reading/history intent. A hidden or moving drawer cannot
        // retain a native edge target or acknowledge an interrupted animation.
        activeCommand = nil
        lastRequest = nil
    }

    mutating func geometryChanged(_ next: TimelineViewport) {
        viewport = next
        // A measurable arrival ends the displacement episode; the next one
        // may be reconciled again.
        if next.measuredAtBottom { bottomReconcileIsSpent = false }
    }

    mutating func tailVisibilityChanged(_ region: TimelineTailVisibility.Region, visible: Bool) {
        tail.update(region, visible: visible)
    }

    /// Phase and visibility callbacks can arrive in either order. Keep a manual
    /// drag in reading mode until both have settled, so a stale visible marker
    /// cannot grant auto-follow and pull the reader back down.
    @discardableResult mutating func phaseChanged(_ next: Phase, viewport: TimelineViewport) -> Bool {
        self.viewport = viewport
        guard !navigationIsSuspended else { return false }
        let beganGesture = next == .tracking && phase != .tracking
            || next == .interacting && phase != .tracking && phase != .interacting
        if beganGesture {
            browseHistory()
            awaitsUserScrollSettlement = true
        }
        phase = next
        return beganGesture
    }

    mutating func settleUserScroll() {
        guard needsUserScrollSettlement, !returningToBottom else { return }
        awaitsUserScrollSettlement = false
        // A stale visible marker must not grant auto-follow and pull the
        // reader back down; the arrival is measured, not probed (round 1.3).
        mode = viewportIsAtBottom && !interactionIsPresented ? .following : .reading
    }

    var pendingBottomRequest: BottomRequest? {
        guard hasOpened, !navigationIsSuspended, viewport.isMeasured,
              returningToBottom || tail.isMeasured,
              mode != .reading, !userIsScrolling || returningToBottom,
              !interactionIsPresented || returningToBottom else { return nil }
        // A return is issued once even for short content. Subsequent layout
        // changes only need correction when they actually move away from
        // bottom — judged by the measured gap (round 1.3): the stale marker
        // flag would suppress the follow while the page sat hundreds of
        // points short, leaving it parked away from the bottom for good.
        if viewportIsAtBottom && (mode == .following || lastRequest != nil) { return nil }
        let request = BottomRequest(generation: navigationGeneration,
            contentHeight: viewport.contentHeight.rounded(), visibleHeight: viewport.visibleHeight.rounded())
        // The value dedup only holds while the scroll measurably rests at
        // the bottom: a layout that returns to an already-claimed request
        // after an intermediate move (the confirm replace's round trip) is
        // a new displacement, not a processed one — value equality alone
        // would park the page short for good.
        return request == lastRequest && viewport.measuredAtBottom ? nil : request
    }

    /// R2 backstop: the bounded authoritative re-ask the view runs at its
    /// publish point after a sample lands. Both request gates above judge by
    /// the measured gap, but a displacement can still leave nothing to
    /// restart the coalescer: the tail probes may never have measured (the
    /// request guard keeps waiting for them), or the layout can round-trip
    /// to the already-claimed request so its value never changes again (the
    /// confirm replace). When the state is measurably short at rest in
    /// following mode, ask once — a fresh generation restarts the return
    /// chain from scratch. Bounded by construction: the spent latch stops
    /// repeats until the geometry measurably reaches the bottom, an
    /// in-flight command or a reader gesture suppresses the ask entirely,
    /// and a fresh request (one that differs from the last begun return)
    /// stays out of its way — that one is already traveling through the
    /// 24 ms coalescing task.
    @discardableResult
    mutating func reconcileToBottom() -> Bool {
        guard hasOpened, !navigationIsSuspended, viewport.isMeasured,
              mode == .following, !userIsScrolling, activeCommand == nil,
              !viewport.measuredAtBottom, !bottomReconcileIsSpent else { return false }
        guard pendingBottomRequest == nil || pendingBottomRequest == lastRequest else { return false }
        bottomReconcileIsSpent = true
        requestBottom()
        return true
    }

    mutating func begin(_ request: BottomRequest) -> BottomCommand? {
        guard pendingBottomRequest == request else { return nil }
        commandID &+= 1
        let command = BottomCommand(id: commandID, request: request, instant: openingReturnIsPending)
        openingReturnIsPending = false
        lastRequest = request
        activeCommand = command
        return command
    }

    /// Only the latest animation can release ScrollPosition. A new gesture,
    /// approval or drawer transition invalidates an old completion immediately.
    mutating func complete(_ command: BottomCommand) -> Bool {
        guard activeCommand == command else { return false }
        activeCommand = nil
        if returningToBottom { mode = interactionIsPresented ? .reading : .following }
        return true
    }

    func showsBottomButton() -> Bool {
        hasOpened && !navigationIsSuspended && phase == .idle && tail.isMeasured
            && !tail.isNearBottom && activeCommand == nil && pendingBottomRequest == nil
    }

    private mutating func invalidateNavigation() {
        navigationGeneration &+= 1
        lastRequest = nil
        activeCommand = nil
    }
}

/// Two probes overlap the existing tail spacer. The larger region provides the
/// return pill's 96-point margin; only the end marker grants automatic following.
nonisolated struct TimelineTailVisibility: Equatable {
    enum Region { case near, end }
    private var near: Bool?
    private var end: Bool?
    var isMeasured: Bool { near != nil && end != nil }
    var isAtBottom: Bool { end == true }
    var isNearBottom: Bool { isAtBottom || near != false }

    mutating func update(_ region: Region, visible: Bool) {
        switch region {
        case .near: near = visible
        case .end: end = visible
        }
    }
}
