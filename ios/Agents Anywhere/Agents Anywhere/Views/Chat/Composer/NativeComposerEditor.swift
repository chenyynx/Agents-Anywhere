import SwiftUI
import UIKit

/// Keep this controller and the underlying UITextView alive while the glass
/// container changes layout. Never derive submission from SwiftUI .onSubmit.
@MainActor @Observable
final class ComposerEditorController {
    @ObservationIgnored weak var textView: ComposerTextView?
    @ObservationIgnored weak var draft: ComposerDraft?
    /// The profile's expand curve, set by the hosting composer. Only the
    /// expanding transition uses it (see `ComposerFocusTransition`).
    @ObservationIgnored var expandAnimation: Animation?
    /// False while the hosting tab page is mounted but not visible. The page
    /// shares the draft with the visible page, so it must not mirror (or
    /// clear) the shared focus flag.
    @ObservationIgnored var allowsFocus = true
    /// True from the moment UIKit starts ending editing until the finish has
    /// landed. `resignFirstResponder` returns before that happens, so for a
    /// short window `isFirstResponder` still reads true while the keyboard is
    /// already going down. Everything that mirrors or drives the responder
    /// must treat the editor as unfocused during it.
    @ObservationIgnored var isEndingEditing = false

    func finishEditing() {
        guard let textView else { return }
        // The resign sets `isEndingEditing` through `textViewShouldEndEditing`
        // before UIKit starts the teardown, so the mirror below and any
        // SwiftUI update in the window treat the editor as unfocused.
        textView.resignFirstResponder()
        synchronize()
    }

    /// Focus mirror of `finishEditing`: driven straight from the keyboard
    /// gesture, so the pop never waits on a SwiftUI re-render hop.
    func beginEditing() {
        guard let textView else { return }
        textView.becomeFirstResponder()
        synchronize()
    }

    /// Canonical plain text for persistence and sending: command tokens are
    /// inline attachments in the native view, so U+FFFC must be expanded back
    /// to `/name`. The draft and every consumer keep seeing plain text.
    func canonicalText(of view: UITextView) -> String {
        let attributed = view.attributedText ?? NSAttributedString(string: view.text ?? "")
        let source = attributed.string as NSString
        var result = ""
        attributed.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, range, _ in
            if let token = value as? ComposerCommandTokenAttachment {
                result += "/" + token.commandName
            } else {
                result += source.substring(with: range)
            }
        }
        return result
    }

    /// Insert the selected skill as one capsule token. The token is a single
    /// attachment character: typing appends arguments after it and backspace
    /// removes the whole command. Returns the canonical text, or nil when the
    /// native view is not mounted (the caller falls back to plain text).
    @discardableResult
    func insertCommandToken(_ commandName: String) -> String? {
        guard let textView else { return nil }
        let token = ComposerCommandTokenAttachment(
            commandName: commandName,
            traits: textView.traitCollection,
            scale: textView.traitCollection.displayScale
        )
        let bodyFont = UIFont.preferredFont(forTextStyle: .body)
        let attributed = NSMutableAttributedString(attachment: token)
        // The attachment run carries the body font too. UITextView resolves
        // `font` and the caret's typing attributes from the first run; an
        // attachment-only run has no font, so text typed after the capsule
        // fell back to the text view's default (much smaller) face
        // (pp 2026-11-15: 「输入框输入的文字变小了」).
        attributed.addAttribute(.font, value: bodyFont,
                                range: NSRange(location: 0, length: attributed.length))
        attributed.append(NSAttributedString(string: " ", attributes: [
            .font: bodyFont,
            .foregroundColor: UIColor.label,
        ]))
        textView.attributedText = attributed
        // Keep the property itself at body size: `attributedText` can replace
        // it with the first run's font, and later plain-text resets use it.
        textView.font = bodyFont
        textView.typingAttributes = [.font: bodyFont, .foregroundColor: UIColor.label]
        textView.selectedRange = NSRange(location: attributed.length, length: 0)
        if !textView.isFirstResponder { textView.becomeFirstResponder() }
        let canonical = "/\(commandName) "
        draft?.text = canonical
        draft?.isFocused = true
        return canonical
    }

    /// Check native marked text before ending editing. unmarkText() only removes
    /// the mark; it cannot select the user's intended Chinese candidate.
    ///
    /// - Parameter dismissKeyboard: a send ends the editing session and drops
    ///   the keyboard so the conversation is visible; an enqueue does not —
    ///   the queue is fed several messages in a row, and re-tapping the field
    ///   between each would tax the flow the queue exists for.
    func committedTextForSend(dismissKeyboard: Bool = true) async -> String? {
        guard let textView else { return draft?.isComposing == false ? draft?.text : nil }
        guard textView.markedTextRange == nil else { synchronize(); return nil }
        let originalDraft = draft
        guard dismissKeyboard else {
            // Without the resign there is no turn boundary to wait for; the
            // marked-text guard above already settled the composition state.
            synchronize()
            return canonicalText(of: textView)
        }
        textView.resignFirstResponder()
        // Mirror the resignation synchronously, before the yield below hands
        // the main actor to SwiftUI: a send-driven update in that window runs
        // `updateUIView`, which re-focuses whenever `draft.isFocused` is still
        // true — the keyboard dropped and then popped straight back up
        // (pp 2026-11-26, intermittent depending on the update's timing).
        draft?.isFocused = false
        await Task.yield()
        guard !Task.isCancelled, draft === originalDraft, textView.markedTextRange == nil else { return nil }
        synchronize()
        return canonicalText(of: textView)
    }

    func synchronize() {
        guard let textView, let draft, draft.isValid else { return }
        let canonical = canonicalText(of: textView)
        if draft.text != canonical { draft.text = canonical }
        draft.isComposing = textView.markedTextRange != nil
        // A hidden page's editor resignation must not clear the visible page's
        // focus flag.
        guard allowsFocus else { return }
        // During the deferred finish `isFirstResponder` still reads true even
        // though the keyboard is going down. Mirroring that stale value
        // re-expanded the bar the reader had just swiped away and flushed a
        // SwiftUI update that re-entered the responder — the b1678 freeze:
        // updateUIView → resignFirstResponder → UICoreKeyboardTracking →
        // SwiftUI render → AttributeGraph push_slow (pp 2026-11-27 01:42:45).
        let focused = isEndingEditing ? false : textView.isFirstResponder
        guard draft.isFocused != focused else { return }
        if ComposerFocusTransition.animates(previous: draft.isFocused, next: focused,
                                            reduceMotion: UIAccessibility.isReduceMotionEnabled) {
            // The expansion grows the bar, and the bar's height is the page's
            // bottom inset: only an animated transaction moves the inset and
            // the list together, on the same curve the bar itself animates on.
            withAnimation(expandAnimation ?? .smooth(duration: 0.24)) { draft.isFocused = true }
        } else {
            draft.isFocused = focused
        }
    }
}

/// One inserted skill rendered as an inline capsule token. It is a single
/// attachment character in the text view, so backspace deletes the whole
/// command and typing appends arguments after it; the canonical `/name`
/// text is recovered by `ComposerEditorController.canonicalText`.
final class ComposerCommandTokenAttachment: NSTextAttachment {
    let commandName: String

    @MainActor
    init(commandName: String, traits: UITraitCollection, scale: CGFloat) {
        self.commandName = commandName
        super.init(data: nil, ofType: nil)
        let image = CommandTokenRenderer.image(for: commandName, traits: traits, scale: scale)
        self.image = image
        // Bottom sits just below the baseline so the capsule centers on the
        // body line instead of floating above it.
        bounds = CGRect(x: 0, y: -3, width: image.size.width, height: image.size.height)
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
private enum CommandTokenRenderer {
    private static var cache: [String: UIImage] = [:]

    static func image(for commandName: String, traits: UITraitCollection, scale: CGFloat) -> UIImage {
        let dark = traits.userInterfaceStyle == .dark
        let key = "\(commandName)|\(dark)|\(scale)"
        if let cached = cache[key] { return cached }

        // The official card measures 21 pt tall at 15 pt mono, but that
        // proportion sits on a body line of 20.5 pt: with the composer's
        // font bug rendering body at 12 pt the chip read as a bubble
        // (pp 2026-11-15: 「把这个胶囊缩小 别这么大」). 18 pt / 13 pt stays
        // inside the body line and reads as one token, not a filled field.
        let font = UIFont(name: "JetBrainsMono-Regular", size: 13)
            ?? UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let text = "/\(commandName)" as NSString
        let textSize = text.size(withAttributes: [.font: font])
        // 3 pt side padding, capsule ends. The command name keeps the
        // panel's accent color.
        let size = CGSize(width: ceil(textSize.width) + 6, height: 18)
        let background = dark
            ? UIColor(red: 54 / 255, green: 68 / 255, blue: 90 / 255, alpha: 1)
            : UIColor(red: 208 / 255, green: 216 / 255, blue: 228 / 255, alpha: 1)
        let foreground = CodePageTheme.uiColor(CodePageTheme.accentSecondary100Color)
            .resolvedColor(with: traits)

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            background.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: size.height / 2).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: foreground,
            ]
            let drawn = text.size(withAttributes: attributes)
            text.draw(
                at: CGPoint(x: (size.width - drawn.width) / 2,
                            y: (size.height - drawn.height) / 2),
                withAttributes: attributes
            )
        }
        cache[key] = image
        return image
    }
}

final class ComposerTextView: UITextView {
    var commandSend: (() -> Void)?
    /// A text view created before its window's traits are attached resolves
    /// `preferredFont` against an unspecified category and can render at
    /// UIKit's default face instead of body; plain typing then inherits it.
    /// Resolve again once the real traits exist (pp 2026-11-15: 「输入框输入
    /// 的文字变小了」). `adjustsFontForContentSizeCategory` covers later
    /// category changes.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let window else { return }
        let body = UIFont.preferredFont(forTextStyle: .body,
                                        compatibleWith: window.traitCollection)
        guard font?.pointSize != body.pointSize else { return }
        font = body
        typingAttributes[.font] = body
    }
    /// Long pasted logs leave the editor at paste time, not at send time: the
    /// reply returns true when the paste was consumed — turned into a file, or
    /// refused with an error. Either way the raw text is never inserted.
    var onLongPaste: ((String) -> Bool)?

    override var keyCommands: [UIKeyCommand]? {
        let send = UIKeyCommand(title: String(localized: "发送"), action: #selector(sendWithCommandReturn), input: "\r", modifierFlags: .command)
        send.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + [send]
    }

    @objc private func sendWithCommandReturn() {
        // Leave provisional text and the candidate bar intact. Return/Space or
        // a candidate tap remains owned by the IME; this shortcut never guesses.
        guard markedTextRange == nil else { return }
        commandSend?()
    }

    override func paste(_ sender: Any?) {
        // Do not fight an active IME composition; if the pasted log qualifies,
        // the host appends it as an attachment and the editor stays untouched.
        if markedTextRange == nil,
           let text = UIPasteboard.general.string,
           !text.isEmpty,
           onLongPaste?(text) == true {
            return
        }
        super.paste(sender)
    }
}

struct NativeComposerEditor: UIViewRepresentable {
    @Bindable var draft: ComposerDraft
    let controller: ComposerEditorController
    /// False on a tab page that is mounted but not visible.
    @Environment(\.composerFocusEnabled) private var allowsFocus
    let maximumHeight: CGFloat
    let onCommandSend: () -> Void
    var expandAnimation: Animation? = nil
    var onTextChange: ((String, Bool) -> Void)? = nil
    /// Called before a paste enters the editor. Returning true means the paste
    /// was consumed — turned into an attachment, or refused with an error —
    /// and must not be inserted as text.
    var onLongPaste: ((String) -> Bool)? = nil
    /// A non-paste insertion hit the editor budget. The host shows the error.
    var onEditorLimitReached: (() -> Void)? = nil
    /// The draft itself is over the editor budget; repair it outside the view
    /// update. Never hand such a string to TextKit.
    var onOversizedDraft: (() -> Void)? = nil
    /// Live dictation writes the draft from outside; the caret must follow the
    /// end of the transcript instead of staying at the insertion point.
    var followsTextEnd = false

    func makeUIView(context: Context) -> ComposerTextView {
        let view = ComposerTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        // Resolve against the view's own traits: at `makeUIView` the hosting
        // window's content-size category may not be attached yet.
        view.font = .preferredFont(forTextStyle: .body, compatibleWith: view.traitCollection)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.tintColor = .label
        view.returnKeyType = .default
        view.enablesReturnKeyAutomatically = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.contentInset = .zero
        view.isScrollEnabled = false
        view.showsVerticalScrollIndicator = true
        view.keyboardDismissMode = .none
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityLabel = String(localized: "消息")
        view.accessibilityHint = String(localized: "回车换行，Command 加回车发送。")
        view.accessibilityIdentifier = "chat.composer.editor"
        controller.textView = view; controller.draft = draft
        controller.expandAnimation = expandAnimation
        view.onLongPaste = onLongPaste
        return view
    }

    func updateUIView(_ view: ComposerTextView, context: Context) {
        context.coordinator.parent = self
        controller.textView = view; controller.draft = draft
        controller.expandAnimation = expandAnimation
        view.commandSend = onCommandSend
        view.onLongPaste = onLongPaste
        // UIKit drops back to its own default face when an `attributedText`
        // run carries no font (the command-token path), and a text view first
        // laid out before its window traits arrive starts at that default
        // too. Either way later plain typing inherits it and the composer
        // renders visibly smaller than body (pp 2026-11-15). Repair the font
        // off the live traits; this also rewrites any run that already
        // rendered at the wrong size.
        if view.markedTextRange == nil {
            let bodyFont = UIFont.preferredFont(forTextStyle: .body,
                                                compatibleWith: view.traitCollection)
            if view.font?.pointSize != bodyFont.pointSize {
                view.font = bodyFont
                view.typingAttributes[.font] = bodyFont
            }
        }
        // A draft over the editor budget must never reach TextKit. The
        // 2026-11-22 crash had the main thread in `sizeThatFits` measuring a
        // 4 MB draft past the scene-update watchdog, and because the draft is
        // archived it repeated on every launch. Repair the model off this pass
        // instead of measuring it here.
        if LongMessageAttachmentPolicy.exceedsEditorLimit(draft.text) {
            let repair = onOversizedDraft
            Task { @MainActor in repair?() }
        } else if view.markedTextRange == nil, controller.canonicalText(of: view) != draft.text {
            // Do not replace native pre-edit text or disrupt its selection/candidate bar.
            let selection = view.selectedRange
            view.text = draft.text
            let end = (draft.text as NSString).length
            // Dictation replaces the draft from outside; keep the caret after
            // the newest words instead of at the old insertion point.
            let location = followsTextEnd ? end : min(selection.location, end)
            view.selectedRange = NSRange(location: location, length: 0)
        }
        controller.allowsFocus = allowsFocus
        // Never drive the responder while UIKit is finishing a resignation.
        // `resignFirstResponder` returns before the finish lands, so an
        // update in that window still sees `isFirstResponder == true` while
        // the draft already reads "not focused"; calling resign again from
        // here re-enters UIKit's keyboard teardown from inside a SwiftUI
        // update. The b1678 freeze (pp 2026-11-27 01:42:45; the watchdog
        // killed the process with 0x8BADF00D at 01:44:14) is exactly that:
        // updateUIView → resignFirstResponder → UICoreKeyboardTracking →
        // ViewGraphRootValueUpdater.render → AttributeGraph push_slow, stuck
        // for 89 s. `didEndEditing` clears the flag.
        if !controller.isEndingEditing {
            if allowsFocus, draft.isFocused, !view.isFirstResponder {
                view.becomeFirstResponder()
            } else if (!draft.isFocused || !allowsFocus), view.isFirstResponder {
                view.resignFirstResponder()
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let measured = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let minimum = ceil(uiView.font?.lineHeight ?? 24)
        let height = min(maximumHeight, max(minimum, ceil(measured)))
        let shouldScroll = measured > maximumHeight + 1
        if uiView.isScrollEnabled != shouldScroll { uiView.isScrollEnabled = shouldScroll }
        return CGSize(width: width, height: height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NativeComposerEditor
        init(_ parent: NativeComposerEditor) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) {
            synchronize()
            textView.invalidateIntrinsicContentSize()
        }
        func textViewDidChangeSelection(_ textView: UITextView) { synchronize() }
        func textViewDidBeginEditing(_ textView: UITextView) {
            // A cancelled interactive dismissal resumes editing without ever
            // reaching didEndEditing; the flag must not survive it.
            parent.controller.isEndingEditing = false
            synchronize()
        }
        func textViewShouldEndEditing(_ textView: UITextView) -> Bool {
            // From here until didEndEditing, `isFirstResponder` can still
            // read true while the keyboard is already going down.
            parent.controller.isEndingEditing = true
            return true
        }
        func textViewDidEndEditing(_ textView: UITextView) {
            // Mirror first, while the finish still counts as in flight, then
            // release the guard.
            synchronize()
            parent.controller.isEndingEditing = false
        }
        private func synchronize() {
            parent.controller.synchronize()
            parent.onTextChange?(parent.draft.text, parent.draft.isComposing)
        }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // UIKit owns IME candidate confirmation. A plain Return is always
            // accepted as text input, never interpreted as a send gesture.
            guard textView.markedTextRange == nil else { return true }
            // Only an insertion that would push the editor past its budget is
            // intercepted. This is the last line for paths that never call
            // `paste(_:)` — dictation, drop, a pasteboard without a string
            // representation, a third-party IME — so TextKit cannot be handed
            // a log the size of the 2026-11-22 one.
            let current = ((textView.text ?? "") as NSString).length
            let projected = max(0, current - range.length + (text as NSString).length)
            guard projected > LongMessageAttachmentPolicy.maximumEditorCharacters else { return true }
            // The host turns the insertion into a file, or refuses it with an
            // error; either way nothing is inserted.
            if parent.onLongPaste?(text) == true { return false }
            parent.onEditorLimitReached?()
            return false
        }
    }
}
