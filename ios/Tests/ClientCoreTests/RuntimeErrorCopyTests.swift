import Foundation
import Testing
@testable import ClientCore

/// The retired-process disclosure must reach the user as copy, not as the
/// Connector's English wire message — and the codes this build has never
/// heard of must keep reading as something a person can act on.
@Suite @MainActor struct RuntimeErrorCopyTests {
    /// The Connector's own English, exactly as it ships today. If this ever
    /// starts reaching a user for this code, the cause is back to "the model
    /// was slow" and the work that died with the process is invisible again.
    private let connectorMessage = "The Claude process was terminated after failing to respond. This turn produced no result and any running background tasks have ended. Please try again."

    @Test func theRetirementCodeHasCopy() {
        #expect(RuntimeLocalizedCopy.runtimeErrorCopyKey(for: "claude_process_retired") != nil)
    }

    /// The old timeout code is a DIFFERENT incident (no close happened), and
    /// its wording is still correct. Mapping it here would silently rewrite a
    /// sentence that was never the defect.
    @Test func theTimeoutCodeKeepsTheConnectorsOwnWording() {
        #expect(RuntimeLocalizedCopy.runtimeErrorCopyKey(for: "claude_scheduled_turn_timeout") == nil)
    }

    @Test func anUnknownCodeHasNoCopy() {
        #expect(RuntimeLocalizedCopy.runtimeErrorCopyKey(for: "code_from_a_newer_connector") == nil)
        #expect(RuntimeLocalizedCopy.runtimeErrorCopyKey(for: nil) == nil)
    }

    /// The contract with every future code: keep today's behaviour. An
    /// unknown code shows the Connector's message, NOT an empty string and
    /// NOT a serialized payload.
    @Test func anUnknownCodeStillReadsAsTheConnectorsMessage() {
        let error = V2RuntimeError(code: "code_from_a_newer_connector", message: connectorMessage)
        #expect(error.errorDescription == connectorMessage)
    }

    /// `params` is optional on the wire. A copy entry that needs it must
    /// degrade to its parameterless form; today the retirement copy is a
    /// fixed sentence, so a payload must not change the outcome either way.
    @Test func thePayloadNeverChangesWhatIsSaid() {
        let bare = V2RuntimeError(code: "claude_process_retired", message: connectorMessage)
        let loaded = V2RuntimeError(
            code: "claude_process_retired",
            message: connectorMessage,
            params: .object(["stuckSeconds": .number(600), "interruptedBackgroundTaskCount": .number(0)])
        )
        #expect(bare.params == nil)
        // The payload must really arrive, as given — `stringValue` is not the
        // right probe here: JSONValue deliberately stringifies numbers and
        // bools, so a numeric detail always reads as "600.0" text.
        #expect(loaded.params?["stuckSeconds"] == .number(600))
        #expect(RuntimeLocalizedCopy.runtimeErrorText(code: bare.code, params: bare.params)
                == RuntimeLocalizedCopy.runtimeErrorText(code: loaded.code, params: loaded.params))
    }

    /// The last resort is the one place a blank could reach a person. It must
    /// still be a sentence.
    @Test func aBlankConnectorMessageNeverReachesTheUserBlank() {
        let error = V2RuntimeError(code: "code_from_a_newer_connector", message: "   ")
        let described = error.errorDescription
        #expect(described?.isEmpty == false)
        #expect(described?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }

    @Test func theParamsSurviveDecodingFromTheWire() throws {
        let json = Data("""
        {"code":"claude_process_retired","message":"gone","params":{"stuckSeconds":600}}
        """.utf8)
        let error = try JSONDecoder().decode(V2RuntimeError.self, from: json)
        #expect(error.code == "claude_process_retired")
        #expect(error.params?["stuckSeconds"] != nil)
    }
}