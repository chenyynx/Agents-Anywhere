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
                       measured: Bool) -> CGFloat {
        let rows = CodeMessageBuilder.rows(for: group.rows.map(\.value), profile: profile)
        return height(rows: rows,
                      width: width, typography: typography, traits: traits,
                      measured: measured)
    }

    static func height(rows: [CodeMessageRow],
                       width: CGFloat,
                       typography: TimelineTypographySnapshot,
                       traits: UITraitCollection?,
                       measured: Bool) -> CGFloat {
        CodeRowHeightPlan.height(
            rows: planRows(rows, width: width, typography: typography,
                           traits: traits, measured: measured),
            metrics: metrics(traits: traits))
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
                                 measured: Bool) -> [CodeRowHeightPlan.Row] {
        let width = TimelineHeightKey.quantize(width)
        var planRows: [CodeRowHeightPlan.Row] = []
        planRows.reserveCapacity(rows.count)
        for row in rows {
            var blocks: [CodeRowHeightPlan.Block] = []
            if row.role == .user {
                var texts: [String] = []
                for block in row.blocks {
                    switch block {
                    case .reasoning:
                        continue
                    case let .text(_, text):
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            texts.append(text)
                        }
                    case let .toolCalls(segments):
                        blocks.append(.tools(segments: segments.count))
                    case .other:
                        blocks.append(.other)
                    }
                }
                if !texts.isEmpty {
                    blocks.insert(.text(height: userBubbleTextHeight(
                        texts.joined(separator: "\n\n"), width: width, traits: traits)), at: 0)
                }
            } else {
                for block in row.blocks {
                    switch block {
                    case .reasoning:
                        continue
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

    /// The metrics `CodeMessageRowView` actually lays out with. The tool line
    /// box is a `@ScaledMetric(relativeTo: .footnote)` value, so it must be
    /// scaled with the row's trait collection instead of using 24 pt.
    private static func metrics(traits: UITraitCollection?) -> CodeRowHeightPlan.Metrics {
        let lineHeight = UIFontMetrics(forTextStyle: .footnote)
            .scaledValue(for: CodePageTheme.toolRowLineHeight, compatibleWith: traits)
        return CodeRowHeightPlan.Metrics(
            blockPadding: 2 * CodePageTheme.segmentVerticalPadding,
            blockSpacing: CodePageTheme.segmentVerticalPadding,
            rowSpacing: CodePageTheme.blockSpacing,
            toolLineHeight: lineHeight,
            toolButtonPadding: CodePageTheme.toolRowButtonPadding,
            otherLineHeight: CodePageTheme.toolRowLineHeight,
            rowMargins: CodePageTheme.rowMarginTop + CodePageTheme.rowMarginBottom)
    }

    private static func assistantTextHeight(_ text: String, width: CGFloat,
                                            typography: TimelineTypographySnapshot,
                                            traits: UITraitCollection?) -> CGFloat {
        guard let document = AssistantMarkdownDocumentParser.make(
            text: text, resolvesFileReferences: true, typography: typography) else {
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
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
        let lineSpacing = UIFontMetrics(forTextStyle: .body)
            .scaledValue(for: CodePageTheme.userBubbleLineSpacing, compatibleWith: traits)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .paragraphStyle: paragraph,
        ])
        // The bubble renders through Textual's `InlineText`; its line height
        // and wrapping follow TextKit 2, not `NSString.boundingRect`. The old
        // bounding-rect measurement over-reserved 6.7–8.3 pt on the CJK
        // fixtures (code-profile gate 2026-10-23). The assistant body uses the
        // same TextKit engine and matches the rendered Textual block within
        // 0.7 pt, so the bubble uses it too.
        let scale = traits?.displayScale ?? 2
        let height = AssistantMarkdownTextLayout.height(
            of: attributed, width: available, displayScale: scale)
        // SwiftUI's `lineSpacing` is the gap *between* lines. The TextKit
        // usage height includes one trailing gap after the last line; the
        // rendered bubble does not (the gate measured 6.7–8.3 pt of
        // over-reservation before this subtraction).
        return ceil(max(0, height - lineSpacing))
            + 2 * CodePageTheme.userBubbleVerticalPadding
    }
}
