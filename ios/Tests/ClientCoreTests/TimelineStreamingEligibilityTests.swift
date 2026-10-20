import Testing
@testable import ClientCore

@Suite struct TimelineStreamingEligibilityTests {
    private func admits(
        singleRow: Bool = true,
        assistant: Bool = true,
        streamingText: Bool = false,
        revealing: Bool = false,
        emptyText: Bool = false,
        notice: Bool = false,
        attachments: Bool = false,
        textOnlyAction: Bool = true,
        fallback: Bool = false
    ) -> Bool {
        TimelineStreamingEligibility.admits(
            isSingleRowGroup: singleRow,
            isAssistantMessage: assistant,
            isStreamingText: streamingText,
            isRevealing: revealing,
            textIsEmpty: emptyText,
            hasInlineNotice: notice,
            hasAttachments: attachments,
            isTextOnlyAction: textOnlyAction,
            isFallback: fallback)
    }

    @Test func runningAssistantTextIsEligible() {
        #expect(admits(streamingText: true))
    }

    @Test func finalRevealBatchStaysEligibleAfterDone() {
        // The completion frame is status == .done with the reveal still running;
        // the tail view must keep the row, not a fresh hosting view.
        #expect(admits(streamingText: false, revealing: true))
    }

    @Test func settledDoneRowIsNotEligible() {
        #expect(!admits(streamingText: false, revealing: false))
    }

    @Test func unsupportedRowShapesStayOnHosting() {
        #expect(!admits(streamingText: true, assistant: false))
        #expect(!admits(streamingText: true, singleRow: false))
        #expect(!admits(streamingText: true, emptyText: true))
        #expect(!admits(streamingText: true, notice: true))
        #expect(!admits(streamingText: true, attachments: true))
        #expect(!admits(streamingText: true, textOnlyAction: false))
    }

    @Test func stickyFallbackWinsOverTheLiveStream() {
        #expect(!admits(streamingText: true, revealing: true, fallback: true))
    }
}
