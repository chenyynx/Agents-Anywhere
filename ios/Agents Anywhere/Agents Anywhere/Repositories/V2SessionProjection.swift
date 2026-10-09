import Foundation

/// One row's merge result on the live path: inserted (a genuinely new arrival)
/// versus supersede-replaced (a streamed update of an existing row). Dropped
/// items — window guards, non-superseding revisions — produce no outcome.
/// Purely informational: it is only consumed by the live receive path.
struct V2TimelineMergeOutcome {
    let item: V2TimelineItem
    let wasInserted: Bool
}

/// Reduces server projections without network I/O or UI state. Live projections may
/// change A -> B -> A at the same durable sequence and must not use event-ID dedup.
struct V2SessionProjection {
    private(set) var data: V2SessionData
    private let maximumItems: Int
    /// Approximate serialized-byte budget for the window (session-open-coverage
    /// P2). A row can be tens of KB (tool output, a card's payload), so the row
    /// cap alone cannot bound memory; both gates hold simultaneously. `.max`
    /// disables the byte gate — the default keeps focused test projections
    /// unbounded, while the repository always passes the policy value.
    private let maximumBytes: Int
    /// Per-row size estimates, computed once per (revision of a) row and reused
    /// across merges and trims, so accounting never re-walks the window. Ids of
    /// rows that have left the window stay here: one long session is a few
    /// thousand small entries, which is exactly the trade the window budget
    /// wants (bounded memory for the payload, not the index).
    private var estimatedBytesByID: [V2TimelineItemID: Int] = [:]
    /// The window's approximate total, maintained from the cache above.
    private(set) var estimatedBytes = 0
    /// Whether the last window merge had to drop rows it could not fit (either
    /// gate). The automatic backfill reads this together with the caps: a byte
    /// trim can leave the window a hair under the budget, where the plain
    /// comparison alone would let the backfill fetch page after page that is
    /// immediately trimmed away.
    private(set) var lastMergeOverflowed = false
    private var eventIDs: Set<String> = []
    private var eventOrder: [String] = []
    private let now: () -> Date
    private let decoder = JSONDecoder()

    /// One card's lazily-paged detail rows (P3) are bounded per session: the
    /// rows the panel can read at once, and their approximate bytes. The
    /// repository pages to the same row bound, so a single card's load cannot
    /// outrun the sidecar.
    static let maximumDetailItems = 1000
    static let maximumDetailBytes = 8 * 1024 * 1024

    init(snapshot: V2SessionSnapshot, maximumItems: Int, maximumBytes: Int = .max, now: @escaping () -> Date = Date.init) {
        data = V2SessionData(snapshot: snapshot)
        self.maximumItems = max(1, maximumItems)
        self.maximumBytes = maximumBytes
        self.now = now
        replaceTimeline(snapshot.timeline.items, hasMore: snapshot.timeline.hasMore)
    }

    init(archive: V2SessionSnapshot, hasNewerItems: Bool, maximumItems: Int, maximumBytes: Int = .max, now: @escaping () -> Date = Date.init) {
        self.init(snapshot: archive, maximumItems: maximumItems, maximumBytes: maximumBytes, now: now)
        data.hasNewerItems = hasNewerItems
    }

    static func placeholder(_ session: V2SessionMeta, maximumItems: Int, maximumBytes: Int = .max, now: @escaping () -> Date = Date.init) -> Self {
        let empty = V2RuntimeCapabilitySnapshot(revision: 0, capabilities: [])
        return Self(snapshot: .init(session: session, state: nil, timeline: .init(items: [], nextSeq: 0, hasMore: false),
            approvals: [], notices: [], effectiveCapabilities: empty, runtimeCapabilities: empty, catalogs: [:],
            eventCursor: "seq:0", serverTime: ""), maximumItems: maximumItems, maximumBytes: maximumBytes, now: now)
    }

    /// Whether the window cannot take another page without trimming: either cap
    /// has been reached, or the last merge already had to drop rows. The
    /// automatic backfill stops here instead of fetching pages that a trim
    /// would immediately discard.
    var windowIsAtCapacity: Bool {
        data.items.count >= maximumItems || estimatedBytes >= maximumBytes || lastMergeOverflowed
    }

    /// A deliberately cheap approximation of one row's serialized wire size.
    ///
    /// The exact size needs `JSONEncoder` per row per merge — an allocation
    /// storm the budget itself must not cost. This walk sums the UTF-8 byte
    /// counts of the row's string leaves (where essentially all payload lives:
    /// message text, tool output, card payloads) plus a small fixed overhead
    /// per container/scalar, and rounds everything else (escaping, number
    /// formatting, key quoting) off. Computed once per row and cached, it is
    /// accurate to within a few percent for the 32MB guard, which is all a
    /// memory budget needs.
    static func approximateWireBytes(_ item: V2TimelineItem) -> Int {
        approximateWireBytes(item.raw)
    }

    static func approximateWireBytes(_ value: JSONValue) -> Int {
        switch value {
        case let .string(text): return text.utf8.count + 2
        case .number: return 8
        case .bool: return 5
        case .null: return 4
        case let .array(values): return 2 + values.reduce(0) { $0 + approximateWireBytes($1) + 1 }
        case let .object(fields):
            return 2 + fields.reduce(0) { $0 + $1.key.utf8.count + 4 + approximateWireBytes($1.value) }
        }
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

    mutating func applyMeta(_ session: V2SessionMeta) {
        guard session.id == data.session.id, session.updatedSeq >= data.session.updatedSeq else { return }
        let changedRuntime = session.effectiveRuntimeId != data.session.effectiveRuntimeId
        data.session = session
        if changedRuntime || session.connectorStatus != .online { markStale() }
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
            outcome = merge([try payload("item", in: event)], history: false).first
        case "timeline.snapshot":
            let items: [V2TimelineItem] = try payload("items", in: event)
            replaceTimeline(items, hasMore: false)
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
            eventOrder.append(event.eventId)
            if eventOrder.count > 2048 { eventIDs.remove(eventOrder.removeFirst()) }
        }
        return outcome
    }

    mutating func applyHistory(_ page: V2SessionTimelinePage) {
        guard page.sessionId == data.session.id else { return }
        merge(page.items, history: true)
        data.hasOlderItems = page.hasMore
        // nextSeq is the server high watermark, not proof that intervening events were read.
    }

    /// Opening starts from one page even if a previous visit loaded more. Keep
    /// the event cursor and newer-window flag; this only narrows durable history.
    @discardableResult mutating func limitToLatest(_ count: Int) -> Bool {
        let count = max(1, min(count, maximumItems))
        guard data.items.count > count else { return false }
        data.items = Array(data.items.suffix(count))
        // The narrowing re-opens the window for the new visit's backfill: an
        // overflow the previous visit recorded is no longer in force.
        lastMergeOverflowed = false
        estimatedBytes = data.items.reduce(0) { $0 + (estimatedBytesByID[$1.id] ?? Self.approximateWireBytes($1)) }
        data.hasOlderItems = true
        return true
    }

    /// Merges one SubAgent detail page (timeline `mode=children`, P3) into the
    /// detail sidecar beside the window.
    ///
    /// The sidecar is deliberately *not* the window: these rows never enter
    /// `data.items`, never move the paging cursor (`items.first`), never feed
    /// the history flags or the window's trims — the main timeline's window
    /// semantics stay exactly what they are without the feature. The merge is
    /// id-keyed and honours the same supersedes rule as every other merge, so
    /// pagination, re-opens and live updates cannot produce duplicates. Rows
    /// are kept in timeline order and bounded by the per-card caps above,
    /// evicting the oldest rows first (the newest activity is what a reader
    /// opens a card for). A page for a parent the projection did not ask for
    /// contributes nothing (defensive server-drift guard).
    mutating func applyChildren(_ page: V2SessionTimelinePage, parents: Set<String>) {
        guard page.sessionId == data.session.id, !parents.isEmpty else { return }
        var byID = Dictionary(uniqueKeysWithValues: data.subAgentChildren.map { ($0.id, $0) })
        for item in page.items where item.sessionId == data.session.id {
            guard let parent = SubAgentProgress.parentItemID(item), parents.contains(parent) else { continue }
            if let old = byID[item.id], !item.supersedes(old) { continue }
            estimatedBytesByID[item.id] = Self.approximateWireBytes(item)
            byID[item.id] = item
        }
        let sorted = byID.values.sorted { ($0.orderSeq, $0.id) < ($1.orderSeq, $1.id) }
        // Keep the newest rows under both caps (a single oversized row still
        // lands — an empty sidecar would read as "nothing to show").
        var kept: [V2TimelineItem] = []
        var bytes = 0
        for item in sorted.reversed() {
            guard kept.count < Self.maximumDetailItems else { break }
            let estimate = estimatedBytesByID[item.id] ?? Self.approximateWireBytes(item)
            if !kept.isEmpty, bytes + estimate > Self.maximumDetailBytes { break }
            kept.append(item)
            bytes += estimate
        }
        data.subAgentChildren = Array(kept.reversed())
    }

    /// Records that one parent's on-demand detail drain finished: the server
    /// reported no more rows, or the per-card cap ended the walk (red team
    /// F2). Only the repository's drain loop writes this — row arrival
    /// (`applyChildren`, a live frame) never does, so a partially delivered
    /// card keeps reading as "still owed" and the panel fetches the rest.
    mutating func markDetailDrained(parent: String) {
        data.detailLoadedParents.insert(parent)
    }

    mutating func applyLatest(_ page: V2SessionTimelinePage) {
        guard page.sessionId == data.session.id else { return }
        // A GET can finish after newer socket frames. Its high watermark bounds
        // the window it may replace, but never acknowledges the event cursor.
        let newer = data.items.filter { $0.updatedSeq > page.nextSeq }
        replaceTimeline(page.items, hasMore: page.hasMore)
        merge(newer, history: false)
    }

    private mutating func replaceTimeline(_ items: [V2TimelineItem], hasMore: Bool) {
        data.items = []
        data.hasNewerItems = false
        data.hasOlderItems = hasMore
        merge(items, history: false)
    }

    /// Applies incoming rows and reports, per item, whether it was inserted or
    /// supersede-replaced. The report is purely informational — the window
    /// guards, the supersede rule, ordering and the history semantics below are
    /// untouched. The window itself now holds two gates at once (row count and
    /// approximate bytes, P2); whichever the rows reach first stops the keep,
    /// and the dropped-side flag keeps its existing direction (history keeps
    /// the oldest rows and offers the newest forward, a live window keeps the
    /// newest and offers the oldest back).
    @discardableResult
    private mutating func merge(_ incoming: [V2TimelineItem], history: Bool) -> [V2TimelineMergeOutcome] {
        var byID = Dictionary(uniqueKeysWithValues: data.items.map { ($0.id, $0) })
        let start = data.items.first?.orderSeq ?? 0
        let end = data.items.last?.orderSeq ?? 0
        let confirmedAt = now()
        var outcomes: [V2TimelineMergeOutcome] = []
        for item in incoming where item.sessionId == data.session.id {
            // The active-card sidecar is fed before the window guards, and so
            // before the version check below: a SubAgent card that later traffic
            // pushed out of the window must still reach the capsule. Everything
            // else about the window — its size, its boundaries, its paging — is
            // untouched, and the sidecar is never written back into `items`.
            data.activeAgentCards = SubAgentProgress.absorbingActiveCards(
                item, into: data.activeAgentCards, now: confirmedAt)
            if let old = byID[item.id] {
                guard item.supersedes(old) else { continue }
                estimatedBytesByID[item.id] = Self.approximateWireBytes(item)
                outcomes.append(V2TimelineMergeOutcome(item: item, wasInserted: false))
            } else if !history, data.hasOlderItems, item.orderSeq < start {
                continue // Recovery must not reinsert older rows outside the selected window.
            } else if !history, data.hasNewerItems, item.orderSeq > end {
                continue // Preserve the history window until the caller explicitly loads latest.
            } else {
                estimatedBytesByID[item.id] = Self.approximateWireBytes(item)
                outcomes.append(V2TimelineMergeOutcome(item: item, wasInserted: true))
            }
            byID[item.id] = item
        }
        let sorted = byID.values.sorted { ($0.orderSeq, $0.id) < ($1.orderSeq, $1.id) }
        let kept = windowLimited(sorted, keeping: history ? .oldest : .newest)
        lastMergeOverflowed = kept.count < sorted.count
        estimatedBytes = kept.reduce(0) { $0 + (estimatedBytesByID[$1.id] ?? Self.approximateWireBytes($1)) }
        if history {
            data.items = kept
            data.hasNewerItems = data.hasNewerItems || kept.count < sorted.count
        } else {
            data.items = kept
            data.hasOlderItems = data.hasOlderItems || kept.count < sorted.count
        }
        return outcomes
    }

    private enum WindowEdge { case oldest, newest }

    /// The window's rows under the row-count cap and the approximate-byte cap
    /// together. The row cap picks the keep-side slice first (the existing
    /// behaviour); the byte walk then trims from the far edge of that slice,
    /// always keeping at least one row so an oversized row cannot empty the
    /// window.
    private func windowLimited(_ sorted: [V2TimelineItem], keeping edge: WindowEdge) -> [V2TimelineItem] {
        let byCount = edge == .oldest ? Array(sorted.prefix(maximumItems)) : Array(sorted.suffix(maximumItems))
        let ordered = edge == .oldest ? byCount : Array(byCount.reversed())
        var kept: [V2TimelineItem] = []
        var bytes = 0
        for item in ordered {
            let estimate = estimatedBytesByID[item.id] ?? Self.approximateWireBytes(item)
            if !kept.isEmpty, bytes + estimate > maximumBytes { break }
            kept.append(item)
            bytes += estimate
        }
        return edge == .oldest ? kept : Array(kept.reversed())
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
}
