import SwiftUI
import UIKit

/// One top-level timeline item.
///
/// Height follows the official hosted-cell contract: a row that has no real
/// measurement yet may self-size once through
/// `preferredLayoutAttributesFitting`; once `isMeasured` is true the cell
/// returns the layout's proposed attributes untouched. Later content changes
/// arrive as the SwiftUI geometry value itself (`onContentHeightReport`),
/// exactly like the official `_GeometryActionModifier` → `rowMeasured` chain;
/// the controller accepts it only when the height changed.
final class TimelineHostingCell: UICollectionViewCell {
    static let reuseIdentifier = "TimelineHostingCell"

#if AA_TIMELINE_PROBE
    /// Set by `configure`; the first layout after it closes the row's first
    /// render window. This is the one number that answers "how long does a
    /// newly visible message row cost before it can be drawn".
    private var probeConfiguredAt: TimeInterval = 0

    /// SwiftUI hosting layout runs inside this call, off the scroll callback
    /// stack. Timing it is how the probe tells a UIKit/SwiftUI layout stall
    /// apart from a stall in the controller's own passes.
    override func layoutSubviews() {
        let probeStart = CACurrentMediaTime()
        TimelineProbeStore.shared.enterSection("cell.hostingLayout")
        super.layoutSubviews()
        let probeLayout = CACurrentMediaTime() - probeStart
        TimelineProbeStore.shared.noteStage("cell.hostingLayout", seconds: probeLayout)
        // Short rows are the tool/status rows the device reports as one drop
        // per entry; split them out so the report can tell whether the cost is
        // in the hosting layout of those rows.
        if bounds.height > 0, bounds.height <= 240 {
            TimelineProbeStore.shared.noteStage("cell.shortHosting", seconds: probeLayout)
        }
        TimelineProbeStore.shared.noteScrollSegment("cell.hostingLayout", since: probeStart)
        TimelineProbeStore.shared.leaveSection()
        if probeConfiguredAt > 0 {
            TimelineProbeStore.shared.noteScrollSegment("row.firstRender",
                                                        since: probeConfiguredAt)
            probeConfiguredAt = 0
        }
    }
#endif

    /// The hosting content's laid-out height, in row coordinates, already
    /// rounded up. This **is** the measurement: the official row wraps its
    /// content in `_GeometryActionModifier(value: GeometryProxy.size)`
    /// (`0x100b7d97c`, value `0x100d540ac`), the action reads `size.height`
    /// plus the row's vertical margins (`0x1019edf08` → `0x1019ece34`) and
    /// the surface accepts it only when it changed (`0x101a4081c`). SwiftUI
    /// performs this action on layout changes, not on a timer, so it costs
    /// one measurement per content change instead of a repeated fit.
    var onContentHeightReport: ((CGFloat) -> Void)?

    /// The hosted content laid out taller than the cell's own frame — the row
    /// is drawing inside a height that no longer fits it. Called at most once
    /// a second per cell with (content height, frame height); the controller
    /// turns it into a `timeline.row.overflow` line so a stuck-estimate row
    /// can be named from an exported log (pp 2026-11-28: streaming text's
    /// first line sat on the tool row; the height cache plateaus while the
    /// content keeps growing).
    var onContentOverflowReport: ((CGFloat, CGFloat) -> Void)?
    private var lastOverflowReportAt: CFTimeInterval = 0

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
    /// The item this cell was last configured for. The controller's visible
    /// reconcile uses it to catch a cell that UIKit moved across index paths
    /// without rebinding: a cell still hosting the previous item draws that
    /// item's content into the new item's frame (device probe 2026-10-31
    /// 05:56: a 53 pt row's cell stretched to 1821 pt → most of the screen
    /// blank).
    private(set) var itemID: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        contentView.backgroundColor = .clear
        // Until the measurement (hosting geometry or the one first fit)
        // arrives, a fixed row can be shorter than its SwiftUI content. Clip
        // it instead of letting the overflow draw over the following row.
        contentView.clipsToBounds = true
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ view: AnyView, itemID: String, policy: TimelineRowHeightPolicy,
                   isMeasured: Bool, reportsContentHeight: Bool,
                   seededHeight: CGFloat? = nil) {
#if AA_TIMELINE_PROBE
        probeConfiguredAt = CACurrentMediaTime()
        let configureStart = CACurrentMediaTime()
        defer {
            TimelineProbeStore.shared.noteStage(
                "cell.configure", seconds: CACurrentMediaTime() - configureStart)
        }
#endif
        self.itemID = itemID
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
                let measured = content.onGeometryChange(for: CGFloat.self, of: { proxy in
                    proxy.size.height - proxy.safeAreaInsets.top
                        - proxy.safeAreaInsets.bottom
                }) { [weak self] height in
                    guard let self, self.configurationToken == token else { return }
                    // Official `ceil` before the value reaches the surface.
                    let measured = ceil(height)
                    guard measured.isFinite, measured > 0 else { return }
                    self.noteContentOverflow(contentHeight: measured)
                    self.onContentHeightReport?(measured)
                }
                // Pin the row's content to the top of its cell with an
                // explicit frame, then clip there. A streaming row's height
                // momentarily trails its content (the log's `timeline.row.
                // overflow`: frame 29 pt while the row already draws 44–109),
                // and `UIHostingConfiguration`'s own placement centres the
                // taller content — the row's first line rides up and its top
                // is cut until the next height apply (pp 2026-11-28
                // 「刚回复时第一行被往上挤一下、裁掉一半、1–2 秒正常」).
                // A `GeometryReader` takes the cell's proposed size, so the
                // root is never taller than the cell and no placement can
                // shift it; the content inside is fixed at the top and the
                // overflow leaves through the clipped bottom edge only.
                //
                // The geometry probe stays on the inner content: it must keep
                // measuring the content's ideal height, never the cell frame
                // (feeding the cell's own frame back would make every height
                // application produce another report for the same value).
                GeometryReader { proxy in
                    measured
                        .frame(width: proxy.size.width, height: proxy.size.height,
                               alignment: .top)
                        .clipped()
                }
            } else {
                // The Chat rows keep the controller's visible-cell polling;
                // installing a geometry observer on every scroll cell would
                // only add layout work. They keep the hugging layout the
                // legacy preferred-fit path expects.
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
        itemID = nil
        policy = .measured
        isMeasured = false
        seededHeight = nil
        onContentHeightReport = nil
        onContentOverflowReport = nil
        lastOverflowReportAt = 0
    }

    /// A geometry report taller than the cell's current frame means the row is
    /// drawing into a height that no longer fits it (the layout has not taken
    /// the new content height yet, or its cache plateaued). Throttled to one
    /// line a second: the point is to name the stuck row in an exported log,
    /// not to trace every frame.
    private func noteContentOverflow(contentHeight: CGFloat) {
        let frameHeight = bounds.height
        guard frameHeight > 1, contentHeight > frameHeight + 2 else { return }
        let now = CACurrentMediaTime()
        guard now - lastOverflowReportAt >= 1.0 else { return }
        lastOverflowReportAt = now
        onContentOverflowReport?(contentHeight, frameHeight)
    }

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
#if AA_TIMELINE_PROBE
        let fitStart = CACurrentMediaTime()
        defer {
            TimelineProbeStore.shared.noteStage(
                "cell.fit", seconds: CACurrentMediaTime() - fitStart)
        }
#endif
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
        // `onContentHeightReport` and the layout's changed-only gate, not
        // through this one-shot path.
        if let seed = seededHeight {
            let copy = layoutAttributes.copy() as! UICollectionViewLayoutAttributes
            copy.size.height = seed
            return copy
        }
        return super.preferredLayoutAttributesFitting(layoutAttributes)
    }
}
