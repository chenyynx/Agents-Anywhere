#if canImport(UIKit)
import UIKit

/// The assistant body cell for M2. It hosts a vertical stack of TextKit 2
/// block text views with the product's 12pt block spacing. The row height is
/// owned by `TimelineListLayout` (policy `.measured`); the cell only renders
/// the blocks the layout already measured.
final class AssistantMarkdownCell: UICollectionViewCell {
    static let reuseIdentifier = "AssistantMarkdownCell"

    private let stack = UIStackView()
    private var blocks: [(view: AssistantMarkdownBlockTextView, content: NSAttributedString)] = []
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
        clearContent()
        for block in document.blocks {
            guard case .text(let attributed) = block else { continue }
            let view = AssistantMarkdownBlockTextView()
            view.attributedText = attributed
            stack.addArrangedSubview(view)
            blocks.append((view, attributed))
        }
        // The width may already be known from a reused cell; otherwise
        // `layoutSubviews` installs the constraints on the first pass.
        updateHeightConstraints(for: contentView.bounds.width)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateHeightConstraints(for: contentView.bounds.width)
    }

    /// `UITextView`'s intrinsic height needs a laid-out width, but Auto Layout
    /// fitting (`systemLayoutSizeFitting`) asks before proposing one. Pin each
    /// block to the height the shared TextKit 2 measurement returns, so the
    /// cell's content fitting and the layout's stored height are one number.
    private func updateHeightConstraints(for width: CGFloat) {
        guard width > 0, abs(width - lastLayoutWidth) > 0.5 else { return }
        lastLayoutWidth = width
        NSLayoutConstraint.deactivate(heightConstraints)
        heightConstraints = blocks.map { block in
            let height = AssistantMarkdownTextLayout.height(
                of: block.content,
                width: width,
                displayScale: traitCollection.displayScale)
            let constraint = block.view.heightAnchor.constraint(equalToConstant: height)
            constraint.isActive = true
            return constraint
        }
    }

    private func clearContent() {
        NSLayoutConstraint.deactivate(heightConstraints)
        heightConstraints = []
        blocks = []
        lastLayoutWidth = -1
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        clearContent()
    }
}
#endif
