import Testing
@testable import ClientCore

@Suite("Code working indicator")
struct CodeWorkingIndicatorTests {
    @Test func tailShowsOnlyWithoutAnInlineStatus() {
        #expect(CodeWorkingIndicator.showsTailStatusLine(
            hasPlaceholder: true, hasActiveReasoningStatus: false))
        #expect(!CodeWorkingIndicator.showsTailStatusLine(
            hasPlaceholder: true, hasActiveReasoningStatus: true))
    }

    @Test func noPlaceholderMeansNoTailLine() {
        #expect(!CodeWorkingIndicator.showsTailStatusLine(
            hasPlaceholder: false, hasActiveReasoningStatus: false))
        #expect(!CodeWorkingIndicator.showsTailStatusLine(
            hasPlaceholder: false, hasActiveReasoningStatus: true))
    }
}
