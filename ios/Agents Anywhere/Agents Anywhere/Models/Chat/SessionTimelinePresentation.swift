import Foundation
import Observation

/// Trailing-debounce for history-page prepends (2026-10-10 opening-flood
/// governance). The opening backfill lands its pages back to back; each
/// landing repainted the whole timeline and re-asserted the opening position,
/// which the reader saw as "opening jumps". Every stage that looks like a
/// prepend (the pending batch's first row is not the published one) extends a
/// short hold; a flush that lands inside the hold simply publishes the latest
/// pending batch — which already contains every page that arrived meanwhile,
/// because each observation carries the projection's current full window. The
/// data still lands in memory page by page; only the presentation's landing
/// count shrinks. Bounded by `maxWindow` so a continuous event stream can
/// never starve the flush.
nonisolated struct TimelinePrependCoalescer: Equatable {
    /// One hold's extension per prepend-looking stage.
    static let step: TimeInterval = 0.25
    /// The furthest a hold may extend from its first stage.
    static let maxWindow: TimeInterval = 0.9

    private(set) var until: TimeInterval = 0
    private var cap: TimeInterval = 0

    var isHolding: Bool { until > 0 }

    mutating func notePrependStage(now: TimeInterval) {
        if until <= now {
            until = now + Self.step
            cap = now + Self.maxWindow
        } else {
            until = min(until + Self.step, cap)
        }
    }

    /// The instant a pending batch may publish: the reveal batch clock or the
    /// hold, whichever is later.
    func flushEarliest(nextBatchAt: TimeInterval) -> TimeInterval {
        max(nextBatchAt, until)
    }

    func holds(at now: TimeInterval) -> Bool { until > now }

    mutating func didFlush() {
        until = 0
        cap = 0
    }
}

@MainActor @Observable
final class ChatTimelineRowModel: Identifiable {
    let id: V2TimelineItemID
    private(set) var value: V2TimelineItem
    private(set) var structure: TimelineRowStructure
    private(set) var text: String
    private(set) var isRevealing = false
    private(set) var layoutGeneration = 0
    @ObservationIgnored private var settlesAt: TimeInterval = 0
    @ObservationIgnored private var hasFlushed = false

    init(_ value: V2TimelineItem, animate: Bool = false) {
        id = value.id; self.value = value
        structure = TimelineRowStructure(value)
        text = animate ? "" : value.displayText
    }

    /// Returns true when newly displayed text starts a reveal batch.
    @discardableResult
    func flush(_ next: V2TimelineItem, animate: Bool, now: TimeInterval) -> Bool {
        if animate && hasFlushed && value == next { settle(now: now); return false }
        hasFlushed = true
        let received = next.displayText
        let appending = received.hasPrefix(text)
        // Snapshots/corrections are authoritative replacements, not token deltas.
        if !appending { layoutGeneration += 1 }
        let safeText = animate && appending && next.isStreamingText && !received.isEmpty
            ? String(received.dropLast()) : received
        let displayed = safeText.hasPrefix(text) || !appending ? safeText : received
        var started = false
        if displayed != text {
            isRevealing = animate && appending
            started = isRevealing
            if isRevealing { settlesAt = now + ReplyPresentation.revealSeconds + ReplyPresentation.drawSlack }
            text = displayed
        }
        if value != next { value = next }
        let nextStructure = TimelineRowStructure(next)
        if structure != nextStructure { structure = nextStructure }
        if !animate || now >= settlesAt { isRevealing = false }
        return started
    }

    /// The drawing clock follows the last revealed batch, not the item's
    /// running status. A tool wait or thinking pause stops redrawing; the next
    /// appended text starts a new batch.
    func settle(now: TimeInterval) {
        if now >= settlesAt { isRevealing = false }
    }
}

/// Receives full repository projections without exposing each transport frame to
/// SwiftUI. Only flush() publishes rows. Received text waits in `pending` while
/// the previous batch reveals; the next batch goes on screen when it ends.
@MainActor @Observable
final class SessionTimelinePresentation {
    private(set) var rows: [ChatTimelineRowModel] = []
    /// The SubAgent detail sidecar's rows (P3), as row models — the window's
    /// rows plus these are the union the SubAgent panel reads. Deliberately a
    /// separate array: these rows never join `rows`, so the timeline's
    /// grouping, counts, history anchors and the window-revision bookkeeping
    /// are untouched by detail loading (L2.1 keeps them out of the main chat).
    private(set) var detailRows: [ChatTimelineRowModel] = []
    private(set) var pendingMessages: [V2PendingMessage] = []
    private(set) var hasPresentedSnapshot = false
    /// Bumped whenever a presentation moves the window under the reader: it
    /// drops rows that were on screen (the opening's trim/latest-page
    /// surgery, any wholesale recovery or snapshot replacement) or prepends
    /// new rows above everything presented (the backfill's history pages —
    /// a prepend shifts the viewport's content even though every old row
    /// survives). A pure append never bumps it. The timeline view re-asserts
    /// its opening return on every bump, so a moved window can never render
    /// from its own top: without the re-assert the reader is parked away
    /// from the newest rows until a manual scroll (2026-10-08).
    private(set) var windowRevision = 0
    /// Bumped whenever the row membership changes (any bind that replaces the
    /// `rows` array). The windowed timeline's unit/height caches rebuild off
    /// this revision instead of diffing the array per body evaluation; a
    /// streaming text update never bumps it, so re-estimates stay off the
    /// per-token path.
    private(set) var membershipRevision = 0
    @ObservationIgnored private var pending: [V2TimelineItem]?
    @ObservationIgnored private var animatePending = false
    @ObservationIgnored private var initialized = false
    @ObservationIgnored private var lastConnection: V2SessionConnectionState = .inactive
    @ObservationIgnored private var wake: AsyncStream<Void>.Continuation?
    /// When the newest reveal batch ends and the buffer may publish again.
    @ObservationIgnored private(set) var nextBatchAt: TimeInterval = 0

    func presentOpening(_ items: [V2TimelineItem], pendingMessages: [V2PendingMessage]) {
        stage(items, animate: false)
        flush()
        synchronizePending(pendingMessages)
    }

    func receive(_ observation: V2SessionObservation) {
        defer { lastConnection = observation.connection }
        guard let data = observation.data else { return }
        stage(data.items, detailItems: data.subAgentChildren,
            animate: initialized && lastConnection == .connected && observation.connection == .connected)
        initialized = true
    }

    func stage(_ items: [V2TimelineItem], detailItems: [V2TimelineItem]? = nil, animate: Bool,
               now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        pending = items.filter(\.isVisibleInChat)
        // nil keeps the detail sidecar as staged by the previous call; the
        // observation path always passes the projection's current sidecar.
        if let detailItems { pendingDetail = detailItems.filter(\.isVisibleInChat) }
        // A staged batch whose first row is not the published one is a history
        // prepend (or a replacement — the coalescer only delays, never drops).
        // The backfill's page flood lands through this hold instead of one
        // viewport-shifting repaint per page.
        if let stagedFirst = pending?.first?.id, let publishedFirst = rows.first?.id, stagedFirst != publishedFirst {
            prependCoalescer.notePrependStage(now: now)
        }
        // Once a recovery snapshot is staged, preserve its snap semantics until
        // that tick even if a live event arrives immediately afterwards.
        animatePending = pendingWasStaged ? animatePending && animate : animate
        pendingWasStaged = true
        wake?.yield(())
    }
    @ObservationIgnored private var pendingWasStaged = false
    @ObservationIgnored private var pendingDetail: [V2TimelineItem]?
    /// The history-page prepend debounce (see `TimelinePrependCoalescer`).
    @ObservationIgnored private var prependCoalescer = TimelinePrependCoalescer()

    func flush(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if let pending {
            let existing = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            let presented = Set(existing.keys)
            let previousTail = rows.last?.value.orderSeq ?? Int.min
            var started = false
            let updated = pending.map { value in
                let animate = animatePending && (existing[value.id] != nil || value.orderSeq > previousTail)
                let row = existing[value.id] ?? ChatTimelineRowModel(value, animate: animate && value.isAssistantText)
                if row.flush(value, animate: animate, now: now) { started = true }
                return row
            }
            if started { nextBatchAt = now + ReplyPresentation.batchInterval }
            // A row added above everything the reader has seen is a prepend:
            // the backfill's history pages arrive this way, and prepending
            // shifts the viewport's content whether the reader is following
            // or parked. It is the same class of change as a drop — the window
            // moved under the reader — so it re-arms the same re-assert. The
            // opening's own first presentation has no rows yet, and an append
            // keeps the first id, so neither bumps.
            let prepended = !rows.isEmpty && updated.first?.id != rows.first?.id
            let dropped = !presented.isSubset(of: Set(updated.map(\.id)))
            if rows.map(\.id) != updated.map(\.id) {
                rows = updated
                membershipRevision &+= 1
            }
            // A drop of a previously presented row means the window itself
            // moved (a trim, a latest-page swap, a recovery replacement) — one
            // of the shapes that needs the viewport re-asserted.
            if prepended || dropped { windowRevision &+= 1 }
            if !hasPresentedSnapshot { hasPresentedSnapshot = true }
            self.pending = nil; pendingWasStaged = false
            prependCoalescer.didFlush()
        }
        if let pendingDetail {
            let existing = Dictionary(uniqueKeysWithValues: detailRows.map { ($0.id, $0) })
            let updated = pendingDetail.map { value in
                let row = existing[value.id] ?? ChatTimelineRowModel(value)
                row.flush(value, animate: false, now: now)
                return row
            }
            if detailRows.map(\.id) != updated.map(\.id) { detailRows = updated }
            self.pendingDetail = nil
        }
        for row in rows where row.isRevealing { row.settle(now: now) }
    }

    func run(sessionID: V2SessionID, repository: V2SessionRepository) async {
        let session = repository.session(id: sessionID)
        let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wake = signal.continuation
        defer { signal.continuation.finish(); wake = nil }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in
                defer { signal.continuation.finish() }
                for await value in repository.observe(sessionId: sessionID) {
                    guard !Task.isCancelled, let self else { return }
                    self.receive(value)
                }
            }
            group.addTask { @MainActor [weak self] in
                for await _ in signal.stream {
                    guard !Task.isCancelled, let self else { return }
                    repeat {
                        // Text received during a reveal waits for it to end, then
                        // goes on screen as one batch. Text after a pause shows at
                        // once. Without new text, poll briefly to notice arrivals
                        // and settle rows whose reveal has ended. A prepend batch
                        // additionally waits out the coalescer's hold, so a flood
                        // of history pages lands as few repaints instead of one
                        // per page.
                        let now = ProcessInfo.processInfo.systemUptime
                        let flushAt = self.prependCoalescer.flushEarliest(nextBatchAt: self.nextBatchAt)
                        let wait = self.pending != nil ? flushAt - now : Self.idlePoll
                        if wait > 0 {
                            do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                        }
                        let current = ProcessInfo.processInfo.systemUptime
                        guard self.pending == nil || (current >= self.nextBatchAt && current >= self.prependCoalescer.until) else { continue }
                        self.flush(now: current)
                        self.synchronizePending(session.pendingMessages)
                    } while !Task.isCancelled && (self.pending != nil || self.rows.contains { $0.isRevealing })
                }
            }
            await group.waitForAll()
        }
    }

    private static let idlePoll: TimeInterval = 1.0 / 30

    func synchronizePending(_ messages: [V2PendingMessage]) {
        // Change optimistic membership in the same tick that publishes echoes,
        // avoiding a blank first user row between HTTP/realtime and UI clocks.
        let visible = messages.filter { message in
            !rows.contains { $0.value.role == .user && $0.value.source["clientMessageId"]?.stringValue == message.id }
        }
        if pendingMessages.map(\.id) != visible.map(\.id) { pendingMessages = visible }
    }
}

extension V2TimelineItem {
    var isAssistantText: Bool {
        isReasoning || type == .message && role == .assistant
    }
    var isStreamingText: Bool {
        (status == .pending || status == .running)
            && isAssistantText
    }
    var displayText: String {
        switch content {
        case let .message(value): TimelineText.message(value.text)
        case let .reasoning(value): TimelineText.reasoning(value.raw)
        case let .marker(value): isReasoning ? TimelineText.reasoning(value.raw) : ""
        default: ""
        }
    }
}
