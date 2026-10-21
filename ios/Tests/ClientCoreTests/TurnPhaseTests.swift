import Testing
@testable import ClientCore

@Suite struct TurnPhaseTests {
    @Test func toolOutranksWritingAndReasoning() {
        #expect(ChatTurnPhase.resolve(toolActive: true, writing: true,
                                      reasoning: true) == .usingTool)
        #expect(ChatTurnPhase.resolve(toolActive: false, writing: true,
                                      reasoning: true) == .writing)
        #expect(ChatTurnPhase.resolve(toolActive: false, writing: false,
                                      reasoning: true) == .thinking)
        #expect(ChatTurnPhase.resolve(toolActive: false, writing: false,
                                      reasoning: false) == .idle)
    }

    @Test func endOfStreamIsTheOnlyImpact() {
        #expect(TurnPhaseHaptics.feedback(from: .writing, to: .idle)
            == .impactLight)
        // Interruptions and failures also go writing -> idle; one impact.
        #expect(TurnPhaseHaptics.feedback(from: .writing, to: .idle)
            == TurnPhaseHaptics.feedback(from: .writing, to: .idle))
        // No other transition is an impact.
        for old in ChatTurnPhase.allCases {
            for new in ChatTurnPhase.allCases where !(old == .writing && new == .idle) {
                if old == new {
                    #expect(TurnPhaseHaptics.feedback(from: old, to: new) == .none)
                } else {
                    #expect(TurnPhaseHaptics.feedback(from: old, to: new)
                        == .selection)
                }
            }
        }
    }

    @Test func phaseTagsMatchTheOfficialEnum() {
        #expect(ChatTurnPhase.idle.rawValue == 0)
        #expect(ChatTurnPhase.thinking.rawValue == 1)
        #expect(ChatTurnPhase.writing.rawValue == 2)
        #expect(ChatTurnPhase.usingTool.rawValue == 3)
        #expect(ChatTurnPhase.allCases.count == 4)
    }
}
