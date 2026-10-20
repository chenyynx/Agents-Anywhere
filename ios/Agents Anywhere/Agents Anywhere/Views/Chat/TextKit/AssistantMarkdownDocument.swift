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
    let plainTextLength: Int

    /// Recursive kind census. The gate asserts the fixture really produced the
    /// structures it claims to exercise, not just a paragraph that happened to
    /// pass the height check.
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
                }
            }
        }
        walk(blocks)
        return counts
    }
}

/// Block tree mirroring Textual's `BlockContent`. Nested lists and quotes are
/// containers, not flattened markers, because the product's indentation,
/// marker column and quote rule all depend on the parent column's width.
enum AssistantMarkdownBlock {
    case text(NSAttributedString)
    case list(AssistantListBlock)
    case quote(AssistantQuoteBlock)
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

/// Builds the document from the same parse pipeline the product's Textual
/// renderer uses (`AttributedStringMarkdownParser` + Git/file enrichment +
/// `MarkdownBlockSnapshot.split`), then converts the block tree into UIKit
/// attributes. Conversion returns nil for any construct M3 does not render.
@MainActor
enum AssistantMarkdownDocumentParser {
    static func make(text: String,
                     resolvesFileReferences: Bool,
                     typography: TimelineTypographySnapshot) -> AssistantMarkdownDocument? {
        guard !text.isEmpty,
              let snapshots = try? parseBlocks(text: text,
                                               resolvesFileReferences: resolvesFileReferences),
              !snapshots.isEmpty else { return nil }
        var parsedBlocks: [AssistantMarkdownBlock] = []
        for snapshot in snapshots {
            guard let parsed = parseTree(from: snapshot.content,
                                         parent: nil,
                                         foreground: .label,
                                         typography: typography) else {
                return nil
            }
            // An empty snapshot (a stray separator) contributes nothing; it is
            // not an unsupported construct.
            parsedBlocks.append(contentsOf: parsed)
        }
        return AssistantMarkdownDocument(blocks: parsedBlocks, plainTextLength: text.count)
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
                                  typography: TimelineTypographySnapshot) -> [AssistantMarkdownBlock]? {
        guard !content.characters.isEmpty else { return [] }
        var blocks: [AssistantMarkdownBlock] = []
        for group in blockGroups(in: content, parent: parent) {
            guard let block = makeBlock(group.content,
                                        intent: group.intent,
                                        foreground: foreground,
                                        typography: typography) else {
                return nil
            }
            blocks.append(block)
        }
        return blocks
    }

    private static func makeBlock(_ content: AttributedString,
                                  intent: PresentationIntent.IntentType?,
                                  foreground: UIColor,
                                  typography: TimelineTypographySnapshot) -> AssistantMarkdownBlock? {
        guard !content.characters.isEmpty else { return nil }
        guard let intent else {
            return textBlock(content, headingLevel: nil,
                             foreground: foreground, typography: typography)
                .map(AssistantMarkdownBlock.text)
        }
        switch intent.kind {
        case .paragraph:
            return textBlock(content, headingLevel: nil,
                             foreground: foreground, typography: typography)
                .map(AssistantMarkdownBlock.text)
        case .header(let level):
            return textBlock(content, headingLevel: level,
                             foreground: foreground, typography: typography)
                .map(AssistantMarkdownBlock.text)
        case .orderedList, .unorderedList:
            return listBlock(content, listIntent: intent,
                             foreground: foreground, typography: typography)
        case .blockQuote:
            return quoteBlock(content, quoteIntent: intent, typography: typography)
        default:
            // Code blocks, tables, thematic breaks, math and attachment-only
            // blocks are still hosting-only. One unsupported block makes the
            // whole row fall back, never a half-TextKit reply.
            return nil
        }
    }

    private static func listBlock(_ content: AttributedString,
                                  listIntent: PresentationIntent.IntentType,
                                  foreground: UIColor,
                                  typography: TimelineTypographySnapshot) -> AssistantMarkdownBlock? {
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
                                           typography: typography),
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
            itemSpacing: ChatMetrics.listItemExtraSpacing * scale,
            innerSpacing: typography.paragraphSpacing * scale,
            bodySize: typography.body,
            markerColor: foreground))
    }

    private static func quoteBlock(_ content: AttributedString,
                                   quoteIntent: PresentationIntent.IntentType,
                                   typography: TimelineTypographySnapshot) -> AssistantMarkdownBlock? {
        // The product draws quote text in the body-template ink, not primary.
        guard let children = parseTree(from: content,
                                       parent: quoteIntent,
                                       foreground: ChatTextUIColors.bodyTemplate,
                                       typography: typography),
              !children.isEmpty else { return nil }
        let scale = typography.body / ChatMetrics.referenceBodySize
        return .quote(AssistantQuoteBlock(
            blocks: children,
            // `ChatBlockQuoteStyle` pads by `ChatMetrics.scaled(12)`.
            inset: 12 * scale,
            barWidth: 2.5,
            innerSpacing: typography.paragraphSpacing * scale))
    }

    // MARK: - Text conversion

    private static func textBlock(_ content: AttributedString,
                                  headingLevel: Int?,
                                  foreground: UIColor,
                                  typography: TimelineTypographySnapshot) -> NSAttributedString? {
        guard !content.characters.isEmpty else { return nil }

        let bodySize = typography.body
        let headingSize = headingLevel.map { level -> CGFloat in
            guard !typography.headings.isEmpty else { return bodySize }
            let index = min(max(level - 1, 0), typography.headings.count - 1)
            return typography.headings[index]
        }
        let baseSize = headingSize ?? bodySize
        let baseWeight: UIFont.Weight = (headingLevel != nil || typography.boldText) ? .semibold : .regular
        let baseFont = UIFont.systemFont(ofSize: baseSize, weight: baseWeight)
        let lineSpacing = headingLevel == nil
            ? typography.lineSpacing / ChatMetrics.referenceBodySize * bodySize
            : 0
        let inlineCodeSize = typography.inlineCodePin ?? bodySize * typography.inlineCodeRatio

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = max(0, lineSpacing)
        paragraph.paragraphSpacing = 0
        paragraph.baseWritingDirection = typography.layoutDirection == 1
            ? .rightToLeft : .leftToRight

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
            var color = foreground
            var underline: NSUnderlineStyle?
            var strikethrough: NSUnderlineStyle?

            if let inline = run.inlinePresentationIntent {
                if inline.contains(.code) {
                    font = UIFont.monospacedSystemFont(ofSize: inlineCodeSize,
                        weight: typography.inlineCodeBold ? .semibold : .regular)
                    color = ChatTextUIColors.bodyTemplate
                }
                if inline.contains(.stronglyEmphasized) {
                    font = font.withWeight(.semibold)
                }
                if inline.contains(.emphasized) {
                    font = font.withItalic()
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
        trimBoundaryWhitespace(output)
        return output.length > 0 ? output : nil
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
#endif
