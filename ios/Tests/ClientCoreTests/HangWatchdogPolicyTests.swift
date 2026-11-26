import Foundation
import Testing
@testable import ClientCore

/// The hang watchdog exists because the b1678 freeze (pp 2026-11-27) wrote no
/// trace of where the main thread went. These pin the two decisions that keep
/// it from either missing a real freeze or reporting a suspended app.
@Suite struct HangWatchdogPolicyTests {
    @Test func anOrdinaryBeatDelayedByALayoutPassIsNotAStall() {
        #expect(!HangWatchdogPolicy.isStalled(
            lastBeat: 100, now: 101.5, foreground: true, reportBeat: 0))
    }

    @Test func twoSecondsWithoutABeatIsAStall() {
        #expect(HangWatchdogPolicy.isStalled(
            lastBeat: 100, now: 102, foreground: true, reportBeat: 0))
    }

    @Test func aBackgroundAppIsNotAFrozenScreen() {
        #expect(!HangWatchdogPolicy.isStalled(
            lastBeat: 100, now: 110, foreground: false, reportBeat: 0))
    }

    @Test func oneStallIsReportedOnce() {
        #expect(!HangWatchdogPolicy.isStalled(
            lastBeat: 100, now: 110, foreground: true, reportBeat: 100))
    }

    @Test func recoveryNeedsABeatPastTheCapturedOne() {
        #expect(HangWatchdogPolicy.hasRecovered(lastBeat: 101, reportBeat: 100))
        #expect(!HangWatchdogPolicy.hasRecovered(lastBeat: 100, reportBeat: 100))
        #expect(!HangWatchdogPolicy.hasRecovered(lastBeat: 101, reportBeat: 0))
    }
}
