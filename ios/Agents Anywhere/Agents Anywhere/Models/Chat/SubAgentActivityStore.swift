import Foundation
import Observation

/// C3: the SubAgent panel's activity source for a main-only window.
///
/// When the session window was read with `excludeAgentChildren` it carries no
/// child rows at all, so the panel asks for one card's rows on demand
/// (`mode=children`). The results live here, never in the session's
/// `data.items`: the timeline window's paging boundaries and live/recovery
/// rules belong to the repository, and mixing panel reads into them would
/// corrupt both.
///
/// The store is session-scoped (owned by `V2SessionModel`) so its per-card
/// cache outlives the sheet and can be archived with the session's local
/// cache: a cold offline launch then opens the panel on the last rows it saw
/// instead of 「内容未加载」. Switching cards or dismissing the sheet cancels
/// the request in flight. Nothing polls — a running card's activity keeps
/// arriving through the live window rows the panel merges in.
@MainActor @Observable
final class SubAgentActivityStore {
    typealias Fetch = @MainActor (_ parentItemId: String, _ beforeOrderSeq: Int?) async throws -> V2SessionTimelinePage

    enum Phase: Equatable {
        case idle
        /// First page for the shown card is in flight.
        case loading
        /// An older page is in flight; the rows already loaded stay visible.
        case loadingOlder
        /// A read completed. Zero rows is a legitimate outcome (empty card).
        case loaded
        case failed(String)
        /// 422: the server does not implement the children read. Never retried.
        case unsupported
        case offline
    }

    private struct CardState {
        var rows: [V2TimelineItem]
        var hasMore: Bool
        var phase: Phase
        /// True only for a read completed during the current sheet
        /// presentation. A restored archive entry or a card read in an earlier
        /// presentation is refreshed when it is shown again online.
        var isFetched: Bool
    }

    private enum Retry {
        case firstPage
        case older(Int)
    }

    private(set) var cardID: String?
    private(set) var phase: Phase = .idle
    /// The fetched rows for the shown card, ascending by (orderSeq, id).
    private(set) var rows: [V2TimelineItem] = []
    /// The panel's activity rows: the window's live child rows for the shown
    /// card merged with the fetched pages. Kept as state and rebuilt only when
    /// a page arrives or the window's child rows change, so the panel body
    /// never merges (and re-sorts) the timeline window on every tick.
    private(set) var displayRows: [V2TimelineItem] = []
    private(set) var hasMore = false

    /// The lineage the panel is showing, for its window scan. Not observed: it
    /// changes only with an activation, which also changes the observed
    /// `phase`/`rows`, so the panel re-scans on the same update.
    @ObservationIgnored private(set) var lineageIDs: Set<String> = []

    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let limits: SubAgentActivityLimits
    /// Fired after a successful read lands in the cache, so the session can
    /// mark itself dirty and let the local archive pick the rows up.
    @ObservationIgnored private let onCacheChanged: () -> Void
    @ObservationIgnored private var windowChildRows: [V2TimelineItem] = []
    @ObservationIgnored private var cache: [String: CardState] = [:]
    /// Row models for fetched rows that are not in the window. Kept per id so
    /// a body re-evaluation reuses the same row (its reveal and disclosure
    /// state would otherwise reset on every tick).
    @ObservationIgnored private var models: [V2TimelineItemID: ChatTimelineRowModel] = [:]
    /// Bumped on every card switch, retry and cancel. A result carrying an old
    /// generation is dropped, so a cancelled request cannot land on the card
    /// the reader has moved to.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var requestTask: Task<Void, Never>?
    @ObservationIgnored private var retryOperation: Retry = .firstPage

    init(fetch: @escaping Fetch, limits: SubAgentActivityLimits = .default,
         onCacheChanged: @escaping () -> Void = {}) {
        self.fetch = fetch
        self.limits = limits
        self.onCacheChanged = onCacheChanged
    }

    /// Marks the start of a sheet presentation. Rows restored from the archive
    /// or read by an earlier presentation stay on screen but are stale, so
    /// showing the card again refreshes them online. A card read during this
    /// presentation is left alone: switching chips must not refetch.
    func beginPresentation() {
        for (cardID, state) in cache where state.phase == .loaded {
            cache[cardID]?.isFetched = false
        }
    }

    /// Switches the store to a card. Cached rows show immediately; a card read
    /// in this presentation restores without a request, while an archive
    /// restore or a card from an earlier presentation is refreshed over its
    /// rows. Offline the refresh fails fast and the cached rows stay.
    func activate(cardID: String, lineageIDs: Set<String>) {
        if cardID == self.cardID, requestTask != nil { return }
        if cardID == self.cardID, let cached = cache[cardID], cached.isFetched {
            apply(cached)
            return
        }
        requestTask?.cancel(); requestTask = nil
        if cardID != self.cardID { storeCurrent() }
        generation &+= 1
        let generation = self.generation
        self.cardID = cardID
        self.lineageIDs = lineageIDs
        retryOperation = .firstPage
        // The previous card's live rows belong to another lineage; the panel
        // pushes this card's on the next window change.
        windowChildRows = []
        refreshDisplayRows()
        if let cached = cache[cardID] {
            apply(cached)
            if cached.isFetched { return }
        } else {
            rows = []; hasMore = false
        }
        startFirstPage(generation: generation)
    }

    /// Pushes the shown card's live window rows (its lineage's child rows).
    /// The merge happens here — once per window change — and the panel then
    /// renders `displayRows` as it is.
    func updateWindow(childRows: [V2TimelineItem]) {
        windowChildRows = childRows
        refreshDisplayRows()
    }

    private func refreshDisplayRows() {
        displayRows = SubAgentActivityMerge.items(existing: windowChildRows, incoming: rows)
    }

    /// More rows older than `beforeOrderSeq` (the oldest row the panel shows).
    func loadOlder(beforeOrderSeq: Int) {
        guard phase == .loaded, hasMore, requestTask == nil else { return }
        let generation = self.generation
        retryOperation = .older(beforeOrderSeq)
        phase = .loadingOlder
        requestTask = Task { [weak self] in
            guard let self else { return }
            await self.loadOlderPage(before: beforeOrderSeq, generation: generation)
            if self.generation == generation { self.requestTask = nil }
        }
    }

    /// Re-runs whatever failed — the first page, or the older page — without
    /// discarding the rows already loaded by a failed pagination.
    func retry() {
        guard cardID != nil, requestTask == nil else { return }
        generation &+= 1
        let generation = self.generation
        switch retryOperation {
        case .firstPage:
            rows = []; hasMore = false; phase = .loading
            refreshDisplayRows()
            requestTask = Task { [weak self] in
                guard let self else { return }
                await self.loadFirstPage(generation: generation)
                if self.generation == generation { self.requestTask = nil }
            }
        case .older(let before):
            phase = .loadingOlder
            requestTask = Task { [weak self] in
                guard let self else { return }
                await self.loadOlderPage(before: before, generation: generation)
                if self.generation == generation { self.requestTask = nil }
            }
        }
    }

    /// Card switch and sheet dismissal both end here: the request is cancelled
    /// and its result can no longer be applied.
    func cancel() {
        requestTask?.cancel(); requestTask = nil
        generation &+= 1
    }

    /// The row model for one fetched item, reused across body evaluations. A
    /// later page that carries a newer copy of the same row updates the model
    /// in place, exactly like the timeline's own flush.
    func rowModel(for item: V2TimelineItem) -> ChatTimelineRowModel {
        if let model = models[item.id] {
            model.flush(item, animate: false, now: 0)
            return model
        }
        let model = ChatTimelineRowModel(item)
        models[item.id] = model
        return model
    }

    // MARK: Archive

    /// Seeds the cache restored from the local archive. The rows arrive already
    /// decoded by `V2LocalStore` (an actor), so nothing here parses on the main
    /// actor; only the cheap per-card row cap is applied again.
    func restore(_ entries: [String: [V2TimelineItem]]) {
        for (cardID, rows) in entries {
            let bounded = SubAgentActivityArchive.boundedRows(rows, limits: limits)
            guard !bounded.isEmpty else { continue }
            cache[cardID] = CardState(rows: bounded, hasMore: false, phase: .loaded, isFetched: false)
        }
    }

    /// The cache in its archivable form. This is a reference copy only — no
    /// JSON encoding happens on the main actor; `V2LocalStore` applies the
    /// session byte budget and serializes on its own actor. An empty
    /// dictionary lets the archive leave the field out.
    func archived() -> [String: [JSONValue]] {
        var cached: [String: [JSONValue]] = [:]
        for (cardID, state) in cache where !state.rows.isEmpty {
            cached[cardID] = state.rows.map(\.raw)
        }
        return cached
    }

    // MARK: Requests

    private func startFirstPage(generation: Int) {
        phase = .loading
        requestTask = Task { [weak self] in
            guard let self else { return }
            await self.loadFirstPage(generation: generation)
            if self.generation == generation { self.requestTask = nil }
        }
    }

    private func loadFirstPage(generation: Int) async {
        // A refresh merges over the rows already shown (an archive restore or
        // an earlier read) instead of discarding them: the page is only the
        // newest slice, the cached remainder stays readable.
        var items = rows
        var more = false
        do {
            // The lineage is normally one card; a resume alias adds its
            // sibling so the panel shows the rows attributed to either.
            for parent in lineageIDs.sorted() {
                let page = try await fetch(parent, nil)
                guard generation == self.generation, !Task.isCancelled else { return }
                items = SubAgentActivityMerge.items(existing: items, incoming: page.items)
                more = more || page.hasMore
            }
            guard generation == self.generation, !Task.isCancelled else { return }
            rows = SubAgentActivityArchive.boundedRows(items, limits: limits)
            hasMore = more
            phase = .loaded
            retryOperation = .firstPage
            refreshDisplayRows()
            storeCurrent()
            onCacheChanged()
        } catch {
            handle(error, generation: generation, retry: .firstPage)
        }
    }

    private func loadOlderPage(before: Int, generation: Int) async {
        var items = rows
        var more = false
        do {
            for parent in lineageIDs.sorted() {
                let page = try await fetch(parent, before)
                guard generation == self.generation, !Task.isCancelled else { return }
                items = SubAgentActivityMerge.items(existing: items, incoming: page.items)
                more = more || page.hasMore
            }
            guard generation == self.generation, !Task.isCancelled else { return }
            let bounded = SubAgentActivityArchive.boundedRows(items, limits: limits)
            // The per-card cap keeps the newest rows, so a page entirely older
            // than the cap adds nothing. Stop offering more instead of leaving
            // a button that can never change the list.
            let madeProgress = (bounded.first?.orderSeq ?? Int.max) < before
            rows = bounded
            hasMore = more && madeProgress
            phase = .loaded
            retryOperation = .older(before)
            refreshDisplayRows()
            storeCurrent()
            onCacheChanged()
        } catch {
            handle(error, generation: generation, retry: .older(before))
        }
    }

    private func handle(_ error: Error, generation: Int, retry: Retry) {
        guard generation == self.generation, !Task.isCancelled else { return }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        retryOperation = retry
        // 422 is the server saying the mode does not exist; another attempt
        // would ask the same question and get the same answer.
        if (error as? HTTPError)?.statusCode == 422 {
            rows = []; hasMore = false
            phase = .unsupported
            refreshDisplayRows()
            storeCurrent()
            return
        }
        let failure = V2ClientFailure(error)
        switch failure.kind {
        case .offline: phase = .offline
        case .cancelled: return
        default: phase = .failed(failure.message)
        }
    }

    private func apply(_ cached: CardState) {
        rows = cached.rows; hasMore = cached.hasMore; phase = cached.phase
        refreshDisplayRows()
    }

    /// Only a definite read is cached. A failure or an offline read stays
    /// uncached so showing the card again asks again once the page is
    /// presentable.
    private func storeCurrent() {
        guard let cardID else { return }
        switch phase {
        case .loaded, .unsupported:
            cache[cardID] = CardState(rows: rows, hasMore: hasMore, phase: phase, isFetched: true)
        default:
            break
        }
    }

}

/// The panel's activity rows: the window's own rows plus the fetched pages,
/// one copy per id (the newer revision wins), ordered like the timeline.
nonisolated enum SubAgentActivityMerge {
    static func items(existing: [V2TimelineItem], incoming: [V2TimelineItem]) -> [V2TimelineItem] {
        var byID: [V2TimelineItemID: V2TimelineItem] = [:]
        for item in existing { byID[item.id] = item }
        for item in incoming {
            if let current = byID[item.id] {
                // A live window row and a fetched page can carry the same id;
                // the projection's own rule decides which copy is newer.
                if item.supersedes(current) { byID[item.id] = item }
            } else {
                byID[item.id] = item
            }
        }
        return byID.values.sorted { ($0.orderSeq, $0.id) < ($1.orderSeq, $1.id) }
    }
}

/// Deterministic bounds for the SubAgent activity cache (C3 offline cache).
nonisolated struct SubAgentActivityLimits: Equatable {
    /// Newest child rows kept per card. Bounds one card's memory and disk
    /// footprint; the activity list pages from the newest end.
    var rowsPerCard = 200
    /// Encoded budget for every card of one session. The archive keeps up to
    /// 20 sessions, so this stays small: 4MB is enough for the recent stretch
    /// a reader needs offline, and it bounds both the in-memory copy and the
    /// per-file write cost.
    var byteBudget = 4 * 1024 * 1024

    static let `default` = SubAgentActivityLimits()
}

/// The bounded form of the activity cache, shared by the write (archive) and
/// read (restore) sides so an archive can never exceed what the panel accepts.
/// Nonisolated so `V2LocalStore` can size and bound rows on its own actor.
nonisolated enum SubAgentActivityArchive {
    /// One row's encoded size, the unit of the session byte budget.
    static func encodedSize(of item: V2TimelineItem) -> Int {
        (try? JSONEncoder().encode(item.raw))?.count ?? 0
    }

    /// One card's rows: deduped by id (newer copy wins), ordered, newest kept.
    static func boundedRows(_ rows: [V2TimelineItem], limits: SubAgentActivityLimits) -> [V2TimelineItem] {
        let sorted = SubAgentActivityMerge.items(existing: [], incoming: rows)
        return Array(sorted.suffix(max(0, limits.rowsPerCard)))
    }

    /// Bounds a whole cache. Rows first — the globally oldest row goes, but a
    /// card is never emptied this way; then whole cards, least recently used
    /// first (ties: the card whose newest row is oldest, then the card id).
    static func bounded(
        _ cards: [String: [V2TimelineItem]],
        lastUsed: [String: Int] = [:],
        limits: SubAgentActivityLimits = .default,
        sizes: [V2TimelineItemID: Int] = [:]
    ) -> [String: [V2TimelineItem]] {
        func size(_ item: V2TimelineItem) -> Int { sizes[item.id] ?? encodedSize(of: item) }

        var bounded: [String: [V2TimelineItem]] = [:]
        for (cardID, rows) in cards {
            let rows = boundedRows(rows, limits: limits)
            if !rows.isEmpty { bounded[cardID] = rows }
        }
        var total = bounded.values.reduce(0) { $0 + $1.reduce(0) { $0 + size($1) } }
        guard total > limits.byteBudget else { return bounded }

        // Oldest rows first, never a card's last row: emptying a card is the
        // card-level step's job.
        while total > limits.byteBudget {
            var victim: (cardID: String, item: V2TimelineItem)?
            for cardID in bounded.keys.sorted() {
                guard let oldest = bounded[cardID]?.first, (bounded[cardID]?.count ?? 0) > 1 else { continue }
                if let current = victim?.item,
                   (oldest.orderSeq, oldest.id) >= (current.orderSeq, current.id) { continue }
                victim = (cardID, oldest)
            }
            guard let victim else { break }
            bounded[victim.cardID]?.removeFirst()
            total -= size(victim.item)
        }
        guard total > limits.byteBudget else { return bounded }

        let order = bounded.keys.sorted { lhs, rhs in
            let left = lastUsed[lhs] ?? 0, right = lastUsed[rhs] ?? 0
            if left != right { return left < right }
            let leftNewest = bounded[lhs]?.last?.orderSeq ?? 0
            let rightNewest = bounded[rhs]?.last?.orderSeq ?? 0
            if leftNewest != rightNewest { return leftNewest < rightNewest }
            return lhs < rhs
        }
        for cardID in order where total > limits.byteBudget {
            total -= (bounded[cardID] ?? []).reduce(0) { $0 + size($1) }
            bounded.removeValue(forKey: cardID)
        }
        return bounded
    }
}
