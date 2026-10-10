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
    /// Whether the reader's own gesture stopped at the bottom, taken from the
    /// `.idle` phase callback — the one verdict their finger left behind. The
    /// page's own layout can displace the published viewport afterwards (a tap
    /// inside the settlement task's 64 ms grows the composer and shortens the
    /// visible height), and that displacement must not turn an arrived reader
    /// into a parked one. Settling ORs it with the freshest measurement, so a
    /// late-reported arrival still counts.
    private var readerSettledAtBottom = false
    /// Whether the reader came to rest at the bottom — geometry alone, no
    /// settlement, no probes, no mode. Their own gesture clears it (the
    /// position is theirs until they rest again), and a rest at the bottom sets
    /// it; a displacement the page causes itself, with no gesture behind it,
    /// neither sets nor clears. The keyboard hold reads this instead of
    /// `mode`, whose settlement has to clear a phase callback, a 64 ms task and
    /// the marker probes first — machinery a hold on the bottom does not need.
    private(set) var readerRestsAtBottom = false
    /// Set by `open()`, consumed by the first command it produces. A reader
    /// gesture before that command clears it, so later returns animate.
    private var openingReturnIsPending = false
    /// The opening visit's claim on the viewport. It ends only when the reader
    /// takes over (a drag, or an explicit history request): a window change
    /// landing later must never move a reader who has chosen a position — but
    /// it must still re-assert the opening for everyone else.
    private(set) var readerTookOver = false
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

    /// B11: whether the reader is parked mid-history — they have taken over
    /// the viewport and are resting away from the bottom, outside the top's
    /// older-pull region. A backfill prepend in this state has no anchor
    /// machinery to absorb it (the page is not following, and the opening's
    /// claim is released), so it would jump the reader once per page; the
    /// automatic fill holds its merges while this is true. Reaching the
    /// bottom (mode `.following`) or the top's older-pull region — where
    /// older rows are exactly what the reader is there for — clears it.
    func backfillReaderIsParked(atOlderPrompt: Bool) -> Bool {
        guard readerTookOver, mode != .following else { return false }
        return !atOlderPrompt
    }
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

    /// - Parameter byReader: true for the reader's own gestures and explicit
    ///   history requests — the first one ends the opening visit's claim on
    ///   the viewport. A presented interaction is not the reader: it stops
    ///   automatic following without giving up the opening's positioning
    ///   (the notice's card lives at the tail, where the opening return
    ///   lands), so `reassertOpeningReturn` still owns that case.
    mutating func browseHistory(byReader: Bool = false) {
        if byReader { readerTookOver = true }
        mode = .reading
        awaitsUserScrollSettlement = false
        // The reader took over before the opening return was issued; a later
        // explicit return is a normal animated one.
        openingReturnIsPending = false
        invalidateNavigation()
    }

    /// Re-arms the opening's instant return for a wholesale window change
    /// (the opening's trim/latest-page surgery, a recovery or snapshot
    /// replacement, or a backfill prepend) that landed after the opening
    /// return settled or timed out. The timeline's own anchors cover the
    /// opening (`top` for the initial offset and alignment) and container
    /// size changes (`bottom` — the keyboard and the growing composer); a
    /// replacement is neither, so its content change has no anchor of its
    /// own and can land with the reader parked away from the newest rows —
    /// blank/short list until a manual scroll (2026-10-08,
    /// sess_ps8Z29uknMTIhw). The re-assert reuses the opening's own pipeline
    /// (`requestBottom` → the 24 ms coalescer → an instant
    /// `position.scrollTo(edge: .bottom)`), so it is motionless behind the
    /// opening gate and deterministic: it does not depend on the follow
    /// gates, whose reading/interaction/at-bottom judgements can all be
    /// closed at the landing instant.
    ///
    /// Only the opening visit owns this: an unopened page refuses (there is
    /// no opening to re-assert), a suspended drawer refuses (the native
    /// target would be applied mid-transition), and the first reader gesture
    /// or explicit history request releases the claim for good.
    @discardableResult
    mutating func reassertOpeningReturn() -> Bool {
        guard hasOpened, !navigationIsSuspended, !readerTookOver else { return false }
        openingReturnIsPending = true
        requestBottom()
        return true
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
        if next.measuredAtBottom {
            bottomReconcileIsSpent = false
            if !userIsScrolling { readerRestsAtBottom = true }
        }
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
            browseHistory(byReader: true)
            awaitsUserScrollSettlement = true
            readerRestsAtBottom = false
        }
        phase = next
        if next == .idle, awaitsUserScrollSettlement { readerSettledAtBottom = viewportIsAtBottom }
        if next == .idle, viewportIsAtBottom { readerRestsAtBottom = true }
        return beganGesture
    }

    mutating func settleUserScroll() {
        guard needsUserScrollSettlement, !returningToBottom else { return }
        awaitsUserScrollSettlement = false
        // A stale visible marker must not grant auto-follow and pull the
        // reader back down; the arrival is measured, not probed (round 1.3).
        // Measured twice, either one an arrival: the freshest sample can carry
        // a late-reported arrival, and the stop itself is the only verdict our
        // own later layout cannot displace.
        mode = (readerSettledAtBottom || viewportIsAtBottom) && !interactionIsPresented
            ? .following : .reading
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
    ///
    /// The judgement reads the freshest delivered sample (`sample`) — not
    /// the last *published* viewport — while the stored `viewport` and the
    /// request construction stay untouched, so the S2 publication gating
    /// still stands. The sample box is the one place a burst's dropped
    /// intermediate frame survives (the same main-queue turn delivers only
    /// the last one); the confirm replace's clamp rides exactly such a
    /// frame, and the stale "at bottom" viewport would refuse the request
    /// gate and this backstop at once, parking the page until the next
    /// content change. `nil` judges by the stored viewport, as before.
    @discardableResult
    mutating func reconcileToBottom(using sample: TimelineViewport? = nil) -> Bool {
        guard needsBottomReconcile(using: sample) else { return false }
        bottomReconcileIsSpent = true
        requestBottom()
        return true
    }

    /// The pure twin of `reconcileToBottom(using:)`'s guards, so the view can
    /// ask "would the mutating ask fire?" for every delivered sample without
    /// writing `@State` on the ones that do not need it (S2: sampling stays
    /// per-frame in the non-invalidating box; publishing re-evaluates the
    /// page body). The mutating method stays the authority; both share this
    /// one guard list by construction.
    func needsBottomReconcile(using sample: TimelineViewport? = nil) -> Bool {
        let truth = sample ?? viewport
        guard hasOpened, !navigationIsSuspended, truth.isMeasured,
              mode == .following, !userIsScrolling, activeCommand == nil,
              !truth.measuredAtBottom, !bottomReconcileIsSpent else { return false }
        return pendingBottomRequest == nil || pendingBottomRequest == lastRequest
    }

    /// The pure gate for the spent latch's re-arm from a delivered sample.
    /// `geometryChanged` re-arms it for published samples; a delivered
    /// sample the publication gate filtered (an offset-only arrival frame)
    /// carries the same at-bottom truth, and in the worst modelled world —
    /// coalesced bursts, no phase echo — it is the only channel that ever
    /// reports arrival. The episode ends on the same judgement either way;
    /// asking first keeps the armed state free per frame (S2), and the
    /// write fires once per spent episode. A failed native target still
    /// never produces an at-bottom sample, so the bound stands.
    func needsBottomReconcileRearm(using sample: TimelineViewport) -> Bool {
        bottomReconcileIsSpent && sample.measuredAtBottom
    }

    mutating func rearmBottomReconcile(using sample: TimelineViewport) {
        guard sample.measuredAtBottom else { return }
        bottomReconcileIsSpent = false
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

    /// The return pill is the reader's way back — and its only escape hatch
    /// when a native return failed to move the page. It stays hidden while a
    /// return is on its way, but a request that merely *lingers* (equal to
    /// the last begun return: the coalescer consumed it and the id never
    /// changes again, so nothing will re-begin it) must not hide the pill
    /// for good. The failed-native-target world parks exactly such an inert
    /// request; hiding on it unconditionally turned the pill into a
    /// permanently invisible affordance there.
    func showsBottomButton() -> Bool {
        hasOpened && !navigationIsSuspended && phase == .idle && tail.isMeasured
            && !tail.isNearBottom && activeCommand == nil
            && (pendingBottomRequest == nil || pendingBottomRequest == lastRequest)
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
