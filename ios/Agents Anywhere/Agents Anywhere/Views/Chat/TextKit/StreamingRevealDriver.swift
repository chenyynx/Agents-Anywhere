#if canImport(UIKit)
import QuartzCore
import UIKit

/// One streaming text block's visual reveal. It is the AA counterpart of the
/// official `RevealDriver`: a frame link samples the pure timeline, releases
/// characters in official 24...64 runs with 0.35 s patience, paints each run
/// as per-line mask rectangles, and reports the clamped bottom of the last
/// revealed line for the row height.
///
/// The timeline is owned above the cell (the adapter anchors it when text
/// arrives); this object only owns the visual state that must survive batches:
/// how far the mask has been drawn and where its last line sat.
@MainActor
final class StreamingRevealDriver: NSObject {
    private static let fadeDuration: CFTimeInterval = 0.6
    private static let seatedTolerance: CGFloat = 0.5

    override init() {
        super.init()
    }

    private var timeline: StreamingRevealTimeline?
    private var total = 0
    private var textComplete = false
    private var blockStart = 0
    private var blockLength = 0
    private weak var textView: UITextView?
    private var mask: CALayer?
    private var link: CADisplayLink?

    private var generator = StreamingRevealRunGenerator()
    private var policy = StreamingRevealRunPolicy()
    private var nextRun = 1
    private var waitingSince: TimeInterval?
    /// Bottom of the last painted line, in the text view's coordinates.
    private var seatedMaxY: CGFloat?
    private var seatedMinY: CGFloat?
    private var finishAt: TimeInterval?
    private var didFinish = false
    /// A configure-time mask rebuild changed the clamped bottom; the next tick
    /// reports it (configure runs inside the cell apply, so it must not
    /// invalidate the layout itself).
    private var needsReport = false

    /// Called after every released run with the clamped bottom (`nil` once the
    /// reveal is complete and the row may use its full height).
    var onFrame: ((CGFloat?) -> Void)?
    /// Called once the text is complete and the final fade has finished. The
    /// cell uses it to hand the row over to the static TextKit body.
    var onCaughtUp: (() -> Void)?

    /// Characters the mask has drawn so far, in message coordinates.
    private(set) var released: Int?

    func configure(state: StreamingRevealState,
                   blockStart: Int,
                   blockLength: Int,
                   textView: UITextView?) {
        let now = ProcessInfo.processInfo.systemUptime
        timeline = state.timeline
        total = state.total
        textComplete = state.isTextComplete
        self.blockStart = max(0, blockStart)
        self.blockLength = max(0, blockLength)
        if let released {
            self.released = min(released, total)
        } else {
            // A cell that appears mid-stream shows everything already released
            // without replaying the fade; only later characters animate.
            self.released = min(state.shownThrough(at: now), total)
        }
        if self.textView !== textView {
            detachMask()
            self.textView = textView
            attachMaskPreservingRevealed()
            // The cursor sits at the very start of this block: the row ends
            // where the block starts. Reporting the previous view's clamp here
            // would offset it by a whole block.
            if localRevealedLength == 0, (released ?? 0) > 0 {
                clampedHeight = 0
                needsReport = true
            }
        } else if let textView {
            rebuildMaskIfSeatedDrifted(in: textView)
        }
        if textComplete, (released ?? 0) >= total {
            finishIfFaded(now: now)
        } else {
            startLinkIfNeeded()
        }
    }

    /// Stop the link and drop the mask. Safe to call on reuse.
    func reset() {
        let hadClamp = clampedHeight != nil
        stopLink()
        detachMask()
        timeline = nil
        total = 0
        textComplete = false
        blockStart = 0
        blockLength = 0
        released = nil
        nextRun = 1
        waitingSince = nil
        seatedMaxY = nil
        seatedMinY = nil
        finishAt = nil
        didFinish = false
        needsReport = false
        clampedHeight = nil
        // A row that leaves the character reveal (for example the tail turned
        // into a code block) must return to its measured height. Defer the
        // callback: reset runs inside the cell's configuration, where
        // invalidating the collection layout would race the apply.
        if hadClamp {
            DispatchQueue.main.async { [weak self] in self?.onFrame?(nil) }
        }
    }

    private(set) var clampedHeight: CGFloat?

    // MARK: - Frame loop

    private func startLinkIfNeeded() {
        guard !didFinish else { return }
        if let link {
            link.isPaused = false
            return
        }
        let created = CADisplayLink(target: self, selector: #selector(tick(_:)))
        created.preferredFrameRateRange = CAFrameRateRange(
            minimum: 30, maximum: 60, preferred: 60)
        created.add(to: .main, forMode: .common)
        link = created
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard !didFinish, let timeline, let textView else {
            stopLink()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if mask?.frame != textView.bounds {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mask?.frame = textView.bounds
            CATransaction.commit()
        }
        restoreMaskIfNeeded(in: textView)
        if needsReport {
            needsReport = false
            onFrame?(clampedHeight)
        }

        let target = min(timeline.shownThrough(at: now), total)
        let released = self.released ?? 0
        if target <= released {
            if waitingSince == nil { waitingSince = now }
            if textComplete, released >= total {
                finishIfFaded(now: now)
            } else if !textComplete {
                // Caught up between batches (a tool pause): no frames to
                // paint until new text arrives, and the next configuration
                // restarts the link.
                stopLink()
            }
            return
        }

        let decision = policy.decision(
            released: released, target: target, nextRun: nextRun,
            waitingSince: waitingSince, now: now)
        guard decision == .advance else {
            if waitingSince == nil { waitingSince = now }
            return
        }

        rebuildMaskIfSeatedDrifted(in: textView)

        let lower = max(released, blockStart)
        let upper = max(lower, target)
        let localLower = min(lower - blockStart, blockLength)
        let localUpper = min(upper - blockStart, blockLength)
        if localUpper > localLower {
            let range = NSRange(location: localLower,
                                length: localUpper - localLower)
            let rects = AssistantMarkdownMaskRenderer.lineRects(
                for: range, in: textView)
            if !rects.isEmpty, let mask {
                if let layer = AssistantMarkdownMaskRenderer.makeRunLayer(
                    rects: rects, in: textView, fadeDuration: Self.fadeDuration) {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    mask.addSublayer(layer)
                    CATransaction.commit()
                }
                let clamped = rects.map(\.maxY).max()
                if let last = rects.last {
                    seatedMinY = last.minY
                    seatedMaxY = clamped
                }
                if clamped != clampedHeight {
                    clampedHeight = clamped
                    onFrame?(clamped)
                    // The cell may have reconfigured the driver from inside
                    // the callback (cursor crossed a block, full rebuild);
                    // do not write state into a reset driver.
                    guard self.timeline != nil else { return }
                }
            }
        }
        self.released = upper
        nextRun = generator.nextRun()
        waitingSince = nil
        if textComplete, upper >= total {
            finishAt = now + Self.fadeDuration
        }
    }

    private func finishIfFaded(now: TimeInterval) {
        guard !didFinish, textComplete else { return }
        if let finishAt, now < finishAt { return }
        finish()
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        stopLink()
        detachMask()
        clampedHeight = nil
        onFrame?(nil)
        onCaughtUp?()
    }

    // MARK: - Mask

    private var localRevealedLength: Int {
        min(max(0, min(released ?? 0, total) - blockStart), blockLength)
    }

    private func attachMaskPreservingRevealed() {
        guard let textView else { return }
        let container = AssistantMarkdownMaskRenderer.makeMaskContainer(for: textView)
        textView.layer.mask = container
        mask = container
        let length = localRevealedLength
        guard length > 0 else { return }
        let rects = AssistantMarkdownMaskRenderer.lineRects(
            for: NSRange(location: 0, length: length), in: textView)
        guard !rects.isEmpty else { return }
        // Restored text is already revealed; replaying the 0.6 s fade here
        // would flash the whole block whenever a cell is rebuilt.
        if let layer = AssistantMarkdownMaskRenderer.makeRunLayer(
            rects: rects, in: textView, fadeDuration: 0) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            container.addSublayer(layer)
            CATransaction.commit()
        }
        seatedMinY = rects.last?.minY
        seatedMaxY = rects.last?.maxY
        clampedHeight = rects.last?.maxY
        needsReport = clampedHeight != nil
        // No height callback here: this runs inside the cell's configuration,
        // where invalidating the collection layout would race the apply. The
        // next display-link tick reports the same value.
    }

    private func detachMask() {
        if let mask, textView?.layer.mask === mask {
            textView?.layer.mask = nil
        }
        mask = nil
        seatedMaxY = nil
        seatedMinY = nil
    }

    /// A text view that was created before its first layout has no width, so
    /// the restored mask could not be built. Rebuild it once the view has a
    /// width; without this the already-released text stays hidden until the
    /// next run repaints it.
    private func restoreMaskIfNeeded(in textView: UITextView) {
        let length = localRevealedLength
        guard seatedMaxY == nil, length > 0, textView.bounds.width > 0,
              let mask else { return }
        let rects = AssistantMarkdownMaskRenderer.lineRects(
            for: NSRange(location: 0, length: length), in: textView)
        guard let last = rects.last else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.sublayers?.forEach { $0.removeFromSuperlayer() }
        if let layer = AssistantMarkdownMaskRenderer.makeRunLayer(
            rects: rects, in: textView, fadeDuration: 0) {
            mask.addSublayer(layer)
        }
        CATransaction.commit()
        seatedMaxY = last.maxY
        seatedMinY = last.minY
        clampedHeight = last.maxY
        needsReport = true
    }

    /// A content update can move the lines the mask already covers. Official
    /// rebuilds the covered range when its seated bottom drifts by 0.5 pt.
    private func rebuildMaskIfSeatedDrifted(in textView: UITextView) {
        let length = localRevealedLength
        guard length > 0, let mask, let knownMaxY = seatedMaxY else { return }
        let rects = AssistantMarkdownMaskRenderer.lineRects(
            for: NSRange(location: 0, length: length), in: textView)
        guard let last = rects.last else { return }
        guard abs(last.maxY - knownMaxY) > Self.seatedTolerance
                || abs(last.minY - (seatedMinY ?? last.minY)) > Self.seatedTolerance else {
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.sublayers?.forEach { $0.removeFromSuperlayer() }
        if let layer = AssistantMarkdownMaskRenderer.makeRunLayer(
            rects: rects, in: textView, fadeDuration: 0) {
            mask.addSublayer(layer)
        }
        CATransaction.commit()
        seatedMaxY = last.maxY
        seatedMinY = last.minY
        clampedHeight = last.maxY
        needsReport = true
    }
}
#endif
