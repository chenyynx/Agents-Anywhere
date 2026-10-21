import Testing
@testable import ClientCore

@Suite struct TimelineStreamingEligibilityTests {
    private func admits(
        singleRow: Bool = true,
        assistant: Bool = true,
        streamingText: Bool = false,
        revealing: Bool = false,
        revealPending: Bool = false,
        emptyText: Bool = false,
        notice: Bool = false,
        attachments: Bool = false,
        footerSupported: Bool = true,
        fallback: Bool = false,
        holdsEngine: Bool = false
    ) -> Bool {
        TimelineStreamingEligibility.admits(
            isSingleRowGroup: singleRow,
            isAssistantMessage: assistant,
            isStreamingText: streamingText,
            isRevealing: revealing,
            isRevealPending: revealPending,
            textIsEmpty: emptyText,
            hasInlineNotice: notice,
            hasAttachments: attachments,
            footerSupported: footerSupported,
            isFallback: fallback,
            holdsEngineThroughDisqualifiers: holdsEngine)
    }

    @Test func runningAssistantTextIsEligible() {
        #expect(admits(streamingText: true))
    }

    @Test func finalRevealBatchStaysEligibleAfterDone() {
        // The completion frame is status == .done with the reveal still running;
        // the tail view must keep the row, not a fresh hosting view.
        #expect(admits(streamingText: false, revealing: true))
    }

    @Test func rendererOwnedCursorKeepsTheRowAfterDone() {
        // The wire item is done but the TextKit reveal cursor is still behind
        // the received text; the row must not swap to a fresh hosting view.
        #expect(admits(streamingText: false, revealing: false,
                       revealPending: true))
    }

    @Test func settledDoneRowIsNotEligible() {
        #expect(!admits(streamingText: false, revealing: false))
    }

    @Test func unsupportedRowShapesStayOnHosting() {
        #expect(!admits(assistant: false, streamingText: true))
        #expect(!admits(singleRow: false, streamingText: true))
        #expect(!admits(streamingText: true, emptyText: true))
        #expect(!admits(streamingText: true, notice: true))
        #expect(!admits(streamingText: true, attachments: true))
        #expect(!admits(streamingText: true, footerSupported: false))
    }

    @Test func stickyFallbackWinsOverTheLiveStream() {
        #expect(!admits(streamingText: true, revealing: true, fallback: true))
        #expect(!admits(revealPending: true, fallback: true))
    }

    @Test func blockedShapesStayIneligibleWhileRevealing() {
        #expect(!admits(revealPending: true, emptyText: true))
        #expect(!admits(revealPending: true, notice: true))
        #expect(!admits(revealPending: true, attachments: true))
        #expect(!admits(revealPending: true, footerSupported: false))
        #expect(!admits(assistant: false, revealPending: true))
    }

    // MARK: - M4.3 engine hold

    @Test func aNoticeArrivingMidRevealDoesNotSwitchEngines() {
        // The reveal owns the row and has already published the full text;
        // a notice must wait for the handoff, not dump the remaining
        // characters through the hosting path.
        #expect(admits(revealPending: true, notice: true, holdsEngine: true))
        #expect(admits(streamingText: true, notice: true, holdsEngine: true))
        // Once ownership clears the row is ineligible and hands off.
        #expect(!admits(revealPending: true, notice: true, holdsEngine: false))
    }

    @Test func anAttachmentArrivingMidRevealDoesNotSwitchEngines() {
        #expect(admits(revealPending: true, attachments: true, holdsEngine: true))
        #expect(!admits(revealPending: true, attachments: true))
    }

    @Test func anUnsupportedFooterArrivingMidRevealDoesNotSwitchEngines() {
        #expect(admits(revealPending: true, footerSupported: false,
                       holdsEngine: true))
        #expect(!admits(revealPending: true, footerSupported: false))
    }

    @Test func theHoldNeverRescuesAnUnrenderableDocument() {
        // No document means no TextKit engine to hold: the fallback is sticky.
        #expect(!admits(streamingText: true, fallback: true, holdsEngine: true))
        #expect(!admits(revealPending: true, fallback: true, holdsEngine: true))
    }

    @Test func theHoldNeverRescuesANonAssistantOrEmptyRow() {
        #expect(!admits(assistant: false, streamingText: true, holdsEngine: true))
        #expect(!admits(singleRow: false, streamingText: true, holdsEngine: true))
        #expect(!admits(streamingText: true, emptyText: true, holdsEngine: true))
    }

    @Test func theHoldDoesNotKeepASettledRow() {
        // Ownership can linger for one runloop turn after the fade; that must
        // not resurrect a row whose stream and reveals are both finished.
        #expect(!admits(streamingText: false, revealing: false,
                        revealPending: false, notice: true, holdsEngine: true))
    }
}
