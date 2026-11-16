import Testing
@testable import ClientCore

/// The send frame's two rows — the pending bubble and the standalone working
/// row — must enter one apply, and the working row draws no text until the
/// server acknowledges the send. pp 2026-11-16: the row ran ahead of the
/// bubble, so its +38 follow started first and the 53 pt bubble landed inside
/// that flight (probe `timeline.rows.frame`).
@Suite struct SendFramePresentationTests {
    @Test func theWorkingRowWaitsForItsPublishedBubble() {
        #expect(!SendFramePresentation.showsWorkingRow(
            placeholderVisible: true, pendingIDs: ["p1"],
            publishedPendingIDs: [], echoedPendingIDs: [],
            isStepsProfile: false, hasLiveSteps: false, queueCount: 0))
        #expect(SendFramePresentation.showsWorkingRow(
            placeholderVisible: true, pendingIDs: ["p1"],
            publishedPendingIDs: ["p1"], echoedPendingIDs: [],
            isStepsProfile: false, hasLiveSteps: false, queueCount: 0))
        // The echo retires the pending row from the presentation; the timeline
        // row it produced is the published send frame.
        #expect(SendFramePresentation.showsWorkingRow(
            placeholderVisible: true, pendingIDs: ["p1"],
            publishedPendingIDs: [], echoedPendingIDs: ["p1"],
            isStepsProfile: false, hasLiveSteps: false, queueCount: 0))
    }

    @Test func aStatusDrivenRowNeedsNoPendingFrame() {
        #expect(SendFramePresentation.showsWorkingRow(
            placeholderVisible: true, pendingIDs: [],
            publishedPendingIDs: [], echoedPendingIDs: [],
            isStepsProfile: false, hasLiveSteps: false, queueCount: 0))
        #expect(!SendFramePresentation.showsWorkingRow(
            placeholderVisible: false, pendingIDs: [],
            publishedPendingIDs: [], echoedPendingIDs: [],
            isStepsProfile: false, hasLiveSteps: false, queueCount: 0))
    }

    @Test func theStepsProfileKeepsTheMarkOnTheGroupRow() {
        #expect(!SendFramePresentation.showsWorkingRow(
            placeholderVisible: true, pendingIDs: ["p1"],
            publishedPendingIDs: ["p1"], echoedPendingIDs: [],
            isStepsProfile: true, hasLiveSteps: true, queueCount: 0))
        #expect(!SendFramePresentation.showsWorkingRow(
            placeholderVisible: true, pendingIDs: ["p1"],
            publishedPendingIDs: ["p1"], echoedPendingIDs: [],
            isStepsProfile: true, hasLiveSteps: false, queueCount: 1))
        #expect(SendFramePresentation.showsWorkingRow(
            placeholderVisible: true, pendingIDs: ["p1"],
            publishedPendingIDs: ["p1"], echoedPendingIDs: [],
            isStepsProfile: true, hasLiveSteps: false, queueCount: 0))
    }

    @Test func theMarkAloneIsTheOptimisticSend() {
        #expect(!SendFramePresentation.showsWorkingRowText(
            latestDelivery: .sending, runtimeIsInFlight: false))
        // A runtime already working can only have the message; keep the text.
        #expect(SendFramePresentation.showsWorkingRowText(
            latestDelivery: .sending, runtimeIsInFlight: true))
        #expect(SendFramePresentation.showsWorkingRowText(
            latestDelivery: .accepted, runtimeIsInFlight: false))
        #expect(SendFramePresentation.showsWorkingRowText(
            latestDelivery: .confirmed, runtimeIsInFlight: false))
        #expect(SendFramePresentation.showsWorkingRowText(
            latestDelivery: .uncertain(V2ClientFailure(kind: .transient, message: "boom")),
            runtimeIsInFlight: false))
        #expect(SendFramePresentation.showsWorkingRowText(
            latestDelivery: nil, runtimeIsInFlight: false))
    }
}
