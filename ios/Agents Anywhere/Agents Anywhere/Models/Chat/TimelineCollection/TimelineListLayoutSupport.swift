import Foundation

/// One row's measured height, or nil when the hosting pass could not produce
/// a finite positive height. Implementations are main-thread only: the
/// collection view and its layout live there.
@MainActor protocol TimelineHeightMeasuring {
    func measure(itemID: String, width: CGFloat) -> CGFloat?
}

/// The transient scroll/interaction facts the layout needs to classify a
/// height correction. Pulled once per correction instead of threaded through
/// every call.
nonisolated struct TimelineLayoutInteractionState: Equatable {
    var isTracking = false
    var isDecelerating = false
    var keyboardTransition = false
    var suppressContentOffsetAdjustment = false
    var interactionPresented = false
    var hasArmedBottomTarget = false
    var userIsScrolling = false
    var mode: TimelineScrollState.Mode = .reading
    var streamingItemIDs: Set<String> = []

    var isAutoScrollPinning: Bool {
        TimelinePreferredAttributesDecision.isAutoScrollPinning(
            hasArmedBottomTarget: hasArmedBottomTarget,
            interactionPresented: interactionPresented,
            userIsScrolling: userIsScrolling,
            mode: mode)
    }
}

/// What the collection controller must expose to the layout. The layout never
/// reaches into the model or the SwiftUI row hierarchy directly, so the same
/// layout can be driven by the C3 integration gate with a synthetic host.
@MainActor protocol TimelineListLayoutHost: AnyObject {
    var layoutItemCount: Int { get }
    func layoutItem(at index: Int) -> TimelineListItem
    /// First timeline row the layout is currently describing. A prepend
    /// target is only valid for the update that carries that page; earlier
    /// updates must not consume it.
    var layoutFirstRowID: String? { get }
    func layoutHeightKey(for item: TimelineListItem, width: CGFloat) -> TimelineHeightKey
    func layoutEstimateKind(for item: TimelineListItem) -> TimelineHeightEstimateKind
    func layoutHeightPolicy(for item: TimelineListItem) -> TimelineRowHeightPolicy
    func layoutContentKind(for item: TimelineListItem) -> TimelineMeasurementContent
    func layoutInteractionState() -> TimelineLayoutInteractionState

    /// Called in effect order when a browse gesture settles: the pull decision
    /// first, then each parked height correction (v7 §3.4.4).
    func layoutDidSettlePull()
    /// Content height changed in `prepare`. The controller re-publishes its
    /// viewport sample and, if the bottom target is armed, re-pins. This is
    /// called synchronously from `prepare`; the implementation must not
    /// re-enter the layout (schedule work on the next main-queue turn).
    func layoutDidChangeContentHeight(_ height: CGFloat)

    /// A width change re-keyed every row and left real measurements missing.
    /// A pure rotation/split-view resize does not run an apply, so the layout
    /// must ask the host to schedule them; the host must not measure inside
    /// `prepare`.
    func layoutNeedsMeasurement(width: CGFloat)
}
