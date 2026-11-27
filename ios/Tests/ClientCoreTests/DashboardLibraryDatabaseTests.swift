import Foundation
import Testing
@testable import ClientCore

@Suite @MainActor struct DashboardLibraryDatabaseTests {
    private func temporaryPath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("aa-dashboard-db-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("timeline.sqlite")
    }

    private func database() throws -> TimelineDatabase {
        try TimelineDatabase(path: temporaryPath().path)
    }

    private func session(id: String, connectorId: String) throws -> V2SessionMeta {
        let object = try fixtureObject("snapshot")
        var session = object["session"] as! [String: Any]
        session["id"] = id
        session["connectorId"] = connectorId
        return try decode(session)
    }

    /// The fixture dashboard carries a single session; the delete/local tests
    /// need a second remote row, so build it from the same fixture.
    private func input() throws -> DashboardIngestInput {
        let snapshot: V2DashboardSnapshot = try decode(fixtureObject("dashboard"))
        var sessions = snapshot.sessions
        if let connector = snapshot.connectors.first {
            sessions.append(try session(id: "second", connectorId: connector.id))
        }
        return DashboardIngestInput(connectors: snapshot.connectors,
                                    projects: snapshot.projects,
                                    sessions: sessions)
    }

    private func mutated(_ session: V2SessionMeta, updatedSeq: Int,
                         title: String) throws -> V2SessionMeta {
        var object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(session)) as! [String: Any]
        object["updatedSeq"] = updatedSeq
        object["title"] = title
        return try JSONDecoder().decode(
            V2SessionMeta.self,
            from: JSONSerialization.data(withJSONObject: object))
    }

    private func localSession(connectorId: String) throws -> V2SessionMeta {
        let object = try fixtureObject("snapshot")
        var session = object["session"] as! [String: Any]
        session["id"] = "local:test"
        session["connectorId"] = connectorId
        session["updatedSeq"] = 1
        return try decode(session)
    }

    @Test func ingestWritesRowsAndRevision() throws {
        let database = try database()
        let value = try input()
        let outcome = try database.ingestDashboard(value)
        #expect(outcome.wrote)
        #expect(outcome.revision == 1)

        let rows = try database.dashboardRows()
        #expect(rows.revision == 1)
        #expect(rows.sessions.map(\.id).sorted() == value.sessions.map(\.id).sorted())
        #expect(rows.connectors.map(\.id).sorted() == value.connectors.map(\.id).sorted())
        #expect(rows.projects.map(\.id).sorted() == value.projects.map(\.id).sorted())
    }

    @Test func identicalSnapshotIsSkipped() throws {
        let database = try database()
        let value = try input()
        let first = try database.ingestDashboard(value)
        let second = try database.ingestDashboard(value)
        #expect(!second.wrote)
        #expect(second.revision == first.revision)
        #expect(try database.dashboardRows().revision == first.revision)
    }

    @Test func changedSessionUpdatesOnlyThatRow() throws {
        let database = try database()
        let value = try input()
        let target = try #require(value.sessions.first)
        _ = try database.ingestDashboard(value)

        var sessions = value.sessions
        sessions[sessions.firstIndex { $0.id == target.id }!] =
            try mutated(target, updatedSeq: target.updatedSeq + 1, title: "changed")
        let outcome = try database.ingestDashboard(DashboardIngestInput(
            connectors: value.connectors, projects: value.projects, sessions: sessions))

        #expect(outcome.wrote)
        #expect(outcome.changedSessionIDs == [target.id])
        #expect(outcome.sessionsChanged)
    }

    @Test func snapshotWithoutARemoteSessionDeletesIt() throws {
        let database = try database()
        let value = try input()
        #expect(value.sessions.count >= 2)
        let removed = value.sessions[0]
        let kept = Array(value.sessions.dropFirst())
        _ = try database.ingestDashboard(value)

        let outcome = try database.ingestDashboard(DashboardIngestInput(
            connectors: value.connectors, projects: value.projects, sessions: kept))
        #expect(outcome.sessionsChanged)
        #expect(!outcome.changedSessionIDs.contains(removed.id))
        let rows = try database.dashboardRows()
        #expect(!rows.sessions.contains { $0.id == removed.id })
    }

    @Test func localPendingSessionSurvivesASnapshot() throws {
        let database = try database()
        let value = try input()
        let connector = try #require(value.connectors.first)
        let local = try localSession(connectorId: connector.id)

        _ = try database.ingestDashboard(DashboardIngestInput(
            connectors: value.connectors, projects: value.projects,
            sessions: value.sessions + [local]))
        _ = try database.ingestDashboard(value)

        let rows = try database.dashboardRows()
        #expect(rows.sessions.contains { $0.id == local.id })
    }

    @Test func observationReadsTheCurrentRows() async throws {
        let database = try database()
        _ = try database.ingestDashboard(try input())
        var iterator = database.observeDashboard().makeAsyncIterator()
        let rows = await iterator.next()
        #expect(rows?.revision == 1)
        #expect(rows?.sessions.isEmpty == false)
    }

    @Test func archiveImportRunsOnce() throws {
        let database = try database()
        let value = try input()
        let archive = V2DashboardArchive(connectors: value.connectors,
                                         projects: value.projects,
                                         sessions: value.sessions, pages: [])
        #expect(try database.importDashboardArchive(archive))
        #expect(try !database.importDashboardArchive(archive))
        #expect(try database.dashboardRows().sessions.count == value.sessions.count)
    }

    @Test func clearRemovesEverything() throws {
        let database = try database()
        _ = try database.ingestDashboard(try input())
        try database.clearDashboard()
        let rows = try database.dashboardRows()
        #expect(rows.sessions.isEmpty)
        #expect(rows.connectors.isEmpty)
        #expect(rows.projects.isEmpty)
        #expect(rows.revision == 0)
    }

    /// The transcript-cache switch turns the row store off; the library must
    /// report "no store" so the app falls back instead of showing empty lists.
    @Test func storeWithoutADatabaseHasNoLibrary() async throws {
        let store = V2LocalStore(
            directory: temporaryPath().deletingLastPathComponent(),
            timelineDatabaseEnabled: false)
        #expect(await store.ingestDashboard(try input()) == nil)
        #expect(await store.observeDashboard() == nil)
        #expect(await store.dashboardRows() == nil)
    }

    /// A local mutation must survive an identical snapshot (the signature
    /// skip path), not be overwritten or deleted by it.
    @Test func identicalSnapshotKeepsMirroredMutations() async throws {
        let database = try database()
        let value = try input()
        _ = try database.ingestDashboard(value)
        let target = try #require(value.sessions.first)
        let renamed = try mutated(target, updatedSeq: target.updatedSeq,
                                  title: "local rename")
        _ = try database.upsertDashboardSessions([renamed])

        let outcome = try database.ingestDashboard(value)
        #expect(!outcome.wrote)
        let rows = try database.dashboardRows()
        #expect(rows.sessions.first { $0.id == target.id }?.title == "local rename")
    }
}
