#if canImport(UIKit)
import SwiftUI
import UIKit

/// The Code page's Markdown text block, built the way the official page builds
/// it: a `UIViewRepresentable` whose synchronous `sizeThatFits` measures the
/// same TextKit document that draws it.
///
/// Official evidence: the Code row is a `UIHostingConfiguration` and SwiftUI
/// asks `MarkdownTextLeafRepresentable` for its size through the
/// `UIViewRepresentable` size witness; the leaf consults its TextKit
/// measurement (`EVIDENCE/UPSTREAM/part-aa-markdown-ui.md:149`,
/// `CANONICAL/05-layout-scroll.md:102`). Because the measurement is synchronous,
/// the first fit already sees the real body — the official cell never corrects
/// a settled row.
///
/// The document parser and block views are the ones the Chat page and
/// `CodeMessageHeightMeasurer` already use. That makes the height the first fit
/// reports equal to the height the layout stores, so no later correction (the
/// 3 pt / 1900 pt family) is produced.
struct CodeMarkdownTextLeaf: UIViewRepresentable {
    let text: String
    /// The adapter's typography snapshot. Production always passes it; the
    /// fallback keeps previews and gates honest when they build the row
    /// directly.
    var typography: TimelineTypographySnapshot?

    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.legibilityWeight) private var legibilityWeight

    init(text: String, typography: TimelineTypographySnapshot?) {
        self.text = text
        self.typography = typography
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var document: AssistantMarkdownDocument?
        var documentKey = ""
    }

    /// The adapter's snapshot is the unscaled official Code scale; this leaf
    /// applies the reader's Dynamic Type setting with the same shared factory
    /// `CodeMessageHeightMeasurer` uses on its `UITraitCollection`. SwiftUI's
    /// `dynamicTypeSize` is mapped to the equivalent UIKit category — the two
    /// sides must resolve the same category or a row would resize after the
    /// first fit.
    private var snapshot: TimelineTypographySnapshot {
        let base: TimelineTypographySnapshot
        if let typography {
            base = typography
        } else {
            base = TimelineChatContentAdapter.typography(
                dynamicType: String(describing: dynamicTypeSize),
                layoutDirection: layoutDirection == .rightToLeft ? 1 : 0,
                boldText: legibilityWeight == .bold,
                scale: CodePageTheme.markdownScale)
        }
        return base.resolvedForCodePage(
            category: dynamicTypeSize.contentSizeCategory)
    }

    private func document(in coordinator: Coordinator) -> AssistantMarkdownDocument? {
        let metrics = snapshot
        let key = "\(metrics.revision):\(text)"
        if coordinator.documentKey == key { return coordinator.document }
        let parsed = AssistantMarkdownDocumentParser.make(
            text: text, resolvesFileReferences: true, typography: metrics,
            codeStyle: CodePageTheme.codeCardStyle)?
            .applyingCodePageTextColors()
        coordinator.document = parsed
        coordinator.documentKey = key
        return parsed
    }

    func makeUIView(context: Context) -> CodeMarkdownTextStackView {
        let view = CodeMarkdownTextStackView()
        view.backgroundColor = .clear
        view.isOpaque = false
        return view
    }

    func updateUIView(_ uiView: CodeMarkdownTextStackView, context: Context) {
        let document = document(in: context.coordinator)
        uiView.install(document: document,
                       key: context.coordinator.documentKey,
                       displayScale: max(displayScale, 1))
    }

    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView: CodeMarkdownTextStackView,
                      context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0, width.isFinite else { return nil }
        guard let document = document(in: context.coordinator) else {
            return CGSize(width: width, height: 0)
        }
        let height = ceil(AssistantMarkdownTextLayout.measure(
            document, width: width, displayScale: max(displayScale, 1)))
        return CGSize(width: width, height: height)
    }
}

/// The UIKit content of one `CodeMarkdownTextLeaf`: the document's blocks in a
/// vertical stack, each at the height `AssistantMarkdownTextLayout` measured.
/// The heights are constraints, exactly like `AssistantMarkdownCell`, so the
/// rendered layout and the value returned by `sizeThatFits` are the same
/// arithmetic.
final class CodeMarkdownTextStackView: UIView {
    private let stack = UIStackView()
    private var heightConstraints: [NSLayoutConstraint] = []
    private var document: AssistantMarkdownDocument?
    private var documentKey = ""
    private var displayScale: CGFloat = 2
    private var builtWidth: CGFloat = -1
    private var builtKey = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .clear
        isOpaque = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let bottom = stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        // The stack's height is the document measurement; the representable's
        // frame is that number too. Keep the pin below required so a subpixel
        // difference cannot break the layout.
        bottom.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            bottom,
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The latest document. Building happens on the next layout pass, when the
    /// representable has its real width.
    func install(document: AssistantMarkdownDocument?, key: String, displayScale: CGFloat) {
        self.document = document
        self.documentKey = key
        self.displayScale = displayScale
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        guard width > 0 else { return }
        guard abs(width - builtWidth) > 0.5 || documentKey != builtKey else { return }
        builtWidth = width
        builtKey = documentKey
        rebuild(width: width)
    }

    private func rebuild(width: CGFloat) {

        for constraint in heightConstraints { constraint.isActive = false }
        heightConstraints.removeAll()
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard let document else { return }
        for block in document.blocks {
            let made = AssistantMarkdownBlockViewFactory.make(
                block, width: width, displayScale: displayScale)
            stack.addArrangedSubview(made.view)
            let constraint = made.view.heightAnchor.constraint(equalToConstant: made.height)
            constraint.isActive = true
            heightConstraints.append(constraint)
        }
        // Textual collapses adjacent block margins (max, not sum); the
        // measurement path uses the same rule, so the stack must too.
        for index in 1..<max(1, document.blocks.count) {
            guard stack.arrangedSubviews.indices.contains(index - 1) else { break }
            stack.setCustomSpacing(
                AssistantMarkdownTextLayout.topLevelSpacing(after: index - 1, in: document),
                after: stack.arrangedSubviews[index - 1])
        }
    }
}

// MARK: - Official Code text colours

extension AssistantMarkdownDocument {
    /// Map the Chat ink to the official Code colours: body text
    /// `#131313`/`#F9F9F7`, inline code `#184F95`/`#6DA7EC`. The official
    /// theme links use the body colour, and inline code is the only blue.
    /// Colours never change a height, so the measured and drawn documents
    /// stay identical.
    ///
    /// [E] R19 `typography-inline.md` §1.2/§12 — the target build's headings
    /// are Anthropic Sans at weight 550, not the 2026-03 Serif face; this
    /// pass no longer rewrites heading fonts.
    func applyingCodePageTextColors() -> AssistantMarkdownDocument {
        AssistantMarkdownDocument(blocks: Self.styledBlocks(blocks),
                                  blockGroups: blockGroups,
                                  plainTextLength: plainTextLength,
                                  blockSpacing: blockSpacing,
                                  codeRoles: codeRoles)
    }

    private static func styledBlocks(
        _ blocks: [AssistantMarkdownBlock]
    ) -> [AssistantMarkdownBlock] {
        blocks.map { block in
            switch block {
            case .text(let text):
                return .text(AssistantTextBlock(
                    attributed: Self.recolored(text.attributed),
                    headingLevel: text.headingLevel))
            case .list(let list):
                let items = list.items.map {
                    AssistantListBlock.Item(marker: $0.marker,
                                            blocks: styledBlocks($0.blocks))
                }
                return .list(AssistantListBlock(
                    items: items,
                    indent: list.indent,
                    markerGap: list.markerGap,
                    bulletSize: list.bulletSize,
                    bulletCenterX: list.bulletCenterX,
                    itemSpacing: list.itemSpacing,
                    innerSpacing: list.innerSpacing,
                    bodySize: list.bodySize,
                    // The bullet and ordered label are drawn outside the
                    // attributed text, so they need the same body ink the
                    // runs receive below.
                    markerColor: CodePageTheme.markdownTextUIColor))
            case .quote(let quote):
                return .quote(AssistantQuoteBlock(
                    blocks: styledBlocks(quote.blocks),
                    inset: quote.inset,
                    barWidth: quote.barWidth,
                    innerSpacing: quote.innerSpacing,
                    barColor: quote.barColor))
            case .table(let table):
                return .table(AssistantTableBlock(
                    rows: table.rows.map { row in
                        row.map { recolored($0) }
                    },
                    columnWidths: table.columnWidths,
                    rowHeights: table.rowHeights,
                    cellPaddingHorizontal: table.cellPaddingHorizontal,
                    cellPaddingVertical: table.cellPaddingVertical,
                    cornerRadius: table.cornerRadius,
                    headerFillColor: table.headerFillColor,
                    borderColor: table.borderColor))
            default:
                return block
            }
        }
    }

    private static func recolored(_ attributed: NSAttributedString) -> NSAttributedString {
        let output = NSMutableAttributedString(attributedString: attributed)
        let full = NSRange(location: 0, length: output.length)
        output.enumerateAttribute(.font, in: full) { value, range, _ in
            let font = value as? UIFont
            let isMono = font?.fontDescriptor.symbolicTraits
                .contains(.traitMonoSpace) ?? false
            output.addAttribute(
                .foregroundColor,
                value: isMono ? CodePageTheme.inlineCodeTextUIColor
                              : CodePageTheme.markdownTextUIColor,
                range: range)
        }
        return output
    }
}

nonisolated extension DynamicTypeSize {
    /// SwiftUI's size ladder → the UIKit category the measurer reads.
    ///
    /// `CodeMarkdownTextLeaf` scales from this category and
    /// `CodeMessageHeightMeasurer` scales from
    /// `UITraitCollection.preferredContentSizeCategory`; both must name the
    /// same step of the ladder.
    var contentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        // SwiftUI exposes the reverse mapping (`DynamicTypeSize(_:
        // UIContentSizeCategory)`) but not this direction; future ladder steps
        // fall back to the standard body size.
        @unknown default: return .large
        }
    }
}
#endif
