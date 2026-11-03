import Testing
@testable import ClientCore

@Suite @MainActor struct HapticGateTests {
    /// A user-action haptic owns the engine for `userActionWindow`; a passive
    /// status cue inside that window is dropped instead of colliding with it.
    @Test func passiveCuesStaySilentInsideTheUserActionWindow() {
        HapticGate.reset()
        #expect(HapticGate.statusAllowed(now: 1_000))

        HapticGate.noteUserAction(now: 1_000)
        #expect(!HapticGate.statusAllowed(now: 1_000))
        #expect(!HapticGate.statusAllowed(now: 1_000.149))
        #expect(HapticGate.statusAllowed(now: 1_000.15))

        HapticGate.reset()
        #expect(HapticGate.statusAllowed(now: 1_000))
    }
}
