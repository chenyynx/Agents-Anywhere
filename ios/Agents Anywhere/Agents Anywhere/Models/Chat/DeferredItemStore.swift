import Foundation
import Observation

/// The page's reader for deferred summary rows (`deferActivity`).
///
/// A deferred window replaces a large tool payload with a summary row that
/// carries `content.deferred == true` and its original byte size. The full row
/// comes from the single-item read (`GET …/timeline/items/{item_id}`), which
/// the repository projects into the window in place. This store owns only the
/// outcome the UI renders per row — idle, loading, failed or offline — plus the
/// in-flight dedupe.
///
/// The read is explicit: the row shows its preview and a load control, and the
/// user asks for the full payload (the official transcript's "Load full file").
/// There is no automatic prefetch: a read the reader did not ask for competes
/// with the page's own window requests, which is exactly the traffic that made
/// a stale window impossible to heal.
@MainActor @Observable
final class DeferredItemStore {
    typealias Load = @MainActor (V2TimelineItemID) async throws -> Void

    enum Phase: Equatable {
        case idle
        /// The explicit read is in flight. The row keeps its preview; only the
        /// load control reflects this state.
        case loading
        /// The read failed for a reason other than a down path (a 404, an
        /// HTTP error, an unreadable response). Retryable.
        case failed
        /// The path is down. Retryable once it returns.
        case offline
    }

    /// Observable so `phase(_:)` re-evaluates when a read starts or settles.
    /// A missing entry is `.idle`; a successful read leaves nothing behind.
    private var phases: [V2TimelineItemID: Phase] = [:]
    @ObservationIgnored private let loader: Load
    /// The one in-flight read per row. An id present here is deduped: a second
    /// tap starts nothing.
    @ObservationIgnored private var tasks: [V2TimelineItemID: Task<Void, Never>] = [:]
    /// Identity of the read registered in `tasks`, so a cancelled or
    /// superseded read cannot clear a newer registration or write a stale
    /// phase.
    @ObservationIgnored private var tokens: [V2TimelineItemID: UUID] = [:]

    init(load: @escaping Load) { loader = load }

    func phase(_ id: V2TimelineItemID) -> Phase { phases[id] ?? .idle }

    /// User-triggered read. Idempotent: a row already in flight is left alone.
    func load(_ id: V2TimelineItemID) { _ = startLoad(id) }

    /// A retry is a new attempt after `.failed`/`.offline`; otherwise identical
    /// to `load`.
    func retry(_ id: V2TimelineItemID) { _ = startLoad(id) }

    /// Cancels every read (page teardown). A cancelled read leaves no phase
    /// behind: cancellation is the page going away, not a fact about the row.
    func cancelAll() {
        let running = Array(tasks.values)
        tasks.removeAll()
        tokens.removeAll()
        phases.removeAll()
        for task in running { task.cancel() }
    }

    /// Registers a read for the row, or returns the one already in flight.
    @discardableResult
    private func startLoad(_ id: V2TimelineItemID) -> Task<Void, Never>? {
        if let task = tasks[id] { return task }
        let token = UUID()
        tokens[id] = token
        phases[id] = .loading
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
}
