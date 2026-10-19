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
        TimelineHeightKey(itemID: item.itemID,
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
        case .group, .notice, .pending: return .row
        }
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
                onLoad: onLoadOlder))
        case .latestPrompt:
            return AnyView(TimelineCollectionLatestPromptRow(
                hasNewerItems: model.session.hasNewerItems,
                isLoading: isLoadingLatest || isLoadingOlder,
                pullReady: latestPullReady,
                onLoad: onLoadLatest))
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
                onDismiss: { [weak model] in model?.session.dismissPendingMessage(id: id) }))
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
        case .olderPrompt, .latestPrompt: return []
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

        let notices = model.session.notices.notices
        let visibleNotices = notices.filter { $0.isVisible && !$0.blocks(model.session.id) }
        let interactionTargets = Set(notices.filter(\.isVisible).compactMap(\.timelineTargetID))
        let groups = TimelineGrouping.groups(model.timeline.rows, interactionTargets: interactionTargets)
        let rowIDs = Set(model.timeline.rows.map(\.id))
        let tailNotices = SessionNoticeRouting.tailNotices(notices, sessionID: model.session.id,
                                                          timelineRowIDs: rowIDs)
        let pending = model.timeline.pendingMessages
        let identity = TimelineItemIdentity.build(
            hasOlderPrompt: model.session.hasOlderItems || keepsOlderPrompt,
            groupIDs: groups.map(\.id),
            noticeIDs: tailNotices.map(\.id),
            pendingIDs: pending.map(\.id),
            hasLatestPrompt: model.session.hasNewerItems)

        var groupsByID: [String: ChatTimelineGroup] = [:]
        for group in groups { groupsByID[group.id] = group }
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
        if entries != lastEntries {
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
        var inlineNotices: [TimelineInlineNoticeSignature] = []
        var attachments: [TimelineAttachmentPreviewSignature] = []
        for row in group.rows {
            rows.append(TimelineRowContentSignature(id: row.id, revision: row.value.revision,
                                                   updatedSeq: row.value.updatedSeq))
            if model.disclosures.isExpanded(row.id) { expandedRowIDs.append(row.id) }
            for notice in inlineNoticesByRow[row.id] ?? [] {
                inlineNotices.append(TimelineInlineNoticeSignature(id: notice.id,
                    status: notice.notice.status, revision: notice.notice.revision))
            }
            if !row.value.attachments.isEmpty {
                attachments.append(contentsOf: attachmentSignatures(row.value.attachments))
            }
        }
        let action = turnActions[group.id]
        return TimelineGroupContentSignature(
            rows: rows,
            disclosureExpanded: expanded,
            expandedRowIDs: expandedRowIDs,
            inlineNotices: inlineNotices,
            attachments: attachments,
            turnAction: action.map {
                TimelineTurnActionSignature(replyIDs: $0.replies.map(\.id),
                                            changeIDs: $0.changes.map(\.id),
                                            startsMidTurn: $0.startsMidTurn)
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
            case .reasoning, .compact, .tool, .marker: return true
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
            rows: [], disclosureExpanded: false, inlineNotices: [], attachments: [],
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

    static func typography(dynamicType: String, layoutDirection: Int, boldText: Bool) -> TimelineTypographySnapshot {
        let scale = ChatTypeSettings.current
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
