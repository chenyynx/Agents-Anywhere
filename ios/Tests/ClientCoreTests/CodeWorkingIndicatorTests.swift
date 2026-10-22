import Testing
@testable import ClientCore

@Suite("Code working indicator")
struct CodeWorkingIndicatorTests {
    @Test func tailShowsOnlyWithoutAnInlineStatus() {
        #expect(CodeWorkingIndicator.showsTailStatusLine(
            hasPlaceholder: true, hasInlineStatus: false))
        #expect(!CodeWorkingIndicator.showsTailStatusLine(
            hasPlaceholder: true, hasInlineStatus: true))
    }

    @Test func noPlaceholderMeansNoTailLine() {
        #expect(!CodeWorkingIndicator.showsTailStatusLine(
            hasPlaceholder: false, hasInlineStatus: false))
        #expect(!CodeWorkingIndicator.showsTailStatusLine(
            hasPlaceholder: false, hasInlineStatus: true))
    }
}
