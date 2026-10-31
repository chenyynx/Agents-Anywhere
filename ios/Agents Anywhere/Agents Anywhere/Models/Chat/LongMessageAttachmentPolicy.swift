import Foundation

/// A pasted log can be tens of thousands of characters. Rendering it as a
/// chat bubble measures and lays out the whole string on the main thread, and
/// the user sees the app freeze. Keep the outgoing message small: above a
/// threshold the text becomes one ordinary `.txt` attachment, so the bubble is
/// a file card and the file still reaches the agent.
nonisolated enum LongMessageAttachmentPolicy {
    /// Two screens of text is already past what a chat bubble should measure
    /// on the main thread. The 2026-10-31 b788 report rendered an 8 KB,
    /// ~100-line paste as a 7,916 pt bubble (+7,061 pt offset jump) because
    /// the old 12k/300 budget sat far above the rendering cost it guarded.
    static let characterThreshold = 2_000
    /// Logs are line-heavy; this catches a long paste that is under the
    /// character threshold but still dozens of rows tall.
    static let lineThreshold = 60
    static let maximumAttachments = 5

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

    /// Returns nil when the text is ordinary or the draft cannot take another
    /// attachment. The caller replaces the text with an empty string and
    /// appends this attachment, so the normal upload/send path owns delivery.
    static func makeAttachment(from text: String,
                               existingAttachmentCount: Int,
                               canAttach: Bool,
                               now: Date = Date()) -> ChatAttachment? {
        guard canAttach,
              existingAttachmentCount < maximumAttachments,
              shouldConvert(text) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "long-message-\(formatter.string(from: now)).txt"
        return ChatAttachment(name: name, data: Data(text.utf8), mediaType: "text/plain")
    }
}
