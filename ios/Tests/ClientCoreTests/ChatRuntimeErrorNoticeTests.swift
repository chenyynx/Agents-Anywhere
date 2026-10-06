import Foundation
import Testing
@testable import ClientCore

/// The retired-process disclosure as a chat notice: only codes with reviewed
/// copy are surfaced, the identity is the code plus the error's parameters,
/// and the message degrades safely when the catalog cannot serve it.
///
/// The catalog binding itself (which key carries which sentence) is verified
/// by `check-localization.py` and by the app build, not from a unit test —
/// the unit bundle has no app catalog, so `runtimeErrorText` returns nil here
/// and the message assertions below pin the degradation path. Same convention
/// as `RuntimeErrorCopyTests`.
@Suite @MainActor struct ChatRuntimeErrorNoticeTests {
    private let connectorMessage = "The Claude process was terminated after failing to respond. This turn produced no result and any running background tasks have ended. Please try again."

    @Test func theRetirementCodeBecomesANotice() {
        let error = V2RuntimeError(code: "claude_process_retired", message: connectorMessage)
        let notice = ChatRuntimeErrorNotice.make(for: error)
        #expect(notice != nil)
        #expect(notice?.title == String(localized: "任务已中断"))
        #expect(notice?.canRetry == false)
        #expect(notice?.identity == ChatRuntimeErrorNotice.Identity(code: "claude_process_retired", params: nil))
    }

    /// The gate is the copy table, nothing else: no error, no code, an
    /// unreviewed code, and the old timeout code (a different incident whose
    /// wording is still correct) all keep today's behaviour — no chat notice.
    @Test func codesWithoutReviewedCopyStayOffThisSurface() {
        #expect(ChatRuntimeErrorNotice.make(for: nil) == nil)
        #expect(ChatRuntimeErrorNotice.make(for: V2RuntimeError(code: nil, message: connectorMessage)) == nil)
        #expect(ChatRuntimeErrorNotice.make(for: V2RuntimeError(code: "code_from_a_newer_connector", message: connectorMessage)) == nil)
        #expect(ChatRuntimeErrorNotice.make(for: V2RuntimeError(code: "claude_scheduled_turn_timeout", message: connectorMessage)) == nil)
    }

    /// The message must never be the raw catalog key, an empty string, or the
    /// untranslated placeholder. In the unit bundle the copy lookup degrades
    /// to the error's own description — the Connector's sentence here, a
    /// generic sentence for a blank wire message.
    @Test func theMessageFallsBackToSomethingReadable() {
        let withWireMessage = ChatRuntimeErrorNotice.make(for: V2RuntimeError(code: "claude_process_retired", message: connectorMessage))
        #expect(withWireMessage?.message == connectorMessage)
        #expect(withWireMessage?.message != "runtime.error.claudeProcessRetired")

        let blank = ChatRuntimeErrorNotice.make(for: V2RuntimeError(code: "claude_process_retired", message: "   "))
        #expect(blank?.message.isEmpty == false)
        #expect(blank?.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }

    /// Identity is the code plus the payload. One incident rebuilt keeps its
    /// identity; a parameter change — the signal the invariants name for a
    /// new event — produces a different identity even though the copy is a
    /// fixed sentence that cannot show the difference.
    @Test func theIdentityIsTheCodePlusThePayload() {
        let bare = ChatRuntimeErrorNotice.make(for: V2RuntimeError(code: "claude_process_retired", message: connectorMessage))
        let rebuilt = ChatRuntimeErrorNotice.make(for: V2RuntimeError(code: "claude_process_retired", message: connectorMessage))
        let payloadA = ChatRuntimeErrorNotice.make(for: V2RuntimeError(
            code: "claude_process_retired", message: connectorMessage,
            params: .object(["retirementConfirmed": .bool(true), "stuckSeconds": .number(600)])
        ))
        let payloadB = ChatRuntimeErrorNotice.make(for: V2RuntimeError(
            code: "claude_process_retired", message: connectorMessage,
            params: .object(["retirementConfirmed": .bool(true), "stuckSeconds": .number(601)])
        ))
        #expect(bare != nil && rebuilt != nil && payloadA != nil && payloadB != nil)
        #expect(bare == rebuilt)
        #expect(bare?.identity != payloadA?.identity)
        #expect(payloadA?.identity != payloadB?.identity)
        // The copy is fixed (`RuntimeErrorCopyTests.thePayloadNeverChangesWhatIsSaid`),
        // which is exactly why the identity has to carry the payload.
        #expect(bare?.message == payloadA?.message)
    }

    /// The same payload written in a different key order is the same event:
    /// `JSONValue.object` equality is key-order independent, and the identity
    /// must inherit that.
    @Test func keyOrderDoesNotFabricateANewEvent() {
        let first = ChatRuntimeErrorNotice.make(for: V2RuntimeError(
            code: "claude_process_retired", message: connectorMessage,
            params: .object(["stuckSeconds": .number(600), "interruptedBackgroundTaskCount": .number(2)])
        ))
        let reordered = ChatRuntimeErrorNotice.make(for: V2RuntimeError(
            code: "claude_process_retired", message: connectorMessage,
            params: .object(["interruptedBackgroundTaskCount": .number(2), "stuckSeconds": .number(600)])
        ))
        #expect(first != nil && reordered != nil)
        #expect(first?.identity == reordered?.identity)
    }
}
