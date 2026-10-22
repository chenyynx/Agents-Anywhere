import SwiftUI
import Textual

extension EnvironmentValues {
    @Entry var chatLayoutTraceOwner = "markdown"
    /// True while a row is hosted by the collection timeline. Its controller
    /// animates the row height itself (one 0.18 s ease-in-out), so a fold must
    /// change state without SwiftUI's own content animation; otherwise the
    /// content and the cell frame run on two different clocks (the "not
    /// smooth" device report).
    @Entry var collectionTimelineHeightAnimation = false
    /// Running-text size for every block. When nil the view resolves the
    /// user's preferred size from `ChatMetrics.bodySize`, so a size change in
    /// Settings reaches the chat without a relaunch. Callers that need a
    /// fixed size (reasoning bodies at `.caption2`) still inject a font and
    /// opt out.
    @Entry var chatMarkdownFont: Font?
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
        // The TextKit 2 path reuses this exact pipeline; keeping one copy is
        // what stops the two renderers from parsing the same reply differently.
        let snapshots = try AssistantMarkdownDocumentParser.parseBlocks(
            text: text, resolvesFileReferences: request.resolvesFileReferences)
        try Task.checkCancellation()
        return snapshots.enumerated().map { offset, snapshot in
            MarkdownBlockSnapshot(id: startID + offset, content: snapshot.content)
        }
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
    @Environment(\.chatMarkdownFont) private var injectedFont

    /// An injected font pins the size (reasoning bodies). Otherwise resolve the
    /// user's setting here, inside the view's evaluation, so a change in
    /// Settings re-renders at the new size instead of waiting for a relaunch.
    private var font: Font { injectedFont ?? .system(size: ChatMetrics.bodySize) }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.block == rhs.block && lhs.isStreaming == rhs.isStreaming && lhs.isTail == rhs.isTail
            && lhs.revealDeadline == rhs.revealDeadline
    }

    /// Underlines the web links, and only those.
    ///
    /// Two kinds of link reach this view and they are not the same gesture. A
    /// web link leaves the app, and the reference marks it with a rule. A
    /// workspace file reference is an in-app jump to a file the connector
    /// owns — it is drawn as plain code, no rule, because there is nowhere
    /// else to go. Telling them apart by scheme is what keeps a path from
    /// looking like a URL.
    ///
    /// The parser only records the link (it runs off the main actor, where
    /// `Text.LineStyle` cannot be built). This runs on the view side, once per
    /// block evaluation.
    ///
    /// A plain solid rule with no colour of its own, so it takes the run's own
    /// ink — the same underline the settings preview draws, which is what the
    /// reference does. The dotted grey rule this replaced read as a second,
    /// unrelated colour on top of the link's.
    private static func styled(_ content: AttributedString) -> AttributedString {
        var output = content
        let rule = Text.LineStyle(pattern: .solid)
        for run in content.runs {
            guard let link = run.link, link.isWebLink else { continue }
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
                // Textual's own default is 0.25em, which sits *inside* the
                // line's leading and makes a wrapped line look like a new
                // item. The reference sets the item pitch 2pt wider than the
                // line box; see `ChatMetrics.listItemSpacing`.
                .textual.listItemSpacing(.fontScaled(top: ChatMetrics.listItemSpacingRatio))
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
    /// Both inks are user-tunable, so this is rebuilt per block evaluation
    /// rather than cached: reading `UserDefaults` is cheap next to parsing, and
    /// a cached copy would ignore a colour change until the view is rebuilt.
    static var standard: InlineStyle {
        InlineStyle()
            .code(
                .monospaced,
                .fontScale(ChatMetrics.inlineCodeSize / ChatMetrics.bodySize),
                .foregroundColor(ChatTextInk.bodyTemplate),
                // `.code(...)` replaces the whole property set, so the weight
                // has to be chosen here rather than layered on afterwards.
                // `.regular` is the shipped look; semibold is the opt-in.
                .fontWeight(ChatColorSettings.inlineCodeBold() ? .semibold : .regular)
            )
            .link(.foregroundColor(ChatTextInk.link))
            .strong(.fontWeight(.semibold))
    }
}

/// Resolves the two user-tunable inks into `Color`. Lives beside the renderer
/// because it needs the iOS colour bridge, unlike `ChatColorStore`.
enum ChatTextInk {
    static var bodyTemplate: Color { color(ChatColorStore.bodyTemplate) }
    static var link: Color { color(ChatColorStore.link) }

    private static func color(_ pair: ChatColorSettings.Pair) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(hexString: traits.userInterfaceStyle == .dark ? pair.dark : pair.light)
                ?? .label
        })
    }
}

private extension UIColor {
    convenience init?(hexString: String) {
        guard let (r, g, b) = ChatColorSettings.parse(hexString) else { return nil }
        self.init(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}

private extension URL {
    /// See `ChatLink.isWeb`. Kept here so the render path reads as one
    /// sentence.
    var isWebLink: Bool { ChatLink.isWeb(self) }
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
            .foregroundStyle(ChatTextInk.bodyTemplate)
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

    /// Heading sizes come from the active scheme (AA: 18 / 16 / 14pt against a
    /// 14pt body; moonveil: 1.5 / 1.3 / 1.15 of its own body). Textual wants a
    /// ratio, so it is expressed against the body the scheme was measured at
    /// rather than the current one: raising the body should grow the heading
    /// with it, not shrink the heading's own ratio back toward the body.
    private static func scale(for level: Int) -> CGFloat {
        let scale = ChatTypeSettings.current
        guard scale.body > 0, !scale.headings.isEmpty else { return 1 }
        let index = min(max(level - 1, 0), scale.headings.count - 1)
        return scale.headings[index] / scale.body
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
