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
    /// Converts a pasted log into an attachment before it reaches the editor.
    /// Returns true when the paste was consumed as a file.
    var onLongPaste: ((String) -> Bool)? = nil
    /// Opens the markup editor for a staged image attachment.
    var onEditAttachment: ((ChatAttachment) -> Void)? = nil
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
    @AppStorage(AppAccent.storageKey) private var accentValue = AppAccent.storageDefault.rawValue
    private var accent: AppAccent { AppAccent.resolve(accentValue) }

    var body: some View {
        // [E] R19 chrome-composer.md §1 — the official composer is
        // `GlassEffectContainer(spacing: nil)` + `Glass.regular.interactive`
        // in a continuous rounded rectangle; it is not a solid/Material bar.
        GlassEffectContainer(spacing: nil) {
            VStack(spacing: 0) {
                if !draft.attachments.isEmpty { attachmentTray }
                ComposerLayout(expanded: draft.isExpanded, maximumEditorHeight: maximumEditorHeight, controls: controls) {
                    HStack(spacing: 8) {
                        Button(action: onOptions) {
                            AppSymbol("plus", size: controls.profile.plusSymbolSize)
                                .foregroundStyle(AppTheme.composerControlGlyph(colorScheme))
                                .frame(width: controls.touchTarget, height: controls.touchTarget)
                                .background {
                                    if controls.profile.plusStyle == .circle {
                                        // Official chrome: 36 pt circle inside
                                        // the 44 pt hit slot, #F0EFEC light /
                                        // white 8% dark (round30 §3.3).
                                        Circle()
                                            .fill(AppTheme.composerControlFill(colorScheme))
                                            .frame(width: controls.profile.plusCircleDiameter,
                                                   height: controls.profile.plusCircleDiameter)
                                    }
                                }
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "附件与对话选项"))
                        .accessibilityIdentifier("chat.composer.options")
                    }

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
                            expandAnimation: expandAnimation, onLongPaste: onLongPaste)
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
                            // Official stop key: neutral chrome (light #F0EFEC /
                            // dark white 8%) with a black text100 square — only
                            // the send key wears the accent fill.
                            .foregroundStyle(isStopState
                                ? AnyShapeStyle(AppTheme.composerControlGlyph(colorScheme))
                                : AnyShapeStyle(sendGlyph))
                            .frame(width: controls.sendDiameter, height: controls.sendDiameter)
                            .background((isStopState
                                ? AppTheme.composerControlFill(colorScheme)
                                : sendFill)
                                .opacity(sendEnabled && !isBusy ? 1 : 0.42), in: Circle())
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
                        ContextRingButton(state: contextUsage,
                            touchTarget: controls.touchTarget,
                            ringDiameter: controls.contextRingDiameter,
                            visualOffsetX: Self.contextRingOpticalShift)
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

    /// The ring's slot is centred between the command glyph (18 pt) and the
    /// send key's disc (36 pt), so the visible gap is 26 pt on the command
    /// side and 17 pt on the send side. Half that difference re-centres the
    /// ring optically without moving the slot or its hit area
    /// (pp 2026-11-10).
    private static let contextRingOpticalShift: CGFloat = -4.5

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
        // Official glyph ink: send arrow ~11×13 pt, stop square 12×12 pt.
        // The Lucide assets fill 14/24 (arrow) and 18/24 (square) of their
        // frame, so the frames are 20 and 16 to land on the official ink.
        affordance.shape == .stop ? 18 : 20
    }

    private var isStopState: Bool { affordance.shape == .stop }

    /// The send key keeps the official terracotta while the app accent stays
    /// the shipped black-and-white default; choosing another accent still
    /// recolors the key, so the accent feature is intact.
    private var sendFill: Color {
        accent == .default ? AppTheme.claudeTerracotta : AppTheme.accentBackground(accent, colorScheme)
    }

    private var sendGlyph: Color {
        accent == .default ? .white : AppTheme.accentForeground(accent, colorScheme)
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
            // Official AttachmentBar: items 4 pt apart, 8 pt inside the card.
            HStack(spacing: 4) {
                ForEach(draft.attachments) { attachment in
                    ChatComposerAttachment(
                        attachment: attachment,
                        onRemove: { draft.attachments.removeAll { $0.id == attachment.id } },
                        onEdit: onEditAttachment.map { edit in { edit(attachment) } })
                }
            }
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }
}
