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
            from: text, existingAttachmentCount: 0))
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
            from: text,
            existingAttachmentCount: LongMessageAttachmentPolicy.maximumAttachments - 1) != nil)
        #expect(LongMessageAttachmentPolicy.makeAttachment(
            from: text,
            existingAttachmentCount: LongMessageAttachmentPolicy.maximumAttachments) == nil)
    }

    // MARK: - Paste gate

    @Test func ordinaryPasteInsertsWhateverTheRuntimeCanDeliver() {
        for delivery in [AttachmentDelivery.deliverable, .unavailable, .unknown] {
            #expect(LongMessageAttachmentPolicy.decidePaste(
                "hello", existingAttachmentCount: 0, delivery: delivery) == .insert)
        }
    }

    @Test func aLongPasteBecomesAFileEvenWhenDeliveryIsUnknown() {
        let text = String(repeating: "a", count: LongMessageAttachmentPolicy.characterThreshold)
        // Offline, capabilities stale, new session still preparing: the local
        // card is still the right shape. Coupling this to delivery is exactly
        // what let 4 MB reach TextKit (2026-11-22 b1485).
        #expect(LongMessageAttachmentPolicy.decidePaste(
            text, existingAttachmentCount: 0, delivery: .unknown) == .attachment)
        #expect(LongMessageAttachmentPolicy.decidePaste(
            text, existingAttachmentCount: 0, delivery: .deliverable) == .attachment)
    }

    @Test func aRuntimeWithoutAttachmentSupportKeepsMeasurableText() {
        let measurable = String(repeating: "a", count: LongMessageAttachmentPolicy.characterThreshold)
        #expect(LongMessageAttachmentPolicy.decidePaste(
            measurable, existingAttachmentCount: 0, delivery: .unavailable) == .insert)
        let oversized = String(repeating: "a",
                               count: LongMessageAttachmentPolicy.maximumEditorCharacters + 1)
        #expect(LongMessageAttachmentPolicy.decidePaste(
            oversized, existingAttachmentCount: 0, delivery: .unavailable) == .refused)
    }

    @Test func fullAttachmentSlotsOnlyRefuseOversizedText() {
        let measurable = String(repeating: "a", count: LongMessageAttachmentPolicy.characterThreshold)
        #expect(LongMessageAttachmentPolicy.decidePaste(
            measurable,
            existingAttachmentCount: LongMessageAttachmentPolicy.maximumAttachments,
            delivery: .deliverable) == .insert)
        let oversized = String(repeating: "a",
                               count: LongMessageAttachmentPolicy.maximumEditorCharacters + 1)
        #expect(LongMessageAttachmentPolicy.decidePaste(
            oversized,
            existingAttachmentCount: LongMessageAttachmentPolicy.maximumAttachments,
            delivery: .deliverable) == .refused)
    }

    // MARK: - Restored drafts

    @Test func aDraftInsideTheEditorBudgetIsRestoredVerbatim() {
        let text = String(repeating: "a", count: LongMessageAttachmentPolicy.characterThreshold * 2)
        let restored = LongMessageAttachmentPolicy.sanitizeRestoredDraft(
            text, existingAttachmentCount: 0)
        #expect(restored.text == text)
        #expect(restored.attachment == nil)
        #expect(!restored.didSanitize)
    }

    @Test func anOversizedDraftBecomesAFileAtRestore() throws {
        let text = String(repeating: "a", count: LongMessageAttachmentPolicy.maximumEditorCharacters + 1)
        let restored = LongMessageAttachmentPolicy.sanitizeRestoredDraft(
            text, existingAttachmentCount: 0)
        #expect(restored.didSanitize)
        #expect(restored.text.isEmpty)
        let attachment = try #require(restored.attachment)
        #expect(attachment.data == Data(text.utf8))
    }

    // MARK: - Folding an optimistic card back into text

    @Test func aPolicyCardFoldsBackOnlyInsideTheBudget() throws {
        let text = String(repeating: "a", count: LongMessageAttachmentPolicy.characterThreshold)
        let card = try #require(LongMessageAttachmentPolicy.makeAttachment(
            from: text, existingAttachmentCount: 0))
        #expect(LongMessageAttachmentPolicy.isLongMessageAttachment(card))
        #expect(LongMessageAttachmentPolicy.textFromLongMessageAttachment(card) == text)

        let oversizedCard = try #require(LongMessageAttachmentPolicy.makeAttachment(
            from: String(repeating: "a",
                         count: LongMessageAttachmentPolicy.maximumEditorCharacters + 1),
            existingAttachmentCount: 0))
        #expect(LongMessageAttachmentPolicy.textFromLongMessageAttachment(oversizedCard) == nil)

        let picked = ChatAttachment(name: "notes.txt", data: Data("x".utf8), mediaType: "text/plain")
        #expect(!LongMessageAttachmentPolicy.isLongMessageAttachment(picked))
    }

    @Test func anOversizedDraftWithFullSlotsKeepsItsHead() {
        let text = String(repeating: "a", count: LongMessageAttachmentPolicy.maximumEditorCharacters + 1)
        let restored = LongMessageAttachmentPolicy.sanitizeRestoredDraft(
            text, existingAttachmentCount: LongMessageAttachmentPolicy.maximumAttachments)
        #expect(restored.didSanitize)
        #expect(restored.attachment == nil)
        #expect(restored.text.count == LongMessageAttachmentPolicy.maximumEditorCharacters)
    }
}
