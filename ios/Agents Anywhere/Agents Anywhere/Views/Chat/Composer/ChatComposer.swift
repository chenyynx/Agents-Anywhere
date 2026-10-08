import SwiftUI

struct ChatComposer: View {
    @Bindable var draft: ComposerDraft
    let editor: ComposerEditorController
    let isStreaming: Bool
    var canSend = true
    var canStop = true
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
    /// Live context-window usage; nil, invalid, or an unfocused editor (no
    /// keyboard) hides the ring entirely.
    var contextUsage: ContextUsage? = nil
    /// Reports draft mutations from this subtree only. Persisting the draft
    /// must not make the page root observe the editor's text.
    var onDraftChange: () -> Void = {}
    /// Which control the trailing slot shows and whether it is live, resolved
    /// by `ComposerQueueAffordance` at the dock. The queue form keeps the stop
    /// control, drawn smaller, so a running turn can still be interrupted.
    var affordance = ComposerQueueAffordance(shape: .send, isActionEnabled: true)
    var onQueueSend: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Visual diameter of the queue-form stop key, matched to the composer's
    /// footnote scale and drawn inside a full-size touch target.
    @ScaledMetric(relativeTo: .footnote) private var queueStopDiameter: CGFloat = 26
    @Namespace private var glass
    @AppStorage(AppAccent.storageKey) private var accentValue = AppAccent.default.rawValue
    private var accent: AppAccent { AppAccent.resolve(accentValue) }

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
                        if draft.text.isEmpty {
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

                    if showsQueueSend {
                        // The running composer with text to send: the accent
                        // arrow keeps send's rightmost slot and enqueues, while
                        // this small outlined stop key keeps the interrupt
                        // reachable just to its left.
                        queueStopButton
                    }

                    if let contextUsage, contextUsage.isValid, draft.isFocused {
                        ContextRingButton(usage: contextUsage, touchTarget: controls.touchTarget)
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
    }

    /// The queue form: the accent arrow enqueues and the small outlined stop
    /// key sits just to its left.
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

    /// The queue form's small outlined stop key. Same interrupt action as the
    /// idle stop key; only the affordance shrinks so both actions fit.
    private var queueStopButton: some View {
        Button(action: onStop) {
            AppSymbol("stop.fill", size: 12)
                .foregroundStyle(AppTheme.secondaryText(colorScheme))
                .frame(width: queueStopDiameter, height: queueStopDiameter)
                .overlay(Circle().strokeBorder(AppTheme.secondaryControlStroke(colorScheme), lineWidth: 1.5))
                .frame(width: controls.touchTarget, height: controls.touchTarget)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy || !canStop)
        .opacity(canStop && !isBusy ? 1 : 0.42)
        .accessibilityLabel(String(localized: "停止生成"))
        .accessibilityIdentifier("chat.composer.stop")
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
