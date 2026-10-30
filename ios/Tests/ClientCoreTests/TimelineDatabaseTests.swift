import Foundation
import Testing
@testable import ClientCore

@Suite @MainActor struct TimelineDatabaseTests {
    private func temporaryPath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("aa-timeline-db-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("timeline.sqlite")
    }

    private func snapshot(count: Int, sessionID: String = "session") throws -> TimelineSnapshot {
        try snapshot(indices: Array(1...count), sessionID: sessionID)
    }

    private func snapshot(indices: [Int], sessionID: String = "session") throws -> TimelineSnapshot {
        let rows = try indices.map { index in
            TimelineRow(
                id: "item-\(index)",
                orderSeq: index,
                updatedSeq: index,
                payload: try JSONSerialization.data(
                    withJSONObject: itemObject(id: "item-\(index)", order: index, seq: index)))
        }
        return TimelineSnapshot(
            sessionID: sessionID,
            cursor: "seq:10",
            hasOlderItems: true,
            hasNewerItems: false,
            excludesAgentChildren: false,
            pinned: false,
            lastAccess: 1_000,
            cacheBytes: Int64(rows.reduce(0) { $0 + $1.payload.count }),
            stateBlob: Data("state".utf8),
            rows: rows)
    }

    @Test func replaceAndReadTheNewestWindow() throws {
        let path = temporaryPath()
        let database = try TimelineDatabase(path: path.path)
        defer { try? database.close() }
        try database.replace(try snapshot(count: 10))

        let fetched = try database.read(sessionID: "session", limit: 3)
        let read = try #require(fetched)
        #expect(read.rows.map(\.orderSeq) == [8, 9, 10])
        #expect(read.meta.cursor == "seq:10")
        #expect(read.meta.hasOlderItems)
        #expect(!read.meta.hasNewerItems)
        #expect(read.meta.stateBlob == Data("state".utf8))
        #expect(try database.rowCount(sessionID: "session") == 10)
    }

    @Test func replaceIsAuthoritativeAndIdempotent() throws {
        let path = temporaryPath()
        let database = try TimelineDatabase(path: path.path)
        defer { try? database.close() }
        try database.replace(try snapshot(count: 10))
        try database.replace(try snapshot(count: 5))
        #expect(try database.rowCount(sessionID: "session") == 5)
        #expect(try database.rowIDs(sessionID: "session") == (1...5).map { "item-\($0)" })

        // Reopening the same file must not re-run the schema or clear rows.
        let reopened = try TimelineDatabase(path: path.path)
        defer { try? reopened.close() }
        #expect(try reopened.rowCount(sessionID: "session") == 5)
    }

    private func cacheSnapshot(sessionID: String, pinned: Bool,
                               lastAccess: Double, cacheBytes: Int64) -> TimelineSnapshot {
        TimelineSnapshot(
            sessionID: sessionID, cursor: "seq:1", hasOlderItems: false,
            hasNewerItems: false, excludesAgentChildren: false, pinned: pinned,
            lastAccess: lastAccess, cacheBytes: cacheBytes,
            stateBlob: Data("state".utf8),
            rows: [TimelineRow(id: "item-\(sessionID)", orderSeq: 1, updatedSeq: 1,
                               payload: Data(repeating: 0x78, count: 100))])
    }

    @Test func trimEvictsLeastRecentlyUsedUnpinnedSessions() throws {
        let path = temporaryPath()
        let database = try TimelineDatabase(path: path.path)
        defer { try? database.close() }
        try database.replace(cacheSnapshot(sessionID: "old", pinned: false,
                                           lastAccess: 1, cacheBytes: 100))
        try database.replace(cacheSnapshot(sessionID: "pinned", pinned: true,
                                           lastAccess: 0, cacheBytes: 100))
        try database.replace(cacheSnapshot(sessionID: "new", pinned: false,
                                           lastAccess: 3, cacheBytes: 100))
        #expect(try database.cacheUsage() == LocalCacheUsage(bytes: 300, sessions: 3))

        let evicted = try database.trim(to: 150)
        #expect(evicted == ["old", "new"])
        #expect(try database.cacheUsage().bytes == 100)
        #expect(try database.rowCount(sessionID: "pinned") == 1)
        #expect(try database.rowCount(sessionID: "old") == 0)
        #expect(try database.rowCount(sessionID: "new") == 0)
    }

    @Test func clearCacheKeepsPinnedRowsAndSessionMeta() throws {
        let path = temporaryPath()
        let database = try TimelineDatabase(path: path.path)
        defer { try? database.close() }
        try database.replace(cacheSnapshot(sessionID: "free", pinned: false,
                                           lastAccess: 2, cacheBytes: 100))
        try database.replace(cacheSnapshot(sessionID: "pinned", pinned: true,
                                           lastAccess: 1, cacheBytes: 100))

        let cleared = try database.clearCache(keepingPinned: true)
        #expect(cleared == ["free"])
        #expect(try database.rowCount(sessionID: "free") == 0)
        #expect(try database.rowCount(sessionID: "pinned") == 1)
        #expect(try database.read(sessionID: "free", limit: 10) != nil)
    }

    @Test func upsertKeepsRowsOutsideTheCurrentWindow() throws {
        let path = temporaryPath()
        let database = try TimelineDatabase(path: path.path)
        defer { try? database.close() }
        try database.replace(try snapshot(count: 300))
        try database.upsert(try snapshot(indices: Array(201...300)))
        #expect(try database.rowCount(sessionID: "session") == 300)
        #expect(try database.hasOlderRows(sessionID: "session", beforeOrderSeq: 201))
        #expect(try database.rowIDs(sessionID: "session").first == "item-1")
    }

    @Test func hasOlderRowsUsesTheOrderSeqBoundary() throws {
        let path = temporaryPath()
        let database = try TimelineDatabase(path: path.path)
        defer { try? database.close() }
        try database.replace(try snapshot(count: 10))
        let hasOlder = try database.hasOlderRows(sessionID: "session", beforeOrderSeq: 6)
        let noOlderAtStart = try database.hasOlderRows(sessionID: "session", beforeOrderSeq: 1)
        let noOlderForMissing = try database.hasOlderRows(sessionID: "missing", beforeOrderSeq: 6)
        #expect(hasOlder)
        #expect(!noOlderAtStart)
        #expect(!noOlderForMissing)
    }

    @Test func removeSessionDeletesItsRowsAndMeta() throws {
        let path = temporaryPath()
        let database = try TimelineDatabase(path: path.path)
        defer { try? database.close() }
        try database.replace(try snapshot(count: 3))
        try database.removeSession("session")
        #expect(try database.rowCount(sessionID: "session") == 0)
        #expect(try database.read(sessionID: "session", limit: 10) == nil)
    }

    @Test func readMissingSessionReturnsNil() throws {
        let path = temporaryPath()
        let database = try TimelineDatabase(path: path.path)
        defer { try? database.close() }
        #expect(try database.read(sessionID: "missing", limit: 10) == nil)
    }
}
