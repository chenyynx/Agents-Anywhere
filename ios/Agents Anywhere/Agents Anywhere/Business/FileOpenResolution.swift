import Foundation

/// The outcome of disambiguating a raw path from a message before opening it.
///
/// Kept as a pure value with no UI dependency so the mapping from a connector
/// `resolve-path` result to an open decision is unit-testable; the View only
/// switches on the result to preview, present a chooser, or surface a "not found".
enum FileOpenResolution: Equatable {
    /// A single file matched — open this absolute path directly.
    case open(String)
    /// Several files matched — the user must pick one of the candidates. The
    /// associated string is the original requested path (for display).
    case choose(String, [V2WorkspaceFileCandidate])
    /// Nothing matched. The associated string is the original requested path.
    case notFound(String)
}

extension FileOpenResolution {
    /// Maps a connector resolve result onto an open decision.
    ///
    /// `exact` with a usable path opens directly; `ambiguous` with candidates
    /// asks the user to choose; everything else (missing, `exact` without a
    /// path, `ambiguous` with no candidates) is a not-found — the client never
    /// guesses a target.
    static func make(requestedPath: String, result: V2WorkspaceResolveResult) -> FileOpenResolution {
        switch result.status {
        case "exact":
            if let path = result.path, !path.isEmpty { return .open(path) }
            return .notFound(requestedPath)
        case "ambiguous":
            if let candidates = result.candidates, !candidates.isEmpty { return .choose(requestedPath, candidates) }
            return .notFound(requestedPath)
        default:
            return .notFound(requestedPath)
        }
    }
}
