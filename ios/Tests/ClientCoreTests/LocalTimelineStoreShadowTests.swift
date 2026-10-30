import Foundation
import Testing
@testable import ClientCore

@Suite @MainActor struct LocalTimelineStoreShadowTests {
    @Test func shadowWritesMirrorTheJSONArchive() async throws {
        let items = try (1...20).map {
            try itemObject(id: "item-\($0)", order: $0, seq: $0)
        }
        let projection = V2SessionProjection(
            snapshot: try snapshot(items: items), maximumItems: 20)
        let probe = repository(transport: TestHTTPTransport())
        let archive = V2SessionArchive(data: projection.data, model: probe.session(id: "session"))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aa-shadow-\(UUID().uuidString)", isDirectory: true)
        let store = V2LocalStore(directory: directory, maximumSessions: 20,
                                 timelineDatabaseEnabled: true)
        await store.saveSession(archive)
        await store.close(removing: false)

        let database = try TimelineDatabase(
            path: directory.appendingPathComponent("timeline.sqlite").path)
        defer {
            try? database.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let expectedIDs = archive.items.compactMap { raw in
            try? V2TimelineItem(json: raw).id
        }
        #expect(try database.rowIDs(sessionID: "session") == expectedIDs)
        #expect(try database.rowCount(sessionID: "session") == archive.items.count)

        let read = try #require(try database.read(sessionID: "session", limit: 100))
        let state = try #require(read.meta.stateBlob)
        let decoded = try JSONDecoder().decode(V2SessionArchive.self, from: state)
        #expect(decoded.items.isEmpty)
        #expect(decoded.session.id == archive.session.id)
    }

    @Test func disabledFlagWritesNoDatabase() async throws {
        let items = try (1...3).map { try itemObject(id: "item-\($0)", order: $0, seq: $0) }
        let projection = V2SessionProjection(
            snapshot: try snapshot(items: items), maximumItems: 3)
        let probe = repository(transport: TestHTTPTransport())
        let archive = V2SessionArchive(data: projection.data, model: probe.session(id: "session"))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aa-shadow-off-\(UUID().uuidString)", isDirectory: true)
        let store = V2LocalStore(directory: directory, maximumSessions: 20,
                                 timelineDatabaseEnabled: false)
        await store.saveSession(archive)
        await store.close(removing: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("timeline.sqlite").path))
    }

    @Test func shadowWritesAreIdempotent() async throws {
        let items = try (1...5).map { try itemObject(id: "item-\($0)", order: $0, seq: $0) }
        let projection = V2SessionProjection(
            snapshot: try snapshot(items: items), maximumItems: 5)
        let probe = repository(transport: TestHTTPTransport())
        let archive = V2SessionArchive(data: projection.data, model: probe.session(id: "session"))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aa-shadow-repeat-\(UUID().uuidString)", isDirectory: true)
        let store = V2LocalStore(directory: directory, maximumSessions: 20,
                                 timelineDatabaseEnabled: true)
        await store.saveSession(archive)
        await store.saveSession(archive)
        await store.close(removing: false)

        let database = try TimelineDatabase(
            path: directory.appendingPathComponent("timeline.sqlite").path)
        defer {
            try? database.close()
            try? FileManager.default.removeItem(at: directory)
        }
        #expect(try database.rowCount(sessionID: "session") == 5)
    }
}
