import UIKit

/// The transcript's single content-offset writer.
///
/// It owns the official placement state machine, resolves the target from the
/// placement on every event and frame (never from a cached offset), and moves
/// the list either by placing directly or through the Mover. Safe-area (and
/// thus keyboard and composer) changes are written here too, because the
/// official surface has exactly one inset owner.
///
/// The controller supplies geometry through closures and forwards native
/// events; nothing else may write `contentOffset` while the driver is active.
@MainActor
final class TimelineAnchorDriver {
    struct Inputs {
        /// Content height of the prepared layout.
        var contentHeight: () -> CGFloat
        /// Content-space top of a row, nil when it is not in the window.
        var rowStart: (String) -> CGFloat?
        /// The row under the viewport top and how far into it the top sits.
        var readingAnchor: (CGFloat) -> (id: String, offsetIntoRow: CGFloat)?
        /// First row of the window (status-bar scroll-to-top target).
        var firstRowID: () -> String?
        /// The measured viewport reached the bottom (opening mask release).
        var onBottomArrived: (() -> Void)?
    }

    private(set) weak var scrollView: UICollectionView?
    private let inputs: Inputs

    private(set) var state = TimelineAnchorState()
    private var mover: TimelineAnchorMover
    /// The placement the running Mover was started for. A placement change is
    /// a new motion: the Pace shift must not carry across it (the target jump
    /// between `.end` and `.row` is a real distance to animate, not content
    /// growth to track 1:1).
    private var moverPlacement: TimelineAnchorPlacement?
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var pageInsets: UIEdgeInsets = .zero
    private var isApplying = false
    private var isSuspended = false
    private var isInteractionPresented = false
    private var didReportOpeningArrival = false
#if DEBUG
    /// Gate counter: how many Mover motions actually started.
    private(set) var debugMoveStarts = 0
    /// Gate probe: a programme-driven scroll must be interpreted differently
    /// while a Mover spring is still travelling.
    var debugMoverRunning: Bool { mover.isRunning }
#endif

    init(scrollView: UICollectionView, inputs: Inputs) {
        self.scrollView = scrollView
        self.inputs = inputs
        self.mover = TimelineAnchorMover(position: scrollView.contentOffset.y)
    }

    // MARK: - Geometry

    private var pixel: CGFloat {
        TimelineSpringFollow.pixel(displayScale: scrollView?.traitCollection.displayScale ?? 2)
    }

    private func geometry(titleTop: CGFloat? = nil, bottom: CGFloat? = nil) -> TimelineAnchorGeometry {
        let view = scrollView
        return TimelineAnchorGeometry(
            contentHeight: inputs.contentHeight(),
            containerHeight: view?.bounds.height ?? 0,
            topInset: titleTop ?? (view?.adjustedContentInset.top ?? 0),
            bottomInset: bottom ?? (view?.adjustedContentInset.bottom ?? 0),
            rowStart: inputs.rowStart,
            readingAnchor: inputs.readingAnchor)
    }

    private func bottomTarget(topInset: CGFloat, bottomInset: CGFloat,
                              contentHeight: CGFloat? = nil) -> CGFloat {
        TimelineOffsetTarget.bottomOffset(
            contentHeight: contentHeight ?? inputs.contentHeight(),
            containerHeight: scrollView?.bounds.height ?? 0,
            topInset: topInset,
            bottomInset: bottomInset)
    }

    private func currentAnchor() -> (id: String, offsetIntoRow: CGFloat)? {
        guard let view = scrollView else { return nil }
        return inputs.readingAnchor(view.contentOffset.y)
    }

    private func isAtEnd() -> Bool {
        guard let view = scrollView else { return false }
        return geometry().isAtEnd(offset: view.contentOffset.y,
                                  displayScale: view.traitCollection.displayScale)
    }

    private func writeOffset(_ y: CGFloat) {
        guard let view = scrollView else { return }
        guard abs(view.contentOffset.y - y) >= 0.5 else { return }
        isApplying = true
        view.setContentOffset(CGPoint(x: view.contentOffset.x, y: y), animated: false)
        isApplying = false
    }

    // MARK: - Safe area (inset owner)

    /// Applies the official inset and keeps the reader's place across the
    /// write. A change with an ambient animation (keyboard, `inherited=0.383s`
    /// on device) is written directly and rides it. A composer-only change
    /// arrives with **no** animation transaction (`inherited=0.000s`, b558
    /// probe): writing the offset directly there was a measured 49 pt hard
    /// jump, so the follow adds a 0.24 s spring matched to the composer's
    /// `.smooth(duration: 0.24)` (fix `499b3e3f`, device-verified on b559).
    /// A shrink moves the offset before the inset so UIKit cannot clamp it
    /// against the old maximum.
    func updateSafeAreaInsets(_ insets: UIEdgeInsets) {
        pageInsets = insets
        applyInsets()
    }

    private func applyInsets() {
        guard let view = scrollView else { return }
        let viewInsets = view.safeAreaInsets
        let target = UIEdgeInsets(top: max(pageInsets.top - viewInsets.top, 0),
                                  left: max(pageInsets.left - viewInsets.left, 0),
                                  bottom: max(pageInsets.bottom - viewInsets.bottom, 0),
                                  right: max(pageInsets.right - viewInsets.right, 0))
        let current = view.contentInset
        let changed = abs(current.top - target.top) > 0.5
            || abs(current.left - target.left) > 0.5
            || abs(current.bottom - target.bottom) > 0.5
            || abs(current.right - target.right) > 0.5
        guard changed else { return }
#if AA_TIMELINE_PROBE
        let offsetBefore = view.contentOffset
        let insetBefore = current
        defer {
            AnchorDeviceProbe.shared.recordApply(
                proxyBottom: pageInsets.bottom,
                inherited: UIView.inheritedAnimationDuration,
                insetBefore: insetBefore, insetAfter: view.contentInset,
                offsetBefore: offsetBefore, offsetAfter: view.contentOffset)
        }
#endif
        let following = state.placement == .end
            && state.motion != .dragging && state.motion != .coasting
        if !following {
            let offset = view.contentOffset
            isApplying = true
            view.contentInset = target
            if view.contentOffset != offset {
                view.setContentOffset(offset, animated: false)
            }
            isApplying = false
            return
        }
        stopMover()
        if state.motion == .easing || state.motion == .flying {
            state.motion = .resting
        }
        let top = target.top + viewInsets.top
        let bottom = target.bottom + viewInsets.bottom
        let destination = bottomTarget(topInset: top, bottomInset: bottom)
        let needsMove = abs(view.contentOffset.y - destination) > 0.5
        let shrinking = target.bottom < current.bottom - 0.5
        let ambient = UIView.inheritedAnimationDuration > 0.01
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
            || UIAccessibility.isVoiceOverRunning
        let apply = { [weak self, weak view] in
            guard let self, let view else { return }
            self.isApplying = true
            if shrinking && needsMove {
                view.setContentOffset(CGPoint(x: view.contentOffset.x, y: destination),
                                      animated: false)
                view.contentInset = target
            } else {
                view.contentInset = target
                if needsMove {
                    view.setContentOffset(CGPoint(x: view.contentOffset.x, y: destination),
                                          animated: false)
                }
            }
            self.isApplying = false
        }
        if ambient || reduceMotion {
            apply()
        } else {
            UIView.animate(withDuration: 0.24, delay: 0,
                           usingSpringWithDamping: 1,
                           initialSpringVelocity: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction]) {
                apply()
            }
        }
    }

    // MARK: - Events

    func viewportChanged() {
        perform(.viewportChanged)
    }

    /// Bounds changed (rotation, split view) without an inset change: only a
    /// following page re-resolves; a reading page keeps its offset.
    func containerChanged() {
        if state.placement == .end { placeDirect() }
    }

    /// `disarmBottom` semantics: pin the live viewport as the reading anchor
    /// and stop any motion (a history request must not fight a follow).
    func adoptReadingPlacement() {
        stopMover()
        if state.motion == .easing || state.motion == .flying {
            state.motion = .resting
        }
        guard let view = scrollView,
              let anchor = inputs.readingAnchor(view.contentOffset.y) else { return }
        state.placement = .reading(id: anchor.id, offsetIntoRow: anchor.offsetIntoRow)
    }

    func contentChanged() {
        perform(.contentChanged)
    }

    func readerBeganDragging() {
        guard let anchor = currentAnchor() else { return }
        perform(.readerBeganDragging(id: anchor.id, offsetIntoRow: anchor.offsetIntoRow))
    }

    func readerLifted(willCoast: Bool) {
        guard let anchor = currentAnchor() else {
            perform(.readerLifted(willCoast: willCoast, atEnd: isAtEnd(),
                                  id: nil, offsetIntoRow: 0))
            return
        }
        perform(.readerLifted(willCoast: willCoast, atEnd: isAtEnd(),
                              id: anchor.id, offsetIntoRow: anchor.offsetIntoRow))
    }

    func coastingEnded() {
        guard let anchor = currentAnchor() else {
            perform(.coastingEnded(atEnd: isAtEnd(), id: nil, offsetIntoRow: 0))
            return
        }
        perform(.coastingEnded(atEnd: isAtEnd(),
                               id: anchor.id, offsetIntoRow: anchor.offsetIntoRow))
    }

    /// The scroll view moved while no finger was down and the driver did not
    /// write it — UIKit's own safe-area/layout adjustment (official
    /// `scrolledWithoutAHand`). The driver's own writes set `isApplying`.
    func scrolledWithoutAHand() {
        guard state.hasLanded else { return }
        guard !isApplying, state.motion != .dragging, state.motion != .coasting else { return }
        if mover.isRunning {
            // A UIKit layout correction moved the page under the Mover. Adopt
            // the live position; the next tick continues from there.
            mover.reseed(at: scrollView?.contentOffset.y ?? mover.position)
            return
        }
        guard let anchor = currentAnchor() else { return }
        perform(.scrolledWithoutAHand(atEnd: isAtEnd(),
                                      id: anchor.id, offsetIntoRow: anchor.offsetIntoRow))
    }

    /// Stops any Mover motion where it is (approval presented, drawer moves).
    func haltMotion() {
        stopMover()
        if state.motion == .easing || state.motion == .flying {
            state.motion = .resting
        }
    }

    func requestEnd(animated: Bool) {
        perform(.askedForEnd(animated: animated))
    }

    func requestStart() {
        guard let first = inputs.firstRowID() else { return }
        perform(.askedForStart(id: first))
    }

    func windowReplaced(readerTookOver: Bool) {
        perform(.windowReplaced(readerTookOver: readerTookOver))
    }

    func interactionPresentedChanged(_ presented: Bool) {
        guard isInteractionPresented != presented else { return }
        isInteractionPresented = presented
        let anchor = currentAnchor()
        perform(.interactionPresentedChanged(presented: presented,
                                             id: anchor?.id,
                                             offsetIntoRow: anchor?.offsetIntoRow ?? 0))
    }

    func navigationSuspendedChanged(_ suspended: Bool) {
        guard isSuspended != suspended else { return }
        isSuspended = suspended
        perform(.navigationSuspendedChanged(suspended: suspended))
    }

    func setSuspended(_ suspended: Bool) {
        isSuspended = suspended
    }

    // MARK: - Reducer plumbing

    private func perform(_ event: TimelineAnchorEvent) {
        let reduction = TimelineAnchorReducer.reduce(state, event)
        state = reduction.state
        switch reduction.action {
        case .none:
            break
        case .halt:
            stopMover()
        case .placeDirect:
            stopMover()
            placeDirect()
        case .move:
            startMover()
        }
    }

    /// Resolves the placement and writes it in the current transaction.
    /// A row that is no longer in the window repairs the placement from the
    /// live viewport instead of jumping.
    private func placeDirect() {
        guard let view = scrollView else { return }
        guard let target = state.placement.target(in: geometry()) else {
            repairPlacement()
            return
        }
        writeOffset(target)
        if state.placement == .end, !didReportOpeningArrival, isAtEnd() {
            didReportOpeningArrival = true
            inputs.onBottomArrived?()
        }
    }

    private func repairPlacement() {
        guard let view = scrollView else { return }
        guard let anchor = inputs.readingAnchor(view.contentOffset.y) else {
            state.placement = .end
            return
        }
        state.placement = .reading(id: anchor.id, offsetIntoRow: anchor.offsetIntoRow)
    }

    private func startMover() {
        guard let view = scrollView else { return }
        guard let target = state.placement.target(in: geometry()) else {
            repairPlacement()
            return
        }
        if UIAccessibility.isReduceMotionEnabled || UIAccessibility.isVoiceOverRunning {
            // Official conditions: no sprung motion under Reduce Motion or
            // VoiceOver; the placement is resolved directly.
            writeOffset(target)
            state.motion = .resting
            return
        }
        let current = view.contentOffset.y
        let visible = TimelineOffsetTarget.visibleHeight(
            containerHeight: view.bounds.height,
            topInset: view.adjustedContentInset.top,
            bottomInset: view.adjustedContentInset.bottom)
        let spring = TimelineSpringFollow.spring(
            target: target, current: current, visibleHeight: visible)
        if mover.isRunning, moverPlacement == state.placement {
            // Same motion, new destination: retarget without restarting the
            // spring (a restart on every height change would jitter). This
            // must outrank the dead band below: with the Pace shift a live
            // stream keeps a sub-pixel gap while the motion still has to stay
            // alive.
            mover.retarget(spring: spring)
            if state.motion == .easing, spring == .fly {
                state.motion = .flying
            }
            return
        }
        guard TimelineSpringFollow.shouldMove(
            target: target, current: current,
            displayScale: view.traitCollection.displayScale) else {
            state.motion = .resting
            return
        }
        if mover.isRunning {
            // Different placement: start a new motion so the Pace shift cannot
            // mistake the placement jump for content growth.
            stopMover()
        }
        let preplaced = TimelineSpringFollow.preplacedOffset(
            target: target, current: current, visibleHeight: visible)
        if abs(preplaced - current) >= pixel {
            writeOffset(preplaced)
        }
        mover.start(at: view.contentOffset.y, spring: spring)
        moverPlacement = state.placement
#if DEBUG
        debugMoveStarts += 1
#endif
        state.motion = spring == .fly ? .flying : .easing
        startLink()
    }

    private func startLink() {
        guard link == nil else { return }
        lastTick = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        let maxFPS = max(60, screenMaxFPS())
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: Float(maxFPS) / 2, maximum: Float(maxFPS), preferred: 0)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func screenMaxFPS() -> Int {
        scrollView?.window?.screen.maximumFramesPerSecond ?? 60
    }

    private func stopMover() {
        mover.stop()
        moverPlacement = nil
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let view = scrollView, mover.isRunning else {
            stopMover()
            return
        }
        guard !isSuspended else {
            stopMover()
            state.motion = .resting
            return
        }
        let now = CACurrentMediaTime()
        let dt = now - lastTick
        lastTick = now
        if abs(view.contentOffset.y - mover.position) > 1 {
            // A layout pass moved the page between ticks; continue from the
            // live offset instead of overwriting it with the stale integral.
            mover.reseed(at: view.contentOffset.y)
        }
        let target = state.placement.target(in: geometry()) ?? view.contentOffset.y
        let step = mover.step(target: target, dt: dt,
                              displayScale: view.traitCollection.displayScale)
        writeOffset(step.position)
        if step.arrived {
            stopMover()
            state.motion = .resting
            perform(.arrived)
            if state.placement == .end {
                didReportOpeningArrival = true
                inputs.onBottomArrived?()
            }
        }
    }
}
