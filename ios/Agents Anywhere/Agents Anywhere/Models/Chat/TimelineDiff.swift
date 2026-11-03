import Foundation

nonisolated struct TimelineDiff {
    struct Line: Identifiable, Hashable {
        enum Kind { case add, delete, hunk, file, context, annotation }
        let id: Int
        let kind: Kind
        let text: String
        let oldLine: Int?
        let newLine: Int?
        var sign: String { kind == .add ? "+" : kind == .delete ? "−" : "" }
    }
    let lines: [Line]
    private static let hunkHeader = try? NSRegularExpression(pattern: "^@@\\s+-(\\d+)(?:,\\d+)?\\s+\\+(\\d+)(?:,\\d+)?\\s+@@")
    init(_ code: String) {
        var oldLine: Int?, newLine: Int?
        lines = code.components(separatedBy: "\n").enumerated().map { index, text in
            let kind: Line.Kind
            if text.hasPrefix("@@") {
                kind = .hunk
                let ns = text as NSString
                let match = Self.hunkHeader?.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
                oldLine = match.flatMap { Int(ns.substring(with: $0.range(at: 1))) }
                newLine = match.flatMap { Int(ns.substring(with: $0.range(at: 2))) }
            } else if ["diff --git", "index ", "--- ", "+++ "].contains(where: text.hasPrefix) {
                kind = .file
                oldLine = nil; newLine = nil
            } else if text.hasPrefix("\\") { kind = .annotation }
            else if text.hasPrefix("+") { kind = .add }
            else if text.hasPrefix("-") { kind = .delete }
            else { kind = .context }
            let numbered = [.add, .delete, .context].contains(kind)
            let line = Line(id: index, kind: kind,
                text: kind == .add || kind == .delete || kind == .context && text.hasPrefix(" ") ? String(text.dropFirst()) : text,
                oldLine: numbered && kind != .add ? oldLine : nil, newLine: numbered && kind != .delete ? newLine : nil)
            if numbered {
                if kind != .add { oldLine = oldLine.map { $0 + 1 } }
                if kind != .delete { newLine = newLine.map { $0 + 1 } }
            }
            return line
        }
    }
    static func isUnified(_ code: String) -> Bool {
        code.components(separatedBy: "\n").contains { line in
            ["@@", "diff --git", "index ", "--- ", "+++ "].contains(where: line.hasPrefix)
                || line.range(of: "^[+-]\\S", options: .regularExpression) != nil
        }
    }

    /// Strong unified-diff evidence: a `diff --git` header, a numbered hunk
    /// header (`@@ -N`), or a `--- ` / `+++ ` header pair.
    ///
    /// A created file's content can carry lines that begin with `-`/`+`
    /// (Markdown bullets, front matter, code); `isUnified` alone would read
    /// those as patch lines and count body text as deletions. Callers that
    /// know the change action use this stricter test before treating the
    /// text as a patch.
    static func isStrictUnified(_ code: String) -> Bool {
        var hasOldHeader = false
        var hasNewHeader = false
        for line in code.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git") { return true }
            if line.hasPrefix("@@ -"), line.dropFirst(4).first?.isNumber == true { return true }
            if line.hasPrefix("--- ") { hasOldHeader = true }
            else if line.hasPrefix("+++ ") { hasNewHeader = true }
        }
        return hasOldHeader && hasNewHeader
    }
}
