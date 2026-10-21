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

    /// The C5/M2 TextKit 2 path: a static assistant body whose blocks the
    /// controller can measure synchronously before apply. Nil means "keep the
    /// hosting cell" — unsupported blocks, streaming rows, attachments, folds
    /// and every non-assistant row return nil.
    func assistantMarkdown(for item: TimelineListItem) -> AssistantMarkdownDocument?

    /// The C5/M4 streaming path: the same TextKit cell renders settled blocks
    /// and hosts the revealing tail in the existing Markdown view. Nil means
    /// the row stays on the hosting path (unsupported blocks, attachments,
    /// notices, or a non-assistant row).
    func assistantStreamingDocument(for item: TimelineListItem) -> AssistantStreamingDocument?

    /// The reveal state for the streaming row (timeline anchor, character
    /// total, whether the text stopped growing). Kept separate from the
    /// document so frame ticks do not rebuild parsed blocks.
    func assistantStreamingReveal(for item: TimelineListItem) -> StreamingRevealState?

    /// The cell's reveal driver finished its final fade. The provider drops
    /// its reveal ownership so the next apply measures and configures the
    /// static body (which installs the turn-action footer).
    func streamingRevealDidFinish(for item: TimelineListItem)

    /// The text-only turn action footer for a TextKit assistant row. Nil for
    /// rows whose footer includes a variable-height file-change summary (those
    /// keep hosting) and for every hosting row.
    func assistantTurnFooter(for item: TimelineListItem) -> AssistantTurnFooter?

    /// The footer the TextKit cell hosts at a fixed height. Covers the action
    /// row and, from M4.3, the file-change summary. Nil keeps the row on the
    /// hosting path (or means the turn has no footer).
    func assistantFooter(for item: TimelineListItem) -> AssistantFooterHost?

    /// Row ids contained in a top-level item. A group contains several; the
    /// history anchor maps a row id back to its group item.
    func rowIDs(in item: TimelineListItem) -> [String]
    func item(containingRow rowID: String) -> TimelineListItem?

    func interactionState() -> TimelineLayoutInteractionState

    /// Both are protocol requirements (not extension-only helpers): the
    /// representable calls them through an existential, and an extension-only
    /// method would statically dispatch to the no-op default instead of the
    /// product adapter's implementation.
    func prepareForUpdate()
    func applyTypography(_ snapshot: TimelineTypographySnapshot)
}

extension TimelineCollectionContentProviding {
    /// Marks the provider's item list stale before the representable reads
    /// `contentGeneration`. The C3 gate's synthetic model wants no work here.
    func prepareForUpdate() {}

    /// The C3 synthetic model keeps every row on the hosting path.
    func assistantMarkdown(for item: TimelineListItem) -> AssistantMarkdownDocument? { nil }
    func assistantStreamingDocument(for item: TimelineListItem) -> AssistantStreamingDocument? { nil }
    func assistantStreamingReveal(for item: TimelineListItem) -> StreamingRevealState? { nil }
    func streamingRevealDidFinish(for item: TimelineListItem) {}
    func assistantTurnFooter(for item: TimelineListItem) -> AssistantTurnFooter? { nil }

    /// C3's synthetic rows and the M4 gate have no footer; the M3 gate only
    /// needs the action row, so the default wraps its `assistantTurnFooter`.
    func assistantFooter(for item: TimelineListItem) -> AssistantFooterHost? {
        guard let footer = assistantTurnFooter(for: item) else { return nil }
        return AssistantFooterHost(
            height: SessionTurnActionsRow.rowHeight,
            view: AnyView(SessionTurnActionsRow(
                copyText: footer.copyText,
                timestampText: footer.timestampText)))
    }

    /// Typography changes every height key. The C3 gate's synthetic rows keep
    /// one fixed scale and use this default; the product adapter overrides it.
    func applyTypography(_ snapshot: TimelineTypographySnapshot) {}
}
