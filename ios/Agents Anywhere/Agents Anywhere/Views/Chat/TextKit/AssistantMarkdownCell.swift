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

    static var averageMilliseconds: Double {
        count == 0 ? 0 : totalMilliseconds / Double(count)
    }

    static func reset() {
        count = 0
        totalMilliseconds = 0
        maxMilliseconds = 0
    }

    static func record(_ milliseconds: Double) {
        count += 1
        totalMilliseconds += milliseconds
        maxMilliseconds = max(maxMilliseconds, milliseconds)
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

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        contentView.clipsToBounds = true
        clipsToBounds = true
        stack.axis = .vertical
        stack.alignment = .fill
        stack.distribution = .fill
        stack.spacing = AssistantMarkdownTextLayout.blockSpacing
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

    func configure(_ document: AssistantMarkdownDocument,
                   footer: AssistantTurnFooter? = nil) {
        self.document = document
        self.footer = footer
        lastLayoutWidth = -1
        rebuildIfPossible()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = contentView.bounds.width
        if width > 0, abs(width - lastLayoutWidth) > 0.5 {
            rebuildIfPossible()
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
        removeBlockViews()
        let width = contentView.bounds.width
        lastLayoutWidth = width
        for block in document.blocks {
            let made = AssistantMarkdownBlockViewFactory.make(
                block, width: width, displayScale: traitCollection.displayScale)
            stack.addArrangedSubview(made.view)
            let constraint = made.view.heightAnchor.constraint(equalToConstant: made.height)
            constraint.isActive = true
            heightConstraints.append(constraint)
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

    private func removeBlockViews() {
        NSLayoutConstraint.deactivate(heightConstraints)
        heightConstraints = []
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
        lastLayoutWidth = -1
        removeBlockViews()
    }
}
#endif
