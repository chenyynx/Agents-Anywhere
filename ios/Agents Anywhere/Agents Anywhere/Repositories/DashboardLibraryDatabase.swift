import Foundation
import GRDB

/// One consistent read of the dashboard library. The UI observes this shape
/// instead of the network snapshot: rows live in the local database and the
/// view layer only diffs what it reads.
nonisolated struct DashboardRows: Sendable, Equatable {
    let connectors: [V2Connector]
    let projects: [V2Project]
    let sessions: [V2SessionMeta]
    let revision: Int
}

/// A full dashboard snapshot handed to the local store for merging.
nonisolated struct DashboardIngestInput: Sendable {
    let connectors: [V2Connector]
    let projects: [V2Project]
    let sessions: [V2SessionMeta]
}

/// What one ingest wrote. `wrote == false` means the content signature matched
/// the previous ingest and nothing was written or published.
nonisolated struct DashboardIngestOutcome: Sendable, Equatable {
    let revision: Int
    let wrote: Bool
    let changedSessionIDs: [String]
    let sessionsChanged: Bool
    let connectorsChanged: Bool
    let projectsChanged: Bool
}

/// The dashboard half of the local store: three row tables plus a revision
/// fence, written in one transaction and read through `ValueObservation`.
/// All entry points are synchronous and called from `V2LocalStore`'s actor, so
/// no database work runs on the main actor.
extension TimelineDatabase {
    // MARK: - Reads

    func dashboardRows() throws -> DashboardRows {
        try pool.read { db in try Self.fetchDashboardRows(db) }
    }

    /// Live rows for the UI. The observation runs on a background queue;
    /// `removeDuplicates` keeps identical reads from waking the main actor.
    func observeDashboard() -> AsyncStream<DashboardRows> {
        AsyncStream { continuation in
            let observation = ValueObservation
                .tracking { db in try Self.fetchDashboardRows(db) }
                .removeDuplicates()
            let cancellable = observation.start(
                in: pool,
                scheduling: .async(onQueue: DispatchQueue(
                    label: "aa.dashboard.library", qos: .utility)),
                onError: { error in
                    ClientDiagnosticsLog.shared.record(
                        kind: "dashboard.observe.failed",
                        detail: ["error": String(describing: error)],
                        dedupe: true)
                    continuation.finish()
                },
                onChange: { rows in continuation.yield(rows) })
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }

    // MARK: - Writes

    /// Merges a full snapshot into the library in one transaction:
    /// upsert changed rows, delete rows the snapshot no longer carries, keep
    /// local pending sessions, then advance the revision.
    func ingestDashboard(_ input: DashboardIngestInput) throws -> DashboardIngestOutcome {
        try pool.write { db in
            let revision = try Self.currentRevision(db)
            let signature = Self.signature(input)
            let previous = try String.fetchOne(
                db, sql: "SELECT value FROM dashboard_meta WHERE key = 'signature'")
            guard previous != signature else {
                return DashboardIngestOutcome(revision: revision, wrote: false,
                    changedSessionIDs: [], sessionsChanged: false,
                    connectorsChanged: false, projectsChanged: false)
            }

            let held = try Self.fetchHeldSessions(db)
            let merged = DashboardMerge.apply(
                held: held, incoming: input.sessions,
                validConnectorIDs: Set(input.connectors.map(\.id)),
                reconcile: { $0 })

            var existingSessions: [String: Data] = [:]
            for row in try Row.fetchAll(
                db, sql: "SELECT session_id, payload FROM dashboard_sessions") {
                existingSessions[row["session_id"]] = row["payload"]
            }
            var changedSessionIDs: [String] = []
            for session in merged {
                let payload = try Self.encode(session)
                guard existingSessions[session.id] != payload else { continue }
                changedSessionIDs.append(session.id)
                try db.execute(sql: """
                    INSERT INTO dashboard_sessions
                        (session_id, connector_id, archived, updated_seq, payload)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(session_id) DO UPDATE SET
                        connector_id = excluded.connector_id,
                        archived = excluded.archived,
                        updated_seq = excluded.updated_seq,
                        payload = excluded.payload
                    WHERE excluded.updated_seq >= dashboard_sessions.updated_seq
                    """, arguments: [session.id, session.connectorId,
                                     session.archived, session.updatedSeq, payload])
            }
            let mergedIDs = Set(merged.map(\.id))
            var removedSessions = 0
            for id in existingSessions.keys where !mergedIDs.contains(id) {
                try db.execute(sql: "DELETE FROM dashboard_sessions WHERE session_id = ?",
                               arguments: [id])
                removedSessions += 1
            }

            let connectorsChanged = try Self.replaceConnectors(db, input.connectors)
            let projectsChanged = try Self.replaceProjects(db, input.projects)

            let next = revision + 1
            try Self.setMeta(db, key: "revision", value: String(next))
            try Self.setMeta(db, key: "signature", value: signature)
            return DashboardIngestOutcome(
                revision: next, wrote: true,
                changedSessionIDs: changedSessionIDs.sorted(),
                sessionsChanged: !changedSessionIDs.isEmpty || removedSessions > 0,
                connectorsChanged: connectorsChanged,
                projectsChanged: projectsChanged)
        }
    }

    /// Local mutations bypass the snapshot signature: they must land at once.
    func upsertDashboardSessions(_ sessions: [V2SessionMeta]) throws -> Int {
        try pool.write { db in
            for session in sessions { try Self.insertSession(db, session) }
            let next = try Self.currentRevision(db) + 1
            try Self.setMeta(db, key: "revision", value: String(next))
            return next
        }
    }

    func removeDashboardSession(id: String) throws -> Int {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM dashboard_sessions WHERE session_id = ?",
                           arguments: [id])
            let next = try Self.currentRevision(db) + 1
            try Self.setMeta(db, key: "revision", value: String(next))
            return next
        }
    }

    func upsertDashboardConnector(_ connector: V2Connector) throws -> Int {
        try pool.write { db in
            let payload = try Self.encode(connector)
            try db.execute(sql: """
                INSERT INTO dashboard_connectors (id, payload) VALUES (?, ?)
                ON CONFLICT(id) DO UPDATE SET payload = excluded.payload
                """, arguments: [connector.id, payload])
            let next = try Self.currentRevision(db) + 1
            try Self.setMeta(db, key: "revision", value: String(next))
            return next
        }
    }

    func removeDashboardConnector(id: String) throws -> Int {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM dashboard_connectors WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM dashboard_projects WHERE connector_id = ?",
                           arguments: [id])
            try db.execute(sql: "DELETE FROM dashboard_sessions WHERE connector_id = ?",
                           arguments: [id])
            let next = try Self.currentRevision(db) + 1
            try Self.setMeta(db, key: "revision", value: String(next))
            return next
        }
    }

    func upsertDashboardProject(_ project: V2Project) throws -> Int {
        try pool.write { db in
            let payload = try Self.encode(project)
            try db.execute(sql: """
                INSERT INTO dashboard_projects (id, connector_id, payload)
                VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    connector_id = excluded.connector_id, payload = excluded.payload
                """, arguments: [project.id, project.connectorId, payload])
            let next = try Self.currentRevision(db) + 1
            try Self.setMeta(db, key: "revision", value: String(next))
            return next
        }
    }

    func replaceDashboardProjects(_ values: [V2Project]) throws -> Int {
        try pool.write { db in
            _ = try Self.replaceProjects(db, values)
            let next = try Self.currentRevision(db) + 1
            try Self.setMeta(db, key: "revision", value: String(next))
            return next
        }
    }

    func deleteDashboardProject(id: String) throws -> Int {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM dashboard_projects WHERE id = ?", arguments: [id])
            let next = try Self.currentRevision(db) + 1
            try Self.setMeta(db, key: "revision", value: String(next))
            return next
        }
    }

    func clearDashboard() throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM dashboard_sessions")
            try db.execute(sql: "DELETE FROM dashboard_connectors")
            try db.execute(sql: "DELETE FROM dashboard_projects")
            try db.execute(sql: "DELETE FROM dashboard_meta")
        }
    }

    /// Imports the legacy JSON archive once (when the library is empty).
    /// Returns whether rows were imported.
    func importDashboardArchive(_ archive: V2DashboardArchive) throws -> Bool {
        try pool.write { db in
            let imported = try String.fetchOne(
                db, sql: "SELECT value FROM dashboard_meta WHERE key = 'imported'")
            guard imported != "1" else { return false }
            // Upsert, never delete: a WS first frame may land before this
            // import and write newer rows; the old archive only fills gaps.
            var rows = 0
            for session in archive.sessions {
                try Self.insertSession(db, session)
                rows += 1
            }
            try Self.upsertConnectors(db, archive.connectors)
            try Self.upsertProjects(db, archive.projects)
            try Self.setMeta(db, key: "imported", value: "1")
            return rows > 0
        }
    }

    // MARK: - Internals

    private static func currentRevision(_ db: Database) throws -> Int {
        Int(try String.fetchOne(
            db, sql: "SELECT value FROM dashboard_meta WHERE key = 'revision'") ?? "0") ?? 0
    }

    private static func fetchDashboardRows(_ db: Database) throws -> DashboardRows {
        DashboardRows(
            connectors: try rows(db, "dashboard_connectors", as: V2Connector.self),
            projects: try rows(db, "dashboard_projects", as: V2Project.self),
            sessions: try rows(db, "dashboard_sessions", as: V2SessionMeta.self),
            revision: try currentRevision(db))
    }

    private static func rows<Value: Decodable>(_ db: Database, _ table: String,
                                               as type: Value.Type) throws -> [Value] {
        var result: [Value] = []
        for row in try Row.fetchAll(db, sql: "SELECT payload FROM \(table) ORDER BY rowid") {
            let payload: Data = row["payload"]
            do {
                result.append(try JSONDecoder().decode(Value.self, from: payload))
            } catch {
                ClientDiagnosticsLog.shared.record(
                    kind: "dashboard.row.dropped",
                    detail: ["table": table], dedupe: true)
            }
        }
        return result
    }

    private static func fetchHeldSessions(_ db: Database) throws -> [V2SessionMeta] {
        var result: [V2SessionMeta] = []
        for row in try Row.fetchAll(
            db, sql: "SELECT payload FROM dashboard_sessions ORDER BY session_id") {
            let payload: Data = row["payload"]
            do {
                result.append(try JSONDecoder().decode(V2SessionMeta.self, from: payload))
            } catch {
                ClientDiagnosticsLog.shared.record(
                    kind: "dashboard.row.dropped",
                    detail: ["table": "held"], dedupe: true)
            }
        }
        return result
    }

    private static func insertSession(_ db: Database, _ session: V2SessionMeta) throws {
        let payload = try encode(session)
        try db.execute(sql: """
            INSERT INTO dashboard_sessions
                (session_id, connector_id, archived, updated_seq, payload)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(session_id) DO UPDATE SET
                connector_id = excluded.connector_id, archived = excluded.archived,
                updated_seq = excluded.updated_seq, payload = excluded.payload
            WHERE excluded.updated_seq >= dashboard_sessions.updated_seq
            """, arguments: [session.id, session.connectorId, session.archived,
                             session.updatedSeq, payload])
    }

    private static func upsertConnectors(_ db: Database, _ values: [V2Connector]) throws {
        for value in values {
            let payload = try encode(value)
            try db.execute(sql: """
                INSERT INTO dashboard_connectors (id, payload) VALUES (?, ?)
                ON CONFLICT(id) DO UPDATE SET payload = excluded.payload
                """, arguments: [value.id, payload])
        }
    }

    private static func upsertProjects(_ db: Database, _ values: [V2Project]) throws {
        for value in values {
            let payload = try encode(value)
            try db.execute(sql: """
                INSERT INTO dashboard_projects (id, connector_id, payload)
                VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    connector_id = excluded.connector_id, payload = excluded.payload
                """, arguments: [value.id, value.connectorId, payload])
        }
    }

    private static func replaceConnectors(_ db: Database,
                                          _ values: [V2Connector]) throws -> Bool {
        // Duplicate ids in a server payload must not trap the app.
        var incoming: [String: V2Connector] = [:]
        for value in values { incoming[value.id] = value }
        var changed = false
        var existing: [String: Data] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, payload FROM dashboard_connectors") {
            existing[row["id"]] = row["payload"]
        }
        for (id, connector) in incoming {
            let payload = try encode(connector)
            guard existing[id] != payload else { continue }
            changed = true
            try db.execute(sql: """
                INSERT INTO dashboard_connectors (id, payload) VALUES (?, ?)
                ON CONFLICT(id) DO UPDATE SET payload = excluded.payload
                """, arguments: [id, payload])
        }
        for id in existing.keys where incoming[id] == nil {
            try db.execute(sql: "DELETE FROM dashboard_connectors WHERE id = ?", arguments: [id])
            changed = true
        }
        return changed
    }

    private static func replaceProjects(_ db: Database,
                                        _ values: [V2Project]) throws -> Bool {
        // Duplicate ids in a server payload must not trap the app.
        var incoming: [String: V2Project] = [:]
        for value in values { incoming[value.id] = value }
        var changed = false
        var existing: [String: Data] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, payload FROM dashboard_projects") {
            existing[row["id"]] = row["payload"]
        }
        for (id, project) in incoming {
            let payload = try encode(project)
            guard existing[id] != payload else { continue }
            changed = true
            try db.execute(sql: """
                INSERT INTO dashboard_projects (id, connector_id, payload)
                VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    connector_id = excluded.connector_id, payload = excluded.payload
                """, arguments: [id, project.connectorId, payload])
        }
        for id in existing.keys where incoming[id] == nil {
            try db.execute(sql: "DELETE FROM dashboard_projects WHERE id = ?", arguments: [id])
            changed = true
        }
        return changed
    }

    private static func setMeta(_ db: Database, key: String, value: String) throws {
        try db.execute(sql: """
            INSERT INTO dashboard_meta (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """, arguments: [key, value])
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        try JSONEncoder().encode(value)
    }

    /// Stable content signature: sorted-key JSON of every input row, folded
    /// into one FNV-1a value. Identical snapshots skip the transaction.
    private static func signature(_ input: DashboardIngestInput) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ data: Data) {
            for byte in data {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
        }
        var encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for connector in input.connectors {
            if let data = try? encoder.encode(connector) { mix(data) }
        }
        for project in input.projects {
            if let data = try? encoder.encode(project) { mix(data) }
        }
        for session in input.sessions {
            if let data = try? encoder.encode(session) { mix(data) }
        }
        return String(hash, radix: 16)
    }
}
