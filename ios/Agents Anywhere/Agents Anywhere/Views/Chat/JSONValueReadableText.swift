import Foundation

extension JSONValue {
    /// A stable, human-readable rendering of an arbitrary JSON value (sorted
    /// keys, unescaped slashes). Used where a notice's context is shown as
    /// plain text.
    var readableText: String {
        if case let .string(value) = self { return value }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
