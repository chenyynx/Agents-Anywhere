#if canImport(UIKit)
import QuartzCore
import SwiftUI
import UIKit

#if DEBUG
/// DEBUG-only build cost for the scroll gate. Counts every full block-tree
/// construction so the probe can separate view building from layout.
@MainActor
enum AssistantMarkdownCellBuildMetrics {
    private(set) static var count = 0
    private(set) static var totalMilliseconds: Double = 0
    private(set) static var maxMilliseconds: Double = 0
    private(set) static var kindTotals: [String: Double] = [:]
    private(set) static var kindCounts: [String: Int] = [:]

    static var averageMilliseconds: Double {
        count == 0 ? 0 : totalMilliseconds / Double(count)
    }

    static func reset() {
        count = 0
        totalMilliseconds = 0
        maxMilliseconds = 0
        kindTotals = [:]
        kindCounts = [:]
    }

    static func record(_ milliseconds: Double) {
        count += 1
        totalMilliseconds += milliseconds
        maxMilliseconds = max(maxMilliseconds, milliseconds)
    }

    static func record(kind: String, milliseconds: Double) {
        kindTotals[kind, default: 0] += milliseconds
        kindCounts[kind, default: 0] += 1
    }

    static var kindSnapshot: [String: Any] {
        var snapshot: [String: Any] = [:]
        for (kind, total) in kindTotals {
            let samples = kindCounts[kind] ?? 0
            snapshot[kind] = [
                "totalMs": total,
                "count": samples,
                "averageMs": samples == 0 ? 0 : total / Double(samples),
            ]
        }
        return snapshot
    }
}
#endif

/// The assistant body cell. It hosts a vertical stack of block views with the
/// product's 12pt block spacing. The row height is owned by
/// `TimelineListLayout` (policy `.measured`); the cell only renders the blocks
/// the layout already measured, installing the same heights as constraints so
/// `systemLayoutSizeFitting` reports the identical number.
final class AssistantMarkdownCell: UICollectionViewCell {
    static let reuseIdentifier = "AssistantMarkdownCell"

    private let stack = UIStackView()
    private var document: AssistantMarkdownDocument?
    private var footer: AssistantTurnFooter?
    private var footerHost: UIHostingController<SessionTurnActionsRow>?
    private var heightConstraints: [NSLayoutConstraint] = []
    private var lastLayoutWidth: CGFloat = -1

    // C5/M4 streaming state. Settled blocks keep their views across batches;
    // the tail is rebuilt from the same TextKit block factory and only its
    // open text block carries the reveal mask.
    private var streaming: AssistantStreamingDocument?
    private var revealState: StreamingRevealState?
    private var stableIDs: [AssistantBlockID] = []
    private var stableViews: [AssistantBlockID: UIView] = [:]
    private var stableConstraints: [AssistantBlockID: NSLayoutConstraint] = [:]
    private var tailIDs: [AssistantBlockID] = []
    private var tailViews: [AssistantBlockID: UIView] = [:]
    private var tailConstraints: [AssistantBlockID: NSLayoutConstraint] = [:]
    private var lastGeneration = -1

    /// The reveal driver per cell. It survives batch configurations so the
    /// mask keeps its released cursor; reuse and static configuration reset it.
    private let revealDriver = StreamingRevealDriver()
    /// Row height while the cursor is mid-message (`nil` means the full
    /// measured height). The controller installs this on the layout.
    var onStreamingRevealFrame: ((CGFloat?) -> Void)?
    /// The final fade finished; the row may hand over to the static body.
    var onStreamingRevealCaughtUp: (() -> Void)?

    #if DEBUG
    private(set) var debugStableViewsBuilt = 0
    private(set) var debugTailUpdates = 0

    var debugTailViewCount: Int { tailViews.count }
    var debugMaskInstalled: Bool {
        revealDriver.clampedHeight != nil
    }
    /// Whether the cursor text view actually carries the reveal mask. The
    /// clamp flag is a proxy; the gate checks the layer itself.
    var debugMaskLayerInstalled: Bool {
        revealCursorView?.layer.mask != nil
    }
    var debugRevealedCharacters: Int { revealDriver.released ?? 0 }
    /// Last row height the reveal reported (`nil` once the row uses its full
    /// measured height).
    private(set) var debugStreamingRowHeight: CGFloat?
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        contentView.clipsToBounds = true
        clipsToBounds = true
        stack.axis = .vertical
        stack.alignment = .fill
        stack.distribution = .fill
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        let bottom = stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        // Optional: the layout may round the row a fraction above the block
        // heights. The fitting pass still needs a bottom edge, or it minimizes
        // the content view to zero.
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            bottom,
        ])
        revealDriver.onFrame = { [weak self] clamped in
            self?.handleRevealFrame(clamped)
        }
        revealDriver.onCaughtUp = { [weak self] in
            self?.onStreamingRevealCaughtUp?()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    #if DEBUG
    var debugArrangedBlockViews: [UIView] { stack.arrangedSubviews }
    #endif

    func configure(_ document: AssistantMarkdownDocument,
                   footer: AssistantTurnFooter? = nil) {
        self.document = document
        self.footer = footer
        self.streaming = nil
        self.revealState = nil
        lastGeneration = -1
        lastLayoutWidth = -1
        revealDriver.reset()
        #if DEBUG
        debugStreamingRowHeight = nil
        #endif
        rebuildIfPossible()
    }

    /// Streaming row: every block is a TextKit view; the open text block runs
    /// the official per-line reveal mask. The timeline lives in the adapter so
    /// cell reuse does not restart the cursor.
    func configure(streaming: AssistantStreamingDocument,
                   reveal: StreamingRevealState?) {
        self.document = nil
        self.footer = nil
        self.streaming = streaming
        self.revealState = reveal
        rebuildStreamingIfPossible()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = contentView.bounds.width
        if width > 0, abs(width - lastLayoutWidth) > 0.5 {
            if streaming != nil {
                rebuildStreamingIfPossible()
            } else {
                rebuildIfPossible()
            }
        }
    }

    /// An offscreen cell must stop its reveal link (and report the clamp as
    /// cleared). The adapter keeps the cursor, so a cell that comes back shows
    /// everything already released without replaying the fade.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil, streaming != nil {
            revealDriver.reset()
            revealCursorView = nil
            #if DEBUG
            debugStreamingRowHeight = nil
            #endif
        }
    }

    /// Block views need a concrete width: the text views measure their glyphs
    /// at it, and the list/quote containers divide the remaining column. Before
    /// the first layout pass the width is zero, so `layoutSubviews` builds them.
    private func rebuildIfPossible() {
        guard let document, contentView.bounds.width > 0 else { return }
        #if DEBUG
        let buildStart = CACurrentMediaTime()
        defer {
            AssistantMarkdownCellBuildMetrics.record(
                (CACurrentMediaTime() - buildStart) * 1000)
        }
        #endif
        #if DEBUG
        let clearStart = CACurrentMediaTime()
        #endif
        removeBlockViews()
        #if DEBUG
        AssistantMarkdownCellBuildMetrics.record(
            kind: "clear",
            milliseconds: (CACurrentMediaTime() - clearStart) * 1000)
        #endif
        let width = contentView.bounds.width
        lastLayoutWidth = width
        for block in document.blocks {
            #if DEBUG
            let blockStart = CACurrentMediaTime()
            #endif
            let made = AssistantMarkdownBlockViewFactory.make(
                block, width: width, displayScale: traitCollection.displayScale)
            #if DEBUG
            AssistantMarkdownCellBuildMetrics.record(
                kind: block.kindName,
                milliseconds: (CACurrentMediaTime() - blockStart) * 1000)
            #endif
            stack.addArrangedSubview(made.view)
            let constraint = made.view.heightAnchor.constraint(equalToConstant: made.height)
            constraint.isActive = true
            heightConstraints.append(constraint)
        }

        // Textual collapses adjacent block margins (max, not sum); the same
        // rule is used by the measurement path.
        for index in 1..<max(1, document.blocks.count) {
            guard stack.arrangedSubviews.indices.contains(index - 1) else { break }
            stack.setCustomSpacing(
                AssistantMarkdownTextLayout.topLevelSpacing(
                    after: index - 1, in: document),
                after: stack.arrangedSubviews[index - 1])
        }

        if let footer {
            // `SessionTimelineGroupView` uses a 4pt VStack gap between the
            // reply and its footer; the action row itself has a fixed height.
            if let last = stack.arrangedSubviews.last {
                stack.setCustomSpacing(AssistantTurnFooter.topSpacing, after: last)
            }
            let host = UIHostingController(rootView: SessionTurnActionsRow(
                copyText: footer.copyText, timestampText: footer.timestampText))
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(host.view)
            let constraint = host.view.heightAnchor.constraint(
                equalToConstant: SessionTurnActionsRow.rowHeight)
            constraint.isActive = true
            heightConstraints.append(constraint)
            footerHost = host
        }
    }

    // MARK: - Streaming

    /// Settled blocks are appended once; the tail blocks are rebuilt from the
    /// same TextKit factory and follow the stable views. A new generation
    /// (correction), a width change, or a stable set that is not a prefix of
    /// the previous one rebuilds everything.
    private func rebuildStreamingIfPossible() {
        guard let streaming, contentView.bounds.width > 0 else { return }
        let width = contentView.bounds.width
        let displayScale = traitCollection.displayScale
        let ids = streaming.stableBlockIDs
        let shared = zip(ids, stableIDs).prefix { $0.0 == $0.1 }.count
        let needsFull = streaming.generation != lastGeneration
            || abs(width - lastLayoutWidth) > 0.5
            || shared < min(ids.count, stableIDs.count)
            || ids.count < stableIDs.count
        if needsFull {
            removeBlockViews()
            lastLayoutWidth = width
            lastGeneration = streaming.generation
        }

        if ids.count > stableIDs.count {
            for index in stableIDs.count..<ids.count {
                guard index < streaming.document.blocks.count else { break }
                let id = ids[index]
                let made = AssistantMarkdownBlockViewFactory.make(
                    streaming.document.blocks[index], width: width,
                    displayScale: displayScale)
                stack.insertArrangedSubview(made.view, at: tailInsertionIndex())
                let constraint = made.view.heightAnchor.constraint(
                    equalToConstant: made.height)
                constraint.isActive = true
                stableIDs.append(id)
                stableViews[id] = made.view
                stableConstraints[id] = constraint
                #if DEBUG
                debugStableViewsBuilt += 1
                #endif
            }
        }

        updateTail(streaming, width: width)

        // Every block has exactly one arranged view, in document order, so the
        // same collapsed-margin rule the measurement and the static cell use
        // maps directly onto the stack.
        let blocks = streaming.document.blocks
        for index in blocks.indices where stack.arrangedSubviews.indices.contains(index) {
            let spacing = index + 1 < blocks.count
                ? AssistantMarkdownTextLayout.topLevelSpacing(
                    after: index, in: streaming.document)
                : 0
            stack.setCustomSpacing(spacing, after: stack.arrangedSubviews[index])
        }

        configureReveal(streaming)
    }

    /// The first tail view's position: a newly promoted stable block lands in
    /// front of the tail, never after it.
    private func tailInsertionIndex() -> Int {
        for id in tailIDs {
            if let view = tailViews[id],
               let index = stack.arrangedSubviews.firstIndex(where: { $0 === view }) {
                return index
            }
        }
        return stack.arrangedSubviews.count
    }

    private func updateTail(_ streaming: AssistantStreamingDocument, width: CGFloat) {
        let blocks = streaming.document.blocks
        let start = min(streaming.stableBlockCount, blocks.count)
        guard streaming.blockIDs.count == blocks.count else { return }
        let ids = Array(streaming.blockIDs[start...])
        let keep = Set(ids)
        for id in tailIDs where !keep.contains(id) {
            removeTailView(id)
        }
        for (offset, id) in ids.enumerated() {
            let block = blocks[start + offset]
            let height = AssistantMarkdownTextLayout.height(
                of: block, width: width,
                displayScale: traitCollection.displayScale)
            if let view = tailViews[id] as? AssistantMarkdownBlockTextView,
               case .text(let text) = block {
                if let current = view.attributedText,
                   current.isEqual(to: text.attributed) {
                    // Same content: keep the view and its mask layers.
                } else {
                    view.attributedText = text.attributed
                }
                tailConstraints[id]?.constant = height
            } else {
                let isNew = tailViews[id] == nil
                removeTailView(id)
                let made = AssistantMarkdownBlockViewFactory.make(
                    block, width: width,
                    displayScale: traitCollection.displayScale)
                stack.addArrangedSubview(made.view)
                let constraint = made.view.heightAnchor.constraint(
                    equalToConstant: made.height)
                constraint.isActive = true
                tailViews[id] = made.view
                tailConstraints[id] = constraint
                // Code/table/list/quote tails enter with the official cell
                // fade (`revealEntrance`, 0.25 s, ease-out). Text leaves use
                // the character mask instead.
                if isNew, !(made.view is AssistantMarkdownBlockTextView) {
                    applyBlockEntrance(to: made.view)
                }
            }
        }
        tailIDs = ids
        #if DEBUG
        debugTailUpdates += 1
        #endif
    }

    /// The official Chat entrance: opacity 0 → 1 over 0.25 s ease-out with a
    /// 5 pt rise (the rise is off under Reduce Motion; the fade stays).
    /// `opacity = min(4 × progress, 1)` at first appearance is 0, so the first
    /// frame is the full 0.25 s / 5 pt.
    private func applyBlockEntrance(to view: UIView) {
        let now = CACurrentMediaTime()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.0
        fade.toValue = 1.0
        fade.duration = 0.25
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.beginTime = now
        fade.fillMode = .backwards
        view.layer.add(fade, forKey: "revealEntrance")
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = 5.0
        rise.toValue = 0.0
        rise.duration = 0.25
        rise.timingFunction = CAMediaTimingFunction(name: .easeOut)
        rise.beginTime = now
        rise.fillMode = .backwards
        view.layer.add(rise, forKey: "revealEntranceRise")
    }

    private func removeTailView(_ id: AssistantBlockID) {
        guard let view = tailViews[id] else { return }
        tailConstraints[id]?.isActive = false
        stack.removeArrangedSubview(view)
        view.removeFromSuperview()
        tailViews.removeValue(forKey: id)
        tailConstraints.removeValue(forKey: id)
    }

    /// The cursor block is the top-level block that contains the reveal
    /// offset. A text block gets the per-line mask even when a list, quote,
    /// code or table follows it; those later structures use the block
    /// entrance instead of a character mask.
    private func configureReveal(_ streaming: AssistantStreamingDocument) {
        guard let state = revealState else {
            revealDriver.reset()
            revealCursorView = nil
            return
        }
        let blocks = streaming.document.blocks
        let now = ProcessInfo.processInfo.systemUptime
        let cursor = min(state.shownThrough(at: now), state.total)
        var start = 0
        var cursorIndex = -1
        for (index, block) in blocks.enumerated() {
            let end = start + block.characterCount
            if cursor < end {
                cursorIndex = index
                break
            }
            start = end
        }
        if cursorIndex < 0 { cursorIndex = blocks.count - 1 }
        guard cursorIndex >= 0,
              cursorIndex < streaming.blockIDs.count,
              case .text = blocks[cursorIndex],
              let view = (stableViews[streaming.blockIDs[cursorIndex]]
                            ?? tailViews[streaming.blockIDs[cursorIndex]])
                        as? AssistantMarkdownBlockTextView else {
            revealDriver.reset()
            revealCursorView = nil
            return
        }
        var blockStart = 0
        for index in 0..<cursorIndex {
            blockStart += blocks[index].characterCount
        }
        revealCursorView = view
        revealDriver.configure(
            state: state, blockStart: blockStart,
            blockLength: blocks[cursorIndex].characterCount,
            textView: view)
    }

    /// The open text block's view (tail or already-promoted stable). The
    /// cursor is chosen by character offset, not by "last block": a text
    /// paragraph followed by a list must still be masked while revealing.
    private weak var revealCursorView: UIView?

    private func handleRevealFrame(_ clamped: CGFloat?) {
        guard let clamped, let cursorView = revealCursorView else {
            #if DEBUG
            debugStreamingRowHeight = nil
            #endif
            onStreamingRevealFrame?(nil)
            return
        }
        let point = cursorView.convert(CGPoint(x: 0, y: clamped), to: contentView)
        let height = ceil(point.y + 1.0)
        #if DEBUG
        debugStreamingRowHeight = height
        #endif
        onStreamingRevealFrame?(height)
    }

    private func removeBlockViews() {
        revealDriver.reset()
        revealCursorView = nil
        NSLayoutConstraint.deactivate(heightConstraints)
        NSLayoutConstraint.deactivate(Array(stableConstraints.values))
        NSLayoutConstraint.deactivate(Array(tailConstraints.values))
        heightConstraints = []
        stableIDs = []
        stableViews = [:]
        stableConstraints = [:]
        tailIDs = []
        tailViews = [:]
        tailConstraints = [:]
        lastGeneration = -1
        footerHost = nil
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        document = nil
        footer = nil
        streaming = nil
        revealState = nil
        lastLayoutWidth = -1
        #if DEBUG
        debugStreamingRowHeight = nil
        #endif
        removeBlockViews()
    }
}
#endif
