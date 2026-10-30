import Foundation
import Testing
@testable import ClientCore

/// Pins the anchor reducer's transition table: the nine statically proven
/// official events (`CANONICAL/05-layout-scroll.md` §6.4) plus the AA mapping
/// events. Each expectation is the behaviour the driver relies on, not an
/// implementation detail.

@Suite struct TimelineAnchorReducerTests {
    private func landed(_ placement: TimelineAnchorPlacement = .end,
                        motion: TimelineAnchorMotion = .resting) -> TimelineAnchorState {
        TimelineAnchorState(placement: placement, motion: motion, hasLanded: true)
    }

    private func reduce(_ state: TimelineAnchorState,
                        _ event: TimelineAnchorEvent) -> TimelineAnchorReduction {
        TimelineAnchorReducer.reduce(state, event)
    }

    @Test func theOpeningLandsOnceDirectly() {
        let first = reduce(TimelineAnchorState(), .viewportChanged)
        #expect(first.state.hasLanded)
        #expect(first.state.placement == .end)
        #expect(first.action == .placeDirect)

        let second = reduce(first.state, .viewportChanged)
        #expect(second.action == .none)
    }

    @Test func aDragDerivesTheReadingAnchorAndStopsTheMover() {
        let result = reduce(landed(.end, motion: .easing),
                            .readerBeganDragging(id: "u3", offsetIntoRow: 24))
        #expect(result.state.placement == .reading(id: "u3", offsetIntoRow: 24))
        #expect(result.state.motion == .dragging)
        #expect(!result.state.isFollowingCatchUp)
        #expect(result.action == .halt)
    }

    @Test func liftingInHistoryKeepsTheReadingAnchor() {
        let result = reduce(landed(.reading(id: "u3", offsetIntoRow: 24), motion: .dragging),
                            .readerLifted(willCoast: false, atEnd: false,
                                          id: "u3", offsetIntoRow: 24))
        #expect(result.state.motion == .resting)
        #expect(result.state.placement == .reading(id: "u3", offsetIntoRow: 24))
        #expect(result.action == .halt)
        #expect(!result.state.isFollowingCatchUp)
    }

    @Test func liftingAtTheBottomRearmsTheEnd() {
        let result = reduce(landed(.reading(id: "u9", offsetIntoRow: 0), motion: .dragging),
                            .readerLifted(willCoast: false, atEnd: true,
                                          id: "u9", offsetIntoRow: 0))
        #expect(result.state.motion == .resting)
        #expect(result.state.placement == .end)
        #expect(result.state.isFollowingCatchUp)
    }

    @Test func coastingEndsWithTheOfficialBottomTest() {
        var state = landed(.reading(id: "u9", offsetIntoRow: 0), motion: .coasting)
        state = reduce(state, .coastingEnded(atEnd: false, id: "u5", offsetIntoRow: 12)).state
        #expect(state.motion == .resting)
        #expect(state.placement == .reading(id: "u5", offsetIntoRow: 12))
        #expect(!state.isFollowingCatchUp)

        let ended = reduce(landed(.reading(id: "u5", offsetIntoRow: 12), motion: .coasting),
                           .coastingEnded(atEnd: true, id: "u5", offsetIntoRow: 12))
        #expect(ended.state.placement == .end)
        #expect(ended.state.isFollowingCatchUp)
    }

    @Test func aScrollWithoutAHandRederivesThePlacement() {
        let result = reduce(landed(.end, motion: .coasting),
                            .scrolledWithoutAHand(atEnd: false, id: "u1", offsetIntoRow: 80))
        #expect(result.state.motion == .resting)
        #expect(result.state.placement == .reading(id: "u1", offsetIntoRow: 80))
    }

    @Test func sendingDoesNotMoveThePage() {
        let result = reduce(landed(.end), .sending)
        #expect(result.action == .none)
        #expect(result.state.placement == .end)
    }

    @Test func sentPinsTheNewRowToTheTop() {
        let result = reduce(landed(.end), .sent(id: "me-7"))
        #expect(result.state.placement == .row(id: "me-7"))
        #expect(result.action == .move)
    }

    @Test func askedForEndIsIgnoredWhileDragging() {
        let result = reduce(landed(.reading(id: "u2", offsetIntoRow: 10), motion: .dragging),
                            .askedForEnd(animated: true))
        #expect(result.state.placement == .reading(id: "u2", offsetIntoRow: 10))
        #expect(result.action == .none)
    }

    @Test func askedForEndIsIgnoredWhileAlreadyFlyingToTheEnd() {
        let result = reduce(landed(.end, motion: .flying), .askedForEnd(animated: true))
        #expect(result.action == .none)
        #expect(result.state.placement == .end)
    }

    @Test func askedForEndArmsTheEndAndMoves() {
        let result = reduce(landed(.reading(id: "u2", offsetIntoRow: 10)), .askedForEnd(animated: true))
        #expect(result.state.placement == .end)
        #expect(result.action == .move)
        #expect(result.state.isFollowingCatchUp)

        let instant = reduce(landed(.reading(id: "u2", offsetIntoRow: 10)),
                             .askedForEnd(animated: false))
        #expect(instant.action == .placeDirect)
    }

    @Test func anInstantEndRequestLandsEvenWhileFlying() {
        let result = reduce(landed(.end, motion: .flying), .askedForEnd(animated: false))
        #expect(result.state.placement == .end)
        #expect(result.action == .placeDirect)
    }

    @Test func askedForStartPlacesTheFirstRowAtTheTop() {
        let result = reduce(landed(.end), .askedForStart(id: "u0"))
        #expect(result.state.placement == .reading(id: "u0", offsetIntoRow: 0))
        #expect(result.action == .move)
        #expect(!result.state.isFollowingCatchUp)
    }

    @Test func askedForStartIsIgnoredWhileDragging() {
        let result = reduce(landed(.reading(id: "u2", offsetIntoRow: 10), motion: .dragging),
                            .askedForStart(id: "u0"))
        #expect(result.state.placement == .reading(id: "u2", offsetIntoRow: 10))
        #expect(result.action == .none)
    }

    @Test func arrivalOnlyEndsAMoverMotion() {
        let mover = reduce(landed(.end, motion: .flying), .arrived)
        #expect(mover.state.motion == .resting)
        #expect(mover.action == .none)

        let resting = reduce(landed(.reading(id: "u1", offsetIntoRow: 4), motion: .resting), .arrived)
        #expect(resting.state.motion == .resting)
    }

    @Test func contentGrowthFollowsOnlyTheEnd() {
        let following = reduce(landed(.end), .contentChanged)
        #expect(following.action == .move)
        #expect(following.state.isFollowingCatchUp)

        let reading = reduce(landed(.reading(id: "u1", offsetIntoRow: 40)), .contentChanged)
        #expect(reading.action == .none)
        #expect(!reading.state.isFollowingCatchUp)
    }

    @Test func aSafeAreaChangePlacesDirectlyAndStopsTheMover() {
        let result = reduce(landed(.end, motion: .easing), .safeAreaChanged)
        #expect(result.state.motion == .resting)
        #expect(result.action == .placeDirect)
    }

    @Test func aWindowReplacementLeavesAReaderAlone() {
        let tookOver = reduce(landed(.reading(id: "u4", offsetIntoRow: 8)),
                              .windowReplaced(readerTookOver: true))
        #expect(tookOver.action == .none)
        #expect(tookOver.state.placement == .reading(id: "u4", offsetIntoRow: 8))

        let opened = reduce(landed(.reading(id: "u4", offsetIntoRow: 8)),
                            .windowReplaced(readerTookOver: false))
        #expect(opened.action == .placeDirect)
        #expect(opened.state.placement == .end)
    }

    @Test func anApprovalPinsTheReadingAnchorAndItsRemovalReturns() {
        let presented = reduce(landed(.end), .interactionPresentedChanged(
            presented: true, id: "u6", offsetIntoRow: 30))
        #expect(presented.state.placement == .reading(id: "u6", offsetIntoRow: 30))
        #expect(presented.action == .halt)

        let dismissed = reduce(presented.state, .interactionPresentedChanged(
            presented: false, id: nil, offsetIntoRow: 0))
        #expect(dismissed.state.placement == .end)
        #expect(dismissed.action == .move)
    }

    @Test func navigationSuspensionStopsAndResumeRePlaces() {
        let suspended = reduce(landed(.end, motion: .flying), .navigationSuspendedChanged(suspended: true))
        #expect(suspended.state.motion == .resting)
        #expect(suspended.action == .halt)

        let resumed = reduce(suspended.state, .navigationSuspendedChanged(suspended: false))
        #expect(resumed.action == .placeDirect)
    }
}
