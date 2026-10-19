#if canImport(UIKit)
import UIKit

/// The assistant body cell for M2. It hosts a vertical stack of TextKit 2
/// block text views with the product's 12pt block spacing. The row height is
/// owned by `TimelineListLayout` (policy `.measured`); the cell only renders
/// the blocks the layout already measured.
final class AssistantMarkdownCell: UICollectionViewCell {
    static let reuseIdentifier = "AssistantMarkdownCell"

    private let stack = UIStackView()

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
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ document: AssistantMarkdownDocument) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for block in document.blocks {
            guard case .text(let attributed) = block else { continue }
            let view = AssistantMarkdownBlockTextView()
            view.attributedText = attributed
            stack.addArrangedSubview(view)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }
}
#endif
