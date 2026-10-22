import Foundation
import Observation

/// The page's reader for deferred summary rows (`deferActivity`).
///
/// A deferred window replaces a large tool payload with a summary row that
/// carries `content.deferred == true` and its original byte size. The full row
/// comes from the single-item read (`GET …/timeline/items/{item_id}`), which
/// the repository projects into the window in place. This store owns only the
/// outcome the UI renders per row — idle, failed or offline — plus the
/// in-flight dedupe and the bounded prefetch queue. It deliberately exposes no
/// loading state: the summary row is already on screen and a spinner on every
/// row would read as a broken page.
@MainActor @Observable
final class DeferredItemStore {
    typealias Load = @MainActor (V2TimelineItemID) async throws -> Void

    enum Phase: Equatable {
        case idle
        /// The read failed for a reason other than a down path (a 404, an
        /// HTTP error, an unreadable response). Retryable.
        case failed
        /// The path is down. Retryable once it returns.
        case offline
    }

    /// Prefetch budgets. The values are deliberately small: these reads run
    /// behind the reader's back and must never queue ahead of the requests
    /// that build the page.
    private static let prefetchMaximumRows = 12
    private static let prefetchMaximumBytes = 512 * 1024
    private static let prefetchRowByteCap = 65_536

    /// Observable so `phase(_:)` re-evaluates when a read settles. A missing
    /// entry is `.idle`; keeping only settled failures in the map means a
    /// successful read leaves nothing behind.
    private var phases: [V2TimelineItemID: Phase] = [:]
    @ObservationIgnored private let loader: Load
    /// The one in-flight read per row. An id present here is deduped: a second
    /// tap starts nothing.
    @ObservationIgnored private var tasks: [V2TimelineItemID: Task<Void, Never>] = [:]
    /// Identity of the read registered in `tasks`, so a cancelled or
    /// superseded read cannot clear a newer registration or write a stale
    /// phase.
    @ObservationIgnored private var tokens: [V2TimelineItemID: UUID] = [:]
    /// Rows waiting for their turn; drained serially by `prefetchTask`.
    @ObservationIgnored private var prefetchQueue: [V2TimelineItemID] = []
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchToken: UUID?

    init(load: @escaping Load) { loader = load }

    func phase(_ id: V2TimelineItemID) -> Phase { phases[id] ?? .idle }

    /// User-triggered read. Idempotent: a row already in flight is left alone.
    func load(_ id: V2TimelineItemID) { _ = startLoad(id) }

    /// A retry is a new attempt after `.failed`/`.offline`; otherwise identical
    /// to `load`.
    func retry(_ id: V2TimelineItemID) { _ = startLoad(id) }

    /// Queues the visible summary rows worth reading ahead of the reader. Only
    /// rows already summarized (`isDeferred`) with a known, small payload are
    /// taken, and one call never queues more than the row/byte budget. Rows
    /// with any non-idle phase are skipped — a failed row is retried by the
    /// user, not by this path.
    func prefetch(_ items: [V2TimelineItem]) {
        var budget = Self.prefetchMaximumBytes
        var accepted = 0
        var queued = Set(prefetchQueue)
        for item in items {
            guard item.isDeferred, let bytes = item.deferredBytes,
                  bytes >= 0, bytes <= Self.prefetchRowByteCap,
                  accepted < Self.prefetchMaximumRows,
                  bytes <= budget else { continue }
            guard phase(item.id) == .idle, tasks[item.id] == nil,
                  queued.insert(item.id).inserted else { continue }
            prefetchQueue.append(item.id)
            budget -= bytes
            accepted += 1
        }
        startPrefetchIfNeeded()
    }

    /// Cancels every read and the prefetch queue (page teardown). A cancelled
    /// read leaves no phase behind: cancellation is the page going away, not a
    /// fact about the row.
    func cancelAll() {
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchToken = nil
        prefetchQueue.removeAll()
        let running = Array(tasks.values)
        tasks.removeAll()
        tokens.removeAll()
        for task in running { task.cancel() }
    }

    /// Registers a read for the row, or returns the one already in flight.
    @discardableResult
    private func startLoad(_ id: V2TimelineItemID) -> Task<Void, Never>? {
        if let task = tasks[id] { return task }
        let token = UUID()
        tokens[id] = token
        let task = Task { [weak self] in
            // Explicit Void result: `await self?.fetch(...)` would infer
            // `Task<()?, Never>` and fail to assign to `Task<Void, Never>`.
            guard let self else { return }
            await self.fetch(id, token: token)
        }
        tasks[id] = task
        return task
    }

    private func fetch(_ id: V2TimelineItemID, token: UUID) async {
        do {
            try await loader(id)
            if tokens[id] == token { phases[id] = nil }
        } catch {
            let failure = V2ClientFailure(error)
            if failure.kind != .cancelled, tokens[id] == token {
                phases[id] = failure.kind == .offline ? .offline : .failed
            }
        }
        if tokens[id] == token {
            tasks[id] = nil
            tokens[id] = nil
        }
    }

    private func startPrefetchIfNeeded() {
        guard prefetchTask == nil, !prefetchQueue.isEmpty else { return }
        let token = UUID()
        prefetchToken = token
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.prefetchToken == token {
                    self.prefetchTask = nil
                    self.prefetchToken = nil
                }
            }
            while !Task.isCancelled, !self.prefetchQueue.isEmpty {
                let id = self.prefetchQueue.removeFirst()
                guard self.phase(id) == .idle, self.tasks[id] == nil else { continue }
                if let task = self.startLoad(id) { await task.value }
            }
        }
    }
}
