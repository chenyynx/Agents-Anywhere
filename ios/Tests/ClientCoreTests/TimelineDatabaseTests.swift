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
        let rows = try (1...count).map { index in
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
            cacheBytes: rows.reduce(0) { $0 + $1.payload.count },
            stateBlob: Data("state".utf8),
            rows: rows)
    }

    @Test func replaceAndReadTheNewestWindow() throws {
        let path = temporaryPath()
        let database = try TimelineDatabase(path: path.path)
        defer { try? database.close() }
        try database.replace(try snapshot(count: 10))

        let read = try #require(try database.read(sessionID: "session", limit: 3))
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
