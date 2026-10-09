import SwiftUI
import UIKit

/// L2 (§3.3): the SubAgent detail panel. Opened either from the capsule
/// (entry A) or from a timeline Agent card / SubAgent group (entry B).
///
/// pp 2026-10-08 flattened the panel: there are no per-turn pages any more —
/// a SubAgent shows while it runs and leaves once it ends (运行中显示，结束
/// 退场), with no duplicate names. The layout therefore has two shapes:
///
/// - Entry A (opened from the capsule): the chip strip lists **every active
///   card** in the session (the same window ∪ sidecar union the capsule
///   counts), and each chip drops out on the next redraw once its card
///   reaches a terminal phase. The selected card's detail stays put while the
///   user reads it — even after it completes, so the final output is readable
///   — and disappears only when the user switches or closes.
/// - Entry B (opened from a timeline card): the card's own detail alone, with
///   no chip strip, so an ended dispatch stays browsable from history.
///
/// Everything renders from the presented rows, so the panel restores after a
/// relaunch and follows live updates exactly like the timeline does.
struct SubAgentPanelSheet: View {
    let chat: SessionChatModel
    let deviceName: String?
    let fallbackRuntimeName: String?
    let onFile: (String) -> Void
    /// The second argument is the thumbnail already decoded by the bubble.
    let onAttachment: (V2AttachmentContent, UIImage?) -> Void
    /// The card the panel was opened from, and how it was opened: a capsule
    /// carries the newest active id (entry A), a timeline card its own id
    /// (entry B), nil the whole panel (entry A, no anchor).
    private let openingCardID: String?
    private let opensFromCapsule: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppAccent.storageKey) private var accentValue = AppAccent.default.rawValue
    private var accent: AppAccent { AppAccent.resolve(accentValue) }
    @State private var selection: String?
    @State private var showsFullPrompt = false
    /// P3: whether the selected card's lazily-fetched detail rows are being
    /// loaded. The state bits come from the ClientCore rules above
    /// (`hasDetailRows` / `isContentLoaded`); this only rides beside them so
    /// the body can pick the skeleton over the honest "not loaded" line.
    @State private var isLoadingDetail = false

    private static let collapsedPromptLimit = 8
    /// Below this the prompt renders whole; no fold affordance for short text.
    private static let promptFoldThreshold = 300

    init(chat: SessionChatModel, deviceName: String?, fallbackRuntimeName: String?,
         initialCardID: String?, opensFromCapsule: Bool = false,
         onFile: @escaping (String) -> Void = { _ in }, onAttachment: @escaping (V2AttachmentContent, UIImage?) -> Void = { _, _ in }) {
        self.chat = chat
        self.deviceName = deviceName
        self.fallbackRuntimeName = fallbackRuntimeName
        self.onFile = onFile
        self.onAttachment = onAttachment
        self.openingCardID = initialCardID
        self.opensFromCapsule = opensFromCapsule
        // The requested card wins; otherwise the opening rule (newest active /
        // newest, applied in `selectedCard`) whenever it is nil or gone.
        _selection = State(initialValue: initialCardID)
    }

    private var window: [V2TimelineItem] { chat.timeline.rows.map(\.value) }
    /// The loaded window plus the lazily-fetched SubAgent detail sidecar
    /// (P3): what the activity section can render right now. The card list
    /// itself still reads the window ∪ active-card sidecar — detail rows only
    /// feed the per-card content.
    private var detailWindow: [V2TimelineItem] { window + chat.timeline.detailRows.map(\.value) }
    private var sidecar: [V2ActiveAgentCard] { chat.session.activeAgentCards }
    /// The panel's whole source: every top-level card the session holds, from
    /// the same union the capsule counts (pp 2026-10-08: 不分回合).
    private var sessionCards: [SubAgentCard] {
        SubAgentProgress.sessionCards(inWindow: window, activeCards: sidecar)
    }
    /// The chip strip's set — the active subset in dispatch order. Empty for
    /// entry B, which shows one card's detail with no strip.
    private var activeCards: [SubAgentCard] {
        opensFromCapsule ? sessionCards.filter { $0.phase.isActive } : []
    }
    /// The card being shown. A card the user is reading stays resolved by id
    /// even once it completes (so the final output can be read); when the id is
    /// gone (or never set), the flat panel picks the requested card when it is
    /// still present, else the newest active one (entry A) or the newest card
    /// of the window (entry B, which keeps an ended dispatch readable).
    private var selectedCard: SubAgentCard? {
        if let current = sessionCards.first(where: { $0.id == selection }) { return current }
        if opensFromCapsule {
            return SubAgentProgress.resolveSelection(activeCards, requested: openingCardID)
                ?? SubAgentProgress.resolveSelection(sessionCards, requested: nil)
        }
        return sessionCards.last
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let card = selectedCard {
                    // §3.3 order: the fixed stats line sits directly below the
                    // title/subtitle; the chip strip (entry A) follows, above
                    // the body.
                    statsRow(card)
                    if opensFromCapsule { tabStrip(selectedID: card.id) }
                    ScrollView {
                        sections(card)
                            // Switching chips swaps the whole body in place, and
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
                    SubAgentPanelEmptyState()
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
        .task(id: detailRequest) { await loadDetailIfNeeded() }
    }

    /// The card whose detail rows this screen wants right now: the selection
    /// while its own rows are missing locally, nil otherwise (nothing to
    /// load, or the rows are already here). Keyed on `hasDetailRows`, not
    /// `isContentLoaded`: a card the window still holds reads as "loaded"
    /// while its activity rows may be missing entirely — the normal shape
    /// once the coverage reads exclude them. Driving `.task(id:)` from it
    /// keeps the load one-shot per card — a failed load is not retried until
    /// a new selection, and a card the panel never shows produces no request.
    private var detailRequest: String? {
        guard let card = selectedCard, !SubAgentProgress.hasDetailRows(card, in: detailWindow) else { return nil }
        return card.id
    }

    /// P3: fetches the missing rows through the repository's on-demand
    /// `mode=children` read (lineage-wide, so a resume-alias card pulls its
    /// dispatch sibling's rows too). The skeleton shows while it runs; the
    /// merged rows arrive through the projection like every other update.
    private func loadDetailIfNeeded() async {
        guard let card = selectedCard, !SubAgentProgress.hasDetailRows(card, in: detailWindow) else { return }
        isLoadingDetail = true
        defer { isLoadingDetail = false }
        await chat.session.loadSubAgentDetail(parentIDs: SubAgentProgress.lineageIDs(of: card, in: detailWindow))
    }

    // MARK: Header controls

    /// The chip strip (entry A): every active card in the session, the selected
    /// one included. A chip exits with its card — 结束退场 — on the next
    /// redraw, so the strip never shows a second copy of the same dispatch.
    private func tabStrip(selectedID: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(activeCards) { card in
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
                            ? AppTheme.accentForeground(accent, colorScheme)
                            : AppTheme.primaryText(colorScheme))
                        .padding(.horizontal, 12).frame(height: 32)
                        .background(card.id == selectedID
                            ? AppTheme.accentBackground(accent, colorScheme)
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
            HStack(spacing: 8) {
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
            }
            // One element, one sentence: VoiceOver should read the state and
            // its numbers together instead of stopping on the dot, the badge
            // and the metrics separately. The stop controls stay outside this
            // element — children-ignoring would swallow the buttons.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(SubAgentProgress.statsAccessibilityLabel(for: card))
            Spacer(minLength: 0)
            stopControls(for: card)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    /// §A3: the selected card's live-task stop controls, trailing the header.
    /// 门控不渲染: nothing without the usable `session.subagent_control`
    /// capability, nothing for a card without live tasks; otherwise one
    /// control per live task, each bound to exactly one task id (including
    /// nested tasks, G3 — the projection reads every live `agents` entry).
    @ViewBuilder private func stopControls(for card: SubAgentCard) -> some View {
        let tasks = SubAgentProgress.stopTasks(for: card, capabilities: chat.session.runtime.capabilities)
        if !tasks.isEmpty {
            ForEach(tasks) { task in
                SubAgentStopControl(task: task, showsName: tasks.count > 1,
                    isStopping: chat.stoppingSubagentTaskIDs.contains(task.taskID)) {
                    Task { await chat.stopSubagent(taskID: task.taskID) }
                }
            }
        }
    }

    /// Light mode: a 12% wash reads as a chip on white. Dark mode needs more of
    /// the same color or the chip dissolves into the black background.
    private static func badgeFillOpacity(_ scheme: ColorScheme) -> Double {
        scheme == .dark ? 0.20 : 0.12
    }

    // MARK: Body

    @ViewBuilder private func sections(_ card: SubAgentCard) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            // §3.3 honesty: a card with no loaded row anywhere in its lineage —
            // its own row gone from the window (the sidecar still holds the
            // card) and no sibling's rows either — has its own name, phase and
            // prompt but none of its activity. Say so instead of rendering a
            // blank body that reads as "nothing happened". A resume-alias card
            // passes this gate through its sibling's rows (pp 2026-10-09).
            // P3: while the missing detail rows are being fetched on demand,
            // the skeleton stands in. The notice itself stays bound to
            // `isContentLoaded` (the pre-P3 honesty rule) — a card whose row
            // is present but whose activity is still in flight must not
            // falsely claim nothing is loaded.
            if !SubAgentProgress.hasDetailRows(card, in: detailWindow) {
                if isLoadingDetail { SubAgentDetailLoadingSkeleton() }
                else if !SubAgentProgress.isContentLoaded(card, in: detailWindow) { notLoadedNotice }
            }
            promptSection(card)
            activitySection(card)
            outputSection(card)
        }
    }

    /// Neutral copy: the rows are outside the loaded window, whatever the
    /// reason — no turn is named (pp 2026-10-08: 不分回合).
    private var notLoadedNotice: some View {
        Text(String(localized: "内容未加载"))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 14))
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

    /// The card's activity as one chronological list (pp 2026-10-05): tool
    /// calls, reasoning and the subagent's text rows interleaved in the order
    /// the connector published them, the way the main chat reads. The
    /// per-kind 「工具调用」/「深度思考」 section headers are deliberately
    /// gone; prompt and final output stay at the ends. Which rows qualify is
    /// `SubAgentProgress.activityRows` — its lineage merge means a resume-alias
    /// card shows the original dispatch card's rows — through the same
    /// `isVisibleInChat` gate the chat applies, so hidden rows and empty
    /// reasoning never enter the panel; the row component itself is unchanged
    /// and gets no `onSubAgent` (v1 renders one nested layer).
    @ViewBuilder private func activitySection(_ card: SubAgentCard) -> some View {
        let rows = activityRows(of: card)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(rows) { row in
                    SessionTimelineRow(row: row, chat: chat, onAttachment: onAttachment,
                        cwd: chat.session.metadata?.cwd, disclosures: chat.disclosures, onFile: onFile)
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

    /// The card's visible activity rows, as the row models the chat already
    /// holds. Membership and order come from the ClientCore rule
    /// (`SubAgentProgress.activityRows`, which merges a resume alias with its
    /// original dispatch card); the lookup swaps item ids for those live
    /// models — the window's rows first, the detail sidecar's rows (P3) for
    /// the ones the window no longer holds — so the panel renders the chat's
    /// own reveal state and never duplicates a row.
    private func activityRows(of card: SubAgentCard) -> [ChatTimelineRowModel] {
        let rowsByID = Dictionary((chat.timeline.rows + chat.timeline.detailRows).map { ($0.id, $0) },
                                  uniquingKeysWith: { first, _ in first })
        return SubAgentProgress.activityRows(of: card, in: detailWindow)
            .compactMap { rowsByID[$0.id] }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// P3: the loading placeholder for one card's lazily-paged detail rows —
/// shown while the on-demand `mode=children` load runs, in place of the
/// "内容未加载" notice. Reuses the existing loading copy; the geometry mirrors
/// the activity list's rounded panel so the swap does not jump.
private struct SubAgentDetailLoadingSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.quaternary)
                    .frame(height: 13)
                    .frame(maxWidth: index == 2 ? 180 : .infinity, alignment: .leading)
                    .opacity([0.9, 0.65, 0.45][index])
            }
            HStack(spacing: 8) {
                ProgressView().progressViewStyle(.circular).controlSize(.small)
                Text(String(localized: "正在加载较早的消息…"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

/// The flat panel's only empty state (pp 2026-10-08: 宁简勿怪): reached when
/// the session holds no top-level SubAgent card at all — no active work and
/// nothing to browse. A single quiet line, no chip and no turn wording.
private struct SubAgentPanelEmptyState: View {
    var body: some View {
        VStack {
            Spacer(minLength: 0)
            Text(String(localized: "暂无子代理"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
