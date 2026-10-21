import Testing
@testable import ClientCore

@Suite struct StreamingRevealOwnershipTests {
    @Test func beginKeepsTheRowUntilFinish() {
        var ownership = StreamingRevealOwnership()
        ownership.begin("a")
        #expect(ownership.isActive("a"))
        let firstFinish = ownership.finish("a")
        #expect(firstFinish)
        #expect(!ownership.isActive("a"))
        // A second finish must not pretend there was work to re-apply.
        let secondFinish = ownership.finish("a")
        #expect(!secondFinish)
    }

    @Test func rowsAreIndependent() {
        var ownership = StreamingRevealOwnership()
        ownership.begin("a")
        ownership.begin("b")
        let finishedA = ownership.finish("a")
        #expect(finishedA)
        #expect(ownership.isActive("b"))
        #expect(ownership.signatureRowIDs == ["b"])
    }

    @Test func pruneDropsRowsThatLeftTheTimeline() {
        var ownership = StreamingRevealOwnership()
        ownership.begin("a")
        ownership.begin("b")
        ownership.begin("c")
        ownership.prune(keeping: ["b", "c"])
        #expect(ownership.signatureRowIDs == ["b", "c"])
        ownership.prune(keeping: [])
        #expect(ownership.activeRowIDs.isEmpty)
    }
}
