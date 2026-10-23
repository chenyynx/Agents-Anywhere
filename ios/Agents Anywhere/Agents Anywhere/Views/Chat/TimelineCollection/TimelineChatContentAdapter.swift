import SwiftUI
import UIKit
import QuartzCore

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

    /// The Code page reports a collapsed tool row's tap here; the page owns the
    /// sheet (a cell-local `@State` would be rebuilt by every streaming
    /// reconfigure and could dismiss an open detail).
    var onCodeToolDetail: ((CodeToolDetailRequest) -> Void)?

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
    /// Runtime resolved once per refresh from the session metadata; every code
    /// group is built and rendered against this profile.
    private var codeProfile: CodeRuntimeProfile = .generic
    /// `CodeMessageBuilder` output for each message group, keyed by the group's
    /// explicit message id. Built once per refresh so `estimateKind` /
    /// `heightPolicy` do not re-run the builder for every layout pass.
    private var codeRowsByGroupID: [String: [CodeMessageRow]] = [:]
    /// The last message group of a live turn. It owns the transcript's single
    /// working status line; every other reasoning-only group is not rendered
    /// (device report 2026-10-23: two "Computing…" lines plus the tail orb).
    /// One chunked streaming publisher per in-flight assistant text row. The
    /// publisher is fed with the row's full text on every refresh and dropped
    /// as soon as the row settles (the persisted block text is complete then).
    private var codeStreamingPublishers: [String: CodeStreamingPublisher] = [:]
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
            contentRevision: heightContentRevision(for: item, width: width),
            width: width,
            dynamicType: typography.dynamicType,
            typographyRevision: typography.revision,
            layoutDirection: typography.layoutDirection)
    }

    /// The height key's content revision follows what the row **draws**, not
    /// the wire bookkeeping. `revision`/`updatedSeq` still drive `reconfigure`
    /// (the cell must re-read new text), but the server also bumps them while
    /// reordering siblings and streaming without changing the drawn content;
    /// hashing them into the height key retired measured heights for no visual
    /// reason (probe 2026-10-23). The paced streaming snapshot is part of the
    /// drawn content, so it is included here.
    private struct CachedHeightRevision {
        let signature: Int
        let width: CGFloat
        let typography: Int
        let scale: Int
        let streaming: String?
        let value: Int
    }
    private var heightRevisionCache: [String: CachedHeightRevision] = [:]

    private func heightContentRevision(for item: TimelineListItem, width: CGFloat) -> Int {
        guard case .group(let id) = item, groupsByID[id]?.explicitID != nil else {
            return contentSignature(for: item).contentRevision
        }
        // `prepare` asks for every row's key on every layout pass; hashing the
        // whole message text there would put a per-frame O(text) cost on the
        // scroll path. The signature (cached per item) and the paced snapshot
        // decide whether the drawn content moved, so a settled row is a hit.
        let signature = contentSignature(for: item).contentRevision
        let quantized = TimelineHeightKey.quantize(width)
        let typographyRevision = typography.revision
        let scale = Int(((controller?.traitCollection.displayScale ?? 2) * 100).rounded())
        let streaming = codeStreamingText(for: item)
        if let cached = heightRevisionCache[item.itemID],
           cached.signature == signature,
           cached.width == quantized,
           cached.typography == typographyRevision,
           cached.scale == scale,
           cached.streaming == streaming?.text {
            return cached.value
        }
        var hasher = TimelineStableHasher()
        hasher.combine(codeHeightDigest(rows: codeRowsByGroupID[id] ?? [], width: width))
        if let streaming {
            hasher.combine(streaming.rowID)
            hasher.combine(streaming.text)
        }
        let value = hasher.revision
        heightRevisionCache[item.itemID] = CachedHeightRevision(
            signature: signature, width: quantized, typography: typographyRevision,
            scale: scale, streaming: streaming?.text, value: value)
        return value
    }

    func estimateKind(for item: TimelineListItem) -> TimelineHeightEstimateKind {
        switch item {
        case .olderPrompt: return .olderPrompt
        case .latestPrompt: return .latestPrompt
        case .workingStatus: return .fixed(CodeWorkingStatusRow.estimatedHeight)
        case .tail: return .tail(statusLine: tailStatusLineVisible)
        case .notice: return .row
        case .pending(let id):
            guard let pending = pendingByID[id] else { return .row }
            return .text(textEstimate(for: item,
                rows: [TimelineHeightEstimate.TextRow(text: pending.content,
                                                     attachmentCount: pending.attachments.count)],
                minimum: 60))
        case .group(let id):
            guard let group = groupsByID[id] else { return .row }
            // A Code message group has no folds: its estimate is the message's
            // body text plus one line per collapsed tool row (W7 §3.6 / §6).
            if group.explicitID != nil {
                return codeEstimateKind(for: item, groupID: id)
            }
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

    /// The Code message group's estimate. It is only used while the group is
    /// still streaming: a settled group is measured exactly before apply
    /// (`measuredCodeGroupHeight`), so the row never corrects itself under the
    /// reader's finger.
    ///
    /// The arithmetic is `CodeRowHeightPlan`: the same paddings, scaled line
    /// box and row spacing the row view uses. `CodeMessageHeightMeasurer`
    /// answers with an already-measured component when one is cached and with
    /// the plain-text placeholder otherwise; it never hosts a view here, so
    /// the layout's prepare pass stays cheap. The old plain-text model took
    /// the unscaled 24 pt line box and wrapped long Bash commands, so every
    /// tool-only row arrived 2 pt too tall and long commands reserved hundreds
    /// of points the first fit had to give back (device report 2026-10-23).
    private func codeEstimateKind(for item: TimelineListItem,
                                  groupID: String) -> TimelineHeightEstimateKind {
        let width = TimelineHeightKey.quantize(lastWidth > 0 ? lastWidth : 361)
        let scale = Int(((controller?.traitCollection.displayScale ?? 2) * 100).rounded())
        var hasher = TimelineStableHasher()
        hasher.combine(contentSignature(for: item).contentRevision)
        hasher.combine(width)
        hasher.combine(typography.revision)
        hasher.combine(scale)
        let cacheKey = hasher.revision
        if let cached = codeEstimateCache[cacheKey] { return .fixed(cached) }
        let height = CodeMessageHeightMeasurer.height(
            rows: codeRowsByGroupID[groupID] ?? [],
            width: width,
            typography: typography,
            traits: controller?.traitCollection,
            measured: false)
        if codeEstimateCache.count > 600 { codeEstimateCache.removeAll() }
        codeEstimateCache[cacheKey] = height
        return .fixed(height)
    }
    private var codeEstimateCache: [Int: CGFloat] = [:]

    /// Parsed Markdown for the Code row's first frame, keyed by the text digest
    /// plus the typography revision. The same blocks feed the row view
    /// (`CodeMessageRowView.preparedBlocks`) and the height measurer, so the
    /// first frame is neither blank nor a different parse than the one that
    /// was measured. Parsing is synchronous by design: the cell must have its
    /// blocks before it configures, and the measurer's controller never enters
    /// a window (so an async `.task` would not run there).
    private var preparedMarkdownCache: [String: [MarkdownBlockSnapshot]] = [:]

    private func preparedMarkdownBlocks(for text: String) -> [MarkdownBlockSnapshot]? {
        let key = "\(ChatMarkdownPrepared.key(for: text)):\(typography.revision)"
        if let cached = preparedMarkdownCache[key] { return cached }
        guard let blocks = CodeMessageHeightMeasurer.preparedBlocks(for: text) else {
            return nil
        }
        if preparedMarkdownCache.count > 128 {
            preparedMarkdownCache.removeAll(keepingCapacity: true)
        }
        preparedMarkdownCache[key] = blocks
        return blocks
    }

    /// The blocks for every assistant text block of one Code message, keyed by
    /// the text the row will draw (a live streaming snapshot wins over the
    /// persisted block text, exactly as `CodeMessageRowView.displayedText`
    /// resolves it).
    private func preparedTextBlocks(for rows: [CodeMessageRow],
                                    streaming: CodeStreamingText?)
        -> [String: [MarkdownBlockSnapshot]]? {
        var prepared: [String: [MarkdownBlockSnapshot]] = [:]
        for row in rows where row.role != .user {
            for block in row.blocks {
                guard case let .text(id, fallback) = block else { continue }
                let text = streaming?.rowID == id ? streaming?.text ?? fallback : fallback
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                let key = ChatMarkdownPrepared.key(for: text)
                if prepared[key] != nil { continue }
                if let blocks = preparedMarkdownBlocks(for: text) {
                    prepared[key] = blocks
                }
            }
        }
        return prepared.isEmpty ? nil : prepared
    }

    /// The exact height of a settled Code group, measured before the snapshot
    /// applies. The controller needs this because the Code page hosts every
    /// message itself: the TextKit document path below is never offered a Code
    /// row, so without this hook the layout starts every group on an estimate
    /// and corrects it when the cell first becomes visible.
    ///
    /// Text blocks and the user bubble are measured by hosting the real
    /// `ChatMarkdownView` / `CodeUserBubble` (`CodeMessageHeightMeasurer`), so
    /// the stored height is the height the cell draws. A live group is
    /// skipped: hosting the growing text on every 0.1 s flush would be
    /// quadratic, and its estimate is only visible while the reader is
    /// watching the streaming row.
    /// Code message rows follow the official hosted-cell contract: the cell
    /// self-measures once and reports later content changes. The Chat rows keep
    /// the legacy controller polling path for now.
    func usesCellReportedHeight(for item: TimelineListItem) -> Bool {
        if case .workingStatus = item { return true }
        guard case .group(let id) = item else { return false }
        return groupsByID[id]?.explicitID != nil
    }

    func measuredCodeGroupHeight(for item: TimelineListItem, width: CGFloat) -> CGFloat? {
        guard case .group(let id) = item,
              let group = groupsByID[id], group.explicitID != nil,
              let rows = codeRowsByGroupID[id] else { return nil }
        guard !group.rows.contains(where: { $0.isRevealing || $0.value.isStreamingText }) else {
            return nil
        }
        let digest = codeHeightDigest(rows: rows, width: width)
        if let cached = codeHeightCache[id], cached.digest == digest {
            return cached.height
        }
        let height = CodeMessageHeightMeasurer.height(
            rows: rows,
            width: width,
            typography: typography,
            traits: controller?.traitCollection,
            measured: true)
        codeHeightCache[id] = CachedCodeHeight(digest: digest, height: height)
        return height
    }

    private struct CachedCodeHeight {
        let digest: Int
        let height: CGFloat
    }
    private var codeHeightCache: [String: CachedCodeHeight] = [:]

    private func codeHeightDigest(rows: [CodeMessageRow],
                                  width: CGFloat) -> Int {
        var hasher = TimelineStableHasher()
        for row in rows {
            hasher.combine(row.role.rawValue)
            for block in row.blocks {
                switch block {
                case .reasoning:
                    hasher.combine(0)
                case let .text(_, text):
                    hasher.combine(1)
                    hasher.combine(text)
                case let .toolCalls(segments):
                    hasher.combine(2)
                    hasher.combine(segments.count)
                case .other:
                    hasher.combine(3)
                }
            }
        }
        hasher.combine(TimelineHeightKey.quantize(width))
        hasher.combine(typography.revision)
        let scale = controller?.traitCollection.displayScale ?? 2
        hasher.combine(Int((scale * 100).rounded()))
        return hasher.revision
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
            // A Code message row is measured before apply and owned by the
            // layout: every part of its height is known. Letting it self-size
            // made UIKit ask for preferred attributes on every scroll and
            // routed it through the interactive correction path.
            if group.explicitID != nil { return .measured }
            return groupHasInteractiveContent(group) ? .interactive : .measured
        case .olderPrompt, .latestPrompt, .workingStatus: return .measured
        }
    }

    /// Code message, notice and pending rows draw the official top/bottom
    /// 5 pt margins themselves, so the list must not add its historical 20 pt
    /// gap. Without the pair, a pending bubble sat 5 pt under the previous
    /// Code row and 25 pt above the next one (review 2026-10-23).
    func itemSpacing(after item: TimelineListItem) -> CGFloat {
        switch item {
        case .group(let id) where groupsByID[id]?.explicitID != nil: return 0
        case .workingStatus, .notice, .pending: return 0
        default: return TimelineListMetrics.itemSpacing
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
    /// Rows whose renderer-owned reveal is still running. The cell driver
    /// clears this through `streamingRevealDidFinish` after the final fade;
    /// the signature includes it so the completion triggers one more apply
    /// (footer install + measured static height).
    private var rendererRevealOwnership = StreamingRevealOwnership()
    /// Rows whose stream contained a block the TextKit path cannot render stay
    /// on the hosting path for the rest of the turn. Flipping engines mid-stream
    /// would be a visible jump.
    private var streamingFallbacks: Set<String> = []

    /// The TextKit path only takes a static assistant message: one row, no
    /// fold, no inline notice, no attachments, no streaming. A turn footer is
    /// allowed when its height is a constant (M3.1 action row, M4.3 file
    /// summary). Any block the parser does not render still makes the whole
    /// row return nil.
    ///
    /// W7: the Code page hosts every message itself (`CodeMessageRowView` in
    /// the hosting cell), so the controller is never offered a TextKit
    /// document. The C3/M4 gates keep exercising this path through their own
    /// independent providers (`TimelineAutoRun`, `TextKitM4*AutoRun`); the
    /// machinery below stays compiled for the mixed-row phase.
    func assistantMarkdown(for item: TimelineListItem) -> AssistantMarkdownDocument? {
        nil
    }

    /// The streaming counterpart of `assistantMarkdown`. W7 hands the live
    /// body to `CodeMessageRowView` + W6's chunked publisher instead (no
    /// character reveal, full-text snapshots), so the TextKit streaming cell
    /// is not offered either.
    func assistantStreamingDocument(for item: TimelineListItem) -> AssistantStreamingDocument? {
        nil
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
            rendererRevealOwnership.finish(row.id)
            return
        }
        let total = document.document.revealCharacterCount
        let now = ProcessInfo.processInfo.systemUptime
        var timeline = revealTimelines[row.id] ?? StreamingRevealTimeline()
        guard timeline.total != total else {
            if total > 0 { rendererRevealOwnership.begin(row.id) }
            return
        }
        timeline.retarget(total: total, at: now)
        revealTimelines[row.id] = timeline
        if total > 0 { rendererRevealOwnership.begin(row.id) }
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
        // While the renderer-owned reveal still owns the row, a notice or a
        // footer arriving mid-stream must not switch engines: the full text
        // is already published, so the hosting path would show all of the
        // remaining characters at once. Hand off after the reveal settles.
        let holdsEngine = isRevealEnabled
            && rendererRevealOwnership.isActive(row.id)
        let admitted = TimelineStreamingEligibility.admits(
            isSingleRowGroup: group.kind == .single && group.rows.count == 1,
            isAssistantMessage: isAssistantMessage,
            isStreamingText: row.value.isStreamingText,
            isRevealing: row.isRevealing,
            isRevealPending: revealPending(for: row, at: now),
            textIsEmpty: row.text.isEmpty,
            hasInlineNotice: inlineNoticesByRow[row.id] != nil,
            hasAttachments: !attachments(of: row.value).isEmpty,
            footerSupported: footerIsSupported(turnActions[group.id],
                                               groupID: group.id),
            isFallback: streamingFallbacks.contains(row.id),
            holdsEngineThroughDisqualifiers: holdsEngine)
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
                rendererRevealOwnership.finish(row.id)
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
              rendererRevealOwnership.isActive(row.id) else { return false }
        guard let timeline = revealTimelines[row.id], timeline.total > 0 else {
            rendererRevealOwnership.finish(row.id)
            return false
        }
        if timeline.shownThrough(at: now) < timeline.total {
            revealCaughtUpAt.removeValue(forKey: row.id)
            return true
        }
        // The formula caught up; keep the row until the cell driver reports
        // that the final run and fade finished. The fallback bounds a driver
        // that never reports (its cell scrolled away).
        let caught = revealCaughtUpAt[row.id] ?? now
        revealCaughtUpAt[row.id] = caught
        if now - caught > 1.5 {
            rendererRevealOwnership.finish(row.id)
            return false
        }
        return true
    }

    /// The cell finished the final fade for this item's streaming row. Drop
    /// the reveal ownership so the next apply measures and configures the
    /// static body (which is what installs the copy/timestamp footer).
    func streamingRevealDidFinish(for item: TimelineListItem) {
        guard case .group(let id) = item, let group = groupsByID[id],
              let row = group.rows.first else { return }
        guard rendererRevealOwnership.finish(row.id) else { return }
        revealCaughtUpAt.removeValue(forKey: row.id)
        prepareForUpdate()
    }

    // MARK: - Footer

    /// What the footer will contain. Presence and counts are deterministic at
    /// a given revision (`TimelineTurnReview` parses the diffs synchronously
    /// and is memoized), and the height is a constant, so no fitting pass is
    /// involved.
    private struct FooterPlan {
        let hasReview: Bool
        let hasReplies: Bool

        var height: CGFloat {
            AssistantFooterMetrics.contentHeight(
                hasReview: hasReview, hasReplies: hasReplies,
                actionRowHeight: SessionTurnActionsRow.rowHeight)
        }
    }

    private struct FooterReviewKey: Equatable {
        struct Item: Equatable {
            let id: String
            let revision: Int
            let updatedSeq: Int
        }

        let root: String?
        let items: [Item]
    }

    /// Last parsed review per group. `SessionTurnReviewFooter.ReviewMemo` does
    /// the same inside the view; the TextKit path cannot rely on that memo
    /// because it builds the view on every measurement.
    private var footerReviews: [String: (key: FooterReviewKey, review: TimelineTurnReview)] = [:]

    private func footerReview(_ action: TimelineTurnAction,
                              groupID: String) -> TimelineTurnReview {
        let root = model.session.metadata?.cwd
        let key = FooterReviewKey(
            root: root,
            items: action.changes.map {
                FooterReviewKey.Item(id: $0.id,
                                     revision: $0.value.revision,
                                     updatedSeq: $0.value.updatedSeq)
            })
        if let cached = footerReviews[groupID], cached.key == key {
            return cached.review
        }
        let windows = root?.range(of: #"^[A-Za-z]:[/\\]|^\\\\"#,
                                  options: .regularExpression) != nil
        let review = TimelineTurnReview.build(
            items: action.changes.map(\.value), root: root,
            caseInsensitive: windows)
        footerReviews[groupID] = (key, review)
        return review
    }

    /// Nil means "keep hosting": an extreme Dynamic Type size can push the
    /// summary line past its fixed 44pt row. M4.5 handles that scale.
    private func footerPlan(for action: TimelineTurnAction,
                            groupID: String) -> FooterPlan? {
        let hasReview = action.changes.isEmpty
            ? false : !footerReview(action, groupID: groupID).files.isEmpty
        let hasReplies = !action.replies.isEmpty
        guard hasReview || hasReplies else {
            return FooterPlan(hasReview: false, hasReplies: false)
        }
        if hasReview,
           UIFont.preferredFont(forTextStyle: .footnote).lineHeight
            > AssistantFooterMetrics.reviewRowHeight {
            return nil
        }
        return FooterPlan(hasReview: hasReview, hasReplies: hasReplies)
    }

    private func footerIsSupported(_ action: TimelineTurnAction?,
                                   groupID: String) -> Bool {
        guard let action else { return true }
        return footerPlan(for: action, groupID: groupID) != nil
    }

    func assistantFooter(for item: TimelineListItem) -> AssistantFooterHost? {
        guard case .group(let id) = item,
              let action = turnActions[id],
              let plan = footerPlan(for: action, groupID: id),
              plan.hasReview || plan.hasReplies else { return nil }
        let review = plan.hasReview ? footerReview(action, groupID: id) : nil
        let content = VStack(alignment: .leading,
                             spacing: AssistantFooterMetrics.groupSpacing) {
            if let review {
                SessionTurnReviewFooter(
                    action: action,
                    root: model.session.metadata?.cwd,
                    hasOlderItems: model.session.hasOlderItems,
                    onFile: onFile)
                .equatable()
            }
            if plan.hasReplies {
                SessionTurnActionsRow(copyText: action.copyText,
                                      timestampText: action.timestampText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        return AssistantFooterHost(height: plan.height, view: AnyView(content))
    }

    func measurementContent(for item: TimelineListItem) -> TimelineMeasurementContent {
        switch item {
        case .tail: return .tail
        case .notice, .pending: return .interactive
        case .group(let id):
            guard let group = groupsByID[id] else { return .markdown }
            return groupHasInteractiveContent(group) ? .interactive : .markdown
        case .olderPrompt, .latestPrompt, .workingStatus: return .plainText
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
        case .workingStatus:
            return AnyView(CodeWorkingStatusRow())
        case .group(let id):
            guard let group = groupsByID[id] else { return AnyView(EmptyView()) }
            // A message group (declared message id) renders through the Code
            // row; a single-row group is either an interaction target or a row
            // with no message key and keeps the existing renderer.
            if group.explicitID != nil {
                let streamingText = codeStreamingText(for: item)
                return AnyView(CodeMessageRowView(
                    group: group,
                    profile: codeProfile,
                    cwd: model.session.metadata?.cwd,
                    streaming: streamingText,
                    preparedBlocks: preparedTextBlocks(
                        for: codeRowsByGroupID[id] ?? [], streaming: streamingText),
                    onToolDetail: { [weak self] request in
                        self?.onCodeToolDetail?(request)
                    }))
            }
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
            // The same row margins as a Code message row: these rows report 0
            // list gap, so their own margins are the whole inter-row gap.
            return AnyView(SessionInteractionCard(item: notice, chat: model)
                .padding(.vertical, CodePageTheme.rowMarginTop))
        case .pending(let id):
            guard let pending = pendingByID[id] else { return AnyView(EmptyView()) }
            return AnyView(PendingMessageRow(pending: pending, chat: model,
                onAttachment: onAttachment,
                onDismiss: { [weak self] in self?.model.session.dismissPendingMessage(id: id) })
                .padding(.vertical, CodePageTheme.rowMarginTop))
        case .tail:
            return AnyView(TimelineCollectionTailRow(model: model,
                                                     showsStatusLine: tailStatusLineVisible))
        }
    }

    // MARK: - Code streaming (W6 publisher)

    /// The paced snapshot for the message's in-flight body, if it has one.
    ///
    /// The Code page has no per-character reveal: W6 publishes full-text
    /// snapshots on the model's 0.1 s leading-edge throttle, and the row view
    /// renders the last snapshot. A completed publisher is dropped during the
    /// refresh that notices the row settled, so the view falls back to the
    /// persisted block text (which is complete at that point).
    func codeStreamingText(for item: TimelineListItem) -> CodeStreamingText? {
        guard case .group(let id) = item, let group = groupsByID[id] else { return nil }
        for row in group.rows.reversed() where row.value.isStreamingText {
            guard let publisher = codeStreamingPublishers[row.id],
                  !publisher.publishedText.isEmpty else { continue }
            return CodeStreamingText(rowID: row.id, text: publisher.publishedText)
        }
        return nil
    }

    /// Feeds every in-flight assistant text row of a Code message group into
    /// its publisher and completes the ones that settled. Called once per
    /// refresh, which the wrapper triggers on every stream flush
    /// (`flushRevision`).
    ///
    /// The rows switch to renderer-owned reveal before feeding: the Chat
    /// page's batching (a 0.24 s reveal that withholds the last glyph) belongs
    /// to the reveal renderer, which the Code page does not use. With the row
    /// publishing its full received text, W6's 0.1 s leading-edge throttle is
    /// the single pacing layer (official streaming has no character reveal).
    /// The switch is deferred one runloop turn because `row` is observable and
    /// this refresh runs inside a SwiftUI update (same rule as the retired
    /// `streamingRow` path); the next flush then feeds the full text.
    private func updateCodeStreaming(groups: [ChatTimelineGroup]) {
        let now = CACurrentMediaTime()
        var rowsByID: [String: ChatTimelineRowModel] = [:]
        // Only message groups render through `CodeMessageRowView`; an
        // interaction-target row keeps the Chat renderer (and its reveal), so
        // it must not be switched to renderer-owned reveal.
        for group in groups where group.explicitID != nil {
            for row in group.rows where rowsByID[row.id] == nil {
                rowsByID[row.id] = row
            }
        }
        for (rowID, row) in rowsByID {
            if row.value.isStreamingText {
                if !row.rendererOwnedReveal {
                    DispatchQueue.main.async {
                        row.useRendererOwnedReveal()
                    }
                }
                var publisher = codeStreamingPublishers[rowID] ?? CodeStreamingPublisher()
                _ = publisher.receive(fullText: row.text, at: now)
                codeStreamingPublishers[rowID] = publisher
            } else if let publisher = codeStreamingPublishers[rowID] {
                // The row stopped streaming: publish the remainder once, then
                // drop the publisher. Keeping one per settled message would
                // duplicate every reply's text for the whole window.
                var completed = publisher
                _ = completed.complete(at: now)
                codeStreamingPublishers.removeValue(forKey: rowID)
            }
        }
        // A row that left the timeline (history page swap, recovery) stops
        // being fed immediately.
        codeStreamingPublishers = codeStreamingPublishers.filter { rowsByID[$0.key] != nil }
    }

    func rowIDs(in item: TimelineListItem) -> [String] {
        switch item {
        case .group(let id):
            return groupsByID[id]?.rows.map(\.id) ?? [id]
        case .notice(let id): return [id]
        case .pending(let id): return [id]
        case .workingStatus: return ["working:status"]
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

    // MARK: - Probe (probe builds only)

#if AA_TIMELINE_PROBE
    /// A one-line identity for the probe report. The item id alone is opaque
    /// on a phone screenshot; the preview and the block counts let the reader
    /// match a report line to the row they see.
    func probeDescribe(_ item: TimelineListItem) -> String {
        switch item {
        case .group(let id):
            guard let group = groupsByID[id] else { return "missing group \(id)" }
            guard group.explicitID != nil else {
                return "group kind=\(group.kind) rows=\(group.rows.count)"
            }
            let rows = codeRowsByGroupID[id] ?? []
            var textBlocks = 0
            var toolBlocks = 0
            var segments = 0
            var others = 0
            var preview = ""
            for row in rows {
                for block in row.blocks {
                    switch block {
                    case .reasoning:
                        continue
                    case let .text(_, text):
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            continue
                        }
                        textBlocks += 1
                        if preview.isEmpty {
                            preview = text.replacingOccurrences(of: "\n", with: " ")
                        }
                    case let .toolCalls(blockSegments):
                        toolBlocks += 1
                        segments += blockSegments.count
                    case .other:
                        others += 1
                    }
                }
            }
            return "code rows=\(rows.count) text=\(textBlocks) toolBlocks=\(toolBlocks) "
                + "segs=\(segments) other=\(others) preview=\"\(preview.prefix(36))\""
        case .workingStatus: return "workingStatus"
        case .pending: return "pending"
        case .notice: return "notice"
        case .tail: return "tail"
        case .olderPrompt: return "olderPrompt"
        case .latestPrompt: return "latestPrompt"
        }
    }

    /// `est` is what the layout reserves (the structural plan); `exact` is the
    /// same plan with the text blocks measured by the renderer. A visible
    /// cell's fit should match `exact` within the parity gap; a gap between
    /// the two is the cost of using the streaming text model.
    func probeBreakdown(_ item: TimelineListItem) -> String? {
        guard case .group(let id) = item,
              groupsByID[id]?.explicitID != nil else { return nil }
        let rows = codeRowsByGroupID[id] ?? []
        let width = TimelineHeightKey.quantize(lastWidth > 0 ? lastWidth : 361)
        var textBlocks = 0
        var toolBlocks = 0
        var segments = 0
        var others = 0
        for row in rows {
            for block in row.blocks {
                switch block {
                case .reasoning:
                    continue
                case let .text(_, text):
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        textBlocks += 1
                    }
                case let .toolCalls(blockSegments):
                    toolBlocks += 1
                    segments += blockSegments.count
                case .other:
                    others += 1
                }
            }
        }
        let estimate = estimateKind(for: item).height
        let exact = CodeMessageHeightMeasurer.height(
            rows: rows,
            width: width, typography: typography,
            traits: controller?.traitCollection, measured: true)
        return "est=\(probeFormat(estimate)) exact=\(probeFormat(exact)) "
            + "textBlocks=\(textBlocks) toolBlocks=\(toolBlocks) segs=\(segments) "
            + "other=\(others) rows=\(rows.count)"
    }

    private func probeFormat(_ value: CGFloat) -> String {
        String(format: "%.1f", value)
    }
#endif

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
        // W7: the timeline is the Code page. One message = one group, keyed by
        // the wire's declared message id (`nativeMessageId ?? itemId`), so a
        // late first row cannot rename an item and drop its height/scroll state.
        let profile = model.session.metadata.map { CodeRuntimeProfile(meta: $0) } ?? .generic
        let codeGroups = TimelineGrouping.codeGroups(model.timeline.rows,
                                                     profile: profile,
                                                     interactionTargets: interactionTargets)
        var codeRowsByGroupID: [String: [CodeMessageRow]] = [:]
        for group in codeGroups {
            guard let explicitID = group.explicitID else { continue }
            let rows = CodeMessageBuilder.rows(for: group.rows.map(\.value), profile: profile)
            guard !rows.isEmpty else { continue }
            codeRowsByGroupID[explicitID] = rows
        }
        // The working status is its own transcript row (the official
        // `CodeThinkingView` shape). It no longer lives inside the last
        // message, so a reasoning-only group is never kept alive by it and
        // the status line cannot re-key a message group.
        let hasWorkingStatus = model.sendingPlaceholder != nil
        var groups: [ChatTimelineGroup] = []
        groups.reserveCapacity(codeGroups.count)
        for group in codeGroups {
            guard let explicitID = group.explicitID else {
                groups.append(group)
                continue
            }
            guard let rows = codeRowsByGroupID[explicitID] else { continue }
            let hasVisibleBlock = rows.contains { row in
                row.blocks.contains { block in
                    switch block {
                    case .reasoning:
                        return false
                    case let .text(_, text):
                        // An empty text block renders nothing; it must not
                        // keep a group (or a 44 pt estimate) alive.
                        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    case .toolCalls, .other:
                        return true
                    }
                }
            }
            // `codeGroups` already drops a message whose only rows are calls
            // the runtime skips; this guard keeps a message whose only block
            // is reasoning (or no visible block) from becoming an empty item.
            guard hasVisibleBlock else { continue }
            groups.append(group)
        }
        let timelineRowIDs = Set(model.timeline.rows.map(\.id))
        let tailNotices = SessionNoticeRouting.tailNotices(notices, sessionID: model.session.id,
                                                          timelineRowIDs: timelineRowIDs)
        let pending = model.timeline.pendingMessages
        let identity = TimelineItemIdentity.build(
            hasOlderPrompt: model.session.hasOlderItems || keepsOlderPrompt,
            groupIDs: groups.map(\.id),
            hasWorkingStatus: hasWorkingStatus,
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
        self.codeProfile = profile
        self.codeRowsByGroupID = codeRowsByGroupID
        codeHeightCache = codeHeightCache.filter { codeRowsByGroupID[$0.key] != nil }
        // The cache is keyed by `TimelineListItem.itemID` ("g:<group id>");
        // `groupsByID` is keyed by the bare group id. Strip the prefix or the
        // filter clears the cache on every refresh (the O(text) rehash this
        // cache exists to avoid).
        heightRevisionCache = heightRevisionCache.filter { key, _ in
            guard key.hasPrefix("g:") else { return false }
            return groupsByID[String(key.dropFirst(2))] != nil
        }
        self.tailNoticesByID = tailNoticesByID
        self.pendingByID = pendingByID
        self.rowToItem = rowToItem
        self.inlineNoticesByRow = inlineNoticesByRow
        self.turnActions = turnActions
        // Feed the chunked publishers from the rows' full text before any
        // signature/measurement pass reads `codeStreamingText`.
        updateCodeStreaming(groups: groups)
        // Parsed documents are keyed by row id; drop rows that left the
        // timeline so a long session does not retain old replies.
        assistantDocuments = assistantDocuments.filter { rowToItem[$0.key] != nil }
        footerReviews = footerReviews.filter { turnActions[$0.key] != nil }
        let streamingNow = ProcessInfo.processInfo.systemUptime
        let presentRowIDs = Set(model.timeline.rows.map(\.id))
        rendererRevealOwnership.prune(keeping: presentRowIDs)
        for rowID in Array(rendererRevealOwnership.activeRowIDs) {
            guard let timeline = revealTimelines[rowID], timeline.total > 0 else { continue }
            if timeline.shownThrough(at: streamingNow) < timeline.total {
                revealCaughtUpAt.removeValue(forKey: rowID)
                continue
            }
            let caught = revealCaughtUpAt[rowID] ?? streamingNow
            revealCaughtUpAt[rowID] = caught
            if streamingNow - caught > 1.5 { rendererRevealOwnership.finish(rowID) }
        }
        let streamingRowIDs = Set(model.timeline.rows.compactMap { row -> String? in
            if row.value.isStreamingText || rendererRevealOwnership.isActive(row.id) {
                return row.id
            }
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
                // The owed target belongs to a page that never arrived; drop
                // it so a later unrelated update cannot consume it.
                controller?.cancelHistoryRequest()
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
        case .workingStatus:
            return .workingStatus
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
        // The Code row renders only its rows. The generic signature also
        // hashes the turn action, suppression, inline notices and attachments;
        // none of them reach `CodeMessageRowView`, and hashing the turn state
        // re-keyed every group when a turn ended (probe 2026-10-23: one apply
        // reconfigured 192 rows, dropping every measured height). Keep the
        // Code signature to what the row draws. The working status is its own
        // row now, so it is not signed here either.
        if group.explicitID != nil {
            return TimelineGroupContentSignature(
                rows: group.rows.map {
                    TimelineRowContentSignature(id: $0.id,
                                                revision: $0.value.revision,
                                                updatedSeq: $0.value.updatedSeq)
                },
                disclosureExpanded: false,
                expandedRowIDs: [],
                revealingRowIDs: [],
                inlineNotices: [],
                attachments: [],
                turnAction: nil,
                turnSuppression: TimelineTurnSuppression(
                    isRunning: false, hasNewerItems: false, hasPendingUserMessage: false))
        }
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
            if row.isRevealing || rendererRevealOwnership.isActive(row.id) {
                revealingRowIDs.append(row.id)
            }
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
            hasNewerItems: model.session.hasNewerItems,
            statusLineVisible: tailStatusLineVisible)
    }

    /// The working status is its own transcript row (`CodeWorkingStatusRow`)
    /// now, so the Code tail must not draw a second indicator.
    private var tailStatusLineVisible: Bool { false }

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
    /// False while a message row already shows the official working status
    /// line: one turn gets one mark, never two (device report 2026-10-23).
    let showsStatusLine: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

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
                if showsStatusLine, model.isRunning {
                    // The Code page's working row, not the Chat page's orb:
                    // the flipbook mark plus the rotating `.connecting` verb
                    // (CANONICAL/20-working-mark.md §1–§4).
                    CodeThinkingStatusLine()
                } else if showsStatusLine, let text = model.sendingPlaceholder {
                    HStack(spacing: CodePageTheme.toolRowButtonPadding) {
                        WorkingMarkView(body: .think, isRunning: true)
                        Text(verbatim: text)
                            .font(.system(size: CodePageTheme.runningStatusFontSize))
                            .foregroundStyle(CodePageTheme.runningStatusColor
                                .resolved(for: colorScheme))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: CodePageTheme.workingMarkSize, alignment: .leading)
                } else { Color.clear }
            }
            .frame(height: showsStatusLine ? 32 : Self.idleHeight)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: showsStatusLine)
        }
    }
}
