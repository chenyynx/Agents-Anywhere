import Foundation
import Testing
@testable import ClientCore

/// The Code page's three tunable inks: one stored colour each, the shipped
/// pair when untouched, and a contrast-lifted dark variant for anything a
/// reader picks.
@Suite("Code page inks")
struct CodeInkColorSettingsTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "CodeInkColorSettingsTests-\(UUID().uuidString)")!
    }

    @Test("an untouched install keeps the built-in pairs")
    func untouchedInstallKeepsTheBuiltInPairs() {
        let store = defaults()
        #expect(ChatColorSettings.codeFileReference(in: store)
            == ChatColorSettings.defaultCodeFileReference)
        #expect(ChatColorSettings.codeExternalLink(in: store)
            == ChatColorSettings.defaultCodeExternalLink)
        #expect(ChatColorSettings.codeInlineCode(in: store)
            == ChatColorSettings.defaultCodeInlineCode)
    }

    @Test("a custom ink keeps its light value and lifts for dark")
    func customInkKeepsItsLightValueAndLiftsForDark() throws {
        let store = defaults()
        #expect(ChatColorSettings.setCodeColor("#131313",
            for: ChatColorSettings.codeExternalLinkKey, in: store))

        let pair = ChatColorSettings.codeExternalLink(in: store)
        #expect(pair.light == "#131313")
        #expect(pair.dark != pair.light)

        let ratio = try #require(ChatColorSettings.contrastRatio(
            pair.dark, ChatColorSettings.codeDarkPageHex))
        #expect(ratio >= 2.99)
    }

    @Test("an ink that already clears the dark page is unchanged")
    func brightInkIsUnchanged() {
        #expect(ChatColorSettings.darkVariant(of: "#F9F9F7") == "#F9F9F7")
    }

    @Test("a malformed stored value falls back to the default")
    func malformedStoredValueFallsBack() {
        let store = defaults()
        store.set("not-a-colour", forKey: ChatColorSettings.codeInlineCodeKey)
        #expect(ChatColorSettings.codeInlineCode(in: store)
            == ChatColorSettings.defaultCodeInlineCode)
    }

    @Test("reset restores every built-in pair")
    func resetRestoresBuiltInPairs() {
        let store = defaults()
        ChatColorSettings.setCodeColor("#123456",
            for: ChatColorSettings.codeFileReferenceKey, in: store)
        ChatColorSettings.setCodeColor("#654321",
            for: ChatColorSettings.codeExternalLinkKey, in: store)
        ChatColorSettings.setCodeColor("#ABCDEF",
            for: ChatColorSettings.codeInlineCodeKey, in: store)

        ChatColorSettings.resetCodeColors(in: store)

        #expect(ChatColorSettings.codeFileReference(in: store)
            == ChatColorSettings.defaultCodeFileReference)
        #expect(ChatColorSettings.codeExternalLink(in: store)
            == ChatColorSettings.defaultCodeExternalLink)
        #expect(ChatColorSettings.codeInlineCode(in: store)
            == ChatColorSettings.defaultCodeInlineCode)
    }

    @Test("the contrast helper matches the WCAG endpoints")
    func contrastEndpoints() throws {
        let ratio = try #require(ChatColorSettings.contrastRatio("#000000", "#FFFFFF"))
        #expect(abs(ratio - 21) < 0.01)
        #expect(ChatColorSettings.contrastRatio("nope", "#FFFFFF") == nil)
    }
}
