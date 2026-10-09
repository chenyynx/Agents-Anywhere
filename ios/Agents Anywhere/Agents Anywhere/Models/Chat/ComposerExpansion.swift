import Foundation

/// The composer's expanded shape is derived, never a stored flag that can
/// stick: it is the current draft — focus, attachments, or genuinely multi-line
/// text. A whitespace-only draft (a lone newline an interrupted focus left
/// behind) counts as empty, so it can neither force the expanded bar open nor
/// hide the placeholder while the bar reads as blank.
nonisolated enum ComposerExpansion {
    /// Content that is more than whitespace. Spaces, tabs and newlines alone
    /// are empty — the same rule the send gate already uses, so the bar can no
    /// longer look empty (placeholder hidden) while the send key stays grey.
    static func hasContent(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// More than one line, judged from the draft's own line breaks with the
    /// surrounding whitespace ignored. It is deliberately NOT a pixel
    /// measurement: the bar's text width differs between the compact and
    /// expanded states, so a height judgement at one width could feed back into
    /// the expansion it is deciding (widen → a line fits → collapse → it wraps
    /// → expand …). A logical line count has no width to oscillate on.
    static func isMultiline(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).contains("\n")
    }

    /// Expanded while focused, while holding attachments, or while the draft
    /// has more than one line. A blank draft and a single-line draft collapse.
    static func isExpanded(isFocused: Bool, attachmentCount: Int, text: String) -> Bool {
        if isFocused || attachmentCount > 0 { return true }
        return hasContent(text) && isMultiline(text)
    }
}
