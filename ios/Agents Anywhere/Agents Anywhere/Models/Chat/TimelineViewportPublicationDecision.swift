import Foundation

/// Decides whether a per-frame geometry sample may be published into view
/// state (S2). Sampling itself stays per-frame in a non-invalidating box;
/// publishing writes `@State` and re-evaluates the page body, so it is
/// reserved for samples that change a decision.
nonisolated enum TimelineViewportPublicationDecision {
    enum Outcome: Equatable {
        case ignore
        case publish
    }

    /// Rules ①-⑤ of the A2 audit:
    /// ① the first measured sample always publishes — opening and the instant
    ///    return both wait for `viewport.isMeasured`;
    /// ② a content height change always publishes: it moves the follow target;
    /// ③ a top inset change always publishes: it moves the reader's reference;
    /// ④ a visible-height-only change while the keyboard transition window is
    ///    open is the keyboard itself — republishing it per frame is the body
    ///    storm this rule removes. The 2pt end probe owns the bottom truth, so
    ///    the sample is ignored unless the probe itself flipped
    ///    (`tailChanged`);
    /// ⑤ the transition end re-evaluates the settled sample with
    ///    `keyboardTransitionActive == false`, so a withheld height lands and
    ///    the scroll state's `lastRequest` dedup cannot stay pinned to a
    ///    pre-keyboard value.
    static func outcome(published: TimelineViewport, next: TimelineViewport,
                        keyboardTransitionActive: Bool, tailChanged: Bool) -> Outcome {
        if !published.isMeasured && next.isMeasured { return .publish }
        if published.contentHeight != next.contentHeight { return .publish }
        if published.topInset != next.topInset { return .publish }
        if published.visibleHeight != next.visibleHeight {
            return keyboardTransitionActive && !tailChanged ? .ignore : .publish
        }
        return .ignore
    }
}
