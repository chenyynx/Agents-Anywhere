import Foundation
import Testing
@testable import ClientCore

@Suite struct LongMessageAttachmentPolicyTests {
    @Test func ordinaryTextStaysInTheBubble() {
        #expect(!LongMessageAttachmentPolicy.shouldConvert("hello"))
        #expect(!LongMessageAttachmentPolicy.shouldConvert(
            String(repeating: "a", count: LongMessageAttachmentPolicy.characterThreshold - 1)))
    }

    @Test func aHugePasteBecomesATextAttachment() throws {
        let text = String(repeating: "log line\n", count: 2_000)
        #expect(LongMessageAttachmentPolicy.shouldConvert(text))
        let attachment = try #require(LongMessageAttachmentPolicy.makeAttachment(
            from: text, existingAttachmentCount: 0, canAttach: true))
        #expect(attachment.mediaType == "text/plain")
        #expect(attachment.name.hasPrefix("long-message-"))
        #expect(attachment.name.hasSuffix(".txt"))
        #expect(attachment.data == Data(text.utf8))
    }

    @Test func manyShortLinesAlsoConvert() {
        let text = Array(repeating: "x", count: LongMessageAttachmentPolicy.lineThreshold)
            .joined(separator: "\n")
        #expect(LongMessageAttachmentPolicy.shouldConvert(text))
    }

    @Test func theDraftMustStillAcceptAnAttachment() {
        let text = String(repeating: "a", count: LongMessageAttachmentPolicy.characterThreshold)
        #expect(LongMessageAttachmentPolicy.makeAttachment(
            from: text, existingAttachmentCount: 0, canAttach: false) == nil)
        #expect(LongMessageAttachmentPolicy.makeAttachment(
            from: text,
            existingAttachmentCount: LongMessageAttachmentPolicy.maximumAttachments,
            canAttach: true) == nil)
    }
}
