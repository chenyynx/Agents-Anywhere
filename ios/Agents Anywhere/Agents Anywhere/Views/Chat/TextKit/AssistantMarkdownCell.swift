#if canImport(UIKit)
import UIKit

/// The assistant body cell. It hosts a vertical stack of block views with the
/// product's 12pt block spacing. The row height is owned by
/// `TimelineListLayout` (policy `.measured`); the cell only renders the blocks
/// the layout already measured, installing the same heights as constraints so
/// `systemLayoutSizeFitting` reports the identical number.
final class AssistantMarkdownCell: UICollectionViewCell {
    static let reuseIdentifier = "AssistantMarkdownCell"

    private let stack = UIStackView()
    private var document: AssistantMarkdownDocument?
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

    func configure(_ document: AssistantMarkdownDocument) {
        self.document = document
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
    }

    private func removeBlockViews() {
        NSLayoutConstraint.deactivate(heightConstraints)
        heightConstraints = []
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        document = nil
        lastLayoutWidth = -1
        removeBlockViews()
    }
}
#endif
