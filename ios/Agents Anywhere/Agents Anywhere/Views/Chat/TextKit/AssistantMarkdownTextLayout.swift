#if canImport(UIKit)
import Textual
import UIKit

/// TextKit 2 measurement for the assistant body. The same attributed strings
/// are handed to the block text views, so measurement and rendering are one
/// engine (the shape the Claude app uses: `NSTextLayoutManager` with a
/// detached `NSTextContainer`).
@MainActor
enum AssistantMarkdownTextLayout {
    /// Textual's CSS-style margin collapsing: the gap between two blocks is
    /// the larger of the previous block's bottom margin and the next block's
    /// top margin. The values come from AA's existing typography scheme, not
    /// from a redesign.
    struct BlockMargins {
        let top: CGFloat?
        let bottom: CGFloat?
    }

    static func margins(for block: AssistantMarkdownBlock) -> BlockMargins {
        // Textual's `.fontScaled` multiplies the reference ratio by the current
        // body size; keep the same conversion here.
        let scale = ChatMetrics.bodySize / ChatMetrics.referenceBodySize
        func scaled(_ points: CGFloat) -> CGFloat { points * scale }
        switch block {
        case .text(let text):
            return BlockMargins(
                top: scaled(ChatMetrics.paragraphSpacing),
                bottom: text.headingLevel == nil ? nil : scaled(8))
        case .code, .table:
            return BlockMargins(
                top: scaled(ChatMetrics.codeBlockMargin),
                bottom: scaled(ChatMetrics.codeBlockMargin))
        case .list, .quote, .image, .math:
            // The legacy renderer treats an image or a display formula as a
            // paragraph block, so it takes the paragraph's top margin.
            return BlockMargins(top: scaled(ChatMetrics.paragraphSpacing), bottom: nil)
        case .divider:
            // Textual's themed break spacing is `.fontScaled(top: 1.6,
            // bottom: 1.6)`; both sides carry it so the collapsed margin with
            // a neighbouring paragraph is the same 1.6em.
            let spacing = 1.6 * ChatMetrics.bodySize
            return BlockMargins(top: spacing, bottom: spacing)
        }
    }

    static func spacing(after block: AssistantMarkdownBlock,
                        before next: AssistantMarkdownBlock) -> CGFloat {
        max(margins(for: block).bottom ?? 0,
            margins(for: next).top ?? 0)
    }

    /// Height of one text block, wrapped to `width`. Pixel-rounded the same way
    /// `MarkdownBlockSizing` rounds a Textual block.
    static func height(of attributed: NSAttributedString,
                       width: CGFloat,
                       displayScale: CGFloat) -> CGFloat {
        guard width > 0, width.isFinite, attributed.length > 0 else { return 0 }
        let storage = NSTextContentStorage()
        storage.attributedString = attributed
        let manager = NSTextLayoutManager()
        storage.addTextLayoutManager(manager)
        let container = NSTextContainer(
            size: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.textContainer = container
        manager.ensureLayout(for: manager.documentRange)
        let used = manager.usageBoundsForTextContainer.maxY
        guard used.isFinite, used > 0 else { return 0 }
        return roundUp(used, scale: displayScale)
    }

    /// TextKit's used size for an attributed string laid out without wrapping.
    /// Code blocks scroll horizontally, so their intrinsic width is what sets
    /// the scroll content and their height must not depend on the column.
    static func intrinsicSize(of attributed: NSAttributedString,
                              displayScale: CGFloat) -> CGSize {
        guard attributed.length > 0 else { return .zero }
        let storage = NSTextContentStorage()
        storage.attributedString = attributed
        let manager = NSTextLayoutManager()
        storage.addTextLayoutManager(manager)
        let container = NSTextContainer(
            size: CGSize(width: 1_000_000, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.textContainer = container
        manager.ensureLayout(for: manager.documentRange)
        let used = manager.usageBoundsForTextContainer
        guard used.width.isFinite, used.height.isFinite, used.height > 0 else { return .zero }
        return CGSize(width: roundUp(used.width, scale: displayScale),
                      height: roundUp(used.height, scale: displayScale))
    }

    /// Code text size, memoised by the same key + digest the height cache
    /// uses. The height computation and the card's own init both need the
    /// unbounded layout of the source; without this they laid the whole code
    /// block out twice, and a long card was the single most expensive block on
    /// the device probe (max 60 ms).
    private struct IntrinsicKey: Hashable {
        let key: String
        let digest: Int
        let displayScale: CGFloat
        let typographyRevision: Int
    }

    private static var intrinsicSizes: [IntrinsicKey: CGSize] = [:]
    private static var intrinsicOrder: [IntrinsicKey] = []
    private static let intrinsicLimit = 256

    static func cachedIntrinsicSize(of attributed: NSAttributedString,
                                    displayScale: CGFloat,
                                    key: String?,
                                    digest: Int,
                                    typographyRevision: Int) -> CGSize {
        guard let key else {
            return intrinsicSize(of: attributed, displayScale: displayScale)
        }
        let scale = displayScale > 0 && displayScale.isFinite ? displayScale : 1
        let cacheKey = IntrinsicKey(
            key: key, digest: digest,
            displayScale: (scale * 100).rounded() / 100,
            typographyRevision: typographyRevision)
        if let hit = intrinsicSizes[cacheKey] { return hit }
        let size = intrinsicSize(of: attributed, displayScale: displayScale)
        intrinsicSizes[cacheKey] = size
        intrinsicOrder.append(cacheKey)
        if intrinsicOrder.count > intrinsicLimit {
            let drop = intrinsicOrder.count - intrinsicLimit
            for old in intrinsicOrder.prefix(drop) { intrinsicSizes[old] = nil }
            intrinsicOrder.removeFirst(drop)
        }
        return size
    }

    /// Height of any block, from the same measurements its view installs as
    /// explicit constraints.
    static func height(of block: AssistantMarkdownBlock,
                       width: CGFloat,
                       displayScale: CGFloat) -> CGFloat {
        guard width > 0, width.isFinite else { return 0 }
        switch block {
        case .text(let text):
            return height(of: text.attributed, width: width, displayScale: displayScale)
        case .list(let list):
            var total: CGFloat = 0
            for (index, item) in list.items.enumerated() {
                if index > 0 { total += list.itemSpacing }
                let contentWidth = max(0, width - list.contentIndent(for: item.marker))
                total += stackHeight(of: item.blocks,
                                     width: contentWidth,
                                     uniformSpacing: list.itemSpacing,
                                     displayScale: displayScale)
            }
            return roundUp(total, scale: displayScale)
        case .quote(let quote):
            let contentWidth = max(0, width - quote.inset)
            let total = stackHeight(of: quote.blocks,
                                    width: contentWidth,
                                    displayScale: displayScale)
            return roundUp(total, scale: displayScale)
        case .code(let code):
            let divider = displayScale > 0 && displayScale.isFinite
                ? 1 / displayScale : 1
            let textHeight = intrinsicSize(of: code.code,
                                           displayScale: displayScale).height
            return roundUp(code.headerHeight + divider
                           + code.contentPadding * 2 + textHeight,
                           scale: displayScale)
        case .table(let table):
            // Column widths are capped and fixed at parse time, so the grid
            // scrolls sideways instead of reflowing against the row width.
            return roundUp(table.totalHeight, scale: displayScale)
        case .image(let image):
            // The reserved box is the legacy attachment's footprint; the
            // loaded image only ever draws inside it.
            return roundUp(image.reservedSize(columnWidth: width).height,
                           scale: displayScale)
        case .math(let math):
            return roundUp(math.metrics(columnWidth: width).size.height,
                           scale: displayScale)
        case .divider:
            // `Divider().frame(minHeight: 1)`.
            return roundUp(1, scale: displayScale)
        }
    }

    /// Column widths and row heights for a table, from the same TextKit engine
    /// the cell text views use. The table's own width is the sum of the columns
    /// and does not depend on the timeline column.
    static func tableMetrics(rows: [[NSAttributedString]],
                             paddingHorizontal: CGFloat,
                             paddingVertical: CGFloat) -> (widths: [CGFloat], heights: [CGFloat]) {
        let columnCount = max(1, rows.map { $0.count }.max() ?? 0)
        var widths = Array(repeating: paddingHorizontal * 2, count: columnCount)
        // Metrics are baked into the document, before a cell knows the
        // display scale; rounding to whole points keeps the two consumers
        // identical and costs at most one point against the product.
        let metricScale: CGFloat = 1
        for row in rows {
            for (column, cell) in row.enumerated() where column < columnCount {
                let ideal = intrinsicSize(of: cell, displayScale: metricScale).width
                widths[column] = min(
                    max(widths[column], ideal + paddingHorizontal * 2),
                    ChatMetrics.tableContentWidthCap)
            }
        }
        let heights = rows.map { row -> CGFloat in
            var tallest: CGFloat = 0
            for (column, cell) in row.enumerated() where column < columnCount {
                let textWidth = max(0, widths[column] - paddingHorizontal * 2)
                tallest = max(tallest,
                    height(of: cell, width: textWidth, displayScale: metricScale)
                        + paddingVertical * 2)
            }
            return tallest
        }
        return (widths, heights)
    }

    /// Height of a vertical block stack. Individual blocks are already
    /// pixel-rounded; the caller decides whether the sum needs its own round.
    static func stackHeight(of blocks: [AssistantMarkdownBlock],
                            width: CGFloat,
                            uniformSpacing: CGFloat? = nil,
                            displayScale: CGFloat) -> CGFloat {
        var total: CGFloat = 0
        for (index, block) in blocks.enumerated() {
            if index > 0 {
                total += uniformSpacing
                    ?? spacing(after: blocks[index - 1], before: block)
            }
            total += height(of: block, width: width, displayScale: displayScale)
        }
        return total
    }

    /// The legacy renderer places each `MarkdownBlockSnapshot` in a VStack with
    /// this spacing; blocks inside one snapshot use Textual's collapsed
    /// margins instead.
    static let snapshotSpacing: CGFloat = 12

    static func topLevelSpacing(after index: Int,
                                in document: AssistantMarkdownDocument) -> CGFloat {
        guard document.blocks.indices.contains(index + 1),
              document.blockGroups.indices.contains(index),
              document.blockGroups.indices.contains(index + 1) else { return 0 }
        // [E] The Code page's official Markdown renderer uses one block gap
        // (`blockSpacing = 16`, 0x10170a9c8). AA's Chat path keeps its
        // snapshot boundary and collapsed margins.
        if let blockSpacing = document.blockSpacing {
            if let roles = document.codeRoles,
               let headingGap = headingGap(
                    after: document.blocks[index],
                    before: document.blocks[index + 1],
                    roles: roles) {
                return headingGap
            }
            return blockSpacing
        }
        if document.blockGroups[index] != document.blockGroups[index + 1] {
            return snapshotSpacing
        }
        return spacing(after: document.blocks[index],
                       before: document.blocks[index + 1])
    }

    /// Heading spacing for the Code page, expressed as the gap between two
    /// top-level blocks so the renderer's stack and this measurement share one
    /// number (a paragraph-style `paragraphSpacingBefore/After` inside a
    /// single-block text view would be outside the stack's control).
    ///
    /// Evidence: `EVIDENCE/round19/typography-inline.md` §1.2 — before =
    /// size × 0.4 (9.6 / 8.0 / 6.8), after = size × 0.6 (14.4 / 12.0 / 10.2).
    /// TextKit's paragraph spacing applies the previous paragraph's after and
    /// the next paragraph's before, so a heading adjacent to another heading
    /// adds both.
    private static func headingGap(after block: AssistantMarkdownBlock,
                                   before next: AssistantMarkdownBlock,
                                   roles: CodePageMarkdownRoles) -> CGFloat? {
        let bottom = headingLevel(of: block).map {
            roles.headingSize(for: $0) * roles.headingBottomSpacingMultiplier
        }
        let top = headingLevel(of: next).map {
            roles.headingSize(for: $0) * roles.headingTopSpacingMultiplier
        }
        guard bottom != nil || top != nil else { return nil }
        return (bottom ?? 0) + (top ?? 0)
    }

    private static func headingLevel(of block: AssistantMarkdownBlock) -> Int? {
        guard case .text(let text) = block else { return nil }
        return text.headingLevel
    }

    /// Sum of the block heights plus the same spacing the cell stack uses.
    static func measure(_ document: AssistantMarkdownDocument,
                        width: CGFloat,
                        displayScale: CGFloat) -> CGFloat {
        measure(document, width: width, displayScale: displayScale,
                cache: nil, typographyRevision: 0)
    }

    /// The same sum with per-block memoisation. A streaming tick reparses only
    /// the open tail, so every settled block keeps its key and digest and hits
    /// the cache; only the tail block runs TextKit again.
    static func measure(_ document: AssistantMarkdownDocument,
                        width: CGFloat,
                        displayScale: CGFloat,
                        cache: AssistantMarkdownBlockHeightCache?,
                        typographyRevision: Int = 0) -> CGFloat {
        let keyed = document.blockKeys.count == document.blocks.count
            && document.blockDigests.count == document.blocks.count
        var total: CGFloat = 0
        for (index, block) in document.blocks.enumerated() {
            if index > 0 { total += topLevelSpacing(after: index - 1, in: document) }
            if keyed {
                total += height(of: block, width: width, displayScale: displayScale,
                                key: document.blockKeys[index],
                                digest: document.blockDigests[index],
                                typographyRevision: typographyRevision,
                                cache: cache)
            } else {
                total += height(of: block, width: width, displayScale: displayScale)
            }
        }
        return total
    }

    /// Height of one keyed block, memoised when a cache is supplied. The key
    /// carries the content digest, width bucket, display scale and typography
    /// revision, so no caller can inherit a height from a different layout.
    static func height(of block: AssistantMarkdownBlock,
                       width: CGFloat,
                       displayScale: CGFloat,
                       key: String?,
                       digest: Int,
                       typographyRevision: Int,
                       cache: AssistantMarkdownBlockHeightCache?) -> CGFloat {
        guard let key, let cache else {
            return height(of: block, width: width, displayScale: displayScale)
        }
        if case .code(let code) = block {
            // The intrinsic size is the whole cost of a code block's height;
            // the arithmetic around it is free, and the card's init reads the
            // same entry instead of laying the source out again.
            let textSize = cachedIntrinsicSize(
                of: code.code, displayScale: displayScale, key: key,
                digest: digest, typographyRevision: typographyRevision)
            let divider = displayScale > 0 && displayScale.isFinite
                ? 1 / displayScale : 1
            return roundUp(code.headerHeight + divider
                           + code.contentPadding * 2 + textSize.height,
                           scale: displayScale)
        }
        return cache.height(
            blockKey: key, digest: digest, width: width,
            displayScale: displayScale,
            typographyRevision: typographyRevision
        ) {
            height(of: block, width: width, displayScale: displayScale)
        }
    }

    private static func roundUp(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0 else { return 0 }
        let s = scale > 0 && scale.isFinite ? scale : 1
        return ceil(value * s) / s
    }
}

/// Per-block height memo for the streaming text path. The official leaf caches
/// its block heights by block identity; this cache is keyed by the same
/// identity plus every input that can change a height, so a hit is only
/// possible when the answer would be identical.
///
/// Eviction is FIFO at a fixed ceiling: a long reply has a few hundred blocks
/// at most, and the cache is already reset by the leaf when typography or the
/// document generation changes.
@MainActor
final class AssistantMarkdownBlockHeightCache {
    /// One cache for the measurer and the leaf. False hits are impossible
    /// because the key carries the content digest; duplicate entries for two
    /// replies are only wasted slots, not wrong heights.
    static let shared = AssistantMarkdownBlockHeightCache()

    private struct Key: Hashable {
        let block: String
        let digest: Int
        let width: CGFloat
        let displayScale: CGFloat
        let typographyRevision: Int
    }

    private var storage: [Key: CGFloat] = [:]
    private var order: [Key] = []
    private let limit: Int

    init(limit: Int = 512) {
        self.limit = max(1, limit)
    }

    var count: Int { storage.count }

    func height(blockKey: String, digest: Int, width: CGFloat,
                displayScale: CGFloat, typographyRevision: Int,
                compute: () -> CGFloat) -> CGFloat {
        let key = Key(block: blockKey, digest: digest,
                      width: TimelineHeightKey.quantize(width),
                      displayScale: Self.quantizeScale(displayScale),
                      typographyRevision: typographyRevision)
        if let cached = storage[key] {
            #if DEBUG
            CodePageBuildStats.heightCacheHits += 1
            #endif
            return cached
        }
        #if DEBUG
        CodePageBuildStats.heightCacheMisses += 1
        #endif
        let value = compute()
        storage[key] = value
        order.append(key)
        if order.count > limit {
            let evicted = order.removeFirst()
            storage.removeValue(forKey: evicted)
        }
        return value
    }

    func removeAll() {
        storage.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
    }

    private static func quantizeScale(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite, scale > 0 else { return 1 }
        return max(1, (scale * 2).rounded() / 2)
    }
}

/// One TextKit 2 block, drawn by this view itself.
///
/// `UITextView` cost 0.8 ms to create and 0.3 ms to assign per block; a row
/// carries six of them, which was most of the 7 ms `codeStack.build` measured
/// on device (the 120 Hz frame budget is 8.3 ms).
///
/// The official renderer has three leaves behind a remote flag
/// (`EVIDENCE/UPSTREAM/part-aa-markdown-ui.md` §1.4, §3 Q1): `MarkdownUITextView`
/// (a `UITextView` subclass, the default), `MarkdownTextView` (a plain
/// `UIView` that self-draws its layout fragments) and
/// `SelectableMarkdownTextView` (the same self-drawn view plus
/// `UITextInteraction` and its own `UITextInput`). This view is the second
/// shape. The third is what the selection layer will need when it comes back.
final class AssistantMarkdownBlockTextView: UIView, UIGestureRecognizerDelegate {
    private let ownStorage: NSTextContentStorage
    private let ownLayoutManager: NSTextLayoutManager
    private let ownContainer: NSTextContainer

    /// The backing storage, shared with the layout manager. The code card's
    /// streaming highlight path edits it in place, so it is exposed as-is.
    var textStorage: NSTextStorage {
        if let storage = ownStorage.textStorage { return storage }
        ownStorage.attributedString = ownStorage.attributedString
        if let storage = ownStorage.textStorage { return storage }
        assertionFailure("NSTextContentStorage has no backing text storage")
        return NSTextStorage()
    }

    /// What is actually laid out — the storage, not `sourceAttributed`: the
    /// code card appends to the storage without going through the setter.
    /// Go through the getter: `NSTextContentStorage.textStorage` is nil until
    /// it is materialised, and a nil read here silently skipped every glyph
    /// (only the chip overlay, which reads the layout manager, kept drawing).
    private var renderedLength: Int {
        ownStorage.offset(from: ownStorage.documentRange.location,
                          to: ownStorage.documentRange.endLocation)
    }

    /// The string the owner assigned, unchanged. The storage holds a copy
    /// whose link runs are recoloured (see `recolouringLinks`), so the getter
    /// keeps answering what was set — callers diff it against the document to
    /// decide whether a block needs updating.
    private var sourceAttributed: NSAttributedString?

    var attributedText: NSAttributedString? {
        get { sourceAttributed }
        set {
            sourceAttributed = newValue
            selectionOffsets = nil
            ownStorage.attributedString = Self.recolouringLinks(newValue ?? NSAttributedString())
            setNeedsDisplay()
        }
    }

    /// `UITextView` painted links with `linkTextAttributes` — body colour and
    /// a single underline (`CANONICAL/06-visuals-assets.md`: links are not
    /// blue) — overriding whatever colour the document builder put on the run.
    /// A layout manager draws the run's own colour, so the override has to be
    /// written into the string this view lays out.
    private static func recolouringLinks(_ attributed: NSAttributedString) -> NSAttributedString {
        let full = NSRange(location: 0, length: attributed.length)
        guard attributed.length > 0 else { return attributed }
        var hasLink = false
        attributed.enumerateAttribute(.link, in: full) { value, _, stop in
            if value != nil {
                hasLink = true
                stop.pointee = true
            }
        }
        guard hasLink else { return attributed }
        let copy = NSMutableAttributedString(attributedString: attributed)
        copy.enumerateAttribute(.link, in: full) { value, range, _ in
            guard value != nil else { return }
            copy.addAttributes([
                .foregroundColor: CodePageTheme.markdownTextUIColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: range)
        }
        return copy
    }

    var textLayoutManager: NSTextLayoutManager? { ownLayoutManager }
    var textContainer: NSTextContainer { ownContainer }

    /// Set by the owner when it wants a non-default URL router.
    var openLink: ((URL) -> Void)?

    private var textInteractionEnabled = false
    private var linkTapRecognizer: UITapGestureRecognizer?
    private var lastOpened: (url: URL, at: TimeInterval)?
    private var lastMeasuredWidth: CGFloat = -1
    private var lastContainerSize: CGSize = .zero

    /// Selection in UTF-16 offsets; `nil` when nothing is selected.
    private var selectionOffsets: (start: Int, end: Int)?
    private weak var textInputDelegateStorage: UITextInputDelegate?
    private lazy var textTokenizer = UITextInputStringTokenizer(textInput: self)

    init(interactive: Bool = false) {
        let storage = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        let container = NSTextContainer(
            size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.textContainer = container
        storage.addTextLayoutManager(layout)
        // Materialise the backing storage up front: `NSTextContentStorage`
        // creates it lazily, and the code card edits it before any
        // `attributedText` has been assigned. Without this the getter would
        // hand out a detached copy (edits never reach the layout) and the
        // next insert would throw an NSRangeException.
        storage.attributedString = NSAttributedString()
        ownStorage = storage
        ownLayoutManager = layout
        ownContainer = container
        super.init(frame: .zero)
        #if DEBUG
        CodePageBuildStats.textViewCreations += 1
        #endif
        isUserInteractionEnabled = interactive
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        container.widthTracksTextView = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        // `UITextInteraction` drives the gestures and the handles; the
        // highlight is ours, because the fragments here are drawn by hand.
        if let (start, end) = selectionOffsets, end > start {
            context.setFillColor(UIColor.tintColor.withAlphaComponent(0.28).cgColor)
            for frame in selectionFrames(from: start, to: end) {
                context.fill(frame)
            }
        }
        guard renderedLength > 0 else { return }
        ownLayoutManager.ensureLayout(for: ownLayoutManager.documentRange)
        ownLayoutManager.enumerateTextLayoutFragments(
            from: ownLayoutManager.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            context.saveGState()
            context.translateBy(x: fragment.layoutFragmentFrame.minX,
                                y: fragment.layoutFragmentFrame.minY)
            for line in fragment.textLineFragments {
                line.draw(at: line.typographicBounds.origin, in: context)
            }
            context.restoreGState()
            return true
        }
    }

    // MARK: - Interaction

    /// Body text: links tap, long press selects, and the edit menu copies.
    func enableTextInteraction() {
        guard !textInteractionEnabled else { return }
        textInteractionEnabled = true
        isUserInteractionEnabled = true
        if openLink == nil {
            openLink = { url in
                guard let scheme = url.scheme?.lowercased(),
                      ["http", "https", "mailto", "tel"].contains(scheme) else {
                    return
                }
                UIApplication.shared.open(url)
            }
        }
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleLinkTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        addGestureRecognizer(tap)
        linkTapRecognizer = tap
        // The official selectable leaf is this view plus
        // `UITextInteraction` and its own `UITextInput`
        // (`EVIDENCE/UPSTREAM/part-aa-markdown-ui.md` §1.4); the interaction
        // brings word selection, the loupe, the drag handles and the edit
        // menu, and talks to the text through `UITextInput`.
        let interaction = UITextInteraction(for: .nonEditable)
        interaction.textInput = self
        addInteraction(interaction)
        textSelectionInteraction = interaction
    }

    private var textSelectionInteraction: UITextInteraction?

    @discardableResult
    func openLink(at point: CGPoint) -> Bool {
        guard textInteractionEnabled,
              let index = characterIndex(at: point),
              let attributed = attributedText,
              attributed.length > 0 else { return false }
        let clamped = min(max(index, 0), attributed.length - 1)
        guard let url = attributed.attribute(.link, at: clamped,
                                             effectiveRange: nil) as? URL
        else { return false }
        open(url)
        return true
    }

    @objc private func handleLinkTap(_ recognizer: UITapGestureRecognizer) {
        openLink(at: recognizer.location(in: self))
    }

    /// Resolve a tap to a character index by walking the laid-out lines. The
    /// line fragment answers in its own coordinates, so the point is rebased
    /// twice: fragment origin, then the line's typographic origin.
    private func characterIndex(at point: CGPoint) -> Int? {
        ownLayoutManager.ensureLayout(for: ownLayoutManager.documentRange)
        guard let fragment = ownLayoutManager.textLayoutFragment(for: point) else { return nil }
        for line in fragment.textLineFragments {
            let origin = CGPoint(
                x: fragment.layoutFragmentFrame.minX + line.typographicBounds.minX,
                y: fragment.layoutFragmentFrame.minY + line.typographicBounds.minY)
            let bounds = CGRect(origin: origin, size: line.typographicBounds.size)
                .insetBy(dx: 0, dy: -2)
            guard bounds.contains(point) else { continue }
            let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
            return line.characterRange.location + line.characterIndex(for: local)
        }
        return nil
    }

    /// Both the system link action and the fallback tap can fire for one tap;
    /// keep the URL open once.
    private func open(_ url: URL) {
        let now = Date.timeIntervalSinceReferenceDate
        if let lastOpened, lastOpened.url == url, now - lastOpened.at < 0.4 {
            return
        }
        lastOpened = (url, now)
        openLink?(url)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    // MARK: - Selection

    private var textLength: Int { sourceAttributed?.length ?? 0 }

    private func location(atOffset offset: Int) -> NSTextLocation? {
        ownStorage.location(ownStorage.documentRange.location, offsetBy: offset)
    }

    private func offset(of location: NSTextLocation) -> Int {
        ownStorage.offset(from: ownStorage.documentRange.location, to: location)
    }

    /// Segment rectangles for `[start, end)`, the same enumeration the reveal
    /// mask uses.
    func selectionFrames(from start: Int, to end: Int) -> [CGRect] {
        guard end > start,
              let a = location(atOffset: start),
              let b = location(atOffset: end),
              let range = NSTextRange(location: a, end: b) else { return [] }
        ownLayoutManager.ensureLayout(for: ownLayoutManager.documentRange)
        var frames: [CGRect] = []
        ownLayoutManager.enumerateTextSegments(in: range, type: .standard, options: []) {
            _, frame, _, _ in
            frames.append(frame)
            return true
        }
        return frames
    }

    private func characterFrame(at offset: Int) -> CGRect? {
        guard offset >= 0, offset < textLength,
              let a = location(atOffset: offset),
              let b = location(atOffset: offset + 1),
              let range = NSTextRange(location: a, end: b) else { return nil }
        ownLayoutManager.ensureLayout(for: ownLayoutManager.documentRange)
        var frame = CGRect.zero
        ownLayoutManager.enumerateTextSegments(in: range, type: .standard, options: []) {
            _, rect, _, _ in
            frame = rect
            return false
        }
        return frame.isEmpty ? nil : frame
    }

    private func caretFrame(at offset: Int) -> CGRect? {
        let clamped = min(max(offset, 0), textLength)
        if clamped < textLength, let rect = characterFrame(at: clamped) {
            return CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height)
        }
        if clamped > 0, let rect = characterFrame(at: clamped - 1) {
            return CGRect(x: rect.maxX, y: rect.minY, width: 2, height: rect.height)
        }
        return nil
    }

    private func wordRange(at offset: Int) -> UITextRange? {
        guard textLength > 0 else { return nil }
        let clamped = min(max(offset, 0), textLength - 1)
        let position = MarkdownTextOffsetPosition(clamped)
        if let range = textTokenizer.rangeEnclosingPosition(
            position, with: .word, inDirection: .storage(.forward)) as? MarkdownTextOffsetRange,
           range.startOffset != range.endOffset {
            return range
        }
        return MarkdownTextOffsetRange(clamped, min(clamped + 1, textLength))
    }

    private func notifySelectionChanged() {
        textInputDelegateStorage?.selectionWillChange(self)
        textInputDelegateStorage?.selectionDidChange(self)
    }

    override var canBecomeFirstResponder: Bool { textInteractionEnabled }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)) {
            guard let selectionOffsets else { return false }
            return selectionOffsets.end > selectionOffsets.start
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func copy(_ sender: Any?) {
        guard let selectionOffsets, selectionOffsets.end > selectionOffsets.start else { return }
        let text = (sourceAttributed?.string ?? "") as NSString
        UIPasteboard.general.string = text.substring(
            with: NSRange(location: selectionOffsets.start,
                          length: selectionOffsets.end - selectionOffsets.start))
    }

    // MARK: - Chip overlay

    /// The inline-code chip background is painted by the overlay in
    /// `AssistantMarkdownTextBlockView`, not here (`draw(_:)` is clipped to the
    /// view's bounds, which cut the chip's 4 pt padding off a line start).
    weak var chipOverlay: AssistantInlineCodeChipOverlayView?

    override func setNeedsDisplay() {
        super.setNeedsDisplay()
        chipOverlay?.setNeedsDisplay()
    }

    override func setNeedsDisplay(_ rect: CGRect) {
        super.setNeedsDisplay(rect)
        chipOverlay?.setNeedsDisplay()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previous) {
            setNeedsDisplay()
        }
    }

    // MARK: - Measurement

    /// Give the container the row width without laying the text out. The block
    /// height comes from `AssistantMarkdownTextLayout.height`, which already
    /// laid the text out at this width; laying it out again here would price
    /// every text block twice. The view lays out once, when it first draws.
    func prepareLayout(width: CGFloat) {
        guard width > 0, width.isFinite else { return }
        let target = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        if ownContainer.size != target {
            ownContainer.size = target
            lastContainerSize = target
        }
    }

    func measuredHeight(width: CGFloat, displayScale: CGFloat) -> CGFloat {
        guard width > 0, width.isFinite,
              renderedLength > 0 else { return 0 }
        prepareLayout(width: width)
        ownLayoutManager.ensureLayout(for: ownLayoutManager.documentRange)
        let used = ownLayoutManager.usageBoundsForTextContainer.maxY
        guard used.isFinite, used > 0 else { return 0 }
        let scale = displayScale > 0 && displayScale.isFinite ? displayScale : 1
        return ceil(used * scale) / scale
    }

    override var intrinsicContentSize: CGSize {
        guard bounds.width > 0, renderedLength > 0 else {
            return CGSize(width: UIView.noIntrinsicMetric, height: 0)
        }
        return CGSize(width: UIView.noIntrinsicMetric,
                      height: measuredHeight(width: bounds.width,
                                             displayScale: traitCollection.displayScale))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(bounds.width - lastMeasuredWidth) > 0.5 {
            lastMeasuredWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
        // The code card resizes the container directly; redraw when it moves.
        if ownContainer.size != lastContainerSize {
            lastContainerSize = ownContainer.size
            setNeedsDisplay()
        }
    }
}

// MARK: - UITextInput

extension AssistantMarkdownBlockTextView: UITextInput {
    var selectedTextRange: UITextRange? {
        get {
            guard let selectionOffsets else { return nil }
            return MarkdownTextOffsetRange(selectionOffsets.start, selectionOffsets.end)
        }
        set {
            if let range = newValue as? MarkdownTextOffsetRange {
                selectionOffsets = (range.startOffset, range.endOffset)
            } else if newValue == nil {
                selectionOffsets = nil
            }
            setNeedsDisplay()
            notifySelectionChanged()
        }
    }

    var markedTextRange: UITextRange? { nil }

    var markedTextStyle: [NSAttributedString.Key: Any]? {
        get { nil }
        set {}
    }

    var inputDelegate: UITextInputDelegate? {
        get { textInputDelegateStorage }
        set { textInputDelegateStorage = newValue }
    }

    var tokenizer: UITextInputTokenizer { textTokenizer }

    var beginningOfDocument: UITextPosition { MarkdownTextOffsetPosition(0) }

    var endOfDocument: UITextPosition { MarkdownTextOffsetPosition(textLength) }

    var textInputView: UIView { self }

    var hasText: Bool { textLength > 0 }

    func text(in range: UITextRange) -> String? {
        guard let range = range as? MarkdownTextOffsetRange,
              range.startOffset >= 0, range.endOffset <= textLength else { return nil }
        return ((sourceAttributed?.string ?? "") as NSString).substring(
            with: NSRange(location: range.startOffset,
                          length: range.endOffset - range.startOffset))
    }

    // Read-only: the block never accepts edits, but the protocol requires the
    // entry points.
    func replace(_ range: UITextRange, withText text: String) {}

    func insertText(_ text: String) {}

    func deleteBackward() {}

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {}

    func unmarkText() {}

    func position(within range: UITextRange,
                  farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        guard let range = range as? MarkdownTextOffsetRange else { return nil }
        let forward = direction == .right || direction == .down
        return MarkdownTextOffsetPosition(forward ? range.endOffset : range.startOffset)
    }

    func characterRange(byExtending position: UITextPosition,
                        in direction: UITextLayoutDirection) -> UITextRange? {
        guard let p = position as? MarkdownTextOffsetPosition else { return nil }
        let forward = direction == .right || direction == .down
        let other = min(max(p.offset + (forward ? 1 : -1), 0), textLength)
        return MarkdownTextOffsetRange(p.offset, other)
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let p = position as? MarkdownTextOffsetPosition else { return nil }
        return MarkdownTextOffsetPosition(min(max(p.offset + offset, 0), textLength))
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection,
                  offset: Int) -> UITextPosition? {
        let backwards = direction == .left || direction == .up
        return self.position(from: position, offset: backwards ? -offset : offset)
    }

    func offset(from: UITextPosition, to: UITextPosition) -> Int {
        guard let a = from as? MarkdownTextOffsetPosition,
              let b = to as? MarkdownTextOffsetPosition else { return 0 }
        return b.offset - a.offset
    }

    func textRange(from: UITextPosition, to: UITextPosition) -> UITextRange? {
        guard let a = from as? MarkdownTextOffsetPosition,
              let b = to as? MarkdownTextOffsetPosition else { return nil }
        return MarkdownTextOffsetRange(a.offset, b.offset)
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        guard let a = position as? MarkdownTextOffsetPosition,
              let b = other as? MarkdownTextOffsetPosition else { return .orderedSame }
        if a.offset < b.offset { return .orderedAscending }
        if a.offset > b.offset { return .orderedDescending }
        return .orderedSame
    }

    func firstRect(for range: UITextRange) -> CGRect {
        guard let range = range as? MarkdownTextOffsetRange else { return .zero }
        if let first = selectionFrames(from: range.startOffset, to: range.endOffset).first {
            return convert(first, to: nil)
        }
        if let caret = caretFrame(at: range.startOffset) {
            return convert(caret, to: nil)
        }
        return .zero
    }

    func caretRect(for position: UITextPosition) -> CGRect {
        guard let p = position as? MarkdownTextOffsetPosition,
              let caret = caretFrame(at: p.offset) else { return .zero }
        return caret
    }

    func closestPosition(to point: CGPoint) -> UITextPosition? {
        if let index = characterIndex(at: point) {
            return MarkdownTextOffsetPosition(min(max(index, 0), textLength))
        }
        return MarkdownTextOffsetPosition(point.y > bounds.height / 2 ? textLength : 0)
    }

    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        guard let limit = range as? MarkdownTextOffsetRange,
              let closest = closestPosition(to: point) as? MarkdownTextOffsetPosition else {
            return closestPosition(to: point)
        }
        return MarkdownTextOffsetPosition(
            min(max(closest.offset, limit.startOffset), limit.endOffset))
    }

    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        guard let range = range as? MarkdownTextOffsetRange else { return [] }
        let frames = selectionFrames(from: range.startOffset, to: range.endOffset)
        return frames.enumerated().map { index, frame in
            MarkdownTextSelectionRect(rect: frame,
                                      containsStart: index == 0,
                                      containsEnd: index == frames.count - 1)
        }
    }

    func characterRange(at point: CGPoint) -> UITextRange? {
        guard let index = characterIndex(at: point) else { return nil }
        return wordRange(at: index)
    }

    func baseWritingDirection(for position: UITextPosition,
                              in direction: UITextStorageDirection) -> UITextWritingDirection {
        effectiveUserInterfaceLayoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
    }

    func setBaseWritingDirection(_ writingDirection: UITextWritingDirection,
                                 for range: UITextRange) {}
}

/// Positions are UTF-16 offsets into the block's string; the official
/// `SelectableMarkdownTextView` wraps its offsets the same way (`OffsetPosition`
/// / `OffsetRange`, `EVIDENCE/UPSTREAM/part-aa-markdown-ui.md` §1.4).
final class MarkdownTextOffsetPosition: UITextPosition {
    let offset: Int
    init(_ offset: Int) { self.offset = offset }
}

final class MarkdownTextOffsetRange: UITextRange {
    let startOffset: Int
    let endOffset: Int
    init(_ start: Int, _ end: Int) {
        startOffset = min(start, end)
        endOffset = max(start, end)
    }
    override var start: UITextPosition { MarkdownTextOffsetPosition(startOffset) }
    override var end: UITextPosition { MarkdownTextOffsetPosition(endOffset) }
    override var isEmpty: Bool { startOffset == endOffset }
}

final class MarkdownTextSelectionRect: UITextSelectionRect {
    private let frame: CGRect
    private let startsHere: Bool
    private let endsHere: Bool
    init(rect: CGRect, containsStart: Bool, containsEnd: Bool) {
        frame = rect
        startsHere = containsStart
        endsHere = containsEnd
    }
    override var rect: CGRect { frame }
    override var containsStart: Bool { startsHere }
    override var containsEnd: Bool { endsHere }
    override var writingDirection: UITextWritingDirection { .leftToRight }
    override var isVertical: Bool { false }
}

#endif
