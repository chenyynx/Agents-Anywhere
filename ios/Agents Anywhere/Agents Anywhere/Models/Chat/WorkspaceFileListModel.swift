import Foundation
import Observation

/// Caches workspace file catalogs keyed by `(connectorId, root)`.
///
/// Loading is always background and best-effort: the model never blocks session
/// rendering, a missing catalog simply reads back as `nil` (so the caller treats
/// paths as plain text), and a failed refresh silently keeps the previous value.
/// A key that is already in flight is never re-requested.
@MainActor
@Observable
final class WorkspaceFileListModel {
    /// Cache key: a connector plus the workspace root it was listed from.
    struct Key: Hashable {
        let connectorId: V2ConnectorID
        let root: String
    }

    /// Catalogs keyed by connector + root. Observation tracks the dictionary,
    /// so a view re-evaluates when a background load lands.
    private(set) var catalogs: [Key: WorkspaceFileCatalog] = [:]

    @ObservationIgnored private var inFlight: Set<Key> = []

    /// The cached catalog for a connector + root, or `nil` when it has not been
    /// loaded yet (or its load failed). Never blocks: it only reads the cache.
    func catalog(connectorId: V2ConnectorID, root: String) -> WorkspaceFileCatalog? {
        catalogs[Key(connectorId: connectorId, root: root)]
    }

    /// Fetches and caches the file catalog for a connector + root.
    ///
    /// - A key already loading (or loaded) is skipped, so repeated triggers
    ///   within one session do not fire duplicate requests.
    /// - Failures are swallowed: the previous catalog (if any) is kept and the
    ///   caller is never blocked or shown an error.
    func load(connectorId: V2ConnectorID, root: String, service: V2WorkspaceFilesService) async {
        let key = Key(connectorId: connectorId, root: root)
        guard catalogs[key] == nil, !inFlight.contains(key) else { return }
        await fetch(key: key, service: service)
    }

    /// Re-fetches a catalog even when one is already cached — the App-active /
    /// post-write trigger, where the previous list may be stale. In-flight
    /// requests are still collapsed onto their result, so a background load
    /// and a rapid re-trigger never race two requests for the same key.
    func refresh(connectorId: V2ConnectorID, root: String, service: V2WorkspaceFilesService) async {
        let key = Key(connectorId: connectorId, root: root)
        guard !inFlight.contains(key) else { return }
        await fetch(key: key, service: service)
    }

    private func fetch(key: Key, service: V2WorkspaceFilesService) async {
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        do {
            let result = try await service.fileList(connectorId: key.connectorId, root: key.root)
            try Task.checkCancellation()
            catalogs[key] = WorkspaceFileCatalog(files: result.files)
        } catch {
            // Best-effort: keep any previous catalog, never surface an error and
            // never block the session on a missing/failed list.
        }
    }

    /// Drops every cached catalog and any in-flight marker — the account
    /// boundary (sign-out / account switch), where a stale workspace listing
    /// must not survive into the next session.
    func reset() {
        catalogs = [:]
        inFlight = []
    }
}
