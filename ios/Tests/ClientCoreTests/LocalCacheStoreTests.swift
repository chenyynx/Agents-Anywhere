import Foundation
import Testing
@testable import ClientCore

@Suite @MainActor struct LocalCacheStoreTests {
    @Test func clearCacheKeepsTheDraftAndDropsRows() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aa-cache-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = V2LocalStore(directory: url, timelineDatabaseEnabled: true)
        let probe = repository(transport: TestHTTPTransport())
        let data = V2SessionData(snapshot: try snapshot(items: (1...10).map {
            try itemObject(id: "item-\($0)", order: $0)
        }))
        let session = probe.session(id: "session")
        session.draft = "keep my draft"
        await store.saveSession(V2SessionArchive(data: data, model: session))

        let usage = await store.clearCache()
        #expect(usage.bytes == 0)
        let restored = await store.restoreSession("session")
        #expect(restored?.items.isEmpty == true)
        #expect(restored?.archive.draft == "keep my draft")

        probe.reset()
        await store.close(removing: true)
    }

    @Test func trimKeepsTheStateJSONForEvictedSessions() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aa-cache-trim-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = V2LocalStore(directory: url, timelineDatabaseEnabled: true)
        let probe = repository(transport: TestHTTPTransport())
        for id in ["a", "b"] {
            let data = V2SessionData(snapshot: try snapshot(id: id, items: (1...5).map {
                try itemObject(id: "\(id)-\($0)", sessionID: id, order: $0)
            }))
            await store.saveSession(V2SessionArchive(data: data, model: probe.session(id: id)))
        }

        let evicted = await store.trimCache(to: 0)
        #expect(Set(evicted) == Set(["a", "b"]))
        let files = try FileManager.default.contentsOfDirectory(atPath: url.path)
        let sessionFiles = files.filter { $0.hasPrefix("session-") }
        #expect(sessionFiles.count == 2)
        for file in sessionFiles {
            let data = try Data(contentsOf: url.appendingPathComponent(file))
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let value = try #require(object["value"] as? [String: Any])
            #expect((value["items"] as? [Any])?.isEmpty == true)
        }
        let usage = await store.cacheUsage()
        #expect(usage.bytes == 0)

        probe.reset()
        await store.close(removing: true)
    }
}
