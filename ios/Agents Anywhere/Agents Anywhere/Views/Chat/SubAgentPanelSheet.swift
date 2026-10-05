import SwiftUI

/// L2 (§3.3): the SubAgent detail panel. Opened from the capsule or from the
/// timeline's Agent card / SubAgent group. Each page is one turn (pp
/// 2026-10-05): the tab strip lists the opening card's turn, so an older
/// dispatch point reopens its own page and a new dispatch opens the new one.
/// Everything renders from the presented rows, so the panel restores after a
/// relaunch and follows live updates exactly like the timeline does.
struct SubAgentPanelSheet: View {
    let chat: SessionChatModel
    let deviceName: String?
    let fallbackRuntimeName: String?
    let onFile: (String) -> Void
    let onAttachment: (V2AttachmentContent) -> Void
    /// The card the panel was opened from — the per-turn page's anchor
    /// (pp 2026-10-05: each turn reopens its own page).
    private let openingCardID: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var selection: String?
    @State private var showsFullPrompt = false

    private static let collapsedPromptLimit = 8
    /// Below this the prompt renders whole; no fold affordance for short text.
    private static let promptFoldThreshold = 300

    init(chat: SessionChatModel, deviceName: String?, fallbackRuntimeName: String?, initialCardID: String?,
         onFile: @escaping (String) -> Void = { _ in }, onAttachment: @escaping (V2AttachmentContent) -> Void = { _ in }) {
        self.chat = chat
        self.deviceName = deviceName
        self.fallbackRuntimeName = fallbackRuntimeName
        self.onFile = onFile
        self.onAttachment = onAttachment
        self.openingCardID = initialCardID
        // The requested card wins; the opening rule (first running tab, else
        // the first) applies whenever it is nil or no longer present.
        _selection = State(initialValue: initialCardID)
    }

    private var cards: [SubAgentCard] {
        SubAgentProgress.turnScopedTopLevelCards(in: chat.timeline.rows.map(\.value),
                                                 containing: openingCardID)
    }
    /// The requested card when it still exists; otherwise the opening rule —
    /// first running tab, else the first one.
    private var selectedCard: SubAgentCard? {
        let list = cards
        if let current = list.first(where: { $0.id == selection }) { return current }
        let fallback = SubAgentProgress.defaultSelection(list, requested: nil)
        return list.first { $0.id == fallback }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let card = selectedCard {
                    // §3.3 order: the fixed stats line sits directly below the
                    // title/subtitle; the tab chips follow, above the body.
                    statsRow(card)
                    tabStrip(selectedID: card.id)
                    ScrollView {
                        sections(card)
                            // Switching tabs swaps the whole body in place, and
                            // the markdown block views are reused by block
                            // position while their reserved height only ever
                            // grows. Without an identity of its own the body
                            // keeps the previous card's heights, so a long block
                            // leaves a blank gap in a short one (pp, device,
                            // 2026-10-05).
                            .id(card.id)
                            .padding(.horizontal, 20)
                            .padding(.top, 4)
                            .padding(.bottom, 24)
                    }
                } else {
                    Spacer(minLength: 0)
                }
            }
            .navigationTitle(selectedCard?.taskName ?? String(localized: "Agent"))
            .navigationSubtitle(SessionHeaderSubtitle.text(metadata: chat.session.metadata,
                deviceName: deviceName, fallbackRuntimeName: fallbackRuntimeName))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetCloseToolbar { dismiss() } }
        }
        .appSheetPresentation(.compact)
        .onChange(of: selection) { _, _ in showsFullPrompt = false }
    }

    // MARK: Header controls

    private func tabStrip(selectedID: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(cards) { card in
                    Button { selection = card.id } label: {
                        HStack(spacing: 6) {
                            Circle().fill(SubAgentPalette.phase(card.phase)).frame(width: 7, height: 7)
                            Text(card.taskName)
                                .font(.footnote.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: 200, alignment: .leading)
                            if let badge = card.badge {
                                Text(badge).font(.caption2)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(.quaternary, in: .capsule)
                            }
                        }
                        .foregroundStyle(card.id == selectedID
                            ? AppTheme.primaryControlForeground(colorScheme)
                            : AppTheme.primaryText(colorScheme))
                        .padding(.horizontal, 12).frame(height: 32)
                        .background(card.id == selectedID
                            ? AppTheme.primaryControlBackground(colorScheme)
                            : AppTheme.groupedFill(colorScheme), in: .capsule)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(card.taskName)
                    .accessibilityValue(card.phase.word)
                    .accessibilityAddTraits(card.id == selectedID ? .isSelected : [])
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.top, 4)
    }

    /// The fixed stats line (§3.3): pinned below the header, never scrolls with
    /// the body, follows the selected tab and freezes when the card closes.
    /// Redesigned as a status badge plus trimmed metrics: the phase word wears
    /// its own color on a wash of that color, the numbers stay neutral gray so
    /// the row scans as one glanceable state + one line of numbers.
    private func statsRow(_ card: SubAgentCard) -> some View {
        let phaseColor = SubAgentPalette.phase(card.phase)
        let metrics = SubAgentProgress.statsLine(for: card)
        return HStack(spacing: 8) {
            HStack(spacing: 5) {
                Circle().fill(phaseColor).frame(width: 6, height: 6)
                Text(card.phase.word)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(phaseColor)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(phaseColor.opacity(Self.badgeFillOpacity(colorScheme)), in: .capsule)
            if !metrics.isEmpty {
                Text(metrics)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
        // One element, one sentence: VoiceOver should read the state and its
        // numbers together instead of stopping on the dot, the badge and the
        // metrics separately.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SubAgentProgress.statsAccessibilityLabel(for: card))
    }

    /// Light mode: a 12% wash reads as a chip on white. Dark mode needs more of
    /// the same color or the chip dissolves into the black background.
    private static func badgeFillOpacity(_ scheme: ColorScheme) -> Double {
        scheme == .dark ? 0.20 : 0.12
    }

    // MARK: Body

    @ViewBuilder private func sections(_ card: SubAgentCard) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            promptSection(card)
            toolSection(card)
            reasoningSection(card)
            outputSection(card)
        }
    }

    @ViewBuilder private func promptSection(_ card: SubAgentCard) -> some View {
        if let prompt = card.prompt, !prompt.isEmpty {
            let foldable = prompt.count > Self.promptFoldThreshold
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel(String(localized: "提示词"))
                VStack(alignment: .leading, spacing: 6) {
                    Text(prompt)
                        .font(.callout)
                        .lineLimit(foldable && !showsFullPrompt ? Self.collapsedPromptLimit : nil)
                        .textSelection(.enabled)
                    if foldable {
                        Button(showsFullPrompt ? String(localized: "收起") : String(localized: "展开")) {
                            withAnimation(.easeInOut(duration: 0.18)) { showsFullPrompt.toggle() }
                        }
                        .font(.footnote.weight(.medium))
                        .frame(minHeight: 32)
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 14))
            }
        }
    }

    @ViewBuilder private func toolSection(_ card: SubAgentCard) -> some View {
        let rows = childRows(of: card).filter { $0.value.type == .tool }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel(String(localized: "工具调用"))
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { row in
                        SessionTimelineRow(row: row, chat: chat, onAttachment: onAttachment,
                            cwd: chat.session.metadata?.cwd, disclosures: chat.disclosures, onFile: onFile)
                    }
                }
            }
        }
    }

    @ViewBuilder private func reasoningSection(_ card: SubAgentCard) -> some View {
        let rows = childRows(of: card).filter { $0.value.isReasoning }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel(String(localized: "深度思考"))
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { row in
                        SessionTimelineRow(row: row, chat: chat, onAttachment: onAttachment,
                            cwd: chat.session.metadata?.cwd, disclosures: chat.disclosures, onFile: onFile)
                    }
                }
            }
        }
    }

    @ViewBuilder private func outputSection(_ card: SubAgentCard) -> some View {
        if let summary = card.summary, !summary.isEmpty, !card.phase.isActive {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel(String(localized: "最终输出"))
                ChatMarkdownView(text: summary)
            }
        }
    }

    private func childRows(of card: SubAgentCard) -> [ChatTimelineRowModel] {
        chat.timeline.rows.filter { SubAgentProgress.parentItemID($0.value) == card.id }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}
