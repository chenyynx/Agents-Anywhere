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
    let cacheBytes: Int
    let stateBlob: Data
    let rows: [TimelineRow]
}

nonisolated struct TimelineMeta: Sendable {
    let cursor: String
    let hasOlderItems: Bool
    let hasNewerItems: Bool
    let excludesAgentChildren: Bool
    let pinned: Bool
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

    /// P1 shadow write: replace the session wholesale so the database is an
    /// exact mirror of the JSON archive. P2 adds the row-level diff.
    func replace(_ snapshot: TimelineSnapshot) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM timeline_items WHERE session_id = ?",
                           arguments: [snapshot.sessionID])
            for row in snapshot.rows {
                try db.execute(sql: """
                    INSERT INTO timeline_items
                        (session_id, item_id, order_seq, updated_seq, payload)
                    VALUES
                        (:sessionID, :itemID, :orderSeq, :updatedSeq, :payload)
                    """, arguments: [
                        "sessionID": snapshot.sessionID,
                        "itemID": row.id,
                        "orderSeq": row.orderSeq,
                        "updatedSeq": row.updatedSeq,
                        "payload": row.payload,
                    ])
            }
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
    }

    func read(sessionID: String, limit: Int) throws -> (meta: TimelineMeta, rows: [TimelineRow])? {
        try pool.read { db in
            guard let metaRow = try Row.fetchOne(db, sql: """
                SELECT cursor, has_older, has_newer, excludes_agent_children,
                       pinned, state_blob
                FROM session_meta WHERE session_id = ?
                """, arguments: [sessionID]) else { return nil }
            let meta = TimelineMeta(
                cursor: metaRow["cursor"],
                hasOlderItems: metaRow["has_older"],
                hasNewerItems: metaRow["has_newer"],
                excludesAgentChildren: metaRow["excludes_agent_children"],
                pinned: metaRow["pinned"],
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
