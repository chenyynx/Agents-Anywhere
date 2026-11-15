import SwiftUI

/// The official interrupted-response notice (ClaudeChatUI.InterruptedResponseBanner).
///
/// Decompiled shape (26110919 Claude.app): `ChatMessageBanner` — one
/// `RoundedRectangle`-bordered line, a leading `info.circle` glyph and the
/// sentence 「<Agent> 的回复已中断。」. The official variant also
/// carries an optional Retry capsule; pp 2026-11-14 chose the notice-only
/// variant until the runtime gains a regenerate path.
///
/// Metrics are measured from the official screenshot (@3x, 393pt wide) and
/// cross-checked against the design-system constants:
/// - card width = content width (16pt page margins);
/// - height 40.3pt = 10pt vertical padding + a 20.8pt line box;
/// - 12pt horizontal padding, 20pt icon slot + 8pt gap;
/// - 13pt text, `info.circle` drawn at 16pt (the official 4px ring at @3x);
/// - #52514E ink, ~10% black hairline, 12pt continuous corners.
struct ChatInterruptedNoticeCard: View {
    /// The session's configured agent name ("Claude", "Codex", …). The
    /// official copy names the agent; AA must not hardcode Claude for
    /// non-Claude runtimes (pp 2026-11-14).
    let agentName: String

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    /// One-line card height with the 20.8pt line box. Used by the collection's
    /// pre-measure estimate; the row is measured for real once hosted.
    static let estimatedHeight: CGFloat = 41

    var body: some View {
        HStack(spacing: 8) {
            AppSymbol("info.circle", size: 16)
                .frame(width: 20, height: 20)

            Text("\(agentName) 的回复已中断。")
                .font(.custom(CodePageTheme.sansFontName,
                              size: 13,
                              relativeTo: .caption))
                .frame(minHeight: 20.8, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .foregroundStyle(ink)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(border, lineWidth: 1 / displayScale)
        }
        // The collection column already carries the official 16pt page inset
        // (CodeMessageRowView relies on the same column margin), so the card
        // spans it exactly like the official capture.
        .accessibilityElement(children: .combine)
    }

    /// Measured `#52514E` on the official light capture. Dark mode keeps the
    /// same contrast family as the transcript's secondary ink.
    private var ink: Color {
        colorScheme == .dark
            ? Color(.sRGB, red: 0.765, green: 0.761, blue: 0.718)
            : Color(.sRGB, red: 0.322, green: 0.318, blue: 0.306)
    }

    /// The card is border-only on the page background: the official fill is
    /// the same `#F9F9F7` as the page. 10% black light / 14% white dark.
    private var border: Color {
        colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.10)
    }
}
