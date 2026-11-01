import SwiftUI

/// The official tool-result truncation note.
///
/// Source: `0d8e.tool_truncated` = "Truncated" / "已截断"
/// (`EVIDENCE/strings-diff.csv:3548`, ClaudeChatUI bundle). The official view
/// at `0x102a4a92c` builds `Text(LocalizedStringKey)` and applies
/// `foregroundStyle(Color)`, `_FlexFrameLayout` and `_PaddingLayout` (type
/// records `0x105c4b9f8` / `0x105c4bd50`; the padding constant is 12 at
/// `0x105a68220`). It sits inside the tool card at the bottom, centred in the
/// secondary ink — the Edit-detail screenshot (pp 2026-11-01) shows exactly
/// this.
///
/// This is not the Read full-file footnote (`tool_detail_read_truncated`,
/// "Showing %lld of %lld lines…"): that one belongs to the Read detail's
/// full-file control and stays in `DeferredLoadFooter`.
///
/// AA shows the note whenever what is on screen is cut: the server's deferred
/// summary, an `outputPreview`-only row, or the client's 200k preview cap. The
/// full-row load control (where one exists) is a separate AA affordance.
struct ToolTruncatedNote: View {
    /// The official `_PaddingLayout` value (`0x105a68220` = 12.0); the
    /// surrounding `_FlexFrameLayout` is the full-width centred frame.
    private static let verticalPadding: CGFloat = 12

    var body: some View {
        Text(String(localized: "已截断"))
            // [U] the exact font; the official type records do not name one.
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, Self.verticalPadding)
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

    /// Read carries its own full-file control and footnote, so it must not
    /// also take the generic in-card note.
    static func isReadTool(_ item: V2TimelineItem?) -> Bool {
        let name = toolName(item)
        return name == "read" || name == "readfile"
    }

    /// No full output value exists; the row carries only `outputPreview`.
    /// Mirrors `CodeToolOutput.outputPayload`'s full-value keys.
    static func isPreviewOnly(_ item: V2TimelineItem) -> Bool {
        let content = item.raw["content"] ?? .object([:])
        let hasFull = ["output", "outputText", "result", "text"].contains { key in
            guard let value = content[key], value != .null else { return false }
            switch value {
            case let .string(text): return !text.isEmpty
            case let .array(items): return !items.isEmpty
            case let .object(fields): return !fields.isEmpty
            default: return true
            }
        }
        guard let preview = content["outputPreview"], preview != .null else { return false }
        if case let .string(text) = preview, text.isEmpty { return false }
        return !hasFull
    }
}
