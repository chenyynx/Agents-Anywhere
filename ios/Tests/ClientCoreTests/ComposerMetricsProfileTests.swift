import Foundation
import Testing
@testable import ClientCore

/// Pins the two composer geometry profiles. The Code values come from pp's
/// official screenshots (2026-10-26): collapsed 16 / 52, expanded 9 / 95.
@Suite struct ComposerMetricsProfileTests {
    @Test func codeProfileMatchesTheOfficialScreenshots() {
        let profile = ComposerMetricsProfile.code
        #expect(profile.collapsedHorizontalInset == 16)
        #expect(profile.expandedHorizontalInset == 9)
        #expect(profile.collapsedHeight == 52)
        #expect(profile.touchTarget == 44)
        #expect(profile.sendDiameter == 36)
        #expect(profile.collapsedLeadingInset == 0)
        #expect(profile.collapsedTrailingInset == 2)
        #expect(profile.collapsedTextGap == 14)
        #expect(profile.collapsedCornerRadius == 26)
        #expect(profile.expandedCornerRadius == 24)
        #expect(profile.collapsedBottomMargin == 0)
        #expect(profile.expandedBottomMargin == 8)
        #expect(profile.expandedContentInset == 3)
        #expect(profile.plusStyle == .circle)
        #expect(profile.plusSymbolSize == 20)
        // 11 + 22 + 10 + 44 + 8 = 95 pt, the measured expanded height.
        #expect(profile.expandedHeight(editorHeight: 22) == 95)
        #expect(profile.expandAnimation == .spring(response: 0.22, dampingFraction: 0.77))
    }

    @Test func chatProfileKeepsTheCurrentBar() {
        let profile = ComposerMetricsProfile.chat(bodyLineHeight: 22)
        #expect(profile.collapsedHorizontalInset == 32)
        #expect(profile.expandedHorizontalInset == 12)
        #expect(profile.collapsedHeight == 48)
        #expect(profile.touchTarget == 44)
        #expect(profile.sendDiameter == 36)
        #expect(profile.collapsedLeadingInset == 2)
        #expect(profile.collapsedTrailingInset == 2)
        #expect(profile.collapsedCornerRadius == 24)
        #expect(profile.expandedCornerRadius == 26)
        #expect(profile.collapsedBottomMargin == 10)
        #expect(profile.expandedBottomMargin == 10)
        #expect(profile.expandedContentInset == 8)
        #expect(profile.collapsedTextGap == 4)
        #expect(profile.plusStyle == .bare)
        #expect(profile.plusSymbolSize == 24)
        #expect(profile.expandedHeight(editorHeight: 22) == 100)
        #expect(profile.expandAnimation == .smooth(duration: 0.24))
    }

    @Test func chatProfileStillScalesWithTheBodyLineHeight() {
        // 44 pt line height is beyond the 48 pt floor: 44 + 12 = 56.
        let profile = ComposerMetricsProfile.chat(bodyLineHeight: 44)
        #expect(profile.collapsedHeight == 56)
        #expect(profile.touchTarget == 52)
        #expect(profile.sendDiameter == 44)
        #expect(profile.collapsedCornerRadius == 28)
        #expect(profile.expandedCornerRadius == 30)
    }
}
