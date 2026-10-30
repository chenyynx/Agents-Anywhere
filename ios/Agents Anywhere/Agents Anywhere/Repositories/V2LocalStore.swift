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
    private var lastTrimCheck = Date.distantPast
    private static let log = Logger(subsystem: "agents.anywhere", category: "timeline-store")

    init(directory: URL, maximumSessions: Int = 8,
         timelineDatabaseEnabled: Bool = LocalTimelineStore.enabled) {
        self.directory = directory
        self.maximumSessions = maximumSessions
        self.timelineDatabaseEnabled = timelineDatabaseEnabled
    }
    func dashboard() -> V2DashboardArchive? { read("dashboard", as: V2DashboardArchive.self) }
    func session(_ id: String) -> V2SessionArchive? {
        read(sessionKey(id), as: V2SessionArchive.self)
            ?? read(stateKey(id), as: V2SessionArchive.self)
    }
    /// Decodes the archived timeline here, off the main actor; a malformed item
    /// is skipped instead of discarding the whole session. The SubAgent
    /// activity cache is decoded here too, so restoring a few hundred child
    /// rows never blocks the main actor.
    func restoreSession(_ id: String,
                        window: Int = V2SessionCachePolicy.defaultOpeningWindow) -> V2SessionRestore? {
        guard valid else { return nil }
        // P2 read path: the row store is the source when it holds this
        // session. A missing/malformed database row falls back to the JSON
        // archive, which also lazily imports that archive into the store.
        if let database = timelineStore(),
           let stored = try? database.read(sessionID: id, limit: max(1, window)),
           let state = stored.meta.stateBlob,
           let decodedArchive = try? JSONDecoder().decode(V2SessionArchive.self, from: state) {
            // A failed database write must not beat a newer JSON archive:
            // compare the archive's mtime with the last successful DB save.
            let jsonModified = try? url(sessionKey(id))
                .resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            let databaseIsCurrent = jsonModified.map {
                $0.timeIntervalSince1970 <= stored.meta.lastAccess + 2
            } ?? true
            if databaseIsCurrent {
                var archive = decodedArchive
                archive.hasOlderItems = archive.hasOlderItems || stored.meta.hasOlderItems
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
                // An offline read must still refresh the LRU timestamp.
                try? database.touch(sessionID: id, at: Date().timeIntervalSince1970)
                return V2SessionRestore(archive: archive, items: items,
                    subAgentActivity: activity, localHasOlderRows: localOlder)
            }
        }

        guard let archive = session(id) else { return nil }
        let activity = (archive.subAgentActivity ?? [:]).mapValues { values in
            values.compactMap { try? V2TimelineItem(json: $0) }
        }
        // Lazy, idempotent migration: an archive written before the row store
        // existed is imported on its first open, then the next open reads the
        // database. No startup scan and no extra blocking on the launch path.
        let database = timelineStore()
        if let database {
            do { try database.upsert(archive.timelineSnapshot()) }
            catch { Self.log.error("timeline lazy import failed: \(String(describing: error), privacy: .public)") }
        }
        // The JSON archive is the older store: bound its opening read the same
        // way the row store bounds a database read.
        let windowed = max(1, window)
        let items = archive.items.compactMap { try? V2TimelineItem(json: $0) }
        return V2SessionRestore(archive: archive,
            items: Array(items.suffix(windowed)),
            subAgentActivity: activity,
            localHasOlderRows: database != nil && items.count > windowed)
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

    func cacheUsage() -> LocalCacheUsage {
        let legacy = legacyJSONBytes()
        guard let database = timelineStore(),
              let usage = try? database.cacheUsage() else {
            return LocalCacheUsage(bytes: legacy, sessions: 0)
        }
        return LocalCacheUsage(bytes: usage.bytes + legacy, sessions: usage.sessions)
    }

    private func legacyJSONBytes() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { total, file in
            guard file.lastPathComponent.hasPrefix("session-"),
                  let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                return total
            }
            return total + Int64(size)
        }
    }

    /// Evicted/cleared sessions keep a state-only JSON file for the rollback
    /// path; the content file must be gone so it cannot resurrect rows.
    private func persistEvictedState(_ database: TimelineDatabase, _ ids: [String]) {
        for id in ids {
            try? FileManager.default.removeItem(at: url(sessionKey(id)))
            if let archive = try? database.stateArchive(sessionID: id) {
                write(archive, key: stateKey(id))
            } else {
                try? FileManager.default.removeItem(at: url(stateKey(id)))
            }
        }
    }

    /// Trims the row store to `limitBytes` and removes the legacy JSON cache of
    /// every evicted session so it cannot resurrect the rows on the next open.
    @discardableResult
    func trimCache(to limitBytes: Int64) -> [String] {
        guard let database = timelineStore(),
              let evicted = try? database.trim(to: limitBytes) else { return [] }
        persistEvictedState(database, evicted)
        return evicted
    }

    @discardableResult
    func clearCache(keepingPinned: Bool = true) -> LocalCacheUsage {
        guard let database = timelineStore() else {
            // The row store is off: the legacy JSON cache is still the only
            // cache, so clearing it must work from Settings too.
            if let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                        includingPropertiesForKeys: nil) {
                for file in files where file.lastPathComponent.hasPrefix("session-")
                    || file.lastPathComponent.hasPrefix("state-") {
                    try? FileManager.default.removeItem(at: file)
                }
            }
            return cacheUsage()
        }
        let cleared = (try? database.clearCache(keepingPinned: keepingPinned)) ?? []
        persistEvictedState(database, cleared)
        return cacheUsage()
    }

    /// Apply the current user setting now (Settings changed the limit) and
    /// return the resulting usage. `unlimited` resolves against free disk.
    func enforceCacheLimit() -> LocalCacheUsage {
        let limit = LocalCachePolicy.effectiveLimit(freeBytes: Self.freeDiskBytes())
        trimCache(to: max(0, limit - legacyJSONBytes()))
        return cacheUsage()
    }

    /// Cheap, throttled budget check after a save. The user-facing setting is
    /// read here; `unlimited` still resolves to the device safety line.
    func trimIfNeeded() {
        guard let database = timelineStore() else { return }
        let now = Date()
        guard now.timeIntervalSince(lastTrimCheck) >= 30 else { return }
        lastTrimCheck = now
        let limit = LocalCachePolicy.effectiveLimit(freeBytes: Self.freeDiskBytes())
        let evicted = (try? database.trim(to: max(0, limit - legacyJSONBytes()))) ?? []
        persistEvictedState(database, evicted)
    }

    private static func freeDiskBytes() -> Int64? {
        try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    func updatePinned(_ values: [String: Bool]) {
        guard let database = timelineStore() else { return }
        for (id, pinned) in values {
            try? database.setPinned(sessionID: id, pinned: pinned)
        }
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
        guard valid, !removedSessions.contains(value.session.id) else { return }
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
        // A stale state-only file must not shadow the regenerated content.
        try? FileManager.default.removeItem(at: url(stateKey(value.session.id)))
        // The row store is the read source when enabled; the JSON archive stays
        // the rollback. A database failure must never block the JSON path
        // (offline cache, drafts and the send path all depend on it).
        if let database = timelineStore() {
            do { try database.upsert(value.timelineSnapshot()) }
            catch { Self.log.error("timeline shadow write failed: \(String(describing: error), privacy: .public)") }
            trimIfNeeded()
        }
        savesSinceTrim += 1
        if isNew || savesSinceTrim >= 20 { trim(); savesSinceTrim = 0 }
    }
    func removeSession(_ id: String) {
        removedSessions.insert(id)
        try? FileManager.default.removeItem(at: url(sessionKey(id)))
        try? FileManager.default.removeItem(at: url(stateKey(id)))
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
        guard valid else { return nil }
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
    /// A state-only archive kept after eviction/clear for the rollback path.
    private func stateKey(_ id: String) -> String { "state-" + V2RestorationStore.digest(id) }
    private func url(_ key: String) -> URL { directory.appendingPathComponent(key + ".json") }
}
