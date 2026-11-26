import Testing
@testable import ClientCore

@Suite @MainActor struct SessionPageRegistryTests {
    @Test func reportsTheOtherPaneOnlyWhileBothAreLive() {
        SessionPageRegistry.reset()
        #expect(SessionPageRegistry.entered("s", pane: .chat).isEmpty)
        #expect(SessionPageRegistry.entered("s", pane: .devices) == [.chat])
        SessionPageRegistry.left("s", pane: .devices)
        // Re-entering after the other page left is not a duplicate.
        #expect(SessionPageRegistry.entered("s", pane: .devices) == [.chat])
        SessionPageRegistry.left("s", pane: .chat)
        SessionPageRegistry.left("s", pane: .devices)
        #expect(SessionPageRegistry.entered("s", pane: .chat).isEmpty)
        SessionPageRegistry.reset()
    }
}
