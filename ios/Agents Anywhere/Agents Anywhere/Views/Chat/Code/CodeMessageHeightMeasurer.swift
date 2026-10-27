import Foundation
import UIKit

/// Measures one Code message row from the same parts its view draws.
///
/// The adapter calls this before a snapshot applies so a settled row never
/// corrects its height under the reader's finger. The code-profile gate calls
/// it for its rendered fixture and compares the result with the hosting
/// view's fitting height, which keeps the arithmetic honest against the real
/// SwiftUI layout.
///
/// Text blocks are measured with `AssistantMarkdownDocumentParser` +
/// `AssistantMarkdownTextLayout` — the engine the parity gate compares against
/// `ChatMarkdownView` (608.3 vs 610 pt on the shared fixture). The user bubble
/// is plain text, so it is measured directly with the body font and the same
/// scaled line spacing the bubble uses.
@MainActor
enum CodeMessageHeightMeasurer {
    static func height(group: ChatTimelineGroup,
                       profile: CodeRuntimeProfile,
                       width: CGFloat,
                       typography: TimelineTypographySnapshot,
                       traits: UITraitCollection?,
                       measured: Bool,
                       hasActionBar: Bool = false,
                       pixelSize: (V2AttachmentContent) -> CGSize? = { $0.serverPixelSize },
                       attachmentIsFailed: (V2AttachmentContent) -> Bool = { _ in false }) -> CGFloat {
        let rows = CodeMessageBuilder.rows(for: group.rows.map(\.value), profile: profile)
        return height(rows: rows,
                      width: width, typography: typography, traits: traits,
                      measured: measured, hasActionBar: hasActionBar,
                      pixelSize: pixelSize,
                      attachmentIsFailed: attachmentIsFailed)
    }

    static func height(rows: [CodeMessageRow],
                       width: CGFloat,
                       typography: TimelineTypographySnapshot,
                       traits: UITraitCollection?,
                       measured: Bool,
                       hasActionBar: Bool = false,
                       pixelSize: (V2AttachmentContent) -> CGSize? = { $0.serverPixelSize },
                       attachmentIsFailed: (V2AttachmentContent) -> Bool = { _ in false }) -> CGFloat {
        // The renderer (`CodeMarkdownTextLeaf`) resolves the same roles from
        // SwiftUI's `dynamicTypeSize`; both go through the one factory, so the
        // stored height and the drawn row use identical scaled values.
        let resolvedTypography = typography.resolvedForCodePage(
            traits: traits ?? UITraitCollection.current)
        return CodeRowHeightPlan.height(
            rows: planRows(rows, width: width, typography: resolvedTypography,
                           traits: traits, measured: measured, pixelSize: pixelSize,
                           attachmentIsFailed: attachmentIsFailed),
            metrics: metrics(traits: traits),
            hasActionBar: hasActionBar)
    }

    /// The blocks `ChatMarkdownView` parses for `text`, produced synchronously
    /// so a cell can paint its first frame instead of waiting for its async
    /// task. The adapter owns the cache; this shares the exact parse pipeline.
    static func preparedBlocks(for text: String) -> [MarkdownBlockSnapshot]? {
        try? AssistantMarkdownDocumentParser.parseBlocks(
            text: text, resolvesFileReferences: true)
    }

    /// The rendered rows projected into the pure height plan. User rows join
    /// their text blocks into one bubble; assistant rows keep one measured
    /// block per `.text` block.
    private static func planRows(_ rows: [CodeMessageRow],
                                 width: CGFloat,
                                 typography: TimelineTypographySnapshot,
                                 traits: UITraitCollection?,
                                 measured: Bool,
                                 pixelSize: (V2AttachmentContent) -> CGSize?,
                                 attachmentIsFailed: (V2AttachmentContent) -> Bool) -> [CodeRowHeightPlan.Row] {
        let width = TimelineHeightKey.quantize(width)
        var planRows: [CodeRowHeightPlan.Row] = []
        planRows.reserveCapacity(rows.count)
        for row in rows {
            var blocks: [CodeRowHeightPlan.Block] = []
            if row.role == .user {
                var texts: [String] = []
                for block in row.blocks {
                    switch block {
                    case let .reasoning(_, text, status):
                        guard status == .done,
                              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        else { continue }
                        blocks.append(.thinking)
                    case let .text(_, text):
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            texts.append(text)
                        }
                    case let .attachments(_, files, _):
                        blocks.append(contentsOf: attachmentBlocks(
                            files, pixelSize: pixelSize,
                            attachmentIsFailed: attachmentIsFailed,
                            traits: traits))
                    case let .toolCalls(segments):
                        blocks.append(.tools(segments: segments.count))
                    case .other:
                        blocks.append(.other)
                    }
                }
                if !texts.isEmpty {
                    // The official user row draws attachments above the
                    // text bubble; the plan mirrors that order (the total is
                    // the same, but the block sequence no longer lies to the
                    // gate or to a future view).
                    // The user row reserves the trailing shadow inset in the
                    // view; measure the bubble at the same width or a long
                    // line can wrap one word earlier/later than the
                    // measurement.
                    blocks.append(.text(height: userBubbleTextHeight(
                        texts.joined(separator: "\n\n"),
                        width: width - CodePageTheme.userRowShadowInset,
                        traits: traits)))
                }
            } else {
                for block in row.blocks {
                    switch block {
                    case let .reasoning(_, text, status):
                        guard status == .done,
                              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        else { continue }
                        blocks.append(.thinking)
                    case let .text(_, text):
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            continue
                        }
                        let height = measured
                            ? assistantTextHeight(text, width: width, typography: typography,
                                                  traits: traits)
                            : estimatedAssistantTextHeight(text, width: width,
                                                           typography: typography)
                        blocks.append(.text(height: height))
                    case let .attachments(_, files, _):
                        blocks.append(contentsOf: attachmentBlocks(
                            files, pixelSize: pixelSize,
                            attachmentIsFailed: attachmentIsFailed,
                            traits: traits))
                    case let .toolCalls(segments):
                        blocks.append(.tools(segments: segments.count))
                    case .other:
                        blocks.append(.other)
                    }
                }
            }
            if !blocks.isEmpty { planRows.append(CodeRowHeightPlan.Row(blocks: blocks)) }
        }
        return planRows
    }

    /// The attachment blocks one `.attachments` model block draws, in draw
    /// order: the image grid, then the failed cards, then the successful file
    /// grid (CLOSURE.md §4 / `attachment-file-card.md` §0). They are siblings
    /// of the same 8 pt stack, so `CodeRowHeightPlan` puts one block gap
    /// between them exactly as the row's `VStack` does.
    ///
    /// `pixelSize` lets the page prefer the locally decoded preview size over
    /// the server's reported dimensions. The settled row resolves both through
    /// the same `ChatAttachmentStore`, so the measured height and the drawn
    /// tile box cannot disagree. `attachmentIsFailed` pulls failed documents
    /// out of the file grid and prices their cards. The defaults keep the
    /// ClientCore geometry usable without a store (tests and the offscreen gate).
    private static func attachmentBlocks(
        _ files: [V2AttachmentContent],
        pixelSize: (V2AttachmentContent) -> CGSize?,
        attachmentIsFailed: (V2AttachmentContent) -> Bool,
        traits: UITraitCollection?
    ) -> [CodeRowHeightPlan.Block] {
        let cardHeight = failedCardHeight(traits: traits)
        var blocks: [CodeRowHeightPlan.Block] = []
        for height in CodeAttachmentLayout.blockHeights(
            files: files, pixelSize: pixelSize,
            isFailed: attachmentIsFailed,
            failedCardHeight: { _ in cardHeight }) {
            blocks.append(.attachments(height: height))
        }
        return blocks
    }

    /// The card's line heights are `@ScaledMetric`s relative to the same
    /// styles (`subheadline` for name, `callout` for artifactType), so the
    /// measured card and the drawn card scale together.
    private static func failedCardHeight(traits: UITraitCollection?) -> CGFloat {
        let nameLine = UIFontMetrics(forTextStyle: .subheadline)
            .scaledValue(for: 21, compatibleWith: traits)
        let typeLine = UIFontMetrics(forTextStyle: .callout)
            .scaledValue(for: 18.2, compatibleWith: traits)
        return CodeAttachmentLayout.failedCardHeight(
            nameLineHeight: nameLine, typeLineHeight: typeLine)
    }

    /// The metrics `CodeMessageRowView` actually lays out with. The tool line
    /// box is a `@ScaledMetric(relativeTo: .footnote)` value, so it must be
    /// scaled with the row's trait collection instead of using 24 pt.
    private static func metrics(traits: UITraitCollection?) -> CodeRowHeightPlan.Metrics {
        let lineHeight = UIFontMetrics(forTextStyle: .footnote)
            .scaledValue(for: CodePageTheme.toolRowLineHeight, compatibleWith: traits)
        return CodeRowHeightPlan.Metrics(
            blockSpacing: CodePageTheme.blockGap,
            rowSpacing: CodePageTheme.interMessageSpacing,
            toolLineHeight: lineHeight,
            toolButtonPadding: CodePageTheme.toolRowButtonPadding,
            otherLineHeight: CodePageTheme.toolRowLineHeight,
            rowMargins: CodePageTheme.rowMarginTop + CodePageTheme.rowMarginBottom)
    }

    private static func assistantTextHeight(_ text: String, width: CGFloat,
                                            typography: TimelineTypographySnapshot,
                                            traits: UITraitCollection?) -> CGFloat {
        guard let document = AssistantMarkdownDocumentParser.make(
            text: text, resolvesFileReferences: true, typography: typography,
            codeStyle: CodePageTheme.codeCardStyle(
                category: (traits ?? UITraitCollection.current)
                    .preferredContentSizeCategory))?
            .applyingCodePageTextColors() else {
            return estimatedAssistantTextHeight(text, width: width, typography: typography)
        }
        let scale = traits?.displayScale ?? 2
        return ceil(AssistantMarkdownTextLayout.measure(
            document, width: width, displayScale: scale))
    }

    /// The streaming fallback. No 20% cushion: the Code estimate is assembled
    /// from exact structural parts, and the cushion was itself reserving a
    /// fifth of a screen the first fit had to take back.
    private static func estimatedAssistantTextHeight(_ text: String, width: CGFloat,
                                                     typography: TimelineTypographySnapshot) -> CGFloat {
        TimelineHeightEstimate.height(
            rows: [TimelineHeightEstimate.TextRow(text: text)], width: width,
            bodySize: typography.body, lineSpacing: typography.lineSpacing,
            paragraphSpacing: typography.paragraphSpacing,
            minimum: 0, cushion: 1)
    }

    /// The user bubble is plain `Text` in a 36 pt opposite gutter with 16 pt
    /// horizontal padding; the vertical padding is part of the bubble.
    private static func userBubbleTextHeight(_ text: String, width: CGFloat,
                                             traits: UITraitCollection?) -> CGFloat {
        let available = max(1, width
            - CodePageTheme.userBubbleLeadingGutter
            - 2 * CodePageTheme.userBubbleHorizontalPadding)
        // The renderer (`CodeUserBubbleText`) and this measurement share one
        // attributed-string builder and one TextKit call, so the bubble can
        // never correct itself after display (the Textual/TextKit split was
        // the code-profile gate's 3.67 pt delta).
        let scale = traits?.displayScale ?? 2
        let height = CodeUserBubbleTextMetrics.height(
            text: text, width: available, displayScale: scale, traits: traits)
        return height + 2 * CodePageTheme.userBubbleVerticalPadding
    }
}
