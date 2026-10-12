import Foundation

/// The outcome of resolving a raw file reference (bare name or relative path)
/// against a workspace file catalog before opening it.
///
/// A pure value with no UI dependency, mirroring `FileOpenResolution`, so the
/// mapping from a reference to an open decision is unit-testable. The caller
/// opens `.open`/`.openAsIs` directly and presents a chooser for `.choose`.
nonisolated enum FileReferenceResolution: Equatable {
    /// A single catalog entry matched — open this workspace-relative path.
    case open(String)
    /// Several entries matched — the user must pick one (sorted by path).
    case choose([String])
    /// Nothing matched — open the raw reference as-is; the server decides
    /// whether it exists, is a directory, or is missing, and reports back.
    case openAsIs(String)
}

/// The path-shape helpers shared by the render-time recognizer and the open
/// path, mirroring ccpocket's `file_path_syntax.dart` / `markdown_link_handler.dart`.
///
/// Everything here is pure and offline: it decides only whether a piece of text
/// *looks like* an absolute path or carries a trailing `:line:col`. Membership
/// against the real catalog is a separate step, so the "绝对路径不查名单"
/// rule (3.3b) stays explicit at each call site.
nonisolated enum FileReferenceRecognizer {
    /// A trailing `:line` / `:line:col` run (`:42`, `:42:8`).
    private static let lineColumnSuffix = try! NSRegularExpression(pattern: #"(?::\d+){1,2}$"#)
    /// A drive-letter (`C:\`) or UNC (`\\host`) prefix, mirroring ccpocket.
    private static let windowsAbsolute = try! NSRegularExpression(pattern: #"^[A-Za-z]:[/\\]"#)

    /// True when the reference is an absolute path — POSIX (`/…`), a Windows
    /// drive (`C:\…`), or a UNC share (`\\…`). Such a reference is always a
    /// file candidate and never consulted against the catalog (it may be
    /// truncated out of a very large workspace).
    static func isAbsolutePath(_ reference: String) -> Bool {
        let value = reference.replacingOccurrences(of: "\\", with: "/")
        return value.hasPrefix("/") || windowsAbsolute.firstMatch(in: reference, range: NSRange(reference.startIndex..., in: reference)) != nil
    }

    /// Removes a trailing `:line:col` suffix. A bare name with no suffix is
    /// returned unchanged.
    static func stripLineColumn(_ reference: String) -> String {
        let source = reference as NSString
        guard let match = lineColumnSuffix.firstMatch(in: reference, range: NSRange(location: 0, length: source.length)) else {
            return reference
        }
        return source.replacingCharacters(in: match.range, with: "")
    }

    /// Whether `content` should render as a clickable file reference:
    /// an absolute path, or a member of the catalog's suffix set (after the
    /// trailing `:line:col` is stripped). A directory name (dropped from the
    /// suffix set) never matches.
    static func recognize(_ content: String, catalog: WorkspaceFileCatalog) -> Bool {
        if isAbsolutePath(content) { return true }
        return catalog.containsSuffix(stripLineColumn(content))
    }
}

/// Scans text for the two render-time entries of §3.3b: backtick-quoted paths
/// (entry ①) and bare path-like tokens in prose (entry ②). Pure and offline, so
/// the recognition rules are unit-testable away from the SwiftUI view.
nonisolated enum FileReferenceScanner {
    /// Path-like token: word characters, dots, slashes and hyphens, ending in a
    /// dotted extension (`main.dart`, `lib/main.dart`). Mirrors ccpocket's
    /// `BareFilePathSyntax`. Because it must end in `.ext`, a URL, e-mail,
    /// version number, fraction, or a dotless phrase can never match as a whole.
    private static let barePathPattern = try! NSRegularExpression(pattern: #"[\w][\w./-]*\.[\w]+"#)

    /// Entry ① — a backtick-quoted (inline-code) run: the path to link when its
    /// content is an absolute path or a catalog member, else `nil` (stays
    /// plain code). The returned path has any `:line:col` suffix stripped.
    static func codeReference(_ text: String, catalog: WorkspaceFileCatalog) -> String? {
        guard FileReferenceRecognizer.recognize(text, catalog: catalog) else { return nil }
        return FileReferenceRecognizer.stripLineColumn(text)
    }

    /// Entry ② — bare tokens inside one plain-text run: the ranges of the
    /// path-like tokens that are exact catalog members. A bare name is a link
    /// only when it names a real workspace file, so ordinary prose keeps its
    /// text. Ranges are into `text`.
    static func bareReferences(in text: String, catalog: WorkspaceFileCatalog, limit: Int = .max) -> [Range<String.Index>] {
        let source = text as NSString
        var result: [Range<String.Index>] = []
        if limit <= 0 { return result }
        for match in barePathPattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let candidate = source.substring(with: match.range)
            guard catalog.containsSuffix(candidate), let range = Range(match.range, in: text) else { continue }
            result.append(range)
            if result.count >= limit { break }
        }
        return result
    }
}

/// An in-memory catalog of a workspace's file paths (relative to its root),
/// queryable by suffix so a bare filename or a partial path can be matched to
/// real files without touching the disk.
///
/// Mirrors ccpocket's `buildSuffixSet` / `resolveFilePeekPaths`: every path
/// `a/b/c.md` contributes the suffixes `a/b/c.md`, `b/c.md`, `c.md`. Directory
/// entries (paths ending in `/`) are dropped from the suffix set so a directory
/// name can never be matched as a file.
///
/// A pure, `Sendable` value type: the suffix set is built once when the catalog
/// is created (from a list that is already in memory) and never mutated, so a
/// catalog can cross actors — e.g. ride into the detached markdown-parse worker
/// — without a lock or a data race.
nonisolated struct WorkspaceFileCatalog: Equatable, Sendable {
    /// Relative-to-root POSIX paths, as returned by the connector.
    let files: [String]

    /// Precomputed suffix set (every suffix of every non-directory path).
    private let suffixes: Set<String>
    /// A per-instance identity box: copies share it, a freshly built catalog
    /// does not. Drives the equatable seams above the renderer (O(1)).
    private let box = IdentityBox()

    init(files: [String]) {
        self.files = files
        var set = Set<String>()
        for path in files where !path.hasSuffix("/") {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            for index in parts.indices {
                set.insert(parts[index...].joined(separator: "/"))
            }
        }
        suffixes = set
    }

    /// Identity equality, not value equality: a copy of a catalog equals its
    /// source, but a freshly built catalog is a change (its paths must re-link).
    /// O(1), so the per-render `.task(id:)` comparison never walks the file list.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.box === rhs.box }

    /// A cheap identity for the equatable seams above the renderer: two
    /// catalogs share it only when they are the same value (a copy), so a
    /// freshly loaded catalog is seen as a change and its paths re-link, while
    /// passing the same catalog down never forces a re-render.
    nonisolated var identity: ObjectIdentifier { ObjectIdentifier(box) }

    /// True when this reference (a file name or partial path) matches an entry
    /// in the catalog. A `\` is normalized to `/` first, so a Windows-style
    /// reference matches a POSIX catalog.
    func containsSuffix(_ reference: String) -> Bool {
        suffixes.contains(Self.normalize(reference))
    }

    /// The catalog entries a raw reference matches, best-first: an exact match,
    /// or entries whose full path ends with `/<reference>`, sorted by path.
    func suffixCandidates(for raw: String) -> [String] {
        let reference = Self.normalize(raw)
        guard !reference.isEmpty else { return [] }
        if files.contains(reference) { return [reference] }
        let suffix = reference.hasPrefix("/") ? reference : "/\(reference)"
        return files
            .filter { !$0.hasSuffix("/") && "/\($0)".hasSuffix(suffix) }
            .sorted()
    }

    /// Normalizes separators (`\` → `/`) and drops trailing slashes so a
    /// directory-style reference compares as its bare name.
    private static func normalize(_ reference: String) -> String {
        var value = reference.replacingOccurrences(of: "\\", with: "/")
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    /// An empty, immutable, per-instance reference token (identity only).
    nonisolated private final class IdentityBox: Sendable {}
}

nonisolated extension FileReferenceResolution {
    /// Resolves a raw file reference (bare name / relative path) against the
    /// catalog, mirroring ccpocket's `resolveFilePeekPaths`:
    ///
    /// 1. exact hit → open it;
    /// 2. suffix hit(s) → open the single candidate, or ask the user to choose;
    /// 3. no hit → open the reference as-is (never an error).
    ///
    /// Full absolute paths (leading `/`) are not routed through this catalog —
    /// the reference layer opens those directly.
    static func resolve(_ raw: String, catalog: WorkspaceFileCatalog) -> FileReferenceResolution {
        resolveWithCandidates(raw, catalog: catalog).resolution
    }

    /// As `resolve(_:catalog:)`, but also returns the matched catalog entries
    /// (best-first) so a caller can present or record them.
    static func resolveWithCandidates(
        _ raw: String,
        catalog: WorkspaceFileCatalog
    ) -> (resolution: FileReferenceResolution, candidates: [String]) {
        let candidates = catalog.suffixCandidates(for: raw)
        switch candidates.count {
        case 0: return (.openAsIs(raw), candidates)
        case 1: return (.open(candidates[0]), candidates)
        default: return (.choose(candidates), candidates)
        }
    }
}
