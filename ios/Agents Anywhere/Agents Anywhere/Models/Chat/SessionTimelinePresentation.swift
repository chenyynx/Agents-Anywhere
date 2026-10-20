import Foundation
import Observation

@MainActor @Observable
final class ChatTimelineRowModel: Identifiable {
    let id: V2TimelineItemID
    private(set) var value: V2TimelineItem
    private(set) var structure: TimelineRowStructure
    private(set) var text: String
    private(set) var isRevealing = false
    private(set) var layoutGeneration = 0
    @ObservationIgnored private(set) var settlesAt: TimeInterval = 0
    @ObservationIgnored private var hasFlushed = false
    @ObservationIgnored private var entryCache: (cwd: String?, entry: TimelineEntryPresentation)?
    /// False while a streaming batch withholds the final glyph of the received text.
    @ObservationIgnored private var displaysFullText = false

    init(_ value: V2TimelineItem, animate: Bool = false) {
        id = value.id; self.value = value
        structure = TimelineRowStructure(value)
        text = animate ? "" : value.displayText
    }

    /// Returns true when newly displayed text starts a reveal batch.
    @discardableResult
    func flush(_ next: V2TimelineItem, animate: Bool, now: TimeInterval) -> Bool {
        // Unchanged rows neither recompute their structure nor rescan their text.
        if hasFlushed && value == next && (animate || displaysFullText) { settle(now: now); return false }
        hasFlushed = true
        let received = next.displayText
        let appending = received.hasPrefix(text)
        // Snapshots/corrections are authoritative replacements, not token deltas.
        if !appending { layoutGeneration += 1 }
        let safeText = animate && appending && next.isStreamingText && !received.isEmpty
            ? String(received.dropLast()) : received
        let displayed = safeText.hasPrefix(text) || !appending ? safeText : received
        displaysFullText = displayed == received
        var started = false
        if displayed != text {
            isRevealing = animate && appending
            started = isRevealing
            if isRevealing { settlesAt = now + ReplyPresentation.revealSeconds + ReplyPresentation.drawSlack }
            text = displayed
        }
        if value != next { value = next; entryCache = nil }
        let nextStructure = TimelineRowStructure(next)
        if structure != nextStructure { structure = nextStructure }
        if !animate || now >= settlesAt { isRevealing = false }
        return started
    }

    /// Tool/marker rows parse their payload once per item version instead of
    /// on every body evaluation of the row and its expanded details.
    func entry(cwd: String?) -> TimelineEntryPresentation {
        if let entryCache, entryCache.cwd == cwd { return entryCache.entry }
        let entry = TimelineEntryPresentation(item: value, cwd: cwd)
        entryCache = (cwd, entry)
        return entry
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
    private(set) var pendingMessages: [V2PendingMessage] = []
    private(set) var hasPresentedSnapshot = false
    /// Bumped whenever a presentation drops rows that were on screen — the
    /// opening's trim/latest-page surgery and any wholesale recovery or
    /// snapshot replacement. A pure append never bumps it. The timeline view
    /// re-asserts its opening return on every bump so a replaced window can
    /// never render from its own top: the scroll view anchors content-size
    /// changes to the top, so without the re-assert the reader is parked
    /// away from the newest rows until a manual scroll (2026-10-08).
    private(set) var windowRevision = 0
    /// Bumped once per published flush. Row text changes in place on a
    /// `ChatTimelineRowModel` (an observable class), so the `rows` array
    /// identity does not move when a streaming reply grows. The collection
    /// wrapper reads this value to re-evaluate and recompute content
    /// signatures; without it the new container would only notice a stream
    /// on the next unrelated model change.
    private(set) var flushRevision = 0
    @ObservationIgnored private var rowsByID: [V2TimelineItemID: ChatTimelineRowModel] = [:]
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
        stage(data.items, animate: initialized && lastConnection == .connected && observation.connection == .connected)
        initialized = true
    }

    func stage(_ items: [V2TimelineItem], animate: Bool) {
        pending = items.filter(\.isVisibleInChat)
        // Once a recovery snapshot is staged, preserve its snap semantics until
        // that tick even if a live event arrives immediately afterwards.
        animatePending = pendingWasStaged ? animatePending && animate : animate
        pendingWasStaged = true
        wake?.yield(())
    }
    @ObservationIgnored private var pendingWasStaged = false

    func flush(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let signpost = PerfSignpost.begin("timeline.flush")
        defer { PerfSignpost.end("timeline.flush", signpost) }
        if let pending {
            let presented = Set(rows.map(\.id))
            let previousTail = rows.last?.value.orderSeq ?? Int.min
            var started = false
            var updated: [ChatTimelineRowModel] = []
            updated.reserveCapacity(pending.count)
            var orderChanged = pending.count != rows.count
            for (index, value) in pending.enumerated() {
                let existing = rowsByID[value.id]
                let animate = animatePending && (existing != nil || value.orderSeq > previousTail)
                let row: ChatTimelineRowModel
                if let existing { row = existing } else {
                    row = ChatTimelineRowModel(value, animate: animate && value.isAssistantText)
                    rowsByID[value.id] = row
                }
                if row.flush(value, animate: animate, now: now) { started = true }
                if !orderChanged, rows[index] !== row { orderChanged = true }
                updated.append(row)
            }
            if started { nextBatchAt = now + ReplyPresentation.batchInterval }
            if orderChanged {
                rows = updated
                rowsByID = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0) })
            }
            // A drop of a previously presented row means the window itself
            // moved (a trim, a latest-page swap, a recovery replacement) — the
            // one shape that needs the viewport re-asserted. The opening's own
            // first presentation drops nothing and keeps the claim with
            // `open()`, and an append keeps every old id, so neither bumps.
            if !presented.isSubset(of: Set(updated.map(\.id))) { windowRevision &+= 1 }
            if !hasPresentedSnapshot { hasPresentedSnapshot = true }
            flushRevision &+= 1
            self.pending = nil; pendingWasStaged = false
        }
        // A reveal settling flips which renderer may own the row (the live
        // tail vs. the static TextKit body) without a wire revision change.
        // Publish one update so the collection re-evaluates that row; without
        // it the row can stay on the hosting path until an unrelated update.
        var revealSettled = false
        for row in rows where row.isRevealing {
            row.settle(now: now)
            if !row.isRevealing { revealSettled = true }
        }
        if revealSettled { flushRevision &+= 1 }
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
                        // and settle rows whose reveal has ended.
                        let now = ProcessInfo.processInfo.systemUptime
                        // Without new text, sleep until the earliest reveal ends
                        // instead of waking at a fixed cadence.
                        let wait = self.pending != nil ? self.nextBatchAt - now
                            : max(Self.minimumIdleWait, (self.rows.filter(\.isRevealing).map(\.settlesAt).min() ?? now) - now)
                        if wait > 0 {
                            do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                        }
                        let current = ProcessInfo.processInfo.systemUptime
                        guard self.pending == nil || current >= self.nextBatchAt else { continue }
                        self.flush(now: current)
                        self.synchronizePending(session.pendingMessages)
                    } while !Task.isCancelled && (self.pending != nil || self.rows.contains { $0.isRevealing })
                }
            }
            await group.waitForAll()
        }
    }

    private static let minimumIdleWait: TimeInterval = 1.0 / 60

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
}
