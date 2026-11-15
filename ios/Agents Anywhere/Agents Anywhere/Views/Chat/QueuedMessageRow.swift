import SwiftUI
import UIKit

/// One message the user queued while the agent was still running. It sits at
/// the tail of the timeline, under the status line, right-aligned like a user
/// bubble and built from the same bubble tokens (`CodePageTheme`), so leaving
/// the queue does not change its colour, face or height. It carries its own
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
///
/// Attachments sit above the bubble in the same Code attachment layout the
/// echo will draw. Their previews are local and already in the store, so an
/// image is visible while the queue waits even though its bytes have not
/// reached the server.
struct QueuedMessageRow: View {
    let item: V2QueuedMessage
    let model: SessionChatModel
    /// Queued sends have no server reference yet; the viewer resolves their
    /// local bytes by the queue id (`SessionChatView.openAttachment`).
    var onAttachment: (V2AttachmentContent, UIImage?) -> Void = { _, _ in }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The whole queue is paused: this row shows the paused outline and glyph,
    /// even while it is still only waiting its turn.
    private var isPaused: Bool { model.session.isSendQueuePaused }
    /// `.sending` and the echo-wait both render as the on-the-wire bubble.
    private var isOnWire: Bool { item.state != .queued }

    /// The queue row shows the same attachment block the echo will draw. The
    /// local preview is already in the store (`remember` runs at enqueue), so
    /// an image is visible before — and while — its bytes upload.
    private var resolvedAttachments: [ChatMessageAttachment] {
        model.session.attachmentPreviews.resolve(item.attachments.map(\.content),
                                                 clientID: item.id)
    }

    var body: some View {
        let attachments = resolvedAttachments
        HStack(alignment: .bottom, spacing: 8) {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 8) {
                if !attachments.isEmpty {
                    // Attachments keep the settled Code user row's shape and
                    // stay at `.complete`: the dashed bubble / queue banner
                    // already says "waiting", and dimming a queued image made
                    // it look broken (pp 2026-11-14).
                    CodeAttachmentRow(files: attachments,
                                      state: { _ in .complete },
                                      onAttachment: onAttachment,
                                      loadThumbnail: model.thumbnail)
                }
                if !item.content.isEmpty {
                    // The same text view, face and line metrics as the settled
                    // user bubble: the queue row used to draw with the app
                    // accent palette and the system face, so colour and height
                    // changed the moment the message left the queue. Selection
                    // stays off — the long press belongs to the queue menu.
                    CodeUserBubbleText(text: item.content,
                        color: isOnWire
                            ? CodePageTheme.userBubbleText.resolved(for: colorScheme)
                            : AppTheme.secondaryText(colorScheme),
                        isSelectable: false)
                        .padding(.horizontal, CodePageTheme.userBubbleHorizontalPadding)
                        .padding(.vertical, CodePageTheme.userBubbleVerticalPadding)
                        // Reserve the bottom-trailing glyph's lane only when a
                        // glyph is actually there (the pause mark or the
                        // spinner), so a plain waiting bubble hugs its text
                        // like the user bubble does. The queue keeps no clock:
                        // order alone says "waiting" (pp).
                        .padding(.trailing, hasAccessory ? 16 : 0)
                        .background { bubbleShape }
                        .overlay(alignment: .bottomTrailing) {
                            if hasAccessory {
                                accessory.padding(.trailing, 9).padding(.bottom, 9)
                            }
                        }
                }
            }
        }
        // A file card's soft shadow needs the same trailing lane the settled
        // Code row reserves; without it the tail cell clips the shadow.
        .padding(.trailing, attachments.contains { !$0.content.isImage }
            ? CodePageTheme.userRowShadowInset : 0)
        .overlay(alignment: .bottomLeading) {
            // An attachment-only queued message has no bubble to anchor on;
            // its spinner/pause glyph sits on the row's leading edge, like the
            // optimistic Code row.
            if item.content.isEmpty, !attachments.isEmpty, hasAccessory {
                accessory.padding(.leading, 9).padding(.bottom, 9)
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
            RoundedRectangle(cornerRadius: CodePageTheme.userBubbleCornerRadius)
                .fill(CodePageTheme.userBubbleFill.resolved(for: colorScheme))
        } else {
            RoundedRectangle(cornerRadius: CodePageTheme.userBubbleCornerRadius)
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
        var parts = [String(localized: "排队中的消息")]
        if !item.content.isEmpty { parts.append(item.content) }
        if !item.attachments.isEmpty {
            parts.append(String(localized: "\(item.attachments.count) 个附件"))
        }
        return parts.joined(separator: "，")
    }

    private var accessibilityValue: String {
        if isPaused { return String(localized: "排队中的消息已暂停") }
        switch item.state {
        case .queued: return String(localized: "排队中")
        case .sending, .awaitingEcho: return String(localized: "正在发送消息")
        }
    }
}
