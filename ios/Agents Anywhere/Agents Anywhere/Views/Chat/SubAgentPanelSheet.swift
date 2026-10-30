import SwiftUI
import UIKit

/// L2 (§3.3): the SubAgent panel. Opened either from the circular glass entry
/// above the composer (entry A) or from a timeline Agent card / SubAgent group
/// (entry B).
///
/// pp 2026-10-30 replaced the old chip strip with a list-first page: the
/// circular entry always lands on one capsule row per active SubAgent, even
/// when only one is running, and tapping a row pushes that card's detail.
/// A finished card leaves the list (the entry itself is active-only) and stays
/// reachable from its timeline tool row, which opens entry B directly.
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
    /// The card the panel was opened from, and how it was opened: a capsule
    /// carries the newest active id (entry A), a timeline card its own id
    /// (entry B), nil the whole panel (entry A, no anchor).
    private let openingCardID: String?
    private let opensFromCapsule: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var selection: String?
    @State private var showsFullPrompt = false
    /// The list-first entry (pp 2026-10-30): the circular glass button always
    /// lands on the capsule-row list, even for a single running SubAgent.
    @State private var showsList: Bool
    /// A tapped step group pushes the same detail sheet the chat timeline uses.
    @State private var stepGroupDetail: CodeStepGroupDetailRequest?
    /// C3: the on-demand child-row source. It lives on the session model so
    /// its per-card cache outlives the sheet and feeds the local archive; this
    /// view only drives activation and cancellation.
    private var activity: SubAgentActivityStore { chat.session.subAgentActivity }

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
        _showsList = State(initialValue: opensFromCapsule)
    }

    private var window: [V2TimelineItem] { chat.timeline.rows.map(\.value) }
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
            Group {
                if opensFromCapsule && showsList {
                    listPage
                } else if let card = selectedCard {
                    detailPage(card)
                } else {
                    SubAgentPanelEmptyState()
                }
            }
            .toolbar { SheetCloseToolbar { dismiss() } }
        }
        .appSheetPresentation(.compact)
        .sheet(item: $stepGroupDetail) { request in
            CodeStepGroupDetailView(group: request.group,
                                    cwd: chat.session.metadata?.cwd,
                                    startsAtBottom: request.startsAtBottom)
        }
    }

    // MARK: - List

    /// The list-first page (pp 2026-10-30): the circular glass button always
    /// lands here, even with one running SubAgent. Active cards only, in
    /// dispatch order; a finished card leaves the list and stays reachable from
    /// its timeline tool row.
    private var listPage: some View {
        let cards = activeCards
        return ScrollView {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                LazyVStack(spacing: 12) {
                    ForEach(cards) { card in
                        SubAgentListRow(
                            card: card,
                            now: card.phase.isActive ? context.date : nil,
                            stopTasks: rowStopTasks(for: card),
                            stoppingTaskIDs: chat.stoppingSubagentTaskIDs,
                            onTap: {
                                selection = card.id
                                showsFullPrompt = false
                                showsList = false
                            },
                            onStop: { taskID in
                                Task { await chat.stopSubagent(taskID: taskID) }
                            })
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .navigationTitle(cards.isEmpty
                         ? String(localized: "子代理")
                         : String(localized: "\(cards.count) 个智能体正在运行"))
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if cards.isEmpty { SubAgentPanelEmptyState() }
        }
    }

    /// Only a card with exactly one live task gets the row-level stop; a
    /// multi-task card stops from its detail page, one control per task.
    private func rowStopTasks(for card: SubAgentCard) -> [SubAgentTask] {
        let tasks = SubAgentProgress.stopTasks(for: card,
                                               capabilities: chat.session.runtime.capabilities)
        return tasks.count == 1 ? tasks : []
    }

    // MARK: - Detail

    private func detailPage(_ card: SubAgentCard) -> some View {
        VStack(spacing: 0) {
            statsRow(card)
            ScrollView {
                sections(card)
                    // A card switch must not reuse the previous card's
                    // markdown heights by block position.
                    .id(card.id)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
            }
            stopBar(card)
        }
        .navigationTitle(card.taskName)
        .navigationSubtitle(SessionHeaderSubtitle.text(metadata: chat.session.metadata,
            deviceName: deviceName, fallbackRuntimeName: fallbackRuntimeName))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if opensFromCapsule {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showsList = true
                    } label: {
                        AppSymbol("chevron.left", size: 16)
                    }
                    .accessibilityLabel(String(localized: "返回列表"))
                }
            }
        }
        .onAppear {
            activity.beginPresentation()
            activateActivity(cardID: card.id)
        }
        .task(id: card.id) { activateActivity(cardID: card.id) }
        // Live child rows reach the panel through the window; push them into
        // the store only when their identity/version set changes.
        .onChange(of: activityWindowRowSignature, initial: true) { _, _ in
            activity.updateWindow(childRows: liveActivityChildRows)
        }
        .onDisappear { activity.cancel() }
    }

    /// The bottom stop affordance (pp 2026-10-30): one capsule per live task,
    /// fixed above the safe area. A single task keeps the bare 「停止智能体」;
    /// a multi-task card names each control with its task label.
    @ViewBuilder private func stopBar(_ card: SubAgentCard) -> some View {
        let tasks = SubAgentProgress.stopTasks(for: card,
                                               capabilities: chat.session.runtime.capabilities)
        if !tasks.isEmpty {
            VStack(spacing: 8) {
                ForEach(tasks) { task in
                    Button {
                        Task { await chat.stopSubagent(taskID: task.taskID) }
                    } label: {
                        Text(tasks.count > 1
                             ? "\(String(localized: "停止")) \(task.label ?? String(localized: "智能体"))"
                             : String(localized: "停止智能体"))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(CodePageTheme.userBubbleText.resolved(for: colorScheme))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(CodePageTheme.userBubbleFill.resolved(for: colorScheme),
                                        in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .disabled(chat.stoppingSubagentTaskIDs.contains(task.taskID))
                    .accessibilityIdentifier("chat.subagent.stop.\(task.taskID)")
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
    }

    /// Only a main-only window needs the on-demand read; a normal one already
    /// carries the child rows in `chat.timeline.rows`.
    private func activateActivity(cardID: String) {
        guard chat.session.windowExcludesAgentChildren,
              let card = sessionCards.first(where: { $0.id == cardID }) else { return }
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

    /// The fixed stats line (§3.3): pinned below the header, never scrolls with
    /// the body, follows the selected tab and freezes when the card closes.
    /// Redesigned as a status badge plus trimmed metrics: the phase word wears
    /// its own color on a wash of that color, the numbers stay neutral gray so
    /// the row scans as one glanceable state + one line of numbers.
    @ViewBuilder
    private func statsRow(_ card: SubAgentCard) -> some View {
        // A running card's clock ticks locally every second between the
        // connector's publications (pp, 2026-10-21: 实时); a finished card is
        // static, so it skips the per-second redraw entirely.
        if card.phase.isActive {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                statsContent(card, now: context.date)
            }
        } else {
            statsContent(card, now: nil)
        }
    }

    private func statsContent(_ card: SubAgentCard, now: Date?) -> some View {
        let phaseColor = SubAgentPalette.phase(card.phase)
        let metrics = SubAgentProgress.metrics(for: card, now: now)
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
                    // One telemetry strip: glyph + number pairs (⚒ 100  ◷
                    // 37:48  ↑ 380k  ↓ 12k) — pp, 2026-10-21.
                    HStack(spacing: 10) {
                        ForEach(Array(metrics.enumerated()), id: \.offset) { _, metric in
                            HStack(spacing: 4) {
                                AppSymbol(metric.symbol, size: 12)
                                    .foregroundStyle(.secondary)
                                Text(metric.value)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            // One element, one sentence: VoiceOver should read the state and
            // its numbers together instead of stopping on the dot, the badge
            // and the metrics separately. The stop controls stay outside this
            // element — children-ignoring would swallow the buttons.
            .accessibilityElement(children: .ignore)
            // Spoken from the stored numbers, never from the ticking clock: a
            // label that changes every second can make VoiceOver re-announce
            // the element while a user is still on it.
            .accessibilityLabel(SubAgentProgress.statsAccessibilityLabel(for: card))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    /// Light mode: a 12% wash reads as a chip on white. Dark mode needs more of
    /// the same color or the chip dissolves into the black background.
    private static func badgeFillOpacity(_ scheme: ColorScheme) -> Double {
        scheme == .dark ? 0.20 : 0.12
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

    @ViewBuilder private func promptSection(_ card: SubAgentCard) -> some View {
        if let prompt = card.prompt, !prompt.isEmpty {
            let foldable = prompt.count > Self.promptFoldThreshold
            VStack(alignment: .leading, spacing: 6) {
                Text(prompt)
                    .font(.system(size: 17))
                    .lineSpacing(CodePageTheme.userBubbleLineSpacing)
                    .foregroundStyle(CodePageTheme.userBubbleText.resolved(for: colorScheme))
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
            .padding(.horizontal, CodePageTheme.userBubbleHorizontalPadding)
            .padding(.vertical, CodePageTheme.userBubbleVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CodePageTheme.userBubbleFill.resolved(for: colorScheme),
                        in: RoundedRectangle(cornerRadius: CodePageTheme.userBubbleCornerRadius,
                                             style: .continuous))
        }
    }

    /// The card's activity as one chronological list (pp 2026-10-05): tool
    /// calls, reasoning and the subagent's text rows interleaved in the order
    /// the connector published them. pp 2026-10-30: the list renders through
    /// the current Chat page's grouping — `TimelineChatGrouping` step groups
    /// for reasoning/tool runs, chat message rows for body text — instead of
    /// the Code page components. Which rows qualify is
    /// `SubAgentProgress.activityRows` — its lineage merge means a resume-alias
    /// card shows the original dispatch card's rows — through the same
    /// `isVisibleInChat` gate the chat applies, so hidden rows and empty
    /// reasoning never enter the panel.
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
                    // pp 2026-10-30: the activity follows the current Chat
                    // page — TimelineChatGrouping units, the step-group row for
                    // thinking/tool runs, and the chat message row for body
                    // text. The step sheet is the same one the chat timeline
                    // opens. Lazy: after a few pages this list can hold
                    // hundreds of rows.
                    chatTranscript(rows, card: card)
                }
            }
        }
    }

    /// The child transcript through the chat profile's own grouping: step
    /// groups for runs of reasoning/tool rows, message rows for body text, and
    /// the old row view only for a standalone fallback. `isLiveTail` matches
    /// the chat page's rule — only the active card's trailing step group keeps
    /// the dots.
    @ViewBuilder private func chatTranscript(_ rows: [ChatTimelineRowModel],
                                             card: SubAgentCard) -> some View {
        let profile = chat.session.metadata.map { CodeRuntimeProfile(meta: $0) } ?? .generic
        let units = TimelineChatGrouping.units(items: rows.map(\.value),
                                               profile: profile,
                                               interactionTargets: [],
                                               excludesSubAgentChildren: false)
        let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let lastStepGroupID: String? = {
            guard card.phase.isActive, let last = units.last else { return nil }
            if case let .stepGroup(group, _) = last { return group.id }
            return nil
        }()
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(units) { unit in
                switch unit {
                case let .stepGroup(group, _):
                    CodeStepGroupRowView(group: group,
                                         cwd: chat.session.metadata?.cwd,
                                         isLiveTail: group.id == lastStepGroupID) {
                        stepGroupDetail = CodeStepGroupDetailRequest(
                            group: group, startsAtBottom: group.id == lastStepGroupID)
                    }
                case let .message(_, rowIDs):
                    // The chat page's body rows read through the same Chat row
                    // view the panel always used; only the grouping (and the
                    // step-group row) comes from the chat profile.
                    ForEach(rowIDs.compactMap { rowsByID[$0] }) { row in
                        SessionTimelineRow(row: row, chat: chat,
                                           onAttachment: onAttachment,
                                           cwd: chat.session.metadata?.cwd,
                                           disclosures: chat.disclosures,
                                           onFile: onFile, onSubAgent: nil)
                    }
                case let .standalone(rowID):
                    if let row = rowsByID[rowID] {
                        SessionTimelineRow(row: row, chat: chat,
                                           onAttachment: onAttachment,
                                           cwd: chat.session.metadata?.cwd,
                                           disclosures: chat.disclosures,
                                           onFile: onFile, onSubAgent: nil)
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
    }
}
