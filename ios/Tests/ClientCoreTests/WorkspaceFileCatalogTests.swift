import Foundation
import Testing
@testable import ClientCore

@Suite @MainActor struct WorkspaceFileCatalogTests {
    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func api(_ http: TestHTTPTransport) -> V2ConnectorAPI { V2ConnectorAPI(transport: http) }

    private func service(_ http: TestHTTPTransport) -> V2WorkspaceFilesService {
        .init(connectorAPI: V2ConnectorAPI(transport: http), serverURL: URL(string: "https://example.test")!)
    }

    // MARK: - 1. Suffix set

    @Test func buildsEverySuffixAndSkipsDirectoryEntries() {
        let catalog = WorkspaceFileCatalog(files: ["a/b/c.md", "src/skip/", "src/keep/d.txt"])
        // All three suffixes of a/b/c.md.
        #expect(catalog.containsSuffix("a/b/c.md"))
        #expect(catalog.containsSuffix("b/c.md"))
        #expect(catalog.containsSuffix("c.md"))
        // A directory entry (trailing slash) contributes no suffix.
        #expect(!catalog.containsSuffix("src/skip"))
        #expect(!catalog.containsSuffix("skip/"))
        // A real file alongside a directory of the same leaf name still matches.
        #expect(catalog.containsSuffix("keep/d.txt"))
        // Unknown names never match.
        #expect(!catalog.containsSuffix("missing.md"))
    }

    // MARK: - 2. resolve

    @Test func resolveExactMatchOpensDirectly() {
        let catalog = WorkspaceFileCatalog(files: ["a/b/c.md"])
        #expect(FileReferenceResolution.resolve("a/b/c.md", catalog: catalog) == .open("a/b/c.md"))
    }

    @Test func resolveUniqueSuffixOpensTheCandidate() {
        let catalog = WorkspaceFileCatalog(files: ["apps/mobile/lib/main.dart", "apps/mobile/README.md"])
        #expect(FileReferenceResolution.resolve("lib/main.dart", catalog: catalog) == .open("apps/mobile/lib/main.dart"))
        #expect(FileReferenceResolution.resolve("main.dart", catalog: catalog) == .open("apps/mobile/lib/main.dart"))
    }

    @Test func resolveMultipleSuffixMatchesAsksTheUserInPathOrder() {
        let catalog = WorkspaceFileCatalog(files: ["y/messages.dart", "x/messages.dart"])
        #expect(FileReferenceResolution.resolve("messages.dart", catalog: catalog) == .choose(["x/messages.dart", "y/messages.dart"]))
    }

    @Test func resolveNoMatchOpensAsIsWithoutError() {
        let catalog = WorkspaceFileCatalog(files: ["a/b/c.md"])
        #expect(FileReferenceResolution.resolve("nope.md", catalog: catalog) == .openAsIs("nope.md"))
    }

    @Test func resolveNormalizesWindowsSeparators() {
        let catalog = WorkspaceFileCatalog(files: ["src/main.dart"])
        #expect(FileReferenceResolution.resolve("src\\main.dart", catalog: catalog) == .open("src/main.dart"))
        #expect(catalog.containsSuffix("main.dart"))
    }

    @Test func resolveDirectoryReferenceDoesNotMatchAFile() {
        // A reference that names a directory that exists in the list must not be
        // treated as a file match.
        let catalog = WorkspaceFileCatalog(files: ["src/", "src/main.dart"])
        #expect(FileReferenceResolution.resolve("src", catalog: catalog) == .openAsIs("src"))
    }

    // MARK: - 3. API decode

    @Test func decodesFileListResult() async throws {
        let http = TestHTTPTransport()
        http.respond = { _ in try self.data([
            "ok": true,
            "result": ["files": ["src/a.md", "src/b.md", "docs/"], "truncated": true, "totalFiles": 3],
        ]) }
        let response = try await api(http).workspaceFileList(connectorId: "device", root: "/work")
        #expect(response.ok && response.error == nil)
        let result = try #require(response.result)
        #expect(result.files == ["src/a.md", "src/b.md", "docs/"])
        #expect(result.truncated)
        #expect(result.totalFiles == 3)
    }

    @Test func fileListRequestUsesListFilesRouteWithVerbatimRoot() async throws {
        let http = TestHTTPTransport()
        http.respond = { _ in try self.data(["ok": true, "result": ["files": [], "truncated": false, "totalFiles": 0]]) }
        _ = try await api(http).workspaceFileList(connectorId: "device", root: "/home/ubuntu")
        let call = try #require(http.calls.first)
        #expect(call.method == .post)
        #expect(call.path == "/connectors/device/fs/list-files")
        #expect(call.query.first(where: { $0.name == "root" })?.value == "/home/ubuntu")
    }

    // MARK: - 4. fileList error handling

    @Test func fileListThrowsWhenResponseIsNotOk() async {
        let http = TestHTTPTransport()
        http.respond = { _ in try self.data(["ok": false, "error": ["code": "list_failed", "message": "boom"]]) }
        await #expect(throws: V2RuntimeError.self) {
            _ = try await self.service(http).fileList(connectorId: "device", root: "/work")
        }
    }

    @Test func fileListThrowsWhenResultIsMissing() async {
        let http = TestHTTPTransport()
        http.respond = { _ in try self.data(["ok": true]) }
        await #expect(throws: V2BusinessError.self) {
            _ = try await self.service(http).fileList(connectorId: "device", root: "/work")
        }
    }

    @Test func fileListReturnsResultOnSuccess() async throws {
        let http = TestHTTPTransport()
        http.respond = { _ in try self.data(["ok": true, "result": ["files": ["a.md"], "truncated": false, "totalFiles": 1]]) }
        let result = try await service(http).fileList(connectorId: "device", root: "/work")
        #expect(result.files == ["a.md"] && !result.truncated && result.totalFiles == 1)
    }

    // MARK: - 5. Model caching

    @Test func loadCachesCatalogPerKey() async throws {
        let http = TestHTTPTransport(), model = WorkspaceFileListModel()
        http.respond = { _ in try self.data(["ok": true, "result": ["files": ["src/main.dart"], "truncated": false, "totalFiles": 1]]) }
        let svc = service(http)

        #expect(model.catalog(connectorId: "device", root: "/work") == nil, "No catalog before load")

        await model.load(connectorId: "device", root: "/work", service: svc)
        let catalog = try #require(model.catalog(connectorId: "device", root: "/work"))
        #expect(catalog.containsSuffix("main.dart"))

        // A second load for the same key must not hit the network again.
        await model.load(connectorId: "device", root: "/work", service: svc)
        #expect(http.calls.count == 1)

        // A different key does fetch.
        await model.load(connectorId: "device", root: "/other", service: svc)
        #expect(http.calls.count == 2)
    }

    @Test func failedLoadIsSilentAndLeavesNoCatalog() async throws {
        let http = TestHTTPTransport(), model = WorkspaceFileListModel()
        http.respond = { _ in throw URLError(.timedOut) }
        await model.load(connectorId: "device", root: "/work", service: service(http))
        #expect(model.catalog(connectorId: "device", root: "/work") == nil)
    }
}
