import SwiftUI
import UIKit

/// The row under a finished reply: copy, like, dislike, branch, then the time.
///
/// The timeline's hosting path wraps `SessionTurnActions`; the TextKit path
/// hosts `SessionTurnActionsRow` directly with the same copy text and
/// timestamp, so both renderers share one implementation.
struct SessionTurnActions: View, Equatable {
    let action: TimelineTurnAction

    /// The timeline compares rows to skip body evaluation; the copy flash is
    /// local state and must not force a recompare.
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.action == rhs.action }

    var body: some View {
        SessionTurnActionsRow(copyText: action.copyText,
                              timestampText: action.timestampText)
    }
}

/// The row itself, split out so a UIKit cell can host it without owning a
/// `TimelineTurnAction` (which carries the turn's row models).
///
/// Layout follows the reference at 1:1 — the icons are absolutely placed
/// because their optical spacing is tighter than an `HStack` produces: the
/// glyph pitch is roughly 25pt, so a 44pt target on every glyph would overlap
/// its neighbour. Targets are therefore sized to the gap the reference leaves
/// between glyphs (about 26×28pt) and pushed apart by `contentShape`, which
/// grows the hit region without moving the drawing.
///
/// Like, dislike and branch are **placeholders**: no backend exists for them
/// yet. They render and announce themselves but do nothing.
struct SessionTurnActionsRow: View {
    let copyText: String
    let timestampText: String
    @State private var copied = false
    @State private var copyFeedback = 0

    /// The row's laid-out height: the action line plus its bottom gap. The
    /// TextKit measurement uses this exact number instead of fitting the
    /// hosting view.
    static let rowHeight = ChatMetrics.actionRowHeight + ChatMetrics.actionRowBottomGap

    /// Horizontal centre-to-centre pitch, from the reference glyph offsets.
    private static let pitch: CGFloat = 25
    /// The tap target: the full pitch wide, and tall enough to be comfortable
    /// without overlapping the row above. Below Apple's 44pt guidance, which is
    /// a deliberate trade for the reference's tight optical spacing.
    private static let target = CGSize(width: 25, height: 28)

    var body: some View {
        ZStack(alignment: .topLeading) {
            button(ChatIcon.copy, x: -0.67, y: 5.17, label: String(localized: "复制回复"), showsConfirmation: copied) {
                UIPasteboard.general.string = copyText
                copied = true
                copyFeedback += 1
            }
            button(ChatIcon.thumbUp, x: 24.67, y: 5.17, label: String(localized: "赞")) {}
            button(ChatIcon.thumbDown, x: 50, y: 5.17, label: String(localized: "踩")) {}
            button(ChatIcon.shuffle, x: 74.33, y: 5.83, label: String(localized: "重新生成")) {}
            // No wire timestamp renders nothing rather than an empty frame, so
            // the row collapses to its icons instead of reserving blank space.
            if !timestampText.isEmpty {
                Text(timestampText)
                    .font(.system(size: ChatMetrics.timestampSize))
                    .foregroundStyle(ChatPalette.iconSecondary.color)
                    .frame(height: ChatMetrics.actionRowHeight)
                    .offset(x: 99.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: ChatMetrics.actionRowHeight, alignment: .topLeading)
        // `[pp 2026-10-18]` the group's own 4pt spacing already separates this
        // row from the file summary above it, which is the same 4pt that
        // separates the prose from that summary. No extra padding: the two
        // gaps are equal by construction rather than by a hand-matched value.
        .padding(.bottom, ChatMetrics.actionRowBottomGap)
        .disabled(copyText.isEmpty)
        // [E] Official copy feedback is `.selection`
        // (EVIDENCE/round19/motion.md §P2-9).
        .sensoryFeedback(.selection, trigger: copyFeedback)
        .accessibilityIdentifier("chat.turn.actions")
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(2)); copied = false } catch {}
        }
    }

    /// The glyph keeps the reference position; the target is centred on it so
    /// the drawing never moves when the hit area changes.
    private func button(
        _ icon: TracedIcon,
        x: CGFloat,
        y: CGFloat,
        label: String,
        showsConfirmation: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            TracedIconView(
                icon: icon,
                color: showsConfirmation ? .accentColor : ChatPalette.iconSecondary.color
            )
            .frame(width: Self.target.width, height: Self.target.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .offset(
            x: x - (Self.target.width - icon.size.width) / 2,
            y: y - (Self.target.height - icon.size.height) / 2
        )
    }
}
