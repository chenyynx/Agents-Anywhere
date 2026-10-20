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
    // only the tail is re-hosted and re-measured.
    private var streaming: AssistantStreamingDocument?
    private var streamingReveal = false
    private var stableIDs: [AssistantBlockID] = []
    private var stableViews: [AssistantBlockID: UIView] = [:]
    private var stableConstraints: [AssistantBlockID: NSLayoutConstraint] = [:]
    private var tailHost: UIHostingController<ChatMarkdownView>?
    private var tailConstraint: NSLayoutConstraint?
    private var lastGeneration = -1
    #if DEBUG
    private(set) var debugStableViewsBuilt = 0
    private(set) var debugTailUpdates = 0

    /// The tail host's own layout height. The gate compares it with the
    /// constraint derived from the TextKit measurement; this is the only place
    /// the two engines can disagree inside the cell.
    var debugTailFitHeight: CGFloat? {
        guard let tailHost, contentView.bounds.width > 0 else { return nil }
        return tailHost.sizeThatFits(in: CGSize(
            width: contentView.bounds.width,
            height: .greatestFiniteMagnitude)).height
    }

    var debugTailConstraintHeight: CGFloat? { tailConstraint?.constant }
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
        self.streamingReveal = false
        lastGeneration = -1
        lastLayoutWidth = -1
        rebuildIfPossible()
    }

    /// Streaming row: settled blocks are TextKit views that survive batches;
    /// the open tail is hosted by the existing reveal view so the glyph
    /// animation does not change.
    func configure(streaming: AssistantStreamingDocument, reveal: Bool) {
        self.document = nil
        self.footer = nil
        self.streaming = streaming
        self.streamingReveal = reveal
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

    /// Settled blocks are appended once; the tail host is the only subview
    /// replaced on each batch. A new generation (correction), a width change,
    /// or a stable set that is not a prefix of the previous one rebuilds.
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
                let insertion = tailHost.map { host in
                    stack.arrangedSubviews.firstIndex(where: { $0 === host.view })
                        ?? stack.arrangedSubviews.count
                } ?? stack.arrangedSubviews.count
                stack.insertArrangedSubview(made.view, at: insertion)
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

        // The same collapsed-margin rule the measurement and the static cell
        // use. The last settled block keeps its spacing before the tail.
        for (index, id) in stableIDs.enumerated() {
            guard let view = stableViews[id] else { continue }
            let spacing = index + 1 < streaming.document.blocks.count
                ? AssistantMarkdownTextLayout.topLevelSpacing(
                    after: index, in: streaming.document)
                : 0
            stack.setCustomSpacing(spacing, after: view)
        }

        updateTail(streaming, width: width)
    }

    private func updateTail(_ streaming: AssistantStreamingDocument, width: CGFloat) {
        let start = min(streaming.stableBlockCount,
                        streaming.document.blocks.count)
        let range = start..<streaming.document.blocks.count
        let height = tailHeight(streaming, range: range, width: width)
        if range.isEmpty {
            if let tailHost {
                stack.removeArrangedSubview(tailHost.view)
                tailHost.view.removeFromSuperview()
                tailConstraint?.isActive = false
                self.tailHost = nil
                self.tailConstraint = nil
            }
            return
        }

        let host: UIHostingController<ChatMarkdownView>
        if let tailHost {
            host = tailHost
        } else {
            host = UIHostingController(rootView: ChatMarkdownView(
                text: streaming.tailText,
                isStreaming: streamingReveal,
                resolvesFileReferences: true))
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false
            host.view.clipsToBounds = true
            stack.addArrangedSubview(host.view)
            let constraint = host.view.heightAnchor.constraint(equalToConstant: height)
            constraint.isActive = true
            self.tailHost = host
            self.tailConstraint = constraint
        }
        host.rootView = ChatMarkdownView(
            text: streaming.tailText,
            isStreaming: streamingReveal,
            resolvesFileReferences: true)
        tailConstraint?.constant = height
        #if DEBUG
        debugTailUpdates += 1
        #endif
    }

    private func tailHeight(_ streaming: AssistantStreamingDocument,
                            range: Range<Int>,
                            width: CGFloat) -> CGFloat {
        guard !range.isEmpty else { return 0 }
        var total: CGFloat = 0
        for index in range {
            if index > range.lowerBound {
                total += AssistantMarkdownTextLayout.topLevelSpacing(
                    after: index - 1, in: streaming.document)
            }
            total += AssistantMarkdownTextLayout.height(
                of: streaming.document.blocks[index], width: width,
                displayScale: traitCollection.displayScale)
        }
        return total
    }

    private func removeBlockViews() {
        NSLayoutConstraint.deactivate(heightConstraints)
        NSLayoutConstraint.deactivate(Array(stableConstraints.values))
        tailConstraint?.isActive = false
        heightConstraints = []
        stableIDs = []
        stableViews = [:]
        stableConstraints = [:]
        tailHost = nil
        tailConstraint = nil
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
        streamingReveal = false
        lastLayoutWidth = -1
        removeBlockViews()
    }
}
#endif
