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
        // The exact boundary is not representable as a Double subtraction
        // (1000.15 - 1000.0 is 0.1499999...); assert just past it instead.
        #expect(HapticGate.statusAllowed(now: 1_000.2))

        HapticGate.reset()
        #expect(HapticGate.statusAllowed(now: 1_000))
    }
}
