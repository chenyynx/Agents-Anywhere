import SwiftUI

/// The shared face for an in-card tool status line ("已截断" / "已加载完整
/// 文件" / failure).
///
/// Source: `0d8e.tool_truncated` = "Truncated" / "已截断"
/// (`EVIDENCE/strings-diff.csv:3548`). The official view at `0x102a4a92c` is
/// `Text + foregroundStyle(Color) + _FlexFrameLayout + _PaddingLayout`; the
/// pp screenshot (2026-11-01) pins the rest: bottom-left inside the card,
/// ~16 pt leading inset, ~12 pt vertical padding, 13 pt ink, and a dark
/// neutral (~sRGB 0.31) rather than SwiftUI's lighter `.secondary`. The
/// binary's color getter (`0x1029e4810`) is a token cache that does not expose
/// the RGB in the decoded path, so the literal comes from the screenshot.
struct ToolStatusText: View {
    let text: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Self.ink(for: colorScheme))
    }

    static func ink(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(.sRGB, red: 0.75, green: 0.75, blue: 0.74)
            : Color(.sRGB, red: 0.31, green: 0.31, blue: 0.30)
    }
}

/// One-line official truncation note: bottom-left inside the card.
struct ToolTruncatedNote: View {
    var body: some View {
        ToolStatusText(text: String(localized: "已截断"))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
    }
}

/// Shared wire questions around truncation, kept next to the note so the chat
/// fold and the Code detail answer them the same way.
nonisolated enum ToolTruncation {
    /// The wire tool name (`toolName` / `name` / `tool`), lowercased.
    static func toolName(_ item: V2TimelineItem?) -> String? {
        guard let content = item?.raw["content"] else { return nil }
        return [content["toolName"], content["name"], content["tool"]]
            .compactMap { $0?.stringValue }
            .first?
            .lowercased()
    }

    /// Read carries its own full-file wording; the load control is the same.
    static func isReadTool(_ item: V2TimelineItem?) -> Bool {
        let name = toolName(item)
        return name == "read" || name == "readfile"
    }
}
