import SwiftUI
import UIKit

/// One message the user queued while the agent was still running. It sits at
/// the tail of the timeline, under the status line, right-aligned like a user
/// bubble (same 24 pt corner radius, same 17/12 padding). It carries its own
/// render for the three queue states:
///
/// - `.queued` — a plain dashed outline: no glyph, no label; order alone says
///   "waiting" (pp 2026-10-08: the clock is gone).
/// - `.sending` / `.awaitingEcho` — the shipped solid user bubble with a small
///   spinner in the corner; the state swap cross-fades in 0.25 s.
/// - a paused queue repaints the outline and shows an amber pause mark, so
///   "paused" reads without a second word of text.
///
/// Order alone communicates position: the row never prints "queued" or an
/// ordinal, and never shows a dismiss glyph. The long press is a native context
/// menu (copy / edit / withdraw) — no "send now".
struct QueuedMessageRow: View {
    let item: V2QueuedMessage
    let model: SessionChatModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppAccent.storageKey) private var accentValue = AppAccent.default.rawValue
    private var accent: AppAccent { AppAccent.resolve(accentValue) }

    /// The whole queue is paused: this row shows the paused outline and glyph,
    /// even while it is still only waiting its turn.
    private var isPaused: Bool { model.session.isSendQueuePaused }
    /// `.sending` and the echo-wait both render as the on-the-wire bubble.
    private var isOnWire: Bool { item.state != .queued }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Spacer(minLength: 48)
            Text(item.content)
                .font(.body)
                .foregroundStyle(isOnWire
                    ? AppTheme.accentTextColor(accent, colorScheme)
                    : AppTheme.secondaryText(colorScheme))
                // A long press belongs to the context menu, so this text is a
                // plain Text with selection off (never ChatSelectableText).
                .textSelection(.disabled)
                .padding(.horizontal, 17)
                .padding(.vertical, 12)
                // Reserve the bottom-trailing glyph's lane only when a glyph is
                // actually there (the pause mark or the spinner), so a plain
                // waiting bubble hugs its text like the user bubble does. The
                // queue keeps no clock: order alone says "waiting" (pp).
                .padding(.trailing, hasAccessory ? 16 : 0)
                .background { bubbleShape }
                .overlay(alignment: .bottomTrailing) {
                    if hasAccessory {
                        accessory.padding(.trailing, 9).padding(.bottom, 9)
                    }
                }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: item.state)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: isPaused)
        .contextMenu {
            Button(String(localized: "复制"), systemImage: "doc.on.doc") {
                UIPasteboard.general.string = item.content
            }
            Button(String(localized: "编辑"), systemImage: "pencil") {
                model.session.editQueuedMessage(id: item.id)
            }
            .disabled(isOnWire)
            Button(String(localized: "撤回"), systemImage: "trash", role: .destructive) {
                model.session.withdrawQueuedMessage(id: item.id)
            }
            .disabled(isOnWire)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(String(localized: "长按可复制、编辑或撤回"))
        .accessibilityIdentifier("chat.queue.row")
    }

    /// Dashed outline while waiting, solid bubble once on the wire — the same
    /// take as the user bubble, so the corner and metrics line up exactly.
    @ViewBuilder private var bubbleShape: some View {
        if isOnWire {
            RoundedRectangle(cornerRadius: 24)
                .fill(AppTheme.accentBubbleBackground(accent, colorScheme))
        } else {
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(queuedStroke, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }
    }

    private var queuedStroke: Color {
        isPaused ? AppTheme.warning(colorScheme) : AppTheme.secondaryControlStroke(colorScheme)
    }

    /// Whether the corner glyph is present at all: the spinner while on the
    /// wire, the pause mark while the queue is held. A plain waiting bubble
    /// carries none.
    private var hasAccessory: Bool { isOnWire || isPaused }

    @ViewBuilder private var accessory: some View {
        if isOnWire {
            ProgressView().progressViewStyle(.circular).controlSize(.small)
        } else {
            AppSymbol("exclamationmark.circle", size: 13)
                .foregroundStyle(AppTheme.warning(colorScheme))
        }
    }

    private var accessibilityLabel: String {
        let base = String(localized: "排队中的消息")
        return item.content.isEmpty ? base : "\(base)，\(item.content)"
    }

    private var accessibilityValue: String {
        if isPaused { return String(localized: "排队中的消息已暂停") }
        switch item.state {
        case .queued: return String(localized: "排队中")
        case .sending, .awaitingEcho: return String(localized: "正在发送消息")
        }
    }
}
