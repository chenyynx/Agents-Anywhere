import Foundation
import Testing
@testable import ClientCore

@Suite @MainActor struct InlineFileResolutionTests {
    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func api(_ http: TestHTTPTransport) -> V2ConnectorAPI { V2ConnectorAPI(transport: http) }

    private func service(_ http: TestHTTPTransport) -> V2WorkspaceFilesService {
        .init(connectorAPI: V2ConnectorAPI(transport: http), serverURL: URL(string: "https://example.test")!)
    }

    private func candidate(_ path: String, relative: String = "a", name: String = "a.md", score: Int = 10) -> [String: Any] {
        ["path": path, "relative": relative, "name": name, "score": score]
    }

    // MARK: - 1. API decode: exact / ambiguous / missing

    @Test func decodesExactResult() async throws {
        let http = TestHTTPTransport()
        http.respond = { _ in try self.data(["ok": true, "result": ["status": "exact", "path": "/work/src/a.md"]]) }
        let response = try await api(http).resolveWorkspacePath(connectorId: "device", root: "~",
            request: V2WorkspaceResolveRequest(path: "src/a.md"))
        #expect(response.ok && response.error == nil)
        let result = try #require(response.result)
        #expect(result.status == "exact" && result.path == "/work/src/a.md" && result.candidates == nil)
    }

    @Test func decodesAmbiguousResultWithRankedCandidates() async throws {
        let http = TestHTTPTransport()
        http.respond = { _ in try self.data(["ok": true, "result": ["status": "ambiguous", "candidates": [
            self.candidate("/work/a.md", relative: "a.md", name: "a.md", score: 30),
            self.candidate("/work/sub/a.md", relative: "sub/a.md", name: "a.md", score: 20),
        ]]]) }
        let response = try await api(http).resolveWorkspacePath(connectorId: "device", root: "~",
            request: V2WorkspaceResolveRequest(path: "a.md"))
        let result = try #require(response.result)
        #expect(result.status == "ambiguous" && result.path == nil)
        let candidates = try #require(result.candidates)
        #expect(candidates.map(\.path) == ["/work/a.md", "/work/sub/a.md"])
        #expect(candidates.map(\.score) == [30, 20])
        #expect(candidates.first?.relative == "a.md")
        #expect(candidates.first?.id == "/work/a.md")
    }

    @Test func decodesMissingResult() async throws {
        let http = TestHTTPTransport()
        http.respond = { _ in try self.data(["ok": true, "result": ["status": "missing"]]) }
        let response = try await api(http).resolveWorkspacePath(connectorId: "device", root: "~",
            request: V2WorkspaceResolveRequest(path: "nope.md"))
        let result = try #require(response.result)
        #expect(result.status == "missing" && result.path == nil && result.candidates == nil)
    }

    // MARK: - 2. Request construction (path kept verbatim)

    @Test func requestUsesResolvePathRouteWithVerbatimRootAndPath() async throws {
        let http = TestHTTPTransport()
        http.respond = { _ in try self.data(["ok": true, "result": ["status": "missing"]]) }
        // A bare filename and a `~` root must be sent as-is: no requestRoot rewriting.
        _ = try await api(http).resolveWorkspacePath(connectorId: "device", root: "~",
            request: V2WorkspaceResolveRequest(path: "app.py"))
        let call = try #require(http.calls.first)
        #expect(call.method == .post)
        #expect(call.path == "/connectors/device/fs/resolve-path")
        #expect(call.query.first(where: { $0.name == "root" })?.value == "~")
        #expect(call.body?["path"] == .string("app.py"))
    }

    @Test func serviceSendsOriginalRootAndRelativePathWithoutRequestRoot() async throws {
        let http = TestHTTPTransport()
        http.respond = { _ in try self.data(["ok": true, "result": ["status": "missing"]]) }
        // Even a Windows-absolute path that `requestRoot` would normally re-anchor
        // must reach the connector untouched — the connector owns resolution.
        _ = try await service(http).resolvePath(connectorId: "device", root: "/work", path: "D:\\docs\\a.md")
        let call = try #require(http.calls.first)
        #expect(call.query.first(where: { $0.name == "root" })?.value == "/work")
        #expect(call.body?["path"] == .string("D:\\docs\\a.md"))
    }

    // MARK: - 3. FileOpenResolution.make mapping

    @Test func exactWithPathOpens() {
        let resolution = FileOpenResolution.make(requestedPath: "a.md",
            result: V2WorkspaceResolveResult(status: "exact", path: "/work/src/a.md", candidates: nil))
        #expect(resolution == .open("/work/src/a.md"))
    }

    @Test func ambiguousWithCandidatesAsksTheUser() throws {
        let candidates = [
            V2WorkspaceFileCandidate(path: "/work/a.md", relative: "a.md", name: "a.md", score: 30),
            V2WorkspaceFileCandidate(path: "/work/sub/a.md", relative: "sub/a.md", name: "a.md", score: 20),
        ]
        let resolution = FileOpenResolution.make(requestedPath: "a.md",
            result: V2WorkspaceResolveResult(status: "ambiguous", path: nil, candidates: candidates))
        #expect(resolution == .choose("a.md", candidates))
    }

    @Test func exactWithoutPathIsNotFound() {
        let resolution = FileOpenResolution.make(requestedPath: "a.md",
            result: V2WorkspaceResolveResult(status: "exact", path: nil, candidates: nil))
        #expect(resolution == .notFound("a.md"))
    }

    @Test func missingIsNotFound() {
        let resolution = FileOpenResolution.make(requestedPath: "a.md",
            result: V2WorkspaceResolveResult(status: "missing", path: nil, candidates: nil))
        #expect(resolution == .notFound("a.md"))
    }

    @Test func ambiguousWithoutCandidatesIsNotFound() {
        let resolution = FileOpenResolution.make(requestedPath: "a.md",
            result: V2WorkspaceResolveResult(status: "ambiguous", path: nil, candidates: []))
        #expect(resolution == .notFound("a.md"))
    }

    // MARK: - 4. resolvePath error handling

    @Test func resolvePathThrowsWhenResponseIsNotOk() async {
        let http = TestHTTPTransport()
        http.respond = { _ in try self.data(["ok": false, "error": ["code": "resolve_failed", "message": "boom"]]) }
        await #expect(throws: V2RuntimeError.self) {
            _ = try await self.service(http).resolvePath(connectorId: "device", root: "~", path: "a.md")
        }
    }

    @Test func resolvePathThrowsWhenResultIsMissing() async {
        let http = TestHTTPTransport()
        http.respond = { _ in try self.data(["ok": true]) }
        await #expect(throws: V2BusinessError.self) {
            _ = try await self.service(http).resolvePath(connectorId: "device", root: "~", path: "a.md")
        }
    }

    @Test func resolvePathReturnsResultOnSuccess() async throws {
        let http = TestHTTPTransport()
        http.respond = { _ in try self.data(["ok": true, "result": ["status": "exact", "path": "/work/a.md"]]) }
        let result = try await service(http).resolvePath(connectorId: "device", root: "/work", path: "a.md")
        #expect(result.status == "exact" && result.path == "/work/a.md")
    }
}
