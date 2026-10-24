#if canImport(UIKit)
import SwiftUI
import Textual
import UIKit

/// A static assistant reply prepared for the TextKit 2 cell.
///
/// M3 renders the structures the product actually emits: paragraphs and
/// headings (M2), unordered/ordered lists with nesting, and block quotes.
/// Code blocks, tables and attachments still make the whole row fall back to
/// the hosting path until their own M3 steps land; a half-rendered reply would
/// show a mix of two visual systems.
struct AssistantMarkdownDocument {
    let blocks: [AssistantMarkdownBlock]
    /// One entry per top-level block: its `MarkdownBlockSnapshot` index. The
    /// legacy renderer puts `VStack(spacing: 12)` between snapshots, while
    /// blocks inside one snapshot use Textual's collapsed margins.
    let blockGroups: [Int]
    let plainTextLength: Int

    /// Recursive kind census. The gate asserts the fixture really produced the
    /// structures it claims to exercise, not just a paragraph that happened to
    /// pass the height check.
    /// Character total the reveal timeline anchors on (see
    /// `AssistantMarkdownBlock.characterCount`).
    var revealCharacterCount: Int {
        blocks.reduce(0) { $0 + $1.characterCount }
    }

    var blockCounts: [String: Int] {
        var counts: [String: Int] = [:]
        func walk(_ blocks: [AssistantMarkdownBlock]) {
            for block in blocks {
                switch block {
                case .text:
                    counts["text", default: 0] += 1
                case .list(let list):
                    counts["list", default: 0] += 1
                    for item in list.items { walk(item.blocks) }
                case .quote(let quote):
                    counts["quote", default: 0] += 1
                    walk(quote.blocks)
                case .code:
                    counts["code", default: 0] += 1
                case .table:
                    counts["table", default: 0] += 1
                case .image:
                    counts["image", default: 0] += 1
                case .math:
                    counts["math", default: 0] += 1
                case .divider:
                    counts["divider", default: 0] += 1
                }
            }
        }
        walk(blocks)
        return counts
    }
}

/// A running-text block. `headingLevel` is kept because Textual gives headings
/// an 8pt bottom margin while body paragraphs have none.
struct AssistantTextBlock {
    let attributed: NSAttributedString
    let headingLevel: Int?
}

/// Block tree mirroring Textual's `BlockContent`. Nested lists and quotes are
/// containers, not flattened markers, because the product's indentation,
/// marker column and quote rule all depend on the parent column's width.
enum AssistantMarkdownBlock {
    case text(AssistantTextBlock)
    case list(AssistantListBlock)
    case quote(AssistantQuoteBlock)
    case code(AssistantCodeBlock)
    case table(AssistantTableBlock)
    case image(AssistantImageBlock)
    case math(AssistantMathBlock)
    case divider

    /// Stable label for DEBUG build-cost instrumentation.
    var kindName: String {
        switch self {
        case .text: return "text"
        case .list: return "list"
        case .quote: return "quote"
        case .code: return "code"
        case .table: return "table"
        case .image: return "image"
        case .math: return "math"
        case .divider: return "divider"
        }
    }

    /// Rendered UTF-16 length. The reveal cursor counts characters of the
    /// blocks that are on screen (the official controller anchors on the sum
    /// of its block lengths), not the raw Markdown source.
    ///
    /// Image and math blocks render as one atomic attachment, so they count
    /// as one character. The legacy renderer counted the alt/label text,
    /// which only changes the reveal pacing, not the visible result.
    var characterCount: Int {
        switch self {
        case .text(let text):
            return text.attributed.length
        case .list(let list):
            return list.items.reduce(0) { total, item in
                total + item.blocks.reduce(0) { $0 + $1.characterCount }
            }
        case .quote(let quote):
            return quote.blocks.reduce(0) { $0 + $1.characterCount }
        case .code(let code):
            return code.code.length
        case .table(let table):
            return table.rows.reduce(0) { total, row in
                total + row.reduce(0) { $0 + $1.length }
            }
        case .image, .math, .divider:
            return 1
        }
    }
}

/// One Markdown image that occupies its own paragraph. The reserved box is
/// the legacy attachment's footprint (`ChatMarkdownImageAttachment`), resolved
/// against the column the same way Textual does, so measurement never waits
/// for the network.
struct AssistantImageBlock {
    let url: URL
    let description: String
    let isFileReference: Bool

    func reservedSize(columnWidth: CGFloat) -> CGSize {
        let width = min(420, max(0, columnWidth))
        // `[pp]` the legacy attachment reserves a 4:3 box for remote images
        // and a 68pt chip for a session file reference.
        return CGSize(width: width, height: isFileReference ? 68 : width * 0.75)
    }
}

/// One block-level formula (`$$…$$`). Inline formulas stay attachments inside
/// a text block; a display formula gets its own centered block the way
/// Textual's `MathBlock` does.
struct AssistantMathBlock {
    let latex: String
    /// The surrounding body size; the bridge applies Textual's 1.2 scale.
    let fontSize: CGFloat

    func metrics(columnWidth: CGFloat) -> TextualMath.Metrics {
        TextualMath.metrics(latex: latex, isBlock: true,
                            fontSize: fontSize, proposalWidth: columnWidth)
    }
}

struct AssistantListBlock {
    enum Marker {
        case bullet
        case ordered(Int)
    }

    struct Item {
        let marker: Marker
        /// A list item may hold more than one block (for example a paragraph
        /// followed by a nested list); the marker aligns with the first one and
        /// the rest sit inside the item's text column.
        let blocks: [AssistantMarkdownBlock]
    }

    let items: [Item]
    /// Content leading for a bullet item: marker centre + half bullet + gap.
    let indent: CGFloat
    let markerGap: CGFloat
    let bulletSize: CGFloat
    let bulletCenterX: CGFloat
    let itemSpacing: CGFloat
    let innerSpacing: CGFloat
    let bodySize: CGFloat
    let markerColor: UIColor

    /// The product's decimal marker is a trailing-aligned label with a minimum
    /// one-em width, so its column is wider than a bullet's. Measurement and
    /// rendering both go through this method.
    func contentIndent(for marker: Marker) -> CGFloat {
        switch marker {
        case .bullet:
            return indent
        case .ordered(let ordinal):
            return orderedMarkerWidth(ordinal) + markerGap
        }
    }

    func orderedMarkerWidth(_ ordinal: Int) -> CGFloat {
        let font = UIFont.monospacedDigitSystemFont(ofSize: bodySize, weight: .regular)
        let width = ("\(ordinal)." as NSString).size(withAttributes: [.font: font]).width
        return max(bodySize, ceil(width))
    }
}

struct AssistantQuoteBlock {
    let blocks: [AssistantMarkdownBlock]
    /// Leading inset from the quote edge to its content; the rule occupies the
    /// first `barWidth` points of it.
    let inset: CGFloat
    let barWidth: CGFloat
    let innerSpacing: CGFloat
}

/// A footer hosted under the TextKit body at a fixed height.
///
/// The height excludes the spacing between the reply and the footer (the
/// cell installs `AssistantFooterMetrics.groupSpacing` itself). It comes from
/// legacy view constants, never from a fitting pass, so a slow or pending
/// footer can never collapse or grow the row after layout.
struct AssistantFooterHost {
    let height: CGFloat
    let view: AnyView
}

/// The copy/like/retry footer of a finished turn, reduced to the data the
/// TextKit cell needs. The view is the product's own `SessionTurnActionsRow`,
/// hosted at a fixed height so the footer never participates in fitting.
struct AssistantTurnFooter {
    let copyText: String
    let timestampText: String

    /// `SessionTimelineGroupView` puts a 4pt VStack gap between the reply and
    /// its footer; the action row itself is fixed by `SessionTurnActionsRow`.
    static let topSpacing: CGFloat = 4
    static var height: CGFloat { topSpacing + SessionTurnActionsRow.rowHeight }
}

/// A fenced code block. The code is laid out without wrapping inside a
/// horizontal scroll, so its height does not depend on the column width; the
/// card's header and padding are design constants from `ChatMarkdownCodeBlock`.
struct AssistantCodeBlock {
    let code: NSAttributedString
    let language: String?
    let headerHeight: CGFloat
    let contentPadding: CGFloat
    let cornerRadius: CGFloat
    /// Optional card chrome. `nil` keeps the Chat palette; the Code leaf
    /// supplies the official card values.
    var fillColor: UIColor? = nil
    var borderColor: UIColor? = nil
    var titleColor: UIColor? = nil
    var titleFontSize: CGFloat = 12
    var titleWeight: UIFont.Weight = .medium
}

/// Font faces for the Markdown document. `nil` names keep the system fonts
/// (Chat); the Code page passes the official variable-font PostScript names.
struct MarkdownFontStyle {
    var bodyName: String? = nil
    var bodyItalicName: String? = nil
    var headingName: String? = nil
    var headingItalicName: String? = nil
    var monoName: String? = nil
    var bodyWeight: CGFloat = 400
    /// The Chat path keeps its semibold emphasis; the Code page overrides
    /// these with the official preset weights (bold 550, heading 400).
    var boldWeight: CGFloat = 600
    var headingWeight: CGFloat = 600

    static let system = MarkdownFontStyle()
}

/// The code card's chrome. Defaults are the Chat card; the Code page passes
/// the official values (44 pt header, 24 pt radius, white/#20201F fill).
struct AssistantCodeCardStyle {
    var headerHeight: CGFloat = 36
    var contentPadding: CGFloat = 14
    var cornerRadius: CGFloat = ChatMetrics.codeRadius
    var fillColor: UIColor? = nil
    var borderColor: UIColor? = nil
    var titleColor: UIColor? = nil
    var titleFontSize: CGFloat = 12
    var titleWeight: UIFont.Weight = .medium
    var textColor: UIColor? = nil
    /// The running-text faces. `fonts` travels with the same style object the
    /// parser already threads, so the measurer and the renderer share them.
    var fonts: MarkdownFontStyle = .system

    static let chat = AssistantCodeCardStyle()
}

/// A table with precomputed column widths and row heights. Both the view and
/// the measurement read these numbers, so a wrapped cell cannot make the card
/// and the stored row height disagree.
struct AssistantTableBlock {
    let rows: [[NSAttributedString]]
    let columnWidths: [CGFloat]
    let rowHeights: [CGFloat]
    let cellPaddingHorizontal: CGFloat
    let cellPaddingVertical: CGFloat
    let cornerRadius: CGFloat

    var totalWidth: CGFloat { columnWidths.reduce(0, +) }
    var totalHeight: CGFloat { rowHeights.reduce(0, +) }
}

/// Builds the document from the same parse pipeline the product's Textual
/// renderer uses (`AttributedStringMarkdownParser` + Git/file enrichment +
/// `MarkdownBlockSnapshot.split`), then converts the block tree into UIKit
/// attributes. Conversion returns nil for any construct M3 does not render.
@MainActor
enum AssistantMarkdownDocumentParser {
    /// One parsed snapshot converted to renderable blocks. The snapshot id is
    /// the identity the streaming parser assigns; the digest changes only when
    /// the snapshot's content changes.
    struct ConvertedSnapshot {
        let id: Int
        let digest: Int
        let blocks: [AssistantMarkdownBlock]
    }

    static func convert(snapshot: MarkdownBlockSnapshot,
                        typography: TimelineTypographySnapshot,
                        codeStyle: AssistantCodeCardStyle = .chat) -> ConvertedSnapshot? {
        guard let parsed = parseTree(from: snapshot.content,
                                     parent: nil,
                                     foreground: .label,
                                     typography: typography,
                                     codeStyle: codeStyle) else {
            return nil
        }
        return ConvertedSnapshot(id: snapshot.id, digest: snapshot.digest,
                                 blocks: parsed)
    }

    static func make(text: String,
                     resolvesFileReferences: Bool,
                     typography: TimelineTypographySnapshot,
                     codeStyle: AssistantCodeCardStyle = .chat) -> AssistantMarkdownDocument? {
        guard !text.isEmpty,
              let snapshots = try? parseBlocks(text: text,
                                               resolvesFileReferences: resolvesFileReferences),
              !snapshots.isEmpty else { return nil }
        var parsedBlocks: [AssistantMarkdownBlock] = []
        var blockGroups: [Int] = []
        for snapshot in snapshots {
            guard let converted = convert(snapshot: snapshot, typography: typography,
                                          codeStyle: codeStyle) else {
                return nil
            }
            // An empty snapshot (a stray separator) contributes nothing; it is
            // not an unsupported construct.
            parsedBlocks.append(contentsOf: converted.blocks)
            blockGroups.append(contentsOf:
                repeatElement(converted.id, count: converted.blocks.count))
        }
        return AssistantMarkdownDocument(
            blocks: parsedBlocks, blockGroups: blockGroups,
            plainTextLength: text.count)
    }

    /// The exact pipeline `ChatMarkdownView` runs for a complete document.
    /// Kept here so the TextKit path and the Textual path cannot drift.
    nonisolated static func parseBlocks(text: String,
                                        resolvesFileReferences: Bool) throws -> [MarkdownBlockSnapshot] {
        var document = try AttributedStringMarkdownParser.parse(text, syntaxExtensions: [.math])
        if resolvesFileReferences {
            for run in document.runs {
                guard run.link == nil, run.inlinePresentationIntent?.contains(.code) == true else { continue }
                let literal = String(document[run.range].characters)
                // A URL first; the file-reference matcher would otherwise
                // claim it as a path. Mirrors `ChatMarkdownView.parse`.
                if let url = ChatInlineURL.url(for: literal) {
                    document[run.range].link = url
                    continue
                }
                if let reference = SessionFileReference.inlineReference(literal) {
                    document[run.range].link = reference.link
                }
            }
        }
        document = GitDirectiveParser.enrich(document) { directives, attributes in
            var badge = AttributedString(directives.map(\.label).joined(separator: " · "),
                                         attributes: attributes)
            badge.textual.attachment = AnyAttachment(ChatGitBadgeAttachment(directives: directives))
            return badge
        }
        return MarkdownBlockSnapshot.split(document, startingAt: 0)
    }

    // MARK: - Block tree

    private struct BlockGroup {
        let intent: PresentationIntent.IntentType?
        let content: AttributedString
    }

    /// Presentation intents are ordered innermost-first. With a parent intent,
    /// a run's direct child is the component immediately before the parent; at
    /// the top level it is the outermost component. This is the same walk
    /// Textual's `BlockContent` performs.
    private static func childIntent(of intent: PresentationIntent?,
                                    parent: PresentationIntent.IntentType?)
        -> PresentationIntent.IntentType? {
        guard let intent else { return nil }
        guard let parent else { return intent.components.last }
        guard let index = intent.components.firstIndex(of: parent),
              index != intent.components.startIndex else { return nil }
        return intent.components[intent.components.index(before: index)]
    }

    private static func blockGroups(in content: AttributedString,
                                    parent: PresentationIntent.IntentType?) -> [BlockGroup] {
        var groups: [BlockGroup] = []
        var currentIntent: PresentationIntent.IntentType?
        var current = AttributedString()
        var hasCurrent = false

        func flush() {
            guard hasCurrent, !current.characters.isEmpty else { return }
            guard !current.characters.allSatisfy({ $0.isWhitespace }) else { return }
            groups.append(BlockGroup(intent: currentIntent, content: current))
        }

        for run in content.runs {
            let intent = childIntent(of: run.presentationIntent, parent: parent)
            if hasCurrent, currentIntent == intent {
                current += AttributedString(content[run.range])
            } else {
                flush()
                current = AttributedString(content[run.range])
                currentIntent = intent
                hasCurrent = true
            }
        }
        flush()
        return groups
    }

    private static func parseTree(from content: AttributedString,
                                  parent: PresentationIntent.IntentType?,
                                  foreground: UIColor,
                                  typography: TimelineTypographySnapshot,
                                  codeStyle: AssistantCodeCardStyle) -> [AssistantMarkdownBlock]? {
        guard !content.characters.isEmpty else { return [] }
        var blocks: [AssistantMarkdownBlock] = []
        for group in blockGroups(in: content, parent: parent) {
            guard let block = makeBlock(group.content,
                                        intent: group.intent,
                                        foreground: foreground,
                                        typography: typography,
                                        codeStyle: codeStyle) else {
                return nil
            }
            blocks.append(block)
        }
        return blocks
    }

    private static func makeBlock(_ content: AttributedString,
                                  intent: PresentationIntent.IntentType?,
                                  foreground: UIColor,
                                  typography: TimelineTypographySnapshot,
                                  codeStyle: AssistantCodeCardStyle) -> AssistantMarkdownBlock? {
        guard !content.characters.isEmpty else { return nil }
        guard let intent else {
            if let image = standaloneImageBlock(content) {
                return .image(image)
            }
            if let math = standaloneMathBlock(content, typography: typography) {
                return .math(math)
            }
            return textBlock(content, headingLevel: nil,
                             foreground: foreground, typography: typography,
                             codeStyle: codeStyle)
                .map(AssistantMarkdownBlock.text)
        }
        switch intent.kind {
        case .paragraph:
            if let image = standaloneImageBlock(content) {
                return .image(image)
            }
            if let math = standaloneMathBlock(content, typography: typography) {
                return .math(math)
            }
            return textBlock(content, headingLevel: nil,
                             foreground: foreground, typography: typography,
                             codeStyle: codeStyle)
                .map(AssistantMarkdownBlock.text)
        case .header(let level):
            return textBlock(content, headingLevel: level,
                             foreground: foreground, typography: typography,
                             codeStyle: codeStyle)
                .map(AssistantMarkdownBlock.text)
        case .orderedList, .unorderedList:
            return listBlock(content, listIntent: intent,
                             foreground: foreground, typography: typography,
                             codeStyle: codeStyle)
        case .blockQuote:
            return quoteBlock(content, quoteIntent: intent, typography: typography,
                              codeStyle: codeStyle)
        case .codeBlock(let languageHint):
            return codeBlock(content, language: languageHint, typography: typography,
                             codeStyle: codeStyle)
        case .thematicBreak:
            // Textual's default thematic break: a hairline divider with
            // 1.6em spacing on both sides (`DividerThematicBreakStyle`).
            return .divider
        case .table(let columns):
            return tableBlock(content, tableIntent: intent, columns: columns,
                              foreground: foreground, typography: typography)
        default:
            // Thematic breaks, block HTML and mixed attachment runs are still
            // hosting-only. One unsupported block makes the whole row fall
            // back, never a half-TextKit reply.
            return nil
        }
    }

    /// A paragraph whose only visible content is one Markdown image. A mixed
    /// text+image paragraph still returns nil: the legacy renderer keeps the
    /// inline flow, and "宁缺勿假" forbids a half-rendered reply.
    private static func standaloneImageBlock(
        _ content: AttributedString
    ) -> AssistantImageBlock? {
        var found: (url: URL, description: String)?
        for run in content.runs {
            if let url = run.imageURL {
                guard found == nil else { return nil }
                found = (url, String(content[run.range].characters))
                continue
            }
            if run.textual.attachment != nil { return nil }
            if String(content[run.range].characters).contains(where: { !$0.isWhitespace }) {
                return nil
            }
        }
        guard let found else { return nil }
        return AssistantImageBlock(
            url: found.url,
            description: found.description,
            isFileReference: SessionFileReference.path(from: found.url) != nil)
    }

    /// A paragraph whose only visible content is one display-style formula.
    /// Inline formulas stay attachments inside a text block.
    private static func standaloneMathBlock(
        _ content: AttributedString,
        typography: TimelineTypographySnapshot
    ) -> AssistantMathBlock? {
        var descriptor: TextualMath.Descriptor?
        for run in content.runs {
            if let attachment = run.textual.attachment {
                guard descriptor == nil,
                      let math = TextualMath.descriptor(for: attachment) else { return nil }
                descriptor = math
                continue
            }
            if run.imageURL != nil { return nil }
            if String(content[run.range].characters).contains(where: { !$0.isWhitespace }) {
                return nil
            }
        }
        guard let descriptor, descriptor.isBlock else { return nil }
        return AssistantMathBlock(latex: descriptor.latex, fontSize: typography.body)
    }

    private static func listBlock(_ content: AttributedString,
                                  listIntent: PresentationIntent.IntentType,
                                  foreground: UIColor,
                                  typography: TimelineTypographySnapshot,
                                  codeStyle: AssistantCodeCardStyle) -> AssistantMarkdownBlock? {
        let groups = blockGroups(in: content, parent: listIntent)
        guard !groups.isEmpty else { return nil }
        var items: [AssistantListBlock.Item] = []
        items.reserveCapacity(groups.count)
        for group in groups {
            guard let intent = group.intent,
                  case .listItem(let ordinal) = intent.kind,
                  let children = parseTree(from: group.content,
                                           parent: intent,
                                           foreground: foreground,
                                           typography: typography,
                                           codeStyle: codeStyle),
                  !children.isEmpty else {
                return nil
            }
            let marker: AssistantListBlock.Marker
            if case .orderedList = listIntent.kind {
                marker = .ordered(ordinal)
            } else {
                marker = .bullet
            }
            items.append(AssistantListBlock.Item(marker: marker, blocks: children))
        }
        guard !items.isEmpty else { return nil }

        let scale = typography.body / ChatMetrics.referenceBodySize
        return .list(AssistantListBlock(
            items: items,
            indent: ChatMetrics.listTextIndent * scale,
            markerGap: ChatMetrics.listMarkerGap * scale,
            bulletSize: ChatMetrics.bulletSize * scale,
            bulletCenterX: ChatMetrics.bulletCenterX * scale,
            // Textual replaces block spacing inside a list with the list item
            // pitch: body line spacing + the 2pt extra gap.
            itemSpacing: ChatMetrics.listItemSpacing * scale,
            innerSpacing: typography.paragraphSpacing * scale,
            bodySize: typography.body,
            markerColor: foreground))
    }

    private static func quoteBlock(_ content: AttributedString,
                                   quoteIntent: PresentationIntent.IntentType,
                                   typography: TimelineTypographySnapshot,
                                   codeStyle: AssistantCodeCardStyle) -> AssistantMarkdownBlock? {
        // The product draws quote text in the body-template ink, not primary.
        guard let children = parseTree(from: content,
                                       parent: quoteIntent,
                                       foreground: ChatTextUIColors.bodyTemplate,
                                       typography: typography,
                                       codeStyle: codeStyle),
              !children.isEmpty else { return nil }
        let scale = typography.body / ChatMetrics.referenceBodySize
        return .quote(AssistantQuoteBlock(
            blocks: children,
            // `ChatBlockQuoteStyle` pads by `ChatMetrics.scaled(12)`.
            inset: 12 * scale,
            barWidth: 2.5,
            innerSpacing: typography.paragraphSpacing * scale))
    }

    private static func codeBlock(_ content: AttributedString,
                                  language: String?,
                                  typography: TimelineTypographySnapshot,
                                  codeStyle: AssistantCodeCardStyle) -> AssistantMarkdownBlock? {
        for run in content.runs {
            if run.textual.attachment != nil || run.imageURL != nil { return nil }
        }
        var code = String(content.characters)
        // The block parser leaves the separator newline at the end; keeping it
        // would add an empty code line to the measured card.
        while code.hasSuffix("\n") || code.hasSuffix("\r") { code.removeLast() }

        let size = typography.codeBlockPin ?? typography.body * typography.codeBlockRatio
        let lineSpacing = max(0, size * typography.codeBlockLineSpacingRatio)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.paragraphSpacing = 0
        // Code keeps its character order even inside an RTL reply.
        paragraph.baseWritingDirection = .leftToRight
        let attributed = NSAttributedString(
            string: code,
            attributes: [
                .font: MarkdownFontFactory.font(
                    name: codeStyle.fonts.monoName, size: size,
                    weight: codeStyle.fonts.bodyWeight),
                .foregroundColor: codeStyle.textColor ?? ChatTextUIColors.text,
                .paragraphStyle: paragraph,
            ])
        // The Chat card is the default style (36 pt header, 14 pt padding,
        // `ChatMetrics.codeRadius`); the Code page supplies the official
        // chrome through `AssistantCodeCardStyle`.
        return .code(AssistantCodeBlock(
            code: attributed,
            language: language,
            headerHeight: codeStyle.headerHeight,
            contentPadding: codeStyle.contentPadding,
            cornerRadius: codeStyle.cornerRadius,
            fillColor: codeStyle.fillColor,
            borderColor: codeStyle.borderColor,
            titleColor: codeStyle.titleColor,
            titleFontSize: codeStyle.titleFontSize,
            titleWeight: codeStyle.titleWeight))
    }

    private static func tableBlock(_ content: AttributedString,
                                   tableIntent: PresentationIntent.IntentType,
                                   columns: [PresentationIntent.TableColumn],
                                   foreground: UIColor,
                                   typography: TimelineTypographySnapshot) -> AssistantMarkdownBlock? {
        let rowGroups = blockGroups(in: content, parent: tableIntent)
        guard !rowGroups.isEmpty else { return nil }

        var rawRows: [[(column: Int, content: AttributedString)]] = []
        for rowGroup in rowGroups {
            guard let rowIntent = rowGroup.intent else { return nil }
            switch rowIntent.kind {
            case .tableHeaderRow, .tableRow:
                break
            default:
                return nil
            }
            var cells: [(column: Int, content: AttributedString)] = []
            var nextColumn = 0
            for cellGroup in blockGroups(in: rowGroup.content, parent: rowIntent) {
                let column: Int
                if let cellIntent = cellGroup.intent,
                   case .tableCell(let columnIndex) = cellIntent.kind {
                    column = columnIndex
                } else {
                    column = nextColumn
                }
                cells.append((column: column, content: cellGroup.content))
                nextColumn = column + 1
            }
            rawRows.append(cells)
        }

        let widestRow = rawRows.map { row in
            (row.map { $0.column }.max() ?? -1) + 1
        }.max() ?? 0
        let columnCount = max(1, max(columns.count, widestRow))

        var rows: [[NSAttributedString]] = []
        rows.reserveCapacity(rawRows.count)
        for (rowIndex, rawRow) in rawRows.enumerated() {
            var cells = Array(repeating: NSAttributedString(), count: columnCount)
            for cell in rawRow where cell.column >= 0 && cell.column < columnCount {
                guard let attributed = tableCell(
                    cell.content,
                    isHeader: rowIndex == 0,
                    column: cell.column,
                    columns: columns,
                    foreground: foreground,
                    typography: typography) else { return nil }
                cells[cell.column] = attributed
            }
            rows.append(cells)
        }

        let paddingHorizontal = ChatMetrics.tableCellPadHorizontal
        let paddingVertical = ChatMetrics.tableCellPadVertical
        // Column widths and row heights depend only on the cell text, not on
        // the timeline's column width: the table scrolls sideways.
        let metrics = AssistantMarkdownTextLayout.tableMetrics(
            rows: rows,
            paddingHorizontal: paddingHorizontal,
            paddingVertical: paddingVertical)
        return .table(AssistantTableBlock(
            rows: rows,
            columnWidths: metrics.widths,
            rowHeights: metrics.heights,
            cellPaddingHorizontal: paddingHorizontal,
            cellPaddingVertical: paddingVertical,
            cornerRadius: ChatMetrics.tableRadius))
    }

    private static func tableCell(_ content: AttributedString,
                                  isHeader: Bool,
                                  column: Int,
                                  columns: [PresentationIntent.TableColumn],
                                  foreground: UIColor,
                                  typography: TimelineTypographySnapshot) -> NSAttributedString? {
        let font = UIFont.systemFont(ofSize: ChatMetrics.tableCellSize,
                                     weight: isHeader ? .semibold : .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 0
        paragraph.paragraphSpacing = 0
        paragraph.alignment = tableAlignment(column: column, columns: columns)
        paragraph.baseWritingDirection = typography.layoutDirection == 1
            ? .rightToLeft : .leftToRight
        guard let attributed = inlineAttributedString(
            content, baseFont: font, baseColor: foreground,
            paragraph: paragraph, typography: typography) else { return nil }
        trimBoundaryWhitespace(attributed)
        return attributed
    }

    private static func tableAlignment(column: Int,
                                       columns: [PresentationIntent.TableColumn]) -> NSTextAlignment {
        guard columns.indices.contains(column) else { return .natural }
        switch columns[column].alignment {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        @unknown default: return .natural
        }
    }

    // MARK: - Text conversion

    private static func textBlock(_ content: AttributedString,
                                  headingLevel: Int?,
                                  foreground: UIColor,
                                  typography: TimelineTypographySnapshot,
                                  codeStyle: AssistantCodeCardStyle) -> AssistantTextBlock? {
        guard !content.characters.isEmpty else { return nil }

        let fonts = codeStyle.fonts
        let isHeading = headingLevel != nil
        let bodySize = typography.body
        let headingSize = headingLevel.map { level -> CGFloat in
            guard !typography.headings.isEmpty else { return bodySize }
            let index = min(max(level - 1, 0), typography.headings.count - 1)
            return typography.headings[index]
        }
        let baseSize = headingSize ?? bodySize
        let baseWeight = isHeading
            ? fonts.headingWeight
            : (typography.boldText ? fonts.boldWeight : fonts.bodyWeight)
        let baseFamily = isHeading
            ? (fonts.headingName ?? fonts.bodyName)
            : fonts.bodyName
        let italicFamily = isHeading
            ? (fonts.headingItalicName ?? fonts.headingName
                ?? fonts.bodyItalicName ?? fonts.bodyName)
            : (fonts.bodyItalicName ?? fonts.bodyName)
        let baseFont = MarkdownFontFactory.font(
            name: baseFamily, size: baseSize, weight: baseWeight)
        let lineSpacing = headingLevel == nil
            ? typography.lineSpacing / ChatMetrics.referenceBodySize * bodySize
            : 0

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = max(0, lineSpacing)
        paragraph.paragraphSpacing = 0
        paragraph.baseWritingDirection = typography.layoutDirection == 1
            ? .rightToLeft : .leftToRight

        guard let output = inlineAttributedString(
            content, baseFont: baseFont, baseColor: foreground,
            paragraph: paragraph, typography: typography, fonts: fonts,
            baseFamily: baseFamily, italicFamily: italicFamily,
            baseWeight: baseWeight) else { return nil }
        trimBoundaryWhitespace(output)
        return output.length > 0
            ? AssistantTextBlock(attributed: output, headingLevel: headingLevel)
            : nil
    }

    /// Shared inline conversion for running text and table cells. `baseFont`
    /// carries the block's own size, so inline code scales from it the way
    /// Textual's `.fontScale` does instead of always using the body size.
    private static func inlineAttributedString(_ content: AttributedString,
                                               baseFont: UIFont,
                                               baseColor: UIColor,
                                               paragraph: NSParagraphStyle,
                                               typography: TimelineTypographySnapshot,
                                               fonts: MarkdownFontStyle = .system,
                                               baseFamily: String? = nil,
                                               italicFamily: String? = nil,
                                               baseWeight: CGFloat = 400)
        -> NSMutableAttributedString? {
        let inlineCodeRatio = typography.body > 0
            ? (typography.inlineCodePin.map { $0 / typography.body } ?? typography.inlineCodeRatio)
            : typography.inlineCodeRatio
        let inlineCodeSize = baseFont.pointSize * inlineCodeRatio

        let output = NSMutableAttributedString()
        for run in content.runs {
            // Textual resolves images after parsing (`run.imageURL`), while
            // Git badges and math arrive as textual attachments. Both are M3
            // attachment work; neither may reach the text renderer as a
            // replacement character.
            if run.textual.attachment != nil || run.imageURL != nil { return nil }
            var text = String(content[run.range].characters)
            // Textual renders a soft break as a space (`Formatter` maps it to
            // `.text(" ")`); copying the literal newline would add a line that
            // the product never shows, especially inside list items.
            if run.inlinePresentationIntent?.contains(.softBreak) == true {
                text = " "
            }
            guard !text.isEmpty else { continue }
            var font = baseFont
            var color = baseColor
            var isCode = false
            var isBold = false
            var underline: NSUnderlineStyle?
            var strikethrough: NSUnderlineStyle?

            if let inline = run.inlinePresentationIntent {
                if inline.contains(.code) {
                    isCode = true
                    if let mono = fonts.monoName {
                        font = MarkdownFontFactory.font(
                            name: mono, size: inlineCodeSize,
                            weight: typography.inlineCodeBold
                                ? fonts.boldWeight : fonts.bodyWeight)
                    } else {
                        font = UIFont.monospacedSystemFont(ofSize: inlineCodeSize,
                            weight: typography.inlineCodeBold ? .semibold : .regular)
                    }
                    color = ChatTextUIColors.bodyTemplate
                }
                if inline.contains(.stronglyEmphasized) {
                    isBold = true
                    if let family = isCode ? fonts.monoName : baseFamily {
                        font = MarkdownFontFactory.font(
                            name: family, size: font.pointSize,
                            weight: fonts.boldWeight)
                    } else {
                        font = font.withWeight(.semibold)
                    }
                }
                if inline.contains(.emphasized) {
                    if isCode {
                        // No italic mono face is bundled; keep the upright mono.
                    } else if let italicFamily {
                        font = MarkdownFontFactory.font(
                            name: italicFamily, size: font.pointSize,
                            weight: isBold ? fonts.boldWeight : baseWeight)
                    } else {
                        font = font.withItalic()
                    }
                }
                if inline.contains(.strikethrough) {
                    strikethrough = .single
                }
            }
            if let url = run.link {
                color = ChatTextUIColors.link
                if ChatLink.isWeb(url) {
                    underline = .single
                }
            }

            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
            if let underline {
                attributes[.underlineStyle] = underline.rawValue
            }
            if let strikethrough {
                attributes[.strikethroughStyle] = strikethrough.rawValue
            }
            output.append(NSAttributedString(string: text, attributes: attributes))
        }
        return output
    }

    /// Block boundaries already provide the spacing between structures; the
    /// parser leaves the separating newline inside each run. Keeping it would
    /// add an empty line to the block's measured height.
    private static func trimBoundaryWhitespace(_ output: NSMutableAttributedString) {
        let string = output.string as NSString
        let whitespace = CharacterSet.whitespacesAndNewlines
        var lower = 0
        var upper = string.length
        while lower < upper,
              let scalar = Unicode.Scalar(string.character(at: lower)),
              whitespace.contains(scalar) {
            lower += 1
        }
        while upper > lower,
              let scalar = Unicode.Scalar(string.character(at: upper - 1)),
              whitespace.contains(scalar) {
            upper -= 1
        }
        if upper < string.length {
            output.deleteCharacters(in: NSRange(location: upper, length: string.length - upper))
        }
        if lower > 0 {
            output.deleteCharacters(in: NSRange(location: 0, length: lower))
        }
    }
}

/// UIKit bridge for the chat inks. Textual's `Color` cannot be handed to
/// `NSAttributedString`; both views resolve the same stored pair.
enum ChatTextUIColors {
    static var bodyTemplate: UIColor { dynamic(ChatColorStore.bodyTemplate) }
    static var link: UIColor { dynamic(ChatColorStore.link) }
    static var quoteBar: UIColor { dynamic(ChatPalette.quoteBar) }
    static var text: UIColor { dynamic(ChatPalette.text) }
    static var codeCardFill: UIColor { dynamic(ChatPalette.codeCardFill) }
    static var codeCardBorder: UIColor { dynamic(ChatPalette.codeCardBorder) }
    static var codeHeaderDivider: UIColor { dynamic(ChatPalette.codeHeaderDivider) }
    static var codeHeaderLabel: UIColor { dynamic(ChatPalette.codeHeaderLabel) }
    static var codeHeaderIcon: UIColor { dynamic(ChatPalette.codeHeaderIcon) }
    static var tableLine: UIColor { dynamic(ChatPalette.tableLine) }
    static var tableHeaderFill: UIColor { dynamic(ChatPalette.tableHeaderFill) }

    // Syntax tokens, mirroring `ChatHighlighterTheme`.
    static var synKey: UIColor { dynamic(ChatPalette.synKey) }
    static var synString: UIColor { dynamic(ChatPalette.synString) }
    static var synComment: UIColor { dynamic(ChatPalette.synComment) }
    static var synPunct: UIColor { dynamic(ChatPalette.synPunct) }
    static var synKeyword: UIColor { dynamic(ChatPalette.synKeyword) }
    static var synNumber: UIColor { dynamic(ChatPalette.synNumber) }
    static var synType: UIColor { dynamic(ChatPalette.synType) }
    static var synFunction: UIColor { dynamic(ChatPalette.synFunction) }

    private static func dynamic(_ pair: ChatColorSettings.Pair) -> UIColor {
        UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? pair.dark : pair.light
            guard let (r, g, b) = ChatColorSettings.parse(hex) else { return .label }
            return UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255,
                           blue: CGFloat(b) / 255, alpha: 1)
        }
    }

    private static func dynamic(_ token: ChatPalette.Token) -> UIColor {
        UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? token.dark : token.light
            return UIColor(red: CGFloat((value >> 16) & 0xFF) / 255,
                           green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255,
                           alpha: 1)
        }
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight],
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }

    func withItalic() -> UIFont {
        let traits = fontDescriptor.symbolicTraits.union(.traitItalic)
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

/// Identity of one rendered block inside a streaming document. The snapshot id
/// comes from `MarkdownParseState` and survives batches; `index` is the block's
/// position inside that snapshot.
nonisolated struct AssistantBlockID: Hashable {
    let snapshot: Int
    let index: Int
}

/// A streaming document plus the boundary between settled and revealing
/// content. Blocks before `stableBlockCount` never change again, so the cell
/// may keep their views; the tail is the text after the last safe split and is
/// rendered by the existing reveal view.
struct AssistantStreamingDocument {
    let document: AssistantMarkdownDocument
    /// One id per rendered block, in document order.
    let blockIDs: [AssistantBlockID]
    let stableBlockIDs: [AssistantBlockID]
    /// Blocks settled *before this batch*. A block that completed in this
    /// batch stays in the tail for one more frame, so its last glyphs still
    /// run the reveal animation instead of appearing already typeset.
    let stableBlockCount: Int
    let tailText: String
    /// Bumped when the text stops extending the previous batch (a correction or
    /// a recovery snapshot). The cell must rebuild rather than reuse views.
    let generation: Int
}

/// Builds the streaming document incrementally: completed snapshots are parsed
/// and converted once, the open tail is reparsed each batch. The work stays on
/// the main actor (the conversion needs UIKit colours); the measured cost of
/// the tail is sub-millisecond for the fixtures, so this keeps the adapter's
/// synchronous contract instead of adding async document delivery.
@MainActor
final class AssistantStreamingDocumentBuilder {
    private var state = MarkdownParseState()
    private var stable: [AssistantMarkdownDocumentParser.ConvertedSnapshot] = []
    private var lastText = ""
    private var generation = 0
    private(set) var isRejected = false
    /// The render boundary from the previous batch. Blocks completed in the
    /// current batch are not promoted until the next one.
    private var promotedSnapshotCount = 0
    private var promotedPrefixText = ""

    func reset() {
        state = MarkdownParseState()
        stable = []
        lastText = ""
        generation &+= 1
        isRejected = false
        promotedSnapshotCount = 0
        promotedPrefixText = ""
    }

    func make(text: String,
              typography: TimelineTypographySnapshot) -> AssistantStreamingDocument? {
        guard !isRejected, !text.isEmpty else { return nil }
        if !text.hasPrefix(lastText) { reset() }
        // Promotion lags one batch. The boundary this frame renders with was
        // settled at the end of the previous batch, so anything that completed
        // in this batch is still in the tail and still reveals letter by letter.
        let renderedSnapshotCount = min(promotedSnapshotCount, stable.count)
        let renderedPrefixText = promotedPrefixText
        guard let parsed = try? Self.parseIncremental(text: text, state: state) else {
            isRejected = true
            return nil
        }
        state = parsed.state

        for snapshot in parsed.completed {
            guard let converted = AssistantMarkdownDocumentParser.convert(
                snapshot: snapshot, typography: typography) else {
                isRejected = true
                return nil
            }
            stable.append(converted)
        }
        var tailConverted: [AssistantMarkdownDocumentParser.ConvertedSnapshot] = []
        tailConverted.reserveCapacity(parsed.tailSnapshots.count)
        for snapshot in parsed.tailSnapshots {
            guard let converted = AssistantMarkdownDocumentParser.convert(
                snapshot: snapshot, typography: typography) else {
                isRejected = true
                return nil
            }
            tailConverted.append(converted)
        }
        promotedSnapshotCount = stable.count
        promotedPrefixText = parsed.state.prefixText

        var blocks: [AssistantMarkdownBlock] = []
        var groups: [Int] = []
        var ids: [AssistantBlockID] = []
        var renderedStableBlocks = 0
        for snapshot in stable.prefix(renderedSnapshotCount) {
            renderedStableBlocks += snapshot.blocks.count
        }
        func append(_ converted: [AssistantMarkdownDocumentParser.ConvertedSnapshot]) {
            for snapshot in converted {
                for (index, block) in snapshot.blocks.enumerated() {
                    blocks.append(block)
                    groups.append(snapshot.id)
                    ids.append(AssistantBlockID(snapshot: snapshot.id, index: index))
                }
            }
        }
        append(stable)
        append(tailConverted)
        lastText = text

        let tailText: String
        if text.hasPrefix(renderedPrefixText) {
            let start = text.index(text.startIndex, offsetBy: renderedPrefixText.count)
            tailText = String(text[start...])
        } else {
            tailText = text
        }

        return AssistantStreamingDocument(
            document: AssistantMarkdownDocument(
                blocks: blocks, blockGroups: groups,
                plainTextLength: text.count),
            blockIDs: ids,
            stableBlockIDs: Array(ids.prefix(renderedStableBlocks)),
            stableBlockCount: renderedStableBlocks,
            tailText: tailText,
            generation: generation)
    }

    private struct ParseResult {
        let state: MarkdownParseState
        let completed: [MarkdownBlockSnapshot]
        let tail: String
        let tailSnapshots: [MarkdownBlockSnapshot]
    }

    /// Same boundary rule as `ChatMarkdownView.parse`: completed text is parsed
    /// once into state, the open tail is parsed per batch.
    private static func parseIncremental(text: String,
                                         state: MarkdownParseState) throws -> ParseResult {
        var state = state
        let consumed = state.prefixEnd(text)
        let split = MarkdownStreamSplit.safeSplitIndex(in: text)
            .flatMap { $0 >= consumed ? $0 : nil }

        var completed: [MarkdownBlockSnapshot] = []
        if let split, split > consumed {
            let raw = try AssistantMarkdownDocumentParser.parseBlocks(
                text: String(text[consumed..<split]),
                resolvesFileReferences: true)
            completed = raw.enumerated().map { offset, snapshot in
                MarkdownBlockSnapshot(id: state.nextID + offset,
                                      content: snapshot.content)
            }
            state.blocks.append(contentsOf: completed)
            state.nextID += completed.count
            state.prefixText = String(text[..<split])
        }

        let tail = String(text[(split ?? consumed)...])
        let tailSnapshots: [MarkdownBlockSnapshot]
        if tail.isEmpty {
            tailSnapshots = []
        } else {
            let raw = try AssistantMarkdownDocumentParser.parseBlocks(
                text: tail, resolvesFileReferences: true)
            tailSnapshots = raw.enumerated().map { offset, snapshot in
                MarkdownBlockSnapshot(id: state.nextID + offset,
                                      content: snapshot.content)
            }
        }
        return ParseResult(state: state, completed: completed,
                           tail: tail, tailSnapshots: tailSnapshots)
    }
}
#endif
