import Testing
@testable import ClientCore

/// Pins the composer chip's type badge: the uppercased extension, and nil when
/// the name has none (round30 §3.2).
@Suite struct ComposerAttachmentBadgeTests {
    @Test func uppercasesTheExtension() {
        #expect(ComposerAttachmentBadge.text(for: "loon-network.conf") == "CONF")
        #expect(ComposerAttachmentBadge.text(for: "Report.PDF") == "PDF")
    }

    @Test func missingExtensionHasNoBadge() {
        #expect(ComposerAttachmentBadge.text(for: "README") == nil)
        #expect(ComposerAttachmentBadge.text(for: "") == nil)
        #expect(ComposerAttachmentBadge.text(for: "trailing.") == nil)
    }
}
