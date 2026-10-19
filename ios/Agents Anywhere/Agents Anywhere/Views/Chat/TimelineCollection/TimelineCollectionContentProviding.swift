import SwiftUI

/// The product data the collection controller needs. C4 adapts the chat model
/// to this protocol; the C3 gate implements it with synthetic rows, so the
/// container and measurement machinery are exercised without a live session.
@MainActor
protocol TimelineCollectionContentProviding: AnyObject {
    /// Bumped whenever the item list or any signature-bearing field changes.
    /// The representable's update calls `reloadFromContent` on every SwiftUI
    /// evaluation; the controller only re-applies when this value moves.
    var contentGeneration: Int { get }
    var itemCount: Int { get }
    func item(at index: Int) -> TimelineListItem
    func contentSignature(for item: TimelineListItem) -> TimelineContentSignature
    func heightKey(for item: TimelineListItem, width: CGFloat) -> TimelineHeightKey
    func estimateKind(for item: TimelineListItem) -> TimelineHeightEstimateKind
    func heightPolicy(for item: TimelineListItem) -> TimelineRowHeightPolicy
    func measurementContent(for item: TimelineListItem) -> TimelineMeasurementContent

    /// The real row view, used both by the cell and by the offscreen measurer.
    /// Both must build the same hierarchy; that equality is the C3
    /// measurement-consistency gate.
    func rowView(for item: TimelineListItem) -> AnyView

    /// Row ids contained in a top-level item. A group contains several; the
    /// history anchor maps a row id back to its group item.
    func rowIDs(in item: TimelineListItem) -> [String]
    func item(containingRow rowID: String) -> TimelineListItem?

    func interactionState() -> TimelineLayoutInteractionState
}
