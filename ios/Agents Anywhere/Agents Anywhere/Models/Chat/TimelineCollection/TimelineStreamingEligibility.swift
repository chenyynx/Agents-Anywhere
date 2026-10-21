import Foundation

/// Admission rule for the streaming TextKit row. Kept pure and in ClientCore
/// so the rule has unit coverage; the adapter supplies the current row facts.
///
/// The row stays eligible through the final reveal batch: either the legacy
/// reveal flag or the renderer-owned cursor (`isRevealPending`) keeps it on
/// the TextKit cell after `status == .done`, so committing does not cut the
/// animation or hand the message to a fresh hosting view for one frame.
nonisolated enum TimelineStreamingEligibility {
    /// - Parameter footerSupported: the turn-action footer can be rendered by
    ///   this row (M4.3 extends this from text-only to file-change summaries).
    /// - Parameter holdsEngineThroughDisqualifiers: the renderer-owned reveal
    ///   still owns the row. A notice, an attachment or a newly eligible
    ///   footer must not yank the row to the hosting path mid-reveal: the
    ///   presentation has already published the full received text, so the
    ///   switch would dump every remaining character at once. The row hands
    ///   off when ownership clears (reveal caught up + fade finished).
    ///   A sticky fallback is never held: there is no document to keep alive.
    static func admits(isSingleRowGroup: Bool,
                       isAssistantMessage: Bool,
                       isStreamingText: Bool,
                       isRevealing: Bool,
                       isRevealPending: Bool = false,
                       textIsEmpty: Bool,
                       hasInlineNotice: Bool,
                       hasAttachments: Bool,
                       footerSupported: Bool,
                       isFallback: Bool,
                       holdsEngineThroughDisqualifiers: Bool = false) -> Bool {
        guard isSingleRowGroup,
              isAssistantMessage,
              !textIsEmpty,
              !isFallback else { return false }
        if !holdsEngineThroughDisqualifiers {
            guard !hasInlineNotice,
                  !hasAttachments,
                  footerSupported else { return false }
        }
        return isStreamingText || isRevealing || isRevealPending
    }
}
