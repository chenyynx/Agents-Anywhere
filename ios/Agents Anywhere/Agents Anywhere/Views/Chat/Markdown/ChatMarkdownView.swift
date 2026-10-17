import SwiftUI
import Textual

extension EnvironmentValues {
    @Entry var chatLayoutTraceOwner = "markdown"
    /// Running-text size for every block. `ChatMetrics.bodySize` is the
    /// reference snapshot; Dynamic Type still scales it, because this is a
    /// `Font` and not a fixed `CGFloat`.
    @Entry var chatMarkdownFont: Font = .system(size: ChatMetrics.bodySize)
}

struct ChatMarkdownView: View {
    let text: String
    var isStreaming = false
    var resolvesFileReferences = false
    @State private var blocks: [MarkdownBlockSnapshot] = []
    /// When each block's newest glyphs finish revealing. A block's drawing
    /// clock runs only until then, so a stalled or finished block stops redrawing.
    @State private var revealDeadlines: [Int: Date] = [:]
    /// Completed blocks parsed so far; each batch re-parses only the open tail.
    @State private var parseState = MarkdownParseState()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in
                MarkdownBlockView(block: block, isStreaming: isStreaming, isTail: block.id == blocks.last?.id,
                                  revealDeadline: revealDeadlines[block.id] ?? .distantPast)
                    .equatable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: ParseRequest(text: text, resolvesFileReferences: resolvesFileReferences)) {
            let request = ParseRequest(text: text, resolvesFileReferences: resolvesFileReferences)
            // Parsing a long response must not block scroll and drawer gestures.
            // Cancelled requests cannot publish an older snapshot over a new reply.
            // Streaming replies reuse the blocks before the last safe boundary.
            let previous = isStreaming ? parseState : nil
            let worker = Task.detached(priority: .userInitiated) { try Self.parse(request, previous: previous) }
            let result = await withTaskCancellationHandler {
                await worker.result
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, case .success(let parsed) = result else { return }
            parseState = parsed.state
            let next = parsed.blocks
            guard blocks != next else { return }
            if isStreaming {
                // Set in the same update as the text, so the first frame of new
                // glyphs already has a running clock.
                let deadline = Date.now.addingTimeInterval(ReplyPresentation.revealSeconds + ReplyPresentation.drawSlack)
                let previous = Dictionary(blocks.map { ($0.id, $0.digest) }, uniquingKeysWith: { $1 })
                var deadlines = revealDeadlines.filter { id, _ in next.contains { $0.id == id } }
                for block in next where previous[block.id] != block.digest { deadlines[block.id] = deadline }
                revealDeadlines = deadlines
            }
            blocks = next
        }
    }

    nonisolated private struct ParseRequest: Equatable, Sendable {
        let text: String
        let resolvesFileReferences: Bool
    }

    /// Completed text is parsed once per safe boundary; the open tail is parsed
    /// per batch. A reply whose text no longer extends the cached prefix (a
    /// correction or recovery) starts over from an empty state.
    nonisolated private static func parse(_ request: ParseRequest, previous: MarkdownParseState?)
        throws -> (blocks: [MarkdownBlockSnapshot], state: MarkdownParseState) {
        let text = request.text
        var state = previous.flatMap { $0.covers(text) ? $0 : nil } ?? MarkdownParseState()
        let consumed = state.prefixEnd(text)
        let split = MarkdownStreamSplit.safeSplitIndex(in: text).flatMap { $0 >= consumed ? $0 : nil }
        if let split, split > consumed {
            let completed = try parse(String(text[consumed..<split]), request: request, startingAt: state.nextID)
            state.blocks.append(contentsOf: completed)
            state.nextID += completed.count
            state.prefixText = String(text[..<split])
        }
        let tail = String(text[(split ?? consumed)...])
        let tailBlocks = tail.isEmpty ? [] : try parse(tail, request: request, startingAt: state.nextID)
        return (state.blocks + tailBlocks, state)
    }

    nonisolated private static func parse(_ text: String, request: ParseRequest, startingAt startID: Int) throws -> [MarkdownBlockSnapshot] {
        try Task.checkCancellation()
        var document = try AttributedStringMarkdownParser.parse(text, syntaxExtensions: [.math])
        try Task.checkCancellation()
        if request.resolvesFileReferences {
            for run in document.runs {
                guard run.link == nil, run.inlinePresentationIntent?.contains(.code) == true else { continue }
                let literal = String(document[run.range].characters)
                // A URL first: the reference underlines it with dots, and the
                // file-reference matcher would otherwise claim it as a path.
                if let url = ChatInlineURL.url(for: literal) {
                    // Only the link is set here. The dotted underline is applied
                    // in the view layer (`MarkdownBlockView`), where building a
                    // `Text.LineStyle` — which carries a `Color` — is safe.
                    document[run.range].link = url
                    continue
                }
                if let reference = SessionFileReference.inlineReference(literal) {
                    document[run.range].link = reference.link
                }
            }
        }
        document = GitDirectiveParser.enrich(document) { directives, attributes in
            var badge = AttributedString(directives.map(\.label).joined(separator: " · "), attributes: attributes)
            badge.textual.attachment = AnyAttachment(ChatGitBadgeAttachment(directives: directives))
            return badge
        }
        try Task.checkCancellation()
        return MarkdownBlockSnapshot.split(document, startingAt: startID)
    }
}

private struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlockSnapshot
    let isStreaming: Bool
    let isTail: Bool
    let revealDeadline: Date
    @State private var hasSettled = false
    @State private var headingLedger = GlyphRevealLedger()
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.displayScale) private var displayScale
    @Environment(\.layoutDirection) private var direction
    @Environment(\.chatLayoutTraceOwner) private var traceOwner
    @Environment(\.chatMarkdownFont) private var font

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.block == rhs.block && lhs.isStreaming == rhs.isStreaming && lhs.isTail == rhs.isTail
            && lhs.revealDeadline == rhs.revealDeadline
    }

    /// Adds the dotted rule under a URL that arrived inside inline code.
    ///
    /// The parser only records the link (it runs off the main actor, where
    /// `Text.LineStyle` — which carries a `Color` — cannot be built). This runs
    /// on the view side, once per block evaluation.
    private static func styled(_ content: AttributedString) -> AttributedString {
        var output = content
        let rule = Text.LineStyle(pattern: .dot, color: ChatPalette.underlineDot.color)
        for run in content.runs {
            guard run.link != nil,
                  run.inlinePresentationIntent?.contains(.code) == true else { continue }
            output[run.range].underlineStyle = rule
        }
        return output
    }

    var body: some View {
        // Only changed blocks reach Textual's parser. The complete document was
        // parsed above, so cross-block references and nested structures survive.
        MarkdownBlockLayout(dynamicType: dynamicType, displayScale: displayScale, direction: direction) {
            StructuredText(String(block.digest), parser: ParsedMarkdownText(content: Self.styled(block.content)))
                .textual.structuredTextStyle(ChatMarkdownStyle(headingLedger: headingLedger))
                .textual.highlighterTheme(ChatHighlighterTheme.standard)
                .textual.imageAttachmentLoader(ChatImageLoader())
                // Controls own their gestures. Only paragraph/heading labels and
                // the native code/table text areas install selection overlays.
                .textual.textSelection(.disabled)
                .environment(\.streamingGlyphAnimation, isStreaming && !hasSettled)
                .environment(\.streamingRevealDeadline, revealDeadline)
                .font(font)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .traceChatLayout("markdown:\(traceOwner):\(block.id):layout")
        .task(id: RevealPhase(isStreaming: isStreaming, isTail: isTail)) {
            // Opening static history must not schedule delayed state changes
            // for every paragraph. A live append still settles completed blocks.
            guard isStreaming else { return }
            hasSettled = false
            guard !isTail else { return }
            do { try await Task.sleep(for: ReplyPresentation.settleDelay) } catch { return }
            // Finish any new glyphs, then stop the drawing clock for this
            // completed block even while the rest of the response streams.
            hasSettled = true
        }
    }

    private struct RevealPhase: Equatable {
        let isStreaming: Bool
        let isTail: Bool
    }
}

/// Apply one complete style. A default bundle closer to StructuredText would
/// override individual styles applied outside it, silently bypassing our renderer.
private struct ChatMarkdownStyle: StructuredText.Style {
    private let defaults = StructuredText.DefaultStyle()
    let headingStyle: ChatHeadingStyle
    let paragraphStyle = ChatParagraphStyle()
    let codeBlockStyle = ChatCodeBlockStyle()

    init(headingLedger: GlyphRevealLedger) {
        headingStyle = ChatHeadingStyle(ledger: headingLedger)
    }

    var inlineStyle: InlineStyle { ChatInlineStyle.standard }
    var blockQuoteStyle: ChatBlockQuoteStyle { ChatBlockQuoteStyle() }
    // `markerSpacing` is the gap *between* the marker and the item text, not
    // the text's indent. Measured: item text starts 24.6pt from the column
    // edge, the bullet is 5pt wide centred 9.6pt in, so its trailing edge is
    // at 12.1pt and the gap is ~12.5pt.
    var listItemStyle: StructuredText.DefaultListItemStyle {
        .default(markerSpacing: .fontScaled(ChatMetrics.listMarkerGapRatio))
    }
    var unorderedListMarker: StructuredText.SymbolListMarker {
        .init(symbolName: "circle.fill",
              scale: ChatMetrics.bulletSize / ChatMetrics.referenceBodySize,
              minWidth: .fontScaled(ChatMetrics.bulletCenterX / ChatMetrics.referenceBodySize))
    }
    var orderedListMarker: StructuredText.DecimalListMarker { .init(minWidth: .fontScaled(1)) }
    var tableStyle: ChatTableStyle { ChatTableStyle() }
    var tableCellStyle: StructuredText.DefaultTableCellStyle { defaults.tableCellStyle }
    var thematicBreakStyle: StructuredText.DividerThematicBreakStyle { defaults.thematicBreakStyle }
}

/// Inline run styling: code, links, emphasis.
///
/// Only `code` and `link` differ from Textual's default — emphasis, strong and
/// strikethrough keep the defaults so the renderer behaves exactly as before.
///
/// Every inline-code span gets the dotted rule, not just URLs: a URL inside
/// code is the only code that becomes a link, and the reference draws that rule
/// on the code run itself. Applying it to all code keeps the two cases visually
/// identical to the capture, where only the URL case existed.
private enum ChatInlineStyle {
    static var standard: InlineStyle {
        InlineStyle()
            .code(
                .monospaced,
                .fontScale(ChatMetrics.inlineCodeSize / ChatMetrics.bodySize),
                .foregroundColor(ChatPalette.textSecondary.color)
            )
            .link(.foregroundColor(ChatPalette.link.color))
            .strong(.fontWeight(.semibold))
    }
}

private struct ChatParagraphStyle: StructuredText.ParagraphStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textual.lineSpacing(.fontScaled(ChatMetrics.bodyLineSpacingRatio))
            .textual.blockSpacing(.fontScaled(top: ChatMetrics.paragraphSpacingRatio))
            .modifier(StreamingGlyphReveal())
            .textual.textSelectionScope()
    }
}

/// A thin leading rule, like Web, instead of Textual's padded aside box.
private struct ChatBlockQuoteStyle: StructuredText.BlockQuoteStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(ChatPalette.textSecondary.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textual.padding(.leading, .fontScaled(ChatMetrics.scaled(12)))
            .overlay(alignment: .leading) {
                Capsule().fill(ChatPalette.quoteBar.color).frame(width: 2.5).allowsHitTesting(false)
            }
    }
}

private struct ChatHeadingStyle: StructuredText.HeadingStyle {
    let ledger: GlyphRevealLedger

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textual.fontScale(Self.scale(for: configuration.headingLevel))
            .fontWeight(.semibold)
            .textual.blockSpacing(.fontScaled(top: ChatMetrics.paragraphSpacingRatio,
                                              bottom: ChatMetrics.scaled(8)))
            // Textual identifies headings by their changing slug. Keep births
            // in the stable outer block so an append doesn't replay the heading.
            .modifier(StreamingGlyphReveal(ledger: ledger))
            .textual.textSelectionScope()
    }

    /// Reference headings measured 18 / 16 / 14pt against a 14pt body.
    private static func scale(for level: Int) -> CGFloat {
        switch level {
        case 1: return 18 / ChatMetrics.bodySize
        case 2: return 16 / ChatMetrics.bodySize
        default: return 1
        }
    }
}

private struct ChatCodeBlockStyle: StructuredText.CodeBlockStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChatMarkdownCodeBlock(code: configuration.codeBlock.text, language: configuration.languageHint) {
            configuration.label
                .monospaced()
                .textual.fontScale(ChatMetrics.blockCodeSize / ChatMetrics.bodySize)
                .textual.lineSpacing(.fontScaled(ChatMetrics.scaled(ChatMetrics.blockCodeLineSpacing)))
                .modifier(StreamingGlyphReveal())
        }
        .textual.blockSpacing(.fontScaled(top: ChatMetrics.codeBlockMarginRatio,
                                          bottom: ChatMetrics.codeBlockMarginRatio))
    }
}

private struct ChatTableStyle: StructuredText.TableStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChatMarkdownTable(rows: configuration.rows, columns: configuration.columns)
            .textual.blockSpacing(.fontScaled(top: ChatMetrics.codeBlockMarginRatio,
                                              bottom: ChatMetrics.codeBlockMarginRatio))
    }
}
