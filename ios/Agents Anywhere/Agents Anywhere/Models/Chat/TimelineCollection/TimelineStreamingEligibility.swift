import Foundation

/// Admission rule for the streaming TextKit row. Kept pure and in ClientCore
/// so the rule has unit coverage; the adapter supplies the current row facts.
///
/// The row stays eligible through the final reveal batch: either the legacy
/// reveal flag or the renderer-owned cursor (`isRevealPending`) keeps it on
/// the TextKit cell after `status == .done`, so committing does not cut the
/// animation or hand the message to a fresh hosting view for one frame.
nonisolated enum TimelineStreamingEligibility {
    static func admits(isSingleRowGroup: Bool,
                       isAssistantMessage: Bool,
                       isStreamingText: Bool,
                       isRevealing: Bool,
                       isRevealPending: Bool = false,
                       textIsEmpty: Bool,
                       hasInlineNotice: Bool,
                       hasAttachments: Bool,
                       isTextOnlyAction: Bool,
                       isFallback: Bool) -> Bool {
        guard isSingleRowGroup,
              isAssistantMessage,
              !textIsEmpty,
              !hasInlineNotice,
              !hasAttachments,
              isTextOnlyAction,
              !isFallback else { return false }
        return isStreamingText || isRevealing || isRevealPending
    }
}
