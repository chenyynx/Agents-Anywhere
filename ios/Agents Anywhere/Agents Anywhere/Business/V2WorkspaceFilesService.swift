import Foundation

struct V2WorkspaceFilesService {
    let connectorAPI: any V2ConnectorAPIProtocol
    let serverURL: URL

    /// Reads one directory from the connector through the server RPC boundary.
    func directory(
        connectorId: V2ConnectorID,
        root: String,
        path: String
    ) async throws -> V2WorkspaceDirectory {
        let response = try await connectorAPI.listWorkspaceFiles(
            connectorId: connectorId,
            request: V2WorkspaceFilesListRequest(root: ProjectWorkspacePath.requestRoot(root, path: path), path: path)
        )
        if let error = response.error, !response.ok { throw error }
        guard response.ok, let directory = response.result else {
            throw V2BusinessError.workspaceFilesUnavailable(
                message: String(localized: "The workspace directory is unavailable.")
            )
        }
        return directory
    }

    /// Fetches the whole workspace file catalog rooted at `root` in one call.
    ///
    /// The root is sent verbatim — like `resolvePath`, this deliberately skips
    /// `ProjectWorkspacePath.requestRoot`: the caller has already chosen the
    /// workspace root (session cwd / project path) and the connector lists
    /// exactly that directory.
    func fileList(connectorId: V2ConnectorID, root: String) async throws -> V2WorkspaceFileListResult {
        let response = try await connectorAPI.workspaceFileList(connectorId: connectorId, root: root)
        if let error = response.error, !response.ok { throw error }
        guard response.ok, let result = response.result else {
            throw V2BusinessError.workspaceFilesUnavailable(
                message: String(localized: "The workspace file list is unavailable.")
            )
        }
        return result
    }

    /// Disambiguates a raw path inside the workspace. The path and root are sent
    /// verbatim — resolving a bare filename to a real file is the connector's
    /// job, so this deliberately skips `ProjectWorkspacePath.requestRoot`.
    func resolvePath(
        connectorId: V2ConnectorID,
        root: String,
        path: String
    ) async throws -> V2WorkspaceResolveResult {
        let response = try await connectorAPI.resolveWorkspacePath(
            connectorId: connectorId, root: root, request: V2WorkspaceResolveRequest(path: path)
        )
        if let error = response.error, !response.ok { throw error }
        guard response.ok, let result = response.result else {
            throw V2BusinessError.workspaceFilesUnavailable(
                message: String(localized: "The workspace path could not be resolved.")
            )
        }
        return result
    }

    func readText(connectorId: V2ConnectorID, root: String, path: String, maxBytes: Int = 1_048_576) async throws -> V2WorkspaceTextResponse {
        guard (1...4_194_304).contains(maxBytes) else { throw V2BusinessError.invalidPageSize }
        return try await connectorAPI.readWorkspaceText(
            connectorId: connectorId, root: ProjectWorkspacePath.requestRoot(root, path: path),
            request: V2WorkspaceTextRequest(path: path, maxBytes: maxBytes)
        )
    }

    /// Explicit export/open-in action uses the full binary transfer, including for
    /// text files. The size-limited Web text preview is never used as a download.
    func download(connectorId: V2ConnectorID, root: String, entry: V2WorkspaceEntry) async throws -> WorkspaceDownloadedFile {
        guard entry.isFile else { throw V2BusinessError.workspaceEntryNotPreviewable }
        return try await connectorAPI.downloadWorkspaceFile(
            connectorId: connectorId, root: ProjectWorkspacePath.requestRoot(root, path: entry.path), path: entry.path)
    }

    /// Creates a one-use scoped token and returns the existing Web file-preview route.
    func previewURL(
        connectorId: V2ConnectorID,
        root: String,
        entry: V2WorkspaceEntry,
        location: SessionFileReference? = nil
    ) async throws -> URL {
        guard entry.isFile else { throw V2BusinessError.workspaceEntryNotPreviewable }
        let token = try await connectorAPI.createWorkspaceFilePreviewToken(
            connectorId: connectorId,
            root: ProjectWorkspacePath.requestRoot(root, path: entry.path),
            request: V2WorkspaceFileReadRequest(path: entry.path)
        )
        return try makePreviewURL(previewToken: token.previewToken, name: entry.name, location: location)
    }

    private func makePreviewURL(previewToken: String, name: String, location: SessionFileReference?) throws -> URL {
        let rootURL = URL(string: "/", relativeTo: serverURL)?.absoluteURL ?? serverURL
        guard var components = URLComponents(url: rootURL, resolvingAgainstBaseURL: false) else {
            throw V2BusinessError.invalidWorkspacePreviewURL
        }
        var fragmentComponents = URLComponents()
        fragmentComponents.queryItems = [
            URLQueryItem(name: "previewToken", value: previewToken),
            URLQueryItem(name: "name", value: name),
        ]
        if let line = location?.line { fragmentComponents.queryItems?.append(URLQueryItem(name: "line", value: String(line))) }
        if let column = location?.column { fragmentComponents.queryItems?.append(URLQueryItem(name: "column", value: String(column))) }
        guard let query = fragmentComponents.percentEncodedQuery else {
            throw V2BusinessError.invalidWorkspacePreviewURL
        }
        components.query = nil
        components.percentEncodedFragment = "/preview?\(query)"
        guard let url = components.url else {
            throw V2BusinessError.invalidWorkspacePreviewURL
        }
        return url
    }
}
