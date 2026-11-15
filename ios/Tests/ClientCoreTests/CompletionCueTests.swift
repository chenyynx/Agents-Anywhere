import Testing
@testable import ClientCore

@Suite("Completion cue")
struct CompletionCueTests {
    private func allows(lastTurnEndWasStop: Bool = false,
                        stopRequested: Bool = false,
                        predictedIdle: Bool = false,
                        isOpeningReady: Bool = true,
                        isFresh: Bool = true,
                        isIdle: Bool = true) -> Bool {
        CompletionCue.allows(isOpeningReady: isOpeningReady, isFresh: isFresh,
                             isIdle: isIdle, lastTurnEndWasStop: lastTurnEndWasStop,
                             stopRequested: stopRequested, predictedIdle: predictedIdle)
    }

    @Test func aNaturalIdleTurnPlaysTheCue() {
        #expect(allows())
    }

    @Test func anAcknowledgedStopSuppressesTheCue() {
        #expect(!allows(lastTurnEndWasStop: true))
    }

    /// The authoritative idle can beat the interrupt ack: the tap flag is
    /// already set, so the completion's double pulse must stay silent.
    @Test func aStopTapSuppressesTheCueBeforeItsAckArrives() {
        #expect(!allows(stopRequested: true))
    }

    @Test func anAcceptedStopAckSuppressesTheCue() {
        #expect(!allows(predictedIdle: true))
    }

    @Test func aStaleOrNonIdleTurnDoesNotPlay() {
        #expect(!allows(isOpeningReady: false))
        #expect(!allows(isFresh: false))
        #expect(!allows(isIdle: false))
    }
}
