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
        /// Bumped whenever the previous document can no longer be extended
        /// (the text stopped growing at the tail, the typography changed, or a
        /// plain fallback replaced the parsed document). The stack view rebuilds
        /// instead of diffing when this changes.
        var generation = 0
        var builder: AssistantStreamingDocumentBuilder?
        /// The typography revision the builder was created with. A change
        /// rebuilds the builder and clears the memoised block heights.
        var builderRevision: Int?
        /// The builder generation the renderer has consumed. The builder bumps
        /// its own generation when the text stops extending the previous batch.
        var lastBuilderGeneration = -1
        /// Bumped for every new document; the stack view uses it as its cheap
        /// change key instead of comparing the whole reply text.
        var documentRevision = 0
        /// The text the current document was built from.
        var lastParsedText = ""
        /// Per-leaf height memo. Keys carry the block identity and digest, so
        /// this cache can never return a height for different content.
        let heightCache = AssistantMarkdownBlockHeightCache()
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
        let category = dynamicTypeSize.contentSizeCategory

        // The builder holds converted blocks and the ink-mapped attributed
        // strings; a typography change invalidates all of it.
        if coordinator.builderRevision != metrics.revision {
            coordinator.builder = AssistantStreamingDocumentBuilder(
                codeStyle: CodePageTheme.codeCardStyle(category: category),
                colorize: { AssistantMarkdownDocument.applyingCodePageTextColors(to: $0) })
            coordinator.builderRevision = metrics.revision
            coordinator.heightCache.removeAll()
            coordinator.generation &+= 1
            coordinator.lastParsedText = ""
            coordinator.document = nil
            coordinator.documentKey = ""
        }

        guard !text.isEmpty else {
            coordinator.document = nil
            coordinator.documentKey = "empty:\(coordinator.generation)"
            coordinator.lastParsedText = text
            return nil
        }
        if coordinator.lastParsedText == text { return coordinator.document }
        coordinator.lastParsedText = text

        guard CodeStreamingIncremental.enabled else {
            return fullDocument(
                in: coordinator, metrics: metrics,
                style: CodePageTheme.codeCardStyle(category: category))
        }
        guard let builder = coordinator.builder else { return nil }
        if let streaming = builder.make(text: text, typography: metrics) {
            // The builder bumps its generation when the text stops extending
            // the previous batch; propagate it so the stack rebuilds instead
            // of diffing two unrelated documents.
            if streaming.generation != coordinator.lastBuilderGeneration {
                coordinator.lastBuilderGeneration = streaming.generation
                coordinator.generation &+= 1
            }
            return installDocument(streaming.document, in: coordinator)
        }
        // A block the converter cannot represent must not erase the whole
        // reply. The TextKit path used to return nil here, which rendered a
        // zero-height text block (the `---` bug class). Render the raw text as
        // one plain paragraph instead and keep the rest of the row visible.
        // The builder marks itself rejected; reset it so the next batch retries
        // from scratch (the pre-incremental path retried on every change and
        // recovered once the unsupported text was replaced).
        builder.reset()
        coordinator.generation &+= 1
        return installDocument(
            Self.plainTextDocument(text, typography: metrics), in: coordinator)
    }

    /// The pre-incremental path: one full parse per text change. Kept behind
    /// `CodeStreamingIncremental.enabled` so a device regression can fall back
    /// without reverting the file.
    private func fullDocument(in coordinator: Coordinator,
                              metrics: TimelineTypographySnapshot,
                              style: AssistantCodeCardStyle) -> AssistantMarkdownDocument {
        let parsed = AssistantMarkdownDocumentParser.make(
            text: text, resolvesFileReferences: true, typography: metrics,
            codeStyle: style)?
            .applyingCodePageTextColors()
        return installDocument(
            parsed ?? Self.plainTextDocument(text, typography: metrics),
            in: coordinator)
    }

    /// Store a newly built document and give it a cheap change key. The stack
    /// only needs to know that this is a different document; the block keys
    /// and digests inside decide what actually gets reused.
    private func installDocument(_ document: AssistantMarkdownDocument,
                                 in coordinator: Coordinator) -> AssistantMarkdownDocument {
        coordinator.document = document
        coordinator.documentRevision &+= 1
        coordinator.documentKey = "d\(coordinator.documentRevision)"
        return document
    }

    private static func plainTextDocument(
        _ text: String, typography: TimelineTypographySnapshot
    ) -> AssistantMarkdownDocument {
        let font = MarkdownFontFactory.font(
            name: CodePageTheme.sansFontName, size: typography.body, weight: 400)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = typography.lineSpacing
        paragraph.paragraphSpacing = typography.paragraphSpacing
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: CodePageTheme.markdownTextUIColor,
            .paragraphStyle: paragraph,
        ])
        return AssistantMarkdownDocument(
            blocks: [.text(AssistantTextBlock(
                attributed: attributed, headingLevel: nil))],
            blockGroups: [0],
            plainTextLength: text.count,
            blockSpacing: CodePageTheme.blockSpacing,
            codeRoles: typography.codeMarkdownRoles)
    }

    func makeUIView(context: Context) -> CodeMarkdownTextStackView {
        let view = CodeMarkdownTextStackView()
        view.backgroundColor = .clear
        view.isOpaque = false
        return view
    }

    func updateUIView(_ uiView: CodeMarkdownTextStackView, context: Context) {
        let coordinator = context.coordinator
        let document = document(in: coordinator)
        uiView.install(document: document,
                       key: coordinator.documentKey,
                       displayScale: max(displayScale, 1),
                       generation: coordinator.generation,
                       cache: coordinator.heightCache,
                       typographyRevision: coordinator.builderRevision ?? 0)
    }

    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView: CodeMarkdownTextStackView,
                      context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0, width.isFinite else { return nil }
        let coordinator = context.coordinator
        guard let document = document(in: coordinator) else {
            return CGSize(width: width, height: 0)
        }
        let height = ceil(AssistantMarkdownTextLayout.measure(
            document, width: width, displayScale: max(displayScale, 1),
            cache: coordinator.heightCache,
            typographyRevision: coordinator.builderRevision ?? 0))
        return CGSize(width: width, height: height)
    }
}

/// The UIKit content of one `CodeMarkdownTextLeaf`: the document's blocks in a
/// vertical stack, each at the height `AssistantMarkdownTextLayout` measured.
/// The heights are constraints, exactly like `AssistantMarkdownCell`, so the
/// rendered layout and the value returned by `sizeThatFits` are the same
/// arithmetic.
final class CodeMarkdownTextStackView: UIView, UIGestureRecognizerDelegate {
    private let stack = UIStackView()

    /// One installed block. `key` is the block's stable identity and `digest`
    /// the content version; together they decide whether the view can be kept.
    private struct Record {
        let key: String
        var kind: String
        var digest: Int
        let view: UIView
        let constraint: NSLayoutConstraint
    }

    private var records: [Record] = []
    private var document: AssistantMarkdownDocument?
    private var documentKey = ""
    private var displayScale: CGFloat = 2
    private var builtWidth: CGFloat = -1
    private var builtKey = ""
    private var builtGeneration = -1
    private var generation = 0
    private var cache: AssistantMarkdownBlockHeightCache?
    private var typographyRevision = 0

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

        // Ancestor fallback: the hosted list sometimes lets the text view's
        // own link gesture lose arbitration. A tap recognizer on the stack
        // still sees the touch; resolve it to the descendant text view.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleAncestorLinkTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The latest document. Building happens on the next layout pass, when the
    /// representable has its real width.
    func install(document: AssistantMarkdownDocument?, key: String,
                 displayScale: CGFloat, generation: Int,
                 cache: AssistantMarkdownBlockHeightCache?,
                 typographyRevision: Int) {
        self.document = document
        self.documentKey = key
        self.displayScale = displayScale
        self.generation = generation
        self.cache = cache
        self.typographyRevision = typographyRevision
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        guard width > 0 else { return }
        let widthChanged = abs(width - builtWidth) > 0.5
        guard widthChanged || documentKey != builtKey else { return }
        builtWidth = width
        builtKey = documentKey
        applyDocument(width: width, widthChanged: widthChanged)
    }

    @objc private func handleAncestorLinkTap(_ recognizer: UITapGestureRecognizer) {
        _ = openLink(in: self, at: recognizer.location(in: self))
    }

    private func openLink(in view: UIView, at point: CGPoint) -> Bool {
        if let textView = view as? AssistantMarkdownBlockTextView {
            let local = textView.convert(point, from: self)
            if textView.bounds.contains(local), textView.openLink(at: local) {
                return true
            }
        }
        for subview in view.subviews {
            if openLink(in: subview, at: point) { return true }
        }
        return false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    private func enableTextInteraction(in view: UIView) {
        if view is AssistantCodeBlockView || view is AssistantTableBlockView {
            return
        }
        if let textView = view as? AssistantMarkdownBlockTextView {
            textView.enableTextInteraction()
        }
        for subview in view.subviews {
            enableTextInteraction(in: subview)
        }
    }

    /// Keep the blocks whose identity survived the batch, update only the
    /// content that changed, and append the new tail. The official cell keeps
    /// its `MarkdownTextCellRow.leaves` the same way; a full rebuild happens
    /// only when the document's generation changed (a correction, a typography
    /// change, or a fallback document without block identities).
    private func applyDocument(width: CGFloat, widthChanged: Bool) {
        guard let document else {
            UIView.performWithoutAnimation { removeRecords(from: 0) }
            builtGeneration = generation
            return
        }
        let blocks = document.blocks
        let keys = document.blockKeys
        let digests = document.blockDigests
        let keyed = keys.count == blocks.count && digests.count == blocks.count
        guard keyed, CodeStreamingIncremental.enabled,
              builtGeneration == generation else {
            rebuild(document, width: width)
            return
        }
        #if DEBUG
        CodePageBuildStats.incrementalUpdates += 1
        #endif

        UIView.performWithoutAnimation {
            // Longest prefix whose block identity survived the batch.
            var keep = min(records.count, blocks.count)
            var index = 0
            while index < keep, records[index].key == keys[index] { index += 1 }
            keep = index
            removeRecords(from: keep)

            for index in 0..<keep {
                updateRecord(at: index, block: blocks[index], digest: digests[index],
                             width: width, widthChanged: widthChanged)
            }
            for index in keep..<blocks.count {
                appendRecord(block: blocks[index], key: keys[index],
                             digest: digests[index], width: width)
            }
            updateSpacing(document: document)
        }
        builtGeneration = generation
    }

    private func rebuild(_ document: AssistantMarkdownDocument, width: CGFloat) {
        #if DEBUG
        CodePageBuildStats.fullRebuilds += 1
        #endif
        UIView.performWithoutAnimation {
            removeRecords(from: 0)
            let keys = document.blockKeys
            let digests = document.blockDigests
            let keyed = keys.count == document.blocks.count
                && digests.count == document.blocks.count
            for (index, block) in document.blocks.enumerated() {
                if keyed {
                    appendRecord(block: block, key: keys[index],
                                 digest: digests[index], width: width)
                } else {
                    // A document without block identities (the plain
                    // fallback) is rebuilt as a whole on every change.
                    appendRecord(block: block, key: "unkeyed:\(index)",
                                 digest: 0, width: width)
                }
            }
            updateSpacing(document: document)
        }
        builtGeneration = generation
    }

    /// One view for a block, with its measured height installed as a required
    /// constraint. The height comes from the same function the representable's
    /// `sizeThatFits` sums.
    private func makeRecord(block: AssistantMarkdownBlock, key: String,
                            digest: Int, width: CGFloat) -> Record {
        let made = AssistantMarkdownBlockViewFactory.make(
            block, width: width, displayScale: displayScale,
            interactiveText: true)
        // Body text (including list/quote paragraphs) gets system
        // link/selection interaction. Fenced code owns its copy button and
        // horizontal scroll; tables keep their own link lift/menu, so
        // those subtrees stay inert.
        enableTextInteraction(in: made.view)
        let constraint = made.view.heightAnchor.constraint(equalToConstant: made.height)
        constraint.isActive = true
        return Record(key: key, kind: block.kindName, digest: digest,
                      view: made.view, constraint: constraint)
    }

    private func appendRecord(block: AssistantMarkdownBlock, key: String,
                              digest: Int, width: CGFloat) {
        let record = makeRecord(block: block, key: key, digest: digest, width: width)
        stack.addArrangedSubview(record.view)
        records.append(record)
    }

    private func replaceRecord(at index: Int, block: AssistantMarkdownBlock,
                               key: String, digest: Int, width: CGFloat) {
        let old = records[index]
        let record = makeRecord(block: block, key: key, digest: digest, width: width)
        old.constraint.isActive = false
        stack.removeArrangedSubview(old.view)
        old.view.removeFromSuperview()
        stack.insertArrangedSubview(record.view, at: index)
        records[index] = record
    }

    private func removeRecords(from index: Int) {
        guard index < records.count else { return }
        for record in records[index...].reversed() {
            record.constraint.isActive = false
            stack.removeArrangedSubview(record.view)
            record.view.removeFromSuperview()
        }
        records.removeSubrange(index...)
    }

    /// Update one block whose identity survived. Text and code views update in
    /// place; containers (list/quote/table/image/math) are replaced until each
    /// grows its own incremental path.
    private func updateRecord(at index: Int, block: AssistantMarkdownBlock,
                              digest: Int, width: CGFloat, widthChanged: Bool) {
        let record = records[index]
        guard record.kind == block.kindName else {
            replaceRecord(at: index, block: block, key: record.key,
                          digest: digest, width: width)
            return
        }
        switch block {
        case .text(let text):
            guard let view = record.view as? AssistantMarkdownBlockTextView else {
                replaceRecord(at: index, block: block, key: record.key,
                              digest: digest, width: width)
                return
            }
            if record.digest != digest {
                view.attributedText = text.attributed
            }
            if record.digest != digest || widthChanged {
                record.constraint.constant = height(
                    of: block, key: record.key, digest: digest, width: width)
            }
        case .code(let code):
            guard let view = record.view as? AssistantCodeBlockView else {
                replaceRecord(at: index, block: block, key: record.key,
                              digest: digest, width: width)
                return
            }
            if record.digest != digest {
                record.constraint.constant = view.update(codeBlock: code)
            }
        case .divider:
            break
        case .list, .quote, .table, .image, .math:
            if record.digest != digest || widthChanged {
                replaceRecord(at: index, block: block, key: record.key,
                              digest: digest, width: width)
                return
            }
        }
        records[index].digest = digest
    }

    private func height(of block: AssistantMarkdownBlock, key: String,
                        digest: Int, width: CGFloat) -> CGFloat {
        AssistantMarkdownTextLayout.height(
            of: block, width: width, displayScale: displayScale,
            key: key, digest: digest,
            typographyRevision: typographyRevision, cache: cache)
    }

    /// Textual collapses adjacent block margins (max, not sum); the
    /// measurement path uses the same rule, so the stack must too.
    private func updateSpacing(document: AssistantMarkdownDocument) {
        guard records.count == document.blocks.count else { return }
        for index in 1..<max(1, document.blocks.count) {
            guard records.indices.contains(index - 1) else { break }
            stack.setCustomSpacing(
                AssistantMarkdownTextLayout.topLevelSpacing(after: index - 1, in: document),
                after: records[index - 1].view)
        }
    }

    #if DEBUG
    /// Gate probes: the streaming path must keep the same view instances for
    /// blocks whose keys survive, and only append new ones.
    var debugBlockViews: [UIView] { records.map(\.view) }
    var debugRecordKeys: [String] { records.map(\.key) }
    #endif
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
