import Testing
@testable import ClientCore

@Suite struct ComposerQueueAffordanceTests {
    @Test func anIdleComposerShowsSend() {
        let affordance = ComposerQueueAffordance.resolve(
            isStreaming: false, hasText: true,
            canQueue: true, canStop: true, canSend: true)
        #expect(affordance.shape == .send)
        #expect(affordance.isActionEnabled)
    }

    @Test func aRunningTurnKeepsStopUntilTheResponseStarts() {
        let affordance = ComposerQueueAffordance.resolve(
            isStreaming: true, hasText: false,
            canQueue: true, canStop: true, canSend: false)
        #expect(affordance.shape == .stop)
        #expect(affordance.isActionEnabled)
    }

    /// The runtime still reports the turn as running while it finalizes, but
    /// the visible reply is done: the official composer switches to send at
    /// the message boundary instead of waiting for idle (pp 2026-10-31).
    @Test func aFinishedReplySwitchesToSendBeforeIdle() {
        let empty = ComposerQueueAffordance.resolve(
            isStreaming: true, responseFinished: true, hasText: false,
            canQueue: true, canStop: true, canSend: false)
        #expect(empty.shape == .send)
        // The send gate stays closed until the turn ends; an empty draft is
        // disabled in the idle composer too.
        #expect(!empty.isActionEnabled)

        let typed = ComposerQueueAffordance.resolve(
            isStreaming: true, responseFinished: true, hasText: true,
            canQueue: true, canStop: true, canSend: false)
        #expect(typed.shape == .queueSend)
        #expect(typed.isActionEnabled)
    }
}
