import Foundation

/// One row's merge result on the live path: inserted (a genuinely new arrival)
/// versus supersede-replaced (a streamed update of an existing row).
///
/// `deferredNewer` marks the one drop the caller must act on: the row belongs
/// beyond the held window while the projection already knows the newest side
/// is incomplete. The row cannot be inserted without the missing span, so the
/// caller has to fetch the newest page. Other drops (older-edge guards,
/// non-superseding revisions) produce no outcome.
struct V2TimelineMergeOutcome {
    let item: V2TimelineItem
    let wasInserted: Bool
    var deferredNewer = false
}

/// The row the reader is looking at when a history page starts. History paging
/// keeps the in-memory window around this position, so a prepend cannot evict
/// the newest rows (the old `prefix` rule) and the return-to-bottom path still
/// finds the tail it left behind.
nonisolated struct V2TimelineWindowAnchor: Equatable, Sendable {
    let orderSeq: Int
    let itemID: V2TimelineItemID?
}

/// Which side of the merged window a trim actually removed. `hasOlderItems` and
/// `hasNewerItems` are page flags, not guesses: a history merge that drops the
/// far-old end must still keep `hasOlderItems` true, while a merge that drops
/// the newest tail is the only history case that sets `hasNewerItems`.
private struct V2TimelineWindowTrim {
    var droppedOlder = false
    var droppedNewer = false
}

/// Reduces server projections without network I/O or UI state. Live projections may
/// change A -> B -> A at the same durable sequence and must not use event-ID dedup.
struct V2SessionProjection {
    private(set) var data: V2SessionData
    private let maximumItems: Int
    /// Non-nil while the reader is browsing history. Live creates outside this
    /// window are deferred to the latest page and flagged as newer instead of
    /// being allowed to push the anchor out.
    private var windowAnchor: V2TimelineWindowAnchor?
    private var eventIDs: Set<String> = []
    /// Fixed-size ring of recent durable event IDs; replacing the oldest slot
    /// avoids shifting the whole window for every event once it is full.
    private var eventOrder: [String] = []
    private let now: () -> Date
    private var eventOrderNext = 0
    private static let dedupeWindow = 2048
    private let decoder = JSONDecoder()
    /// The newest row the newer-window guard refused and no applied page has
    /// covered yet. A latest page selected before this row existed must not
    /// clear `hasNewerItems` just because it arrived: the row would be lost
    /// with the cursor already past it (2026-11-01 review P1).
    private var uncoveredDeferredItem: V2TimelineItem?

    init(snapshot: V2SessionSnapshot, maximumItems: Int, now: @escaping () -> Date = Date.init) {
        data = V2SessionData(snapshot: snapshot)
        self.maximumItems = max(1, maximumItems)
        self.now = now
        replaceTimeline(snapshot.timeline.items, hasMore: snapshot.timeline.hasMore)
    }

    init(archive: V2SessionSnapshot, hasNewerItems: Bool, maximumItems: Int, now: @escaping () -> Date = Date.init) {
        self.init(snapshot: archive, maximumItems: maximumItems, now: now)
        data.hasNewerItems = hasNewerItems
    }

    static func placeholder(_ session: V2SessionMeta, maximumItems: Int, now: @escaping () -> Date = Date.init) -> Self {
        let empty = V2RuntimeCapabilitySnapshot(revision: 0, capabilities: [])
        return Self(snapshot: .init(session: session, state: nil, timeline: .init(items: [], nextSeq: 0, hasMore: false),
            approvals: [], notices: [], effectiveCapabilities: empty, runtimeCapabilities: empty, catalogs: [:],
            eventCursor: "seq:0", serverTime: ""), maximumItems: maximumItems, now: now)
    }

    var sequence: Int { Self.sequence(data.cursor) }

    static func sequence(_ cursor: String) -> Int {
        Int(cursor.dropFirst(4)) ?? 0
    }

    mutating func advanceCursor(_ cursor: String) {
        if Self.sequence(cursor) > sequence { data.cursor = cursor }
    }

    mutating func markStale() { data.liveStateIsFresh = false }

    mutating func applyLive(_ live: V2SessionLiveState) {
        guard live.state.sessionId == data.session.id,
              (live.state.runtimeId ?? live.state.runtime) == data.session.effectiveRuntimeId else { return }
        data.state = live.state
        data.capabilities = live.capabilities
        data.notices = live.notices
        data.liveStateIsFresh = data.session.connectorStatus == .online
    }

    /// Returns false when the metadata was stale or identical, so callers can
    /// skip republishing the whole projection.
    @discardableResult mutating func applyMeta(_ session: V2SessionMeta) -> Bool {
        guard session.id == data.session.id, session.updatedSeq >= data.session.updatedSeq,
              session != data.session else { return false }
        let changedRuntime = session.effectiveRuntimeId != data.session.effectiveRuntimeId
        data.session = session
        if changedRuntime || session.connectorStatus != .online { markStale() }
        return true
    }

    mutating func applyState(_ state: V2RuntimeState) {
        guard state.sessionId == data.session.id,
              (state.runtimeId ?? state.runtime) == data.session.effectiveRuntimeId else { return }
        data.state = state
    }

    /// A selection write response carries selections together with a status
    /// that is not proof of anything: connectors whose selection result has no
    /// state make the server synthesise `status: "idle"`, and writing that over
    /// a running projection is how a live turn turned into a grey send key
    /// (2026-10-05). Take only the selections; status, statusReason, error and
    /// timestamps stay on the values live facts provided. With no projection
    /// state yet there is nothing safe to graft onto, so nothing is written —
    /// the write path's follow-up recovery supplies the facts.
    mutating func applySelections(_ state: V2RuntimeState) {
        guard state.sessionId == data.session.id,
              (state.runtimeId ?? state.runtime) == data.session.effectiveRuntimeId else { return }
        guard let existing = data.state else { return }
        data.state = existing.replacing(selections: state.selections)
    }

    /// Returns the merge outcome of a timeline item frame — the live socket
    /// path consumes it for the orb's receive pulse; every other caller
    /// (recovery replay included) just discards it.
    @discardableResult
    mutating func apply(_ event: V2SessionEvent) throws -> V2TimelineMergeOutcome? {
        guard event.sessionId == data.session.id else { return nil }
        guard event.sequence >= sequence else { return nil }
        if !event.isLiveProjection, eventIDs.contains(event.eventId) { return nil }
        var outcome: V2TimelineMergeOutcome?
        switch event.type {
        case "session.meta.updated":
            applyMeta(try payload("session", in: event))
        case "runtime.state.updated":
            applyState(try payload("state", in: event))
        case "runtime.capability.updated":
            data.capabilities = try payload("capabilitySet", in: event)
        case "timeline.item_created", "timeline.item_updated":
            // A single-item frame still decodes strictly: a malformed row here
            // is a stream-level failure the recovery path is designed to
            // surface (see RecoverySelfHealTests), and it carries no collection
            // to isolate within. Only item *collections* below are lossy.
            outcome = mergeSingle(try payload("item", in: event))
        case "timeline.snapshot":
            let items: [V2TimelineItem] = try lossyItems(in: event)
            applySnapshot(items)
        case "runtime.notice.snapshot":
            data.notices = try payload("notices", in: event)
        case "runtime.notice.updated":
            let notice: V2RuntimeNotice = try payload("notice", in: event)
            guard notice.sessionId == data.session.id else { return nil }
            if let index = data.notices.firstIndex(where: { $0.id == notice.id }) {
                if notice.revision >= data.notices[index].revision { data.notices[index] = notice }
            } else {
                data.notices.append(notice)
            }
        case "runtime.catalog.updated":
            break // Catalog reads are independently cached and invalidated by the repository.
        case "session.subscribed", "session.refetch_required":
            return nil // These are recovery signals, never cursor acknowledgements.
        default:
            data.lastExtensionEvent = event
        }
        advanceCursor(event.cursor)
        if !event.isLiveProjection {
            eventIDs.insert(event.eventId)
            if eventOrder.count < Self.dedupeWindow {
                eventOrder.append(event.eventId)
            } else {
                eventIDs.remove(eventOrder[eventOrderNext])
                eventOrder[eventOrderNext] = event.eventId
                eventOrderNext = (eventOrderNext + 1) % Self.dedupeWindow
            }
        }
        return outcome
    }

    /// Applies one older page around the row the reader is looking at. The
    /// anchor is optional for callers without a viewport (tests and the legacy
    /// SwiftUI list); without one the first held row stands in for the reading
    /// position, which still preserves the newest tail instead of the old
    /// `prefix` rule.
    mutating func applyHistory(_ page: V2SessionTimelinePage, anchorOrderSeq: Int? = nil) {
        guard page.sessionId == data.session.id else { return }
        if let anchorOrderSeq {
            windowAnchor = V2TimelineWindowAnchor(
                orderSeq: anchorOrderSeq,
                itemID: data.items.first(where: { $0.orderSeq == anchorOrderSeq })?.id)
        } else if let first = data.items.first {
            windowAnchor = V2TimelineWindowAnchor(orderSeq: first.orderSeq, itemID: first.id)
        } else if let last = page.items.last {
            windowAnchor = V2TimelineWindowAnchor(orderSeq: last.orderSeq, itemID: last.id)
        } else {
            windowAnchor = nil
        }
        let trim = merge(page.items, history: true)
        data.hasOlderItems = page.hasMore || trim.droppedOlder
        data.hasNewerItems = data.hasNewerItems || trim.droppedNewer
        // nextSeq is the server high watermark, not proof that intervening events were read.
    }

    /// True while the reader is at the newest edge of the held window (no
    /// history anchor). A window that is behind the server in this state is a
    /// defect: live creates are meant to append here, not wait for the reader
    /// to page.
    var isFollowingLatest: Bool { windowAnchor == nil }

    /// Returns the viewport to the live tail. The anchor is only a reading
    /// position; once the reader is back at the newest edge, live creates must
    /// append instead of being deferred behind `hasNewerItems`.
    mutating func followLatest() {
        windowAnchor = nil
    }

    /// Opening starts from one page even if a previous visit loaded more. Keep
    /// the event cursor and newer-window flag; this only narrows durable history.
    @discardableResult mutating func limitToLatest(_ count: Int) -> Bool {
        let count = max(1, min(count, maximumItems))
        guard data.items.count > count else { return false }
        windowAnchor = nil
        data.items = Array(data.items.suffix(count))
        data.hasOlderItems = true
        return true
    }

    /// A restored window with no rows cannot be behind the server: there is no
    /// newest edge to defer live rows against. The row store keeps session
    /// metadata after evicting its rows, so the saved "newer rows exist" flag
    /// would otherwise turn every live row into a deferred one and leave the
    /// transcript empty until a latest page landed (device 2026-11-01: opening
    /// a session whose rows were evicted showed only the older prompt).
    mutating func settleEmptyWindow() {
        guard data.items.isEmpty else { return }
        data.hasNewerItems = false
        uncoveredDeferredItem = nil
    }

    /// The local store, not the server, reports whether it still holds rows
    /// older than the restored window.
    mutating func setLocalOlderAvailable(_ value: Bool) {
        data.localOlderAvailable = value
    }

    /// `hasNewerAfterApply` is for a local-first page that is known to be
    /// behind the live cursor. Replacing the window must not claim the newest
    /// side is complete until the authoritative page lands.
    /// `keepingAnchor` is for the background reconcile of a stale local-first
    /// page: it fills the newest gap while the reader may be paged into
    /// history, so the anchored window must survive (2026-10-31 08:31: the
    /// arriving reply was the only row it had to add, but the newest-edge
    /// trim would have dropped the reader's pages). A user-requested return to
    /// the latest edge keeps the default: clear the anchor and let the idle
    /// ceiling bound the window.
    mutating func applyLatest(_ page: V2SessionTimelinePage,
                              hasNewerAfterApply: Bool = false,
                              keepingAnchor: Bool = false) {
        guard page.sessionId == data.session.id else { return }
        // A GET can finish after newer socket frames. Its high watermark bounds
        // the window it may replace, but never acknowledges the event cursor.
        let newer = data.items.filter { $0.updatedSeq > page.nextSeq }
        let heldAnchor = keepingAnchor ? windowAnchor : nil
        windowAnchor = nil
        // A latest page updates the newest side. It must not drop older rows
        // the reader already loaded: the local-first page can be tiny (the
        // 06:12 device report collapsed a full history to its 5-row local
        // page, then to the 200-row network page). Merge when the page
        // overlaps the held window; a disjoint page replaces it so a gap can
        // never leave history paging anchored on an unreachable older row.
        let windowFirst = data.items.first?.orderSeq
        let windowLast = data.items.last?.orderSeq
        let pageFirst = page.items.first?.orderSeq
        let pageLast = page.items.last?.orderSeq
        let overlaps: Bool
        if let windowFirst, let windowLast, let pageFirst, let pageLast {
            overlaps = pageFirst <= windowLast && pageLast >= windowFirst
        } else {
            overlaps = false
        }
        if overlaps {
            // A latest page is server-selected, like a history page: the
            // newest-edge guards must not reject its newer rows.
            data.hasNewerItems = false
            windowAnchor = heldAnchor
            let trim = merge(page.items, history: true)
            data.hasOlderItems = data.hasOlderItems || page.hasMore || trim.droppedOlder
            // A browse window at its 10k ceiling can still drop the newest
            // tail; the prompt must stay honest about the missing side.
            data.hasNewerItems = data.hasNewerItems || trim.droppedNewer
        } else {
            replaceTimeline(page.items, hasMore: page.hasMore)
        }
        // This page now defines the window's read mode (the panel's loaded
        // gate reads it).
        data.windowExcludesAgentChildren = page.excludesAgentChildren
        data.windowDeferredActivity = page.deferredActivity == true
        // The window's own rows beyond the page are known to belong (they are
        // already in `items`); an anchored window's merge guard would reject
        // them as "newer than the page", so admit them as page rows too.
        _ = merge(newer, history: heldAnchor != nil)
        if hasNewerAfterApply { data.hasNewerItems = true }
        settleDeferredNewer(pageNextSeq: hasNewerAfterApply ? nil : page.nextSeq)
    }

    /// A `timeline.snapshot` is the server's **complete** timeline: rows absent
    /// from it are deletions, so only its rows survive. It must not, however,
    /// drop the reader's browse window: replacing the timeline cleared the
    /// window anchor and trimmed to the idle `maximumItems`, so a snapshot
    /// landing right after a send collapsed a 498-item history view to 199 and
    /// jumped the viewport (device 2026-10-31 14:43: offset 88831 → 40145).
    /// Keep the anchor across the replacement so the snapshot's own rows are
    /// trimmed with the browse budget around the reader instead.
    private mutating func applySnapshot(_ items: [V2TimelineItem]) {
        let heldAnchor = windowAnchor
        data.items = []
        data.hasNewerItems = false
        data.hasOlderItems = false
        windowAnchor = items.isEmpty ? nil : heldAnchor
        let trim = merge(items, history: true)
        data.hasOlderItems = trim.droppedOlder
        data.hasNewerItems = trim.droppedNewer
        // A snapshot is the server's complete timeline: a deferred row it does
        // not carry was deleted/reset, not missed. Do not keep retrying it.
        uncoveredDeferredItem = nil
    }

    /// Replaces one summary row with its complete payload, in place. Only a
    /// row the window already holds is touched: the returned `false` means the
    /// window moved on (paging, a newer snapshot), and inserting the row here
    /// would bypass the window's paging boundaries. The array keeps its order
    /// — the full row carries the same `orderSeq`, and re-sorting could move a
    /// row the reader is looking at. Nothing else about the window changes:
    /// paging flags, cursor and active cards stay exactly as they were.
    @discardableResult mutating func replaceDeferredItem(_ item: V2TimelineItem) -> Bool {
        guard item.sessionId == data.session.id,
              let index = data.items.firstIndex(where: { $0.id == item.id }) else { return false }
        let existing = data.items[index]
        // The fetched row must still be the current version. The summary it
        // replaces carries the same revision, and `supersedes` accepts an
        // equal pair, so this rejects only a fetch that really raced a newer
        // window — never the normal summary-to-complete replacement.
        guard item.supersedes(existing) else { return false }
        data.items[index] = item
        return true
    }

    private mutating func replaceTimeline(_ items: [V2TimelineItem], hasMore: Bool) {
        windowAnchor = nil
        data.items = []
        data.hasNewerItems = false
        data.hasOlderItems = hasMore
        let trim = merge(items, history: false)
        data.hasOlderItems = hasMore || trim.droppedOlder
    }

    /// Single-row fast path for the live socket.
    ///
    /// The batch `merge` below rebuilds an id index and re-sorts the whole
    /// window for every call. A streaming session calls it once per frame, so
    /// a 1000-row window paid O(n log n) per delta. One row costs a scan plus
    /// either an in-place replace or a binary-search insert; the window guards
    /// and the supersede rule are the same as `merge`'s.
    private mutating func mergeSingle(_ item: V2TimelineItem) -> V2TimelineMergeOutcome? {
        guard item.sessionId == data.session.id else { return nil }
        data.activeAgentCards = SubAgentProgress.absorbingActiveCards(
            item, into: data.activeAgentCards, now: now())
        if let index = data.items.firstIndex(where: { $0.id == item.id }) {
            let old = data.items[index]
            guard item.supersedes(old) || completesActiveRow(item, old) else { return nil }
            if Self.downgradesCompleteRow(item, old) { return nil }
            if item.orderSeq == old.orderSeq {
                data.items[index] = item
            } else {
                // `supersedes` does not promise a stable orderSeq; a row that
                // moved has to be relocated or the sort invariant breaks.
                data.items.remove(at: index)
                insertSorted(item)
            }
            if item.id == uncoveredDeferredItem?.id { uncoveredDeferredItem = nil }
            return V2TimelineMergeOutcome(item: item, wasInserted: false)
        }
        let start = data.items.first?.orderSeq ?? 0
        let end = data.items.last?.orderSeq ?? 0
        if !data.items.isEmpty, windowAnchor != nil {
            // While browsing history, a create outside the held window belongs
            // to the tail the latest page restores; it must not push the
            // reading anchor out. The newer flag keeps that page honest.
            if item.orderSeq < start || item.orderSeq > end {
                if item.orderSeq > end {
                    data.hasNewerItems = true
                    noteDeferred(item)
                    return V2TimelineMergeOutcome(item: item, wasInserted: false,
                                                  deferredNewer: true)
                }
                return nil
            }
        } else {
            if data.hasOlderItems, item.orderSeq < start { return nil }
            if data.hasNewerItems, item.orderSeq > end {
                noteDeferred(item)
                return V2TimelineMergeOutcome(item: item, wasInserted: false,
                                              deferredNewer: true)
            }
        }
        insertSorted(item)
        if item.id == uncoveredDeferredItem?.id { uncoveredDeferredItem = nil }
        return V2TimelineMergeOutcome(item: item, wasInserted: true)
    }

    /// Re-applies rows a previous projection had already completed in full.
    /// A snapshot/refresh replaces the whole projection, so the merge guard
    /// cannot protect those rows; the server's deferred snapshot carries
    /// summaries for them. Only a row the new window still holds and that is
    /// still summarized is replaced, and only when it still supersedes the
    /// summary.
    @discardableResult
    mutating func graftCompleteRows(_ rows: [V2TimelineItem]) -> Int {
        let complete = Dictionary(
            rows.filter { !$0.isDeferred }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        guard !complete.isEmpty else { return 0 }
        var grafted = 0
        var result = data.items
        for index in result.indices {
            let held = result[index]
            guard held.isDeferred, let row = complete[held.id],
                  row.supersedes(held) else { continue }
            result[index] = row
            grafted += 1
        }
        guard grafted > 0 else { return 0 }
        // A completed row may have moved (an intra-message repack changes
        // orderSeq); replacing in place would break the (orderSeq, id) sort
        // invariant the window's binary search relies on.
        result.sort { ($0.orderSeq, $0.id) < ($1.orderSeq, $1.id) }
        data.items = result
        return grafted
    }

    /// A window page can carry a server summary of a row this window already
    /// holds in full. The two share the same revision and `updatedSeq`, so
    /// `supersedes` cannot tell them apart; the full row is strictly more
    /// useful and must win, or the next background page would silently
    /// downgrade a row the reader had already loaded.
    private static func downgradesCompleteRow(_ item: V2TimelineItem, _ old: V2TimelineItem) -> Bool {
        item.isDeferred && !old.isDeferred
            && item.revision == old.revision
            && item.updatedSeq == old.updatedSeq
    }

    /// Remembers the newest row a newest-edge guard refused. A latest page
    /// selected before this row existed must not clear the flag (see
    /// `settleDeferredNewer`).
    private mutating func noteDeferred(_ item: V2TimelineItem) {
        // A SubAgent child row is never part of the main latest page
        // (`excludeAgentChildren`), so it could never settle the watermark
        // and would keep the fill retrying forever. The panel reads children
        // through its own endpoint.
        guard SubAgentProgress.parentItemID(item) == nil else { return }
        guard let current = uncoveredDeferredItem else {
            uncoveredDeferredItem = item
            return
        }
        if (item.updatedSeq, item.orderSeq) > (current.updatedSeq, current.orderSeq) {
            uncoveredDeferredItem = item
        }
    }

    /// A latest page only covers the deferred rows it actually carries. When
    /// the page was selected before the row existed (`nextSeq` older than the
    /// row's update) the window is still behind: keep `hasNewerItems` so the
    /// fill retries instead of losing the row behind a cursor that already
    /// moved past it. Once the page's watermark has passed the row and the
    /// row is absent, it was deleted or is outside the newest page's span;
    /// another latest read cannot produce it, so stop retrying.
    private mutating func settleDeferredNewer(pageNextSeq: Int?) {
        guard let deferred = uncoveredDeferredItem else { return }
        if data.items.contains(where: { $0.id == deferred.id }) {
            uncoveredDeferredItem = nil
            return
        }
        // A local page's watermark is a row proxy, not the server's fence; it
        // can never prove the row is gone. Only an authoritative page may.
        guard let pageNextSeq, pageNextSeq >= deferred.updatedSeq else {
            data.hasNewerItems = true
            return
        }
        uncoveredDeferredItem = nil
    }

    /// A settled row always supersedes an active one. A row's status only
    /// moves forward (pending/running → done/failed/…), so an older sequence
    /// must not keep a finished step spinning — on 2026-11-01 a thinking row
    /// stayed "running" in the cached history after its terminal update was
    /// missed, and the archive served it back on every visit.
    private func completesActiveRow(_ incoming: V2TimelineItem,
                                    _ held: V2TimelineItem) -> Bool {
        held.status.isActive && !incoming.status.isActive && incoming.status != .unknown
    }

    /// Keeps `data.items` ordered by `(orderSeq, id)` and applies the viewport
    /// window rule: anchored windows keep both sides of the reader, while a
    /// latest window keeps the newest `maximumItems`.
    private mutating func insertSorted(_ item: V2TimelineItem) {
        var low = 0
        var high = data.items.count
        while low < high {
            let mid = (low + high) / 2
            let candidate = data.items[mid]
            if (candidate.orderSeq, candidate.id) < (item.orderSeq, item.id) {
                low = mid + 1
            } else {
                high = mid
            }
        }
        data.items.insert(item, at: low)
        applyWindowTrim()
    }

    /// Applies incoming rows. Batch paging and live recovery share the window
    /// rules; history inserts are not subject to the newest-edge guards because
    /// their page has already been selected by the server.
    private mutating func merge(_ incoming: [V2TimelineItem], history: Bool) -> V2TimelineWindowTrim {
        let signpost = PerfSignpost.begin("timeline.merge")
        defer { PerfSignpost.end("timeline.merge", signpost) }
        var byID = Dictionary(uniqueKeysWithValues: data.items.map { ($0.id, $0) })
        let start = data.items.first?.orderSeq ?? 0
        let end = data.items.last?.orderSeq ?? 0
        let anchored = !data.items.isEmpty && windowAnchor != nil
        let confirmedAt = now()
        for item in incoming where item.sessionId == data.session.id {
            // The active-card sidecar is fed before the window guards, and so
            // before the version check below: a SubAgent card that later traffic
            // pushed out of the window must still reach the capsule. Everything
            // else about the window — its size, its boundaries, its paging — is
            // untouched, and the sidecar is never written back into `items`.
            data.activeAgentCards = SubAgentProgress.absorbingActiveCards(
                item, into: data.activeAgentCards, now: confirmedAt)
            if let old = byID[item.id] {
                guard item.supersedes(old) || completesActiveRow(item, old) else { continue }
                if Self.downgradesCompleteRow(item, old) { continue }
            } else if !history, anchored {
                if item.orderSeq < start || item.orderSeq > end {
                    if item.orderSeq > end { data.hasNewerItems = true }
                    continue
                }
            } else if !history, data.hasOlderItems, item.orderSeq < start {
                continue // Recovery must not reinsert older rows outside the selected window.
            } else if !history, data.hasNewerItems, item.orderSeq > end {
                continue // Preserve the history window until the caller explicitly loads latest.
            }
            byID[item.id] = item
        }
        let sorted = byID.values.sorted { ($0.orderSeq, $0.id) < ($1.orderSeq, $1.id) }
        let trim = applyWindow(to: sorted)
        if !history {
            data.hasOlderItems = data.hasOlderItems || trim.droppedOlder
            data.hasNewerItems = data.hasNewerItems || trim.droppedNewer
        }
        return trim
    }

    /// A reader browsing history must never lose the newer side. Mature
    /// transcript UIs keep the whole loaded conversation and virtualize the
    /// view; the idle/latest ceiling is not a reason to collapse the list
    /// under the reader. Keep up to `browseMaximumItems` while an anchor
    /// exists, and trim back only when the reader returns to the newest edge.
    static let browseMaximumItems = 10_000

    /// Replaces `data.items` with the bounded window and reports which side it
    /// removed. With an anchor, the window is centred on the reader; without
    /// one, the newest edge wins (the opening/latest rule).
    private mutating func applyWindow(to sorted: [V2TimelineItem]) -> V2TimelineWindowTrim {
        guard !sorted.isEmpty else {
            data.items = []
            return V2TimelineWindowTrim()
        }
        if let anchor = windowAnchor {
            let browseLimit = max(maximumItems, Self.browseMaximumItems)
            guard sorted.count > browseLimit else {
                data.items = sorted
                return V2TimelineWindowTrim()
            }
            let anchorIndex = windowAnchorIndex(in: sorted, anchor: anchor)
            let half = browseLimit / 2
            var lower = max(0, anchorIndex - half)
            var upper = min(sorted.count, lower + browseLimit)
            if upper - lower < browseLimit { lower = max(0, upper - browseLimit) }
            data.items = Array(sorted[lower..<upper])
            return V2TimelineWindowTrim(droppedOlder: lower > 0,
                                        droppedNewer: upper < sorted.count)
        }
        guard sorted.count > maximumItems else {
            data.items = sorted
            return V2TimelineWindowTrim()
        }
        data.items = Array(sorted.suffix(maximumItems))
        return V2TimelineWindowTrim(droppedOlder: true)
    }

    private mutating func applyWindowTrim() {
        let trim = applyWindow(to: data.items)
        data.hasOlderItems = data.hasOlderItems || trim.droppedOlder
        data.hasNewerItems = data.hasNewerItems || trim.droppedNewer
    }

    private func windowAnchorIndex(in items: [V2TimelineItem],
                                   anchor: V2TimelineWindowAnchor) -> Int {
        if let itemID = anchor.itemID, let index = items.firstIndex(where: { $0.id == itemID }) {
            return index
        }
        if let index = items.firstIndex(where: { $0.orderSeq >= anchor.orderSeq }) {
            return index
        }
        return max(0, items.count - 1)
    }



    private func item(_ key: String, in event: V2SessionEvent) throws -> V2TimelineItem {
        guard let raw = event.payload[key] else {
            throw HTTPError.decoding(message: String(localized: "Missing '\(key)' in \(event.type)."))
        }
        do { return try V2TimelineItem(json: raw) }
        catch let error as DecodingError {
            throw HTTPError.decoding(message: "\(event.type) · \(key): \(error.v2Description)")
        }
    }

    private func items(_ key: String, in event: V2SessionEvent) throws -> [V2TimelineItem] {
        guard let raw = event.payload[key]?.arrayValue else {
            throw HTTPError.decoding(message: String(localized: "Missing '\(key)' in \(event.type)."))
        }
        do { return try raw.map { try V2TimelineItem(json: $0) } }
        catch let error as DecodingError {
            throw HTTPError.decoding(message: "\(event.type) · \(key): \(error.v2Description)")
        }
    }

    private func payload<Value: Decodable>(_ key: String, in event: V2SessionEvent) throws -> Value {
        guard let raw = event.payload[key] else {
            throw HTTPError.decoding(message: String(localized: "Missing '\(key)' in \(event.type)."))
        }
        do { return try decoder.decode(Value.self, from: JSONEncoder().encode(raw)) }
        catch let error as DecodingError {
            throw HTTPError.decoding(message: "\(event.type) · \(key): \(error.v2Description)")
        }
    }

    /// The items of a `timeline.snapshot` frame, decoded leniently *within* the
    /// array: malformed rows are dropped, so a single bad row never fails the
    /// reset that clears and rebuilds the whole timeline. The `items` key
    /// itself stays required and must be an array — a missing key or a
    /// non-array still throws, so a broken frame cannot silently read as an
    /// empty timeline. (The thrown *type* differs from the previous
    /// `payload("items")` — a bare `DecodingError` here vs the wrapper's
    /// `HTTPError.decoding` — but both surface as the same client failure, so
    /// the behaviour the caller sees is unchanged.)
    private func lossyItems(in event: V2SessionEvent) throws -> [V2TimelineItem] {
        let raw: JSONValue = try payload("items", in: event)
        return try decoder.decode(LossyElements<V2TimelineItem>.self, from: JSONEncoder().encode(raw)).elements
    }
}
