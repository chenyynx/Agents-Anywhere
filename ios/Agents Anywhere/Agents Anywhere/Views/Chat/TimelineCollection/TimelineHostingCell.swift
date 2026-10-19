import SwiftUI
import UIKit

/// One top-level timeline item.
///
/// Height comes from `TimelineListLayout` for measured rows: the cell returns
/// the proposed attributes untouched, so `UIHostingConfiguration`'s
/// self-sizing cannot override the measurement layer. Fold/inline-notice/tail
/// rows are the controlled exceptions and defer to the superclass's fitting
/// pass; the layout decides whether to accept that preferred height.
final class TimelineHostingCell: UICollectionViewCell {
    static let reuseIdentifier = "TimelineHostingCell"

    private var policy: TimelineRowHeightPolicy = .measured

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        contentView.backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ view: AnyView, policy: TimelineRowHeightPolicy) {
        self.policy = policy
        contentConfiguration = UIHostingConfiguration {
            view
        }
        .margins(.all, 0)
        .minSize(width: 0, height: 0)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        contentConfiguration = nil
        policy = .measured
    }

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        guard policy.acceptsPreferredHeight else { return layoutAttributes }
        return super.preferredLayoutAttributesFitting(layoutAttributes)
    }
}
