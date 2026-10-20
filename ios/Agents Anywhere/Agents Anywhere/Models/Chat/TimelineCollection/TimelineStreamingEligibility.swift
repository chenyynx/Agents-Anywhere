import Foundation

/// Admission rule for the streaming TextKit row. Kept pure and in ClientCore
/// so the rule has unit coverage; the adapter supplies the current row facts.
///
/// The row stays eligible through the final reveal batch (`status == .done`
/// while `isRevealing` is true), so committing does not hand the message to a
/// fresh hosting view for one frame.
nonisolated enum TimelineStreamingEligibility {
    static func admits(isSingleRowGroup: Bool,
                       isAssistantMessage: Bool,
                       isStreamingText: Bool,
                       isRevealing: Bool,
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
        return isStreamingText || isRevealing
    }
}
