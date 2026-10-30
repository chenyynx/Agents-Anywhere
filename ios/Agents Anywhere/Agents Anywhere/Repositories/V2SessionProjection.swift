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
    private var eventIDs: Set<String> = []
    /// Fixed-size ring of recent durable event IDs; replacing the oldest slot
    /// avoids shifting the whole window for every event once it is full.
    private var eventOrder: [String] = []
    private let now: () -> Date
    private var eventOrderNext = 0
    private static let dedupeWindow = 2048
    private let decoder = JSONDecoder()

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
        data.hasOlderItems = true
        return true
    }

    /// The local store, not the server, reports whether it still holds rows
    /// older than the restored window.
    mutating func setLocalOlderAvailable(_ value: Bool) {
        data.localOlderAvailable = value
    }

    mutating func applyLatest(_ page: V2SessionTimelinePage) {
        guard page.sessionId == data.session.id else { return }
        // A GET can finish after newer socket frames. Its high watermark bounds
        // the window it may replace, but never acknowledges the event cursor.
        let newer = data.items.filter { $0.updatedSeq > page.nextSeq }
        replaceTimeline(page.items, hasMore: page.hasMore)
        // This page now builds the window, so it also owns the window's read
        // mode (the panel's loaded gate reads it).
        data.windowExcludesAgentChildren = page.excludesAgentChildren
        merge(newer, history: false)
    }

    private mutating func replaceTimeline(_ items: [V2TimelineItem], hasMore: Bool) {
        data.items = []
        data.hasNewerItems = false
        data.hasOlderItems = hasMore
        merge(items, history: false)
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
            guard item.supersedes(old) else { return nil }
            if item.orderSeq == old.orderSeq {
                data.items[index] = item
            } else {
                // `supersedes` does not promise a stable orderSeq; a row that
                // moved has to be relocated or the sort invariant breaks.
                data.items.remove(at: index)
                insertSorted(item)
            }
            return V2TimelineMergeOutcome(item: item, wasInserted: false)
        }
        let start = data.items.first?.orderSeq ?? 0
        let end = data.items.last?.orderSeq ?? 0
        if data.hasOlderItems, item.orderSeq < start { return nil }
        if data.hasNewerItems, item.orderSeq > end { return nil }
        insertSorted(item)
        return V2TimelineMergeOutcome(item: item, wasInserted: true)
    }

    /// Keeps `data.items` ordered by `(orderSeq, id)` and applies the same
    /// newest-`maximumItems` window rule as `merge(history: false)`.
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
        if data.items.count > maximumItems {
            data.items.removeFirst(data.items.count - maximumItems)
            data.hasOlderItems = true
        }
    }

    /// Applies incoming rows and reports, per item, whether it was inserted or
    /// supersede-replaced. The report is purely informational — the window
    /// guards, the supersede rule, ordering and the history semantics below are
    /// untouched.
    @discardableResult
    private mutating func merge(_ incoming: [V2TimelineItem], history: Bool) -> [V2TimelineMergeOutcome] {
        let signpost = PerfSignpost.begin("timeline.merge")
        defer { PerfSignpost.end("timeline.merge", signpost) }
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
                outcomes.append(V2TimelineMergeOutcome(item: item, wasInserted: false))
            } else if !history, data.hasOlderItems, item.orderSeq < start {
                continue // Recovery must not reinsert older rows outside the selected window.
            } else if !history, data.hasNewerItems, item.orderSeq > end {
                continue // Preserve the history window until the caller explicitly loads latest.
            } else {
                outcomes.append(V2TimelineMergeOutcome(item: item, wasInserted: true))
            }
            byID[item.id] = item
        }
        let sorted = byID.values.sorted { ($0.orderSeq, $0.id) < ($1.orderSeq, $1.id) }
        if history {
            data.items = Array(sorted.prefix(maximumItems))
            data.hasNewerItems = data.hasNewerItems || sorted.count > maximumItems
        } else {
            data.items = Array(sorted.suffix(maximumItems))
            data.hasOlderItems = data.hasOlderItems || sorted.count > maximumItems
        }
        return outcomes
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
