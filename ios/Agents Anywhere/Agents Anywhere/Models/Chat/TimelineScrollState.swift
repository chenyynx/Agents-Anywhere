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
        /// K5: the return the keyboard transition window holds and pins the
        /// bottom for (round 1.2) — the flag is what identifies it. The
        /// instant opening return still wins when both flags are set.
        let keyboardMatched: Bool
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
    /// K5: while the keyboard's transition window is open, its animation owns
    /// programmatic scrolling. The tail probe flipping under the shrinking
    /// container must not start the spring next to it (F11).
    private(set) var keyboardTransitionActive = false
    private var lastRequest: BottomRequest?
    private var commandID = 0
    private var awaitsUserScrollSettlement = false
    /// Set by `open()`, consumed by the first command it produces. A reader
    /// gesture before that command clears it, so later returns animate.
    private var openingReturnIsPending = false
    /// K5 (round 1.2): a held matched return means the keyboard began driving
    /// the layout while the page was glued to the bottom. The container then
    /// changes per frame, and only a per-frame offset update can track it —
    /// a one-shot scroll (however well timed) cannot ride a moving container,
    /// which is why the follow never landed. While this is true the view pins
    /// the scroll to the current bottom on every geometry sample, unanimated.
    var keyboardReturnPinsToBottom: Bool { activeCommand?.keyboardMatched == true }

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

    /// K5: opens or closes the keyboard transition window. Closing it is what
    /// releases a withheld return, so the make-up lands once the keyboard has
    /// settled.
    mutating func setKeyboardTransitionActive(_ active: Bool) {
        keyboardTransitionActive = active
    }

    mutating func geometryChanged(_ next: TimelineViewport) { viewport = next }

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
        mode = tail.isAtBottom && !interactionIsPresented ? .following : .reading
    }

    var pendingBottomRequest: BottomRequest? {
        // K5: withheld while the keyboard's transition window is open; the
        // transition-end recheck releases it.
        guard !keyboardTransitionActive else { return nil }
        return ungatedBottomRequest
    }

    private var ungatedBottomRequest: BottomRequest? {
        guard hasOpened, !navigationIsSuspended, viewport.isMeasured,
              returningToBottom || tail.isMeasured,
              mode != .reading, !userIsScrolling || returningToBottom,
              !interactionIsPresented || returningToBottom else { return nil }
        // A return is issued once even for short content. Subsequent layout
        // changes only need correction when they actually move away from bottom.
        if tail.isAtBottom && (mode == .following || lastRequest != nil) { return nil }
        let request = BottomRequest(generation: navigationGeneration,
            contentHeight: viewport.contentHeight.rounded(), visibleHeight: viewport.visibleHeight.rounded())
        return request == lastRequest ? nil : request
    }

    mutating func begin(_ request: BottomRequest) -> BottomCommand? {
        guard pendingBottomRequest == request else { return nil }
        return activate(request, keyboardMatched: false)
    }

    /// K5: the one return begun in the keyboard notification's own runloop
    /// turn, matched to the keyboard's animation. Beginning it directly also
    /// skips the layout-coalescing task (that delay merges layout, it does not
    /// wait for the keyboard), and marking the request stops the tail probe's
    /// flip inside the same transition from queuing a second animation. No
    /// scroll is issued here (round 1.2): while this command is held, the view
    /// pins the bottom on every geometry sample (`keyboardReturnPinsToBottom`),
    /// so the content tracks the per-frame container by construction.
    mutating func beginKeyboardReturn() -> BottomCommand? {
        requestBottom()
        // Deliberately ungated: this command is the one the transition window
        // exists to protect, and the window may already be open around it.
        guard let request = ungatedBottomRequest else { return nil }
        return activate(request, keyboardMatched: true)
    }

    private mutating func activate(_ request: BottomRequest, keyboardMatched: Bool) -> BottomCommand {
        commandID &+= 1
        let command = BottomCommand(id: commandID, request: request,
            instant: openingReturnIsPending, keyboardMatched: keyboardMatched)
        openingReturnIsPending = false
        lastRequest = request
        activeCommand = command
        return command
    }

    /// Only the latest animation can release ScrollPosition. A new gesture,
    /// approval or drawer transition invalidates an old completion immediately.
    ///
    /// K5 (round 1.1): the matched return's edge target must survive the whole
    /// keyboard transition. The same turn that begins the command also bumps the
    /// navigation generation (whose change normally releases the target), and a
    /// zero-distance animation can report completion immediately — either would
    /// clear the target before the keyboard has moved. While the window is open
    /// the command is held; the window's end settles it.
    mutating func complete(_ command: BottomCommand) -> Bool {
        guard activeCommand == command else { return false }
        if command.keyboardMatched && keyboardTransitionActive { return false }
        return settleActiveCommand()
    }

    /// Closes the keyboard transition window and settles the matched command the
    /// window held, if any. `true` means the caller must release the scroll edge
    /// target now that the keyboard has finished.
    @discardableResult mutating func endKeyboardTransition() -> Bool {
        keyboardTransitionActive = false
        guard let command = activeCommand, command.keyboardMatched else { return false }
        return settleActiveCommand()
    }

    private mutating func settleActiveCommand() -> Bool {
        guard activeCommand != nil else { return false }
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
