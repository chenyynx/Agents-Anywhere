import Foundation

/// A pasted log can be tens of thousands of characters. Rendering it as a
/// chat bubble measures and lays out the whole string on the main thread, and
/// the user sees the app freeze. Keep the outgoing message small: above a
/// threshold the text becomes one ordinary `.txt` attachment, so the bubble is
/// a file card and the file still reaches the agent.
///
/// The conversion is a local card, not a delivery promise: `ChatAttachment`
/// needs no runtime support. Whether the runtime can carry it is decided at
/// send time. Coupling the two (2026-11-22, b1485) meant every paste made
/// while capabilities were stale, while a new session was still preparing, or
/// on a runtime without attachment support fell through to the editor and let
/// TextKit measure the raw log until the scene-update watchdog killed the app
/// (`0x8BADF00D`, 4 MB paste, main thread in `NativeComposerEditor.sizeThatFits`).
nonisolated enum LongMessageAttachmentPolicy {
    /// Two screens of text is already past what a chat bubble should measure
    /// on the main thread. The 2026-10-31 b788 report rendered an 8 KB,
    /// ~100-line paste as a 7,916 pt bubble (+7,061 pt offset jump) because
    /// the old 12k/300 budget sat far above the rendering cost it guarded.
    static let characterThreshold = 2_000
    /// Logs are line-heavy; this catches a long paste that is under the
    /// character threshold but still dozens of rows tall.
    static let lineThreshold = 60
    /// Per-message attachment slots, shared by the pickers, the composer and
    /// the long-paste conversion. The server accepts ten refs per message
    /// (`server/agent_server/core/models.py`), so this is the client product
    /// limit and stays a single source instead of a repeated literal.
    static let maximumAttachments = 9
    /// The hard ceiling the editor is allowed to measure, whatever the path:
    /// paste, IME insertion, dictation, drop or a programmatic draft restore.
    /// Past this the composer is a liability, not an input. The number tracks
    /// the 2026-10-31 b788 incident (8 KB ≈ 7,916 pt bubble): anything larger
    /// is unusable as one bubble anyway, so refusing it loses no working path.
    static let maximumEditorCharacters = 8_000

    static func shouldConvert(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        if text.count >= characterThreshold { return true }
        var lines = 1
        for character in text where character == "\n" {
            lines += 1
            if lines >= lineThreshold { return true }
        }
        return false
    }

    static func exceedsEditorLimit(_ text: String) -> Bool {
        text.count > maximumEditorCharacters
    }

    /// What a paste must do before it reaches the editor. Delivery may be
    /// unknown (offline, capabilities not fresh, new session still preparing):
    /// a local file card is still the right shape, because it keeps the text
    /// out of TextKit and the send gate speaks once facts arrive.
    static func decidePaste(_ text: String,
                            existingAttachmentCount: Int,
                            delivery: AttachmentDelivery) -> LongPasteDecision {
        guard shouldConvert(text) else { return .insert }
        if delivery == .unavailable {
            // The runtime cannot deliver a file. Text a bubble can still
            // measure keeps today's behaviour; past the editor budget the
            // paste is refused instead of measured.
            return exceedsEditorLimit(text) ? .refused : .insert
        }
        if existingAttachmentCount < maximumAttachments { return .attachment }
        return exceedsEditorLimit(text) ? .refused : .insert
    }

    /// Returns nil when the text is ordinary or the draft cannot take another
    /// attachment. The caller replaces the text with an empty string and
    /// appends this attachment, so the normal upload/send path owns delivery.
    static func makeAttachment(from text: String,
                               existingAttachmentCount: Int,
                               now: Date = Date()) -> ChatAttachment? {
        guard existingAttachmentCount < maximumAttachments,
              shouldConvert(text) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "long-message-\(formatter.string(from: now)).txt"
        return ChatAttachment(name: name, data: Data(text.utf8), mediaType: "text/plain")
    }

    /// A card this policy created (not a user-picked file). It can go back to
    /// text if the runtime turns out not to accept attachments, so a paste
    /// converted while delivery was unknown never becomes a dead-end draft.
    static func isLongMessageAttachment(_ attachment: ChatAttachment) -> Bool {
        attachment.mediaType.hasPrefix("text/plain") && attachment.name.hasPrefix("long-message-")
    }

    /// The text behind a policy card, when folding it back would stay inside
    /// the editor budget. Nil for any other attachment or an oversized file.
    static func textFromLongMessageAttachment(_ attachment: ChatAttachment) -> String? {
        guard isLongMessageAttachment(attachment),
              let text = String(data: attachment.data, encoding: .utf8),
              !exceedsEditorLimit(text) else { return nil }
        return text
    }

    /// A draft saved before the editor budget existed (or by a build that let
    /// a long paste through) must never be handed back to TextKit verbatim:
    /// that is a launch-time watchdog kill, and because the draft is archived
    /// it repeats on every launch. Above the budget the draft becomes a file
    /// card when a slot is free; otherwise the head is kept so the app opens.
    static func sanitizeRestoredDraft(_ text: String,
                                      existingAttachmentCount: Int,
                                      now: Date = Date()) -> RestoredDraft {
        guard exceedsEditorLimit(text) else {
            return RestoredDraft(text: text, attachment: nil, didSanitize: false)
        }
        if let attachment = makeAttachment(from: text,
                                           existingAttachmentCount: existingAttachmentCount,
                                           now: now) {
            return RestoredDraft(text: "", attachment: attachment, didSanitize: true)
        }
        return RestoredDraft(text: String(text.prefix(maximumEditorCharacters)),
                             attachment: nil, didSanitize: true)
    }
}

/// Whether the runtime can carry a file attachment. Derived from live
/// capability facts, never from a provider name.
nonisolated enum AttachmentDelivery: Equatable {
    /// Fresh facts say the runtime supports attachments and permits them.
    case deliverable
    /// Fresh facts say it does not (no capability, or the permission is off).
    case unavailable
    /// No fresh snapshot yet (offline, reconnecting, new session preparing).
    case unknown

    var diagnosticName: String {
        switch self {
        case .deliverable: return "deliverable"
        case .unavailable: return "unavailable"
        case .unknown: return "unknown"
        }
    }
}

/// The paste decision itself is pure so the composer, the queue and the send
/// path share one rule instead of three slightly different guards.
nonisolated enum LongPasteDecision: Equatable {
    /// Ordinary text: let the editor take it.
    case insert
    /// The text left the editor as a `.txt` card.
    case attachment
    /// The paste was consumed and refused with an error; nothing is inserted.
    case refused
}

nonisolated struct RestoredDraft: Equatable {
    let text: String
    let attachment: ChatAttachment?
    let didSanitize: Bool
}
