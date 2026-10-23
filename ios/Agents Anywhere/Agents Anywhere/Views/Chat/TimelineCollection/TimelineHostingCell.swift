import SwiftUI
import UIKit

/// One top-level timeline item.
///
/// Height follows the official hosted-cell contract: a row that has no real
/// measurement yet may self-size once through
/// `preferredLayoutAttributesFitting`; once `isMeasured` is true the cell
/// returns the layout's proposed attributes untouched. Later content changes
/// are reported through `onContentHeightChange`, which the layout turns into
/// its own height application.
final class TimelineHostingCell: UICollectionViewCell {
    static let reuseIdentifier = "TimelineHostingCell"

    /// The hosting content changed its laid-out size. This is a **trigger**,
    /// not a measurement: the row's height is always read back from
    /// `systemLayoutSizeFitting` at a settled moment (the official first-fit
    /// call), because SwiftUI reports intermediate sizes while it lays out.
    var onContentChanged: (() -> Void)?

    private var policy: TimelineRowHeightPolicy = .measured
    /// Whether the height cache holds a measured/precalc height for the row's
    /// current key. Read from the layout attributes at configuration time.
    private var isMeasured = false
    /// A geometry action from a previous configuration must not report its
    /// old content height into the row that now occupies this cell.
    private var configurationToken = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        contentView.backgroundColor = .clear
        // Until the visible-cell settle reports the real height, a fixed row
        // can be shorter than its SwiftUI content. Clip it instead of letting
        // the overflow draw over the following row.
        contentView.clipsToBounds = true
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ view: AnyView, policy: TimelineRowHeightPolicy,
                   isMeasured: Bool, reportsContentHeight: Bool) {
        self.policy = policy
        self.isMeasured = isMeasured
        configurationToken &+= 1
        let token = configurationToken
        contentConfiguration = UIHostingConfiguration {
            // The cell may still carry the estimate when the async content
            // first parses. Without a vertical fixed size SwiftUI compresses
            // the row into that estimate and the row's own children overlap;
            // clip alone cannot hide that. Lay the content out at its ideal
            // height and let the cell bounds clip until the height arrives.
            let content = view
                .environment(\.collectionTimelineHeightAnimation, true)
                .fixedSize(horizontal: false, vertical: true)
            if reportsContentHeight {
                // Measure the content, never the cell bounds: feeding the
                // cell's own frame back would make every application of a
                // height produce another report for the same value. The
                // hosting window's safe area is not part of a row's height
                // (the M1 parity spike saw a 64 pt status-bar inset).
                content.onGeometryChange(for: CGFloat.self, of: { proxy in
                    proxy.size.height - proxy.safeAreaInsets.top
                        - proxy.safeAreaInsets.bottom
                }) { [weak self] _ in
                    guard let self, self.configurationToken == token else { return }
                    self.onContentChanged?()
                }
            } else {
                // The Chat rows keep the controller's visible-cell polling;
                // installing a geometry observer on every scroll cell would
                // only add layout work.
                content
            }
        }
        .margins(.all, 0)
        .minSize(width: 0, height: 0)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        configurationToken &+= 1
        contentConfiguration = nil
        policy = .measured
        isMeasured = false
        onContentChanged = nil
    }

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        // The attributes the layout just handed over are the current truth;
        // the stored flag is the configuration-time snapshot. Either one
        // saying "measured" means the layout owns the height and the cell must
        // not ask the hosting content again.
        let measured = isMeasured
            || (layoutAttributes as? TimelineListLayoutAttributes)?.isMeasured == true
        guard !measured else { return layoutAttributes }
        // Official first materialization: the unmeasured cell fits its real
        // content once. The layout accepts the result only while the original
        // attributes are unmeasured.
        return super.preferredLayoutAttributesFitting(layoutAttributes)
    }
}
