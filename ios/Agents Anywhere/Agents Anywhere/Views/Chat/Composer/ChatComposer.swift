import SwiftUI

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
    @State private var sendFeedback = 0
    @AppStorage(AppAccent.storageKey) private var accentValue = AppAccent.default.rawValue
    private var accent: AppAccent { AppAccent.resolve(accentValue) }

    var body: some View {
        // [E] R19 chrome-composer.md §1 — the official composer is
        // `GlassEffectContainer(spacing: nil)` + `Glass.regular.interactive`
        // in a continuous rounded rectangle; it is not a solid/Material bar.
        GlassEffectContainer(spacing: nil) {
            VStack(spacing: 0) {
                if !draft.attachments.isEmpty { attachmentTray }
                ComposerLayout(expanded: draft.isExpanded, maximumEditorHeight: maximumEditorHeight, controls: controls) {
                    Button(action: onOptions) {
                        AppSymbol("plus", size: controls.profile.plusSymbolSize)
                            .frame(width: controls.touchTarget, height: controls.touchTarget)
                            .background {
                                if controls.profile.plusStyle == .circle {
                                    // ~#F0F0EE on the official light card.
                                    Circle().fill(Color.primary.opacity(0.05))
                                }
                            }
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
                        NativeComposerEditor(draft: draft, controller: editor,
                            maximumHeight: maximumEditorHeight, onCommandSend: onSend,
                            expandAnimation: expandAnimation)
                    }

                    Button {
                        // [E] The official send key is an `AnimatingHapticButton`
                        // fired with `.selection` (EVIDENCE/round19/motion.md
                        // §P2-10). Only the send/queue shapes are documented;
                        // the stop shape stays silent.
                        if affordance.shape != .stop { sendFeedback += 1 }
                        accentAction()
                    } label: {
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
                    .sensoryFeedback(.selection, trigger: sendFeedback)
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
            .glassEffect(.regular.interactive(), in: RoundedRectangle(
                cornerRadius: draft.isExpanded
                    ? controls.expandedCornerRadius : controls.collapsedCornerRadius,
                style: .continuous))
            .glassEffectID("composer", in: glass)
        }
        .padding(.horizontal, controls.horizontalInset(expanded: draft.isExpanded))
        .padding(.top, controls.topMargin)
        .padding(.bottom, controls.bottomMargin(expanded: draft.isExpanded))
        .animation(expandAnimation, value: draft.isExpanded)
        // The composer is the only subtree that already re-evaluates on every
        // keystroke, including each Chinese IME marked-text update. Observing
        // the draft from the page root re-evaluated the whole conversation.
        .onChange(of: draft.text) { _, _ in onDraftChange() }
        .onChange(of: draft.attachments) { _, _ in onDraftChange() }
    }

    /// The queue form: the single accent key shows the arrow and enqueues.
    private var showsQueueSend: Bool { affordance.shape == .queueSend }

    /// The profile owns the transition curve: Chat keeps `.smooth(0.24)`,
    /// Code uses the official `spring(response: 0.22, dampingFraction: 0.77)`.
    private var expandAnimation: Animation? {
        guard !reduceMotion else { return nil }
        switch controls.expandAnimation {
        case .smooth(let duration):
            return .smooth(duration: duration)
        case .spring(let response, let dampingFraction):
            return .spring(response: response, dampingFraction: dampingFraction)
        }
    }

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
