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

    func finishEditing() {
        guard let textView else { return }
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
        let focused = textView.isFirstResponder
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
        bounds = CGRect(x: 0, y: -4, width: image.size.width, height: image.size.height)
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

        let font = UIFont(name: "JetBrainsMono-Regular", size: 15)
            ?? UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        let text = "/\(commandName)" as NSString
        let textSize = text.size(withAttributes: [.font: font])
        // Measured off the official card: 21 pt tall, 3 pt side padding,
        // capsule ends. The command name keeps the panel's accent color.
        let size = CGSize(width: ceil(textSize.width) + 6, height: 21)
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
    /// Long pasted logs leave the editor at paste time, not at send time: the
    /// reply returns true when the text became an attachment instead.
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
    let maximumHeight: CGFloat
    let onCommandSend: () -> Void
    var expandAnimation: Animation? = nil
    var onTextChange: ((String, Bool) -> Void)? = nil
    /// Called before a paste enters the editor. Returning true means the paste
    /// was turned into an attachment and must not be inserted as text.
    var onLongPaste: ((String) -> Bool)? = nil

    func makeUIView(context: Context) -> ComposerTextView {
        let view = ComposerTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
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
        // Do not replace native pre-edit text or disrupt its selection/candidate bar.
        if view.markedTextRange == nil, controller.canonicalText(of: view) != draft.text {
            let selection = view.selectedRange
            view.text = draft.text
            let end = (draft.text as NSString).length
            view.selectedRange = NSRange(location: min(selection.location, end), length: 0)
        }
        if draft.isFocused, !view.isFirstResponder {
            view.becomeFirstResponder()
        } else if !draft.isFocused, view.isFirstResponder {
            view.resignFirstResponder()
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
        func textViewDidBeginEditing(_ textView: UITextView) { synchronize() }
        func textViewDidEndEditing(_ textView: UITextView) { synchronize() }
        private func synchronize() {
            parent.controller.synchronize()
            parent.onTextChange?(parent.draft.text, parent.draft.isComposing)
        }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // UIKit owns IME candidate confirmation. A plain Return is always
            // accepted as text input, never interpreted as a send gesture.
            true
        }
    }
}
