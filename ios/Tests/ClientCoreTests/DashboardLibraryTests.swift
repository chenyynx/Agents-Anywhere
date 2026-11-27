import Foundation
import Testing
@testable import ClientCore

@Suite @MainActor struct DashboardLibraryTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("aa-dashboard-library-\(UUID().uuidString)", isDirectory: true)
    }

    private func store() -> V2LocalStore {
        V2LocalStore(directory: directory(), timelineDatabaseEnabled: true)
    }

    private func input() throws -> DashboardIngestInput {
        let snapshot: V2DashboardSnapshot = try decode(fixtureObject("dashboard"))
        return DashboardIngestInput(connectors: snapshot.connectors,
                                    projects: snapshot.projects,
                                    sessions: snapshot.sessions)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func ingestPublishesRowsThroughObservation() async throws {
        let library = DashboardLibrary(store: store())
        library.start()
        defer { library.stop() }
        _ = await library.ingest(try input())
        await waitUntil { !library.sessions.isEmpty }
        #expect(!library.sessions.isEmpty)
        #expect(library.revision >= 1)
    }

    @Test func reconcileRunsAtPublishTime() async throws {
        let library = DashboardLibrary(store: store())
        library.reconcile = { value in
            var copy = value
            copy.lastReadSeq += 7
            return copy
        }
        library.start()
        defer { library.stop() }
        _ = await library.ingest(try input())
        await waitUntil { !library.sessions.isEmpty }
        let expected = try input().sessions.first?.lastReadSeq ?? 0
        #expect(library.sessions.first { $0.id == input().sessions.first?.id }?
            .lastReadSeq == expected + 7)
    }

    @Test func archiveSeedPublishesLegacyRows() async throws {
        let library = DashboardLibrary(store: store())
        library.start()
        defer { library.stop() }
        let value = try input()
        let archive = V2DashboardArchive(connectors: value.connectors,
                                         projects: value.projects,
                                         sessions: value.sessions, pages: [])
        _ = await library.seedFromArchive(archive)
        await waitUntil { !library.sessions.isEmpty }
        #expect(library.sessions.count == value.sessions.count)
    }
}
