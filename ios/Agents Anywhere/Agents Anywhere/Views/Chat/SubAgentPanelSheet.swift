import SwiftUI
import UIKit

/// L2 (§3.3): the SubAgent detail panel. Opened either from the capsule
/// (entry A) or from a timeline Agent card / SubAgent group (entry B).
///
/// pp 2026-10-08 flattened the panel: there are no per-turn pages any more —
/// a SubAgent shows while it runs and leaves once it ends (运行中显示，结束
/// 退场), with no duplicate names. pp 2026-11-15 gave entry A its reference
/// shape: a card list first, the chat-like detail behind a tap. The panel
/// therefore has two shapes:
///
/// - Entry A (opened from the capsule): a list of **every active card** in the
///   session (the same window ∪ sidecar union the capsule counts) — one card
///   per SubAgent, each with its live activity line. A card drops out of the
///   list on the next redraw once it reaches a terminal phase; tapping a card
///   pushes its detail. A detail the user is reading stays put even after its
///   card completes, so the final output is readable.
/// - Entry B (opened from a timeline card): the card's own detail directly,
///   with no list, so an ended dispatch stays browsable from history.
///
/// Everything renders from the presented rows, so the panel restores after a
/// relaunch and follows live updates exactly like the timeline does. A
/// main-only window (C2) carries no child rows at all, so its activity is read
/// on demand (C3) and merged with the live rows the window still receives.
struct SubAgentPanelSheet: View {
    let chat: SessionChatModel
    let deviceName: String?
    let fallbackRuntimeName: String?
    let onFile: (String) -> Void
    /// The second argument is the thumbnail already decoded by the bubble.
    let onAttachment: (V2AttachmentContent, UIImage?) -> Void
    /// The card the panel was opened from, and how it was opened: a timeline
    /// card carries its own id (entry B), nil the whole panel (entry A, no
    /// anchor). The capsule still passes the newest active id, but entry A now
    /// always starts on the list (pp 2026-11-15), so the id is unused there.
    private let openingCardID: String?
    private let opensFromCapsule: Bool

    @Environment(\.dismiss) private var dismiss
    /// Entry A's navigation: the list is the root; a tapped card pushes its
    /// detail. Entry B starts on the detail and never pushes.
    @State private var path: [String] = []
    /// The floating pills' visual height (their tap target keeps 44 pt).
    @ScaledMetric(relativeTo: .caption) private var pillHeight: CGFloat = 32

    /// C3: the on-demand child-row source. It lives on the session model so
    /// its per-card cache outlives the sheet and feeds the local archive; this
    /// view only drives activation and cancellation.
    private var activity: SubAgentActivityStore { chat.session.subAgentActivity }

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
    }

    private var window: [V2TimelineItem] { chat.timeline.rows.map(\.value) }
    private var sidecar: [V2ActiveAgentCard] { chat.session.activeAgentCards }
    /// The panel's whole source: every top-level card the session holds, from
    /// the same union the capsule counts (pp 2026-10-08: 不分回合).
    private var sessionCards: [SubAgentCard] {
        SubAgentProgress.sessionCards(inWindow: window, activeCards: sidecar)
    }
    /// The list's set — the active subset in dispatch order. Empty for entry
    /// B, which shows one card's detail with no list.
    private var activeCards: [SubAgentCard] {
        opensFromCapsule ? sessionCards.filter { $0.phase.isActive } : []
    }
    /// The card the sheet shows in detail: the pushed card (entry A), or the
    /// requested/newest card (entry B, which keeps an ended dispatch readable).
    /// Nil while entry A is showing the list.
    private var selectedCard: SubAgentCard? {
        if let id = path.last {
            return sessionCards.first(where: { $0.id == id })
        }
        guard !opensFromCapsule else { return nil }
        return SubAgentProgress.resolveSelection(sessionCards, requested: openingCardID)
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if opensFromCapsule, !activeCards.isEmpty {
                    SubAgentAgentList(cards: activeCards, chat: chat) { path.append($0) }
                        .toolbar { SheetCloseToolbar { dismiss() } }
                } else if !opensFromCapsule, let card = selectedCard {
                    detail(card)
                } else {
                    SubAgentPanelEmptyState()
                        .navigationTitle("")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { SheetCloseToolbar { dismiss() } }
                }
            }
            .navigationDestination(for: String.self) { id in
                if let card = sessionCards.first(where: { $0.id == id }) {
                    detail(card)
                } else {
                    SubAgentPanelEmptyState()
                        .navigationTitle("")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { SheetCloseToolbar { dismiss() } }
                }
            }
        }
        .appSheetPresentation(.compact)
        // Every presentation starts a refresh window: rows restored from the
        // archive (or read by an earlier presentation) show immediately but
        // are fetched again online. Activation runs from both hooks so the
        // order SwiftUI picks between them cannot leave a stale first card.
        .onAppear {
            activity.beginPresentation()
            activateActivity()
        }
        .task(id: selectedCard?.id) { activateActivity() }
        // Live child rows reach the panel through the window; push them into
        // the store only when their identity/version set changes, so the merge
        // stays out of the body. The `updatedSeq` component is what lets a
        // status/content change (not just an id arriving) refresh the merged
        // copy that decides which rows the panel renders.
        .onChange(of: activityWindowRowSignature, initial: true) { _, _ in
            activity.updateWindow(childRows: liveActivityChildRows)
        }
        .onDisappear { activity.cancel() }
    }

    /// Only a main-only window needs the on-demand read; a normal one already
    /// carries the child rows in `chat.timeline.rows`.
    private func activateActivity() {
        guard chat.session.windowExcludesAgentChildren, let card = selectedCard else { return }
        activity.activate(cardID: card.id,
            lineageIDs: SubAgentProgress.lineageIDs(of: card, in: window))
        // The lineage just changed; hand over this card's live rows at once.
        activity.updateWindow(childRows: liveActivityChildRows)
    }

    /// The identity set of the window rows belonging to the shown card. The
    /// ids — not the row contents — drive the merge: a streaming token updates
    /// the live row model in place, and the panel renders that model anyway.
    private var activityWindowRowSignature: [String] {
        let lineage = activity.lineageIDs
        guard !lineage.isEmpty else { return [] }
        var signature: [String] = []
        for row in chat.timeline.rows {
            if case .agents(let parent) = row.structure.groupKind, lineage.contains(parent) {
                // A live row can change status/content under the same id; the
                // merged copy must follow so the activity filter never keeps a
                // row the timeline now hides.
                signature.append("\(row.id)#\(row.value.updatedSeq)")
            }
        }
        return signature
    }

    private var liveActivityChildRows: [V2TimelineItem] {
        let lineage = activity.lineageIDs
        guard !lineage.isEmpty else { return [] }
        return chat.timeline.rows.compactMap { row in
            guard case .agents(let parent) = row.structure.groupKind, lineage.contains(parent) else { return nil }
            return row.value
        }
    }

    // MARK: Detail

    /// One card's detail: a miniature chat — the dispatch prompt as the user's
    /// bubble, then the same rows the timeline renders (assistant bubbles,
    /// tool cards, thinking), with the final-output fallback after. The status
    /// and stop affordances float over the body as glass pills (pp 2026-11-15),
    /// the same family as the timeline's 「到底部」 pill.
    private func detail(_ card: SubAgentCard) -> some View {
        ScrollView {
            sections(card)
                // Switching cards swaps the whole body in place, and the
                // markdown block views are reused by block position while
                // their reserved height only ever grows. Without an
                // identity of its own the body keeps the previous card's
                // heights, so a long block leaves a blank gap in a short
                // one (pp, device, 2026-10-05).
                .id(card.id)
                .padding(.horizontal, 20)
                // Clear the floating pills at rest; content scrolls under
                // them once the reader moves.
                .padding(.top, 52)
                .padding(.bottom, 24)
        }
        .overlay(alignment: .topLeading) {
            statusPill(card).padding(.leading, 16).padding(.top, 6)
        }
        .overlay(alignment: .topTrailing) {
            stopPills(card).padding(.trailing, 16).padding(.top, 6)
        }
        // The chat page's own page colour (#F9F9F7 / #151515); the list uses
        // the same value through the composer-sheet token.
        .background(Color(uiColor: CodePageTheme.pageBackgroundUIColor).ignoresSafeArea())
        .navigationTitle(card.taskName)
        .navigationSubtitle(SessionHeaderSubtitle.text(metadata: chat.session.metadata,
            deviceName: deviceName, fallbackRuntimeName: fallbackRuntimeName))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { SheetCloseToolbar { dismiss() } }
    }

    // MARK: Floating controls

    /// The status capsule: phase dot + word and the trimmed telemetry, floating
    /// over the chat body. Non-interactive; a running card's clock ticks
    /// locally every second between the connector's publications.
    @ViewBuilder private func statusPill(_ card: SubAgentCard) -> some View {
        if card.phase.isActive {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                statusPillContent(card, now: context.date)
            }
        } else {
            statusPillContent(card, now: nil)
        }
    }

    private func statusPillContent(_ card: SubAgentCard, now: Date?) -> some View {
        let phaseColor = SubAgentPalette.phase(card.phase)
        let metrics = SubAgentProgress.metrics(for: card, now: now)
        return HStack(spacing: 6) {
            Circle().fill(phaseColor).frame(width: 6, height: 6)
            Text(card.phase.word)
                .font(.caption.weight(.medium))
                .foregroundStyle(phaseColor)
                .lineLimit(1)
            if !metrics.isEmpty {
                // One telemetry strip: glyph + number pairs (⚒ 100 ◷ 37:48
                // ↑ 380k ↓ 12k) — pp, 2026-10-21.
                HStack(spacing: 8) {
                    ForEach(Array(metrics.enumerated()), id: \.offset) { _, metric in
                        HStack(spacing: 3) {
                            AppSymbol(metric.symbol, size: 10)
                                .foregroundStyle(.secondary)
                            Text(metric.value)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: pillHeight)
        .glassEffect(.regular, in: .capsule)
        // One element, one sentence; spoken from the stored numbers so the
        // ticking clock cannot re-announce the element while VoiceOver is on it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SubAgentProgress.statsAccessibilityLabel(for: card))
    }

    /// The stop affordance as floating glass capsules, one per live task. 门控
    /// 不渲染: nothing without the usable `session.subagent_control` capability
    /// and nothing for a card without live tasks.
    @ViewBuilder private func stopPills(_ card: SubAgentCard) -> some View {
        let tasks = SubAgentProgress.stopTasks(for: card, capabilities: chat.session.runtime.capabilities)
        if !tasks.isEmpty {
            HStack(spacing: 8) {
                ForEach(tasks) { task in
                    Button { Task { await chat.stopSubagent(taskID: task.taskID) } } label: {
                        Label(tasks.count > 1 ? (task.label ?? String(localized: "停止")) : String(localized: "停止"),
                              appSymbol: "stop.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .frame(height: pillHeight)
                            .glassEffect(.regular.interactive(), in: .capsule)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(chat.stoppingSubagentTaskIDs.contains(task.taskID))
                    .opacity(chat.stoppingSubagentTaskIDs.contains(task.taskID) ? 0.5 : 1)
                    .accessibilityIdentifier("chat.subagent.stop.\(task.taskID)")
                    .accessibilityLabel(stopAccessibilityLabel(task: task, multiple: tasks.count > 1))
                }
            }
        }
    }

    /// The control is the feature's own body; the task's name joins only when
    /// controls are stacked, so VoiceOver can tell the buttons apart.
    private func stopAccessibilityLabel(task: SubAgentTask, multiple: Bool) -> String {
        let base = String(localized: "停止子代理")
        guard multiple, let label = task.label else { return base }
        return "\(base) \(label)"
    }

    // MARK: Body

    @ViewBuilder private func sections(_ card: SubAgentCard) -> some View {
        // C3 owns the (window ∪ fetched) union as store state; a normal window
        // still reads the timeline directly, exactly as before.
        let items = activityItems
        VStack(alignment: .leading, spacing: 20) {
            // §3.3 honesty: a card with no loaded row anywhere in its lineage —
            // its own row gone from the window (the sidecar still holds the
            // card) and no sibling's rows either — has its own name, phase and
            // prompt but none of its activity. Say so instead of rendering a
            // blank body that reads as "nothing happened". A resume-alias card
            // passes this gate through its sibling's rows (pp 2026-10-09).
            // A main-only window (C2) can never carry the child rows, so the
            // card's own row must not pass the gate there; C3's fetched rows
            // are the only thing that can.
            if showsContentNotLoaded(card, in: items) {
                notLoadedNotice
            }
            promptSection(card)
            activitySection(card, in: items)
            outputSection(card)
        }
    }

    /// The rows the activity list reads. A main-only window uses the store's
    /// merged state (live child rows ∪ fetched pages); a normal window already
    /// carries everything in `chat.timeline.rows`.
    private var activityItems: [V2TimelineItem] {
        guard chat.session.windowExcludesAgentChildren else { return window }
        // Between a card switch and the store's activation the store still
        // holds the previous card's rows; never show one card's activity under
        // another card's header, even for a frame.
        guard activity.cardID == selectedCard?.id else { return [] }
        return activity.displayRows
    }

    /// Whether the panel must say 「内容未加载」. Today's rule (no row of the
    /// card's lineage in the window) stays for a normal window. A main-only
    /// window settles it only after its on-demand read: zero child rows then
    /// means the activity really is not loaded, while a read still in flight
    /// must not claim it.
    private func showsContentNotLoaded(_ card: SubAgentCard, in items: [V2TimelineItem]) -> Bool {
        guard chat.session.windowExcludesAgentChildren else {
            return !SubAgentProgress.isContentLoaded(card, in: window)
        }
        switch activity.phase {
        case .loaded, .unsupported, .offline:
            return !SubAgentProgress.isContentLoaded(card, in: items, windowExcludesAgentChildren: true,
                lineage: activity.lineageIDs.isEmpty ? nil : activity.lineageIDs)
        case .idle, .loading, .loadingOlder, .failed:
            // Not known yet, or the failure row below already says why.
            return false
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

    /// The dispatch prompt as the chat page's own user bubble — the detail is a
    /// miniature chat: the instruction on the right, the subagent's own rows
    /// (assistant bubbles, tool cards, thinking) underneath.
    @ViewBuilder private func promptSection(_ card: SubAgentCard) -> some View {
        if let prompt = card.prompt, !prompt.isEmpty {
            UserMessageBubble(text: prompt)
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
    @ViewBuilder private func activitySection(_ card: SubAgentCard, in items: [V2TimelineItem]) -> some View {
        let rows = activityRows(of: card, in: items)
        // An empty, settled read renders nothing here (the not-loaded notice
        // already speaks for it); an empty VStack would still eat the outer
        // stack's spacing.
        if !rows.isEmpty || hasActivityStatus(rows: rows) {
            VStack(alignment: .leading, spacing: 8) {
                // The on-demand read's own state (C3). Only a main-only window
                // ever leaves `.idle`: a normal window already holds the rows.
                switch activity.phase {
                case .loading:
                    loadingRow(String(localized: "正在加载子代理活动…"))
                case .loadingOlder:
                    loadingRow(String(localized: "正在加载更早的活动…"))
                case .failed(let message):
                    activityFailure(message)
                case .loaded:
                    if activity.hasMore, let oldest = rows.first?.value.orderSeq {
                        Button(String(localized: "加载更早的活动")) {
                            activity.loadOlder(beforeOrderSeq: oldest)
                        }
                        .font(.footnote.weight(.medium))
                        .frame(minHeight: 32)
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                    }
                case .idle, .unsupported, .offline:
                    EmptyView()
                }
                if !rows.isEmpty {
                    // Lazy: after a few pages this list can hold hundreds of
                    // rows, and eagerly building every row makes the sheet's
                    // first layout (and every body tick) pay for all of them.
                    // It stays above the final-output section, both inside the
                    // ScrollView.
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(rows) { row in
                            SessionTimelineRow(row: row, chat: chat, onAttachment: onAttachment,
                                cwd: chat.session.metadata?.cwd, disclosures: chat.disclosures, onFile: onFile)
                        }
                    }
                }
            }
        }
    }

    private func hasActivityStatus(rows: [ChatTimelineRowModel]) -> Bool {
        switch activity.phase {
        case .loading, .loadingOlder, .failed: return true
        case .loaded: return activity.hasMore && rows.first != nil
        case .idle, .unsupported, .offline: return false
        }
    }

    private func loadingRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().progressViewStyle(.circular).controlSize(.small)
            Text(text).font(.footnote).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }

    private func activityFailure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message).font(.footnote).foregroundStyle(.secondary)
            Button(String(localized: "重试")) { activity.retry() }
                .font(.footnote.weight(.medium))
                .frame(minHeight: 32)
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
        }
    }

    @ViewBuilder private func outputSection(_ card: SubAgentCard) -> some View {
        // `finalOutputSummary` returns nil exactly while the activity stream
        // above already renders this same reply, so a finished card shows its
        // final answer once, not twice (pp 2026-10-15 真机). When the reply is
        // not visible as a row (it sits outside the loaded window, a killed
        // notice carries none), the summary is the only copy and still renders.
        // `activityItems` (not `window`) is the body actually rendered above: a
        // main-only window carries no child rows, so reading `window` here
        // would miss the reply the on-demand read did load and render it twice.
        if let summary = SubAgentProgress.finalOutputSummary(of: card, in: activityItems),
           !card.phase.isActive {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel(String(localized: "最终输出"))
                ChatMarkdownView(text: summary)
            }
        }
    }

    /// The card's visible activity rows, as row models. Membership and order
    /// come from the ClientCore rule (`SubAgentProgress.activityRows`, which
    /// merges a resume alias with its original dispatch card). A row the live
    /// window holds keeps the chat's own model (and its reveal state); a row
    /// that came only from the on-demand read (C3) gets a model owned by the
    /// activity store, so it survives body re-evaluations.
    private func activityRows(of card: SubAgentCard, in items: [V2TimelineItem]) -> [ChatTimelineRowModel] {
        // A main-only read returns child rows only; the lineage must come from
        // the window's card rows, or a resume-alias card would filter its
        // dispatch sibling's rows away and render nothing.
        let visible = SubAgentProgress.activityRows(
            of: card, in: items,
            lineage: activity.lineageIDs.isEmpty ? nil : activity.lineageIDs)
        guard !visible.isEmpty else { return [] }
        // Index only the wanted rows: the window can hold a thousand rows, and
        // building a dictionary of all of them on every body tick is waste.
        let wanted = Set(visible.map(\.id))
        var rowsByID: [V2TimelineItemID: ChatTimelineRowModel] = [:]
        for row in chat.timeline.rows where wanted.contains(row.id) { rowsByID[row.id] = row }
        return visible.map { rowsByID[$0.id] ?? activity.rowModel(for: $0) }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
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
        .background(Color(uiColor: CodePageTheme.pageBackgroundUIColor).ignoresSafeArea())
    }
}
