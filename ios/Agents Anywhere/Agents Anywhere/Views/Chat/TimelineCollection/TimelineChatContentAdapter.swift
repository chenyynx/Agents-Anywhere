import SwiftUI
import UIKit

/// Adapts one `SessionChatModel` projection to the collection timeline.
///
/// The SwiftUI timeline's body built groups, notices, pending bubbles and the
/// tail on every evaluation and let the scroll view measure them lazily. The
/// C4 container needs the same content as a stable top-level list (`TimelineItemIdentity`)
/// plus a signature per item, because heights are measured before apply. This
/// adapter is the only place that translation happens; `SessionChatModel` and
/// the row views stay unchanged.
///
/// It is not `@Observable` on purpose: the wrapper re-evaluates on the model's
/// own observable fields (`flushRevision`, pending, notices, queue, disclosure
/// revision) and calls into the controller, which asks for `contentGeneration`.
/// Rebuilding the item list happens once per wrapper update.
@MainActor
final class TimelineChatContentAdapter: TimelineCollectionContentProviding {
    let model: SessionChatModel
    private let onAttachment: (V2AttachmentContent, UIImage?) -> Void
    private let onFile: (String) -> Void
    private let onSubAgent: (String) -> Void

    weak var controller: TimelineCollectionController?

    /// The representable marks the list stale once per SwiftUI update; reading
    /// the generation rebuilds the maps, and every later `item(at:)` /
    /// `contentSignature` call reads them without re-grouping.
    func prepareForUpdate() {
        needsRefresh = true
    }

    var contentGeneration: Int {
        if needsRefresh {
            needsRefresh = false
            refresh()
        }
        return generation
    }
    private var needsRefresh = true
    private var generation = 0
    private var itemsValue: [TimelineListItem] = []
    private var itemsByID: [String: TimelineListItem] = [:]
    private var groupsByID: [String: ChatTimelineGroup] = [:]
    private var tailNoticesByID: [String: SessionNoticeModel] = [:]
    private var pendingByID: [String: V2PendingMessage] = [:]
    private var rowToItem: [String: TimelineListItem] = [:]
    private var inlineNoticesByRow: [String: [SessionNoticeModel]] = [:]
    private var turnActions: [String: TimelineTurnAction] = [:]
    private var signaturesByItem: [TimelineListItem: TimelineContentSignature] = [:]
    private var lastEntries: [TimelineContentEntry] = []
    private var typography: TimelineTypographySnapshot
    private var isRefreshing = false
    /// Last width `heightKey` was asked for. `estimateKind` runs immediately
    /// after it in the layout's prepare loop, so this is the column the
    /// estimate must use without threading a width through the provider.
    private var lastWidth: CGFloat = 0
    private var estimateCache: [String: CGFloat] = [:]

    // C4 renders the history prompts but leaves their pull/load state to C5;
    // the controller's pull machinery is already shared, so C5 only fills
    // these flags and closures from its history state.
    private var olderPullReady = false
    private var latestPullReady = false
    private var isLoadingOlder = false
    private var isLoadingLatest = false
    private var keepsOlderPrompt = false
    var onLoadOlder: (() -> Void)?
    var onLoadLatest: (() -> Void)?

    /// Set by the bridge before `loadOlder()` starts. The next refresh that
    /// sees a new first row installs the absolute prepend target before the
    /// controller applies the snapshot, so the reader's anchor does not move.
    struct PendingHistoryRequest {
        let generation: Int
        let anchorRowID: String
        let beforeFirstRowID: String?
        let edge: TimelineHistoryLayout.Edge
        let createdAt: Date
    }
    var pendingHistoryRequest: PendingHistoryRequest?

    /// First timeline row of the first item, the value the prepend target
    /// compares against. The history prompt deliberately reports the first
    /// timeline row (not the prompt id); a prompt id would never change and
    /// the target would never install.
    var firstRowID: String? {
        itemsValue.first.flatMap { rowIDs(in: $0).first }
    }

    init(model: SessionChatModel,
         onAttachment: @escaping (V2AttachmentContent, UIImage?) -> Void,
         onFile: @escaping (String) -> Void,
         onSubAgent: @escaping (String) -> Void) {
        self.model = model
        self.onAttachment = onAttachment
        self.onFile = onFile
        self.onSubAgent = onSubAgent
        typography = Self.currentTypography()
        refresh()
        needsRefresh = false
    }

    var measurer: TimelineHostingHeightMeasurer {
        if let hostedMeasurer { return hostedMeasurer }
        let created = TimelineHostingHeightMeasurer { [weak self] itemID in
            guard let self, let item = self.item(forItemID: itemID) else { return AnyView(EmptyView()) }
            return self.rowView(for: item)
        }
        hostedMeasurer = created
        return created
    }
    private var hostedMeasurer: TimelineHostingHeightMeasurer?

    func attach(_ controller: TimelineCollectionController) {
        self.controller = controller
    }

    // MARK: - Content providing

    var itemCount: Int { itemsValue.count }

    func item(at index: Int) -> TimelineListItem { itemsValue[index] }

    func contentSignature(for item: TimelineListItem) -> TimelineContentSignature {
        signaturesByItem[item] ?? makeSignature(for: item)
    }

    func heightKey(for item: TimelineListItem, width: CGFloat) -> TimelineHeightKey {
        lastWidth = width
        return TimelineHeightKey(itemID: item.itemID,
            contentRevision: contentSignature(for: item).contentRevision,
            width: width,
            dynamicType: typography.dynamicType,
            typographyRevision: typography.revision,
            layoutDirection: typography.layoutDirection)
    }

    func estimateKind(for item: TimelineListItem) -> TimelineHeightEstimateKind {
        switch item {
        case .olderPrompt: return .olderPrompt
        case .latestPrompt: return .latestPrompt
        case .tail: return .tail(statusLine: model.sendingPlaceholder != nil)
        case .notice: return .row
        case .pending(let id):
            guard let pending = pendingByID[id] else { return .row }
            return .text(textEstimate(for: item,
                rows: [TimelineHeightEstimate.TextRow(text: pending.content,
                                                     attachmentCount: pending.attachments.count)],
                minimum: 60))
        case .group(let id):
            guard let group = groupsByID[id] else { return .row }
            // A folded group renders its header only; estimating the hidden
            // rows would park a large blank block above the fold.
            let expanded = group.kind == .single || model.disclosures.isExpanded("group:\(group.id)")
            let rows = expanded ? group.rows : []
            let cwd = model.session.metadata?.cwd
            var textRows: [TimelineHeightEstimate.TextRow] = []
            textRows.reserveCapacity(rows.count)
            for row in rows {
                // A collapsed fold renders its header, not its body. Counting
                // the hidden reasoning/tool text would park a large blank
                // block above the fold until the cell fit corrects it.
                let kind = row.entry(cwd: cwd).kind
                let folded: Bool
                switch kind {
                case .reasoning, .compact, .tool:
                    folded = !model.disclosures.isExpanded(row.id)
                case .marker:
                    folded = row.structure.type != .message
                        && !model.disclosures.isExpanded(row.id)
                case .artifact:
                    folded = false
                }
                textRows.append(TimelineHeightEstimate.TextRow(
                    text: folded ? "" : row.text,
                    attachmentCount: folded ? 0 : attachments(of: row.value).count))
            }
            return .text(textEstimate(for: item, rows: textRows, minimum: expanded ? 44 : 64))
        }
    }

    /// The estimate is recomputed only when the row content, typography or
    /// column width changes. `prepare` asks for it for every row on every
    /// layout, so the cache key uses the already-computed content signature
    /// rather than walking the row text again.
    private func textEstimate(for item: TimelineListItem,
                              rows: [TimelineHeightEstimate.TextRow],
                              minimum: CGFloat) -> CGFloat {
        let width = TimelineHeightKey.quantize(lastWidth > 0 ? lastWidth : 361)
        var hasher = TimelineStableHasher()
        hasher.combine(contentSignature(for: item).contentRevision)
        hasher.combine(minimum)
        hasher.combine(typography.revision)
        hasher.combine(width)
        let cacheKey = "\(hasher.revision)"
        if let cached = estimateCache[cacheKey] { return cached }
        let height = TimelineHeightEstimate.height(rows: rows, width: width,
            bodySize: typography.body, lineSpacing: typography.lineSpacing,
            paragraphSpacing: typography.paragraphSpacing, minimum: minimum)
        estimateCache[cacheKey] = height
        return height
    }

    func heightPolicy(for item: TimelineListItem) -> TimelineRowHeightPolicy {
        switch item {
        case .tail: return .tail
        case .notice, .pending: return .interactive
        case .group(let id):
            guard let group = groupsByID[id] else { return .measured }
            return groupHasInteractiveContent(group) ? .interactive : .measured
        case .olderPrompt, .latestPrompt: return .measured
        }
    }

    // MARK: - C5/M3 TextKit 2 assistant body

    private struct CachedAssistantDocument {
        let revision: Int
        let text: String
        let typographyRevision: Int
        let document: AssistantMarkdownDocument?
    }

    private var assistantDocuments: [String: CachedAssistantDocument] = [:]

    /// Streaming documents are rebuilt per revision but only parsed to the new
    /// tail; the cache keeps the measurement and the cell configuration in one
    /// apply from doing the work twice.
    private struct CachedStreamingDocument {
        let revision: Int
        let typographyRevision: Int
        let text: String
        let document: AssistantStreamingDocument?
    }
    private var streamingDocuments: [String: CachedStreamingDocument] = [:]
    private var streamingBuilders: [String: AssistantStreamingDocumentBuilder] = [:]
    /// Per-row reveal timelines. They live here, not in the cell, so scrolling
    /// a cell away and back does not restart the cursor.
    private var revealTimelines: [String: StreamingRevealTimeline] = [:]
    /// First moment the renderer-owned cursor caught up. Kept briefly so the
    /// cell's final run and fade can finish before the static body takes over.
    private var revealCaughtUpAt: [String: TimeInterval] = [:]
    /// Rows whose stream contained a block the TextKit path cannot render stay
    /// on the hosting path for the rest of the turn. Flipping engines mid-stream
    /// would be a visible jump.
    private var streamingFallbacks: Set<String> = []

    /// The TextKit path only takes a static assistant message: one row, no
    /// fold, no inline notice, no attachments, no streaming. A text-only turn
    /// action footer is allowed (M3.1); a footer with a file-change summary is
    /// not, because that summary's height is not deterministic. Any block the
    /// parser does not render still makes the whole row return nil.
    func assistantMarkdown(for item: TimelineListItem) -> AssistantMarkdownDocument? {
        guard case .group(let id) = item, let group = groupsByID[id],
              group.kind == .single, group.rows.count == 1,
              isTextOnlyTurnAction(turnActions[group.id]),
              let row = group.rows.first else { return nil }
        guard inlineNoticesByRow[row.id] == nil else { return nil }
        guard case .message = row.value.content, row.value.role == .assistant else { return nil }
        guard !row.value.isStreamingText, !row.isRevealing else { return nil }
        // A done row whose renderer-owned cursor is still revealing stays on
        // the streaming path; the static body would cut the animation short.
        if isRevealEnabled,
           let timeline = revealTimelines[row.id], timeline.total > 0,
           timeline.shownThrough(at: ProcessInfo.processInfo.systemUptime)
            < timeline.total {
            return nil
        }
        guard row.value.status == .done else { return nil }
        guard attachments(of: row.value).isEmpty, !row.text.isEmpty else { return nil }

        let typographyRevision = typography.revision
        if let cached = assistantDocuments[row.id],
           cached.revision == row.value.revision,
           cached.text == row.text,
           cached.typographyRevision == typographyRevision {
            return cached.document
        }
        let document = AssistantMarkdownDocumentParser.make(
            text: row.text,
            resolvesFileReferences: true,
            typography: typography)
        assistantDocuments[row.id] = CachedAssistantDocument(
            revision: row.value.revision,
            text: row.text,
            typographyRevision: typographyRevision,
            document: document)
        return document
    }

    /// The streaming counterpart of `assistantMarkdown`: the same admission
    /// rules, but the row may be pending/running and its text may still grow.
    func assistantStreamingDocument(for item: TimelineListItem) -> AssistantStreamingDocument? {
        guard let row = streamingRow(for: item) else { return nil }
        if streamingFallbacks.contains(row.id) { return nil }
        let typographyRevision = typography.revision
        if let cached = streamingDocuments[row.id],
           cached.revision == row.value.revision,
           cached.typographyRevision == typographyRevision,
           cached.text == row.text {
            return cached.document
        }
        if let cached = streamingDocuments[row.id],
           cached.typographyRevision != typographyRevision {
            // Converted blocks bake colours and fonts; a type-scale change
            // must rebuild them from the text.
            streamingBuilders[row.id]?.reset()
        }
        let builder: AssistantStreamingDocumentBuilder
        if let existing = streamingBuilders[row.id] {
            builder = existing
        } else {
            let created = AssistantStreamingDocumentBuilder()
            streamingBuilders[row.id] = created
            builder = created
        }
        let document = builder.make(text: row.text, typography: typography)
        if document == nil, builder.isRejected {
            streamingFallbacks.insert(row.id)
        }
        if let document {
            anchorRevealTimeline(for: row, document: document)
        }
        streamingDocuments[row.id] = CachedStreamingDocument(
            revision: row.value.revision,
            typographyRevision: typographyRevision,
            text: row.text,
            document: document)
        return document
    }

    func assistantStreamingReveal(for item: TimelineListItem) -> StreamingRevealState? {
        // Official gating: VoiceOver bypasses the pacing provider entirely and
        // Reduce Motion skips the mask driver; both show the text at once.
        guard isRevealEnabled else { return nil }
        guard let row = streamingRow(for: item),
              let cached = streamingDocuments[row.id],
              let document = cached.document else { return nil }
        let total = document.document.revealCharacterCount
        let now = ProcessInfo.processInfo.systemUptime
        var timeline = revealTimelines[row.id] ?? StreamingRevealTimeline()
        if timeline.total != total {
            timeline.retarget(total: total, at: now)
            revealTimelines[row.id] = timeline
        }
        return StreamingRevealState(
            timeline: timeline, total: total,
            isTextComplete: !row.value.isStreamingText)
    }

    /// Anchor the reveal cursor on the rendered character total. The official
    /// controller retargets when content changes; already-shown characters
    /// never move backwards.
    private func anchorRevealTimeline(for row: ChatTimelineRowModel,
                                      document: AssistantStreamingDocument) {
        guard isRevealEnabled else {
            revealTimelines.removeValue(forKey: row.id)
            revealCaughtUpAt.removeValue(forKey: row.id)
            return
        }
        let total = document.document.revealCharacterCount
        let now = ProcessInfo.processInfo.systemUptime
        var timeline = revealTimelines[row.id] ?? StreamingRevealTimeline()
        guard timeline.total != total else { return }
        timeline.retarget(total: total, at: now)
        revealTimelines[row.id] = timeline
        if timeline.shownThrough(at: now) >= total {
            revealCaughtUpAt[row.id] = revealCaughtUpAt[row.id] ?? now
        } else {
            revealCaughtUpAt.removeValue(forKey: row.id)
        }
    }

    /// A streaming assistant text row that the TextKit cell can own. The row
    /// stays eligible through the final reveal batch (`status == .done` with
    /// `isRevealing == true`), so committing does not flash through a fresh
    /// hosting view; once the reveal settles it hands over to `assistantMarkdown`.
    /// A row that stops streaming clears its builder; a row that gained an
    /// unsupported block keeps its fallback for the rest of the turn.
    private func streamingRow(for item: TimelineListItem) -> ChatTimelineRowModel? {
        guard case .group(let id) = item, let group = groupsByID[id],
              let row = group.rows.first else { return nil }
        let isAssistantMessage: Bool
        if case .message = row.value.content, row.value.role == .assistant {
            isAssistantMessage = true
        } else {
            isAssistantMessage = false
        }
        let now = ProcessInfo.processInfo.systemUptime
        let admitted = TimelineStreamingEligibility.admits(
            isSingleRowGroup: group.kind == .single && group.rows.count == 1,
            isAssistantMessage: isAssistantMessage,
            isStreamingText: row.value.isStreamingText,
            isRevealing: row.isRevealing,
            isRevealPending: revealPending(for: row, at: now),
            textIsEmpty: row.text.isEmpty,
            hasInlineNotice: inlineNoticesByRow[row.id] != nil,
            hasAttachments: !attachments(of: row.value).isEmpty,
            isTextOnlyAction: isTextOnlyTurnAction(turnActions[group.id]),
            isFallback: streamingFallbacks.contains(row.id))
        guard admitted else {
            // Only a row that left streaming (and finished both reveals)
            // discards its incremental state; a temporary notice/attachment
            // keeps it.
            if !row.value.isStreamingText && !row.isRevealing
                && !revealPending(for: row, at: now) {
                streamingDocuments.removeValue(forKey: row.id)
                streamingBuilders.removeValue(forKey: row.id)
                streamingFallbacks.remove(row.id)
                revealTimelines.removeValue(forKey: row.id)
                revealCaughtUpAt.removeValue(forKey: row.id)
            }
            return nil
        }
        // Once the TextKit reveal owns the row, the presentation publishes the
        // full received text and the cursor decides what is visible. The
        // adapter reads happen inside the SwiftUI update; switch on the next
        // runloop turn so the observable row is not mutated mid-update.
        if !row.rendererOwnedReveal {
            DispatchQueue.main.async {
                row.useRendererOwnedReveal()
            }
        }
        return row
    }

    /// VoiceOver and Reduce Motion both bypass the reveal (official: the
    /// pacing provider returns nil / the driver is not created).
    private var isRevealEnabled: Bool {
        !UIAccessibility.isVoiceOverRunning
            && !UIAccessibility.isReduceMotionEnabled
    }

    /// True while the renderer-owned cursor is still behind the received text,
    /// or during the short grace that lets the cell's final run fade out.
    private func revealPending(for row: ChatTimelineRowModel,
                               at now: TimeInterval) -> Bool {
        guard isRevealEnabled,
              let timeline = revealTimelines[row.id], timeline.total > 0 else {
            return false
        }
        if timeline.shownThrough(at: now) >= timeline.total {
            let caught = revealCaughtUpAt[row.id] ?? now
            revealCaughtUpAt[row.id] = caught
            return now - caught < 0.7
        }
        revealCaughtUpAt.removeValue(forKey: row.id)
        return true
    }

    /// A nil action is fine. A text-only action is the fixed copy/retry row
    /// that `AssistantTurnFooter` measures; an action with file changes also
    /// renders `SessionTurnReviewFooter`, whose height depends on its content.
    private func isTextOnlyTurnAction(_ action: TimelineTurnAction?) -> Bool {
        guard let action else { return true }
        return action.changes.isEmpty && !action.replies.isEmpty
    }

    func assistantTurnFooter(for item: TimelineListItem) -> AssistantTurnFooter? {
        guard case .group(let id) = item,
              let action = turnActions[id],
              isTextOnlyTurnAction(action) else { return nil }
        return AssistantTurnFooter(copyText: action.copyText,
                                   timestampText: action.timestampText)
    }

    func measurementContent(for item: TimelineListItem) -> TimelineMeasurementContent {
        switch item {
        case .tail: return .tail
        case .notice, .pending: return .interactive
        case .group(let id):
            guard let group = groupsByID[id] else { return .markdown }
            return groupHasInteractiveContent(group) ? .interactive : .markdown
        case .olderPrompt, .latestPrompt: return .plainText
        }
    }

    func rowView(for item: TimelineListItem) -> AnyView {
        switch item {
        case .olderPrompt:
            return AnyView(TimelineCollectionOlderPromptRow(
                hasOlderItems: model.session.hasOlderItems,
                isLoading: isLoadingOlder || isLoadingLatest,
                pullReady: olderPullReady,
                onLoad: { [weak self] in self?.onLoadOlder?() }))
        case .latestPrompt:
            return AnyView(TimelineCollectionLatestPromptRow(
                hasNewerItems: model.session.hasNewerItems,
                isLoading: isLoadingLatest || isLoadingOlder,
                pullReady: latestPullReady,
                onLoad: { [weak self] in self?.onLoadLatest?() }))
        case .group(let id):
            guard let group = groupsByID[id] else { return AnyView(EmptyView()) }
            return AnyView(SessionTimelineGroupView(
                group: group,
                chat: model,
                onAttachment: onAttachment,
                onFile: onFile,
                turnAction: turnActions[group.id],
                onSubAgent: onSubAgent,
                inlineNotices: group.rows.flatMap { inlineNoticesByRow[$0.id] ?? [] }))
        case .notice(let id):
            guard let notice = tailNoticesByID[id] else { return AnyView(EmptyView()) }
            return AnyView(SessionInteractionCard(item: notice, chat: model))
        case .pending(let id):
            guard let pending = pendingByID[id] else { return AnyView(EmptyView()) }
            return AnyView(PendingMessageRow(pending: pending, chat: model,
                onAttachment: onAttachment,
                onDismiss: { [weak self] in self?.model.session.dismissPendingMessage(id: id) }))
        case .tail:
            return AnyView(TimelineCollectionTailRow(model: model))
        }
    }

    func rowIDs(in item: TimelineListItem) -> [String] {
        switch item {
        case .group(let id):
            return groupsByID[id]?.rows.map(\.id) ?? [id]
        case .notice(let id): return [id]
        case .pending(let id): return [id]
        case .tail: return ["tail"]
        case .olderPrompt:
            // `historyLayout.firstRowID` is the first *timeline row*, not the
            // prompt item (the SwiftUI path uses `timeline.rows.first?.id`).
            // A prompt id here would make C5's loadOlder guard drop the anchor.
            return model.timeline.rows.first.map { [$0.id] } ?? []
        case .latestPrompt: return []
        }
    }

    func item(containingRow rowID: String) -> TimelineListItem? {
        rowToItem[rowID]
    }

    func interactionState() -> TimelineLayoutInteractionState {
        var state = TimelineLayoutInteractionState()
        state.streamingItemIDs = streamingItemIDs()
        return state
    }

    func applyTypography(_ snapshot: TimelineTypographySnapshot) {
        guard snapshot != typography else { return }
        typography = snapshot
        // Every height key changes; a new generation makes the controller
        // re-read the cache with the new scale instead of keeping fixed frames.
        generation &+= 1
    }

    // MARK: - Refresh

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // Capture the prepend origin before any map is replaced. A history
        // page can merge the anchor's group; after the merge, the old row no
        // longer resolves to an item that still has layout attributes.
        let pendingHistoryOrigin = pendingHistoryRequest.flatMap { request in
            controller?.historyLayout(anchorRowID: request.anchorRowID, edge: request.edge)
        }
        isLoadingOlder = model.session.isLoadingHistory
        isLoadingLatest = model.session.isLoadingHistory
        let notices = model.session.notices.notices
        let visibleNotices = notices.filter { $0.isVisible && !$0.blocks(model.session.id) }
        let interactionTargets = Set(notices.filter(\.isVisible).compactMap(\.timelineTargetID))
        let groups = TimelineGrouping.groups(model.timeline.rows, interactionTargets: interactionTargets)
        let timelineRowIDs = Set(model.timeline.rows.map(\.id))
        let tailNotices = SessionNoticeRouting.tailNotices(notices, sessionID: model.session.id,
                                                          timelineRowIDs: timelineRowIDs)
        let pending = model.timeline.pendingMessages
        let identity = TimelineItemIdentity.build(
            hasOlderPrompt: model.session.hasOlderItems || keepsOlderPrompt,
            groupIDs: groups.map(\.id),
            noticeIDs: tailNotices.map(\.id),
            pendingIDs: pending.map(\.id),
            hasLatestPrompt: model.session.hasNewerItems)

        var groupsByID: [String: ChatTimelineGroup] = [:]
        for group in groups where groupsByID[group.id] == nil { groupsByID[group.id] = group }
        var tailNoticesByID: [String: SessionNoticeModel] = [:]
        for notice in tailNotices where tailNoticesByID[notice.id] == nil {
            tailNoticesByID[notice.id] = notice
        }
        var pendingByID: [String: V2PendingMessage] = [:]
        for message in pending where pendingByID[message.id] == nil {
            pendingByID[message.id] = message
        }
        var rowToItem: [String: TimelineListItem] = [:]
        for group in groups {
            let item = TimelineListItem.group(group.id)
            for row in group.rows where rowToItem[row.id] == nil {
                rowToItem[row.id] = item
            }
        }
        var inlineNoticesByRow: [String: [SessionNoticeModel]] = [:]
        for notice in visibleNotices where notice.notice.type == "interaction" {
            guard let target = notice.timelineTargetID else { continue }
            inlineNoticesByRow[target, default: []].append(notice)
        }
        let turnActions = TimelineTurnActions.build(
            groups: groups,
            suppressLatest: model.isRunning || model.session.hasNewerItems,
            hasPendingUserMessage: !model.session.hasNewerItems
                && (!model.timeline.pendingMessages.isEmpty || !model.session.pendingMessages.isEmpty))

        self.groupsByID = groupsByID
        self.tailNoticesByID = tailNoticesByID
        self.pendingByID = pendingByID
        self.rowToItem = rowToItem
        self.inlineNoticesByRow = inlineNoticesByRow
        self.turnActions = turnActions
        // Parsed documents are keyed by row id; drop rows that left the
        // timeline so a long session does not retain old replies.
        assistantDocuments = assistantDocuments.filter { rowToItem[$0.key] != nil }
        let streamingNow = ProcessInfo.processInfo.systemUptime
        let streamingRowIDs = Set(model.timeline.rows.compactMap { row -> String? in
            if row.value.isStreamingText { return row.id }
            // A done row whose cursor is still behind the received text keeps
            // its document and builder until the reveal hands back.
            if let timeline = revealTimelines[row.id], timeline.total > 0,
               timeline.shownThrough(at: streamingNow) < timeline.total {
                return row.id
            }
            return nil
        })
        streamingDocuments = streamingDocuments.filter { streamingRowIDs.contains($0.key) }
        streamingBuilders = streamingBuilders.filter { streamingRowIDs.contains($0.key) }
        streamingFallbacks.formIntersection(streamingRowIDs)
        revealTimelines = revealTimelines.filter { streamingRowIDs.contains($0.key) }
        revealCaughtUpAt = revealCaughtUpAt.filter { streamingRowIDs.contains($0.key) }

        var itemsByID: [String: TimelineListItem] = [:]
        for item in identity.items { itemsByID[item.itemID] = item }
        self.itemsByID = itemsByID

        var signatures: [TimelineListItem: TimelineContentSignature] = [:]
        var entries: [TimelineContentEntry] = []
        entries.reserveCapacity(identity.items.count)
        for item in identity.items {
            let signature = makeSignature(for: item)
            signatures[item] = signature
            entries.append(TimelineContentEntry(item: item, signature: signature))
        }
        itemsValue = identity.items
        signaturesByItem = signatures
        if estimateCache.count > 256 { estimateCache.removeAll(keepingCapacity: true) }
        let contentChanged = entries != lastEntries
        // A history page that actually prepended rows installs its absolute
        // target before `reloadFromContent` reads this generation and applies
        // the snapshot. A page that returned nothing is dropped on timeout.
        // Only a changed snapshot will produce the update that consumes the
        // owed target; firing on an unchanged refresh would leave it behind.
        if let request = pendingHistoryRequest {
            if Date.now.timeIntervalSince(request.createdAt) >= 5 {
                pendingHistoryRequest = nil
            } else if contentChanged, let first = identity.items.first,
                      rowIDs(in: first).first != request.beforeFirstRowID {
                pendingHistoryRequest = nil
                if let origin = pendingHistoryOrigin {
                    _ = controller?.beginHistoryRequest(generation: request.generation,
                        anchorRowID: request.anchorRowID, edge: request.edge,
                        newItems: identity.items, origin: origin)
                }
            }
        }
        if contentChanged {
            lastEntries = entries
            generation &+= 1
        }
#if DEBUG
        if identity.hasDuplicates {
            // Data defect: the first occurrence renders. One line, ids only.
            let duplicates = identity.duplicateGroupIDs + identity.duplicateNoticeIDs + identity.duplicatePendingIDs
            NSLog("timeline duplicates: %@", duplicates.joined(separator: ","))
        }
#endif
    }

    private func item(forItemID itemID: String) -> TimelineListItem? {
        itemsByID[itemID]
    }

    // MARK: - Signatures

    private func makeSignature(for item: TimelineListItem) -> TimelineContentSignature {
        switch item {
        case .olderPrompt:
            return .olderPrompt(pullReady: olderPullReady, isLoading: isLoadingOlder,
                                keepsPrompt: keepsOlderPrompt, hasOlderItems: model.session.hasOlderItems)
        case .latestPrompt:
            return .latestPrompt(pullReady: latestPullReady, isLoading: isLoadingLatest,
                                 hasNewerItems: model.session.hasNewerItems)
        case .notice(let id):
            guard let notice = tailNoticesByID[id] else {
                return .notice(id: id, status: .unknown, revision: 0)
            }
            return .notice(id: id, status: notice.notice.status, revision: notice.notice.revision)
        case .pending(let id):
            guard let pending = pendingByID[id] else { return .pending(id: id, attachments: []) }
            return .pending(id: id, attachments: attachmentSignatures(
                pending.attachments.map(\.content), clientID: pending.id))
        case .tail:
            return .tail(tailSignature())
        case .group(let id):
            guard let group = groupsByID[id] else { return .group(Self.emptyGroupSignature) }
            return .group(groupSignature(group))
        }
    }

    private func groupSignature(_ group: ChatTimelineGroup) -> TimelineGroupContentSignature {
        var rows: [TimelineRowContentSignature] = []
        rows.reserveCapacity(group.rows.count)
        let expanded = group.kind != .single && model.disclosures.isExpanded("group:\(group.id)")
        var expandedRowIDs: [String] = []
        var revealingRowIDs: [String] = []
        var inlineNotices: [TimelineInlineNoticeSignature] = []
        var attachmentPreviews: [TimelineAttachmentPreviewSignature] = []
        for row in group.rows {
            rows.append(TimelineRowContentSignature(id: row.id, revision: row.value.revision,
                                                   updatedSeq: row.value.updatedSeq))
            if model.disclosures.isExpanded(row.id) { expandedRowIDs.append(row.id) }
            if row.isRevealing { revealingRowIDs.append(row.id) }
            for notice in inlineNoticesByRow[row.id] ?? [] {
                inlineNotices.append(TimelineInlineNoticeSignature(id: notice.id,
                    status: notice.notice.status, revision: notice.notice.revision))
            }
            let rowAttachments = attachments(of: row.value)
            if !rowAttachments.isEmpty {
                // Match the row renderer: an optimistic echo without wire
                // attachments falls back to the local store keyed by
                // `clientMessageId`. Resolving with nil here would sign a
                // different file list than the cell draws.
                let clientID = row.value.source["clientMessageId"]?.stringValue
                attachmentPreviews.append(contentsOf:
                    attachmentSignatures(rowAttachments, clientID: clientID))
            }
        }
        let action = turnActions[group.id]
        return TimelineGroupContentSignature(
            rows: rows,
            disclosureExpanded: expanded,
            expandedRowIDs: expandedRowIDs,
            revealingRowIDs: revealingRowIDs,
            inlineNotices: inlineNotices,
            attachments: attachmentPreviews,
            turnAction: action.map {
                TimelineTurnActionSignature(
                    replyIDs: $0.replies.map(\.id),
                    changeIDs: $0.changes.map(\.id),
                    startsMidTurn: $0.startsMidTurn,
                    replyRevisions: $0.replies.map { $0.value.revision },
                    changeRevisions: $0.changes.map { $0.value.revision })
            },
            turnSuppression: TimelineTurnSuppression(
                isRunning: model.isRunning,
                hasNewerItems: model.session.hasNewerItems,
                hasPendingUserMessage: !model.session.hasNewerItems
                    && (!model.timeline.pendingMessages.isEmpty || !model.session.pendingMessages.isEmpty)))
    }

    private func tailSignature() -> TimelineTailContentSignature {
        TimelineTailContentSignature(
            queue: model.session.sendQueue.items.map {
                TimelineQueueEntrySignature(id: $0.id, state: String(describing: $0.state))
            },
            sendingPlaceholder: model.sendingPlaceholder,
            orbActivity: String(describing: model.orbActivity),
            hasNewerItems: model.session.hasNewerItems)
    }

    /// Attachments ride inside the typed content: a message carries a list, an
    /// attachment item carries one. `V2TimelineItem` itself exposes neither.
    private func attachments(of item: V2TimelineItem) -> [V2AttachmentContent] {
        switch item.content {
        case .message(let content): return content.attachments
        case .attachment(let content): return [content]
        default: return []
        }
    }

    private func attachmentSignatures(_ contents: [V2AttachmentContent],
                                      clientID: String? = nil) -> [TimelineAttachmentPreviewSignature] {
        guard !contents.isEmpty else { return [] }
        return model.session.attachmentPreviews.resolve(contents, clientID: clientID).map { attachment in
            let size = attachment.previewPixelSize ?? attachment.content.serverPixelSize
            let width = size.flatMap { $0.width.isFinite && $0.width > 0 ? Int($0.width.rounded()) : nil }
            let height = size.flatMap { $0.height.isFinite && $0.height > 0 ? Int($0.height.rounded()) : nil }
            return TimelineAttachmentPreviewSignature(id: attachment.id,
                                                       pixelWidth: width, pixelHeight: height)
        }
    }

    private func groupHasInteractiveContent(_ group: ChatTimelineGroup) -> Bool {
        if group.kind != .single { return true }
        if group.rows.contains(where: { row in !(inlineNoticesByRow[row.id] ?? []).isEmpty }) { return true }
        let cwd = model.session.metadata?.cwd
        return group.rows.contains { row in
            switch row.entry(cwd: cwd).kind {
            case .reasoning, .compact, .tool: return true
            case .marker:
                // `TimelineEntryPresentation` classifies a plain message as
                // `.marker`; only a real marker row has a fold.
                return row.structure.type != .message
            case .artifact: return false
            }
        }
    }

    private func streamingItemIDs() -> Set<String> {
        var ids: Set<String> = []
        for group in groupsByID.values {
            if group.rows.contains(where: { $0.isRevealing || $0.value.isStreamingText }) {
                ids.insert(TimelineListItem.group(group.id).itemID)
            }
        }
        if model.sendingPlaceholder != nil || !model.session.sendQueue.items.isEmpty {
            ids.insert(TimelineListItem.tail.itemID)
        }
        return ids
    }

    private static var emptyGroupSignature: TimelineGroupContentSignature {
        TimelineGroupContentSignature(
            rows: [], disclosureExpanded: false, revealingRowIDs: [],
            inlineNotices: [], attachments: [],
            turnAction: nil,
            turnSuppression: TimelineTurnSuppression(isRunning: false, hasNewerItems: false,
                                                     hasPendingUserMessage: false))
    }

    // MARK: - Typography

    /// The wrapper's environment wins; this is the pre-first-update fallback so
    /// the initial synchronous measurement uses the same scale as the cell.
    static func currentTypography() -> TimelineTypographySnapshot {
        typography(dynamicType: UITraitCollection.current.preferredContentSizeCategory.rawValue,
                   layoutDirection: UITraitCollection.current.layoutDirection == .rightToLeft ? 1 : 0,
                   boldText: UIAccessibility.isBoldTextEnabled)
    }

    static func typography(dynamicType: String, layoutDirection: Int, boldText: Bool,
                           scale: ChatTypeScale? = nil) -> TimelineTypographySnapshot {
        let scale = scale ?? ChatTypeSettings.current
        return TimelineTypographySnapshot(
            body: scale.body,
            lineSpacing: scale.lineSpacing,
            paragraphSpacing: scale.paragraphSpacing,
            headings: scale.headings,
            inlineCodeRatio: scale.inlineCodeRatio,
            codeBlockRatio: scale.codeBlockRatio,
            codeBlockLineSpacingRatio: scale.codeBlockLineSpacingRatio,
            inlineCodePin: scale.inlineCodePin,
            codeBlockPin: scale.codeBlockPin,
            inlineCodeBold: ChatColorSettings.inlineCodeBold(),
            boldText: boldText,
            dynamicType: dynamicType,
            layoutDirection: layoutDirection)
    }
}

// MARK: - History prompts (rendered, not yet loaded in C4)

private struct TimelineCollectionOlderPromptRow: View {
    let hasOlderItems: Bool
    let isLoading: Bool
    let pullReady: Bool
    let onLoad: (() -> Void)?

    var body: some View {
        Group {
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().progressViewStyle(.circular).controlSize(.small)
                    Text(String(localized: "正在加载较早的消息…"))
                }.accessibilityElement(children: .combine)
            } else if hasOlderItems {
                Button { onLoad?() } label: {
                    Text(pullReady ? String(localized: "松开加载较早的消息") : String(localized: "加载较早的消息"))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }.disabled(onLoad == nil || isLoading)
            } else {
                Text(String(localized: "已到达会话开头")).foregroundStyle(.secondary)
            }
        }
        .font(.footnote).frame(maxWidth: .infinity, minHeight: 44)
    }
}

private struct TimelineCollectionLatestPromptRow: View {
    let hasNewerItems: Bool
    let isLoading: Bool
    let pullReady: Bool
    let onLoad: (() -> Void)?

    var body: some View {
        if hasNewerItems {
            Button { onLoad?() } label: {
                Group {
                    if isLoading { ProgressView(String(localized: "正在加载更新的记录…")) }
                    else {
                        Text(pullReady ? String(localized: "松开加载更新的记录")
                             : String(localized: "继续上拉加载更新的记录"))
                    }
                }.font(.footnote).frame(maxWidth: .infinity, minHeight: 44)
            }.disabled(onLoad == nil || isLoading)
        }
    }
}

/// The tail block from the SwiftUI timeline: queued messages, the two-tier
/// status spacer and its 12↔32 animation. The 96pt/2pt visibility probes stay
/// in C5, where the controller computes scroll-edge visibility geometrically.
private struct TimelineCollectionTailRow: View {
    let model: SessionChatModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasStatusLine: Bool { model.sendingPlaceholder != nil }
    private var queueRoster: String {
        model.session.sendQueue.items.map { "\($0.id):\($0.state)" }.joined(separator: ",")
    }
    private static let idleHeight: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.session.sendQueue.items.isEmpty {
                VStack(spacing: 6) {
                    ForEach(model.session.sendQueue.items) { item in
                        QueuedMessageRow(item: item, model: model)
                            .id(item.id)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: queueRoster)
            }
            Group {
                if let text = model.sendingPlaceholder {
                    HStack(spacing: 8) {
                        ThinkingOrbView(activity: model.orbActivity, size: 30,
                                        pulse: model.session.incomingPulse)
                        OrbStatusText(text: text).font(.footnote).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                } else { Color.clear }
            }
            .frame(height: hasStatusLine ? 32 : Self.idleHeight)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: hasStatusLine)
        }
    }
}
