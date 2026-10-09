import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ChatComposer: View {
    @Bindable var draft: ComposerDraft
    let editor: ComposerEditorController
    let isStreaming: Bool
    var canSend = true
    var isBusy = false
    var placeholder = String(localized: "询问 Agents")
    let maximumEditorHeight: CGFloat
    let controls: ChatControlMetrics
    let onSend: () -> Void
    let onStop: () -> Void
    let onOptions: () -> Void
    /// Shown in the send cluster when the session's runtime offers slash
    /// commands — left of the context ring when the ring is visible, left of
    /// send when it is not.
    var showsCommands = false
    var commandsActive = false
    var onCommands: () -> Void = {}
    /// Live context-window state; hidden, or an unfocused editor (no
    /// keyboard), hides the ring entirely. A real measurement with an unknown
    /// window shows the neutral unknown ring instead of vanishing.
    var contextUsage: ContextRingState = .hidden
    /// Reports draft mutations from this subtree only. Persisting the draft
    /// must not make the page root observe the editor's text.
    var onDraftChange: () -> Void = {}
    /// Which control the single trailing key shows and whether it is live,
    /// resolved by `ComposerQueueAffordance` at the dock: the one key stops a
    /// textless running turn, enqueues a running turn's typed message, and
    /// sends while idle.
    var affordance = ComposerQueueAffordance(shape: .send, isActionEnabled: true)
    var onQueueSend: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glass
    @AppStorage(AppAccent.storageKey) private var accentValue = AppAccent.default.rawValue
    private var accent: AppAccent { AppAccent.resolve(accentValue) }
    @State private var keyboardHoldToken = 0
    private var keyboardExpansionAnimation: Animation { .easeInOut(duration: 0.25) }

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 0) {
                if !draft.attachments.isEmpty { attachmentTray }
                ComposerLayout(expanded: draft.isExpanded, maximumEditorHeight: maximumEditorHeight, controls: controls) {
                    Button(action: onOptions) {
                        AppSymbol("plus", size: 24)
                            .frame(width: controls.touchTarget, height: controls.touchTarget)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "附件与对话选项"))
                    .accessibilityIdentifier("chat.composer.options")

                    ZStack(alignment: .topLeading) {
                        if !draft.hasContent {
                            Text(placeholder)
                                .font(.body)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                                .allowsHitTesting(false)
                        }
                        NativeComposerEditor(draft: draft, controller: editor, maximumHeight: maximumEditorHeight, onCommandSend: onSend)
                    }

                    Button(action: accentAction) {
                        AppSymbol(accentSymbol, size: accentSymbolSize)
                            .contentTransition(.symbolEffect(.replace))
                            .foregroundStyle(AppTheme.accentForeground(accent, colorScheme))
                            .frame(width: controls.sendDiameter, height: controls.sendDiameter)
                            .background(AppTheme.accentBackground(accent, colorScheme).opacity(sendEnabled && !isBusy ? 1 : 0.42), in: Circle())
                            .frame(width: controls.touchTarget, height: controls.touchTarget)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy || !sendEnabled)
                    .accessibilityLabel(accentLabel)
                    .accessibilityHint(draft.isComposing ? String(localized: "请先确认输入法候选文字") : "")
                    .accessibilityIdentifier(showsQueueSend ? "chat.composer.queueSend" : "chat.composer.send")

                    if contextUsage.isVisible, draft.isFocused {
                        ContextRingButton(state: contextUsage, touchTarget: controls.touchTarget)
                    }

                    if showsCommands {
                        Button(action: onCommands) {
                            AppSymbol("command", size: 18)
                                .foregroundStyle(commandsActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                .frame(width: controls.touchTarget, height: controls.touchTarget)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "指令"))
                        .accessibilityAddTraits(commandsActive ? .isSelected : [])
                        .accessibilityIdentifier("chat.composer.commands")
                    }
                }
            }
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: draft.isExpanded ? controls.expandedCornerRadius : controls.collapsedCornerRadius))
            .glassEffectID("composer", in: glass)
        }
        .padding(.horizontal, draft.isExpanded ? ChatControlMetrics.expandedHorizontalInset : ChatControlMetrics.collapsedHorizontalInset)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: draft.isExpanded)
        // The composer is the only subtree that already re-evaluates on every
        // keystroke, including each Chinese IME marked-text update. Observing
        // the draft from the page root re-evaluated the whole conversation.
        .onChange(of: draft.text) { _, _ in onDraftChange() }
        .onChange(of: draft.attachments) { _, _ in onDraftChange() }
        .onChange(of: draft.isFocused, initial: true) { _, focused in
            if focused { holdExpansionUntilKeyboard() } else { finishKeyboardHold() }
        }
#if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            finishKeyboardHold()
        }
#endif
    }

    /// A tap makes the editor first responder several frames before the
    /// keyboard animation begins. Holding the expansion through that gap keeps
    /// the composer's height in the keyboard's own transaction instead of
    /// growing a frame early. The hold gives up after a short window so a
    /// hardware keyboard, an iPad, or a keyboard that never animates still
    /// expands the bar.
    private func holdExpansionUntilKeyboard() {
        draft.awaitingKeyboard = true
        keyboardHoldToken &+= 1
        let token = keyboardHoldToken
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard keyboardHoldToken == token else { return }
            finishKeyboardHold()
        }
    }

    /// Ends the hold and, when focus is still held, brings the expansion in on
    /// the keyboard's own animation — so the bar grows with the keyboard rather
    /// than jumping ahead of it. Collapses are left to the bar's own animation.
    private func finishKeyboardHold() {
        keyboardHoldToken &+= 1
        guard draft.awaitingKeyboard else { return }
        // The mutation itself is inside the transaction, so the layout change
        // it causes animates; a plain flag write would not.
        withAnimation(reduceMotion ? nil : keyboardExpansionAnimation) {
            draft.awaitingKeyboard = false
        }
    }

    /// The queue form: the single accent key shows the arrow and enqueues.
    private var showsQueueSend: Bool { affordance.shape == .queueSend }

    /// Enabled state of the accent key, owned by the resolved affordance.
    private var sendEnabled: Bool { affordance.isActionEnabled }

    /// The accent key's action across its three states.
    private var accentAction: () -> Void {
        switch affordance.shape {
        case .queueSend: return onQueueSend
        case .stop: return onStop
        case .send: return onSend
        }
    }

    /// Stop glyph only belongs to a running turn that has nothing sendable.
    private var accentSymbol: String {
        affordance.shape == .stop ? "stop.fill" : "arrow.up"
    }

    private var accentSymbolSize: CGFloat {
        affordance.shape == .stop ? 13 : 18
    }

    private var accentLabel: String {
        switch affordance.shape {
        case .queueSend: return String(localized: "加入发送队列")
        case .stop: return String(localized: "停止生成")
        case .send: return String(localized: "发送消息")
        }
    }

    private var attachmentTray: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(draft.attachments) { attachment in
                    ChatComposerAttachment(attachment: attachment) {
                        draft.attachments.removeAll { $0.id == attachment.id }
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }
}
