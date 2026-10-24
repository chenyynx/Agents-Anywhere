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
    /// The height the provider already obtained from the real row content
    /// (Code groups: `CodeMessageHeightMeasurer`, hosted `ChatMarkdownView`).
    /// It seeds the cell's one self-measure for the frames before the hosted
    /// content has completed its own layout pass; the layout writes it as the
    /// row's first measurement.
    private var seededHeight: CGFloat?

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
                   isMeasured: Bool, reportsContentHeight: Bool,
                   seededHeight: CGFloat? = nil) {
        self.policy = policy
        self.isMeasured = isMeasured
        // `configurationToken` and the seed share one lifetime: a later
        // configuration must never fit with a height computed for older
        // content, even when `prepareForReuse` was skipped.
        configurationToken &+= 1
        let token = configurationToken
        self.seededHeight = seededHeight.map { ceil($0) }
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
        seededHeight = nil
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
        // content once (`CANONICAL/05-layout-scroll.md:102`), and the layout
        // accepts the result only while the original attributes are unmeasured.
        //
        // At the first fit the hosted body may not have completed its own
        // layout pass yet. The Code row is pre-parsed synchronously before
        // apply (`TimelineChatContentAdapter` builds `preparedBlocks`,
        // `CodeMessageRowView` hands them to `ChatMarkdownView(initialBlocks:)`
        // so the view skips its async `.task`), but `UIHostingConfiguration`
        // installs and lays the content out on a later pass; when the fit runs
        // before that, `super` measures the pre-layout skeleton (458 probe:
        // 598 → 54 → 598). The provider's structural measurement is taken
        // from the real row view (the `CodeMessageHeightMeasurer` equivalent
        // of the official leaf's `sizeThatFits`/`measuredSizes`), so it stands
        // in for the first fit: return that height without asking UIKit to fit
        // the skeleton. Once the content has laid out, its geometry change is
        // the correction pass (the official `rowMeasured`); it goes through
        // the layout's settled cell-fit report, not through this one-shot path.
        if let seed = seededHeight {
            let copy = layoutAttributes.copy() as! UICollectionViewLayoutAttributes
            copy.size.height = seed
            return copy
        }
        return super.preferredLayoutAttributesFitting(layoutAttributes)
    }
}
