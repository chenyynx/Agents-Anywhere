import SwiftUI
import Textual

extension EnvironmentValues {
    @Entry var chatLayoutTraceOwner = "markdown"
    /// One Dynamic Type step below body; every block scales from this.
    @Entry var chatMarkdownFont: Font = .callout
}

struct ChatMarkdownView: View {
    let text: String
    var isStreaming = false
    var resolvesFileReferences = false
    /// The session workspace's file catalog, when it has loaded. `nil` (not yet
    /// loaded) keeps every path as plain text; the same view re-parses and the
    /// paths become clickable once the catalog arrives (loads are background,
    /// never blocking the render).
    var catalog: WorkspaceFileCatalog? = nil
    @State private var blocks: [MarkdownBlockSnapshot] = []
    /// When each block's newest glyphs finish revealing. A block's drawing
    /// clock runs only until then, so a stalled or finished block stops redrawing.
    @State private var revealDeadlines: [Int: Date] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in
                MarkdownBlockView(block: block, isStreaming: isStreaming, isTail: block.id == blocks.last?.id,
                                  revealDeadline: revealDeadlines[block.id] ?? .distantPast)
                    .equatable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: ParseRequest(text: text, resolvesFileReferences: resolvesFileReferences, catalog: catalog)) {
            let request = ParseRequest(text: text, resolvesFileReferences: resolvesFileReferences, catalog: catalog)
            // Parsing a long response must not block scroll and drawer gestures.
            // Cancelled requests cannot publish an older snapshot over a new reply.
            let worker = Task.detached(priority: .userInitiated) { try Self.parse(request) }
            let result = await withTaskCancellationHandler {
                await worker.result
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, case .success(let next) = result else { return }
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
        let catalog: WorkspaceFileCatalog?
    }

    nonisolated private static func parse(_ request: ParseRequest) throws -> [MarkdownBlockSnapshot] {
        try Task.checkCancellation()
        var document = try AttributedStringMarkdownParser.parse(request.text, syntaxExtensions: [.math])
        try Task.checkCancellation()
        // Catalog membership decides what renders as a file object (3.3b): a
        // bare name is a chip only when it is a real workspace file (entry ②); a
        // backtick-quoted path becomes a chip — or loses that — by the same rule
        // (entry ①). A path alone on its own line becomes a card. Without a
        // loaded catalog everything stays plain text / code.
        if request.resolvesFileReferences, let catalog = request.catalog {
            Self.applyFileCards(in: &document, catalog: catalog)
            Self.applyBacktickChips(in: &document, catalog: catalog)
            Self.applyBareChips(in: &document, catalog: catalog)
        }
        document = GitDirectiveParser.enrich(document) { directives, attributes in
            var badge = AttributedString(directives.map(\.label).joined(separator: " · "), attributes: attributes)
            badge.textual.attachment = AnyAttachment(ChatGitBadgeAttachment(directives: directives))
            return badge
        }
        try Task.checkCancellation()
        return MarkdownBlockSnapshot.split(document)
    }

    /// A path alone on its own line renders as a file *card* instead of a chip
    /// (the design's card form). "Alone" = a *standalone* paragraph block (exactly
    /// one presentation component — not nested in a list or quote) whose trimmed
    /// text is exactly one recognized reference (an absolute path, or a catalog
    /// member after the `:line:col` suffix is stripped). A path quoted in
    /// backticks on its own line is a card too — the card replaces what the chip
    /// pass would otherwise draw. Links are skipped (their displayed text is not
    /// the reference), so a `[x](url)` line is left alone.
    ///
    /// The whole paragraph is collapsed into a single run (its original
    /// presentation intent preserved) so exactly one card placeholder is laid
    /// out, not one per original run.
    nonisolated private static func applyFileCards(in document: inout AttributedString, catalog: WorkspaceFileCatalog) {
        // Group runs into blocks by the same identity the block splitter uses.
        var groups: [(range: Range<AttributedString.Index>, intent: PresentationIntent?)] = []
        var lastIdentity: Int?
        for run in document.runs {
            let identity = run.presentationIntent?.components.last?.identity ?? -1
            if groups.last != nil, identity == lastIdentity {
                let lower = groups[groups.count - 1].range.lowerBound
                groups[groups.count - 1].range = lower..<run.range.upperBound
            } else {
                groups.append((run.range, run.presentationIntent))
            }
            lastIdentity = identity
        }
        var edits: [(range: Range<AttributedString.Index>, intent: PresentationIntent, raw: String)] = []
        for group in groups {
            // A standalone paragraph: one component, and it is a paragraph.
            guard let intent = group.intent, intent.components.count == 1,
                  intent.components[0].kind == .paragraph else { continue }
            let content = document[group.range]
            guard content.runs.allSatisfy({ $0.link == nil }) else { continue }
            let text = String(content.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  FileReferenceScanner.codeReference(text, catalog: catalog) != nil else { continue }
            // Keep the raw text (with any `:line:col`) as the open path: the card
            // strips the location for its own title/subtitle, and the open link
            // re-parses it so the preview still focuses the source line.
            edits.append((group.range, intent, text))
        }
        // Apply from the end so earlier ranges stay valid as the document reindexes.
        for edit in edits.reversed() {
            var card = AttributedString(edit.raw)
            card.presentationIntent = edit.intent
            card.textual.attachment = AnyAttachment(ChatFileCardAttachment(path: edit.raw))
            document.replaceSubrange(edit.range, with: card)
        }
    }

    /// Entry ①: a backtick-quoted run whose content is a recognized file
    /// reference (absolute path, or a catalog member after the `:line:col`
    /// suffix is stripped) becomes an inline chip. Any other code — a directory
    /// name, a command, a sentence — keeps rendering as plain inline code. The
    /// chip keeps the raw content as its open path, so `:line:col` still focuses
    /// the preview once `SessionChatView` parses it back out.
    nonisolated private static func applyBacktickChips(in document: inout AttributedString, catalog: WorkspaceFileCatalog) {
        var edits: [(Range<AttributedString.Index>, ChatFileChipAttachment)] = []
        for run in document.runs {
            guard run.textual.attachment == nil, run.link == nil,
                  run.inlinePresentationIntent?.contains(.code) == true else { continue }
            let content = String(document[run.range].characters)
            guard FileReferenceScanner.codeReference(content, catalog: catalog) != nil else { continue }
            edits.append((run.range, ChatFileChipAttachment(path: content, display: content)))
        }
        for edit in edits { document[edit.0].textual.attachment = AnyAttachment(edit.1) }
    }

    /// Entry ②: a bare path-like token in ordinary prose — not code, not HTML,
    /// not an existing link (`[x](path)`), not inside a fenced block — becomes an
    /// inline chip in its own sub-range. The token must end in a dotted extension
    /// and be an exact catalog member, so URLs, e-mail addresses, versions, and
    /// fractions never turn into chips.
    ///
    /// Ceiling on bare-path chips per message. Applying an attachment touches the
    /// document (O(n) each), so a reply that repeats a workspace filename
    /// thousands of times (a big diff / log) would otherwise be O(n²). Past the
    /// cap, later tokens stay plain — no message is ever left un-chipped because
    /// of a pathological one.
    nonisolated private static let maxBareLinksPerMessage = 200

    nonisolated private static func applyBareChips(in document: inout AttributedString, catalog: WorkspaceFileCatalog) {
        var edits: [(Range<AttributedString.Index>, ChatFileChipAttachment)] = []
        var remaining = Self.maxBareLinksPerMessage
        for run in document.runs {
            if remaining <= 0 { break }
            guard run.textual.attachment == nil, run.link == nil,
                  run.inlinePresentationIntent?.intersection([.code, .inlineHTML, .blockHTML]).isEmpty != false,
                  !isCodeBlock(run.presentationIntent) else { continue }
            let plain = String(document[run.range].characters)
            // Token offsets are grapheme counts within the run; step from the
            // run's own document-space lower bound so both indices land in
            // `document` and the mutable subscript updates it in place.
            let base = run.range.lowerBound
            for range in FileReferenceScanner.bareReferences(in: plain, catalog: catalog, limit: remaining) {
                let token = String(plain[range])
                let lower = plain.distance(from: plain.startIndex, to: range.lowerBound)
                let upper = plain.distance(from: plain.startIndex, to: range.upperBound)
                edits.append((document.index(base, offsetByCharacters: lower)..<document.index(base, offsetByCharacters: upper),
                              ChatFileChipAttachment(path: token, display: token)))
                remaining -= 1
            }
        }
        for edit in edits { document[edit.0].textual.attachment = AnyAttachment(edit.1) }
    }

    /// A fence's runs are one `codeBlock` presentation component; a path inside
    /// a code block is never linked.
    nonisolated private static func isCodeBlock(_ intent: PresentationIntent?) -> Bool {
        intent?.components.contains {
            if case .codeBlock = $0.kind { return true }
            return false
        } == true
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

    var body: some View {
        // Only changed blocks reach Textual's parser. The complete document was
        // parsed above, so cross-block references and nested structures survive.
        MarkdownBlockLayout(dynamicType: dynamicType, displayScale: displayScale, direction: direction) {
            StructuredText(String(block.digest), parser: ParsedMarkdownText(content: block.content))
                .textual.structuredTextStyle(ChatMarkdownStyle(headingLedger: headingLedger))
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

    // External links: underline + body ink (design §3 `ExternalLinkStyle`),
    // instead of Textual's default accent color. Only the `link` slot changes;
    // code/strong keep their defaults.
    var inlineStyle: InlineStyle {
        defaults.inlineStyle.link(
            .foregroundColor(DynamicColor(Color(uiColor: ExternalLinkStyle.ink))),
            .underlineStyle(.single)
        )
    }
    var blockQuoteStyle: ChatBlockQuoteStyle { ChatBlockQuoteStyle() }
    // Textual's defaults indent each level by 2em; a phone column needs ~1.4em.
    var listItemStyle: StructuredText.DefaultListItemStyle { .default(markerSpacing: .fontScaled(0.4)) }
    var unorderedListMarker: StructuredText.SymbolListMarker {
        .init(symbolName: "circle.fill", scale: 0.33, minWidth: .fontScaled(1))
    }
    var orderedListMarker: StructuredText.DecimalListMarker { .init(minWidth: .fontScaled(1)) }
    var tableStyle: ChatTableStyle { ChatTableStyle() }
    var tableCellStyle: StructuredText.DefaultTableCellStyle { defaults.tableCellStyle }
    var thematicBreakStyle: StructuredText.DividerThematicBreakStyle { defaults.thematicBreakStyle }
}

private struct ChatParagraphStyle: StructuredText.ParagraphStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textual.lineSpacing(.fontScaled(0.23))
            .textual.blockSpacing(.fontScaled(top: 0.8))
            .modifier(StreamingGlyphReveal())
            .textual.textSelectionScope()
    }
}

/// A thin leading rule, like Web, instead of Textual's padded aside box.
private struct ChatBlockQuoteStyle: StructuredText.BlockQuoteStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textual.padding(.leading, .fontScaled(0.75))
            .overlay(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.18)).frame(width: 3).allowsHitTesting(false)
            }
    }
}

private struct ChatHeadingStyle: StructuredText.HeadingStyle {
    let ledger: GlyphRevealLedger

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textual.fontScale(configuration.headingLevel == 1 ? 1.5 : configuration.headingLevel == 2 ? 1.25 : 1.08)
            .fontWeight(.semibold)
            .textual.blockSpacing(.fontScaled(top: 1.25, bottom: 0.55))
            // Textual identifies headings by their changing slug. Keep births
            // in the stable outer block so an append doesn't replay the heading.
            .modifier(StreamingGlyphReveal(ledger: ledger))
            .textual.textSelectionScope()
    }
}

private struct ChatCodeBlockStyle: StructuredText.CodeBlockStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChatMarkdownCodeBlock(code: configuration.codeBlock.text, language: configuration.languageHint) {
            configuration.label
                .monospaced()
                .textual.fontScale(0.86)
                .textual.lineSpacing(.fontScaled(0.35))
                .modifier(StreamingGlyphReveal())
        }
        .textual.blockSpacing(.fontScaled(top: 0.9, bottom: 0.5))
    }
}

private struct ChatTableStyle: StructuredText.TableStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChatMarkdownTable(rows: configuration.rows, columns: configuration.columns)
            .textual.blockSpacing(.fontScaled(top: 0.9, bottom: 0.5))
    }
}
