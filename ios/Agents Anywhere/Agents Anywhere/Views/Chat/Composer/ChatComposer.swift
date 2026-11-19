import SwiftUI

struct ChatComposer: View {
    @Bindable var draft: ComposerDraft
    let editor: ComposerEditorController
    let isStreaming: Bool
    var canSend = true
    var isBusy = false
    var placeholder = String(localized: "输入或长按说话")
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
    /// The visible send key's frame and the bar's frame, in global space.
    /// The native `Menu` is drawn as an overlay OUTSIDE the glass bar and is
    /// placed back onto the key from these two measurements (see
    /// `sendKeyMenu`).
    @State private var sendSlotFrame: CGRect = .zero
    @State private var barFrame: CGRect = .zero
    @AppStorage(AppAccent.storageKey) private var accentValue = AppAccent.storageDefault.rawValue
    /// The same value the settings row edits. Long-press here writes it, so
    /// the menu is a second entry point to the one setting, never a per-send
    /// temporary override.
    @AppStorage(ComposerDeliverySetting.storageKey) private var deliveryRaw =
        ComposerDeliverySetting.defaultValue.rawValue
    /// Settings → 编写器 → 指令图标常驻输入框. Keeps the commands key on screen
    /// even for runtimes without slash commands (pp 2026-11-20).
    @AppStorage(ComposerCommandsSetting.storageKey) private var commandsAlwaysVisible = false
    private var accent: AppAccent { AppAccent.resolve(accentValue) }
    private var delivery: ComposerDelivery { ComposerDeliverySetting.resolve(deliveryRaw) }

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
                            // Official add artwork (pp 2026-11-20); the metric
                            // now carries the ink-tight point size.
                            AppSymbol("anthropicon.add", size: controls.profile.plusSymbolSize)
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

                    // The visible send key stays inside the bar; its native
                    // Menu lives in the overlay OUTSIDE the glass (below).
                    // A Menu nested in a `.glassEffect` view made the whole
                    // composer — text field included — vanish while the menu
                    // was open (pp 2026-11-18 00:10). The overlay Menu is the
                    // key's only hit target now, so this visual never takes
                    // touches.
                    sendKey
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .onGeometryChange(for: CGRect.self) {
                            $0.frame(in: .global)
                        } action: { sendSlotFrame = $0 }

                    // Voice-input placeholder (pp 2026-11-20): the official
                    // empty composer shows a mic inside a 36 pt chrome circle
                    // left of the accent key. Voice input is not implemented
                    // yet, so the tap does nothing for now.
                    Button(action: {}) {
                        // 19, not 16: the cluster's sizes are tuned against the
                        // reference device, where @ScaledMetric shrinks glyphs
                        // ~14% (the plus draws 13 pt ink from a 15.3 config,
                        // matching the official 13). Official mic ink is
                        // 14x16 pt; 19 renders 14.6x16.3 there (2026-11-20).
                        AppSymbol("anthropicon.microphone", size: 19)
                            .foregroundStyle(AppTheme.composerControlGlyph(colorScheme))
                            .frame(width: controls.touchTarget, height: controls.touchTarget)
                            .background {
                                Circle()
                                    .fill(AppTheme.composerControlFill(colorScheme))
                                    .frame(width: controls.sendDiameter,
                                           height: controls.sendDiameter)
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "语音输入"))
                    .accessibilityIdentifier("chat.composer.voice")

                    if showsCommands || commandsAlwaysVisible {
                        Button(action: onCommands) {
                            // Official Skills artwork (pp 2026-11-19): the
                            // rounded sheet with a tag. Both secondary keys
                            // ride the same ink-tight metric, so skills and
                            // plus stay the same optical size in every
                            // profile; the send arrow keeps its own smaller
                            // official glyph.
                            AppSymbol("anthropicon.scroll",
                                      size: controls.profile.plusSymbolSize)
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
        // The native send menu lives HERE, outside the bar's `.glassEffect`:
        // presenting a Menu from inside the glass hid the whole composer
        // (pp 2026-11-18 00:10). The bar is measured so the invisible menu
        // label can sit exactly on the visible key.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { barFrame = $0 }
        .overlay(alignment: .topLeading) { sendKeyMenu }
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

    /// Idle composer with nothing sendable: the accent key wears the official
    /// voice-mode look — black 36 pt disk, white waveform — and swaps back to
    /// the send arrow (animated) as soon as the draft has content
    /// (pp 2026-11-20).
    private var showsVoiceKey: Bool {
        affordance.shape == .send && !draft.hasSendableContent && !isBusy
    }

    /// The send/queue/stop key the bar draws. Display only: the overlay
    /// `sendKeyMenu` above it owns the tap and the long press.
    private var sendKey: some View {
        // Voice glyph 21, not 15: same scaled-metric compensation as the mic
        // — official waveform ink is 18x18 pt (2026-11-20).
        AppSymbol(showsVoiceKey ? "anthropicon.voice" : accentSymbol,
                  size: showsVoiceKey ? 21 : accentSymbolSize)
            .contentTransition(.symbolEffect(.replace))
            // Official stop key: neutral chrome (light #F0EFEC / dark white
            // 8%) with a black text100 square — only the send key wears the
            // accent fill. The voice key is solid black with white glyph.
            .foregroundStyle(showsVoiceKey
                ? AnyShapeStyle(Color.white)
                : AnyShapeStyle(isStopState
                    ? AppTheme.composerControlGlyph(colorScheme)
                    : sendGlyph))
            .frame(width: controls.sendDiameter, height: controls.sendDiameter)
            .background((showsVoiceKey
                ? Color.black
                : (isStopState ? AppTheme.composerControlFill(colorScheme) : sendFill))
                .opacity(showsVoiceKey || (sendEnabled && !isBusy) ? 1 : 0.42), in: Circle())
            .frame(width: controls.touchTarget, height: controls.touchTarget)
            .contentShape(Circle())
            .animation(.snappy(duration: 0.2), value: showsVoiceKey)
    }

    /// The native menu the long press opens, anchored back onto the key.
    ///
    /// A Menu, not a Button + `.contextMenu`: the context menu anchored at the
    /// touch point and stayed there while the keyboard dismissal moved the
    /// composer. A Menu anchors to its label, and its inline picker keeps
    /// 引导/排队 aligned with one leading edge (pp 2026-11-17). The label is
    /// clear on purpose: the visible key is drawn inside the glass bar, while
    /// this copy must stay OUTSIDE the glass subtree — presenting a Menu from
    /// inside a `.glassEffect` view hid the whole composer (pp 2026-11-18
    /// 00:10).
    private var sendKeyMenu: some View {
        Menu {
            // A second entry point to the ONE persisted setting (the settings
            // row is the first). Selecting here writes the same value; there
            // is no per-send temporary override.
            Picker(String(localized: "后续消息处理方式"), selection: $deliveryRaw) {
                ForEach(ComposerDelivery.allCases) { option in
                    Label {
                        Text(option.title)
                    } icon: {
                        MenuArtwork(name: option.menuSymbol)
                    }
                    .tag(option.rawValue)
                }
            }
        } label: {
            Color.clear
                .frame(width: sendSlotFrame.width, height: sendSlotFrame.height)
                .contentShape(Circle())
        } primaryAction: {
            // A gray key still opens this menu on a long press — the delivery
            // choice is a persisted setting, not an action — but it sends
            // nothing (pp 2026-11-18).
            guard !isBusy, sendEnabled else { return }
            // [E] The official send key is an `AnimatingHapticButton` fired
            // with `.selection` (EVIDENCE/round19/motion.md §P2-10). Only the
            // send/queue shapes are documented; the stop shape stays silent.
            if affordance.shape != .stop { sendFeedback += 1 }
            accentAction()
        }
        .menuIndicator(.hidden)
        // The menu opens upward from the bar; the system's default
        // `priority` order puts the FIRST item closest to the key, which
        // rendered the list bottom-up (device 00:10: 排队 above 引导). Fixed
        // order keeps the declared top-to-bottom order (pp 2026-11-18).
        .menuOrder(.fixed)
        .sensoryFeedback(.selection, trigger: sendFeedback)
        .accessibilityLabel(accentLabel)
        .accessibilityHint(draft.isComposing ? String(localized: "请先确认输入法候选文字") : "")
        .accessibilityIdentifier(
            showsQueueSend
                ? (delivery == .steer
                    ? "chat.composer.steerSend"
                    : "chat.composer.queueSend")
                : "chat.composer.send")
        .offset(x: sendSlotFrame.minX - barFrame.minX,
                y: sendSlotFrame.minY - barFrame.minY)
        // Before the first measurement there is no slot to sit on; keep the
        // overlay out of hit testing instead of parking it in the bar's
        // top-left corner.
        .allowsHitTesting(!sendSlotFrame.isEmpty && !barFrame.isEmpty)
        .opacity(sendSlotFrame.isEmpty || barFrame.isEmpty ? 0 : 1)
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
        if showsVoiceKey { return String(localized: "语音输入") }
        switch affordance.shape {
        case .queueSend:
            // VoiceOver must hear what this tap will actually do.
            return delivery == .steer
                ? String(localized: "引导当前任务")
                : String(localized: "加入发送队列")
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
