import Foundation
import os

/// Serial, bounded disk I/O off the main actor. Account invalidation closes this
/// handle before deleting it, so an in-flight save cannot recreate signed-out data.
actor V2LocalStore {
    private struct Envelope<Value: Codable>: Codable { let version: Int; let value: Value }
    private let directory: URL
    private var valid = true
    private var removedSessions: Set<String> = []
    private var savesSinceTrim = 0
    private let maximumSessions: Int
    private let timelineDatabaseEnabled: Bool
    private var timelineDatabase: TimelineDatabase?
    private var didOpenTimelineDatabase = false
    private static let log = Logger(subsystem: "agents.anywhere", category: "timeline-store")

    init(directory: URL, maximumSessions: Int = 8,
         timelineDatabaseEnabled: Bool = LocalTimelineStore.enabled) {
        self.directory = directory
        self.maximumSessions = maximumSessions
        self.timelineDatabaseEnabled = timelineDatabaseEnabled
    }
    func dashboard() -> V2DashboardArchive? { read("dashboard", as: V2DashboardArchive.self) }
    func session(_ id: String) -> V2SessionArchive? { read(sessionKey(id), as: V2SessionArchive.self) }
    /// Decodes the archived timeline here, off the main actor; a malformed item
    /// is skipped instead of discarding the whole session. The SubAgent
    /// activity cache is decoded here too, so restoring a few hundred child
    /// rows never blocks the main actor.
    func restoreSession(_ id: String, window: Int = 100) -> V2SessionRestore? {
        // P2 read path: the row store is the source when it holds this
        // session. A missing/malformed database row falls back to the JSON
        // archive, which also lazily imports that archive into the store.
        if let database = timelineStore(),
           let stored = try? database.read(sessionID: id, limit: max(1, window)),
           let state = stored.meta.stateBlob,
           let archive = try? JSONDecoder().decode(V2SessionArchive.self, from: state) {
            let items = decodeRows(stored.rows)
            let activity = (archive.subAgentActivity ?? [:]).mapValues { values in
                values.compactMap { try? V2TimelineItem(json: $0) }
            }
            let localOlder: Bool
            if let first = items.first?.orderSeq {
                localOlder = (try? database.hasOlderRows(sessionID: id,
                                                         beforeOrderSeq: first)) ?? false
            } else {
                localOlder = false
            }
            return V2SessionRestore(archive: archive, items: items,
                subAgentActivity: activity, localHasOlderRows: localOlder)
        }

        guard let archive = session(id) else { return nil }
        let activity = (archive.subAgentActivity ?? [:]).mapValues { values in
            values.compactMap { try? V2TimelineItem(json: $0) }
        }
        // Lazy, idempotent migration: an archive written before the row store
        // existed is imported on its first open, then the next open reads the
        // database. No startup scan and no extra blocking on the launch path.
        if let database = timelineStore() {
            do { try database.replace(archive.timelineSnapshot()) }
            catch { Self.log.error("timeline lazy import failed: \(String(describing: error), privacy: .public)") }
        }
        return V2SessionRestore(archive: archive,
            items: archive.items.compactMap { try? V2TimelineItem(json: $0) },
            subAgentActivity: activity,
            localHasOlderRows: archive.items.count > max(1, window))
    }
    /// Older rows for the paging path. `nil` means the row store is not
    /// available; an empty page means the store has no older row.
    func olderRows(sessionID: String, beforeOrderSeq: Int, limit: Int) -> V2LocalTimelinePage? {
        guard let database = timelineStore(),
              let rows = try? database.olderRows(sessionID: sessionID,
                                                 beforeOrderSeq: beforeOrderSeq,
                                                 limit: max(1, limit) + 1) else { return nil }
        // `rows` is ascending and carries one extra oldest row when more
        // history exists; keep the newest `limit` rows and drop that probe.
        let bounded = Array(rows.suffix(max(1, limit)))
        return V2LocalTimelinePage(items: decodeRows(bounded), hasMore: rows.count > limit)
    }

    /// Newer rows for `loadLatest`: the newest page plus whether the store
    /// still holds older rows beside it.
    func latestRows(sessionID: String, limit: Int) -> V2LocalTimelinePage? {
        guard let database = timelineStore(),
              let rows = try? database.latestRows(sessionID: sessionID, limit: max(1, limit)) else {
            return nil
        }
        let items = decodeRows(rows)
        let hasMore: Bool
        if let first = items.first?.orderSeq {
            hasMore = (try? database.hasOlderRows(sessionID: sessionID,
                                                  beforeOrderSeq: first)) ?? false
        } else {
            hasMore = false
        }
        return V2LocalTimelinePage(items: items, hasMore: hasMore)
    }

    func hasOlderRows(sessionID: String, beforeOrderSeq: Int) -> Bool {
        guard let database = timelineStore(),
              let value = try? database.hasOlderRows(sessionID: sessionID,
                                                     beforeOrderSeq: beforeOrderSeq) else {
            return false
        }
        return value
    }

    private func decodeRows(_ rows: [TimelineRow]) -> [V2TimelineItem] {
        rows.compactMap { row in
            guard let raw = try? JSONDecoder().decode(JSONValue.self, from: row.payload) else {
                return nil
            }
            return try? V2TimelineItem(json: raw)
        }
    }

    func saveDashboard(_ value: V2DashboardArchive) { write(value, key: "dashboard") }
    func saveSession(_ value: V2SessionArchive) {
        guard !removedSessions.contains(value.session.id) else { return }
        let key = sessionKey(value.session.id)
        var value = value
        // The activity cache's byte budget needs encoded sizes, so it is
        // applied here, off the main actor, right before serialization.
        if let cached = value.subAgentActivity, !cached.isEmpty {
            let cards = cached.mapValues { values in
                values.compactMap { try? V2TimelineItem(json: $0) }
            }
            let bounded = SubAgentActivityArchive.bounded(cards, limits: .default)
            value.subAgentActivity = bounded.isEmpty ? nil : bounded.mapValues { $0.map(\.raw) }
        }
        // Rewriting an existing archive cannot exceed the session count; only a
        // new file or a byte-limit check needs the directory scan.
        let isNew = !FileManager.default.fileExists(atPath: url(key).path)
        write(value, key: key)
        // P1 shadow write: the JSON archive stays authoritative, the row store
        // is an exact mirror. A database failure must never block the JSON
        // path (offline cache, drafts and the send path all depend on it).
        if let database = timelineStore() {
            do { try database.replace(value.timelineSnapshot()) }
            catch { Self.log.error("timeline shadow write failed: \(String(describing: error), privacy: .public)") }
        }
        savesSinceTrim += 1
        if isNew || savesSinceTrim >= 20 { trim(); savesSinceTrim = 0 }
    }
    func removeSession(_ id: String) {
        removedSessions.insert(id)
        try? FileManager.default.removeItem(at: url(sessionKey(id)))
        if let database = timelineStore() {
            do { try database.removeSession(id) }
            catch { Self.log.error("timeline shadow delete failed: \(String(describing: error), privacy: .public)") }
        }
    }
    func close(removing: Bool) {
        valid = false
        do { try timelineDatabase?.close() }
        catch { Self.log.error("timeline database close failed: \(String(describing: error), privacy: .public)") }
        timelineDatabase = nil
        didOpenTimelineDatabase = false
        if removing { try? FileManager.default.removeItem(at: directory) }
    }
    /// Opens the row store lazily from the actor, never from the main actor.
    private func timelineStore() -> TimelineDatabase? {
        if !didOpenTimelineDatabase {
            didOpenTimelineDatabase = true
            guard timelineDatabaseEnabled else { return nil }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                timelineDatabase = try TimelineDatabase(
                    path: directory.appendingPathComponent("timeline.sqlite").path)
            } catch {
                timelineDatabase = nil
                Self.log.error("timeline database open failed: \(String(describing: error), privacy: .public)")
            }
        }
        return timelineDatabase
    }
    private func read<Value: Codable>(_ key: String, as: Value.Type) -> Value? {
        guard valid else { return nil }
        let location = url(key)
        guard let size = try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64 * 1024 * 1024,
              let bytes = try? Data(contentsOf: location),
              let envelope = try? JSONDecoder().decode(Envelope<Value>.self, from: bytes), envelope.version == 1 else { return nil }
        return envelope.value
    }
    private func write<Value: Codable>(_ value: Value, key: String) {
        guard valid, let bytes = try? JSONEncoder().encode(Envelope(version: 1, value: value)), bytes.count <= 64 * 1024 * 1024 else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var folder = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
            #if os(iOS)
            try bytes.write(to: url(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try bytes.write(to: url(key), options: .atomic)
            #endif
        } catch { /* A full/unavailable disk must not prevent reading or sending. */ }
    }
    private func trim() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        let sessions = files.filter { $0.lastPathComponent.hasPrefix("session-") }.sorted {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                > (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        var bytes = 0
        for (index, file) in sessions.enumerated() {
            bytes += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if index >= maximumSessions || bytes > 128 * 1024 * 1024 { try? FileManager.default.removeItem(at: file) }
        }
    }
    private func sessionKey(_ id: String) -> String { "session-" + V2RestorationStore.digest(id) }
    private func url(_ key: String) -> URL { directory.appendingPathComponent(key + ".json") }
}
