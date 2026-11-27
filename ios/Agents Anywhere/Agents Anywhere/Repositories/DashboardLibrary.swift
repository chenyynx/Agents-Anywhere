import Foundation
import Observation

/// User-facing switch for the local-database dashboard source.
nonisolated enum DashboardLibraryPreferences {
    /// Bool, default on. Turning it off falls back to the in-memory
    /// repository + JSON archive path within one launch.
    static let enabledKey = "aa.dashboard.library"
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }
}

/// The main-actor face of the dashboard library. Views read `sessions` /
/// `connectors` / `projects` from this object; the rows themselves live in the
/// local database and are merged off the main actor by `V2LocalStore`.
///
/// Library changes are coalesced into one publish per 100 ms window; a read
/// that equals the published arrays does not republish. `reconcile` runs on the
/// main actor at publish time (read watermarks), never inside the background
/// ingest.
@MainActor @Observable
final class DashboardLibrary {
    private(set) var connectors: [V2Connector] = []
    private(set) var projects: [V2Project] = []
    private(set) var sessions: [V2SessionMeta] = []
    private(set) var revision = 0
    private(set) var isLive = false

    /// Injected by `AppState` (`sessionReads.ingest`), applied to every row at
    /// publish time.
    @ObservationIgnored var reconcile: (V2SessionMeta) -> V2SessionMeta = { $0 }
    /// Called after a publish with the reconciled rows.
    @ObservationIgnored var onPublish: ((DashboardRows) -> Void)?

    @ObservationIgnored private let store: V2LocalStore
    @ObservationIgnored private var observeTask: Task<Void, Never>?
    @ObservationIgnored private var pendingRows: DashboardRows?
    @ObservationIgnored private var publishTask: Task<Void, Never>?

    init(store: V2LocalStore) {
        self.store = store
    }

    func start() {
        guard observeTask == nil else { return }
        isLive = true
        observeTask = Task { [weak self] in
            guard let self else { return }
            guard let stream = await self.store.observeDashboard() else { return }
            for await rows in stream {
                guard !Task.isCancelled else { return }
                self.receive(rows)
            }
        }
    }

    func stop() {
        observeTask?.cancel(); observeTask = nil
        publishTask?.cancel(); publishTask = nil
        pendingRows = nil
        isLive = false
    }

    // MARK: - Writes (all on the store actor)

    @discardableResult
    func ingest(_ input: DashboardIngestInput) async -> DashboardIngestOutcome? {
        await store.ingestDashboard(input)
    }

    func upsertSessions(_ values: [V2SessionMeta]) async {
        await store.upsertDashboardSessions(values)
    }

    func removeSession(id: String) async {
        await store.removeDashboardSession(id: id)
    }

    func upsertConnector(_ value: V2Connector) async {
        await store.upsertDashboardConnector(value)
    }

    func removeConnector(id: String) async {
        await store.removeDashboardConnector(id: id)
    }

    func upsertProject(_ value: V2Project) async {
        await store.upsertDashboardProject(value)
    }

    func deleteProject(id: String) async {
        await store.deleteDashboardProject(id: id)
    }

    func clear() async {
        await store.clearDashboardLibrary()
    }

    /// One-time import of the legacy JSON dashboard archive.
    @discardableResult
    func seedFromArchive(_ archive: V2DashboardArchive) async -> Bool {
        await store.importDashboardArchive(archive)
    }

    // MARK: - Publish

    private func receive(_ rows: DashboardRows) {
        pendingRows = rows
        guard publishTask == nil else { return }
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, !Task.isCancelled else { return }
            self.publishTask = nil
            self.publish()
        }
    }

    private func publish() {
        guard let rows = pendingRows else { return }
        pendingRows = nil
        let output = DashboardRows(
            connectors: rows.connectors,
            projects: rows.projects,
            sessions: rows.sessions.map(reconcile),
            revision: rows.revision)
        if connectors != output.connectors { connectors = output.connectors }
        if projects != output.projects { projects = output.projects }
        if sessions != output.sessions { sessions = output.sessions }
        revision = output.revision
        onPublish?(output)
    }
}
