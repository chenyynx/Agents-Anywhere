import Foundation
import Testing
@testable import ClientCore

// The official working-row verb rotation is phase-based, not wall-clock:
// `index = (abs(baseDate) % 20 + phase(elapsed)) % 20` with the first term 0,
// `phase(d) = 0 (d < 3s) / 1 (3–7s) / floor((d - 7) / 6) + 2 (≥ 7s)`
// (`CANONICAL/20-working-mark.md` §4; `0x102a85174`, `0x102a89f6c`).

@Suite("Code working status rotation")
struct CodeWorkingStatusTextTests {

    @Test func holdsTheFirstVerbForThreeSeconds() {
        #expect(CodeWorkingStatusText.index(elapsed: 0) == 0)
        #expect(CodeWorkingStatusText.index(elapsed: 2.9) == 0)
    }

    @Test func holdsTheSecondVerbUntilSevenSeconds() {
        #expect(CodeWorkingStatusText.index(elapsed: 3) == 1)
        #expect(CodeWorkingStatusText.index(elapsed: 6.9) == 1)
    }

    @Test func changesEverySixSecondsAfterSeven() {
        #expect(CodeWorkingStatusText.index(elapsed: 7) == 2)
        #expect(CodeWorkingStatusText.index(elapsed: 12.9) == 2)
        #expect(CodeWorkingStatusText.index(elapsed: 13) == 3)
        // The official screenshot at 109–114 s shows Brewing (index 19).
        #expect(CodeWorkingStatusText.index(elapsed: 109) == 19)
        #expect(CodeWorkingStatusText.verb(elapsed: 109) == "Brewing")
        #expect(CodeWorkingStatusText.index(elapsed: 115) == 0)
    }

    @Test func verbTableMatchesTheOfficialArrayOrder() {
        #expect(CodeWorkingStatusText.verbs.count == 20)
        #expect(CodeWorkingStatusText.verbs.first == "Clauding")
        #expect(CodeWorkingStatusText.verbs[8] == "Musing")
        #expect(CodeWorkingStatusText.verbs.last == "Brewing")
    }

    @Test func negativeElapsedClampsToTheFirstVerb() {
        #expect(CodeWorkingStatusText.index(elapsed: -5) == 0)
    }
}
