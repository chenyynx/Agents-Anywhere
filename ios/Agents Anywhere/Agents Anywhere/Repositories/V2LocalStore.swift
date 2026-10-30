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
    func restoreSession(_ id: String) -> V2SessionRestore? {
        guard let archive = session(id) else { return nil }
        let activity = (archive.subAgentActivity ?? [:]).mapValues { values in
            values.compactMap { try? V2TimelineItem(json: $0) }
        }
        return V2SessionRestore(archive: archive,
            items: archive.items.compactMap { try? V2TimelineItem(json: $0) },
            subAgentActivity: activity)
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
