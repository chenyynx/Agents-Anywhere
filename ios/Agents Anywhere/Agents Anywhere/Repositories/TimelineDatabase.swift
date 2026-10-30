import Foundation
import GRDB

/// One timeline row as stored in the local database. `payload` is the original
/// item JSON (`V2TimelineItem.raw`), so the row can be decoded back without a
/// second model.
nonisolated struct TimelineRow: Sendable, Equatable {
    let id: String
    let orderSeq: Int
    let updatedSeq: Int
    let payload: Data
}

/// The session metadata plus its rows. Built on the main actor from
/// `V2SessionArchive` and handed to the database actor.
nonisolated struct TimelineSnapshot: Sendable {
    let sessionID: String
    let cursor: String
    let hasOlderItems: Bool
    let hasNewerItems: Bool
    let excludesAgentChildren: Bool
    let pinned: Bool
    let lastAccess: Double
    let cacheBytes: Int64
    let stateBlob: Data
    let rows: [TimelineRow]
}

nonisolated struct TimelineMeta: Sendable {
    let cursor: String
    let hasOlderItems: Bool
    let hasNewerItems: Bool
    let excludesAgentChildren: Bool
    let pinned: Bool
    let lastAccess: Double
    let stateBlob: Data?
}

/// GRDB-backed row store. Owned by `V2LocalStore` and only ever called from its
/// actor, so no database work runs on the main actor.
nonisolated final class TimelineDatabase {
    private let pool: DatabasePool

    init(path: String) throws {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA busy_timeout = 1000")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            // New databases reclaim deleted rows instead of growing forever;
            // databases created before this pragma need a one-time VACUUM.
            try db.execute(sql: "PRAGMA auto_vacuum = FULL")
        }
        pool = try DatabasePool(path: path, configuration: configuration)
        try Self.migrator.migrate(pool)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_timeline_store") { db in
            try db.create(table: "session_meta") { table in
                table.column("session_id", .text).primaryKey()
                table.column("cursor", .text).notNull()
                table.column("has_older", .boolean).notNull()
                table.column("has_newer", .boolean).notNull()
                table.column("excludes_agent_children", .boolean).notNull().defaults(to: false)
                table.column("last_access", .double).notNull()
                table.column("pinned", .boolean).notNull().defaults(to: false)
                table.column("cache_bytes", .integer).notNull().defaults(to: 0)
                table.column("state_blob", .blob)
            }
            try db.create(table: "timeline_items") { table in
                table.column("session_id", .text).notNull()
                table.column("item_id", .text).notNull()
                table.column("order_seq", .integer).notNull()
                table.column("updated_seq", .integer).notNull()
                table.column("payload", .blob).notNull()
                table.primaryKey(["session_id", "item_id"])
            }
            try db.create(index: "timeline_items_window",
                          on: "timeline_items", columns: ["session_id", "order_seq"])
            try db.create(table: "schema_state") { table in
                table.column("key", .text).primaryKey()
                table.column("value", .blob)
            }
        }
        return migrator
    }

    /// Full replacement. Used for migrations/tests only; normal saves must
    /// upsert, because a slid in-memory window does not mean the rows outside
    /// it were deleted.
    func replace(_ snapshot: TimelineSnapshot) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM timeline_items WHERE session_id = ?",
                           arguments: [snapshot.sessionID])
            try Self.upsertRows(db, snapshot)
            try Self.upsertMeta(db, snapshot)
            try Self.updateCacheBytes(db, sessionID: snapshot.sessionID)
        }
    }

    /// Normal save: upsert the window's rows and metadata without deleting
    /// rows that are merely outside the current in-memory window.
    func upsert(_ snapshot: TimelineSnapshot) throws {
        try pool.write { db in
            try Self.upsertRows(db, snapshot)
            try Self.upsertMeta(db, snapshot)
            try Self.updateCacheBytes(db, sessionID: snapshot.sessionID)
        }
    }

    private static func upsertRows(_ db: Database, _ snapshot: TimelineSnapshot) throws {
        for row in snapshot.rows {
            try db.execute(sql: """
                INSERT INTO timeline_items
                    (session_id, item_id, order_seq, updated_seq, payload)
                VALUES
                    (:sessionID, :itemID, :orderSeq, :updatedSeq, :payload)
                ON CONFLICT(session_id, item_id) DO UPDATE SET
                    order_seq = excluded.order_seq,
                    updated_seq = excluded.updated_seq,
                    payload = excluded.payload
                WHERE excluded.updated_seq >= timeline_items.updated_seq
                """, arguments: [
                    "sessionID": snapshot.sessionID,
                    "itemID": row.id,
                    "orderSeq": row.orderSeq,
                    "updatedSeq": row.updatedSeq,
                    "payload": row.payload,
                ])
        }
    }

    private static func upsertMeta(_ db: Database, _ snapshot: TimelineSnapshot) throws {
        try db.execute(sql: """
            INSERT INTO session_meta
                (session_id, cursor, has_older, has_newer,
                 excludes_agent_children, last_access, pinned, cache_bytes, state_blob)
            VALUES
                (:sessionID, :cursor, :hasOlder, :hasNewer,
                 :excludesAgentChildren, :lastAccess, :pinned, :cacheBytes, :stateBlob)
            ON CONFLICT(session_id) DO UPDATE SET
                cursor = excluded.cursor,
                has_older = excluded.has_older,
                has_newer = excluded.has_newer,
                excludes_agent_children = excluded.excludes_agent_children,
                last_access = excluded.last_access,
                pinned = excluded.pinned,
                cache_bytes = excluded.cache_bytes,
                state_blob = excluded.state_blob
            """, arguments: [
                "sessionID": snapshot.sessionID,
                "cursor": snapshot.cursor,
                "hasOlder": snapshot.hasOlderItems,
                "hasNewer": snapshot.hasNewerItems,
                "excludesAgentChildren": snapshot.excludesAgentChildren,
                "lastAccess": snapshot.lastAccess,
                "pinned": snapshot.pinned,
                "cacheBytes": snapshot.cacheBytes,
                "stateBlob": snapshot.stateBlob,
            ])
    }

    func read(sessionID: String, limit: Int) throws -> (meta: TimelineMeta, rows: [TimelineRow])? {
        try pool.read { db in
            guard let metaRow = try Row.fetchOne(db, sql: """
                SELECT cursor, has_older, has_newer, excludes_agent_children,
                       pinned, last_access, state_blob
                FROM session_meta WHERE session_id = ?
                """, arguments: [sessionID]) else { return nil }
            let meta = TimelineMeta(
                cursor: metaRow["cursor"],
                hasOlderItems: metaRow["has_older"],
                hasNewerItems: metaRow["has_newer"],
                excludesAgentChildren: metaRow["excludes_agent_children"],
                pinned: metaRow["pinned"],
                lastAccess: metaRow["last_access"],
                stateBlob: metaRow["state_blob"])
            let rows = try Row.fetchAll(db, sql: """
                SELECT item_id, order_seq, updated_seq, payload
                FROM timeline_items
                WHERE session_id = ?
                ORDER BY order_seq DESC, item_id DESC
                LIMIT ?
                """, arguments: [sessionID, max(1, limit)]).map { row in
                    TimelineRow(id: row["item_id"],
                                orderSeq: row["order_seq"],
                                updatedSeq: row["updated_seq"],
                                payload: row["payload"])
                }.reversed()
            return (meta: meta, rows: Array(rows))
        }
    }

    func olderRows(sessionID: String, beforeOrderSeq: Int, limit: Int) throws -> [TimelineRow] {
        try pool.read { db in
            Array(try Row.fetchAll(db, sql: """
                SELECT item_id, order_seq, updated_seq, payload
                FROM timeline_items
                WHERE session_id = ? AND order_seq < ?
                ORDER BY order_seq DESC, item_id DESC
                LIMIT ?
                """, arguments: [sessionID, beforeOrderSeq, max(1, limit)])
                .map(Self.timelineRow)
                .reversed())
        }
    }

    func latestRows(sessionID: String, limit: Int) throws -> [TimelineRow] {
        try pool.read { db in
            Array(try Row.fetchAll(db, sql: """
                SELECT item_id, order_seq, updated_seq, payload
                FROM timeline_items
                WHERE session_id = ?
                ORDER BY order_seq DESC, item_id DESC
                LIMIT ?
                """, arguments: [sessionID, max(1, limit)])
                .map(Self.timelineRow)
                .reversed())
        }
    }

    private static func timelineRow(_ row: Row) -> TimelineRow {
        TimelineRow(id: row["item_id"], orderSeq: row["order_seq"],
                    updatedSeq: row["updated_seq"], payload: row["payload"])
    }

    /// True when the store holds at least one row older than `beforeOrderSeq`.
    /// The window read only returns the newest rows; this is the cheap
    /// `EXISTS` query the paging path uses to know whether to read disk next.
    /// The state-only archive (draft/pending/queue/notifications) for a
    /// session whose cached rows were cleared. Used to keep the JSON rollback
    /// path useful after a cache clear/eviction.
    func stateArchive(sessionID: String) throws -> V2SessionArchive? {
        try pool.read { db in
            guard let state = try Data.fetchOne(db, sql: """
                SELECT state_blob FROM session_meta WHERE session_id = ?
                """, arguments: [sessionID]),
                  var archive = try? JSONDecoder().decode(V2SessionArchive.self, from: state) else {
                return nil
            }
            // The rows are gone; an online open must fetch the latest page
            // rather than present an empty window.
            archive.hasOlderItems = true
            return archive
        }
    }

    func setPinned(sessionID: String, pinned: Bool) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE session_meta SET pinned = ? WHERE session_id = ?
                """, arguments: [pinned, sessionID])
        }
    }

    func touch(sessionID: String, at timestamp: Double) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE session_meta SET last_access = ? WHERE session_id = ?
                """, arguments: [timestamp, sessionID])
        }
    }

    func hasOlderRows(sessionID: String, beforeOrderSeq: Int) throws -> Bool {
        try pool.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(
                    SELECT 1 FROM timeline_items
                    WHERE session_id = ? AND order_seq < ?
                )
                """, arguments: [sessionID, beforeOrderSeq]) ?? false
        }
    }

    func cacheUsage() throws -> LocalCacheUsage {
        try pool.read { db in
            let bytes = try Int64.fetchOne(db, sql: """
                SELECT COALESCE(SUM(cache_bytes), 0) FROM session_meta
                """) ?? 0
            let sessions = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM session_meta WHERE cache_bytes > 0
                """) ?? 0
            return LocalCacheUsage(bytes: bytes, sessions: sessions)
        }
    }

    /// Enforces the per-session row cap, then evicts unpinned sessions from
    /// least-recently-used to most recent until the byte budget fits. Returns
    /// the session IDs whose rows were evicted so the caller can remove their
    /// legacy JSON cache too.
    func trim(to limitBytes: Int64) throws -> [String] {
        try pool.write { db in
            let sessions = try Row.fetchAll(db, sql: "SELECT session_id, pinned FROM session_meta")
            for row in sessions {
                let pinned: Bool = row["pinned"]
                guard !pinned else { continue }
                let id: String = row["session_id"]
                let count = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM timeline_items WHERE session_id = ?
                    """, arguments: [id]) ?? 0
                guard count > 5000 else { continue }
                try db.execute(sql: """
                    DELETE FROM timeline_items
                    WHERE session_id = ? AND item_id IN (
                        SELECT item_id FROM timeline_items
                        WHERE session_id = ? ORDER BY order_seq ASC, item_id ASC LIMIT ?
                    )
                    """, arguments: [id, id, count - 5000])
                try Self.updateCacheBytes(db, sessionID: id)
            }

            var total = try Int64.fetchOne(db, sql: """
                SELECT COALESCE(SUM(cache_bytes), 0) FROM session_meta
                """) ?? 0
            guard total > limitBytes else { return [] }
            let candidates = try Row.fetchAll(db, sql: """
                SELECT session_id, cache_bytes FROM session_meta
                WHERE pinned = 0 AND cache_bytes > 0
                ORDER BY last_access ASC
                """)
            var evicted: [String] = []
            for row in candidates {
                guard total > limitBytes else { break }
                let id: String = row["session_id"]
                let bytes: Int64 = row["cache_bytes"]
                try Self.stripCacheableState(db, sessionID: id)
                try db.execute(sql: "DELETE FROM timeline_items WHERE session_id = ?",
                               arguments: [id])
                // Keep the meta (drafts/queue) but flag that the window is no
                // longer complete, so an online open re-reads the latest page
                // instead of presenting an empty timeline.
                try db.execute(sql: """
                    UPDATE session_meta SET cache_bytes = 0, has_older = 1
                    WHERE session_id = ?
                    """, arguments: [id])
                total -= bytes
                evicted.append(id)
            }
            return evicted
        }
    }

    /// Drops cached rows, activity and previews while keeping drafts, queued
    /// messages and notification state. Returns the cleared session IDs.
    func clearCache(keepingPinned: Bool) throws -> [String] {
        try pool.write { db in
            let sql = keepingPinned
                ? "SELECT session_id, state_blob FROM session_meta WHERE pinned = 0"
                : "SELECT session_id, state_blob FROM session_meta"
            let rows = try Row.fetchAll(db, sql: sql)
            var cleared: [String] = []
            for row in rows {
                let id: String = row["session_id"]
                try Self.stripCacheableState(db, sessionID: id)
                try db.execute(sql: """
                    UPDATE session_meta SET cache_bytes = 0, has_older = 1
                    WHERE session_id = ?
                    """, arguments: [id])
                try db.execute(sql: "DELETE FROM timeline_items WHERE session_id = ?",
                               arguments: [id])
                cleared.append(id)
            }
            return cleared
        }
    }

    /// Removes the cacheable halves of the state blob (SubAgent activity and
    /// attachment previews) while keeping drafts, queued messages and
    /// notification state.
    private static func stripCacheableState(_ db: Database, sessionID: String) throws {
        guard let state = try Data.fetchOne(db, sql: """
            SELECT state_blob FROM session_meta WHERE session_id = ?
            """, arguments: [sessionID]),
              var archive = try? JSONDecoder().decode(V2SessionArchive.self, from: state) else {
            return
        }
        archive.subAgentActivity = nil
        archive.previews = nil
        guard let stripped = try? JSONEncoder().encode(archive) else { return }
        try db.execute(sql: """
            UPDATE session_meta SET state_blob = ? WHERE session_id = ?
            """, arguments: [stripped, sessionID])
    }

    private static func updateCacheBytes(_ db: Database, sessionID: String) throws {
        let payload = try Int64.fetchOne(db, sql: """
            SELECT COALESCE(SUM(length(payload)), 0) FROM timeline_items
            WHERE session_id = ?
            """, arguments: [sessionID]) ?? 0
        var extra: Int64 = 0
        if let state = try Data.fetchOne(db, sql: """
            SELECT state_blob FROM session_meta WHERE session_id = ?
            """, arguments: [sessionID]),
           let archive = try? JSONDecoder().decode(V2SessionArchive.self, from: state) {
            if let activity = archive.subAgentActivity,
               let bytes = try? JSONEncoder().encode(activity) {
                extra += Int64(bytes.count)
            }
            if let previews = archive.previews,
               let bytes = try? JSONEncoder().encode(previews) {
                extra += Int64(bytes.count)
            }
        }
        try db.execute(sql: """
            UPDATE session_meta SET cache_bytes = ? WHERE session_id = ?
            """, arguments: [payload + extra, sessionID])
    }

    func rowCount(sessionID: String) throws -> Int {
        try pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM timeline_items WHERE session_id = ?
                """, arguments: [sessionID]) ?? 0
        }
    }

    func rowIDs(sessionID: String) throws -> [String] {
        try pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT item_id FROM timeline_items
                WHERE session_id = ? ORDER BY order_seq, item_id
                """, arguments: [sessionID])
        }
    }

    func removeSession(_ sessionID: String) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM timeline_items WHERE session_id = ?",
                           arguments: [sessionID])
            try db.execute(sql: "DELETE FROM session_meta WHERE session_id = ?",
                           arguments: [sessionID])
        }
    }

    func close() throws {
        try pool.close()
    }
}
