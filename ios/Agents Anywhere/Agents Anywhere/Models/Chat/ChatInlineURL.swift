import Foundation

/// Recognises a URL that a reply wrapped in inline code.
///
/// The reference renders such a URL as grey text with a dotted underline, so it
/// has to become a real link before the highlighter runs. Only whole-cell
/// values match: `config.toml` stays code, `100.79.4.30:18765` stays code.
///
/// Shape follows the reference implementation: an `http(s)` scheme, or a bare
/// host ending in a common top-level domain, with an optional port and path.
nonisolated enum ChatInlineURL {
    private static let pattern = #"^(?:https?://\S+|(?:[A-Za-z0-9-]+\.)+(?:com|cn|net|org|io|dev|ai|app|co|me|xyz|info|edu|gov|tv|cc)(?::\d+)?(?:/\S*)?)$"#

    /// NSRegularExpression is not `Sendable`; the pattern is constant, so the
    /// instance is built once and only ever read.
    private final class Box: @unchecked Sendable {
        let regex = try! NSRegularExpression(pattern: ChatInlineURL.pattern)
    }
    private static let box = Box()

    static func url(for code: String) -> URL? {
        let range = NSRange(location: 0, length: (code as NSString).length)
        guard box.regex.firstMatch(in: code, range: range) != nil else { return nil }
        return URL(string: code.hasPrefix("http") ? code : "https://" + code)
    }
}
