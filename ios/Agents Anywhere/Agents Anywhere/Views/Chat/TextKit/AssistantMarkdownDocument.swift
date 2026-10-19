#if canImport(UIKit)
import SwiftUI
import Textual
import UIKit

/// A static assistant reply prepared for the TextKit 2 cell.
///
/// M2 accepts only paragraph/header blocks. Everything else — lists, quotes,
/// code, tables, images, Git badges, math, attachments — makes the row fall
/// back to the existing hosting path; those blocks are M3 work.
struct AssistantMarkdownDocument {
    let blocks: [AssistantMarkdownBlock]
    let plainTextLength: Int
}

enum AssistantMarkdownBlock {
    case text(NSAttributedString)
}

/// Builds the document from the same parse pipeline the product's Textual
/// renderer uses (`AttributedStringMarkdownParser` + Git/file enrichment +
/// `MarkdownBlockSnapshot.split`), then converts the block runs into UIKit
/// attributes. Conversion returns nil for any construct M2 does not render.
@MainActor
enum AssistantMarkdownDocumentParser {
    static func make(text: String,
                     resolvesFileReferences: Bool,
                     typography: TimelineTypographySnapshot) -> AssistantMarkdownDocument? {
        guard !text.isEmpty,
              let snapshots = try? parseBlocks(text: text,
                                               resolvesFileReferences: resolvesFileReferences),
              !snapshots.isEmpty else { return nil }
        var blocks: [AssistantMarkdownBlock] = []
        blocks.reserveCapacity(snapshots.count)
        for snapshot in snapshots {
            guard let attributed = textBlock(snapshot.content, typography: typography) else {
                return nil
            }
            blocks.append(.text(attributed))
        }
        return AssistantMarkdownDocument(blocks: blocks, plainTextLength: text.count)
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

    // MARK: - Block conversion

    private static func textBlock(_ content: AttributedString,
                                  typography: TimelineTypographySnapshot) -> NSAttributedString? {
        guard !content.characters.isEmpty else { return nil }
        var headingLevel: Int?
        for run in content.runs {
            if run.textual.attachment != nil { return nil }
            guard let intent = run.presentationIntent else { continue }
            for component in intent.components {
                switch component.kind {
                case .paragraph:
                    break
                case .header(let level):
                    headingLevel = level
                default:
                    // Lists, quotes, code, tables, thematic breaks, math and
                    // attachment runs are M3. One unsupported component makes
                    // the whole row fall back to hosting.
                    return nil
                }
            }
        }

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
            let text = String(content[run.range].characters)
            guard !text.isEmpty else { continue }
            var font = baseFont
            var color = UIColor.label
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
        return output.length > 0 ? output : nil
    }
}

/// UIKit bridge for the two user-tunable chat inks. Textual's `Color` cannot
/// be handed to `NSAttributedString`; both views resolve the same stored pair.
enum ChatTextUIColors {
    static var bodyTemplate: UIColor { dynamic(ChatColorStore.bodyTemplate) }
    static var link: UIColor { dynamic(ChatColorStore.link) }

    private static func dynamic(_ pair: ChatColorSettings.Pair) -> UIColor {
        UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? pair.dark : pair.light
            guard let (r, g, b) = ChatColorSettings.parse(hex) else { return .label }
            return UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255,
                           blue: CGFloat(b) / 255, alpha: 1)
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
