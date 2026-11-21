#if canImport(UIKit)
import UIKit

/// One message body's text selection, spanning every participating text block.
///
/// The Code page draws each paragraph / list item / quote as its own
/// `AssistantMarkdownBlockTextView`, each with its own TextKit layout and its
/// own single-block selection. The official app ties the leaves together with
/// `ClaudeCompositeTextSelection` (`EVIDENCE/UPSTREAM/part-aa-markdown-ui.md`
/// Q6); AA has no cross-block layer, so this overlay is the row's one
/// `UITextInput`: it flattens the blocks into one virtual string through
/// `CompositeSelectionModel`, maps points and offsets back to the block that
/// drew them, and lets a single system `UITextInteraction` own the highlight,
/// handles, loupe and Copy menu.
///
/// Code blocks and tables are not participants. Code keeps its own copy
/// button; tables keep per-cell selection from `AssistantTableBlockView`.
@MainActor
final class AssistantCompositeSelectionOverlay: UIView, UITextInput,
                                                UIGestureRecognizerDelegate {
    private(set) var textViews: [AssistantMarkdownBlockTextView] = []
    private var model = CompositeSelectionModel(blockLengths: [])

    private var selectionOffsets: (start: Int, end: Int)?
    private weak var textInputDelegateStorage: UITextInputDelegate?
    private lazy var textTokenizer = UITextInputStringTokenizer(textInput: self)

    private var textInteraction: UITextInteraction?
    private var selectionEnabled = false
    private var linkTapRecognizer: LinkTapRecognizer?
    private var doubleTapGate: UITapGestureRecognizer?
    private var outsideTapRecognizer: UITapGestureRecognizer?
    private var relaxedClippingViews: [UIView] = []

    /// Set by the owner when it wants a non-default URL router.
    var openLink: ((URL) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = true
        isAccessibilityElement = false
        // The block text views own the accessibility tree; the overlay is a
        // gesture vehicle only.
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Participants

    /// Install the blocks that take part in the composite selection, in
    /// document order. Identical participants are a no-op so a layout pass
    /// does not drop a live selection.
    func setParticipants(_ views: [AssistantMarkdownBlockTextView],
                         separators: [String]) {
        let lengths = views.map(\.compositeTextLength)
        if views.count == textViews.count,
           views.elementsEqual(textViews, by: { $0 === $1 }),
           lengths == model.blockLengths,
           separators == model.separators {
            return
        }
        let remapped = remappedSelection(for: lengths, separators: separators)
        textViews = views
        model = CompositeSelectionModel(blockLengths: lengths,
                                        separators: separators)
        if let remapped {
            selectedTextRange = MarkdownTextOffsetRange(remapped.start,
                                                        remapped.end)
        } else {
            endSelection()
        }
    }

    /// Streaming keeps growing the last block while the reader is selecting
    /// an earlier one. Rebuild the flattened offsets from the selected
    /// blocks' own offsets; only a length change inside a selected block
    /// drops the selection, because that text is what the reader pointed at.
    private func remappedSelection(for lengths: [Int],
                                   separators: [String]) -> (start: Int, end: Int)? {
        guard let selectionOffsets,
              let startLocation = model.location(at: selectionOffsets.start),
              let endLocation = model.location(at: selectionOffsets.end) else {
            return nil
        }
        let next = CompositeSelectionModel(blockLengths: lengths,
                                           separators: separators)
        guard next.segments.indices.contains(startLocation.blockIndex),
              next.segments.indices.contains(endLocation.blockIndex),
              next.blockLengths[startLocation.blockIndex]
                == model.blockLengths[startLocation.blockIndex],
              next.blockLengths[endLocation.blockIndex]
                == model.blockLengths[endLocation.blockIndex] else {
            return nil
        }
        guard let start = next.flattenedOffset(
                  blockIndex: startLocation.blockIndex,
                  localOffset: startLocation.localOffset),
              let end = next.flattenedOffset(
                  blockIndex: endLocation.blockIndex,
                  localOffset: endLocation.localOffset) else {
            return nil
        }
        return (min(start, end), max(start, end))
    }

    /// Attach the system selection layer and/or the link tap recognizer.
    /// Called once with the stack's `allowsSelection`; safe to call again when
    /// that setting changes.
    func configure(allowsSelection: Bool) {
        installLinkTapIfNeeded()
        guard allowsSelection != selectionEnabled else { return }
        selectionEnabled = allowsSelection
        if allowsSelection {
            let interaction = UITextInteraction(for: .nonEditable)
            interaction.textInput = self
            addInteraction(interaction)
            textInteraction = interaction
        } else {
            if let textInteraction { removeInteraction(textInteraction) }
            textInteraction = nil
            endSelection()
        }
    }

    private func installLinkTapIfNeeded() {
        guard linkTapRecognizer == nil else { return }
        let tap = LinkTapRecognizer(target: self, action: #selector(handleLinkTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        // Same gate as the single block: a link opens only on a quick tap,
        // never on the release that ends a long press.
        let gate = UITapGestureRecognizer(target: nil, action: nil)
        gate.numberOfTapsRequired = 2
        gate.cancelsTouchesInView = false
        gate.delegate = self
        addGestureRecognizer(gate)
        tap.require(toFail: gate)
        addGestureRecognizer(tap)
        linkTapRecognizer = tap
        doubleTapGate = gate
    }

    // MARK: - Hit testing

    /// Only the area covered by a participating block claims the touch; the
    /// rest falls through to the code copy button and the table scroll view.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01,
              bounds.contains(point) else { return nil }
        return textView(at: point) == nil ? nil : self
    }

    private func textView(at point: CGPoint) -> AssistantMarkdownBlockTextView? {
        textViews.first { rect(of: $0).contains(point) }
    }

    private func rect(of textView: AssistantMarkdownBlockTextView) -> CGRect {
        convert(textView.bounds, from: textView)
    }

    private func nearestBlock(to point: CGPoint)
        -> (view: AssistantMarkdownBlockTextView, local: Int)? {
        guard !textViews.isEmpty else { return nil }
        if let hit = textView(at: point) {
            let index = hit.compositeCharacterIndex(at: convert(point, to: hit)) ?? 0
            return (hit, index)
        }
        var best: (view: AssistantMarkdownBlockTextView, distance: CGFloat)?
        for view in textViews {
            let frame = rect(of: view)
            let distance: CGFloat
            if point.y < frame.minY {
                distance = frame.minY - point.y
            } else if point.y > frame.maxY {
                distance = point.y - frame.maxY
            } else {
                distance = 0
            }
            if best == nil || distance < best!.distance {
                best = (view, distance)
            }
        }
        guard let best else { return nil }
        // Do not snap by the block's midpoint: the finger usually leaves the
        // text column horizontally (right margin, list indent, screen edge)
        // while staying on one line. `compositeCharacterIndex` already clamps
        // to the nearest line on both axes, which answers the end of that line
        // (or the start of the next) without flipping the selection.
        let local = best.view.compositeCharacterIndex(at: convert(point, to: best.view)) ?? 0
        return (best.view, local)
    }

    private func globalOffset(for view: AssistantMarkdownBlockTextView,
                              local: Int) -> Int? {
        guard let index = textViews.firstIndex(where: { $0 === view }) else { return nil }
        return model.flattenedOffset(blockIndex: index, localOffset: local)
    }

    // MARK: - Link taps

    @objc private func handleLinkTap(_ recognizer: UITapGestureRecognizer) {
        if let link = recognizer as? LinkTapRecognizer, !link.isQuickTap { return }
        let point = recognizer.location(in: self)
        guard let view = textView(at: point),
              let url = view.compositeLink(at: convert(point, to: view)) else { return }
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "tel"].contains(scheme) else { return }
        (openLink ?? { UIApplication.shared.open($0) })(url)
    }

    // MARK: - Clipboard

    /// A selection that only covers a separator has no visible content, so
    /// Copy must stay disabled instead of writing an empty pasteboard item.
    private var hasCopyableSelection: Bool {
        guard let selectionOffsets, selectionOffsets.end > selectionOffsets.start else {
            return false
        }
        let range = NSRange(location: selectionOffsets.start,
                            length: selectionOffsets.end - selectionOffsets.start)
        return !model.fragments(in: range).isEmpty
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)) { return hasCopyableSelection }
        return super.canPerformAction(action, withSender: sender)
    }

    override func copy(_ sender: Any?) {
        guard hasCopyableSelection, let selectionOffsets else { return }
        let range = NSRange(location: selectionOffsets.start,
                            length: selectionOffsets.end - selectionOffsets.start)
        let fragments = model.fragments(in: range)
        let plain = joinedText(fragments) { fragment in
            guard textViews.indices.contains(fragment.blockIndex) else { return nil }
            return textViews[fragment.blockIndex].compositePlainText(for: fragment.range)
        }
        let htmlPieces = fragments.compactMap { fragment -> String? in
            guard textViews.indices.contains(fragment.blockIndex) else { return nil }
            return textViews[fragment.blockIndex].compositeHTML(for: fragment.range)
        }
        UIPasteboard.general.items = [[
            "public.html": "<meta charset=\"utf-8\">"
                + htmlPieces.joined(separator: ""),
            "public.utf8-plain-text": plain,
        ]]
        endSelection()
    }

    /// Join per-block pieces with the separators the model carries for the
    /// boundaries the selection crosses: a paragraph break stays a blank
    /// line, a list item break stays one newline.
    private func joinedText(_ fragments: [CompositeSelectionModel.Fragment],
                            body: (CompositeSelectionModel.Fragment) -> String?) -> String {
        var text = ""
        var previousBlock: Int?
        for fragment in fragments {
            if let previousBlock {
                text += model.separatorText(afterBlock: previousBlock,
                                            beforeBlock: fragment.blockIndex)
            }
            if let piece = body(fragment) { text += piece }
            previousBlock = fragment.blockIndex
        }
        return text
    }

    // MARK: - Selection lifecycle

    func endSelection() {
        if selectionOffsets != nil { selectedTextRange = nil }
        if isFirstResponder { resignFirstResponder() }
    }

    private func notifySelectionChanged() {
        textInputDelegateStorage?.selectionWillChange(self)
        textInputDelegateStorage?.selectionDidChange(self)
    }

    private var hasSelection: Bool {
        guard let selectionOffsets else { return false }
        return selectionOffsets.end > selectionOffsets.start
    }

    // MARK: - Selection clipping

    /// The chat cell clips its content; a start-of-line handle would be cut in
    /// half. Relax the clip only while something is selected, then restore it.
    private func relaxAncestorClipping() {
        guard relaxedClippingViews.isEmpty else { return }
        var current = superview
        while let view = current {
            if view.clipsToBounds {
                view.clipsToBounds = false
                relaxedClippingViews.append(view)
            }
            current = view.superview
        }
    }

    private func restoreAncestorClipping() {
        for view in relaxedClippingViews { view.clipsToBounds = true }
        relaxedClippingViews.removeAll()
    }

    private func installOutsideTapRecognizer() {
        guard outsideTapRecognizer == nil, let window else { return }
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleOutsideTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        window.addGestureRecognizer(tap)
        outsideTapRecognizer = tap
    }

    private func removeOutsideTapRecognizer() {
        if let outsideTapRecognizer {
            outsideTapRecognizer.view?.removeGestureRecognizer(outsideTapRecognizer)
        }
        outsideTapRecognizer = nil
    }

    @objc private func handleOutsideTap(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        guard textView(at: point) == nil else { return }
        endSelection()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            removeOutsideTapRecognizer()
            restoreAncestorClipping()
        }
    }

    /// The same responder contract the single block uses: the interaction
    /// needs a first responder to present the edit menu, and resigning drops
    /// the selection and the relaxed clipping.
    override var canBecomeFirstResponder: Bool { selectionEnabled }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { installOutsideTapRecognizer() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        selectionOffsets = nil
        removeOutsideTapRecognizer()
        restoreAncestorClipping()
        return resigned
    }

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === outsideTapRecognizer {
            // Dismiss on any touch that is not on a participating text view:
            // the row's margins, block gaps, code blocks and tables. Those
            // areas are outside the overlay's hit test, so the interaction
            // never sees them; without this the highlight stayed up after
            // tapping the code copy button.
            return textView(at: touch.location(in: self)) == nil
        }
        return true
    }

    // MARK: - UITextInput

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
            if hasSelection {
                relaxAncestorClipping()
                installOutsideTapRecognizer()
            } else {
                restoreAncestorClipping()
                removeOutsideTapRecognizer()
            }
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

    var endOfDocument: UITextPosition { MarkdownTextOffsetPosition(model.totalLength) }

    var textInputView: UIView { self }

    var hasText: Bool { model.totalLength > 0 }

    func text(in range: UITextRange) -> String? {
        guard let range = range as? MarkdownTextOffsetRange,
              range.startOffset >= 0,
              range.endOffset <= model.totalLength else { return nil }
        guard range.endOffset > range.startOffset else { return "" }
        let fragments = model.fragments(in: NSRange(
            location: range.startOffset,
            length: range.endOffset - range.startOffset))
        return joinedText(fragments) { fragment in
            guard textViews.indices.contains(fragment.blockIndex) else { return nil }
            return textViews[fragment.blockIndex].compositeSubstring(for: fragment.range)
        }
    }

    // Read-only: the body never accepts edits, but the protocol requires the
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
        let other = min(max(p.offset + (forward ? 1 : -1), 0), model.totalLength)
        return MarkdownTextOffsetRange(p.offset, other)
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let p = position as? MarkdownTextOffsetPosition else { return nil }
        return MarkdownTextOffsetPosition(
            min(max(p.offset + offset, 0), model.totalLength))
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
        if let first = selectionRects(for: range).first {
            return convert(first.rect, to: nil)
        }
        if let caret = caretFrame(at: range.start) {
            return convert(caret, to: nil)
        }
        return .zero
    }

    func caretRect(for position: UITextPosition) -> CGRect {
        caretFrame(at: position) ?? .zero
    }

    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        guard let range = range as? MarkdownTextOffsetRange else { return [] }
        let fragments = model.fragments(in: NSRange(
            location: range.startOffset,
            length: range.endOffset - range.startOffset))
        var frames: [CGRect] = []
        for fragment in fragments {
            guard textViews.indices.contains(fragment.blockIndex) else { continue }
            let textView = textViews[fragment.blockIndex]
            let localFrames = textView.selectionFrames(
                from: fragment.range.location,
                to: NSMaxRange(fragment.range))
            frames.append(contentsOf: localFrames.map { convert($0, from: textView) })
        }
        return frames.enumerated().map { index, frame in
            MarkdownTextSelectionRect(rect: frame,
                                      containsStart: index == 0,
                                      containsEnd: index == frames.count - 1)
        }
    }

    func closestPosition(to point: CGPoint) -> UITextPosition? {
        guard let nearest = nearestBlock(to: point),
              let offset = globalOffset(for: nearest.view, local: nearest.local) else {
            return MarkdownTextOffsetPosition(0)
        }
        return MarkdownTextOffsetPosition(offset)
    }

    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        guard let limit = range as? MarkdownTextOffsetRange,
              let closest = closestPosition(to: point) as? MarkdownTextOffsetPosition else {
            return closestPosition(to: point)
        }
        return MarkdownTextOffsetPosition(
            min(max(closest.offset, limit.startOffset), limit.endOffset))
    }

    func characterRange(at point: CGPoint) -> UITextRange? {
        guard let nearest = nearestBlock(to: point) else { return nil }
        if let word = nearest.view.compositeWordRange(at: nearest.local)
            as? MarkdownTextOffsetRange,
           let start = globalOffset(for: nearest.view, local: word.startOffset),
           let end = globalOffset(for: nearest.view, local: word.endOffset) {
            return MarkdownTextOffsetRange(start, end)
        }
        guard let offset = globalOffset(for: nearest.view, local: nearest.local) else {
            return nil
        }
        return MarkdownTextOffsetRange(offset, offset)
    }

    func baseWritingDirection(for position: UITextPosition,
                              in direction: UITextStorageDirection) -> UITextWritingDirection {
        effectiveUserInterfaceLayoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
    }

    func setBaseWritingDirection(_ writingDirection: UITextWritingDirection,
                                 for range: UITextRange) {}

    // MARK: - Caret geometry

    /// Caret rect in the overlay's coordinate space.
    private func caretFrame(at position: UITextPosition) -> CGRect? {
        guard let p = position as? MarkdownTextOffsetPosition,
              let location = model.location(at: p.offset),
              textViews.indices.contains(location.blockIndex) else { return nil }
        let textView = textViews[location.blockIndex]
        guard let caret = textView.compositeCaretFrame(at: location.localOffset) else {
            return nil
        }
        return convert(caret, from: textView)
    }

    #if DEBUG
    var debugParticipantCount: Int { textViews.count }
    var debugHasSelectionInteraction: Bool { textInteraction != nil }
    #endif
}

#endif
